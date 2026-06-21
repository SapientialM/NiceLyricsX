//
//  NSScreenHelperTests.swift
//  NiceLyricsXTests
//
//  NSScreen 工具方法的回归测试 —
//
//  锁住的不变式:`pointFromFactor` 必须:
//  1. 把越界 factor clamp 到 [0, 1] — 旧实现直接拿垃圾 factor 算,
//     会把窗口放飞到屏幕外
//  2. 在没有 screen 可用时返回 `(target: nil, point: .zero)` —
//     旧实现 force-unwrap `NSScreen.screens.first!` 在
//     `applicationDidFinishLaunching` 早期 / 无头环境下 EXC_BAD_ACCESS
//

import XCTest
import AppKit
@testable import NiceLyricsX

final class NSScreenHelperTests: XCTestCase {

    // MARK: - Clamp 越界 factor

    func testClampsFactorBelowZero() throws {
        // 用主屏当基准,这样不管测试机有几块屏,结果都稳定
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available")
        }
        let size = NSSize(width: 100, height: 50)
        let r1 = NSScreen.pointFromFactor(xFactor: -5, yFactor: -10, size: size, screen: screen)
        // clamp 到 0 → 屏幕左上角中心
        let expectedX = screen.frame.minX - size.width / 2
        let expectedY = screen.frame.minY - size.height / 2
        XCTAssertEqual(r1.point.x, expectedX, accuracy: 0.5)
        XCTAssertEqual(r1.point.y, expectedY, accuracy: 0.5)
        XCTAssertNotNil(r1.target)
    }

    func testClampsFactorAboveOne() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("No screen") }
        let size = NSSize(width: 100, height: 50)
        let r = NSScreen.pointFromFactor(xFactor: 99, yFactor: 99, size: size, screen: screen)
        // clamp 到 1 → 屏幕右下角中心
        let expectedX = screen.frame.maxX - size.width / 2
        let expectedY = screen.frame.maxY - size.height / 2
        XCTAssertEqual(r.point.x, expectedX, accuracy: 0.5)
        XCTAssertEqual(r.point.y, expectedY, accuracy: 0.5)
    }

    func testCenteredAtHalf() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("No screen") }
        let size = NSSize(width: 100, height: 50)
        let r = NSScreen.pointFromFactor(xFactor: 0.5, yFactor: 0.5, size: size, screen: screen)
        // factor 0.5 → 屏幕中心
        let expectedX = screen.frame.midX - size.width / 2
        let expectedY = screen.frame.midY - size.height / 2
        XCTAssertEqual(r.point.x, expectedX, accuracy: 0.5)
        XCTAssertEqual(r.point.y, expectedY, accuracy: 0.5)
    }

    // MARK: - 显式 screen 入参优先

    func testExplicitScreenWinsOverMain() throws {
        guard let main = NSScreen.main, NSScreen.screens.count >= 2,
              let other = NSScreen.screens.first(where: { $0 != main }) else {
            throw XCTSkip("Need at least two screens to test override")
        }
        let size = NSSize(width: 100, height: 50)
        // 显式传 other,即使 factor = 0.5 也会算在 other 屏的中心,
        // 不应该等于 main 屏中心
        let r = NSScreen.pointFromFactor(xFactor: 0.5, yFactor: 0.5, size: size, screen: other)
        XCTAssertEqual(r.target, other)
        // main 屏中心 ≠ other 屏中心(在多屏环境下)
        let mainCenterX = main.frame.midX - size.width / 2
        XCTAssertNotEqual(r.point.x, mainCenterX, accuracy: 1.0)
    }

    // MARK: - positionFactor 往返

    func testPositionFactorRoundTrip() throws {
        // point → factor → point 应该在原屏还原
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No screen") }
        let original = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        guard let factor = NSScreen.positionFactor(for: original) else {
            XCTFail("positionFactor should return non-nil for point on a screen")
            return
        }
        XCTAssertEqual(factor.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(factor.y, 0.5, accuracy: 0.01)
        XCTAssertEqual(factor.screen, screen)
    }

    func testPositionFactorOutOfBoundsReturnsNil() {
        // 远离所有屏幕的点
        let far = NSPoint(x: -999_999, y: -999_999)
        XCTAssertNil(NSScreen.positionFactor(for: far))
    }
}
