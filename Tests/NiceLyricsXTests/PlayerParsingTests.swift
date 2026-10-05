//
//  PlayerParsingTests.swift
//  NiceLyricsXTests
//
//  AppleScript 返回值解析 + 桌面歌词窗口尺寸 ——
//
//  回归点:
//  - AppleScript 把 real 转字符串时用系统 locale 的小数点,中文 / 欧洲
//    locale 下是逗号。旧实现直接 `TimeInterval(raw)` 会得到 0,
//    导致时长匹配错版本、起播时间戳全错。
//  - 桌面歌词窗口高度必须跟着字号 / 翻译开关变,否则大字被裁。
//

import XCTest
@testable import NiceLyricsX

final class AppleMusicPlayerParsingTests: XCTestCase {

    func testParsesPlainDecimal() {
        XCTAssertEqual(AppleMusicPlayer.parseAppleScriptNumber("256.111"), 256.111, accuracy: 0.0001)
    }

    func testParsesCommaDecimalSeparator() {
        XCTAssertEqual(AppleMusicPlayer.parseAppleScriptNumber("256,111"), 256.111, accuracy: 0.0001)
    }

    func testParsesInteger() {
        XCTAssertEqual(AppleMusicPlayer.parseAppleScriptNumber("42"), 42, accuracy: 0.0001)
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(AppleMusicPlayer.parseAppleScriptNumber("  12.5\n"), 12.5, accuracy: 0.0001)
    }

    func testGarbageFallsBackToZero() {
        XCTAssertEqual(AppleMusicPlayer.parseAppleScriptNumber("missing value"), 0)
        XCTAssertEqual(AppleMusicPlayer.parseAppleScriptNumber(""), 0)
    }
}

/// 回归:AppleScript 必须能被 `osascript` **编译**通过。
///
/// 曾经踩过的坑:把 `tell application "Music"` 改成 `tell application runningApp`
/// (用变量当目标),看起来只是"支持 Music / iTunes 二选一",实际上 AppleScript
/// 需要按目标 App 的 sdef 解析 `player state` 这类术语,动态目标解析不了,
/// 直接编译报错 (-2741) —— 而且只在运行时 osascript 的 stderr 里才看得到,
/// 单元测试不跑脚本就永远发现不了。
final class AppleScriptCompileTests: XCTestCase {

    func testNowPlayingScriptCompiles() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", AppleMusicPlayer.nowPlayingScript]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let errText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertFalse(
            errText.contains("syntax error"),
            "AppleScript 编译失败: \(errText)"
        )
        XCTAssertEqual(
            process.terminationStatus, 0,
            "osascript 退出码 \(process.terminationStatus),stderr: \(errText)"
        )
    }

    /// 脚本输出要么是空串(没在播放),要么是 6 段 `||` 分隔的曲目信息。
    func testScriptOutputShape() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", AppleMusicPlayer.nowPlayingScript]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let output = (String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if output.isEmpty { return }   // 当前没有在播放,合法
        XCTAssertEqual(output.components(separatedBy: "||").count, 6, "非预期输出: \(output)")
    }
}

@MainActor
final class DesktopLyricsPanelSizeTests: XCTestCase {

    func testHeightGrowsWithFontSize() {
        let small = DesktopLyricsWindowController.panelSize(fontSize: 16, showTranslation: false)
        let large = DesktopLyricsWindowController.panelSize(fontSize: 48, showTranslation: false)
        XCTAssertGreaterThan(large.height, small.height)
        XCTAssertEqual(small.width, large.width)
    }

    func testTranslationNeedsMoreHeight() {
        let without = DesktopLyricsWindowController.panelSize(fontSize: 28, showTranslation: false)
        let with = DesktopLyricsWindowController.panelSize(fontSize: 28, showTranslation: true)
        XCTAssertGreaterThan(with.height, without.height)
    }

    func testHeightIsClamped() {
        let tiny = DesktopLyricsWindowController.panelSize(fontSize: 0, showTranslation: false)
        XCTAssertGreaterThanOrEqual(tiny.height, 140)
        let huge = DesktopLyricsWindowController.panelSize(fontSize: 500, showTranslation: true)
        XCTAssertLessThanOrEqual(huge.height, 440)
    }
}
