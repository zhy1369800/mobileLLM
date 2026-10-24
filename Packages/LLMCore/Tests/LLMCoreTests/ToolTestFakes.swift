// SPDX-License-Identifier: MIT

import Foundation
import AppRuntime
@testable import LLMCore

// Shared in-memory fakes for the injectable tool seams, so the memory / calendar / location / assembly
// tests drive the tools without touching disk, EventKit, or CoreLocation (no permission prompts).

/// A `MemoryStoring` backed by an array. Insertion order preserved; no persistence. `search` is left to
/// the protocol's default (rank over `list()`), which is what the real store does too.
actor FakeMemoryStore: MemoryStoring {
    private(set) var facts: [MemoryFact]
    init(_ seed: [MemoryFact] = []) { facts = seed }

    @discardableResult func save(_ text: String, source: MemoryFact.Source) -> MemoryFact {
        let fact = MemoryFact(text: text.trimmingCharacters(in: .whitespacesAndNewlines), source: source)
        facts.append(fact)
        return fact
    }
    @discardableResult func saveIfAbsent(_ text: String,
                                         source: MemoryFact.Source) -> MemorySaveResult {
        saveIfAbsent(text, source: source, sourceText: nil)
    }
    @discardableResult func saveIfAbsent(_ text: String, source: MemoryFact.Source,
                                         sourceText: String?) -> MemorySaveResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = MemoryDeduplication.key(trimmed)
        if let existing = facts.first(where: { MemoryDeduplication.key($0.text) == key }) {
            return .duplicate(existing)
        }
        let fact = MemoryFact(text: trimmed, source: source, sourceText: sourceText)
        facts.append(fact)
        return .saved(fact)
    }
    func list() -> [MemoryFact] { facts }
    func update(id: String, text: String) {
        guard let i = facts.firstIndex(where: { $0.id == id }) else { return }
        let old = facts[i]
        facts[i] = MemoryFact(id: old.id, text: text, createdAt: old.createdAt, source: old.source)
    }
    func delete(id: String) { facts.removeAll { $0.id == id } }
    func deleteAll() { facts.removeAll() }
}

/// An `EventStoring` that records drafts and can simulate access denial. Reads happen via actor awaits.
actor FakeEventStore: EventStoring {
    private(set) var createdEvents: [CalendarEventDraft] = []
    private(set) var updatedEvents: [CalendarEventUpdateDraft] = []
    private(set) var deletedEventIDs: [(id: String, span: String?)] = []
    private(set) var createdReminders: [ReminderDraft] = []
    private(set) var updatedReminders: [ReminderUpdateDraft] = []
    private(set) var completedReminderIDs: [(id: String, completed: Bool)] = []
    private(set) var deletedReminderIDs: [String] = []
    private(set) var lastDaysAhead: Int?
    private(set) var lastCalendarName: String?
    private let toReturn: [CalendarEventInfo]
    private let calendarsToReturn: [CalendarInfo]
    private let freeBusyToReturn: FreeBusyResult?
    private let remindersToReturn: [ReminderInfo]
    private let listsToReturn: [ReminderListInfo]
    private let denyCalendar: Bool
    private let denyReminders: Bool

    init(events: [CalendarEventInfo] = [],
         calendars: [CalendarInfo] = [],
         freebusy: FreeBusyResult? = nil,
         reminders: [ReminderInfo] = [],
         lists: [ReminderListInfo] = [],
         denyCalendar: Bool = false,
         denyReminders: Bool = false) {
        toReturn = events
        calendarsToReturn = calendars
        freeBusyToReturn = freebusy
        remindersToReturn = reminders
        listsToReturn = lists
        self.denyCalendar = denyCalendar
        self.denyReminders = denyReminders
    }

    func createEvent(_ draft: CalendarEventDraft) throws -> String {
        if denyCalendar { throw EventStoreError.calendarAccessDenied }
        createdEvents.append(draft); return draft.title
    }
    func events(daysAhead: Int, calendarName: String?) throws -> [CalendarEventInfo] {
        if denyCalendar { throw EventStoreError.calendarAccessDenied }
        lastDaysAhead = daysAhead
        lastCalendarName = calendarName
        if let cal = calendarName, !cal.isEmpty {
            return toReturn.filter { $0.calendar?.lowercased() == cal.lowercased() }
        }
        return toReturn
    }
    func searchEvents(query: String, daysAhead: Int) throws -> [CalendarEventInfo] {
        if denyCalendar { throw EventStoreError.calendarAccessDenied }
        return toReturn.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            ($0.notes ?? "").localizedCaseInsensitiveContains(query) ||
            ($0.location ?? "").localizedCaseInsensitiveContains(query)
        }
    }
    func updateEvent(_ draft: CalendarEventUpdateDraft) throws -> String {
        if denyCalendar { throw EventStoreError.calendarAccessDenied }
        updatedEvents.append(draft)
        return draft.title ?? draft.id
    }
    func deleteEvent(id: String, span: String?) throws -> Bool {
        if denyCalendar { throw EventStoreError.calendarAccessDenied }
        deletedEventIDs.append((id: id, span: span))
        return true
    }
    func calendars() throws -> [CalendarInfo] {
        if denyCalendar { throw EventStoreError.calendarAccessDenied }
        return calendarsToReturn
    }
    func freebusy(start: Date, end: Date) throws -> FreeBusyResult {
        if denyCalendar { throw EventStoreError.calendarAccessDenied }
        return freeBusyToReturn ?? FreeBusyResult(start: start, end: end)
    }
    func createReminder(_ draft: ReminderDraft) throws -> String {
        if denyReminders { throw EventStoreError.reminderAccessDenied }
        createdReminders.append(draft); return "rem-id-\(createdReminders.count)"
    }
    func reminders(listName: String?, includeCompleted: Bool, limit: Int?) throws -> [ReminderInfo] {
        if denyReminders { throw EventStoreError.reminderAccessDenied }
        var res = remindersToReturn
        if let listName, !listName.isEmpty {
            res = res.filter { $0.listName?.lowercased() == listName.lowercased() }
        }
        if !includeCompleted {
            res = res.filter { !$0.isCompleted }
        }
        if let limit {
            res = Array(res.prefix(limit))
        }
        return res
    }
    func updateReminder(_ draft: ReminderUpdateDraft) throws -> String {
        if denyReminders { throw EventStoreError.reminderAccessDenied }
        updatedReminders.append(draft)
        return draft.title ?? draft.id
    }
    func completeReminder(id: String, completed: Bool) throws -> Bool {
        if denyReminders { throw EventStoreError.reminderAccessDenied }
        completedReminderIDs.append((id: id, completed: completed))
        return true
    }
    func deleteReminder(id: String) throws -> Bool {
        if denyReminders { throw EventStoreError.reminderAccessDenied }
        deletedReminderIDs.append(id)
        return true
    }
    func reminderLists() throws -> [ReminderListInfo] {
        if denyReminders { throw EventStoreError.reminderAccessDenied }
        return listsToReturn
    }
}

/// A `LocationProviding` that returns a canned result.
struct FakeLocationProvider: LocationProviding {
    let result: Result<LocationFix, LocationError>
    func currentLocation() async throws -> LocationFix { try result.get() }
}
