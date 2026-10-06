//
//  PlaybackCommandTests.swift
//  NiceLyricsXTests
//
//  切歌 / 播放控制相关测试。
//
//  最有价值的是 **AppleScript 编译测试**:每个命令的脚本都交给真实的
//  `osascript -e` 编译一遍。之前「动态 tell 目标」那个 -2741 就是这么抓到的 ——
//  那种错误编译器看不出来,只有真把脚本喂给 osascript 才会炸。
//

import XCTest
import os
@testable import NiceLyricsX

final class PlaybackCommandTests: XCTestCase {

    // MARK: 命令 → AppleScript 映射

    func testEveryCommandMapsToAScript() {
        for command in PlaybackCommand.allCases {
            let script = AppleMusicPlayer.appleScript(for: command)
            XCTAssertFalse(script.isEmpty, "\(command) 没生成脚本")
            XCTAssertTrue(script.contains("tell application \"Music\""), "\(command) 缺少 Music 调用")
        }
        // seek 带关联值,单独确认
        let seek = AppleMusicPlayer.appleScript(for: .seek(to: 12.5))
        XCTAssertTrue(seek.contains("set player position to 12.500"))
    }

    func testCommandVerbs() {
        let expectations: [(PlaybackCommand, String)] = [
            (.play, "to play"),
            (.pause, "to pause"),
            (.togglePlayPause, "to playpause"),
            (.next, "to next track"),
            (.previous, "to previous track"),
            (.stop, "to stop")
        ]
        for (command, verb) in expectations {
            let script = AppleMusicPlayer.appleScript(for: command)
            XCTAssertTrue(script.contains(verb), "\(command) 期望包含 \(verb),实际:\n\(script)")
        }
    }

    /// 每个控制脚本都必须先判断 Music 在不在跑,否则会把没开的 Music 拉起来。
    func testEveryScriptGuardsAgainstLaunchingMusic() {
        for command in PlaybackCommand.allCases {
            let script = AppleMusicPlayer.appleScript(for: command)
            XCTAssertTrue(
                script.contains("musicRunning is false then return"),
                "\(command) 缺少「Music 没运行就别碰」的保护"
            )
        }
        XCTAssertTrue(
            AppleMusicPlayer.appleScript(for: .seek(to: 1))
                .contains("musicRunning is false then return")
        )
    }

    /// 负数的 seek 会让 AppleScript 报错,必须夹到 0。
    func testSeekClampsNegativeTime() {
        let script = AppleMusicPlayer.appleScript(for: .seek(to: -30))
        XCTAssertTrue(script.contains("set player position to 0.000"), script)
        XCTAssertFalse(script.contains("to -30"), script)
    }

    func testSeekFormatsFractionalSeconds() {
        let script = AppleMusicPlayer.appleScript(for: .seek(to: 61.2345))
        XCTAssertTrue(script.contains("61.234"), script)   // 三位小数,locale 无关(用 %.3f)
    }

    // MARK: 真编译(绝不执行)

    /// 把每个控制脚本都真的编译一遍。
    ///
    /// ⚠️ 这里必须用 `NSAppleScript.compileAndReturnError` 而**不是**
    /// `osascript -e` —— 后者会**真的执行**脚本:测试一跑就会把用户的
    /// 音乐播放/暂停/切歌/停止挨个按一遍。编译只校验语法和术语解析。
    func testAllControlScriptsCompile() {
        var commands = PlaybackCommand.allCases
        commands.append(.seek(to: 12.5))

        for command in commands {
            let script = AppleMusicPlayer.appleScript(for: command)
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            XCTAssertNotNil(appleScript, "\(command) 构造 NSAppleScript 失败")
            let compiled = appleScript?.compileAndReturnError(&error) ?? false
            XCTAssertTrue(compiled, "\(command) 的 AppleScript 编译失败:\(error ?? [:])")
        }
    }
}

// MARK: - 进度条时间格式

final class PlaybackProgressLabelTests: XCTestCase {

    func testFormatsMinutesAndSeconds() {
        XCTAssertEqual(PlaybackProgressBar.timeLabel(0), "0:00")
        XCTAssertEqual(PlaybackProgressBar.timeLabel(5), "0:05")
        XCTAssertEqual(PlaybackProgressBar.timeLabel(65), "1:05")
        XCTAssertEqual(PlaybackProgressBar.timeLabel(59.6), "1:00", "四舍五入到最近一秒")
        XCTAssertEqual(PlaybackProgressBar.timeLabel(3600), "60:00", "超过一小时不做小时拆分")
    }

    func testHandlesInvalidValues() {
        XCTAssertEqual(PlaybackProgressBar.timeLabel(-3), "0:00")
        XCTAssertEqual(PlaybackProgressBar.timeLabel(.nan), "0:00")
        XCTAssertEqual(PlaybackProgressBar.timeLabel(.infinity), "0:00")
    }
}

// MARK: - 引擎控制入口

@MainActor
final class LyricsEngineControlTests: XCTestCase {

    /// 只读的假播放器(不实现 perform,走协议默认 no-op)。
    private final class ReadOnlyPlayer: MusicPlayerProtocol, @unchecked Sendable {
        let sourceName = "ReadOnly"
        private let stream: AsyncStream<PlaybackInfo>
        private let continuation: AsyncStream<PlaybackInfo>.Continuation

        init() {
            var captured: AsyncStream<PlaybackInfo>.Continuation!
            stream = AsyncStream { captured = $0 }
            continuation = captured
        }

        var isAvailable: Bool { get async { true } }
        var currentInfo: PlaybackInfo { get async { .empty } }
        var infoStream: AsyncStream<PlaybackInfo> { stream }
        func start() { continuation.finish() }
        func stop() {}
    }

    /// 记录收到的控制命令。
    private final class RecordingPlayer: MusicPlayerProtocol, @unchecked Sendable {
        let sourceName = "Recording"
        private let stream: AsyncStream<PlaybackInfo>
        private let continuation: AsyncStream<PlaybackInfo>.Continuation
        /// 用 OSAllocatedUnfairLock 而不是 NSLock —— `perform` 是 async 上下文,
        /// 那里不允许用会阻塞的 NSLock。
        private let received = OSAllocatedUnfairLock<[PlaybackCommand]>(initialState: [])

        init() {
            var captured: AsyncStream<PlaybackInfo>.Continuation!
            stream = AsyncStream { captured = $0 }
            continuation = captured
        }

        var isAvailable: Bool { get async { true } }
        var currentInfo: PlaybackInfo { get async { .empty } }
        var infoStream: AsyncStream<PlaybackInfo> { stream }
        func start() { continuation.finish() }
        func stop() {}

        func perform(_ command: PlaybackCommand) async {
            received.withLock { $0.append(command) }
        }

        var commands: [PlaybackCommand] {
            received.withLock { $0 }
        }
    }

    func testEngineForwardsCommandsToPlayer() async throws {
        let player = RecordingPlayer()
        let engine = LyricsEngine(player: player)

        engine.perform(.next)
        engine.perform(.togglePlayPause)
        engine.perform(.seek(to: 42))

        // perform 是 fire-and-forget 的 Task,给它一点时间
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(player.commands, [.next, .togglePlayPause, .seek(to: 42)])
    }

    /// 播放器不支持控制时不能崩(协议默认实现是 no-op)。
    func testEngineToleratesPlayerWithoutControlSupport() async throws {
        let engine = LyricsEngine(player: ReadOnlyPlayer())
        engine.perform(.play)
        engine.perform(.seek(to: 10))
        try await Task.sleep(nanoseconds: 100_000_000)
        // 走到这里没崩就算过
        XCTAssertFalse(engine.canControlPlayback)
    }

    func testPlaybackMetricsStartEmpty() {
        let engine = LyricsEngine(player: ReadOnlyPlayer())
        XCTAssertEqual(engine.playbackPosition, 0)
        XCTAssertEqual(engine.playbackDuration, 0)
        XCTAssertFalse(engine.canControlPlayback)
    }
}
