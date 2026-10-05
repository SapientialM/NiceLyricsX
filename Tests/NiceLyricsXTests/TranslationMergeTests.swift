//
//  TranslationMergeTests.swift
//  NiceLyricsXTests
//
//  翻译合并测试 ——
//  - `Lyrics.translationKey` 的毫秒对齐
//  - `Lyrics.applyingTranslations` 不覆盖已有内嵌翻译
//  - 网易云 tlyric → 查表
//

import XCTest
@testable import NiceLyricsX

final class TranslationMergeTests: XCTestCase {

    // MARK: - translationKey

    func testTranslationKeyRoundsToMilliseconds() {
        XCTAssertEqual(Lyrics.translationKey(for: 1.2345), 1235)
        XCTAssertEqual(Lyrics.translationKey(for: 0), 0)
        // 同一时间戳的浮点误差应该落到同一个 key
        XCTAssertEqual(Lyrics.translationKey(for: 12.345), Lyrics.translationKey(for: 12.3454))
    }

    // MARK: - applyingTranslations

    func testAppliesTranslation() {
        let lyrics = Lyrics(lines: [
            LyricsLine(index: 0, position: 0, content: "Hello"),
            LyricsLine(index: 1, position: 2.5, content: "World")
        ])
        let merged = lyrics.applyingTranslations([
            Lyrics.translationKey(for: 0): "你好",
            Lyrics.translationKey(for: 2.5): "世界"
        ])
        XCTAssertEqual(merged[0].translation, "你好")
        XCTAssertEqual(merged[1].translation, "世界")
        // 正文不受影响
        XCTAssertEqual(merged[0].content, "Hello")
    }

    func testDoesNotOverwriteInlineTranslation() {
        let lyrics = Lyrics(lines: [
            LyricsLine(index: 0, position: 0, content: "Hello", translation: "内嵌翻译")
        ])
        let merged = lyrics.applyingTranslations([Lyrics.translationKey(for: 0): "外部翻译"])
        XCTAssertEqual(merged[0].translation, "内嵌翻译")
    }

    func testLeavesUnmatchedLinesUntouched() {
        let lyrics = Lyrics(lines: [
            LyricsLine(index: 0, position: 0, content: "A"),
            LyricsLine(index: 1, position: 1, content: "B")
        ])
        let merged = lyrics.applyingTranslations([Lyrics.translationKey(for: 0): "甲"])
        XCTAssertEqual(merged[0].translation, "甲")
        XCTAssertNil(merged[1].translation)
    }

    func testEmptyTableIsIdentity() {
        let lyrics = Lyrics(lines: [LyricsLine(index: 0, position: 0, content: "A")])
        XCTAssertEqual(lyrics.applyingTranslations([:]), lyrics)
    }

    func testPreservesTimeDelayAndSource() {
        let lyrics = Lyrics(
            lines: [LyricsLine(index: 0, position: 0, content: "A")],
            timeDelay: 0.4,
            source: "NetEase",
            trackKey: "k"
        )
        let merged = lyrics.applyingTranslations([0: "甲"])
        XCTAssertEqual(merged.timeDelay, 0.4)
        XCTAssertEqual(merged.source, "NetEase")
        XCTAssertEqual(merged.trackKey, "k")
    }

    // MARK: - 网易云 tlyric 查表

    func testNetEaseTranslationTable() {
        let tlyric = """
        [00:00.000] 海底
        [00:24.104] 散落的月光穿过了云
        """
        let table = NetEaseClient.translationTable(fromLRC: tlyric)
        XCTAssertEqual(table[Lyrics.translationKey(for: 0)], "海底")
        XCTAssertEqual(table[Lyrics.translationKey(for: 24.104)], "散落的月光穿过了云")
    }

    func testNetEaseTranslationTableIgnoresEmptyLRC() {
        XCTAssertTrue(NetEaseClient.translationTable(fromLRC: "").isEmpty)
    }

    /// 端到端(无网):正文 + 翻译两段 LRC 合到一起。
    func testMergesNetEaseLRCWithTranslation() {
        let lrc = """
        [00:00.000] 散落的月光穿过了云
        [00:05.000] 躲着人群
        """
        let tlyric = """
        [00:00.000] Moonlight falls through the clouds
        [00:05.000] Hiding from the crowd
        """
        let parsed = LyricsParser.parse(lrcText: lrc, source: "NetEase")
        let merged = NetEaseClient.mergingTranslation(into: parsed, tlyric: tlyric)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].translation, "Moonlight falls through the clouds")
        XCTAssertEqual(merged[1].translation, "Hiding from the crowd")
        XCTAssertEqual(merged.source, "NetEase + 翻译")
    }

    /// tlyric 存在但一行都对不上时,不能谎报"有翻译"。
    func testUnmatchedTlyricKeepsOriginalSource() {
        let parsed = LyricsParser.parse(
            lrcText: "[00:00.000] 正文",
            source: "NetEase"
        )
        let merged = NetEaseClient.mergingTranslation(into: parsed, tlyric: "[00:99.000] 对不上的翻译")
        XCTAssertEqual(merged.source, "NetEase")
        XCTAssertNil(merged[0].translation)
    }

    func testNilTlyricIsIdentity() {
        let parsed = LyricsParser.parse(lrcText: "[00:00.000] 正文", source: "NetEase")
        XCTAssertEqual(NetEaseClient.mergingTranslation(into: parsed, tlyric: nil), parsed)
        XCTAssertEqual(NetEaseClient.mergingTranslation(into: parsed, tlyric: ""), parsed)
    }
}
