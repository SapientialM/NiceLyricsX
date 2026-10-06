//
//  NotchGeometryTests.swift
//  NiceLyricsXTests
//
//  刘海几何测试 —— 纯数值,不依赖真实屏幕。
//
//  样本取自一台真实 MacBook 内建屏:
//  1470×956,两翼各 645.5,safeAreaInsets.top = 32,visibleFrame 高 863(y=60)
//  ⇒ 刘海 183×32,菜单栏高 33。
//

import XCTest
@testable import NiceLyricsX

final class NotchGeometryTests: XCTestCase {

    /// 真实带刘海屏的样本值。
    private func makeNotched() -> NotchGeometry {
        NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: CGRect(x: 0, y: 60, width: 1470, height: 863),
            safeAreaTop: 32,
            leftWingWidth: 645.5,
            rightWingWidth: 645.5
        )
    }

    /// 外接显示器 / 老 Mac:没有刘海。
    private func makePlain() -> NotchGeometry {
        NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
            safeAreaTop: 0,
            leftWingWidth: nil,
            rightWingWidth: nil
        )
    }

    // MARK: 刘海识别

    func testDetectsPhysicalNotch() {
        XCTAssertTrue(makeNotched().hasPhysicalNotch)
        XCTAssertFalse(makePlain().hasPhysicalNotch)
    }

    /// 两翼存在但 safeAreaInsets.top 为 0 → 不算刘海(某些外接屏会给出翼但没凹口)。
    func testWingsWithoutSafeAreaIsNotANotch() {
        let geometry = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: CGRect(x: 0, y: 60, width: 1470, height: 863),
            safeAreaTop: 0,
            leftWingWidth: 645.5,
            rightWingWidth: 645.5
        )
        XCTAssertFalse(geometry.hasPhysicalNotch)
    }

    // MARK: 尺寸

    func testNotchWidthFromWings() {
        // 1470 − 645.5 − 645.5 + 4 = 183
        XCTAssertEqual(makeNotched().notchWidth, 183, accuracy: 0.001)
    }

    func testNotchHeightUsesSafeArea() {
        XCTAssertEqual(makeNotched().notchHeight, 32, accuracy: 0.001)
    }

    func testMenuBarHeight() {
        // frame.maxY 956 − visibleFrame.maxY 923 = 33
        XCTAssertEqual(makeNotched().menuBarHeight, 33, accuracy: 0.001)
        XCTAssertEqual(makePlain().menuBarHeight, 25, accuracy: 0.001)
    }

    func testNotchRectIsTopCentered() {
        let rect = makeNotched().notchRect
        XCTAssertEqual(rect.midX, 735, accuracy: 0.001)          // 屏幕中线
        XCTAssertEqual(rect.maxY, 956, accuracy: 0.001)          // 贴住屏幕顶
        XCTAssertEqual(rect.width, 183, accuracy: 0.001)
        XCTAssertEqual(rect.height, 32, accuracy: 0.001)
    }

    // MARK: 无刘海退化成虚拟岛

    func testPseudoIslandWhenNoNotch() {
        let geometry = makePlain()
        XCTAssertEqual(geometry.notchWidth, NotchGeometry.pseudoNotchWidth)
        XCTAssertEqual(geometry.notchHeight, geometry.menuBarHeight, accuracy: 0.001)
        XCTAssertEqual(geometry.notchRect.midX, 960, accuracy: 0.001)
    }

    // MARK: 歌词条位置

    func testBarFrameSitsRightBelowMenuBarAndCenteredOnNotch() {
        let geometry = makeNotched()
        let frame = geometry.barFrame(width: 560, height: 52)
        XCTAssertEqual(frame.midX, geometry.notchRect.midX, accuracy: 0.001, "要和刘海同轴")
        XCTAssertEqual(frame.maxY, 923, accuracy: 0.001, "上沿贴菜单栏下沿")
        XCTAssertEqual(frame.width, 560, accuracy: 0.001)
        XCTAssertEqual(frame.height, 52, accuracy: 0.001)
    }

    func testBarFrameRespectsGap() {
        let geometry = makeNotched()
        let frame = geometry.barFrame(width: 560, height: 52, gap: 8)
        XCTAssertEqual(frame.maxY, 923 - 8, accuracy: 0.001)
    }

    func testBarWidthIsWiderThanNotchButClampedToScreen() {
        let geometry = makeNotched()
        let width = geometry.barWidth()
        XCTAssertGreaterThan(width, geometry.notchWidth, "要留出放文字的空间")
        XCTAssertLessThanOrEqual(width, geometry.screenFrame.width - 120)

        // 超宽屏也不会溢出
        let huge = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 775),
            safeAreaTop: 32,
            leftWingWidth: 100,
            rightWingWidth: 100
        )
        XCTAssertLessThanOrEqual(huge.barWidth(), 1000)
    }

    // MARK: 悬停热区

    func testHoverRegionCoversNotchAndBar() {
        let geometry = makeNotched()
        let barWidth = geometry.barWidth()
        let region = geometry.hoverRegion(width: barWidth, height: 52)

        XCTAssertTrue(region.contains(CGPoint(x: geometry.notchRect.midX, y: geometry.notchRect.midY)),
                      "刘海正中间要在热区里")
        let bar = geometry.barFrame(width: barWidth, height: 52)
        XCTAssertTrue(region.contains(CGPoint(x: bar.midX, y: bar.midY)), "歌词条中间要在热区里")
        XCTAssertTrue(region.contains(CGPoint(x: bar.midX, y: bar.maxY + 2)), "两者之间的缝也要算进去")
    }

    func testHoverRegionExcludesFarAwayPoints() {
        let geometry = makeNotched()
        let region = geometry.hoverRegion(width: geometry.barWidth(), height: 52)
        XCTAssertFalse(region.contains(CGPoint(x: 10, y: 10)), "屏幕左下角不该命中")
        XCTAssertFalse(region.contains(CGPoint(x: geometry.screenFrame.midX, y: 400)), "屏幕中部不该命中")
    }
}

// MARK: - 模式

final class NotchLyricsModeTests: XCTestCase {

    func testAllCasesHaveDisplayNames() {
        XCTAssertEqual(NotchLyricsMode.allCases.count, 3)
        for mode in NotchLyricsMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }

    func testRawValuesRoundTrip() {
        for mode in NotchLyricsMode.allCases {
            XCTAssertEqual(NotchLyricsMode(rawValue: mode.rawValue), mode)
        }
        XCTAssertNil(NotchLyricsMode(rawValue: "nonsense"))
    }
}
