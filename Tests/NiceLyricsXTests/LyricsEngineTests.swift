//
//  LyricsEngineTests.swift
//  NiceLyricsXTests
//
//  歌词引擎测试 —— 用假播放器 + 临时缓存目录,不联网。
//
//  覆盖:
//  - timeDelay 的 ±10s 夹取(手动赋值 / 增量都夹)
//  - 曲目元数据只发一次(轮询不抖 UI)
//  - 缓存命中时引擎能走到 .loaded 并算出当前行
//

import XCTest
import Combine
@testable import NiceLyricsX

/// 只 yield 一次快照的假播放器。
private final class FakePlayer: MusicPlayerProtocol, @unchecked Sendable {
    let sourceName = "Fake"

    private let snapshot: PlaybackInfo
    private let stream: AsyncStream<PlaybackInfo>
    private let continuation: AsyncStream<PlaybackInfo>.Continuation

    init(info: PlaybackInfo) {
        self.snapshot = info
        var captured: AsyncStream<PlaybackInfo>.Continuation!
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    var isAvailable: Bool { get async { true } }
    var currentInfo: PlaybackInfo { get async { snapshot } }
    var infoStream: AsyncStream<PlaybackInfo> { stream }

    func start() {
        continuation.yield(snapshot)
        continuation.finish()
    }

    func stop() {}
}

@MainActor
final class LyricsEngineTests: XCTestCase {

    private func makeEngine(
        info: PlaybackInfo? = nil,
        provider: LyricsProvider = LyricsProvider()
    ) -> LyricsEngine {
        let player = FakePlayer(info: info ?? .empty)
        return LyricsEngine(player: player, provider: provider)
    }

    // MARK: - 偏移夹取

    func testAdjustTimeDelayClampsToRange() {
        let engine = makeEngine()
        engine.adjustTimeDelay(by: 100)
        XCTAssertEqual(engine.timeDelay, 10, accuracy: 0.0001)
        engine.adjustTimeDelay(by: -100)
        XCTAssertEqual(engine.timeDelay, -10, accuracy: 0.0001)
    }

    func testDirectTimeDelayAssignmentIsClamped() {
        let engine = makeEngine()
        engine.timeDelay = 42
        XCTAssertEqual(engine.timeDelay, 10, accuracy: 0.0001)
        engine.timeDelay = -42
        XCTAssertEqual(engine.timeDelay, -10, accuracy: 0.0001)
    }

    func testAdjustTimeDelayAccumulates() {
        let engine = makeEngine()
        engine.adjustTimeDelay(by: 0.1)
        engine.adjustTimeDelay(by: 0.2)
        XCTAssertEqual(engine.timeDelay, 0.3, accuracy: 0.0001)
    }

    func testTimeDelayCallbackFiresWithClampedValue() {
        let engine = makeEngine()
        var observed: TimeInterval?
        engine.onTimeDelayChange = { observed = $0 }
        engine.timeDelay = 99
        XCTAssertEqual(observed, 10)
    }

    // MARK: - 缓存命中 → 引擎状态机

    func testLoadsLyricsFromCacheAndPublishesTrack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NiceLyricsXTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = LyricsCache(directory: directory)
        let duration: TimeInterval = 200
        let key = Lyrics.trackKey(title: "海底", artist: "一支榴莲", duration: duration)
        let cached = Lyrics(
            lines: [
                LyricsLine(index: 0, position: 0, content: "散落的月光穿过了云"),
                LyricsLine(index: 1, position: 10, content: "躲着人群")
            ],
            source: "test",
            trackKey: key
        )
        await cache.save(lyrics: cached, trackKey: key)

        let info = PlaybackInfo(
            title: "海底",
            artist: "一支榴莲",
            album: "海底",
            duration: duration,
            state: .playing(start: Date()),
            source: "Fake"
        )
        let engine = LyricsEngine(
            player: FakePlayer(info: info),
            provider: LyricsProvider(cache: cache)
        )

        engine.start()
        await waitUntil { if case .loaded = engine.status { return true } else { return false } }

        guard case .loaded(let count) = engine.status else {
            XCTFail("engine did not reach .loaded, status=\(engine.status)")
            return
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(engine.currentLyrics?.count, 2)
        XCTAssertEqual(engine.currentTrack.title, "海底")
        XCTAssertEqual(engine.currentTrack.artist, "一支榴莲")
        XCTAssertTrue(engine.isPlaying)
        // 起播时刻就在刚刚 → 应该落在第一行
        XCTAssertEqual(engine.currentLineIndex, 0)
    }

    /// 没有在播放时,`clear()` 之后的静默态不应该反复抖动。
    func testIdleStateStaysIdle() async throws {
        let engine = makeEngine(info: .empty)
        engine.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.status, .idle)
        XCTAssertNil(engine.currentLyrics)
        XCTAssertNil(engine.currentLineIndex)
        XCTAssertFalse(engine.isPlaying)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
