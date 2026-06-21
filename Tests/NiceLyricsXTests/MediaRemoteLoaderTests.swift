//
//  MediaRemoteLoaderTests.swift
//  NiceLyricsXTests
//
//  MediaRemote 调用的回归测试 —
//
//  锁住的不变式:在 macOS 26 上,MediaRemoteLoader.getNowPlayingDictionary()
//  不得崩、必须返回 nil 或 [String: Any] 之一。
//
//  背景:macOS 26 把 `MRMediaRemoteGetNowPlayingInfo` 的实现从
//  `() -> CFDictionaryRef` 改成了 `(int32_t, void*, void*) -> CFDictionaryRef`
//  (公开头文件还是写的 0 参,谎言)。如果有人把 typealias 改回 0 参,
//  x0/x1/x2 是垃圾值,函数内部 deref 到 null page (地址 0x3) → EXC_BAD_ACCESS。
//
//  本测试是"必须不崩"的硬约束:任何会让这个调用崩的回归都会被 CI 抓住。
//

import XCTest
@testable import NiceLyricsX

final class MediaRemoteLoaderTests: XCTestCase {

    /// 主回归:在 macOS 26 上 getNowPlayingDictionary 不得崩。
    /// Apple Music 没在播时返回 nil;在播时返回合法 dict。
    func testGetNowPlayingDictionaryDoesNotCrash() throws {
        guard let loader = MediaRemoteLoader.shared else {
            throw XCTSkip("MediaRemote.framework not available")
        }
        XCTAssertTrue(loader.canUse, "MediaRemote should be available on macOS 26+")

        let dict = loader.getNowPlayingDictionary()
        if let dict {
            XCTAssertTrue(dict is [String: Any],
                          "getNowPlayingDictionary should return [String: Any] when non-nil")
        }
        // 走到这里说明没崩
    }

    /// 多次调用幂等不崩 — 防止"首次调用没事,第二次有状态污染才崩"这种隐藏回归。
    func testGetNowPlayingDictionaryIsIdempotent() throws {
        guard let loader = MediaRemoteLoader.shared else {
            throw XCTSkip("MediaRemote.framework not available")
        }
        for _ in 0..<5 {
            _ = loader.getNowPlayingDictionary()
        }
    }

    /// artworkToken 是 getNowPlayingDictionary 的封装,也得跟着不掉链子。
    func testArtworkTokenDoesNotCrash() throws {
        guard let loader = MediaRemoteLoader.shared else {
            throw XCTSkip("MediaRemote.framework not available")
        }
        _ = loader.artworkToken()
    }
}
