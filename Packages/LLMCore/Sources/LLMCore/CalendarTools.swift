// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Seam types (framework-free, so the tools + tests never touch EventKit)

/// A calendar event the model wants to create.
public struct CalendarEventDraft: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date?
    public var location: String?
    public var notes: String?
    public var alarmMinutes: Int?
    public var calendarName: String?

    public init(
        title: String,
        start: Date,
        end: Date? = nil,
        location: String? = nil,
        notes: String? = nil,
        alarmMinutes: Int? = nil,
        calendarName: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.alarmMinutes = alarmMinutes
        self.calendarName = calendarName
    }
}

/// A calendar event read back for listing or searching.
public struct CalendarEventInfo: Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date?
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var calendar: String?

    public init(
        id: String = "",
        title: String,
        start: Date,
        end: Date? = nil,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        calendar: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.calendar = calendar
    }
}

/// A draft for updating an existing calendar event.
public struct CalendarEventUpdateDraft: Sendable, Equatable {
    public var id: String
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var location: String?
    public var notes: String?
    public var alarmMinutes: Int?
    public var calendarName: String?
    public var span: String?

    public init(
        id: String,
        title: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        location: String? = nil,
        notes: String? = nil,
        alarmMinutes: Int? = nil,
        calendarName: String? = nil,
        span: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.alarmMinutes = alarmMinutes
        self.calendarName = calendarName
        self.span = span
    }
}

/// Information about a system calendar.
public struct CalendarInfo: Sendable, Equatable {
    public var id: String
    public var title: String
    public var allowsContentModifications: Bool

    public init(id: String, title: String, allowsContentModifications: Bool = true) {
        self.id = id
        self.title = title
        self.allowsContentModifications = allowsContentModifications
    }
}

/// A time slot for free/busy scheduling analysis.
public struct FreeBusySlot: Sendable, Equatable {
    public var title: String?
    public var start: Date
    public var end: Date

    public init(title: String? = nil, start: Date, end: Date) {
        self.title = title
        self.start = start
        self.end = end
    }
}

/// Free/busy analysis result containing occupied and open intervals.
public struct FreeBusyResult: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var busySlots: [FreeBusySlot]
    public var freeSlots: [FreeBusySlot]

    public init(start: Date, end: Date, busySlots: [FreeBusySlot] = [], freeSlots: [FreeBusySlot] = []) {
        self.start = start
        self.end = end
        self.busySlots = busySlots
        self.freeSlots = freeSlots
    }
}

/// A reminder the model wants to create.
public struct ReminderDraft: Sendable, Equatable {
    public var title: String
    public var due: Date?
    public var notes: String?
    public var listName: String?
    public var priority: Int
    // Geofence
    public var lat: Double?
    public var lng: Double?
    public var locationName: String?
    public var radius: Double?
    public var proximity: String? // "enter" | "leave"
    // Recurrence
    public var recur: String? // "daily" | "weekly" | "monthly" | "yearly"
    public var recurInterval: Int?
    public var recurDays: String?
    public var recurCount: Int?
    public var recurUntil: Date?

    public init(
        title: String,
        due: Date? = nil,
        notes: String? = nil,
        listName: String? = nil,
        priority: Int = 0,
        lat: Double? = nil,
        lng: Double? = nil,
        locationName: String? = nil,
        radius: Double? = nil,
        proximity: String? = nil,
        recur: String? = nil,
        recurInterval: Int? = nil,
        recurDays: String? = nil,
        recurCount: Int? = nil,
        recurUntil: Date? = nil
    ) {
        self.title = title
        self.due = due
        self.notes = notes
        self.listName = listName
        self.priority = priority
        self.lat = lat
        self.lng = lng
        self.locationName = locationName
        self.radius = radius
        self.proximity = proximity
        self.recur = recur
        self.recurInterval = recurInterval
        self.recurDays = recurDays
        self.recurCount = recurCount
        self.recurUntil = recurUntil
    }
}

/// A reminder read back for listing.
public struct ReminderInfo: Sendable, Equatable {
    public var id: String
    public var title: String
    public var isCompleted: Bool
    public var due: Date?
    public var priority: Int
    public var notes: String?
    public var listName: String?
    public var locationName: String?
    public var recurrenceSummary: String?

    public init(
        id: String,
        title: String,
        isCompleted: Bool,
        due: Date? = nil,
        priority: Int = 0,
        notes: String? = nil,
        listName: String? = nil,
        locationName: String? = nil,
        recurrenceSummary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.due = due
        self.priority = priority
        self.notes = notes
        self.listName = listName
        self.locationName = locationName
        self.recurrenceSummary = recurrenceSummary
    }
}

/// A draft for updating an existing reminder.
public struct ReminderUpdateDraft: Sendable, Equatable {
    public var id: String
    public var title: String?
    public var listName: String?
    public var due: Date?
    public var priority: Int?
    public var notes: String?
    public var completed: Bool?
    // Geofence
    public var lat: Double?
    public var lng: Double?
    public var locationName: String?
    public var radius: Double?
    public var proximity: String?
    public var clearLocation: Bool
    // Recurrence
    public var recur: String?
    public var recurInterval: Int?
    public var recurDays: String?
    public var recurCount: Int?
    public var recurUntil: Date?
    public var clearRecur: Bool

    public init(
        id: String,
        title: String? = nil,
        listName: String? = nil,
        due: Date? = nil,
        priority: Int? = nil,
        notes: String? = nil,
        completed: Bool? = nil,
        lat: Double? = nil,
        lng: Double? = nil,
        locationName: String? = nil,
        radius: Double? = nil,
        proximity: String? = nil,
        clearLocation: Bool = false,
        recur: String? = nil,
        recurInterval: Int? = nil,
        recurDays: String? = nil,
        recurCount: Int? = nil,
        recurUntil: Date? = nil,
        clearRecur: Bool = false
    ) {
        self.id = id
        self.title = title
        self.listName = listName
        self.due = due
        self.priority = priority
        self.notes = notes
        self.completed = completed
        self.lat = lat
        self.lng = lng
        self.locationName = locationName
        self.radius = radius
        self.proximity = proximity
        self.clearLocation = clearLocation
        self.recur = recur
        self.recurInterval = recurInterval
        self.recurDays = recurDays
        self.recurCount = recurCount
        self.recurUntil = recurUntil
        self.clearRecur = clearRecur
    }
}

/// Information about a reminders calendar/list.
public struct ReminderListInfo: Sendable, Equatable {
    public var id: String
    public var title: String
    public var isDefault: Bool
    public init(id: String, title: String, isDefault: Bool = false) {
        self.id = id
        self.title = title
        self.isDefault = isDefault
    }
}

/// Errors the calendar/reminder seam raises; the tools map them to instructive strings.
public enum EventStoreError: Error, Sendable, Equatable {
    case calendarAccessDenied
    case reminderAccessDenied
    case failed(String)
}

/// The EventKit seam. A real `EKEventStore`-backed adapter conforms on-device; tests inject a fake. Kept in
/// plain value types so LLMCore's tool + test code never imports EventKit (only the adapter does).
public protocol EventStoring: Sendable {
    /// Create an event; returns a short human label on success.
    func createEvent(_ draft: CalendarEventDraft) async throws -> String
    /// Events starting within the next `daysAhead` days, soonest first, with optional calendar filter.
    func events(daysAhead: Int, calendarName: String?) async throws -> [CalendarEventInfo]
    /// Search events matching query across past 7 days to next `daysAhead` days.
    func searchEvents(query: String, daysAhead: Int) async throws -> [CalendarEventInfo]
    /// Update an existing calendar event.
    func updateEvent(_ draft: CalendarEventUpdateDraft) async throws -> String
    /// Delete a calendar event by identifier.
    func deleteEvent(id: String, span: String?) async throws -> Bool
    /// List available calendar accounts/lists.
    func calendars() async throws -> [CalendarInfo]
    /// Analyze free and busy intervals in a date range.
    func freebusy(start: Date, end: Date) async throws -> FreeBusyResult

    /// Create a reminder; returns a short human label on success.
    func createReminder(_ draft: ReminderDraft) async throws -> String
    /// List reminders with optional list filtering, completed inclusion, and limit.
    func reminders(listName: String?, includeCompleted: Bool, limit: Int?) async throws -> [ReminderInfo]
    /// Update an existing reminder.
    func updateReminder(_ draft: ReminderUpdateDraft) async throws -> String
    /// Mark a reminder completed or incomplete.
    func completeReminder(id: String, completed: Bool) async throws -> Bool
    /// Delete a reminder by its identifier.
    func deleteReminder(id: String) async throws -> Bool
    /// List available reminder lists.
    func reminderLists() async throws -> [ReminderListInfo]
    /// Current system authorization for a domain, without prompting.
    func permissionState(for domain: EventDomain) async -> ToolPermission
    /// Prompt the user if undetermined; resolves immediately when already decided.
    func requestPermission(for domain: EventDomain) async -> ToolPermission
}

/// The two EventKit permission domains (separate TCC switches on iOS).
public enum EventDomain: Sendable { case events, reminders }

/// Defaults keep test fakes to the three data methods.
public extension EventStoring {
    func permissionState(for domain: EventDomain) async -> ToolPermission { .granted }
    func requestPermission(for domain: EventDomain) async -> ToolPermission { .granted }
    func events(daysAhead: Int) async throws -> [CalendarEventInfo] {
        try await events(daysAhead: daysAhead, calendarName: nil)
    }
    func events(daysAhead: Int, calendarName: String?) async throws -> [CalendarEventInfo] { [] }
    func searchEvents(query: String, daysAhead: Int) async throws -> [CalendarEventInfo] { [] }
    func updateEvent(_ draft: CalendarEventUpdateDraft) async throws -> String { draft.title ?? draft.id }
    func deleteEvent(id: String, span: String?) async throws -> Bool { true }
    func calendars() async throws -> [CalendarInfo] { [] }
    func freebusy(start: Date, end: Date) async throws -> FreeBusyResult { FreeBusyResult(start: start, end: end) }
    func reminders(listName: String?, includeCompleted: Bool, limit: Int?) async throws -> [ReminderInfo] { [] }
    func updateReminder(_ draft: ReminderUpdateDraft) async throws -> String { draft.title ?? draft.id }
    func completeReminder(id: String, completed: Bool) async throws -> Bool { true }
    func deleteReminder(id: String) async throws -> Bool { true }
    func reminderLists() async throws -> [ReminderListInfo] { [] }
}

// MARK: - ISO 8601 parsing

/// Lenient date parsing for model-emitted times: ISO 8601 first, then the RELATIVE phrases small models
/// actually produce ("now + 1 hour", "in 30 minutes", "1小时后", "tomorrow 09:00") — observed on-device:
/// a 2B model asked for "an alarm in an hour" emits `now + 1 hour`, and rejecting that kills the whole
/// flow because small models don't reliably retry off an error string. Zone-less strings are interpreted
/// in the device's current timezone. Returns nil for real garbage so the tools still reject clearly.
enum ISO8601Parsing {
    static func date(from raw: String, now: Date = Date()) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        if let d = relative(from: s, now: now) { return d }
        // Last resort: the system's natural-language date detector ("tomorrow 9am", "next Friday").
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let d = match.date, match.range.length >= (s.count * 2) / 3 {
            return d
        }
        return nil
    }

    /// The small relative grammar models emit: "now", "now + N unit(s)" / "now - …", "in N unit(s)",
    /// "N unit(s) from now", and the Chinese equivalents "N分钟后 / N小时后 / N天后", "明天/后天 [HH:mm]".
    static func relative(from raw: String, now: Date) -> Date? {
        let s = raw.lowercased()
        let cal = Calendar.current

        func seconds(_ n: Double, _ unit: String) -> TimeInterval? {
            switch unit {
            case "second", "seconds", "sec", "s", "秒": return n
            case "minute", "minutes", "min", "mins", "m", "分钟", "分": return n * 60
            case "hour", "hours", "hr", "hrs", "h", "小时", "时": return n * 3600
            case "day", "days", "d", "天", "日": return n * 86_400
            case "week", "weeks", "w", "周", "星期": return n * 604_800
            default: return nil
            }
        }
        func firstMatch(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            return (0..<m.numberOfRanges).map {
                Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? ""
            }
        }

        if s == "now" || s == "现在" { return now }
        // "now + 1 hour", "now - 30 min"
        if let g = firstMatch(#"^now\s*([+-])\s*(\d+(?:\.\d+)?)\s*([a-z分钟小时天日周秒时]+)$"#),
           let n = Double(g[2]), let sec = seconds(n, g[3]) {
            return now.addingTimeInterval(g[1] == "-" ? -sec : sec)
        }
        // "in 30 minutes" / "30 minutes from now"
        if let g = firstMatch(#"^in\s+(\d+(?:\.\d+)?)\s*([a-z]+)$"#) ?? firstMatch(#"^(\d+(?:\.\d+)?)\s*([a-z]+)\s+from\s+now$"#),
           let n = Double(g[1]), let sec = seconds(n, g[2]) {
            return now.addingTimeInterval(sec)
        }
        // "1小时后" / "30分钟后" / "2天后"
        if let g = firstMatch(#"^(\d+(?:\.\d+)?)\s*(秒|分钟|分|小时|时|天|日|周|星期)(之后|后)$"#),
           let n = Double(g[1]), let sec = seconds(n, g[2]) {
            return now.addingTimeInterval(sec)
        }
        // "tomorrow [09:00]" / "明天 [9:30]" / "后天"
        if let g = firstMatch(#"^(tomorrow|明天|后天)\s*(\d{1,2}[:：]\d{2})?$"#) {
            let days = (g[1] == "后天") ? 2 : 1
            guard let day = cal.date(byAdding: .day, value: days, to: now) else { return nil }
            guard !g[2].isEmpty else { return cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) }
            let hm = g[2].replacingOccurrences(of: "：", with: ":").split(separator: ":")
            guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]) else { return nil }
            return cal.date(bySettingHour: h, minute: m, second: 0, of: day)
        }
        return nil
    }

    /// Human-readable local rendering for confirmations / listings.
    static func display(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Tools

/// Unified tool for managing calendar events (queries, keyword search, creation, updates, deletion, calendar lists, and free/busy analysis).
public struct CalendarEventTool: Tool {
    private let store: any EventStoring
    public init(store: any EventStoring) { self.store = store }

    public static let schema: ToolSchema = ToolSchema(
        name: "calendar_event_tool",
        description: "Manage calendar events: query upcoming events, search events by keyword, create events with start/end time, location, notes, alarm reminder and target calendar, update existing events, delete events, list calendars, and analyze free/busy time slots for scheduling.",
        parameters: [
            ToolParam(name: "action", kind: .string,
                      description: "Action to perform: list_events, search_events, create_event, update_event, delete_event, list_calendars, freebusy"),
            ToolParam(name: "days", kind: .number,
                      description: "Number of days to look ahead for list_events (default 7), search_events (default 30), or freebusy (default 1)", required: false),
            ToolParam(name: "query", kind: .string,
                      description: "Keyword query for search_events", required: false),
            ToolParam(name: "title", kind: .string,
                      description: "Title of the event (required for create_event)", required: false),
            ToolParam(name: "start", kind: .string,
                      description: "Start datetime in ISO 8601 or relative format (e.g. \"2026-07-20T15:00\", \"tomorrow 09:00\", \"now + 1 hour\")", required: false),
            ToolParam(name: "end", kind: .string,
                      description: "End datetime in ISO 8601 or relative format (optional; defaults to 1 hour after start)", required: false),
            ToolParam(name: "location", kind: .string,
                      description: "Location of the event", required: false),
            ToolParam(name: "notes", kind: .string,
                      description: "Notes or description of the event", required: false),
            ToolParam(name: "alarm_minutes", kind: .number,
                      description: "Alarm alert offset in minutes before event start (e.g. 15 for 15 minutes before)", required: false),
            ToolParam(name: "calendar_name", kind: .string,
                      description: "Target calendar name (e.g. \"Work\", \"Personal\")", required: false),
            ToolParam(name: "id", kind: .string,
                      description: "Calendar event ID (required for update_event and delete_event)", required: false),
            ToolParam(name: "span", kind: .string,
                      description: "\"this\" (default) or \"future\"/\"all\" for recurring event update/deletion", required: false),
        ]
    )

    public var schema: ToolSchema { Self.schema }

    public func execute(argumentsJSON: String) async -> String {
        let call = ToolCall(name: "calendar_event_tool", argumentsJSON: argumentsJSON)
        guard let action = call.arg("action")?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty else {
            return "Error: missing 'action' parameter. Supported actions: list_events, search_events, create_event, update_event, delete_event, list_calendars, freebusy."
        }

        do {
            switch action {
            case "list_events":
                let days = call.arg("days").flatMap { Int(Double($0) ?? -1) } ?? 7
                let calName = call.arg("calendar_name")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let events = try await store.events(daysAhead: max(1, days), calendarName: (calName?.isEmpty == false ? calName : nil))
                let daySuffix = days == 1 ? "" : "s"
                guard !events.isEmpty else {
                    let calSuffix = (calName?.isEmpty == false) ? " in calendar '\(calName!)'" : ""
                    return "No events in the next \(days) day\(daySuffix)\(calSuffix)."
                }
                let lines = events.sorted { $0.start < $1.start }.map { e -> String in
                    var locStr = ""
                    if let loc = e.location, !loc.isEmpty { locStr = " at \(loc)" }
                    var calStr = ""
                    if let cal = e.calendar, !cal.isEmpty { calStr = " [\(cal)]" }
                    var idStr = ""
                    if !e.id.isEmpty { idStr = " (id: \(e.id))" }
                    return "• \(e.title) — \(ISO8601Parsing.display(e.start))\(locStr)\(calStr)\(idStr)"
                }
                return "Events in the next \(days) day\(daySuffix):\n" + lines.joined(separator: "\n")

            case "search_events":
                guard let query = call.arg("query")?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                    return "Error: missing 'query' parameter for search_events."
                }
                let days = call.arg("days").flatMap { Int(Double($0) ?? -1) } ?? 30
                let events = try await store.searchEvents(query: query, daysAhead: max(1, days))
                guard !events.isEmpty else {
                    return "No events found matching \"\(query)\"."
                }
                let lines = events.sorted { $0.start < $1.start }.map { e -> String in
                    var locStr = ""
                    if let loc = e.location, !loc.isEmpty { locStr = " at \(loc)" }
                    var calStr = ""
                    if let cal = e.calendar, !cal.isEmpty { calStr = " [\(cal)]" }
                    var idStr = ""
                    if !e.id.isEmpty { idStr = " (id: \(e.id))" }
                    return "• \(e.title) — \(ISO8601Parsing.display(e.start))\(locStr)\(calStr)\(idStr)"
                }
                let eventSuffix = events.count == 1 ? "" : "s"
                return "Found \(events.count) event\(eventSuffix) matching \"\(query)\":\n" + lines.joined(separator: "\n")

            case "create_event":
                guard let title = call.arg("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                    return "Error: missing event 'title'."
                }
                guard let startRaw = call.arg("start"), let start = ISO8601Parsing.date(from: startRaw) else {
                    return "Error: couldn't read 'start' as a date/time — use ISO 8601 (2026-07-20T15:00) or a relative time like \"now + 1 hour\", \"tomorrow 09:00\"."
                }
                var end: Date?
                if let endRaw = call.arg("end"), !endRaw.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let parsed = ISO8601Parsing.date(from: endRaw) else {
                        return "Error: couldn't read 'end' as a date/time — use ISO 8601 (2026-07-20T16:00) or a relative time like \"now + 2 hours\"."
                    }
                    end = parsed
                }
                let location = call.arg("location")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let notes = call.arg("notes")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let alarmMinutes = call.arg("alarm_minutes").flatMap { Int(Double($0) ?? -1) }
                let calendarName = call.arg("calendar_name")?.trimmingCharacters(in: .whitespacesAndNewlines)

                let draft = CalendarEventDraft(
                    title: title,
                    start: start,
                    end: end,
                    location: location?.isEmpty == false ? location : nil,
                    notes: notes?.isEmpty == false ? notes : nil,
                    alarmMinutes: alarmMinutes != nil && alarmMinutes! >= 0 ? alarmMinutes : nil,
                    calendarName: calendarName?.isEmpty == false ? calendarName : nil
                )
                let label = try await store.createEvent(draft)
                return "Added \"\(label)\" to your calendar on \(ISO8601Parsing.display(start))."

            case "update_event":
                guard let id = call.arg("id")?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                    return "Error: missing event 'id' for update_event."
                }
                let title = call.arg("title")?.trimmingCharacters(in: .whitespacesAndNewlines)
                var start: Date?
                if let startRaw = call.arg("start"), !startRaw.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let parsed = ISO8601Parsing.date(from: startRaw) else {
                        return "Error: couldn't read 'start' as date/time."
                    }
                    start = parsed
                }
                var end: Date?
                if let endRaw = call.arg("end"), !endRaw.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let parsed = ISO8601Parsing.date(from: endRaw) else {
                        return "Error: couldn't read 'end' as date/time."
                    }
                    end = parsed
                }
                let location = call.arg("location")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let notes = call.arg("notes")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let alarmMinutes = call.arg("alarm_minutes").flatMap { Int(Double($0) ?? -1) }
                let calendarName = call.arg("calendar_name")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let span = call.arg("span")?.trimmingCharacters(in: .whitespacesAndNewlines)

                let updateDraft = CalendarEventUpdateDraft(
                    id: id,
                    title: title?.isEmpty == false ? title : nil,
                    start: start,
                    end: end,
                    location: location?.isEmpty == false ? location : nil,
                    notes: notes?.isEmpty == false ? notes : nil,
                    alarmMinutes: alarmMinutes,
                    calendarName: calendarName?.isEmpty == false ? calendarName : nil,
                    span: span?.isEmpty == false ? span : nil
                )
                let label = try await store.updateEvent(updateDraft)
                return "Updated event \"\(label)\"."

            case "delete_event":
                guard let id = call.arg("id")?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                    return "Error: missing event 'id' for delete_event."
                }
                let span = call.arg("span")?.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await store.deleteEvent(id: id, span: span)
                return "Deleted calendar event with ID '\(id)'."

            case "list_calendars":
                let cals = try await store.calendars()
                guard !cals.isEmpty else { return "No calendar accounts found." }
                let lines = cals.map { cal in
                    let mod = cal.allowsContentModifications ? "writable" : "read-only"
                    return "• \(cal.title) (\(mod), id: \(cal.id))"
                }
                return "Calendars (\(cals.count)):\n" + lines.joined(separator: "\n")

            case "freebusy":
                let days = call.arg("days").flatMap { Int(Double($0) ?? -1) } ?? 1
                let now = Date()
                let start: Date
                if let startRaw = call.arg("start"), let parsed = ISO8601Parsing.date(from: startRaw) {
                    start = parsed
                } else {
                    start = Calendar.current.startOfDay(for: now)
                }
                let end: Date
                if let endRaw = call.arg("end"), let parsed = ISO8601Parsing.date(from: endRaw) {
                    end = parsed
                } else {
                    end = Calendar.current.date(byAdding: .day, value: max(1, days), to: start) ?? start.addingTimeInterval(TimeInterval(days * 86400))
                }

                let result = try await store.freebusy(start: start, end: end)
                var sections: [String] = []
                sections.append("Free/Busy schedule from \(ISO8601Parsing.display(start)) to \(ISO8601Parsing.display(end)):")

                if result.busySlots.isEmpty {
                    sections.append("\nBusy slots: None")
                } else {
                    let busyLines = result.busySlots.map { slot in
                        let titlePart = slot.title.map { " (\($0))" } ?? ""
                        return "• \(ISO8601Parsing.display(slot.start)) - \(ISO8601Parsing.display(slot.end))\(titlePart)"
                    }
                    sections.append("\nBusy slots (\(result.busySlots.count)):\n" + busyLines.joined(separator: "\n"))
                }

                if result.freeSlots.isEmpty {
                    sections.append("\nFree slots: None")
                } else {
                    let freeLines = result.freeSlots.map { slot in
                        "• \(ISO8601Parsing.display(slot.start)) - \(ISO8601Parsing.display(slot.end))"
                    }
                    sections.append("\nFree slots (\(result.freeSlots.count)):\n" + freeLines.joined(separator: "\n"))
                }

                return sections.joined(separator: "\n")

            default:
                return "Error: unknown action '\(action)'. Supported actions: list_events, search_events, create_event, update_event, delete_event, list_calendars, freebusy."
            }
        } catch EventStoreError.calendarAccessDenied {
            return "Calendar access is off — enable it in Settings to access events."
        } catch {
            return "Calendar operation failed: \(errorText(error))."
        }
    }
}

/// Unified tool for managing reminders and to-do lists (queries, creation, updates, completion, deletion).
public struct ReminderTaskTool: Tool {
    private let store: any EventStoring
    public init(store: any EventStoring) { self.store = store }

    public static let schema: ToolSchema = ToolSchema(
        name: "reminder_task_tool",
        description: "Manage reminders and to-do lists: query to-dos, create reminders with due dates, locations or repeating rules, update fields, complete/uncomplete, delete reminders, and list reminder categories.",
        parameters: [
            ToolParam(name: "action", kind: .string,
                      description: "Action to perform: list_reminders, create_reminder, update_reminder, complete_reminder, delete_reminder, list_lists"),
            ToolParam(name: "list_name", kind: .string,
                      description: "Reminder category or list name to filter or target", required: false),
            ToolParam(name: "include_completed", kind: .boolean,
                      description: "Include completed reminders in list_reminders (default false)", required: false),
            ToolParam(name: "limit", kind: .number,
                      description: "Maximum number of reminders to return in list_reminders (default 50)", required: false),
            ToolParam(name: "title", kind: .string,
                      description: "Reminder title (required for create_reminder)", required: false),
            ToolParam(name: "due_date", kind: .string,
                      description: "Due date/time in ISO 8601 or relative format (e.g. \"2026-07-20T09:00\", \"tomorrow 09:00\", \"now + 1 hour\")", required: false),
            ToolParam(name: "priority", kind: .number,
                      description: "Priority (0: none, 1: high, 5: medium, 9: low)", required: false),
            ToolParam(name: "notes", kind: .string,
                      description: "Notes or description", required: false),
            ToolParam(name: "id", kind: .string,
                      description: "Identifier of the reminder (required for update_reminder, complete_reminder, delete_reminder)", required: false),
            ToolParam(name: "completed", kind: .boolean,
                      description: "Completion status for complete_reminder or update_reminder", required: false),
            ToolParam(name: "lat", kind: .number,
                      description: "Latitude for geofence location alarm", required: false),
            ToolParam(name: "lng", kind: .number,
                      description: "Longitude for geofence location alarm", required: false),
            ToolParam(name: "location_name", kind: .string,
                      description: "Label for the location", required: false),
            ToolParam(name: "radius", kind: .number,
                      description: "Geofence radius in meters", required: false),
            ToolParam(name: "proximity", kind: .string,
                      description: "\"enter\" for arrival alert, \"leave\" for departure alert", required: false),
            ToolParam(name: "clear_location", kind: .boolean,
                      description: "Set true in update_reminder to remove existing location alarm", required: false),
            ToolParam(name: "recur", kind: .string,
                      description: "Repeat frequency: \"daily\", \"weekly\", \"monthly\", \"yearly\"", required: false),
            ToolParam(name: "recur_interval", kind: .number,
                      description: "Repeat every N intervals (default 1)", required: false),
            ToolParam(name: "recur_days", kind: .string,
                      description: "Weekdays for repeat (e.g. \"mon,wed,fri\")", required: false),
            ToolParam(name: "recur_count", kind: .number,
                      description: "Stop repeating after N occurrences", required: false),
            ToolParam(name: "recur_until", kind: .string,
                      description: "Stop repeating after this date (ISO 8601)", required: false),
            ToolParam(name: "clear_recur", kind: .boolean,
                      description: "Set true in update_reminder to remove repeating rule", required: false)
        ]
    )

    public var schema: ToolSchema { Self.schema }

    public func execute(argumentsJSON: String) async -> String {
        let call = ToolCall(name: "reminder_task_tool", argumentsJSON: argumentsJSON)
        var action = call.arg("action")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        // Lenient fallback: if action is missing but title is provided, assume create_reminder
        if action.isEmpty, let title = call.arg("title"), !title.isEmpty {
            action = "create_reminder"
        }

        do {
            switch action {
            case "list_reminders", "list":
                return try await handleListReminders(call)
            case "create_reminder", "create", "add":
                return try await handleCreateReminder(call)
            case "update_reminder", "update", "edit":
                return try await handleUpdateReminder(call)
            case "complete_reminder", "complete", "finish":
                return try await handleCompleteReminder(call)
            case "delete_reminder", "delete", "remove":
                return try await handleDeleteReminder(call)
            case "list_lists", "lists", "categories":
                return try await handleListLists(call)
            default:
                return "Error: unknown action \"\(action)\". Valid actions: list_reminders, create_reminder, update_reminder, complete_reminder, delete_reminder, list_lists."
            }
        } catch EventStoreError.reminderAccessDenied {
            return "Reminders access is off — enable it in Settings to access reminders."
        } catch {
            return "Error executing reminder operation: \(errorText(error))."
        }
    }

    private func handleListReminders(_ call: ToolCall) async throws -> String {
        let listName = call.arg("list_name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let includeCompleted = call.arg("include_completed").flatMap { Bool($0) } ?? false
        let limit = call.arg("limit").flatMap { Int(Double($0) ?? 50) } ?? 50

        let reminders = try await store.reminders(listName: listName, includeCompleted: includeCompleted, limit: limit)
        guard !reminders.isEmpty else {
            if let listName, !listName.isEmpty {
                return "No reminders found in list \"\(listName)\"."
            }
            return "No reminders found."
        }

        var lines: [String] = []
        for r in reminders {
            let status = r.isCompleted ? "[✓]" : "[ ]"
            var parts = ["\(status) \(r.title)"]
            if let due = r.due {
                parts.append("due: \(ISO8601Parsing.display(due))")
            }
            if r.priority > 0 {
                let p = r.priority == 1 ? "High" : (r.priority == 5 ? "Medium" : "Low")
                parts.append("priority: \(p)")
            }
            if let list = r.listName, !list.isEmpty {
                parts.append("list: \(list)")
            }
            if let loc = r.locationName, !loc.isEmpty {
                parts.append("location: \(loc)")
            }
            if let recur = r.recurrenceSummary, !recur.isEmpty {
                parts.append("repeat: \(recur)")
            }
            parts.append("(id: \(r.id))")
            lines.append("• " + parts.joined(separator: " | "))
        }
        return "Reminders (\(reminders.count)):\n" + lines.joined(separator: "\n")
    }

    private func handleCreateReminder(_ call: ToolCall) async throws -> String {
        guard let title = call.arg("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Error: missing required parameter 'title' for create_reminder."
        }
        var due: Date?
        if let dueRaw = call.arg("due_date") ?? call.arg("due"), !dueRaw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = ISO8601Parsing.date(from: dueRaw) else {
                return "Error: couldn't read 'due_date' as a date/time — use ISO 8601 or relative format like \"tomorrow 09:00\" or \"now + 1 hour\"."
            }
            due = parsed
        }

        var recurUntil: Date?
        if let untilRaw = call.arg("recur_until"), !untilRaw.trimmingCharacters(in: .whitespaces).isEmpty {
            recurUntil = ISO8601Parsing.date(from: untilRaw)
        }

        let draft = ReminderDraft(
            title: title,
            due: due,
            notes: call.arg("notes"),
            listName: call.arg("list_name"),
            priority: call.arg("priority").flatMap { Int(Double($0) ?? 0) } ?? 0,
            lat: call.arg("lat").flatMap { Double($0) },
            lng: call.arg("lng").flatMap { Double($0) },
            locationName: call.arg("location_name"),
            radius: call.arg("radius").flatMap { Double($0) },
            proximity: call.arg("proximity"),
            recur: call.arg("recur"),
            recurInterval: call.arg("recur_interval").flatMap { Int(Double($0) ?? 1) },
            recurDays: call.arg("recur_days"),
            recurCount: call.arg("recur_count").flatMap { Int(Double($0) ?? 0) },
            recurUntil: recurUntil
        )

        let identifier = try await store.createReminder(draft)
        var detail = "Created reminder \"\(title)\""
        if let due { detail += " due for \(ISO8601Parsing.display(due))" }
        if let loc = draft.locationName ?? (draft.lat != nil ? "\(draft.lat!),\(draft.lng!)" : nil) {
            detail += " with location alert at \(loc)"
        }
        if let recur = draft.recur {
            detail += " (repeats: \(recur))"
        }
        return "\(detail). (id: \(identifier))"
    }

    private func handleUpdateReminder(_ call: ToolCall) async throws -> String {
        guard let id = call.arg("id")?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return "Error: missing required parameter 'id' for update_reminder."
        }

        var due: Date?
        if let dueRaw = call.arg("due_date") ?? call.arg("due"), !dueRaw.trimmingCharacters(in: .whitespaces).isEmpty {
            due = ISO8601Parsing.date(from: dueRaw)
        }

        var recurUntil: Date?
        if let untilRaw = call.arg("recur_until"), !untilRaw.trimmingCharacters(in: .whitespaces).isEmpty {
            recurUntil = ISO8601Parsing.date(from: untilRaw)
        }

        let draft = ReminderUpdateDraft(
            id: id,
            title: call.arg("title"),
            listName: call.arg("list_name"),
            due: due,
            priority: call.arg("priority").flatMap { Int(Double($0) ?? 0) },
            notes: call.arg("notes"),
            completed: call.arg("completed").flatMap { Bool($0) },
            lat: call.arg("lat").flatMap { Double($0) },
            lng: call.arg("lng").flatMap { Double($0) },
            locationName: call.arg("location_name"),
            radius: call.arg("radius").flatMap { Double($0) },
            proximity: call.arg("proximity"),
            clearLocation: call.arg("clear_location").flatMap { Bool($0) } ?? false,
            recur: call.arg("recur"),
            recurInterval: call.arg("recur_interval").flatMap { Int(Double($0) ?? 1) },
            recurDays: call.arg("recur_days"),
            recurCount: call.arg("recur_count").flatMap { Int(Double($0) ?? 0) },
            recurUntil: recurUntil,
            clearRecur: call.arg("clear_recur").flatMap { Bool($0) } ?? false
        )

        let resultTitle = try await store.updateReminder(draft)
        return "Updated reminder \"\(resultTitle)\" successfully."
    }

    private func handleCompleteReminder(_ call: ToolCall) async throws -> String {
        guard let id = call.arg("id")?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return "Error: missing required parameter 'id' for complete_reminder."
        }
        let completed = call.arg("completed").flatMap { Bool($0) } ?? true
        _ = try await store.completeReminder(id: id, completed: completed)
        return "Marked reminder \(id) as \(completed ? "completed" : "incomplete")."
    }

    private func handleDeleteReminder(_ call: ToolCall) async throws -> String {
        guard let id = call.arg("id")?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return "Error: missing required parameter 'id' for delete_reminder."
        }
        _ = try await store.deleteReminder(id: id)
        return "Deleted reminder \(id)."
    }

    private func handleListLists(_ call: ToolCall) async throws -> String {
        let lists = try await store.reminderLists()
        guard !lists.isEmpty else { return "No reminder lists found." }
        let items = lists.map { "• \($0.title)\($0.isDefault ? " (Default)" : "")" }
        return "Available reminder lists:\n" + items.joined(separator: "\n")
    }
}

/// A short user-facing string for an unexpected store error.
private func errorText(_ error: Error) -> String {
    if case EventStoreError.failed(let m) = error { return m }
    return "\(error)"
}
