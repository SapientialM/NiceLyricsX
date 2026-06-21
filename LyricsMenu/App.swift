//
//  App.swift
//  NiceLyricsX
//
//  应用入口 —— 配置 NSApplication 为 accessory app(无 Dock 图标),
//  创建菜单栏 status item 和桌面歌词窗口。
//
//  设计要点(参考 LyricsX AppDelegate):
//  - 用 NSApplicationDelegateAdaptor 注入 AppDelegate
//  - LSUIElement 在 Info.plist 里设 true → 无 Dock 图标
//  - 启动后由 AppDelegate 启动 LyricsEngine + DesktopLyricsWindow
//

import SwiftUI
import AppKit

@main
struct NiceLyricsXApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 不需要 WindowGroup —— 我们用 AppKit 风格的 status item + 自定义 NSWindow
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItemController: MenuBarController!
    private var lyricsEngine: LyricsEngine!
    private var desktopWindowController: DesktopLyricsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 确保是 accessory(LSUIElement 在 Info.plist 已经设了,这里兜底)
        NSApp.setActivationPolicy(.accessory)

        // 2. 构造播放器(优先 MediaRemote,失败 Apple Script fallback)
        let appleMusicPlayer = AppleMusicPlayer()
        let player: MusicPlayerProtocol = CompositeMusicPlayer(players: [appleMusicPlayer])

        // 3. 构造歌词引擎
        lyricsEngine = LyricsEngine(player: player)
        lyricsEngine.timeDelay = AppSettings.timeDelay
        lyricsEngine.onTimeDelayChange = { newValue in
            AppSettings.timeDelay = newValue
        }

        // 4. 启动引擎
        lyricsEngine.start()

        // 5. 菜单栏
        statusItemController = MenuBarController(lyricsEngine: lyricsEngine)

        // 6. 桌面歌词窗口
        desktopWindowController = DesktopLyricsWindowController(lyricsEngine: lyricsEngine)
        if AppSettings.desktopLyricsAutoOpen {
            desktopWindowController.show()
        }

        // 7. 检测权限
        requestAutomationPermissionIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lyricsEngine?.stop()
        statusItemController?.cleanup()
        desktopWindowController?.close()
    }

    /// 检查 AppleScript / Automation 权限。
    /// macOS 13+ 需要 TCC 授权才能用 osascript 读 Apple Music。
    private func requestAutomationPermissionIfNeeded() {
        // 用一行无害脚本触发系统授权弹窗
        let script = "tell application \"System Events\" to count processes"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // ignore
        }
    }
}