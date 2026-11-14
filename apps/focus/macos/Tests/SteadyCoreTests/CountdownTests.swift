import Foundation
import SteadyCore
import Testing

@MainActor
struct CountdownTests {
    @Test
    func unsetDurationDoesNotStartAndConfirmedDurationSurvivesRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let task = try workspace.createTask(title: "Читать")
        #expect(throws: WorkspaceError.timerDurationRequired) { try workspace.startTimer(occurrenceID: task.occurrenceID) }
        #expect(workspace.activeSession == nil)
        try workspace.startTimer(occurrenceID: task.occurrenceID, durationSeconds: 600)
        let id = try #require(workspace.activeSession?.id)
        instant += 120
        try workspace.pauseSession()
        instant += 900
        #expect(workspace.remainingSeconds == 480)
        #expect(workspace.elapsedSeconds == 120)
        try workspace.resumeSession()
        instant += 60
        try workspace.stopSession()
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.timeToolResults.first?.id == id)
        #expect(reopened.timeToolResults.first?.kind == .timer)
        #expect(reopened.timeToolResults.first?.durationSeconds == 180)
        #expect(reopened.timeToolResults.first?.endReason == .stopped)
        #expect(reopened.tasks.first?.completedAt == nil)
        #expect(try reopened.timerDurationSeconds(taskID: task.id) == 600)
        try reopened.startTimer(occurrenceID: task.occurrenceID)
        #expect(reopened.remainingSeconds == 600)
    }
    @Test
    func repeatedDeltasPreserveOwnerAndPauseAndDoNotChangeTheTaskSetting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let task = try workspace.createTask(title: "Читать")
        try workspace.startTimer(occurrenceID: task.occurrenceID, durationSeconds: 600)
        let id = try #require(workspace.activeSession?.id)
        instant += 120
        #expect(try workspace.previewTimerIncrement(minutes: 5) == 780)
        try workspace.adjustTimer(minutes: 5)
        try workspace.adjustTimer(minutes: 5)
        #expect(workspace.remainingSeconds == 1080)
        #expect(workspace.activeSession?.id == id)
        #expect(workspace.activeSession?.isPaused == false)
        #expect(workspace.activeSession?.occurrenceID == task.occurrenceID)
        try workspace.pauseSession()
        instant += 600
        try workspace.adjustTimer(minutes: -1)
        #expect(workspace.remainingSeconds == 1020)
        #expect(workspace.activeSession?.isPaused == true)
        #expect(throws: WorkspaceError.invalidTimerIncrement) { try workspace.adjustTimer(minutes: 21) }
        #expect(throws: WorkspaceError.invalidTimerIncrement) { try workspace.previewTimerIncrement(minutes: -21) }
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.remainingSeconds == 1020)
        #expect(reopened.elapsedSeconds == 120)
        #expect(try reopened.timerDurationSeconds(taskID: task.id) == 600)
        #expect(try reopened.previewTimerIncrement(minutes: -20) == 0)
        try reopened.adjustTimer(minutes: -20)
        #expect(reopened.activeSession == nil)
        #expect(reopened.timeToolResults.first?.endReason == .manual)
        #expect(reopened.timeToolResults.first?.durationSeconds == 120)
        #expect(reopened.tasks.first?.completedAt == nil)
    }
    @Test(arguments: [false, true])
    func naturalEndAndStopSaveOneResultAtTheDeadline(stopFirst: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let owner = try workspace.createTask(title: "Читать")
        try workspace.startTimer(occurrenceID: owner.occurrenceID, durationSeconds: 600)
        instant += 120
        try workspace.pauseSession()
        instant += 300
        try workspace.resumeSession()
        instant += 900 // A delayed delivery must not charge the late 420 seconds.
        #expect(workspace.elapsedSeconds == 600)
        #expect(workspace.remainingSeconds == 0)
        if stopFirst { try workspace.stopSession() }
        try workspace.updateTimer()
        try workspace.stopSession()
        try workspace.updateTimer()
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.activeSession == nil)
        #expect(reopened.timeToolResults.count == 1)
        let result = try #require(reopened.timeToolResults.first)
        #expect(result.endReason == .natural)
        #expect(result.durationSeconds == 600)
        #expect(result.stoppedAt == Date(timeIntervalSince1970: 1_800_000_900))
        #expect(result.segments.count == 2)
        #expect(result.segments.last?.endedAt == result.stoppedAt)
        #expect(reopened.tasks.first?.completedAt == nil)
    }
    @Test
    func failedNaturalEndFreezesAtDeadlineAndRetryNeverChargesAbsence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        try workspace.startTimer(durationSeconds: 60)
        instant += 90
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        #expect(throws: (any Error).self) { try workspace.updateTimer() }
        #expect(workspace.sessionNeedsSave)
        #expect(workspace.activeSession?.isPaused == true)
        #expect(workspace.elapsedSeconds == 60)
        instant += 600
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        try workspace.retrySessionSave()
        try workspace.stopSession()
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.timeToolResults.count == 1)
        #expect(reopened.timeToolResults.first?.durationSeconds == 60)
        #expect(reopened.timeToolResults.first?.endReason == .natural)
        #expect(reopened.timeToolResults.first?.stoppedAt == Date(timeIntervalSince1970: 1_800_000_060))
    }
    @Test
    func versionEightSeriesRulesHistoryLabelsDraftAndStopwatchSurviveCountdownMigration() throws {
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
            CREATE TABLE time_tool_runs (id TEXT PRIMARY KEY, kind TEXT, task_id TEXT, occurrence_id TEXT, owner_title TEXT, started_at REAL, time_zone TEXT, stopped_at REAL);
            CREATE TABLE time_tool_segments (id TEXT PRIMARY KEY, run_id TEXT, position INTEGER, started_at REAL, ended_at REAL);
            CREATE UNIQUE INDEX one_active_time_tool ON time_tool_runs ((1)) WHERE stopped_at IS NULL;
            CREATE TABLE labels (id TEXT PRIMARY KEY, title TEXT, title_key TEXT, color TEXT, created_at REAL, deleted_at REAL, deletion_order INTEGER);
            CREATE UNIQUE INDEX active_label_title ON labels(title_key) WHERE deleted_at IS NULL;
            CREATE TABLE task_labels (task_id TEXT, label_id TEXT, PRIMARY KEY(task_id, label_id));
            CREATE TABLE draft_labels (draft_id INTEGER, label_id TEXT, PRIMARY KEY(draft_id, label_id));
            INSERT INTO projects VALUES ('33333333-3333-3333-3333-333333333333', 'Учёба', 'green', 1);
            INSERT INTO tasks VALUES ('11111111-1111-1111-1111-111111111111', 'Читать', 1, 'high', '33333333-3333-3333-3333-333333333333', X'00FF', 'Общая заметка');
            INSERT INTO task_occurrences VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', '2026-11-12', 'Asia/Almaty', 1794477600.25, '2026-11-12', 1, 0);
            INSERT INTO task_occurrences VALUES ('77777777-7777-7777-7777-777777777777', '11111111-1111-1111-1111-111111111111', '2026-11-13', 'Asia/Almaty', NULL, '2026-11-13', 1, 0);
            INSERT INTO recurrence_rules VALUES ('11111111-1111-1111-1111-111111111111', '2026-11-12', '{"daily":{}}');
            INSERT INTO recurrence_rules VALUES ('11111111-1111-1111-1111-111111111111', '2026-11-14', '{"weekdays":{}}');
            INSERT INTO creation_draft VALUES (1, 'Черновик', 'low', NULL, 1, X'00FE', 'Текст черновика', '2026-12-01', 1, 1, '{"daily":{}}', '2026-11-01');
            INSERT INTO labels VALUES ('66666666-6666-6666-6666-666666666666', 'Чтение', 'чтение', 'blue', 1, NULL, NULL);
            INSERT INTO task_labels VALUES ('11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666');
            INSERT INTO draft_labels VALUES (1, '66666666-6666-6666-6666-666666666666');
            INSERT INTO time_tool_runs VALUES ('44444444-4444-4444-4444-444444444444', 'stopwatch', '11111111-1111-1111-1111-111111111111', '77777777-7777-7777-7777-777777777777', 'Читать', 1794564000, 'Asia/Almaty', 1794564060);
            INSERT INTO time_tool_segments VALUES ('55555555-5555-5555-5555-555555555555', '44444444-4444-4444-4444-444444444444', 0, 1794564000, 1794564060);
            PRAGMA user_version = 8;
            """]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        var instant = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let historical = try #require(workspace.tasks.first { $0.seriesDay == "2026-11-12" })
        #expect(historical.occurrenceID.uuidString == "22222222-2222-2222-2222-222222222222")
        #expect(historical.completedAt == Date(timeIntervalSince1970: 1794477600.25))
        #expect(historical.timeZoneIdentifier == "Asia/Almaty")
        #expect(historical.recurrence == .daily)
        #expect(historical.note == TaskNote(rtf: Data([0, 255]), plainText: "Общая заметка"))
        #expect(historical.projectID == workspace.projects.first?.id)
        let labelID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        #expect(workspace.labels.first?.title == "Чтение")
        #expect(historical.labelIDs == [labelID])
        let draft = CreationDraft(title: "Черновик", priority: .low, projectWasChosen: true, plannedDay: "2026-12-01", dayWasChosen: true, note: TaskNote(rtf: Data([0, 254]), plainText: "Текст черновика"), labelIDs: [labelID], labelsWereChosen: true, recurrence: .daily, seriesStart: "2026-11-01")
        #expect(workspace.creationDraft == draft)
        let previous = try #require(workspace.timeToolResults.first)
        #expect(previous.id.uuidString == "44444444-4444-4444-4444-444444444444")
        #expect(previous.kind == .stopwatch)
        #expect(previous.durationSeconds == 60)
        #expect(previous.endReason == nil)
        #expect(previous.segments.first?.id.uuidString == "55555555-5555-5555-5555-555555555555")
        let future = try #require(workspace.tasks.first { $0.seriesDay == "2026-11-16" })
        #expect(future.recurrence == .weekdays)
        #expect(future.seriesStart == "2026-11-12")
        try workspace.startTimer(occurrenceID: future.occurrenceID, durationSeconds: 300)
        instant += 30
        try workspace.stopSession()
        let records = workspace.tasks
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.tasks == records)
        #expect(reopened.creationDraft == draft)
        #expect(reopened.timeToolResults.first == previous)
        #expect(reopened.timeToolResults.last?.kind == .timer)
        #expect(reopened.timeToolResults.last?.durationSeconds == 30)
        #expect(reopened.timeToolResults.last?.occurrenceID == future.occurrenceID)
        #expect(try reopened.timerDurationSeconds(taskID: future.id) == 300)
    }
    @Test
    func unrepresentableDurationRollsBackBeforeStartingAndAllowsValidRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let owner = try workspace.createTask(title: "Без переполнения")
        #expect(throws: WorkspaceError.invalidTimerDuration) {
            try workspace.startTimer(occurrenceID: owner.occurrenceID, durationSeconds: 6e21)
        }
        #expect(workspace.activeSession == nil)
        #expect(try workspace.timerDurationSeconds(taskID: owner.id) == nil)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.activeSession == nil)
        #expect(reopened.timeToolResults.isEmpty)
        #expect(try reopened.timerDurationSeconds(taskID: owner.id) == nil)
        try reopened.startTimer(occurrenceID: owner.occurrenceID, durationSeconds: 600)
        #expect(reopened.remainingSeconds == 600)
        #expect(try reopened.timerDurationSeconds(taskID: owner.id) == 600)
    }

    @Test
    func durationBoundaryRejectsAnOverflowingIncrementWithoutChangingTheRun() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let owner = try workspace.createTask(title: "Граница длительности")
        // Largest Double below 2^63: exactly representable as a signed 64-bit seconds count.
        let duration: TimeInterval = 9_223_372_036_854_774_784
        try workspace.startTimer(occurrenceID: owner.occurrenceID, durationSeconds: duration)
        let original = try #require(workspace.activeSession)
        #expect(throws: WorkspaceError.invalidTimerDuration) { try workspace.previewTimerIncrement(minutes: 20) }
        #expect(throws: WorkspaceError.invalidTimerDuration) { try workspace.adjustTimer(minutes: 20) }
        #expect(workspace.activeSession == original)
        #expect(workspace.remainingSeconds == duration)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.remainingSeconds == duration)
        #expect(try reopened.timerDurationSeconds(taskID: owner.id) == duration)
        #expect(reopened.activeSession?.id == original.id)
        #expect(reopened.activeSession?.isPaused == true)
    }
}
