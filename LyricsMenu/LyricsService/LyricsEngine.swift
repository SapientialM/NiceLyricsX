//
//  LyricsEngine.swift
//  NiceLyricsX
//
//  歌词引擎 —— 协调播放信息和歌词生命周期,对外广播:
//
//  - `currentLyrics: Lyrics?` —— 当前歌词
//  - `currentLineIndex: Int?` —— 当前高亮行
//  - `status: LyricsStatus` —— 加载状态
//
//  设计要点(借鉴 LyricsX `AppController` + `scheduleCurrentLineCheck`):
//  - 当 `PlaybackInfo` 变化且曲目切换时,触发新的歌词搜索(取消上一次进行中的任务)
//  - 切行策略:**不每帧 poll**,而是计算"距离下一行还有多久",
//    用 `Task.sleep` 精准唤醒,CPU 占用几乎为 0
//  - 偏移变化(`timeDelay` 改变)时,实时反映到 `currentLineIndex` 上
//  - `timeDelay` 改动后持久化到 UserDefaults(由 App 层负责通知)
//
//  本类是 `@MainActor` 的 —— 所有 UI 状态修改都在主线程,UI 直接订阅即可。
//

import Foundation
import Combine
import OSLog

@MainActor
public final class LyricsEngine: ObservableObject {

    // MARK: - Published

    @Published public private(set) var currentLyrics: Lyrics? = nil
    @Published public private(set) var currentLineIndex: Int? = nil
    @Published public private(set) var status: LyricsStatus = .idle

    /// 当前曲目元数据。只在「换歌」时更新 —— 播放进度每 2 秒刷一次,
    /// 如果每次都发新值,SwiftUI 会跟着无意义重绘。
    @Published public private(set) var currentTrack: PlaybackInfo = .empty

    /// 是否正在播放。暂停 / 停止时用来给 UI 显示状态。
    @Published public private(set) var isPlaying: Bool = false

    @Published public var timeDelay: TimeInterval = 0 {
        didSet {
            // 手动赋值也要夹到 ±10s(UI 的「重置」/ 启动时读 UserDefaults 都走这里)
            let clamped = max(-10, min(10, timeDelay))
            if clamped != timeDelay {
                timeDelay = clamped   // 在 didSet 里赋值不会重入 didSet
            }
            // 偏移改变 → 重新计算当前行
            recomputeCurrentLine(playbackTime: lastPlaybackTime)
            // 持久化(由外层把 userDefaultsDelay 传进来)
            onTimeDelayChange?(timeDelay)
        }
    }

    /// 偏移变化的回调(由 App 层设,用于写 UserDefaults)。
    public var onTimeDelayChange: ((TimeInterval) -> Void)?

    // MARK: - 内部状态

    private let player: MusicPlayerProtocol
    private let provider: LyricsProvider
    private let logger = Logger(subsystem: "com.local.NiceLyricsX", category: "LyricsEngine")

    private var currentTrackKey: String?
    private var lastPlaybackTime: TimeInterval = 0
    private var lastPlaybackInfo: PlaybackInfo = .empty

    private var playerObserverTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var nextLineWakeupTask: Task<Void, Never>?

    public init(player: MusicPlayerProtocol, provider: LyricsProvider = LyricsProvider()) {
        self.player = player
        self.provider = provider
    }

    // MARK: - 生命周期

    public func start() {
        guard playerObserverTask == nil else { return }
        player.start()

        playerObserverTask = Task { [weak self] in
            guard let self else { return }
            for await info in self.player.infoStream {
                await self.handlePlaybackInfo(info)
            }
        }
    }

    public func stop() {
        playerObserverTask?.cancel()
        playerObserverTask = nil
        loadTask?.cancel()
        loadTask = nil
        nextLineWakeupTask?.cancel()
        nextLineWakeupTask = nil
        player.stop()
    }

    // MARK: - 公开操作

    /// 手动重新搜索当前曲目。
    /// - Parameter forceRefresh: 默认跳过本地缓存,真正重新联网搜一次。
    public func reloadCurrent(forceRefresh: Bool = true) {
        guard !lastPlaybackInfo.title.isEmpty else { return }
        Task { await loadLyrics(for: lastPlaybackInfo, forceRefresh: forceRefresh) }
    }

    /// 清空本地歌词缓存,然后重新搜索当前曲目。
    public func clearCacheAndReload() async {
        await provider.clearCache()
        guard !lastPlaybackInfo.title.isEmpty else { return }
        await loadLyrics(for: lastPlaybackInfo, forceRefresh: true)
    }

    /// 手动设置偏移(供 UI 滑块 / 菜单按钮调用)。
    public func adjustTimeDelay(by delta: TimeInterval) {
        timeDelay = max(-10, min(10, timeDelay + delta))
    }

    /// 清空当前歌词(暂停时显示"等待播放"等)。
    public func clear() {
        resetToIdle()
    }

    // MARK: - 内部:处理播放信息

    private func handlePlaybackInfo(_ info: PlaybackInfo) async {
        // 0. 曲目元数据 / 播放状态 —— 只在真正变化时发布,避免每 2 秒一次空重绘
        publishTrackIfNeeded(info)

        let trackKey = Lyrics.trackKey(
            title: info.title,
            artist: info.artist,
            duration: info.duration
        )

        // 1. 如果是同一首曲子,只更新进度,不重新加载歌词
        if trackKey == currentTrackKey, !trackKey.isEmpty {
            lastPlaybackTime = info.playbackTime
            lastPlaybackInfo = info
            handleProgressUpdate(time: info.playbackTime, isPlaying: info.isPlaying)
            return
        }

        // 2. 曲目切换 → 重新加载
        lastPlaybackInfo = info
        lastPlaybackTime = info.playbackTime
        currentTrackKey = trackKey.isEmpty ? nil : trackKey

        guard !info.title.isEmpty, !info.artist.isEmpty else {
            resetToIdle()
            return
        }

        await loadLyrics(for: info)
        handleProgressUpdate(time: info.playbackTime, isPlaying: info.isPlaying)
    }

    /// 只在曲目身份 / 播放状态变化时推送,进度更新不推送。
    private func publishTrackIfNeeded(_ info: PlaybackInfo) {
        let trackChanged = info.title != currentTrack.title
            || info.artist != currentTrack.artist
            || info.album != currentTrack.album
            || info.source != currentTrack.source
            || abs(info.duration - currentTrack.duration) > 0.5
        if trackChanged {
            currentTrack = info
        }
        if isPlaying != info.isPlaying {
            isPlaying = info.isPlaying
        }
    }

    /// 回到「没在放歌」的静默态。重复调用不产生 @Published 抖动 ——
    /// 轮询每 2 秒来一次,每次无脑赋值会让整个 UI 每 2 秒重绘一遍。
    private func resetToIdle() {
        loadTask?.cancel()
        loadTask = nil
        nextLineWakeupTask?.cancel()
        nextLineWakeupTask = nil
        currentTrackKey = nil

        if currentLyrics != nil { currentLyrics = nil }
        if currentLineIndex != nil { currentLineIndex = nil }
        if status != .idle { status = .idle }
    }

    // MARK: - 内部:加载歌词

    private func loadLyrics(for info: PlaybackInfo, forceRefresh: Bool = false) async {
        loadTask?.cancel()
        if status != .searching { status = .searching }

        let task = Task { [provider, logger] in
            do {
                let lyrics = try await provider.loadLyrics(for: info, forceRefresh: forceRefresh)
                if Task.isCancelled { return }
                self.acceptLoadedLyrics(lyrics)
            } catch {
                if Task.isCancelled { return }
                logger.warning("歌词加载失败: \(error.localizedDescription, privacy: .public)")
                self.acceptLoadFailure(error)
            }
        }
        loadTask = task
    }

    private func acceptLoadedLyrics(_ lyrics: Lyrics) {
        // 用户全局偏移 + 歌词内置 offset 合并
        var merged = lyrics
        let builtInOffset = lyrics.timeDelay
        merged = Lyrics(
            lines: lyrics.lines,
            timeDelay: builtInOffset + timeDelay,
            source: lyrics.source,
            trackKey: lyrics.trackKey
        )
        currentLyrics = merged
        status = .loaded(lineCount: merged.lines.count)
        FileHandle.standardError.write(Data("[LyricsEngine] loaded \(merged.lines.count) lines, source=\(merged.source)\n".utf8))
        recomputeCurrentLine(playbackTime: lastPlaybackTime)
    }

    private func acceptLoadFailure(_ error: Error) {
        currentLyrics = nil
        currentLineIndex = nil
        FileHandle.standardError.write(Data("[LyricsEngine] load failed: \(error)\n".utf8))
        if let lErr = error as? LyricsError, case .noResult = lErr {
            status = .notFound
        } else {
            status = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - 内部:切行匹配

    /// 重新计算当前行(用于偏移变化 / 加载完成 / 状态切换时)。
    private func recomputeCurrentLine(playbackTime: TimeInterval) {
        guard let lyrics = currentLyrics else {
            currentLineIndex = nil
            return
        }
        currentLineIndex = lyrics.lineIndex(at: playbackTime)
    }

    /// 播放进度更新时调用。负责:
    /// - 即时更新 currentLineIndex
    /// - 安排"下一行前 50ms 精准唤醒"任务
    private func handleProgressUpdate(time: TimeInterval, isPlaying: Bool) {
        guard let lyrics = currentLyrics else {
            currentLineIndex = nil
            return
        }
        let newIndex = lyrics.lineIndex(at: time)
        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
        }

        // 重排下次唤醒
        nextLineWakeupTask?.cancel()
        guard isPlaying else { return }

        let progress = lyrics.progress(at: time)
        guard let _ = progress.next, let timeToNext = progress.timeToNext, timeToNext > 0 else {
            return
        }
        // 提前 50ms 唤醒,留出 UI 渲染余量
        let wakeup = max(0.05, timeToNext - 0.05)
        nextLineWakeupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wakeup * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // 用"经过的时间"算下一次,而不是累加 sleep,避免漂移
            let now = self.lastPlaybackInfo.playbackTime
            self.recomputeCurrentLine(playbackTime: now)
            self.handleProgressUpdate(time: now, isPlaying: self.lastPlaybackInfo.isPlaying)
        }
    }
}