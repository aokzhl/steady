import Foundation
import SteadyCore
import Testing

@MainActor
struct RecurrenceTests {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func dailyOccurrencesAreIndependentStableAndMissedDaysCreateNoDebt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let task = try workspace.createTask(title: "Читать", recurrence: .daily, seriesStart: "2026-11-12")
        #expect(workspace.tasks.map(\.plannedDay) == ["2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15"])
        #expect(workspace.openToday.map(\.plannedDay) == ["2026-11-14"])
        let today = try #require(workspace.openToday.first)
        try workspace.setCompleted(occurrenceID: today.occurrenceID, completed: true)
        instant = try Date("2026-11-15T10:00:00Z", strategy: .iso8601)
        try workspace.reload()
        #expect(workspace.openToday.map(\.plannedDay) == ["2026-11-15"])
        #expect(workspace.visibleTasks.count == 1)
        let records = workspace.tasks
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.tasks == records)
        #expect(Set(records.map(\.occurrenceID)).count == records.count)
        #expect(records.allSatisfy { $0.id == task.id })
    }
    @Test func thisAndFutureEditPreservesCompletedActualWorkAndIndividualMoves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let task = try workspace.createTask(title: "Серия", recurrence: .daily, seriesStart: "2026-11-12")
        let all = try workspace.occurrences(from: "2026-11-12", through: "2026-11-20")
        let completed = try #require(all.first { $0.plannedDay == "2026-11-15" })
        let worked = try #require(all.first { $0.plannedDay == "2026-11-17" })
        let moved = try #require(all.first { $0.plannedDay == "2026-11-18" })
        let removed = try #require(all.first { $0.plannedDay == "2026-11-19" })
        try workspace.setCompleted(occurrenceID: completed.occurrenceID, completed: true)
        try workspace.startStopwatch(occurrenceID: worked.occurrenceID)
        instant = instant.addingTimeInterval(45)
        try workspace.stopSession()
        let result = try #require(workspace.timeToolResults.first)
        try workspace.setPlannedDay(occurrenceID: moved.occurrenceID, day: "2026-11-16")
        try workspace.setRecurrence(occurrenceID: task.occurrenceID, recurrence: .selectedWeekdays([2]))
        #expect(workspace.tasks.contains { $0.occurrenceID == completed.occurrenceID && $0.completedAt != nil })
        #expect(workspace.tasks.contains { $0.occurrenceID == worked.occurrenceID })
        #expect(workspace.tasks.contains { $0.occurrenceID == moved.occurrenceID && $0.plannedDay == "2026-11-16" })
        #expect(!workspace.tasks.contains { $0.occurrenceID == removed.occurrenceID })
        #expect(workspace.tasks.filter { $0.plannedDay == "2026-11-16" }.count == 2)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.timeToolResults == [result])
        #expect(reopened.tasks == workspace.tasks)
        #expect(reopened.tasks.contains { $0.plannedDay == "2026-11-12" })
    }

    @Test func weekdaysAndSelectedDaysUseCalendarDatesAcrossDSTAndNewZones() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = try Date("2026-03-07T17:00:00Z", strategy: .iso8601)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let weekdays = try workspace.createTask(title: "Будни", recurrence: .weekdays)
        #expect(weekdays.seriesStart == "2026-03-07")
        #expect(weekdays.plannedDay == "2026-03-09")
        let selected = try workspace.createTask(title: "Выходные", recurrence: .selectedWeekdays([1, 7]), seriesStart: "2026-03-07")
        let days = try workspace.occurrences(from: "2026-03-07", through: "2026-03-09").filter { $0.id == selected.id }
        #expect(days.map(\.plannedDay) == ["2026-03-07", "2026-03-08"])
        #expect(Set(days.map(\.occurrenceID)).count == 2)
        instant = try Date("2026-03-14T01:00:00Z", strategy: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Asia/Almaty")!
        try workspace.reload()
        #expect(workspace.openToday.map(\.plannedDay) == ["2026-03-14"])
        #expect(workspace.tasks.first { $0.occurrenceID == selected.occurrenceID }?.timeZoneIdentifier == "America/New_York")
        #expect(workspace.tasks.first { $0.id == selected.id && $0.plannedDay == "2026-03-14" }?.timeZoneIdentifier == "Asia/Almaty")
        #expect(try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar }).tasks == workspace.tasks)
    }

    @Test func sharedFieldsAndRecurringDraftSurviveReopenAndRemainIsolated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { Self.utcCalendar })
        let project = try workspace.createProject(title: "Книги")
        let label = try workspace.createLabel(title: "Чтение")
        let note = TaskNote(rtf: Data([0, 255, 123, 92]), plainText: "Общая заметка")
        try workspace.saveCreationDraft(CreationDraft(title: "Читать", priority: .high, projectID: project.id, projectWasChosen: true, plannedDay: "2026-12-01", dayWasChosen: true, note: note, labelIDs: [label.id], labelsWereChosen: true, recurrence: .selectedWeekdays([2, 6]), seriesStart: "2026-11-13"))
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { Self.utcCalendar })
        #expect(reopened.creationDraft == workspace.creationDraft)
        try reopened.prepareCreationDraft(plannedDay: "2026-11-30")
        #expect(reopened.creationDraft?.seriesStart == "2026-11-13")
        let task = try reopened.createTaskFromDraft()
        try reopened.setPriority(id: task.id, priority: .low)
        try reopened.renameTask(id: task.id, title: "Прочитать")
        try reopened.setNote(id: task.id, note: TaskNote(plainText: "Новая"))
        #expect(reopened.tasks.allSatisfy { $0.title == "Прочитать" && $0.priority == .low && $0.projectID == project.id && $0.note.plainText == "Новая" && $0.labelIDs == [label.id] })
        #expect(reopened.creationDraft == nil)
        #expect(try TaskWorkspace(databaseURL: directory.appendingPathComponent("other.sqlite"), now: { instant }, calendar: { Self.utcCalendar }).tasks.isEmpty)
    }

    @Test func invalidRulesAndDatesLeaveSeriesAndDraftIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { Self.utcCalendar })
        let task = try workspace.createTask(title: "План", recurrence: .daily)
        let saved = workspace.tasks
        #expect(throws: WorkspaceError.invalidRecurrence) { try workspace.setRecurrence(occurrenceID: task.occurrenceID, recurrence: .selectedWeekdays([])) }
        #expect(throws: WorkspaceError.invalidRecurrence) { try workspace.createTask(title: "Нет", recurrence: .selectedWeekdays([0, 8])) }
        #expect(throws: WorkspaceError.invalidDay) { try workspace.createTask(title: "Нет", recurrence: .daily, seriesStart: "2026-02-30") }
        #expect(throws: WorkspaceError.invalidRecurrence) { try workspace.saveCreationDraft(CreationDraft(title: "Нет", recurrence: .selectedWeekdays([]))) }
        #expect(throws: WorkspaceError.occurrenceNotFound) { try workspace.setRecurrence(occurrenceID: UUID(), recurrence: .daily) }
        #expect(try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { Self.utcCalendar }).tasks == saved)
        #expect(workspace.creationDraft == nil)
    }

    @Test func convertingUndatedTaskToSeriesGivesItACurrentOccurrence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"), now: { instant }, calendar: { Self.utcCalendar })
        let task = try workspace.createTask(title: "Раньше без даты")
        try workspace.setRecurrence(occurrenceID: task.occurrenceID, recurrence: .daily)
        #expect(workspace.openToday.first?.occurrenceID == task.occurrenceID)
        #expect(workspace.openToday.first?.plannedDay == "2026-11-14")
    }

    @Test func failingSeriesSaveRollsBackAndRetryPreservesOccurrenceIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: moved) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { Self.utcCalendar })
        let task = try workspace.createTask(title: "Серия", recurrence: .daily)
        let saved = workspace.tasks
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        #expect(throws: (any Error).self) { try workspace.setRecurrence(occurrenceID: task.occurrenceID, recurrence: .weekdays) }
        #expect(workspace.tasks == saved)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        #expect(try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { Self.utcCalendar }).tasks == saved)
        try workspace.setRecurrence(occurrenceID: task.occurrenceID, recurrence: .weekdays)
        #expect(workspace.visibleTasks.first?.plannedDay == "2026-11-16")
        #expect(try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { Self.utcCalendar }).tasks == workspace.tasks)
    }

    @Test func establishedHistoricalZoneDoesNotChangeWhenTheClockMovesBackward() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = try Date("2026-11-14T01:00:00Z", strategy: .iso8601)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Almaty")!
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let original = try workspace.createTask(title: "Серия", recurrence: .daily)
        instant = try Date("2026-11-13T23:00:00Z", strategy: .iso8601)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        try workspace.reload()
        #expect(workspace.tasks.first { $0.occurrenceID == original.occurrenceID }?.timeZoneIdentifier == "Asia/Almaty")
        #expect(workspace.tasks.first { $0.plannedDay == "2026-11-15" }?.timeZoneIdentifier == "America/New_York")
    }

    @Test func distantFutureSeriesShowsOnlyItsNearestOccurrence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"), now: { instant }, calendar: { Self.utcCalendar })
        let task = try workspace.createTask(title: "В новом году", recurrence: .weekdays, seriesStart: "2027-01-02")
        #expect(task.plannedDay == "2027-01-04")
        #expect(workspace.visibleTasks == [task])
        #expect(workspace.tasks == [task])
        #expect(workspace.openToday.isEmpty)
    }

    @Test(arguments: [5, 6, 7]) func existingOneOffDraftAndTimeFactsMigrateWithoutChangingIdentity(version: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("steady.sqlite")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        fixture.arguments = [url.path, """
            CREATE TABLE projects (id TEXT PRIMARY KEY, title TEXT, color TEXT, created_at REAL);
            CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, created_at REAL, priority TEXT, project_id TEXT, note_rtf BLOB, note_text TEXT);
            CREATE TABLE task_occurrences (id TEXT PRIMARY KEY, task_id TEXT, planned_day TEXT, time_zone TEXT, completed_at REAL);
            CREATE TABLE creation_draft (id INTEGER PRIMARY KEY, title TEXT, priority TEXT, project_id TEXT, project_was_chosen INTEGER, note_rtf BLOB, note_text TEXT, planned_day TEXT, day_was_chosen INTEGER);
            INSERT INTO projects VALUES ('33333333-3333-3333-3333-333333333333', 'Проект', 'blue', 1);
            INSERT INTO tasks VALUES ('11111111-1111-1111-1111-111111111111', 'Старое дело', 1, 'high', '33333333-3333-3333-3333-333333333333', X'00FF', 'Заметка');
            INSERT INTO task_occurrences VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', NULL, 'Asia/Almaty', 1800000000.25);
            INSERT INTO creation_draft VALUES (1, 'Черновик', 'low', NULL, 1, X'00FE', 'Текст', '2026-12-01', 1);
            \(version >= 6 ? "CREATE TABLE time_tool_runs (id TEXT PRIMARY KEY, kind TEXT, task_id TEXT, occurrence_id TEXT, owner_title TEXT, started_at REAL, time_zone TEXT, stopped_at REAL); CREATE TABLE time_tool_segments (id TEXT PRIMARY KEY, run_id TEXT, position INTEGER, started_at REAL, ended_at REAL); CREATE UNIQUE INDEX one_active_time_tool ON time_tool_runs ((1)) WHERE stopped_at IS NULL; INSERT INTO time_tool_runs VALUES ('44444444-4444-4444-4444-444444444444', 'stopwatch', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'Старое дело', 1799999900, 'Asia/Almaty', 1799999960); INSERT INTO time_tool_segments VALUES ('55555555-5555-5555-5555-555555555555', '44444444-4444-4444-4444-444444444444', 0, 1799999900, 1799999960);" : "")
            \(version == 7 ? "CREATE TABLE labels (id TEXT PRIMARY KEY, title TEXT, title_key TEXT, color TEXT, created_at REAL, deleted_at REAL, deletion_order INTEGER); CREATE UNIQUE INDEX active_label_title ON labels(title_key) WHERE deleted_at IS NULL; CREATE TABLE task_labels (task_id TEXT, label_id TEXT, PRIMARY KEY(task_id, label_id)); CREATE TABLE draft_labels (draft_id INTEGER, label_id TEXT, PRIMARY KEY(draft_id, label_id)); ALTER TABLE creation_draft ADD COLUMN labels_were_chosen INTEGER NOT NULL DEFAULT 0; INSERT INTO labels VALUES ('66666666-6666-6666-6666-666666666666', 'Метка', 'метка', 'blue', 1, NULL, NULL); INSERT INTO task_labels VALUES ('11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666'); INSERT INTO draft_labels VALUES (1, '66666666-6666-6666-6666-666666666666'); UPDATE creation_draft SET labels_were_chosen = 1;" : "")
            PRAGMA user_version = \(version);
            """]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        let instant = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { Self.utcCalendar })
        let old = try #require(workspace.tasks.first)
        #expect(old.id.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(old.occurrenceID.uuidString == "22222222-2222-2222-2222-222222222222")
        #expect(old.plannedDay == nil)
        #expect(old.seriesStart == nil)
        #expect(old.completedAt == Date(timeIntervalSince1970: 1800000000.25))
        #expect(old.note == TaskNote(rtf: Data([0, 255]), plainText: "Заметка"))
        #expect(old.projectID == workspace.projects.first?.id)
        let migratedLabelIDs: Set<UUID> = version == 7 ? [UUID(uuidString: "66666666-6666-6666-6666-666666666666")!] : []
        #expect(old.labelIDs == migratedLabelIDs)
        #expect(workspace.creationDraft == CreationDraft(title: "Черновик", priority: .low, projectWasChosen: true, plannedDay: "2026-12-01", dayWasChosen: true, note: TaskNote(rtf: Data([0, 254]), plainText: "Текст"), labelIDs: migratedLabelIDs, labelsWereChosen: version == 7))
        #expect(workspace.timeToolResults.count == (version >= 6 ? 1 : 0))
        if version >= 6 { #expect(workspace.timeToolResults.first?.durationSeconds == 60) }
        _ = try workspace.createTask(title: "Новая серия", recurrence: .daily)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { Self.utcCalendar })
        #expect(reopened.tasks == workspace.tasks)
        #expect(reopened.creationDraft == workspace.creationDraft)
        #expect(reopened.timeToolResults == workspace.timeToolResults)
    }

}
