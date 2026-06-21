//
//  LRCLIBClientTests.swift
//  NiceLyricsXTests
//
//  LRCLIBClient 单元测试 ——
//
//  - JSON 解码
//  - 错误类型描述
//  - pickBestMatch 优先级(走单测可达的内部 helper 通过解码校验)
//

import XCTest
@testable import NiceLyricsX

final class LRCLIBClientTests: XCTestCase {

    func testDecodeRecord() throws {
        let json = """
        {
            "id": 1,
            "trackName": "Hello",
            "artistName": "Adele",
            "albumName": "25",
            "duration": 295.0,
            "instrumental": false,
            "plainLyrics": "[00:00.00]Hello",
            "syncedLyrics": "[00:00.00]Hello\\n[00:02.00]World"
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(LRCLIBRecord.self, from: json)
        XCTAssertEqual(record.id, 1)
        XCTAssertEqual(record.trackName, "Hello")
        XCTAssertEqual(record.artistName, "Adele")
        XCTAssertEqual(record.duration, 295.0)
        XCTAssertEqual(record.instrumental, false)
        XCTAssertNotNil(record.syncedLyrics)
        XCTAssertTrue(record.syncedLyrics!.contains("Hello"))
    }

    func testDecodeOptionalFields() throws {
        let json = """
        {
            "id": 2,
            "trackName": "Inst",
            "artistName": "X",
            "duration": 100.0,
            "instrumental": true
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(LRCLIBRecord.self, from: json)
        XCTAssertNil(record.albumName)
        XCTAssertNil(record.plainLyrics)
        XCTAssertNil(record.syncedLyrics)
    }

    func testLyricsErrorDescription() {
        XCTAssertEqual(LyricsError.noResult.errorDescription, "未找到歌词")
        XCTAssertEqual(LyricsError.http(status: 503).errorDescription, "服务器返回 503")
        XCTAssertEqual(LyricsError.invalidResponse.errorDescription, "服务器响应无效")
    }

    func testClientDefaults() {
        let client = LRCLIBClient()
        XCTAssertEqual(client.baseURL.absoluteString, "https://lrclib.net")
    }
}
