import Foundation
import SteadyCore
import Testing

@MainActor
struct CalendarTests {
    @Test func calendarUsesTheSameOccurrencesAndSeparatesUndatedWeeklyAndDatedTasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = ISO8601DateFormatter().date(from: "2026-11-14T10:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let task = try workspace.createTask(title: "Dated", plannedDay: "2026-11-14")
        let undated = try workspace.createTask(title: "Undated")
        let weekly = try workspace.createTask(title: "Weekly", recurrence: .weekly, seriesStart: "2026-11-09")
        let context = TaskListContext(period: .all)
        try workspace.prepareCalendar(month: "2026-11-01")
        let month = workspace.taskCalendar(month: "2026-11-01", in: context)
        #expect(month.days.count == 30)
        #expect(month.days.first?.day == "2026-11-01")
        #expect(month.days.last?.day == "2026-11-30")
        #expect(month.days.flatMap(\.tasks).map(\.occurrenceID) == [task.occurrenceID])
        #expect(month.undated.map(\.occurrenceID) == [undated.occurrenceID])
        #expect(month.weekly.contains { $0.occurrenceID == weekly.occurrenceID })
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let completed = reopened.taskCalendar(month: "2026-11-01", in: TaskListContext(period: .completed))
        #expect(completed.days.flatMap(\.tasks).map(\.occurrenceID) == [task.occurrenceID])
        #expect(completed.days.flatMap(\.tasks).first?.completedAt != nil)
    }

    @Test func calendarCombinesContextAndPeriodWithoutCountingParentContextOrCollapsingSeries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = ISO8601DateFormatter().date(from: "2026-11-14T10:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"), now: { instant }, calendar: { calendar })
        let project = try workspace.createProject(title: "Work")
        let label = try workspace.createLabel(title: "Read")
        let parent = try workspace.createTask(title: "Parent", projectID: project.id, plannedDay: "2026-11-14")
        let child = try workspace.addSubtask(parentOccurrenceID: parent.occurrenceID, title: "Read", labelIDs: [label.id])
        _ = try workspace.createTask(title: "Other", plannedDay: "2026-11-14", labelIDs: [label.id])
        let daily = try workspace.createTask(title: "Daily", recurrence: .daily, seriesStart: "2026-11-14")
        try workspace.prepareCalendar(month: "2026-11-01")
        let context = TaskListContext(projectID: project.id, labelIDs: [label.id], period: .today)
        #expect(workspace.taskCalendar(month: "2026-11-01", in: context).days.flatMap(\.tasks).map(\.occurrenceID) == [child.occurrenceID])
        #expect(workspace.taskCalendar(month: "2026-11-01", in: TaskListContext(period: .all)).days.flatMap(\.tasks).filter { $0.id == daily.id }.count == 17)
        var december = TaskListContext(period: .month)
        december.namedMonth = "2026-12-01"
        try workspace.prepareCalendar(month: "2026-12-01")
        #expect(workspace.taskCalendar(month: "2026-12-01", in: december).days.flatMap(\.tasks).count == 31)
        #expect(workspace.taskCalendar(month: "2026-12-01", in: TaskListContext(period: .today)).days.flatMap(\.tasks).isEmpty)
        #expect(workspace.adjacentMonth("2026-12-01", offset: 1) == "2027-01-01")
        let undated = try workspace.createTask(title: "Undated done")
        try workspace.setCompleted(occurrenceID: undated.occurrenceID, completed: true)
        #expect(workspace.taskCalendar(month: "2026-11-01", in: TaskListContext(period: .completed)).undated.map(\.occurrenceID) == [undated.occurrenceID])
    }

    @Test func genuineVersionThirteenPreferencesKeepContextSelectionDraftAndTimeFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("steady.sqlite")
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/workspace-v13.sql")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        fixture.arguments = [url.path]
        let input = try FileHandle(forReadingFrom: fixtureURL)
        defer { try? input.close() }
        fixture.standardInput = input
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        let instant = ISO8601DateFormatter().date(from: "2026-11-14T10:00:00Z")!
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let saved = workspace.preferences
        #expect(saved.presentation == .list)
        #expect(saved.calendarMonth == nil)
        #expect(saved.context.projectID?.uuidString == "4A110597-C94C-4EE9-A549-9685C231610B")
        #expect(saved.context.period == .month)
        #expect(saved.context.namedMonth == nil)
        #expect(saved.context.labelIDs.isEmpty)
        #expect(saved.selectedOccurrenceID?.uuidString == "71DC2F77-4060-489F-8D8F-98965B77B9C4")
        #expect(saved.detailsVisible)
        #expect(!saved.sidebarVisible)
        #expect(saved.expandedParentIDs.map(\.uuidString) == ["84E1C3DF-FAFA-4DD3-9EBD-DF1554E9DABA"])
        #expect(workspace.creationDraft?.title == "Legacy draft")
        #expect(workspace.creationDraft?.children.first?.title == "Legacy child")
        #expect(workspace.timeToolResults.count == 1)
        #expect(workspace.timeToolResults.first?.durationSeconds == 30)
        let tasks = workspace.tasks
        let draft = workspace.creationDraft
        let facts = workspace.timeToolResults
        var calendarPreferences = saved
        calendarPreferences.presentation = .calendar
        calendarPreferences.calendarMonth = "2026-12-01"
        calendarPreferences.calendarDay = "2026-12-12"
        calendarPreferences.context.namedMonth = "2026-12-01"
        try workspace.savePreferences(calendarPreferences)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.preferences == calendarPreferences)
        #expect(reopened.tasks == tasks)
        #expect(reopened.creationDraft == draft)
        #expect(reopened.timeToolResults == facts)
    }

    @Test func creatingAndChangingSeriesKeepThePreparedMonthCompleteWithoutRenavigation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = ISO8601DateFormatter().date(from: "2026-11-14T10:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"), now: { instant }, calendar: { calendar })
        try workspace.prepareCalendar(month: "2026-11-01")
        try workspace.saveCreationDraft(CreationDraft(title: "New daily", recurrence: .daily, seriesStart: "2026-11-14"))
        let task = try workspace.createTaskFromDraft()
        let firstMonth = workspace.taskCalendar(month: "2026-11-01", in: TaskListContext(period: .all))
        #expect(firstMonth.days.flatMap(\.tasks).count == 17)
        #expect(firstMonth.days.last?.tasks.first?.plannedDay == "2026-11-30")
        #expect(workspace.creationDraft == nil)
        #expect(throws: WorkspaceError.emptyTitle) { try workspace.createTaskFromDraft() }
        try workspace.setRecurrence(occurrenceID: task.occurrenceID, recurrence: .weekdays)
        #expect(workspace.taskCalendar(month: "2026-11-01", in: TaskListContext(period: .all)).days.flatMap(\.tasks).count == 11)
        let weekday = try #require(workspace.tasks.first { $0.id == task.id })
        try workspace.setRecurrence(occurrenceID: weekday.occurrenceID, recurrence: .daily)
        #expect(workspace.taskCalendar(month: "2026-11-01", in: TaskListContext(period: .all)).days.flatMap(\.tasks).count == 15)
        var december = TaskListContext(period: .month)
        december.namedMonth = "2026-12-01"
        try workspace.prepareTaskList(in: december)
        let second = try workspace.createTask(title: "December daily", recurrence: .daily, seriesStart: "2026-12-01")
        #expect(workspace.taskList(in: december).matches.filter { $0.id == second.id }.count == 31)
    }

    @Test func calendarSearchUsesTheSameTitleAndNoteMatchesAcrossDatedAndSeparateBuckets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = ISO8601DateFormatter().date(from: "2026-11-14T10:00:00Z")!
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"), now: { instant })
        let dated = try workspace.createTask(title: "Dated", plannedDay: workspace.today, note: TaskNote(plainText: "Calendar needle"))
        let undated = try workspace.createTask(title: "Needle undated")
        let weekly = try workspace.createTask(title: "Needle weekly", recurrence: .weekly, seriesStart: "2026-11-09")
        _ = try workspace.createTask(title: "Unrelated", plannedDay: workspace.today)
        try workspace.prepareCalendar(month: "2026-11-01")
        let result = workspace.taskCalendar(month: "2026-11-01", in: TaskListContext(period: .all), searchQuery: "NEEDLE")
        #expect(result.days.flatMap(\.tasks).map(\.occurrenceID) == [dated.occurrenceID])
        #expect(result.undated.map(\.occurrenceID) == [undated.occurrenceID])
        #expect(result.weekly.contains { $0.occurrenceID == weekly.occurrenceID })
        let empty = workspace.taskCalendar(month: "2026-11-01", in: TaskListContext(period: .all), searchQuery: "absent")
        #expect(empty.days.flatMap(\.tasks).isEmpty)
        #expect(empty.undated.isEmpty)
        #expect(empty.weekly.isEmpty)
    }
}
