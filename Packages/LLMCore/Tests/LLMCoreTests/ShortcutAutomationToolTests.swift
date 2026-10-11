// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

actor FakeShortcutAutomationExecutor: ShortcutAutomationExecuting {
    var lastAction: String?
    var lastShortcut: String?
    var lastParams: String?
    var lastTaskId: String?
    var lastTimeoutSeconds: Int?

    var resultToReturn: String = #"{"success":true,"status":"completed","result":"Done"}"#
    var errorToThrow: Error?

    func executeTask(
        action: String,
        shortcut: String?,
        params: String?,
        taskId: String?,
        timeoutSeconds: Int
    ) async throws -> String {
        lastAction = action
        lastShortcut = shortcut
        lastParams = params
        lastTaskId = taskId
        lastTimeoutSeconds = timeoutSeconds

        if let errorToThrow {
            throw errorToThrow
        }
        return resultToReturn
    }

    func permissionState() async -> ToolPermission { .granted }
    func requestPermission() async -> ToolPermission { .granted }
}

final class ShortcutAutomationToolTests: XCTestCase {

    func testSchemaProperties() {
        let schema = ShortcutAutomationTool.schema
        XCTAssertEqual(schema.name, "shortcut_automation_tool")
        XCTAssertTrue(schema.description.contains("Shortcut Automation"))
        let paramNames = schema.parameters.map(\.name)
        XCTAssertTrue(paramNames.contains("action"))
        XCTAssertTrue(paramNames.contains("shortcut"))
        XCTAssertTrue(paramNames.contains("taskId"))
        XCTAssertTrue(paramNames.contains("params"))
        XCTAssertTrue(paramNames.contains("timeout"))
    }

    func testMissingExecutor() async {
        let tool = ShortcutAutomationTool(executor: nil)
        let out = await tool.execute(argumentsJSON: #"{"action":"list"}"#)
        XCTAssertTrue(out.contains("Error: Shortcut automation is not available"), out)
    }

    func testMissingAction() async {
        let executor = FakeShortcutAutomationExecutor()
        let tool = ShortcutAutomationTool(executor: executor)
        let out = await tool.execute(argumentsJSON: #"{"shortcut":"MyShortcut"}"#)
        XCTAssertTrue(out.contains("missing 'action'"), out)
    }

    func testInvalidAction() async {
        let executor = FakeShortcutAutomationExecutor()
        let tool = ShortcutAutomationTool(executor: executor)
        let out = await tool.execute(argumentsJSON: #"{"action":"delete"}"#)
        XCTAssertTrue(out.contains("invalid action \"delete\""), out)
    }

    func testExecMissingShortcut() async {
        let executor = FakeShortcutAutomationExecutor()
        let tool = ShortcutAutomationTool(executor: executor)
        let out = await tool.execute(argumentsJSON: #"{"action":"exec"}"#)
        XCTAssertTrue(out.contains("'shortcut' parameter is required"), out)
    }

    func testListSuccess() async {
        let executor = FakeShortcutAutomationExecutor()
        let tool = ShortcutAutomationTool(executor: executor)
        let out = await tool.execute(argumentsJSON: #"{"action":"list"}"#)
        XCTAssertTrue(out.contains("success"), out)
        let act = await executor.lastAction
        XCTAssertEqual(act, "list")
    }

    func testExecSuccessWithParameters() async {
        let executor = FakeShortcutAutomationExecutor()
        let tool = ShortcutAutomationTool(executor: executor)
        let json = """
        {"action":"exec","shortcut":"MorningBrief","params":"{\\"city\\":\\"Beijing\\"}","taskId":"task-123","timeout":20}
        """
        let out = await tool.execute(argumentsJSON: json)
        XCTAssertTrue(out.contains("success"), out)

        let act = await executor.lastAction
        let shortcut = await executor.lastShortcut
        let params = await executor.lastParams
        let taskId = await executor.lastTaskId
        let timeout = await executor.lastTimeoutSeconds

        XCTAssertEqual(act, "exec")
        XCTAssertEqual(shortcut, "MorningBrief")
        XCTAssertEqual(params, #"{"city":"Beijing"}"#)
        XCTAssertEqual(taskId, "task-123")
        XCTAssertEqual(timeout, 20)
    }

    func testTimeoutClamped() async {
        let executor = FakeShortcutAutomationExecutor()
        let tool = ShortcutAutomationTool(executor: executor)
        _ = await tool.execute(argumentsJSON: #"{"action":"list","timeout":50}"#)
        let timeout = await executor.lastTimeoutSeconds
        XCTAssertEqual(timeout, 25)

        _ = await tool.execute(argumentsJSON: #"{"action":"list","timeout":-5}"#)
        let timeoutLow = await executor.lastTimeoutSeconds
        XCTAssertEqual(timeoutLow, 1)
    }

    func testPermissionDeniedError() async {
        let executor = FakeShortcutAutomationExecutor()
        await (executor as FakeShortcutAutomationExecutor).setErrorToThrow(ShortcutAutomationError.permissionDenied)
        let tool = ShortcutAutomationTool(executor: executor)
        let out = await tool.execute(argumentsJSON: #"{"action":"list"}"#)
        XCTAssertTrue(out.contains("Notification permission is off"), out)
    }

    func testTimeoutError() async {
        let executor = FakeShortcutAutomationExecutor()
        await (executor as FakeShortcutAutomationExecutor).setErrorToThrow(ShortcutAutomationError.timeout(15))
        let tool = ShortcutAutomationTool(executor: executor)
        let out = await tool.execute(argumentsJSON: #"{"action":"list"}"#)
        XCTAssertTrue(out.contains("timed out waiting for completion (15s)"), out)
    }

    func testExecutionFailedError() async {
        let executor = FakeShortcutAutomationExecutor()
        await (executor as FakeShortcutAutomationExecutor).setErrorToThrow(ShortcutAutomationError.executionFailed("Workflow interrupted"))
        let tool = ShortcutAutomationTool(executor: executor)
        let out = await tool.execute(argumentsJSON: #"{"action":"list"}"#)
        XCTAssertTrue(out.contains("Shortcut automation execution failed: Workflow interrupted"), out)
    }
}

private extension FakeShortcutAutomationExecutor {
    func setErrorToThrow(_ error: Error?) {
        self.errorToThrow = error
    }
}
