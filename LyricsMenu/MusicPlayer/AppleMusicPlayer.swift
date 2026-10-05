//
//  AppleMusicPlayer.swift
//  NiceLyricsX
//
//  Apple Music / iTunes 播放器实现。
//
//  读取策略(双轨):
//  1. **首选**:MediaRemote 私有 framework(macOS 14+)
//     - 一次调用 `MRMediaRemoteGetNowPlayingInfo` 拿所有信息
//     - 通过 `com.apple.MediaRemote.nowPlayingInfo` DistributedNotification 监听变更
//  2. **回退**:Apple Script(`osascript` via `NSAppleScript` 或 `Process`)
//     - macOS 13 及更早 / 没有 MediaRemote 时
//     - 通过 `com.apple.iTunes.playerInfo` DistributedNotification 监听
//  3. **兜底**:每 2 秒轮询一次(防止通知丢失)
//
//  参考 LyricsX 的 `LXPlayerAppleMusic.m` 和 `SelectedPlayer.scheduleManualUpdate` 思路:
//  - 用 NSDistributedNotificationCenter 接收变更通知
//  - 用 1.5 秒容差吃掉抖动
//  - 兜底轮询由 `NowPlaying` 统一负责(在 `CompositeMusicPlayer` 中)
//

import Foundation
import AppKit
import OSLog

public final class AppleMusicPlayer: MusicPlayerProtocol, @unchecked Sendable {

    public let sourceName: String = "Apple Music"
    private let logger = Logger(subsystem: "com.local.NiceLyricsX", category: "AppleMusicPlayer")

    // 通知 name(参考 LXPlayerAppleMusic.m)
    private static let mediaRemoteNotification = "com.apple.MediaRemote.nowPlayingInfo"
    private static let iTunesPlayerNotification = "com.apple.iTunes.playerInfo"

    // 进程 bundle id
    private let candidateBundleIDs = ["com.apple.Music", "com.apple.iTunes"]

    // 状态
    private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())
    private var observerTokens: [NSObjectProtocol] = []
    private var pollingTask: Task<Void, Never>?

    /// AppleScript 是同步阻塞的(`Process.waitUntilExit()`),绝不能跑在主线程 ——
    /// 否则每次轮询 / 每次通知进来都会卡住 UI。所有脚本调用扔到这条串行队列上。
    private let scriptQueue = DispatchQueue(
        label: "com.local.NiceLyricsX.appleMusic.script",
        qos: .utility
    )

    /// 同一时刻只允许一次脚本查询在飞。轮询 2s 一次,osascript 偶尔更慢,
    /// 不做合并会排队堆积。
    private let refreshInFlight = OSAllocatedUnfairLock<Bool>(initialState: false)

    private struct State {
        var lastYield: PlaybackInfo = .empty
        var subscribers: [UUID: AsyncStream<PlaybackInfo>.Continuation] = [:]
    }

    public init() {}

    deinit { stop() }

    // MARK: - MusicPlayerProtocol

    public var isAvailable: Bool {
        get async {
            // 1) MediaRemote 可用就直接可用
            if MediaRemoteLoader.shared?.canUse == true { return true }
            // 2) 否则检查 Apple Music / iTunes 是否在跑
            return isAppleMusicRunning()
        }
    }

    public var currentInfo: PlaybackInfo {
        get async {
            // 路径 1:MediaRemote(非阻塞,当前 macOS 26 上是禁用状态)
            if let mr = MediaRemoteLoader.shared, mr.canUse {
                let info = mr.getNowPlayingInfo()
                if !info.title.isEmpty || !info.artist.isEmpty {
                    return enrichWithArtwork(info)
                }
            }

            // 路径 2:AppleScript —— 阻塞调用,放到专用队列
            let info = await runOnScriptQueue { self.queryViaAppleScriptBlocking() }
            guard let info, !info.title.isEmpty else { return .empty }
            return enrichWithArtwork(info)
        }
    }

    public var infoStream: AsyncStream<PlaybackInfo> {
        AsyncStream { continuation in
            let id = UUID()
            self.stateLock.withLock { state in
                state.subscribers[id] = continuation
            }

            continuation.onTermination = { [weak self] _ in
                _ = self?.stateLock.withLock { state in
                    state.subscribers.removeValue(forKey: id)
                }
            }

            // 立即 yield 当前
            Task { [weak self] in
                guard let self else { return }
                let info = await self.currentInfo
                self.broadcast(info)
            }
        }
    }

    public func start() {
        let alreadyRunning = stateLock.withLock { _ in pollingTask != nil }
        if alreadyRunning { return }

        // 监听 DistributedNotification
        let center = DistributedNotificationCenter.default()

        // MediaRemote 通知(macOS 14+)
        if MediaRemoteLoader.shared?.canUse == true {
            MediaRemoteLoader.shared?.registerForNotifications()
            let token = center.addObserver(
                forName: NSNotification.Name(Self.mediaRemoteNotification),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
            observerTokens.append(token)
        }

        // iTunes 老通知(始终监听,兼容老版本系统)
        let itunesToken = center.addObserver(
            forName: NSNotification.Name(Self.iTunesPlayerNotification),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        observerTokens.append(itunesToken)

        // 兜底轮询 —— 2 秒一次,弥补通知丢失
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                guard let self else { return }
                self.refresh()
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil

        let center = DistributedNotificationCenter.default()
        for token in observerTokens { center.removeObserver(token) }
        observerTokens.removeAll()

        MediaRemoteLoader.shared?.unregisterForNotifications()

        let subs = stateLock.withLock { state -> [UUID: AsyncStream<PlaybackInfo>.Continuation] in
            let s = state.subscribers
            state.subscribers.removeAll()
            return s
        }
        for cont in subs.values { cont.finish() }
    }

    // MARK: - Refresh

    /// 触发一次查询。非阻塞:立刻返回,查询结果异步广播。
    ///
    /// 早先的实现直接在调用线程上跑 `osascript && waitUntilExit()`,而这个
    /// 方法是从 MainActor 的轮询 Task / 通知回调里调的 —— 等于每 2 秒把主线程
    /// 冻住几十到几百毫秒。现在脚本走 `scriptQueue`,主线程只做广播。
    private func refresh() {
        let shouldStart = refreshInFlight.withLock { inFlight -> Bool in
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard shouldStart else { return }

        Task { [weak self] in
            guard let self else { return }
            let info = await self.currentInfo
            self.refreshInFlight.withLock { $0 = false }
            self.broadcast(info)
        }
    }

    /// 把阻塞的脚本调用挪到专用串行队列上执行。
    private func runOnScriptQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            scriptQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private func broadcast(_ info: PlaybackInfo) {
        let (active, shouldYield) = stateLock.withLock { state -> ([AsyncStream<PlaybackInfo>.Continuation], Bool) in
            let last = state.lastYield
            if isApproximatelySame(info, last) {
                // 同一个曲目、同一播放进度 → 不重复 yield
                // 但如果 state 切换了(play/pause/stop),仍要 yield
                if case (PlaybackState.stopped, PlaybackState.stopped) = (info.state, last.state) {
                    return ([], false)
                }
            }
            state.lastYield = info
            return (Array(state.subscribers.values), true)
        }

        guard shouldYield else { return }
        for cont in active { cont.yield(info) }
    }

    /// 判断两条 `PlaybackInfo` 在用户感知层面是否"相同"。
    private func isApproximatelySame(_ a: PlaybackInfo, _ b: PlaybackInfo) -> Bool {
        guard a.title == b.title,
              a.artist == b.artist,
              a.album == b.album else { return false }
        return a.state.approximateEqual(to: b.state, tolerate: 1.5)
    }

    // MARK: - Query

    /// 读取当前播放信息的 AppleScript。
    ///
    /// 两点注意:
    /// 1. 先判断 Music 在不在跑,不在跑就直接返回 —— 否则 `tell application
    ///    "Music"` 会把没开的 Music 拉起来。
    /// 2. 不能写成 `tell application runningApp`(用一个字符串变量当目标):
    ///    AppleScript 是在编译期按目标 App 的 sdef 解析 `player state`
    ///    这类术语的,动态目标拿不到术语表 → 语法错误 (-2741)。
    ///    要动态目标必须配 `using terms from application "Music"`,没必要。
    ///    macOS 10.15 起 iTunes 已经并入 Music,这里只认 Music。
    ///
    /// 有单测直接拿它去跑 `osascript -e`,确保它至少能被编译。
    static let nowPlayingScript = """
    tell application "System Events"
        set musicRunning to exists (processes whose bundle identifier is "com.apple.Music")
    end tell
    if musicRunning is false then return ""

    tell application "Music"
        if player state is not stopped then
            set tName to name of current track
            set tArtist to artist of current track
            set tAlbum to album of current track
            set tDuration to duration of current track
            set tPos to player position
            set pState to player state
            return tName & "||" & tArtist & "||" & tAlbum & "||" & (tDuration as string) & "||" & (tPos as string) & "||" & (pState as string)
        end if
    end tell
    return ""
    """

    /// 从 Apple Script 拿当前曲目。**阻塞调用**,只在 `scriptQueue` 上执行。
    private func queryViaAppleScriptBlocking() -> PlaybackInfo? {
        let script = Self.nowPlayingScript

        guard let output = runAppleScript(script: script), !output.isEmpty else {
            return nil
        }

        let parts = output.components(separatedBy: "||")
        guard parts.count >= 6 else {
            FileHandle.standardError.write(Data("[AppleMusicPlayer] malformed: \(output)\n".utf8))
            return nil
        }

        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Self.parseAppleScriptNumber(parts[3])
        let position = Self.parseAppleScriptNumber(parts[4])
        let stateStr = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)

        let state: PlaybackState
        switch stateStr {
        case "playing":
            state = .playing(start: Date(timeIntervalSinceNow: -position))
        case "paused":
            state = .paused(time: position)
        default:
            state = .stopped
        }

        return PlaybackInfo(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            state: state,
            source: "Apple Music"
        )
    }

    /// AppleScript 把 real 转成字符串时用的是**系统 locale 的小数点** ——
    /// 中文 / 欧洲 locale 下会得到 `"256,111"`,直接 `TimeInterval(_:)` 会失败
    /// 变成 0(时长 0 → 歌词匹配选错版本,进度 0 → 起播时间戳全错)。
    /// 这里兼容逗号小数点。
    static func parseAppleScriptNumber(_ raw: String) -> TimeInterval {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = TimeInterval(trimmed) { return value }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        return TimeInterval(normalized) ?? 0
    }

    /// 包装 `osascript` 执行。
    private func runAppleScript(script: String) -> String? {
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("osascript launch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            FileHandle.standardError.write(Data("[AppleMusicPlayer] osascript exit=\(process.terminationStatus) stderr=\(errStr)\n".utf8))
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 补充封面 URL(Apple Music artwork 走 600x600 替换)。
    private func enrichWithArtwork(_ info: PlaybackInfo) -> PlaybackInfo {
        guard let token = artworkTokenFromNowPlaying(),
              !token.isEmpty else { return info }

        // iTunes Search API 反查 artwork(无登录需求)
        let url = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Music/\(token)/600x600bb.jpg")
        return PlaybackInfo(
            trackID: info.trackID,
            title: info.title,
            artist: info.artist,
            album: info.album,
            duration: info.duration,
            state: info.state,
            source: info.source,
            artworkURL: url
        )
    }

    /// MediaRemote 字典里通常带 `kMRMediaRemoteNowPlayingInfoArtworkIdentifier`,
    /// 我们拿它构造 iTunes 风格 artwork URL。
    private func artworkTokenFromNowPlaying() -> String? {
        return MediaRemoteLoader.shared?.artworkToken()
    }

    /// 检查 Apple Music / iTunes 是否在跑。
    private func isAppleMusicRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { app in
            guard let bid = app.bundleIdentifier else { return false }
            return candidateBundleIDs.contains(bid)
        }
    }
}