// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

@MainActor
final class VoiceLiveActivityTests: XCTestCase {

    func testSanitizedSubtitleCollapsesWhitespaceAndTruncatesTail() {
        XCTAssertEqual(
            VoiceLiveActivitySnapshot.sanitizedSubtitle("  第一行\n  第二行\t内容  "),
            "第一行 第二行 内容"
        )

        let longText = "一二三四五六七八九十甲乙丙丁戊己"
        let trimmed = VoiceLiveActivitySnapshot.sanitizedSubtitle(longText, maxLength: 8)
        XCTAssertEqual(trimmed.count, 8)
        XCTAssertTrue(trimmed.hasPrefix("…"))
        XCTAssertEqual(trimmed, "…十甲乙丙丁戊己")
    }

    func testSanitizedSubtitleStripsCommonMarkdownMarkers() {
        let markdownSample = """
        ### 核心能力
        > - **多模态交互**：支持 `Swift` 与 __语音__ 和 ~~旧语法~~
        * 温度约 -5℃，表达式 2 * 3，变量 foo_bar，语言 C#，标签 #话题
        5. **总结**
        ```swift
        """
        XCTAssertEqual(
            VoiceLiveActivitySnapshot.sanitizedSubtitle(markdownSample, maxLength: 200),
            "核心能力 多模态交互：支持 Swift 与 语音 和 旧语法 温度约 -5℃，表达式 2 * 3，变量 foo_bar，语言 C#，标签 #话题 5. 总结"
        )

        XCTAssertEqual(
            VoiceLiveActivitySnapshot.sanitizedSubtitle("```swift\n**\n> \n"),
            ""
        )
    }

    func testLifecycleCoordinatorSkipsQuiesceAndSuspendWhenKeepAliveEnabled() {
        let coordinator = LifecycleCoordinator()
        var enteredBackgroundHook = false
        var stoppedAdmissions = false
        var resumedAdmissions = false
        var quiesced = false
        var suspendedModel = false
        var keepAlive = true

        coordinator.shouldKeepAliveInBackground = { keepAlive }
        coordinator.onEnterBackground = { enteredBackgroundHook = true }
        coordinator.stopAdmittingActions = { stoppedAdmissions = true }
        coordinator.resumeAdmittingActions = { resumedAdmissions = true }
        coordinator.quiesce = { quiesced = true }
        coordinator.suspendModel = { suspendedModel = true }

        // 语音通话保活开启（无论本地还是云端模型）：切后台不挂断、不拒收、不卸载模型
        coordinator.updateSceneStates([.background])
        XCTAssertTrue(coordinator.isInBackground)
        XCTAssertEqual(coordinator.drainState, .idle)
        XCTAssertFalse(enteredBackgroundHook)
        XCTAssertFalse(stoppedAdmissions)
        XCTAssertFalse(quiesced)
        XCTAssertFalse(suspendedModel)

        // 用户在后台通过灵动岛挂断通话：触发延后后台收尾，关闭新请求并卸载闲置权重
        keepAlive = false
        coordinator.completeDeferredBackgroundDrainIfNeeded()
        XCTAssertEqual(coordinator.drainState, .draining)
        XCTAssertTrue(stoppedAdmissions)

        coordinator.updateSceneStates([.foregroundActive])
        XCTAssertFalse(coordinator.isInBackground)
        XCTAssertTrue(resumedAdmissions)

        // 普通聊天（非语音通话）：切后台正常走防打扰与资源冻结序列
        keepAlive = false
        coordinator.updateSceneStates([.background])
        XCTAssertTrue(coordinator.isInBackground)
        XCTAssertEqual(coordinator.drainState, .draining)
        XCTAssertTrue(enteredBackgroundHook)
        XCTAssertTrue(stoppedAdmissions)
    }

    func testEnterBackgroundReenteringCompleteDeferredDrainDoesNotDoubleLease() {
        let provider = ReentryDrainProviderFixture()
        let coordinator = LifecycleCoordinator(drainProvider: provider)
        var stopCount = 0

        coordinator.shouldKeepAliveInBackground = { false }
        coordinator.stopAdmittingActions = { stopCount += 1 }
        coordinator.onEnterBackground = {
            coordinator.completeDeferredBackgroundDrainIfNeeded()
        }

        coordinator.updateSceneStates([.background])

        XCTAssertEqual(provider.beginCount, 1)
        XCTAssertEqual(coordinator.quiesceIssueCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(coordinator.drainState, .draining)
    }
}

@MainActor
private final class ReentryDrainTokenFixture: BackgroundDrainToken {
    let isExpired = false
    func end() {}
}

@MainActor
private final class ReentryDrainProviderFixture: BackgroundDrainProviding {
    private(set) var beginCount = 0
    func beginDrain(named name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> any BackgroundDrainToken {
        beginCount += 1
        return ReentryDrainTokenFixture()
    }
}
