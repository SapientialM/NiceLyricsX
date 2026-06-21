//
//  UserDefaults+Extension.swift
//  NiceLyricsX
//
//  类型安全的 UserDefaults 键集中管理。
//  借鉴 LyricsX 的 `@UserDefault` propertyWrapper(但用更简洁的静态 key + 扩展方法)。
//

import Foundation
import AppKit

public enum AppDefaultsKey: String {
    /// 全局歌词偏移(秒),范围 -10 ~ 10。
    case lyricsTimeDelay = "lyrics.timeDelay"

    /// 桌面歌词窗口是否启用。
    case desktopLyricsEnabled = "desktopLyrics.enabled"

    /// 桌面歌词 X 位置因子 [0, 1]。
    case desktopLyricsXFactor = "desktopLyrics.xFactor"

    /// 桌面歌词 Y 位置因子 [0, 1]。
    case desktopLyricsYFactor = "desktopLyrics.yFactor"

    /// 桌面歌词字体大小。
    case desktopLyricsFontSize = "desktopLyrics.fontSize"

    /// 桌面歌词不透明度 [0, 1]。
    case desktopLyricsOpacity = "desktopLyrics.opacity"

    /// 菜单栏下拉菜单是否启用。
    case menubarLyricsEnabled = "menubarLyrics.enabled"

    /// 是否启动时自动打开桌面歌词。
    case desktopLyricsAutoOpen = "desktopLyrics.autoOpen"

    /// 是否启用鼠标穿透(歌词窗口不接收事件)。
    case desktopLyricsClickThrough = "desktopLyrics.clickThrough"
}

extension UserDefaults {

    /// 通用 get / set 辅助,避免散落 `.double(forKey:)` 等。
    public func set<T>(_ value: T, for key: AppDefaultsKey) {
        set(value, forKey: key.rawValue)
    }

    public func double(for key: AppDefaultsKey, default fallback: Double = 0) -> Double {
        if object(forKey: key.rawValue) == nil { return fallback }
        return double(forKey: key.rawValue)
    }

    public func bool(for key: AppDefaultsKey, default fallback: Bool = false) -> Bool {
        if object(forKey: key.rawValue) == nil { return fallback }
        return bool(forKey: key.rawValue)
    }

    public func int(for key: AppDefaultsKey, default fallback: Int = 0) -> Int {
        if object(forKey: key.rawValue) == nil { return fallback }
        return integer(forKey: key.rawValue)
    }

    public func string(for key: AppDefaultsKey) -> String? {
        return string(forKey: key.rawValue)
    }
}

// MARK: - 业务便捷访问

public enum AppSettings {

    public static var timeDelay: TimeInterval {
        get {
            UserDefaults.standard.double(for: .lyricsTimeDelay)
        }
        set {
            let clamped = max(-10, min(10, newValue))
            UserDefaults.standard.set(clamped, for: .lyricsTimeDelay)
        }
    }

    public static var desktopLyricsEnabled: Bool {
        get { UserDefaults.standard.bool(for: .desktopLyricsEnabled, default: true) }
        set { UserDefaults.standard.set(newValue, for: .desktopLyricsEnabled) }
    }

    public static var desktopLyricsAutoOpen: Bool {
        get { UserDefaults.standard.bool(for: .desktopLyricsAutoOpen, default: false) }
        set { UserDefaults.standard.set(newValue, for: .desktopLyricsAutoOpen) }
    }

    public static var clickThrough: Bool {
        get { UserDefaults.standard.bool(for: .desktopLyricsClickThrough, default: false) }
        set { UserDefaults.standard.set(newValue, for: .desktopLyricsClickThrough) }
    }

    public static var menubarLyricsEnabled: Bool {
        get { UserDefaults.standard.bool(for: .menubarLyricsEnabled, default: true) }
        set { UserDefaults.standard.set(newValue, for: .menubarLyricsEnabled) }
    }

    public static var desktopLyricsXFactor: Double {
        get { UserDefaults.standard.double(for: .desktopLyricsXFactor, default: 0.5) }
        set { UserDefaults.standard.set(newValue, for: .desktopLyricsXFactor) }
    }

    public static var desktopLyricsYFactor: Double {
        get { UserDefaults.standard.double(for: .desktopLyricsYFactor, default: 0.85) }
        set { UserDefaults.standard.set(newValue, for: .desktopLyricsYFactor) }
    }

    public static var desktopLyricsFontSize: Double {
        get { UserDefaults.standard.double(for: .desktopLyricsFontSize, default: 28) }
        set { UserDefaults.standard.set(newValue, for: .desktopLyricsFontSize) }
    }

    public static var desktopLyricsOpacity: Double {
        get { UserDefaults.standard.double(for: .desktopLyricsOpacity, default: 0.85) }
        set { UserDefaults.standard.set(newValue, for: .desktopLyricsOpacity) }
    }
}

// MARK: - 屏幕坐标 → 位置因子

extension NSScreen {

    /// 给定窗口 frame,在所有屏幕中找出包含它的屏幕,并返回 [0,1] 比例因子。
    public static func positionFactor(for point: NSPoint) -> (x: Double, y: Double, screen: NSScreen)? {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                let x = Double((point.x - screen.frame.minX) / screen.frame.width)
                let y = Double((point.y - screen.frame.minY) / screen.frame.height)
                return (x.clamped(to: 0...1), y.clamped(to: 0...1), screen)
            }
        }
        return nil
    }

    /// 把比例因子 + 窗口尺寸还原到屏幕坐标,支持主屏/外接屏。
    public static func pointFromFactor(
        xFactor: Double, yFactor: Double,
        size: NSSize, screen: NSScreen? = nil
    ) -> NSPoint {
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first!
        let x = target.frame.minX + target.frame.width * CGFloat(xFactor) - size.width / 2
        let y = target.frame.minY + target.frame.height * CGFloat(yFactor) - size.height / 2
        return NSPoint(x: x, y: y)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}