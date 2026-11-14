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

    @Test func shippedVersionNinePreservesTimerFactsSeriesLabelsAndExplicitDraftChoices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("steady.sqlite")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        fixture.arguments = [url.path, """
            CREATE TABLE projects (id TEXT PRIMARY KEY, title TEXT, color TEXT, created_at REAL);
            CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, created_at REAL, priority TEXT, project_id TEXT, note_rtf BLOB, note_text TEXT);
            CREATE TABLE task_occurrences (id TEXT PRIMARY KEY, task_id TEXT, planned_day TEXT, time_zone TEXT, completed_at REAL, series_day TEXT, calendar_frozen INTEGER NOT NULL DEFAULT 0, individual_override INTEGER NOT NULL DEFAULT 0);
            CREATE UNIQUE INDEX occurrence_series_day ON task_occurrences(task_id, series_day);
            CREATE TABLE recurrence_rules (task_id TEXT, effective_day TEXT, recurrence TEXT, PRIMARY KEY(task_id, effective_day));
            CREATE TABLE creation_draft (id INTEGER PRIMARY KEY, title TEXT, priority TEXT, project_id TEXT, project_was_chosen INTEGER, note_rtf BLOB, note_text TEXT, planned_day TEXT, day_was_chosen INTEGER, labels_were_chosen INTEGER NOT NULL DEFAULT 0, recurrence TEXT, series_start TEXT);
            CREATE TABLE labels (id TEXT PRIMARY KEY, title TEXT, title_key TEXT, color TEXT, created_at REAL, deleted_at REAL, deletion_order INTEGER);
            CREATE UNIQUE INDEX active_label_title ON labels(title_key) WHERE deleted_at IS NULL;
            CREATE TABLE task_labels (task_id TEXT, label_id TEXT, PRIMARY KEY(task_id, label_id));
            CREATE TABLE draft_labels (draft_id INTEGER, label_id TEXT, PRIMARY KEY(draft_id, label_id));
            CREATE TABLE time_tool_runs (id TEXT PRIMARY KEY, kind TEXT, task_id TEXT, occurrence_id TEXT, owner_title TEXT, started_at REAL, time_zone TEXT, stopped_at REAL, timer_budget_seconds REAL, end_reason TEXT);
            CREATE TABLE time_tool_segments (id TEXT PRIMARY KEY, run_id TEXT, position INTEGER, started_at REAL, ended_at REAL, UNIQUE(run_id, position));
            CREATE UNIQUE INDEX one_active_time_tool ON time_tool_runs ((1)) WHERE stopped_at IS NULL;
            CREATE TABLE task_timer_settings (task_id TEXT PRIMARY KEY, duration_seconds REAL NOT NULL CHECK(duration_seconds > 0));
            INSERT INTO projects VALUES ('33333333-3333-3333-3333-333333333333', 'Проект', 'blue', 1);
            INSERT INTO tasks VALUES ('11111111-1111-1111-1111-111111111111', 'Серия до обновления', 1, 'high', '33333333-3333-3333-3333-333333333333', X'00FF', 'Заметка');
            INSERT INTO task_occurrences VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', '2026-11-13', 'America/New_York', 1794564060, '2026-11-13', 1, 1);
            INSERT INTO recurrence_rules VALUES ('11111111-1111-1111-1111-111111111111', '2026-11-13', '{"daily":{}}');
            INSERT INTO labels VALUES ('66666666-6666-6666-6666-666666666666', 'Метка', 'метка', 'blue', 1, NULL, NULL);
            INSERT INTO task_labels VALUES ('11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666');
            INSERT INTO creation_draft VALUES (1, 'Черновик', 'low', NULL, 1, X'00FE', 'Текст', '2026-12-01', 1, 1, '{"weekdays":{}}', '2026-11-17');
            INSERT INTO draft_labels VALUES (1, '66666666-6666-6666-6666-666666666666');
            INSERT INTO time_tool_runs VALUES ('44444444-4444-4444-4444-444444444444', 'timer', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'Старая подпись', 1794564000, 'America/New_York', 1794564060, 60, 'natural');
            INSERT INTO time_tool_runs VALUES ('77777777-7777-7777-7777-777777777777', 'timer', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'Старая подпись', 1794564100, 'America/New_York', 1794564130, 90, 'manual');
            INSERT INTO time_tool_segments VALUES ('55555555-5555-5555-5555-555555555555', '44444444-4444-4444-4444-444444444444', 0, 1794564000, 1794564060);
            INSERT INTO time_tool_segments VALUES ('88888888-8888-8888-8888-888888888888', '77777777-7777-7777-7777-777777777777', 0, 1794564100, 1794564130);
            INSERT INTO task_timer_settings VALUES ('11111111-1111-1111-1111-111111111111', 90);
            PRAGMA user_version = 9;
            """]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        let instant = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let old = try #require(workspace.tasks.first { $0.occurrenceID == UUID(uuidString: "22222222-2222-2222-2222-222222222222") })
        #expect(old.recurrence == .daily)
        #expect(old.seriesDay == "2026-11-13")
        #expect(old.periodEnd == nil && old.skippedAt == nil)
        #expect(old.completedAt == Date(timeIntervalSince1970: 1794564060))
        #expect(old.timeZoneIdentifier == "America/New_York")
        #expect(old.note == TaskNote(rtf: Data([0, 255]), plainText: "Заметка"))
        #expect(old.labelIDs == Set(workspace.labels.map(\.id)))
        #expect(try workspace.timerDurationSeconds(taskID: old.id) == 90)
        let natural = try #require(workspace.timeToolResults.first { $0.endReason == .natural })
        let manual = try #require(workspace.timeToolResults.first { $0.endReason == .manual })
        #expect(natural.id == UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        #expect(natural.occurrenceID == old.occurrenceID && natural.durationSeconds == 60 && natural.timerBudgetSeconds == 60)
        #expect(manual.durationSeconds == 30 && manual.timerBudgetSeconds == 90)
        #expect(natural.ownerTitle == "Старая подпись" && natural.timeZoneIdentifier == "America/New_York")
        let draft = try #require(workspace.creationDraft)
        #expect(draft.plannedDay == "2026-12-01" && draft.dayWasChosen && draft.projectWasChosen && draft.labelsWereChosen)
        #expect(draft.seriesStart == "2026-11-17" && draft.recurrence == .weekdays)
        #expect(draft.note == TaskNote(rtf: Data([0, 254]), plainText: "Текст"))
        #expect(draft.labelIDs == old.labelIDs)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.tasks == workspace.tasks)
        #expect(reopened.timeToolResults == workspace.timeToolResults)
        #expect(reopened.creationDraft == draft)
        #expect(try reopened.timerDurationSeconds(taskID: old.id) == 90)
    }

    @Test func skipCommandsAreIdempotentAndUnskipDoesNotUndoCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var instant = try Date("2026-11-12T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"), now: { instant }, calendar: { calendar })
        let task = try workspace.createTask(title: "Читать", recurrence: .weekly)
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        let completedAt = instant
        try workspace.setSkipped(occurrenceID: task.occurrenceID, skipped: false)
        #expect(workspace.tasks.first { $0.occurrenceID == task.occurrenceID }?.completedAt == completedAt)
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: false)
        try workspace.setSkipped(occurrenceID: task.occurrenceID, skipped: true)
        let skippedAt = instant
        instant = instant.addingTimeInterval(60)
        try workspace.setSkipped(occurrenceID: task.occurrenceID, skipped: true)
        #expect(workspace.tasks.first { $0.occurrenceID == task.occurrenceID }?.skippedAt == skippedAt)
    }

    @Test func changingMidweekDailyOccurrenceCreatesUndatedWeeklyPeriodWithWeeklyRule() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = try Date("2026-11-11T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"), now: { instant }, calendar: { calendar })
        let task = try workspace.createTask(title: "Читать", recurrence: .daily, seriesStart: "2026-11-09")
        try workspace.setRecurrence(occurrenceID: task.occurrenceID, recurrence: .weekly)
        let weekly = try #require(workspace.tasks.first { $0.periodEnd == "2026-11-15" })
        #expect(weekly.recurrence == .weekly)
        #expect(weekly.plannedDay == nil)
        #expect(weekly.seriesDay == "2026-11-09")
        #expect(workspace.openToday.contains { $0.occurrenceID == weekly.occurrenceID })
    }

    @Test func skippingActiveOrPausedOwnerRequiresManualStopAndPreservesActualResult() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = try Date("2026-11-12T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let owner = try workspace.createTask(title: "Читать", recurrence: .weekly)
        let other = try workspace.createTask(title: "Гулять", recurrence: .weekly)
        try workspace.startStopwatch(occurrenceID: owner.occurrenceID)
        let running = workspace.activeSession
        #expect(throws: WorkspaceError.activeOwnerRequiresStop) { try workspace.setSkipped(occurrenceID: owner.occurrenceID, skipped: true) }
        #expect(workspace.activeSession == running)
        #expect(workspace.tasks.first { $0.occurrenceID == owner.occurrenceID }?.skippedAt == nil)
        #expect(workspace.timeToolResults.isEmpty)
        try workspace.setSkipped(occurrenceID: other.occurrenceID, skipped: true)
        #expect(workspace.activeSession == running)
        instant = instant.addingTimeInterval(45)
        try workspace.pauseSession()
        let paused = workspace.activeSession
        #expect(throws: WorkspaceError.activeOwnerRequiresStop) { try workspace.setSkipped(occurrenceID: owner.occurrenceID, skipped: true) }
        #expect(workspace.activeSession == paused)
        #expect(workspace.timeToolResults.isEmpty)
        instant = instant.addingTimeInterval(15)
        try workspace.stopSession()
        let result = try #require(workspace.timeToolResults.first)
        try workspace.setSkipped(occurrenceID: owner.occurrenceID, skipped: true)
        #expect(result.durationSeconds == 45 && result.occurrenceID == owner.occurrenceID)
        #expect(workspace.tasks.first { $0.occurrenceID == owner.occurrenceID }?.skippedAt == instant)
        #expect(workspace.tasks.first { $0.occurrenceID == owner.occurrenceID }?.completedAt == nil)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.activeSession == nil)
        #expect(reopened.timeToolResults == [result])
        #expect(reopened.tasks == workspace.tasks)
    }

    @Test func editingWorkedWeeklyOccurrenceKeepsPeriodAndAllowsChangingRuleBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = try Date("2026-11-11T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let task = try workspace.createTask(title: "Читать", recurrence: .weekly)
        try workspace.startStopwatch(occurrenceID: task.occurrenceID)
        instant = instant.addingTimeInterval(30)
        try workspace.stopSession()
        let result = try #require(workspace.timeToolResults.first)
        try workspace.setRecurrence(occurrenceID: task.occurrenceID, recurrence: .daily)
        let preserved = try #require(workspace.tasks.first { $0.occurrenceID == task.occurrenceID })
        #expect(preserved.periodEnd == "2026-11-15" && preserved.plannedDay == nil)
        #expect(preserved.recurrence == .daily)
        try workspace.setRecurrence(occurrenceID: task.occurrenceID, recurrence: .weekly)
        #expect(workspace.openToday.map(\.occurrenceID) == [task.occurrenceID])
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.tasks == workspace.tasks)
        #expect(reopened.timeToolResults == [result])
        #expect(result.durationSeconds == 30)
    }

}
