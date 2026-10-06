//
//  NotchGeometry.swift
//  NiceLyricsX
//
//  MacBook 刘海几何 —— **全部基于公开 API**,不碰任何私有 framework。
//
//  三个关键属性:
//  - `NSScreen.safeAreaInsets.top` —— 大于 0 就说明这块屏有物理刘海,
//    值就是刘海高度(pt)
//  - `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` —— 刘海左右
//    两侧那两条"翼"(其实就是菜单栏可用区)。刘海宽度 =
//    屏宽 − 左翼宽 − 右翼宽,再加一点点让它和物理刘海严丝合缝
//  - 菜单栏高度 = `frame.maxY − visibleFrame.maxY`
//
//  没有刘海的机器(外接显示器 / 老 Mac)也能用:用一个 `pseudoNotchWidth`
//  的虚拟岛,位置同样在顶部居中。
//
//  参考实现思路来自开源项目 Boring Notch(GPL-3.0)—— 这里只使用了它同样
//  使用的**公开 API 事实**,没有复制任何代码,所以 NiceLyricsX 保持 MIT。
//

import AppKit

// MARK: - 刘海歌词的显示模式

/// 刘海歌词的三档模式。
public enum NotchLyricsMode: String, CaseIterable, Sendable, Identifiable {
    /// 不显示。
    case off
    /// 切歌时从刘海下方冒出来,几秒后自动收起;鼠标移到刘海可手动展开。
    case peek
    /// 常驻。
    case always

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .peek: return "切歌时出现"
        case .always: return "常驻"
        }
    }
}

// MARK: - 几何

/// 一块屏幕上的刘海几何。
public struct NotchGeometry: Equatable, Sendable {

    public let screenFrame: CGRect
    public let visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`
    public let safeAreaTop: CGFloat
    public let leftWingWidth: CGFloat?
    public let rightWingWidth: CGFloat?

    /// 没有物理刘海时,虚拟岛的宽度(取常见 MacBook 刘海的宽度)。
    public static let pseudoNotchWidth: CGFloat = 183

    public init(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        leftWingWidth: CGFloat?,
        rightWingWidth: CGFloat?
    ) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.leftWingWidth = leftWingWidth
        self.rightWingWidth = rightWingWidth
    }

    /// 当前是否有物理刘海。
    public var hasPhysicalNotch: Bool {
        guard let leftWingWidth, let rightWingWidth else { return false }
        return safeAreaTop > 0 && leftWingWidth > 0 && rightWingWidth > 0
    }

    /// 菜单栏高度。
    public var menuBarHeight: CGFloat {
        max(0, screenFrame.maxY - visibleFrame.maxY)
    }

    /// 刘海宽度。没有物理刘海时退化成虚拟岛宽度。
    public var notchWidth: CGFloat {
        guard hasPhysicalNotch, let leftWingWidth, let rightWingWidth else {
            return Self.pseudoNotchWidth
        }
        return screenFrame.width - leftWingWidth - rightWingWidth + 4
    }

    /// 刘海高度。没有物理刘海时取菜单栏高度。
    public var notchHeight: CGFloat {
        hasPhysicalNotch ? safeAreaTop : menuBarHeight
    }

    /// 物理刘海在屏幕坐标系里的矩形(Cocoa 坐标,原点左下)。
    public var notchRect: CGRect {
        CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
    }

    /// 菜单栏下沿的 y。
    public var menuBarBottomY: CGFloat {
        screenFrame.maxY - menuBarHeight
    }

    /// 歌词条要占的矩形 —— 顶部贴着菜单栏下沿,水平居中于刘海。
    public func barFrame(width: CGFloat, height: CGFloat, gap: CGFloat = 0) -> CGRect {
        CGRect(
            x: screenFrame.midX - width / 2,
            y: menuBarBottomY - gap - height,
            width: width,
            height: height
        )
    }

    /// 歌词条宽度:比刘海宽出一截(左右各留出放文字的空间),
    /// 但不超过屏幕宽度减去安全边距。
    public func barWidth(minimum: CGFloat = 520, extraPerSide: CGFloat = 190) -> CGFloat {
        let ideal = max(notchWidth + extraPerSide * 2, minimum)
        return min(ideal, screenFrame.width - 120)
    }

    /// 悬停热区:刘海本体 + 歌词条,再往外扩一圈容错。
    public func hoverRegion(barWidth: CGFloat, barHeight: CGFloat, padding: CGFloat = 6) -> CGRect {
        notchRect.union(barFrame(width: barWidth, height: barHeight))
            .insetBy(dx: -padding, dy: -padding)
    }

    // MARK: 从 NSScreen 取

    /// 读取某块屏幕的刘海几何。传 nil 时用「有刘海的那块屏」,再退回主屏。
    @MainActor
    public static func current(preferring screen: NSScreen? = nil) -> NotchGeometry? {
        let target = screen ?? notchedScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else { return nil }
        return NotchGeometry(
            screenFrame: target.frame,
            visibleFrame: target.visibleFrame,
            safeAreaTop: target.safeAreaInsets.top,
            leftWingWidth: target.auxiliaryTopLeftArea?.width,
            rightWingWidth: target.auxiliaryTopRightArea?.width
        )
    }

    /// 找出带物理刘海的那块屏(通常是内建屏)。
    @MainActor
    public static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
    }
}
