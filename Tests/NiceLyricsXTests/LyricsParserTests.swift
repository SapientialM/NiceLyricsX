//
//  LyricsParserTests.swift
//  NiceLyricsXTests
//
//  解析器测试 ——
//
//  - 基础时间标签
//  - 多时间标签(同句重复唱)
//  - 行内翻译 【】
//  - [offset:N] ID 标签
//  - 排序与二分查找
//

import XCTest
@testable import NiceLyricsX

final class LyricsParserTests: XCTestCase {

    func testParseSimpleLrc() {
        let text = """
        [00:00.00]第一行
        [00:02.50]第二行
        [00:05.10]第三行
        """
        let lyrics = LyricsParser.parse(lrcText: text)
        XCTAssertEqual(lyrics.count, 3)
        XCTAssertEqual(lyrics[0].position, 0.00, accuracy: 0.001)
        XCTAssertEqual(lyrics[0].content, "第一行")
        XCTAssertEqual(lyrics[1].position, 2.50, accuracy: 0.001)
        XCTAssertEqual(lyrics[2].position, 5.10, accuracy: 0.001)
        XCTAssertNil(lyrics[0].translation)
    }

    func testParseMultiTagLine() {
        let text = """
        [00:01.00][00:05.00][00:09.00]副歌
        [00:03.00]普通一句
        """
        let lyrics = LyricsParser.parse(lrcText: text)
        XCTAssertEqual(lyrics.count, 4)
        // Lyrics 内部按 position 升序排,所以顺序是 1, 3, 5, 9
        XCTAssertEqual(lyrics[0].position, 1.00, accuracy: 0.001)
        XCTAssertEqual(lyrics[1].position, 3.00, accuracy: 0.001)
        XCTAssertEqual(lyrics[2].position, 5.00, accuracy: 0.001)
        XCTAssertEqual(lyrics[3].position, 9.00, accuracy: 0.001)
        // 同一句多时间标签 → 同一 content "副歌"
        XCTAssertEqual(lyrics[0].content, "副歌")
        XCTAssertEqual(lyrics[1].content, "普通一句")
        XCTAssertEqual(lyrics[2].content, "副歌")
        XCTAssertEqual(lyrics[3].content, "副歌")
    }

    func testParseInlineTranslation() {
        let text = "[00:01.00]Hello world【你好世界】"
        let lyrics = LyricsParser.parse(lrcText: text)
        XCTAssertEqual(lyrics.count, 1)
        XCTAssertEqual(lyrics[0].content, "Hello world")
        XCTAssertEqual(lyrics[0].translation, "你好世界")
    }

    func testParseIdTags() {
        let text = """
        [ti:标题]
        [ar:艺人]
        [al:专辑]
        [00:01.00]歌词
        """
        let lyrics = LyricsParser.parse(lrcText: text)
        XCTAssertEqual(lyrics.count, 1)
        XCTAssertEqual(lyrics[0].content, "歌词")
        XCTAssertEqual(lyrics.source, "LRCLIB")
    }

    func testParseOffsetTag() {
        let text = """
        [offset:+500]
        [00:00.00]第一行
        """
        let lyrics = LyricsParser.parse(lrcText: text)
        // [offset:+500] 写入 timeDelay(0.5s)
        XCTAssertEqual(lyrics.timeDelay, 0.5, accuracy: 0.001)
        XCTAssertEqual(lyrics.count, 1)
    }

    func testParseEmpty() {
        let lyrics = LyricsParser.parse(lrcText: "")
        XCTAssertEqual(lyrics.count, 0)
        XCTAssertTrue(lyrics.isEmpty)
    }

    func testParseIgnoresMalformedLines() {
        let text = """
        这是无效行
        [00:01.00]有效行
        [xx:yy]也无效
        """
        let lyrics = LyricsParser.parse(lrcText: text)
        XCTAssertEqual(lyrics.count, 1)
        XCTAssertEqual(lyrics[0].content, "有效行")
    }

    func testParseWindowsLineEndings() {
        let text = "[00:01.00]第一\r\n[00:02.00]第二\r\n"
        let lyrics = LyricsParser.parse(lrcText: text)
        XCTAssertEqual(lyrics.count, 2)
    }
}
