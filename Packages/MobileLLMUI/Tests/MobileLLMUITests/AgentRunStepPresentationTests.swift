// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
import AgentRuntime
import LLMCore
@testable import MobileLLMUI

/// Codex-style action presentation: readable tool names, one-line concrete previews ("Search: …",
/// "Compute: …"), and approval titles that never leak internal descriptor identities.
@MainActor
final class AgentRunStepPresentationTests: XCTestCase {

    func testReadableToolNamePrettifiesIdentifiers() {
        XCTAssertEqual(AgentRunStore.readableToolName("web_search"), "Web search")
        XCTAssertEqual(AgentRunStore.readableToolName("calendar_event_tool"), "Calendar event tool")
        XCTAssertEqual(AgentRunStore.readableToolName("calculator"), "Calculator")
    }

    func testActionPreviewForKnownTools() {
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "web_search", argumentsJSON: #"{"query":"current year"}"#),
            "Search: current year"
        )
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "calculator", argumentsJSON: #"{"expression":"17+25"}"#),
            "Compute: 17+25"
        )
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "remember", argumentsJSON: #"{"text":"The user likes tea."}"#),
            "Remember: The user likes tea."
        )
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "fetch_webpage", argumentsJSON: #"{"url":"https://example.com"}"#),
            "Fetch: https://example.com"
        )
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "calendar_event_tool", argumentsJSON: #"{"title":"Team sync"}"#),
            "Event: Team sync"
        )
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "reminder_task_tool", argumentsJSON: #"{"title":"Water plants"}"#),
            "Remind: Water plants"
        )
    }

    func testActionPreviewFallsBackToCompactJSONAndEmpty() {
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "unknown_tool", argumentsJSON: #"{"a":{"b":"c"}}"#),
            #"{"a":{"b":"c"}}"#
        )
        XCTAssertEqual(AgentRunStore.actionPreview(toolName: "web_search", argumentsJSON: nil), "")
        XCTAssertEqual(AgentRunStore.actionPreview(toolName: "current_datetime", argumentsJSON: "{}"), "")
    }

    func testApprovalTitleUsesReadableToolName() throws {
        let destination = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://html.duckduckgo.com"
        )
        let plan = try ExternalOperationPlan(
            kind: .tool,
            subjectID: "builtin:web_search",
            destination: destination,
            dataCategories: [try AgentDataCategory(rawValue: "web.search")],
            payloadDigest: StableDigest.sha256(Data("x".utf8)),
            effects: [.networkRead],
            requiredCapabilities: AgentCapabilitySet([.networkRead]),
            maximumRequestBytes: 64,
            maximumResponseBytes: 1024,
            timeoutMilliseconds: 1_000,
            retryPolicy: .never,
            idempotency: .pureRead,
            userPreview: "Search the web"
        )
        XCTAssertEqual(AgentRunStore.approvalToolDisplayName(plan), "Web search")
    }

    func testApprovalTitleUsesModelNameForOnlineInference() throws {
        let destination = try ExternalDestination(
            kind: .modelProvider,
            normalizedIdentity: "openai.responses:responses-api-key:deepseek-v4-flash"
        )
        let plan = try ExternalOperationPlan(
            kind: .modelProvider,
            subjectID: "openai.responses",
            destination: destination,
            dataCategories: [try AgentDataCategory(rawValue: "model.inference")],
            payloadDigest: StableDigest.sha256(Data("x".utf8)),
            effects: [.externalCommunication],
            requiredCapabilities: AgentCapabilitySet([.externalCommunication]),
            maximumRequestBytes: 64,
            maximumResponseBytes: 1024,
            timeoutMilliseconds: 1_000,
            retryPolicy: .never,
            idempotency: .nonIdempotent,
            userPreview: "Send this conversation to deepseek-v4-flash"
        )
        XCTAssertEqual(AgentRunStore.approvalToolDisplayName(plan), "deepseek-v4-flash")
    }

    func testToolDisplayNameStripsDevicePrefixes() {
        XCTAssertEqual(AgentRunStore.toolDisplayName("builtin:current_datetime"), "current_datetime")
        XCTAssertEqual(AgentRunStore.toolDisplayName("device:calendar_get_events"), "calendar_get_events")
    }

    func testToolDisplayNameResolvesServerNameFromCache() {
        let serverID = UUID()
        let server = MCPServer(name: "HuggingFace", url: "https://example.com/mcp", stableID: serverID)
        MCPDiscoveryCache.shared.upsert(server: server)
        defer { MCPDiscoveryCache.shared.remove(serverStableID: serverID) }

        XCTAssertEqual(
            AgentRunStore.toolDisplayName("mcp.\(serverID.uuidString).gr1_z_image_turbo_generate_image"),
            "HuggingFace.gr1_z_image_turbo_generate_image"
        )
        XCTAssertEqual(
            AgentRunStore.toolDisplayName("mcp:\(serverID.uuidString):generate_image"),
            "HuggingFace.generate_image"
        )
    }

    func testToolDisplayNameFallsBackWhenServerNotFound() {
        let missingID = UUID()
        XCTAssertEqual(
            AgentRunStore.toolDisplayName("mcp.\(missingID.uuidString).gr1_z_image_turbo_generate_image"),
            "gr1_z_image_turbo_generate_image"
        )
    }

    func testApprovalTitlePrettifiesMcpToolNameWithServer() throws {
        let serverID = UUID(uuidString: "4865807E-90EB-40B8-B2F1-9708D36BC01C")!
        let server = MCPServer(name: "HuggingFace", url: "https://example.com/mcp", stableID: serverID)
        MCPDiscoveryCache.shared.upsert(server: server)
        defer { MCPDiscoveryCache.shared.remove(serverStableID: serverID) }

        let destination = try ExternalDestination(
            kind: .mcpServer,
            normalizedIdentity: serverID.uuidString
        )
        let plan = try ExternalOperationPlan(
            kind: .mcp,
            subjectID: "mcp.\(serverID.uuidString).gr1_z_image_turbo_generate_image",
            destination: destination,
            dataCategories: [try AgentDataCategory(rawValue: "mcp.call")],
            payloadDigest: StableDigest.sha256(Data("x".utf8)),
            effects: [.networkRead],
            requiredCapabilities: AgentCapabilitySet([.networkRead]),
            maximumRequestBytes: 64,
            maximumResponseBytes: 1024,
            timeoutMilliseconds: 1_000,
            retryPolicy: .never,
            idempotency: .pureRead,
            userPreview: "Generate an image"
        )
        XCTAssertEqual(AgentRunStore.approvalToolDisplayName(plan), "HuggingFace.gr1 z image turbo generate image")
    }
}
