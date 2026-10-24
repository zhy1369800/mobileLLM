// SPDX-License-Identifier: MIT

import Foundation
import AppRuntime

/// A stable identifier for each built-in tool, so the UI can persist which tools the user has enabled. The
/// raw value equals the tool's advertised schema name — one source of truth the model, the UI, and the
/// registry all share.
public enum ToolID: String, Sendable, Codable, Hashable, CaseIterable {
    case calculator
    case currentDatetime      = "current_datetime"
    case wikipedia
    case webSearch            = "web_search"
    case fetchWebpage         = "fetch_webpage"
    case remember
    case recall
    case calendarEvent        = "calendar_event_tool"
    case reminderTask         = "reminder_task_tool"
    case locationInfo         = "location_info_tool"
    case mapKit               = "map_kit_tool"
    case shortcutAutomation   = "shortcut_automation_tool"
}

/// Which built-in tools to assemble and how to configure them. `enabled` is the UI-persisted toggle set;
/// `searchEngines` sets `web_search`'s engine priority.
public struct BuiltInToolConfig: Sendable {
    public var searchEngines: [SearchEngine]
    public var enabled: Set<ToolID>

    public init(searchEngines: [SearchEngine] = [.duckduckgo, .bing, .brave],
                enabled: Set<ToolID> = BuiltInToolConfig.defaultEnabled) {
        self.searchEngines = searchEngines
        self.enabled = enabled
    }

    /// On by default: the non-privacy-sensitive tools. Calendar / reminders / location are OFF — they
    /// prompt for system permission, so the UI turns them on only after the user opts in.
    public static let defaultEnabled: Set<ToolID> = [
        .calculator, .currentDatetime, .wikipedia, .webSearch, .fetchWebpage, .remember, .recall,
    ]

    public static let `default` = BuiltInToolConfig()
}

public extension ToolRegistry {
    /// Build the built-in tool set from a config plus injected stores/seams (additive alongside
    /// `.standard` / `.builtIn` / `.build`). A tool is included only when it's enabled AND its dependency
    /// is available — so `remember`/`recall` need a `memoryStore`, the calendar/reminder tools need an
    /// `eventStore`, and `location_info_tool` needs a `locationProvider`. The privacy-free tools
    /// (calculator, clock, wikipedia, web_search, fetch_webpage) need nothing injected.
    ///
    /// MCP tools are layered separately (see `ToolRegistry.build`); this assembles only the on-device
    /// built-ins.
    static func assemble(config: BuiltInToolConfig = .default,
                         memoryStore: (any MemoryStoring)? = nil,
                         eventStore: (any EventStoring)? = nil,
                         locationProvider: (any LocationProviding)? = nil,
                         mapKitProvider: (any MapKitProviding)? = nil,
                         shortcutExecutor: (any ShortcutAutomationExecuting)? = nil,
                         session: URLSession = .shared) -> ToolRegistry {
        var tools: [Tool] = []
        func on(_ id: ToolID) -> Bool { config.enabled.contains(id) }

        if on(.calculator)       { tools.append(CalculatorTool()) }
        if on(.currentDatetime)  { tools.append(DateTimeTool()) }
        if on(.wikipedia)        { tools.append(WikipediaTool(session: session)) }
        if on(.webSearch)        { tools.append(WebSearchTool(engines: config.searchEngines, session: session)) }
        if on(.fetchWebpage)     { tools.append(WebScraperTool(session: session)) }

        if let memoryStore {
            if on(.remember) { tools.append(RememberTool(store: memoryStore)) }
            if on(.recall)   { tools.append(RecallTool(store: memoryStore)) }
        }
        if let eventStore {
            if on(.calendarEvent) { tools.append(CalendarEventTool(store: eventStore)) }
            if on(.reminderTask)  { tools.append(ReminderTaskTool(store: eventStore)) }
        }
        if let locationProvider, on(.locationInfo) {
            tools.append(LocationInfoTool(provider: locationProvider))
        }
        if let mapKitProvider, on(.mapKit) {
            tools.append(MapKitTool(provider: mapKitProvider))
        }
        if let shortcutExecutor, on(.shortcutAutomation) {
            tools.append(ShortcutAutomationTool(executor: shortcutExecutor))
        }
        return ToolRegistry(tools)
    }
}
