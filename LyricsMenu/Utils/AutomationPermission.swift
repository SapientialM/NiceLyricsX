//
//  AutomationPermission.swift
//  NiceLyricsX
//
//  自动化(Apple Events / TCC)权限检测 —— 判断本 App 是否有权控制 Apple Music。
//
//  为什么不用「跑一段 osascript 看它报不报错」:
//  - 那会真的去 `tell application "Music"`,Music 没开时反而会把它拉起来
//  - 报错信息是一坨 stderr 字符串,区分不了「用户拒绝」和「Music 没开」
//
//  `AEDeterminePermissionToAutomateTarget` 是 Apple 官方的查询接口:
//  - `askUserIfNeeded: false` → 只查询当前状态,不弹窗
//  - `askUserIfNeeded: true`  → 未决定时弹出系统授权框(和第一次跑
//    AppleScript 时弹的是同一个 TCC 授权)
//
//  注意这个调用可能阻塞等待用户点击,所以必须在非主线程调用(`requestOffMain`)。
//

import Foundation
import AppKit
import Carbon

public enum AutomationPermission {

    public enum Status: Sendable, Equatable {
        /// 已经授权。
        case granted
        /// 用户明确拒绝过,需要去系统设置里手动打开。
        case denied
        /// 还没问过用户(或目标 App 当前没运行,系统无法询问)。
        case notDetermined
        /// 其它 OSStatus。
        case unknown(OSStatus)

        public var isGranted: Bool { self == .granted }

        /// 需要给用户一条「去系统设置开权限」的提示吗。
        public var needsAttention: Bool { self == .denied }

        public var displayText: String {
            switch self {
            case .granted: return "已授权控制 Apple Music"
            case .denied: return "已被拒绝控制 Apple Music"
            case .notDetermined: return "尚未授权控制 Apple Music"
            case .unknown(let code): return "权限状态未知(\(code))"
            }
        }
    }

    /// Apple Music 的 bundle id(macOS 10.15+ 用这个,iTunes 已并入 Music)。
    public static let musicBundleID = "com.apple.Music"

    // MARK: - 查询

    /// 只查询当前状态,不弹窗。可在主线程调用(开销很小)。
    public static func status(forBundleID bundleID: String = musicBundleID) -> Status {
        map(determine(bundleID: bundleID, askUserIfNeeded: false))
    }

    /// 请求权限 —— 未决定时会弹系统授权框,**可能长时间阻塞**,请在后台调用。
    @discardableResult
    public static func request(forBundleID bundleID: String = musicBundleID) -> Status {
        map(determine(bundleID: bundleID, askUserIfNeeded: true))
    }

    /// 后台请求权限,返回最终状态(自动回到调用方的 actor)。
    public static func requestOffMain(forBundleID bundleID: String = musicBundleID) async -> Status {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: request(forBundleID: bundleID))
            }
        }
    }

    /// 打开「系统设置 → 隐私与安全性 → 自动化」。
    @MainActor
    public static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Internal

    private static func determine(bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else {
            return OSStatus(errAEEventNotPermitted)
        }
        return AEDeterminePermissionToAutomateTarget(
            target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
    }

    private static func map(_ status: OSStatus) -> Status {
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        case OSStatus(procNotFound):
            // 目标 App 没运行 → 系统没法问用户,等同于「还没决定」
            return .notDetermined
        default:
            return .unknown(status)
        }
    }
}
