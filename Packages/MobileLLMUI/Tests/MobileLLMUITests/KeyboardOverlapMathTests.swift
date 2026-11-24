// SPDX-License-Identifier: MIT

import CoreGraphics
import XCTest
@testable import MobileLLMUI

final class KeyboardOverlapMathTests: XCTestCase {

    func testNetLiftSubtractsRestingHomeIndicatorAndClampsAtZero() {
        let windowBounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let restingInset: CGFloat = 34

        // Keyboard off-screen below window -> 0.
        let hiddenFrame = CGRect(x: 0, y: 852, width: 393, height: 336)
        XCTAssertEqual(
            KeyboardOverlapMath.netLift(
                windowBounds: windowBounds,
                keyboardFrameInWindow: hiddenFrame,
                restingBottomInset: restingInset,
                isHiding: false
            ),
            0,
            accuracy: 0.01
        )

        // Resting bottom safe area height (`34pt` tracker height) -> net lift 0.
        let restingTrackerFrame = CGRect(x: 0, y: 818, width: 393, height: 34)
        XCTAssertEqual(
            KeyboardOverlapMath.netLift(
                windowBounds: windowBounds,
                keyboardFrameInWindow: restingTrackerFrame,
                restingBottomInset: restingInset,
                isHiding: false
            ),
            0,
            accuracy: 0.01
        )

        // Docked software keyboard (`336pt` from window bottom) -> 336 - 34 = 302.
        let dockedKeyboard = CGRect(x: 0, y: 516, width: 393, height: 336)
        XCTAssertEqual(
            KeyboardOverlapMath.netLift(
                windowBounds: windowBounds,
                keyboardFrameInWindow: dockedKeyboard,
                restingBottomInset: restingInset,
                isHiding: false
            ),
            302,
            accuracy: 0.01
        )

        // iOS 26 slightly inset keyboard frame -> still anchors lift from intersection.minY to window maxY.
        let insetKeyboard = CGRect(x: 8, y: 520, width: 377, height: 324)
        XCTAssertEqual(
            KeyboardOverlapMath.netLift(
                windowBounds: windowBounds,
                keyboardFrameInWindow: insetKeyboard,
                restingBottomInset: restingInset,
                isHiding: false
            ),
            (852 - 520) - 34,
            accuracy: 0.01
        )

        // Explicit hide notification forces 0 regardless of reported end frame.
        XCTAssertEqual(
            KeyboardOverlapMath.netLift(
                windowBounds: windowBounds,
                keyboardFrameInWindow: dockedKeyboard,
                restingBottomInset: restingInset,
                isHiding: true
            ),
            0,
            accuracy: 0.01
        )
    }

    func testResolvedLiftFallsBackToNotificationWhenKeyboardLayoutGuideStalls() {
        // When keyboardLayoutGuide stalls at 0 (never responded for current keyboard), notification supplies full lift.
        XCTAssertEqual(
            KeyboardOverlapMath.resolvedLift(
                guideLift: 0,
                guideActiveForCurrentKeyboard: false,
                notificationState: .visible(302)
            ),
            302,
            accuracy: 0.01
        )

        // Active layout guide tracks interactive drag-down / height shrink smoothly below stale notifLift.
        XCTAssertEqual(
            KeyboardOverlapMath.resolvedLift(
                guideLift: 180,
                guideActiveForCurrentKeyboard: true,
                notificationState: .visible(302)
            ),
            180,
            accuracy: 0.01
        )

        // Interactive drag-down reaching 0 before willHide fires stays at 0 (does NOT teleport back to notifLift).
        XCTAssertEqual(
            KeyboardOverlapMath.resolvedLift(
                guideLift: 0,
                guideActiveForCurrentKeyboard: true,
                notificationState: .visible(302)
            ),
            0,
            accuracy: 0.01
        )

        // Shrinking keyboard notification updates lift down cleanly when stale guideLift was cleared.
        XCTAssertEqual(
            KeyboardOverlapMath.resolvedLift(
                guideLift: 0,
                guideActiveForCurrentKeyboard: false,
                notificationState: .visible(256)
            ),
            256,
            accuracy: 0.01
        )

        // Hidden state overrides even a stale positive guideLift.
        XCTAssertEqual(
            KeyboardOverlapMath.resolvedLift(
                guideLift: 302,
                guideActiveForCurrentKeyboard: true,
                notificationState: .hidden
            ),
            0,
            accuracy: 0.01
        )

        // Unknown notification state falls back to layout guide measurement.
        XCTAssertEqual(
            KeyboardOverlapMath.resolvedLift(
                guideLift: 260,
                guideActiveForCurrentKeyboard: true,
                notificationState: .unknown
            ),
            260,
            accuracy: 0.01
        )
    }
}
