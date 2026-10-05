//
//  LaunchAtLogin.swift
//  NiceLyricsX
//
//  登录时启动 —— 用 macOS 13+ 的 `SMAppService.mainApp` 注册「登录项」。
//
//  为什么不用老的 `LSSharedFileList` / `SMLoginItemSetEnabled`:
//  - `LSSharedFileList` 在 macOS 13 起被废弃,且需要沙盒 helper bundle
//  - `SMLoginItemSetEnabled` 要求 app 内嵌一个 helper target
//  - `SMAppService.mainApp` 直接把当前 app 注册成登录项,零额外 bundle
//
//  注意事项:
//  - 必须是有签名的 .app(ad-hoc 从 DerivedData 直接跑时 `register()` 会抛错)。
//    调用方(`AppSettingsStore`)会 catch 并把错误反馈到 UI,不会崩。
//  - 状态真源永远是系统,不是 UserDefaults —— 用户可能在「系统设置 →
//    通用 → 登录项」里手动关掉。
//

import Foundation
import ServiceManagement

public enum LaunchAtLogin {

    /// 当前 app 是否已被系统登记为登录项。
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 系统里记录的登录项状态(用于错误提示 / 诊断)。
    public static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已启用"
        case .notRegistered: return "未注册"
        case .notFound: return "未找到"
        case .requiresApproval: return "等待用户在系统设置中批准"
        @unknown default: return "未知"
        }
    }

    /// 注册 / 注销登录项。幂等:已经是目标状态时直接返回。
    public static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }
}
