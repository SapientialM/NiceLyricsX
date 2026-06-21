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
import os
#if canImport(OSLog)
import OSLog
#endif

public final class AppleMusicPlayer: MusicPlayerProtocol, @unchecked Sendable {

    public let sourceName: String = "Apple Music"

    // 通知 name(参考 LXPlayerAppleMusic.m)
    private static let mediaRemoteNotification = "com.apple.MediaRemote.nowPlayingInfo"
    private static let iTunesPlayerNotification = "com.apple.iTunes.playerInfo"

    // 进程 bundle id
    private let candidateBundleIDs = ["com.apple.Music", "com.apple.iTunes"]

    // 状态
    private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())
    private var observerTokens: [NSObjectProtocol] = []
    private var pollingTask: Task<Void, Never>?

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
            return queryNowPlaying()
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
                let info = self.queryNowPlaying()
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

    private func refresh() {
        let info = queryNowPlaying()
        broadcast(info)
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

    /// 查询当前播放信息。
    /// 优先 MediaRemote,失败回退 Apple Script。
    private func queryNowPlaying() -> PlaybackInfo {
        // 路径 1:MediaRemote
        if let mr = MediaRemoteLoader.shared, mr.canUse {
            let info = mr.getNowPlayingInfo()
            // MediaRemote 即使没播放器也可能返回 "kMRMediaRemoteNowPlayingInfoIsMusicApp = 0",
            // 这里兜底:title+artist 都为空 → 视为 stopped
            if !info.title.isEmpty || !info.artist.isEmpty {
                return enrichWithArtwork(info)
            }
        }

        // 路径 2:Apple Script
        if let info = queryViaAppleScript(), !info.title.isEmpty {
            return enrichWithArtwork(info)
        }

        return .empty
    }

    /// 从 Apple Script 拿当前曲目。
    private func queryViaAppleScript() -> PlaybackInfo? {
        let script = """
        tell application "System Events"
            set isRunning to (exists (processes whose name is "Music"))
            if not isRunning then
                set isRunning to (exists (processes whose name is "iTunes"))
            end if
        end tell

        if isRunning then
            tell application "Music"
                if player state is not stopped then
                    set tName to name of current track
                    set tArtist to artist of current track
                    set tAlbum to album of current track
                    set tDuration to duration of current track
                    set tPos to player position
                    set pState to player state
                    return tName & "||" & tArtist & "||" & tAlbum & "||" & (tDuration as string) & "||" & tPos & "||" & (pState as string)
                end if
            end tell
        end if
        return ""
        """

        guard let output = runAppleScript(script: script), !output.isEmpty else {
            return nil
        }

        let parts = output.components(separatedBy: "||")
        guard parts.count >= 6 else { return nil }

        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = TimeInterval(parts[3]) ?? 0
        let position = TimeInterval(parts[4]) ?? 0
        let stateStr = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)

        let state: PlaybackState
        if stateStr == "playing" {
            state = .playing(start: Date(timeIntervalSinceNow: -position))
        } else if stateStr == "paused" {
            state = .paused(time: position)
        } else {
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
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
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