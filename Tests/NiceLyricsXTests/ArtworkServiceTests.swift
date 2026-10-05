//
//  ArtworkServiceTests.swift
//  NiceLyricsXTests
//
//  封面服务测试 —— 不联网,只测请求构造 / 响应解码 / URL 升级。
//

import XCTest
@testable import NiceLyricsX

final class ArtworkServiceTests: XCTestCase {

    // MARK: - 升级尺寸后缀

    func testUpgrades100To600() {
        let url = ArtworkService.upgradeArtworkURL(
            "https://is1-ssl.mzstatic.com/image/thumb/Music123/v4/ab/cd/ef/source/100x100bb.jpg"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music123/v4/ab/cd/ef/source/600x600bb.jpg"
        )
    }

    func testUpgradesArbitrarySize() {
        let url = ArtworkService.upgradeArtworkURL("https://example.com/a/60x60bb.jpg")
        XCTAssertEqual(url?.absoluteString, "https://example.com/a/600x600bb.jpg")
    }

    func testReturnsNilForEmptyOrNil() {
        XCTAssertNil(ArtworkService.upgradeArtworkURL(nil))
        XCTAssertNil(ArtworkService.upgradeArtworkURL(""))
    }

    func testKeepsURLWithoutSizeSuffix() {
        let url = ArtworkService.upgradeArtworkURL("https://example.com/cover.jpg")
        XCTAssertEqual(url?.absoluteString, "https://example.com/cover.jpg")
    }

    // MARK: - 请求构造

    func testSearchRequestEncodesTerm() throws {
        let request = try XCTUnwrap(
            ArtworkService.makeSearchRequest(title: "海底", artist: "一支榴莲")
        )
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "itunes.apple.com")
        XCTAssertEqual(components.path, "/search")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["term"], "海底 一支榴莲")
        XCTAssertEqual(items["entity"], "song")
    }

    func testSearchRequestSkipsEmptyArtist() throws {
        let request = try XCTUnwrap(ArtworkService.makeSearchRequest(title: "Hello", artist: "  "))
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let term = components.queryItems?.first(where: { $0.name == "term" })?.value
        XCTAssertEqual(term, "Hello")
    }

    func testSearchRequestNilWhenTitleEmpty() {
        XCTAssertNil(ArtworkService.makeSearchRequest(title: "", artist: "Adele"))
    }

    // MARK: - 响应解码

    func testDecodesFirstArtwork() throws {
        let json = """
        {
          "resultCount": 2,
          "results": [
            {"trackName": "海底", "artistName": "一支榴莲", "artworkUrl100": "https://example.com/a/100x100bb.jpg"},
            {"trackName": "海底", "artistName": "别人", "artworkUrl100": "https://example.com/b/100x100bb.jpg"}
          ]
        }
        """.data(using: .utf8)!

        let url = try ArtworkService.artworkURL(fromSearchResponse: json)
        XCTAssertEqual(url?.absoluteString, "https://example.com/a/600x600bb.jpg")
    }

    func testDecodesSkippingResultsWithoutArtwork() throws {
        let json = """
        {
          "resultCount": 2,
          "results": [
            {"trackName": "A", "artistName": "B"},
            {"trackName": "C", "artistName": "D", "artworkUrl100": "https://example.com/c/100x100bb.jpg"}
          ]
        }
        """.data(using: .utf8)!

        let url = try ArtworkService.artworkURL(fromSearchResponse: json)
        XCTAssertEqual(url?.absoluteString, "https://example.com/c/600x600bb.jpg")
    }

    func testDecodesEmptyResults() throws {
        let json = #"{"resultCount": 0, "results": []}"#.data(using: .utf8)!
        XCTAssertNil(try ArtworkService.artworkURL(fromSearchResponse: json))
    }

    // MARK: - 缓存 key

    func testCacheKeyNormalizes() {
        XCTAssertEqual(
            ArtworkService.cacheKey(title: " Hello ", artist: " Adele "),
            "hello|adele"
        )
    }

    func testCacheKeyEmptyWithoutTitle() {
        XCTAssertEqual(ArtworkService.cacheKey(title: "   ", artist: "Adele"), "")
    }
}
