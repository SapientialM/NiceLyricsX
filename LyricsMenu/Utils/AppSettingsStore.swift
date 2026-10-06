//
//  AppSettingsStore.swift
//  NiceLyricsX
//
//  应用设置的唯一真源(single source of truth)。
//
//  背景:
//  早期版本把设置散落在 `AppSettings`(UserDefaults 静态访问)+ NotificationCenter
//  广播里。UI 读到的值和实际生效的值之间没有可靠的更新路径 —— 例如字号 / 不透明度
//  改了之后 SwiftUI 不会重绘,桌面歌词窗口大小也不会跟着变。
//
//  这个 store 把"持久化"和"观察"两件事绑在一起:
//  - 每个 `@Published` 属性在 `didSet` 里写回 `AppSettings`(UserDefaults)
//  - 任何持有 store 的 SwiftUI 视图 / Combine 订阅者都会自动收到变更
//  - `LyricsEngine.timeDelay` 不在这个 store 里 —— 它的真源是引擎本身,
//    引擎通过 `onTimeDelayChange` 回写持久化,避免两个真源打架
//

import Foundation
import Combine

@MainActor
public final class AppSettingsStore: ObservableObject {

    /// 全局单例。AppDelegate 在启动时构造 UIKit 之前就会用到它。
    public static let shared = AppSettingsStore()

    // MARK: - 桌面歌词

    @Published public var desktopLyricsEnabled: Bool {
        didSet { AppSettings.desktopLyricsEnabled = desktopLyricsEnabled }
    }

    @Published public var desktopLyricsAutoOpen: Bool {
        didSet { AppSettings.desktopLyricsAutoOpen = desktopLyricsAutoOpen }
    }

    @Published public var clickThrough: Bool {
        didSet { AppSettings.clickThrough = clickThrough }
    }

    @Published public var showTranslation: Bool {
        didSet { AppSettings.showTranslation = showTranslation }
    }

    @Published public var fontSize: Double {
        didSet {
            let clamped = fontSize.clamped(to: AppSettings.desktopLyricsFontSizeRange)
            if clamped != fontSize {
                fontSize = clamped       // didSet 不会被重入触发
            }
            AppSettings.desktopLyricsFontSize = clamped
        }
    }

    @Published public var opacity: Double {
        didSet {
            let clamped = opacity.clamped(to: AppSettings.desktopLyricsOpacityRange)
            if clamped != opacity {
                opacity = clamped
            }
            AppSettings.desktopLyricsOpacity = clamped
        }
    }

    // MARK: - 菜单栏

    /// 菜单栏图标旁边是否显示当前歌词文本。
    @Published public var menubarLyricsEnabled: Bool {
        didSet { AppSettings.menubarLyricsEnabled = menubarLyricsEnabled }
    }

    // MARK: - 刘海歌词

    /// 刘海歌词显示模式:关闭 / 切歌时出现 / 常驻。
    @Published public var notchLyricsMode: NotchLyricsMode {
        didSet { AppSettings.notchLyricsMode = notchLyricsMode }
    }

    // MARK: - 登录时启动

    /// 是否已注册为登录项。真源是 `SMAppService`,不是 UserDefaults。
    @Published public private(set) var launchAtLogin: Bool

    /// 最近一次注册 / 注销登录项失败的原因(供 UI 展示)。
    @Published public private(set) var launchAtLoginError: String?

    // MARK: - Init

    private init() {
        desktopLyricsEnabled = AppSettings.desktopLyricsEnabled
        desktopLyricsAutoOpen = AppSettings.desktopLyricsAutoOpen
        clickThrough = AppSettings.clickThrough
        showTranslation = AppSettings.showTranslation
        fontSize = AppSettings.desktopLyricsFontSize
        opacity = AppSettings.desktopLyricsOpacity
        menubarLyricsEnabled = AppSettings.menubarLyricsEnabled
        notchLyricsMode = AppSettings.notchLyricsMode
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    // MARK: - Actions

    /// 尝试把登录项状态切到 `enabled`。失败时回滚到系统真实状态并记录原因
    /// (从 Xcode DerivedData 直接跑、或未签名时注册会失败)。
    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLogin = LaunchAtLogin.isEnabled
            launchAtLoginError = nil
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchAtLoginError = error.localizedDescription
            FileHandle.standardError.write(
                Data("[AppSettingsStore] launch at login failed: \(error)\n".utf8)
            )
        }
    }
}
