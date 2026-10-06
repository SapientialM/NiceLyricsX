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
//  - 设置统一由 AppSettingsStore 持有,并分发给菜单栏 / 桌面歌词窗口
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let settings = AppSettingsStore.shared
    private var statusItemController: MenuBarController!
    private var lyricsEngine: LyricsEngine!
    private var desktopWindowController: DesktopLyricsWindowController!
    private var notchWindowController: NotchLyricsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 确保是 accessory(LSUIElement 在 Info.plist 已经设了,这里兜底)
        NSApp.setActivationPolicy(.accessory)

        // 2. 构造播放器(优先 MediaRemote,失败 Apple Script fallback)
        let appleMusicPlayer = AppleMusicPlayer()
        let player: MusicPlayerProtocol = CompositeMusicPlayer(players: [appleMusicPlayer])

        // 3. 构造歌词引擎
        lyricsEngine = LyricsEngine(player: player)
        lyricsEngine.onTimeDelayChange = { newValue in
            AppSettings.timeDelay = newValue
        }
        lyricsEngine.timeDelay = AppSettings.timeDelay

        // 4. 启动引擎
        lyricsEngine.start()

        // 5. 桌面歌词窗口(先建,菜单栏的「重置位置」要引用它)
        desktopWindowController = DesktopLyricsWindowController(
            lyricsEngine: lyricsEngine,
            settings: settings
        )

        // 6. 菜单栏
        statusItemController = MenuBarController(
            lyricsEngine: lyricsEngine,
            settings: settings
        ) { [weak self] in
            self?.desktopWindowController?.resetPosition()
        }

        // 7. 刘海歌词(菜单栏下沿、水平居中于刘海;关闭时窗口不创建显示)
        notchWindowController = NotchLyricsWindowController(
            lyricsEngine: lyricsEngine,
            settings: settings
        )
        notchWindowController.start()

        // 8. 恢复桌面歌词窗口的启动状态。
        //    `desktopLyricsEnabled` 是「窗口当前是否显示」的真源,启动时由
        //    「启动时自动打开」决定 —— 否则第一次打开面板会看到开关是 ON、
        //    窗口却不在(用户点一下关、再点一下开才能看到窗口)。
        if settings.desktopLyricsAutoOpen {
            settings.desktopLyricsEnabled = true
            desktopWindowController.show()
        } else {
            settings.desktopLyricsEnabled = false
        }

        // 9. 检测 / 请求自动化权限(后台执行,不阻塞启动)
        requestAutomationPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lyricsEngine?.stop()
        statusItemController?.cleanup()
        desktopWindowController?.teardown()
        desktopWindowController?.close()
        notchWindowController?.teardown()
    }

    /// 检查 Apple Music 的自动化权限。
    ///
    /// 早先的实现是跑一段 `tell application "System Events" to count processes`
    /// 去"蹭"一个弹窗 —— 那个弹的是 System Events 的权限,不是 Music 的;
    /// 而且 `waitUntilExit()` 直接在启动路径上阻塞主线程。
    ///
    /// 现在改用 `AEDeterminePermissionToAutomateTarget`:没问过就弹 Music 的授权框,
    /// 已经决定过就直接拿到结果,且整个过程在后台队列。
    private func requestAutomationPermission() {
        Task {
            let status = await AutomationPermission.requestOffMain()
            FileHandle.standardError.write(
                Data("[NiceLyricsX] automation permission: \(status.displayText)\n".utf8)
            )
        }
    }
}
