// SPDX-License-Identifier: MIT

#if canImport(EventKit)
import Foundation
import EventKit
#if canImport(CoreLocation)
import CoreLocation
#endif

/// The real, on-device `EventStoring` backed by `EKEventStore`. Access is requested lazily on first use
/// (iOS 17+/macOS 14+ full-access APIs); a denial surfaces as `EventStoreError.*AccessDenied` which the
/// tools turn into an instructive "enable it in Settings" message. Not unit-tested — device behavior only;
/// LLMCore's tests exercise the tools through a fake conforming to `EventStoring`.
///
/// `@unchecked Sendable`: `EKEventStore` is a reference type that isn't `Sendable`, but the tools call one
/// method at a time and never share the store across concurrent calls, so the single instance is safe here.
public final class EventKitStore: EventStoring, @unchecked Sendable {
    private let store = EKEventStore()
    public init() {}

    private func ensureEventAccess() async throws {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if !granted { throw EventStoreError.calendarAccessDenied }
    }

    private func ensureReminderAccess() async throws {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        if !granted { throw EventStoreError.reminderAccessDenied }
    }

    public func permissionState(for domain: EventDomain) async -> ToolPermission {
        let status = EKEventStore.authorizationStatus(for: domain == .events ? .event : .reminder)
        switch status {
        case .notDetermined: return .notDetermined
        case .denied, .restricted, .writeOnly: return .denied   // the tools need read+write full access
        case .fullAccess, .authorized: return .granted
        @unknown default: return .denied
        }
    }

    /// Prompt (or resolve) full access for the domain — the Tools screen calls this the moment the
    /// toggle flips, so the system dialog appears at the user's own decision point, not mid-chat.
    public func requestPermission(for domain: EventDomain) async -> ToolPermission {
        let granted: Bool
        switch domain {
        case .events: granted = (try? await store.requestFullAccessToEvents()) ?? false
        case .reminders: granted = (try? await store.requestFullAccessToReminders()) ?? false
        }
        return granted ? .granted : .denied
    }

    private func findCalendar(named name: String) -> EKCalendar? {
        let calendars = store.calendars(for: .event)
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return calendars.first(where: {
            $0.title.lowercased() == n || $0.title.localizedCaseInsensitiveContains(n)
        })
    }

    private func formatCalendarEvent(_ ev: EKEvent) -> CalendarEventInfo {
        CalendarEventInfo(
            id: ev.eventIdentifier ?? "",
            title: ev.title ?? "(untitled)",
            start: ev.startDate ?? Date(),
            end: ev.endDate,
            isAllDay: ev.isAllDay,
            location: ev.location,
            notes: ev.notes,
            calendar: ev.calendar?.title
        )
    }

    public func createEvent(_ draft: CalendarEventDraft) async throws -> String {
        try await ensureEventAccess()
        let calendar: EKCalendar
        if let calName = draft.calendarName, !calName.isEmpty, let matched = findCalendar(named: calName) {
            calendar = matched
        } else if let def = store.defaultCalendarForNewEvents {
            calendar = def
        } else if let first = store.calendars(for: .event).first {
            calendar = first
        } else {
            throw EventStoreError.failed("no writable calendar")
        }

        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end ?? draft.start.addingTimeInterval(3600)
        event.location = draft.location
        event.notes = draft.notes
        event.calendar = calendar

        if let alarmMinutes = draft.alarmMinutes, alarmMinutes >= 0 {
            let alarm = EKAlarm(relativeOffset: -Double(alarmMinutes * 60))
            event.addAlarm(alarm)
        }

        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw EventStoreError.failed(error.localizedDescription)
        }
        return draft.title
    }

    public func events(daysAhead: Int) async throws -> [CalendarEventInfo] {
        try await events(daysAhead: daysAhead, calendarName: nil)
    }

    public func events(daysAhead: Int, calendarName: String?) async throws -> [CalendarEventInfo] {
        try await ensureEventAccess()
        let now = Date()
        let startDate = Calendar.current.startOfDay(for: now)
        let endDate = Calendar.current.date(byAdding: .day, value: max(1, daysAhead), to: startDate) ?? startDate.addingTimeInterval(TimeInterval(daysAhead * 86400))

        var targetCalendars: [EKCalendar]? = nil
        if let calName = calendarName, !calName.isEmpty, let matched = findCalendar(named: calName) {
            targetCalendars = [matched]
        }

        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: targetCalendars)
        let events = store.events(matching: predicate).sorted {
            ($0.startDate ?? Date.distantPast) < ($1.startDate ?? Date.distantPast)
        }
        return events.map { formatCalendarEvent($0) }
    }

    public func searchEvents(query: String, daysAhead: Int) async throws -> [CalendarEventInfo] {
        try await ensureEventAccess()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now.addingTimeInterval(-7 * 86400)
        let endDate = Calendar.current.date(byAdding: .day, value: max(1, daysAhead), to: now) ?? now.addingTimeInterval(TimeInterval(daysAhead * 86400))

        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = store.events(matching: predicate).sorted {
            ($0.startDate ?? Date.distantPast) < ($1.startDate ?? Date.distantPast)
        }

        return events.compactMap { ev -> CalendarEventInfo? in
            if q.isEmpty { return formatCalendarEvent(ev) }
            let titleMatch = (ev.title ?? "").localizedCaseInsensitiveContains(q)
            let notesMatch = (ev.notes ?? "").localizedCaseInsensitiveContains(q)
            let locMatch = (ev.location ?? "").localizedCaseInsensitiveContains(q)
            if titleMatch || notesMatch || locMatch {
                return formatCalendarEvent(ev)
            }
            return nil
        }
    }

    public func updateEvent(_ draft: CalendarEventUpdateDraft) async throws -> String {
        try await ensureEventAccess()
        guard let event = store.event(withIdentifier: draft.id) else {
            throw EventStoreError.failed("Calendar event '\(draft.id)' not found")
        }

        if let title = draft.title { event.title = title }
        if let start = draft.start { event.startDate = start }
        if let end = draft.end { event.endDate = end }
        if let location = draft.location { event.location = location }
        if let notes = draft.notes { event.notes = notes }
        if let calName = draft.calendarName, let cal = findCalendar(named: calName) {
            event.calendar = cal
        }
        if let alarmMinutes = draft.alarmMinutes {
            if let existingAlarms = event.alarms {
                for a in existingAlarms { event.removeAlarm(a) }
            }
            if alarmMinutes >= 0 {
                event.addAlarm(EKAlarm(relativeOffset: -Double(alarmMinutes * 60)))
            }
        }

        let spanStr = draft.span?.lowercased() ?? "this"
        let span: EKSpan = (spanStr == "future" || spanStr == "all") ? .futureEvents : .thisEvent

        do {
            try store.save(event, span: span)
            return event.title ?? draft.id
        } catch {
            throw EventStoreError.failed(error.localizedDescription)
        }
    }

    public func deleteEvent(id: String, span: String?) async throws -> Bool {
        try await ensureEventAccess()
        guard let event = store.event(withIdentifier: id) else {
            throw EventStoreError.failed("Calendar event '\(id)' not found")
        }

        let spanStr = span?.lowercased() ?? "this"
        let ekSpan: EKSpan = (spanStr == "future" || spanStr == "all") ? .futureEvents : .thisEvent

        do {
            try store.remove(event, span: ekSpan)
            return true
        } catch {
            throw EventStoreError.failed(error.localizedDescription)
        }
    }

    public func calendars() async throws -> [CalendarInfo] {
        try await ensureEventAccess()
        let cals = store.calendars(for: .event)
        return cals.map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, allowsContentModifications: $0.allowsContentModifications)
        }
    }

    public func freebusy(start: Date, end: Date) async throws -> FreeBusyResult {
        try await ensureEventAccess()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted {
            ($0.startDate ?? Date.distantPast) < ($1.startDate ?? Date.distantPast)
        }

        var busySlots: [FreeBusySlot] = []
        var freeSlots: [FreeBusySlot] = []
        var lastEnd = start

        for ev in events {
            if ev.isAllDay { continue }
            guard let evStart = ev.startDate, let evEnd = ev.endDate else { continue }
            let s = max(evStart, start)
            let e = min(evEnd, end)
            if s >= e { continue }

            if s > lastEnd {
                freeSlots.append(FreeBusySlot(start: lastEnd, end: s))
            }

            busySlots.append(FreeBusySlot(title: ev.title, start: s, end: e))

            if e > lastEnd {
                lastEnd = e
            }
        }

        if lastEnd < end {
            freeSlots.append(FreeBusySlot(start: lastEnd, end: end))
        }

        return FreeBusyResult(start: start, end: end, busySlots: busySlots, freeSlots: freeSlots)
    }

    public func createReminder(_ draft: ReminderDraft) async throws -> String {
        try await ensureReminderAccess()
        let calendar: EKCalendar
        if let listName = draft.listName?.trimmingCharacters(in: .whitespacesAndNewlines), !listName.isEmpty {
            let calendars = store.calendars(for: .reminder)
            if let matched = calendars.first(where: {
                $0.title.lowercased() == listName.lowercased() || $0.title.localizedCaseInsensitiveContains(listName)
            }) ?? store.defaultCalendarForNewReminders() ?? calendars.first {
                calendar = matched
            } else {
                throw EventStoreError.failed("no writable reminders list")
            }
        } else {
            guard let def = store.defaultCalendarForNewReminders() else {
                throw EventStoreError.failed("no writable reminders list")
            }
            calendar = def
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = calendar
        reminder.priority = draft.priority

        if let due = draft.due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }

        if let recur = draft.recur {
            if let rule = buildRecurrenceRule(recur: recur, interval: draft.recurInterval, daysStr: draft.recurDays, count: draft.recurCount, until: draft.recurUntil) {
                reminder.recurrenceRules = [rule]
            }
        }

        #if canImport(CoreLocation)
        if let lat = draft.lat, let lng = draft.lng {
            let loc = EKStructuredLocation(title: draft.locationName ?? String(format: "%.4f,%.4f", lat, lng))
            loc.geoLocation = CLLocation(latitude: lat, longitude: lng)
            if let radius = draft.radius, radius > 0 { loc.radius = radius }
            let alarm = EKAlarm()
            alarm.structuredLocation = loc
            alarm.proximity = (draft.proximity?.lowercased() == "leave") ? .leave : .enter
            reminder.addAlarm(alarm)
        }
        #endif

        do { try store.save(reminder, commit: true) }
        catch { throw EventStoreError.failed(error.localizedDescription) }
        return reminder.calendarItemIdentifier
    }

    public func reminders(listName: String?, includeCompleted: Bool, limit: Int?) async throws -> [ReminderInfo] {
        try await ensureReminderAccess()
        var targetCalendars: [EKCalendar]? = nil
        if let name = listName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let calendars = store.calendars(for: .reminder)
            if let matched = calendars.first(where: {
                $0.title.lowercased() == name.lowercased() || $0.title.localizedCaseInsensitiveContains(name)
            }) {
                targetCalendars = [matched]
            }
        }

        let predicate: NSPredicate
        if includeCompleted {
            predicate = store.predicateForReminders(in: targetCalendars)
        } else {
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: targetCalendars)
        }

        let ekReminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { list in
                continuation.resume(returning: list ?? [])
            }
        }

        let maxCount = limit.map { max(1, $0) } ?? 50
        let sorted = ekReminders.sorted { r1, r2 in
            guard let d1 = r1.dueDateComponents?.date, let d2 = r2.dueDateComponents?.date else {
                return r1.dueDateComponents != nil
            }
            return d1 < d2
        }

        return sorted.prefix(maxCount).map { makeReminderInfo($0) }
    }

    public func updateReminder(_ draft: ReminderUpdateDraft) async throws -> String {
        try await ensureReminderAccess()
        guard let reminder = store.calendarItem(withIdentifier: draft.id) as? EKReminder else {
            throw EventStoreError.failed("reminder not found for id: \(draft.id)")
        }

        if let title = draft.title, !title.isEmpty { reminder.title = title }
        if let notes = draft.notes { reminder.notes = notes }
        if let priority = draft.priority { reminder.priority = priority }
        if let completed = draft.completed { reminder.isCompleted = completed }

        if let listName = draft.listName?.trimmingCharacters(in: .whitespacesAndNewlines), !listName.isEmpty {
            let calendars = store.calendars(for: .reminder)
            if let matched = calendars.first(where: {
                $0.title.lowercased() == listName.lowercased() || $0.title.localizedCaseInsensitiveContains(listName)
            }) {
                reminder.calendar = matched
            }
        }

        if let due = draft.due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: due)
            for alarm in (reminder.alarms ?? []) where alarm.structuredLocation == nil {
                reminder.removeAlarm(alarm)
            }
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }

        if draft.clearRecur {
            reminder.recurrenceRules = nil
        } else if let recur = draft.recur {
            if let rule = buildRecurrenceRule(recur: recur, interval: draft.recurInterval, daysStr: draft.recurDays, count: draft.recurCount, until: draft.recurUntil) {
                reminder.recurrenceRules = [rule]
            }
        }

        #if canImport(CoreLocation)
        if draft.clearLocation {
            for alarm in (reminder.alarms ?? []) where alarm.structuredLocation != nil {
                reminder.removeAlarm(alarm)
            }
        } else if let lat = draft.lat, let lng = draft.lng {
            for alarm in (reminder.alarms ?? []) where alarm.structuredLocation != nil {
                reminder.removeAlarm(alarm)
            }
            let loc = EKStructuredLocation(title: draft.locationName ?? String(format: "%.4f,%.4f", lat, lng))
            loc.geoLocation = CLLocation(latitude: lat, longitude: lng)
            if let radius = draft.radius, radius > 0 { loc.radius = radius }
            let alarm = EKAlarm()
            alarm.structuredLocation = loc
            alarm.proximity = (draft.proximity?.lowercased() == "leave") ? .leave : .enter
            reminder.addAlarm(alarm)
        }
        #endif

        do { try store.save(reminder, commit: true) }
        catch { throw EventStoreError.failed(error.localizedDescription) }
        return reminder.title ?? draft.id
    }

    public func completeReminder(id: String, completed: Bool) async throws -> Bool {
        try await ensureReminderAccess()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw EventStoreError.failed("reminder not found for id: \(id)")
        }
        reminder.isCompleted = completed
        do { try store.save(reminder, commit: true) }
        catch { throw EventStoreError.failed(error.localizedDescription) }
        return true
    }

    public func deleteReminder(id: String) async throws -> Bool {
        try await ensureReminderAccess()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw EventStoreError.failed("reminder not found for id: \(id)")
        }
        do { try store.remove(reminder, commit: true) }
        catch { throw EventStoreError.failed(error.localizedDescription) }
        return true
    }

    public func reminderLists() async throws -> [ReminderListInfo] {
        try await ensureReminderAccess()
        let defaultCalendar = store.defaultCalendarForNewReminders()
        return store.calendars(for: .reminder).map { cal in
            ReminderListInfo(id: cal.calendarIdentifier, title: cal.title, isDefault: cal == defaultCalendar)
        }
    }

    // MARK: - Helpers

    private func makeReminderInfo(_ r: EKReminder) -> ReminderInfo {
        var locName: String? = nil
        for a in r.alarms ?? [] {
            if let loc = a.structuredLocation {
                locName = loc.title
                break
            }
        }
        let recurStr = r.recurrenceRules?.first.map { ruleDescription($0) }
        return ReminderInfo(
            id: r.calendarItemIdentifier,
            title: r.title ?? "(untitled)",
            isCompleted: r.isCompleted,
            due: r.dueDateComponents?.date,
            priority: r.priority,
            notes: r.notes,
            listName: r.calendar?.title,
            locationName: locName,
            recurrenceSummary: recurStr
        )
    }

    private func buildRecurrenceRule(recur: String, interval: Int?, daysStr: String?, count: Int?, until: Date?) -> EKRecurrenceRule? {
        let freq: EKRecurrenceFrequency
        switch recur.lowercased() {
        case "daily", "day": freq = .daily
        case "weekly", "week": freq = .weekly
        case "monthly", "month": freq = .monthly
        case "yearly", "year", "annually": freq = .yearly
        default: return nil
        }

        var days: [EKRecurrenceDayOfWeek]? = nil
        if let daysStr {
            var parsed: [EKRecurrenceDayOfWeek] = []
            for tok in daysStr.components(separatedBy: ",") {
                let t = tok.trimmingCharacters(in: .whitespaces).lowercased()
                if t.hasPrefix("su") { parsed.append(EKRecurrenceDayOfWeek(.sunday)) }
                else if t.hasPrefix("mo") { parsed.append(EKRecurrenceDayOfWeek(.monday)) }
                else if t.hasPrefix("tu") { parsed.append(EKRecurrenceDayOfWeek(.tuesday)) }
                else if t.hasPrefix("we") { parsed.append(EKRecurrenceDayOfWeek(.wednesday)) }
                else if t.hasPrefix("th") { parsed.append(EKRecurrenceDayOfWeek(.thursday)) }
                else if t.hasPrefix("fr") { parsed.append(EKRecurrenceDayOfWeek(.friday)) }
                else if t.hasPrefix("sa") { parsed.append(EKRecurrenceDayOfWeek(.saturday)) }
            }
            if !parsed.isEmpty { days = parsed }
        }

        var end: EKRecurrenceEnd? = nil
        if let until {
            end = EKRecurrenceEnd(end: until)
        } else if let count, count > 0 {
            end = EKRecurrenceEnd(occurrenceCount: count)
        }

        return EKRecurrenceRule(
            recurrenceWith: freq,
            interval: max(1, interval ?? 1),
            daysOfTheWeek: days,
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }

    private func ruleDescription(_ rule: EKRecurrenceRule) -> String {
        let freq: String = switch rule.frequency {
        case .daily: "daily"
        case .weekly: "weekly"
        case .monthly: "monthly"
        case .yearly: "yearly"
        @unknown default: "recurring"
        }
        if rule.interval > 1 {
            return "every \(rule.interval) \(freq)"
        }
        return freq
    }
}
#endif
