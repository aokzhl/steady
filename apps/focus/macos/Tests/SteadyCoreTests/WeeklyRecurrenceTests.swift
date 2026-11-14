import Foundation
import SteadyCore
import Testing

@MainActor
struct WeeklyRecurrenceTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test func partialWeekHasOneUndatedOccurrenceAndMondayStartsFreshWithoutDebt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = try Date("2026-11-15T23:59:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let first = try workspace.createTask(title: "Прогулка", recurrence: .weekly)
        #expect(first.seriesDay == "2026-11-09")
        #expect(first.periodEnd == "2026-11-15")
        #expect(first.plannedDay == nil)
        #expect(workspace.openToday.map(\.occurrenceID) == [first.occurrenceID])
        #expect(workspace.visibleTasks.map(\.occurrenceID) == [first.occurrenceID])
        #expect(workspace.currentWeekTasks.map(\.occurrenceID) == [first.occurrenceID])
        #expect(try workspace.occurrences(from: "2026-11-09", through: "2026-11-15").count == 1)
        instant = try Date("2026-11-16T00:00:00Z", strategy: .iso8601)
        try workspace.reload()
        let next = try #require(workspace.openToday.first)
        #expect(next.seriesDay == "2026-11-16")
        #expect(next.occurrenceID != first.occurrenceID)
        #expect(workspace.openToday.count == 1)
        #expect(workspace.tasks.first { $0.occurrenceID == first.occurrenceID }?.completedAt == nil)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.tasks == workspace.tasks)
        #expect(Set(reopened.tasks.map(\.occurrenceID)).count == reopened.tasks.count)
    }
    @Test func schedulingStaysWithinOwnWeekAndCanBeClearedAfterReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = try Date("2026-11-12T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let first = try workspace.createTask(title: "Прогулка", recurrence: .weekly)
        try workspace.setPlannedDay(occurrenceID: first.occurrenceID, day: "2026-11-15")
        #expect(workspace.openToday.isEmpty)
        #expect(throws: WorkspaceError.outsideOccurrenceWeek) {
            try workspace.setPlannedDay(occurrenceID: first.occurrenceID, day: "2026-11-16")
        }
        #expect(throws: WorkspaceError.outsideOccurrenceWeek) {
            try workspace.setPlannedDay(occurrenceID: first.occurrenceID, day: "2026-11-08")
        }
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.tasks.first { $0.occurrenceID == first.occurrenceID }?.plannedDay == "2026-11-15")
        try reopened.setPlannedDay(occurrenceID: first.occurrenceID, day: nil)
        #expect(reopened.openToday.map(\.occurrenceID) == [first.occurrenceID])
        #expect(reopened.tasks.filter { $0.seriesDay == "2026-11-09" }.count == 1)
    }

    @Test func explicitSkipIsDurableDistinctFromCompletionAndNewWeekIsOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = try Date("2026-11-15T12:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let first = try workspace.createTask(title: "Прогулка", recurrence: .weekly)
        try workspace.setSkipped(occurrenceID: first.occurrenceID, skipped: true)
        #expect(workspace.openToday.isEmpty)
        #expect(workspace.completedToday.isEmpty)
        let saved = try #require(workspace.tasks.first { $0.occurrenceID == first.occurrenceID })
        #expect(saved.skippedAt == instant)
        #expect(saved.completedAt == nil)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.tasks == workspace.tasks)
        try reopened.setSkipped(occurrenceID: first.occurrenceID, skipped: false)
        #expect(reopened.openToday.count == 1)
        try reopened.setSkipped(occurrenceID: first.occurrenceID, skipped: true)
        instant = try Date("2026-11-16T00:00:00Z", strategy: .iso8601)
        try reopened.reload()
        #expect(reopened.openToday.count == 1)
        #expect(reopened.openToday.first?.skippedAt == nil)
        #expect(reopened.tasks.first { $0.occurrenceID == first.occurrenceID }?.skippedAt == saved.skippedAt)
    }

    @Test func changingDailyToWeeklyReplacesUntouchedDailyCopiesButPreservesFactsAndMoves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = try Date("2026-11-09T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let first = try workspace.createTask(title: "Читать", recurrence: .daily)
        let days = try workspace.occurrences(from: "2026-11-09", through: "2026-11-15")
        let completed = try #require(days.first { $0.seriesDay == "2026-11-10" })
        let worked = try #require(days.first { $0.seriesDay == "2026-11-11" })
        let moved = try #require(days.first { $0.seriesDay == "2026-11-12" })
        try workspace.setCompleted(occurrenceID: completed.occurrenceID, completed: true)
        try workspace.startStopwatch(occurrenceID: worked.occurrenceID)
        instant = instant.addingTimeInterval(30)
        try workspace.stopSession()
        try workspace.setPlannedDay(occurrenceID: moved.occurrenceID, day: "2026-11-15")
        try workspace.setRecurrence(occurrenceID: first.occurrenceID, recurrence: .weekly)
        let week = try workspace.occurrences(from: "2026-11-09", through: "2026-11-15")
        #expect(week.count == 4)
        #expect(week.filter { $0.periodEnd == "2026-11-15" }.count == 1)
        #expect(week.first { $0.occurrenceID == completed.occurrenceID }?.completedAt != nil)
        #expect(week.first { $0.occurrenceID == moved.occurrenceID }?.plannedDay == "2026-11-15")
        #expect(workspace.timeToolResults.first?.occurrenceID == worked.occurrenceID)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.tasks == workspace.tasks)
        #expect(reopened.timeToolResults == workspace.timeToolResults)
    }

    @Test func weeklyConversionDoesNotLoseCompletedMondayOrHideNewWeeklyOccurrence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = try Date("2026-11-09T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let first = try workspace.createTask(title: "Читать", recurrence: .daily)
        try workspace.setCompleted(occurrenceID: first.occurrenceID, completed: true)
        try workspace.setRecurrence(occurrenceID: first.occurrenceID, recurrence: .weekly)
        #expect(workspace.tasks.first { $0.occurrenceID == first.occurrenceID }?.completedAt == instant)
        let current = try #require(workspace.openToday.first)
        #expect(current.periodEnd == "2026-11-15")
        #expect(current.occurrenceID != first.occurrenceID)
        #expect(workspace.visibleTasks.map(\.occurrenceID) == [current.occurrenceID])
    }

    @Test func oldWeeklyStopwatchKeepsItsUTCIdentityWhileNewPeriodAdoptsMacZone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = try Date("2026-11-15T23:59:00Z", strategy: .iso8601)
        var zoneCalendar = calendar
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { zoneCalendar })
        let first = try workspace.createTask(title: "Прогулка", recurrence: .weekly)
        try workspace.startStopwatch(occurrenceID: first.occurrenceID)
        let runID = try #require(workspace.activeSession?.id)
        instant = try Date("2026-11-17T00:00:00Z", strategy: .iso8601)
        zoneCalendar.timeZone = TimeZone(identifier: "Asia/Almaty")!
        try workspace.reload()
        let next = try #require(workspace.openToday.first)
        #expect(next.seriesDay == "2026-11-16")
        #expect(next.timeZoneIdentifier == "Asia/Almaty")
        #expect(workspace.activeSession?.id == runID)
        #expect(workspace.activeSession?.occurrenceID == first.occurrenceID)
        try workspace.stopSession()
        let result = try #require(workspace.timeToolResults.first)
        #expect(result.occurrenceID == first.occurrenceID)
        #expect(result.segments.first?.startedAt == Date(timeIntervalSince1970: 1794787140))
        #expect(result.durationSeconds == 86460)
        #expect(result.timeZoneIdentifier == "GMT")
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { zoneCalendar })
        #expect(reopened.timeToolResults == [result])
        #expect(reopened.tasks.first { $0.occurrenceID == first.occurrenceID }?.timeZoneIdentifier == "GMT")
        #expect(reopened.openToday.first?.occurrenceID == next.occurrenceID)
    }

}
