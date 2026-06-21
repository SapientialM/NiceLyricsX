//
//  NetEaseClientTests.swift
//  NiceLyricsXTests
//
//  NetEase 客户端模型 + 解析测试 —
//
//  跟 LRCLIB 一样,只测模型解码 / LRC 解析(不走网络)。
//  端到端跑可以用 `swift test` 之外的环境,或者运行 app 看 stderr。
//

import XCTest
@testable import NiceLyricsX

final class NetEaseClientTests: XCTestCase {

    /// NetEase 搜索返回的 songs 数组能正确解码
    func testDecodeSearchResponse() throws {
        let json = """
        {
            "code": 200,
            "result": {
                "songs": [
                    {
                        "id": 1430583016,
                        "name": "海底",
                        "duration": 256111,
                        "artists": [{"id": 33694141, "name": "一支榴莲"}],
                        "album": {"id": 86447217, "name": "海底"}
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        struct Envelope: Codable {
            let result: Result
            struct Result: Codable {
                let songs: [NetEaseSong]
            }
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: json)
        XCTAssertEqual(envelope.result.songs.count, 1)
        let song = envelope.result.songs[0]
        XCTAssertEqual(song.id, 1430583016)
        XCTAssertEqual(song.name, "海底")
        XCTAssertEqual(song.artistsName, "一支榴莲")
        XCTAssertEqual(song.durationSeconds, 256.111, accuracy: 0.01)
    }

    /// lyrics 响应能解码
    func testDecodeLyricResponse() throws {
        let json = """
        {
            "code": 200,
            "lrc": {
                "version": 17,
                "lyric": "[00:00.000] 海底\\n[00:24.104] 散落的月光穿过了云"
            }
        }
        """.data(using: .utf8)!

        struct Envelope: Codable {
            let lrc: LRC?
            struct LRC: Codable {
                let lyric: String?
            }
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: json)
        XCTAssertNotNil(envelope.lrc)
        XCTAssertTrue(envelope.lrc!.lyric!.contains("海底"))
    }

    /// 空 lyrics 响应也能解码(lyric 字段为 nil 或空)
    func testDecodeEmptyLyricResponse() throws {
        let json = """
        {"code": 200, "lrc": {"version": 0, "lyric": ""}}
        """.data(using: .utf8)!

        struct Envelope: Codable {
            let lrc: LRC?
            struct LRC: Codable {
                let lyric: String?
            }
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: json)
        XCTAssertEqual(envelope.lrc?.lyric ?? "", "")
    }

    /// NetEase 拿到的 LRC 能正常被 LyricsParser 解析(端到端无网)
    func testLyricsParserOnNetEaseFormat() {
        let lrc = """
        [00:00.000] 海底
        [00:24.104] 散落的月光穿过了云
        [00:33.073] 躲着人群
        [00:37.493] 铺成大海的鳞
        """
        let lyrics = LyricsParser.parse(lrcText: lrc)
        XCTAssertEqual(lyrics.count, 4)
        XCTAssertEqual(lyrics[0].content, "海底")
        XCTAssertEqual(lyrics[0].position, 0.0, accuracy: 0.001)
        XCTAssertEqual(lyrics[3].position, 37.493, accuracy: 0.001)
    }
}
