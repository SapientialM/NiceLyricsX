//
//  LyricsTests.swift
//  NiceLyricsXTests
//
//  Lyrics / LyricsLine 数据模型 + 二分查找测试
//

import XCTest
@testable import NiceLyricsX

final class LyricsTests: XCTestCase {

    private func makeSample() -> Lyrics {
        let lines = (0..<5).map { i in
            LyricsLine(index: i, position: TimeInterval(i) * 2.0, content: "line\(i)")
        }
        return Lyrics(lines: lines, timeDelay: 0, source: "test")
    }

    func testRandomAccessCollection() {
        let lyrics = makeSample()
        XCTAssertEqual(lyrics.count, 5)
        XCTAssertEqual(lyrics.startIndex, 0)
        XCTAssertEqual(lyrics.endIndex, 5)
        XCTAssertEqual(lyrics[2].content, "line2")
    }

    func testLineIndexBeforeFirst() {
        let lyrics = makeSample()
        // time = -1, no line has position <= -1
        XCTAssertNil(lyrics.lineIndex(at: -1))
    }

    func testLineIndexAtBoundary() {
        let lyrics = makeSample()
        // line positions: 0, 2, 4, 6, 8
        XCTAssertEqual(lyrics.lineIndex(at: 0), 0)
        XCTAssertEqual(lyrics.lineIndex(at: 1.99), 0)
        XCTAssertEqual(lyrics.lineIndex(at: 2.0), 1)
        XCTAssertEqual(lyrics.lineIndex(at: 5.5), 2)
        XCTAssertEqual(lyrics.lineIndex(at: 8.0), 4)
        // 超过最后一行
        XCTAssertEqual(lyrics.lineIndex(at: 100), 4)
    }

    func testTimeDelayShiftsLineIndex() {
        let lyrics = Lyrics(lines: [
            LyricsLine(index: 0, position: 0, content: "a"),
            LyricsLine(index: 1, position: 2, content: "b")
        ], timeDelay: 1.0)
        // delay=1 表示 +1 秒后切到下一行
        XCTAssertEqual(lyrics.lineIndex(at: 0), 0)
        XCTAssertEqual(lyrics.lineIndex(at: 1.0), 1)
    }

    func testProgress() {
        let lyrics = makeSample()
        let p = lyrics.progress(at: 2.5)
        XCTAssertEqual(p.current, 1)
        XCTAssertEqual(p.next, 2)
        XCTAssertEqual(p.timeToNext!, 1.5, accuracy: 0.001)
    }

    func testContext() {
        let lyrics = makeSample()
        let ctx = lyrics.context(at: 2.0)
        XCTAssertEqual(ctx.previous?.content, "line0")
        XCTAssertEqual(ctx.current?.content, "line1")
        XCTAssertEqual(ctx.next?.content, "line2")
    }

    func testTrackKey() {
        let key = Lyrics.trackKey(title: "Song", artist: "Artist", duration: 200)
        XCTAssertEqual(key, "song|artist|200")
    }

    func testSortsByPosition() {
        let lyrics = Lyrics(lines: [
            LyricsLine(index: 0, position: 5, content: "later"),
            LyricsLine(index: 1, position: 1, content: "earlier")
        ])
        XCTAssertEqual(lyrics[0].content, "earlier")
        XCTAssertEqual(lyrics[1].content, "later")
    }
}
