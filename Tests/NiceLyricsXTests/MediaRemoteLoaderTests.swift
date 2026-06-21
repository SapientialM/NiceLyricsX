//
//  MediaRemoteLoaderTests.swift
//  NiceLyricsXTests
//
//  MediaRemote 调用的回归测试 —
//
//  历史:
//    macOS 14–15 上 typealias 是 `() -> CFDictionaryRef`,
//    macOS 26 上实现改成了 `(int32_t, void*, void*) -> CFDictionaryRef`(
//    公开头文件撒谎,disasm 才能看到)。如果用 0 参调,x0/x1/x2 是垃圾值,
//    ForClient deref 到 null page (0x3) → EXC_BAD_ACCESS。
//
//  当前状态:
//    macOS 26 上 register + getNowPlayingInfo 这条路径会让 MediaRemote 内部
//    异步 callback deref NULL(FAR=0x54)→ SIGSEGV。所以 `MediaRemoteLoader.init`
//    强制 return nil,所有 canUse 走 false,AppleMusicPlayer 退到 AppleScript
//    fallback。MediaRemote 的代码 / 类型 / 调用点全部保留,等 Apple 接口稳定
//    之后再放开。
//
//  本测试锁住不变式:MediaRemoteLoader.shared 永远是 nil(防止有人把
//  init 恢复成非 nil 重新引入 callback SIGSEGV)。
//

import XCTest
@testable import NiceLyricsX

final class MediaRemoteLoaderTests: XCTestCase {

    func testSharedIsAlwaysNil() {
        // 这是防止"有人把 init 恢复成 dlopen + dlsym、重新踩 callback 那个
        // 坑"的硬锁。当前 macOS 26 上任何 register+getNowPlayingInfo 组合
        // 都会让 MediaRemote 内部 callback deref NULL。
        XCTAssertNil(MediaRemoteLoader.shared,
                     "MediaRemoteLoader.shared should be nil — MediaRemote is disabled, " +
                     "AppleMusicPlayer must fall through to AppleScript")
    }
}
