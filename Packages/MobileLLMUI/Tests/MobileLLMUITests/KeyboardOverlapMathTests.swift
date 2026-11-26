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
}
