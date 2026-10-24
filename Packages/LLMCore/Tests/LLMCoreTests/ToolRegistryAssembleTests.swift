// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The config-driven `ToolRegistry.assemble`: the default privacy-free set, the gate that a tool needs both
/// enabling AND its injected dependency, per-tool disabling, and the invariant that every `ToolID` rawValue
/// maps to exactly one advertised tool name.
final class ToolRegistryAssembleTests: XCTestCase {

    private func names(_ registry: ToolRegistry) -> Set<String> {
        Set(registry.tools.map(\.schema.name))
    }

    func testDefaultAssemblesPrivacyFreeToolsOnly() {
        let n = names(ToolRegistry.assemble())
        XCTAssertTrue(n.isSuperset(of: ["calculator", "current_datetime", "wikipedia",
                                        "web_search", "fetch_webpage"]))
        // No store injected → memory tools absent even though enabled by default.
        XCTAssertFalse(n.contains("remember"))
        XCTAssertFalse(n.contains("recall"))
        // Privacy-sensitive tools are off by default.
        XCTAssertFalse(n.contains("calendar_event_tool"))
        XCTAssertFalse(n.contains("location_info_tool"))
        XCTAssertFalse(n.contains("map_kit_tool"))
    }

    func testMemoryToolsAppearOnlyWithStore() {
        XCTAssertFalse(names(ToolRegistry.assemble()).contains("remember"))
        let n = names(ToolRegistry.assemble(memoryStore: FakeMemoryStore()))
        XCTAssertTrue(n.contains("remember"))
        XCTAssertTrue(n.contains("recall"))
    }

    func testCalendarToolsNeedEnableAndStore() {
        // A store alone isn't enough — calendar ids are off by default.
        XCTAssertFalse(names(ToolRegistry.assemble(eventStore: FakeEventStore())).contains("calendar_event_tool"))
        let cfg = BuiltInToolConfig(enabled: BuiltInToolConfig.defaultEnabled
            .union([.calendarEvent, .reminderTask]))
        let n = names(ToolRegistry.assemble(config: cfg, eventStore: FakeEventStore()))
        XCTAssertTrue(n.isSuperset(of: ["calendar_event_tool", "reminder_task_tool"]))
    }

    func testLocationToolNeedsEnableAndProvider() {
        let cfg = BuiltInToolConfig(enabled: BuiltInToolConfig.defaultEnabled.union([.locationInfo, .mapKit]))
        // Enabled but no provider → absent.
        XCTAssertFalse(names(ToolRegistry.assemble(config: cfg)).contains("location_info_tool"))
        XCTAssertFalse(names(ToolRegistry.assemble(config: cfg)).contains("map_kit_tool"))
        // Enabled + provider → present.
        let n = names(ToolRegistry.assemble(config: cfg,
                                            locationProvider: FakeLocationProvider(result: .failure(.denied)),
                                            mapKitProvider: FakeMapKitProvider()))
        XCTAssertTrue(n.contains("location_info_tool"))
        XCTAssertTrue(n.contains("map_kit_tool"))
    }

    func testDisablingToolRemovesIt() {
        var cfg = BuiltInToolConfig()
        cfg.enabled.remove(.webSearch)
        let n = names(ToolRegistry.assemble(config: cfg))
        XCTAssertFalse(n.contains("web_search"))
        XCTAssertTrue(n.contains("calculator"))
    }

    func testEveryToolIDMapsToATool() {
        let cfg = BuiltInToolConfig(enabled: Set(ToolID.allCases))
        let registry = ToolRegistry.assemble(
            config: cfg,
            memoryStore: FakeMemoryStore(),
            eventStore: FakeEventStore(),
            locationProvider: FakeLocationProvider(result: .failure(.denied)))
        XCTAssertEqual(names(registry), Set(ToolID.allCases.map(\.rawValue)),
                       "assembling every ToolID must yield exactly those tool names")
    }
}
