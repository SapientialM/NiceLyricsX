//
//  MusicPlayerProtocol.swift
//  NiceLyricsX
//
//  播放器抽象协议 —— 所有播放器实现(Apple Music / iTunes / 未来的 Spotify 等)
//  都遵守同一接口,UI 层面向协议编程。
//
//  借鉴 LyricsX 的 `MusicPlayerProtocol` + `Agent` 模式:
//  - `currentInfo` 是当前快照(每次更新都广播新值)
//  - `infoStream` 是 AsyncStream,UI 层用 for-await 监听
//  - `start()` / `stop()` 控制订阅生命周期
//

import Foundation
import os

/// 播放器协议。任何能读取 macOS 音频播放器状态的实现都遵守此协议。
public protocol MusicPlayerProtocol: AnyObject, Sendable {

    /// 播放器标识(如 "Apple Music")。
    var sourceName: String { get }

    /// 是否支持当前正在运行的播放器。
    /// 用于在多个候选中自动选择最合适的(对应 LyricsX 的 NowPlaying 选择策略)。
    var isAvailable: Bool { get async }

    /// 当前播放快照(只读)。
    var currentInfo: PlaybackInfo { get async }

    /// 当前播放信息的广播流。
    /// - 启动订阅后立即 yield 一次当前快照(可能是 `.empty`)。
    /// - 曲目切换、进度跳变、状态切换时 yield 新值。
    /// - 同一曲目下,会按 1.5 秒容差合并抖动。
    var infoStream: AsyncStream<PlaybackInfo> { get }

    /// 启动监听(订阅通知、启动轮询)。可重入。
    func start()

    /// 停止监听并释放资源。
    func stop()
}

// MARK: - 组合播放器

/// 多 Player 代理 —— 在多个播放器中自动选正在播放的。
///
/// 借鉴 LyricsX `MusicPlayers.Selected`(继承 `Agent`):
/// - 优先用 `priority` 列表中第一个 `isPlaying == true` 的
/// - 都没有在播,就选第一个 `state != .stopped` 的
/// - 都没有,选第一个
public final class CompositeMusicPlayer: MusicPlayerProtocol, @unchecked Sendable {

    public let sourceName: String = "Auto"

    private let players: [MusicPlayerProtocol]
    private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())
    private var streamContinuations: [AsyncStream<PlaybackInfo>.Continuation] = []

    /// 内部状态 —— 必须放进 lock 才能在 async 上下文安全读写。
    private struct State {
        var designated: MusicPlayerProtocol?
        var subscribers: [UUID: AsyncStream<PlaybackInfo>.Continuation] = [:]

        init(designated: MusicPlayerProtocol? = nil) {
            self.designated = designated
        }
    }

    public init(players: [MusicPlayerProtocol]) {
        self.players = players
        // 默认选第一个,等收到首个 isPlaying 后再切换
        self.stateLock.withLock { $0.designated = players.first }
    }

    deinit {
        let subs = stateLock.withLock { state -> [UUID: AsyncStream<PlaybackInfo>.Continuation] in
            let s = state.subscribers
            state.subscribers.removeAll()
            return s
        }
        for cont in subs.values { cont.finish() }
        for p in players { p.stop() }
    }

    public var isAvailable: Bool {
        get async { true }
    }

    public var currentInfo: PlaybackInfo {
        get async {
            await reelectDesignated()
            let designated = stateLock.withLock { $0.designated }
            return await designated?.currentInfo ?? .empty
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

            // 立刻 yield 当前快照
            Task { [weak self] in
                guard let self else { return }
                await self.reelectDesignated()
                let designated = self.stateLock.withLock { $0.designated }
                let info = await designated?.currentInfo ?? .empty
                continuation.yield(info)
            }
        }
    }

    public func start() {
        for player in players { player.start() }
        // 监听所有 player 的流,转发到自己的 subscribers
        for player in players {
            Task { [weak self, weak player] in
                guard let self, let player else { return }
                for await info in player.infoStream {
                    await self.handle(info: info, from: player)
                }
            }
        }
    }

    public func stop() {
        for player in players { player.stop() }
        let subs = stateLock.withLock { state -> [UUID: AsyncStream<PlaybackInfo>.Continuation] in
            let s = state.subscribers
            state.subscribers.removeAll()
            return s
        }
        for cont in subs.values { cont.finish() }
    }

    // MARK: - 内部

    private func handle(info: PlaybackInfo, from player: MusicPlayerProtocol) async {
        await reelectDesignated()
        let designated = stateLock.withLock { $0.designated }
        // 只转发当前 designated player 的更新
        guard player === designated else { return }
        let activeSubs = stateLock.withLock { state -> [AsyncStream<PlaybackInfo>.Continuation] in
            Array(state.subscribers.values)
        }
        for cont in activeSubs { cont.yield(info) }
    }

    private func reelectDesignated() async {
        // 已在播的不动
        let cur = stateLock.withLock { $0.designated }
        if let cur, (await cur.currentInfo).isPlaying {
            return
        }
        // 找正在播放的
        let infos = await withTaskGroup(of: (MusicPlayerProtocol, PlaybackInfo).self) { group -> [(MusicPlayerProtocol, PlaybackInfo)] in
            for p in players {
                group.addTask { (p, await p.currentInfo) }
            }
            var results: [(MusicPlayerProtocol, PlaybackInfo)] = []
            for await pair in group { results.append(pair) }
            return results
        }

        let next = infos.first(where: { $0.1.isPlaying })?.0
            ?? infos.first(where: { $0.1.state != .stopped })?.0
            ?? players.first

        stateLock.withLock { state in
            if state.designated !== next { state.designated = next }
        }
    }
}