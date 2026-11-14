import Foundation
import SteadyCore
import Testing

@MainActor
struct PomodoroTests {
    @Test
    func earlyRestReturnsToOneLogicalFocusWithoutCountingRestOrPause() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        var zone = TimeZone(identifier: "Asia/Almaty")!
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar
        })
        let owner = try workspace.createTask(title: "Читать")
        try workspace.startPomodoro(occurrenceID: owner.occurrenceID)
        let runID = try #require(workspace.activeSession?.id)
        let focusID = try #require(workspace.activeSession?.pomodoro?.focusID)
        instant += 300
        try workspace.startRest()
        #expect(workspace.elapsedSeconds == 300)
        #expect(workspace.remainingSeconds == 1200)
        #expect(workspace.activeSession?.pomodoro?.fullPomodoros == 0)
        #expect(throws: WorkspaceError.sessionOccupied) { try workspace.startStopwatch() }
        instant += 60
        zone = TimeZone(identifier: "America/New_York")!
        #expect(workspace.restRemainingSeconds == 240)
        try workspace.pauseSession()
        instant += 600
        #expect(workspace.restRemainingSeconds == 240)
        try workspace.backToWork()
        #expect(workspace.activeSession?.pomodoro?.focusID == focusID)
        instant += 1200
        try workspace.updateTimer()
        #expect(workspace.activeSession?.pomodoro?.stage == .waitingBreak)
        #expect(workspace.activeSession?.pomodoro?.fullPomodoros == 1)
        #expect(workspace.tasks.first?.completedAt == nil)
        #expect(workspace.elapsedSeconds == 1500)
        try workspace.stopSession()
        try workspace.stopSession()
        let reopened = try TaskWorkspace(databaseURL: url)
        let result = try #require(reopened.timeToolResults.first)
        #expect(result.id == runID)
        #expect(result.durationSeconds == 1500)
        #expect(result.timeZoneIdentifier == "Asia/Almaty")
        #expect(result.pomodoro?.parameters == PomodoroParameters())
        #expect(result.pomodoro?.fullPomodoros == 1)
        #expect(result.pomodoro?.focusID == focusID)
        #expect(result.pomodoro?.restSegments.first?.endedAt == Date(timeIntervalSince1970: 1_800_000_360))
        #expect(reopened.timeToolResults.count == 1)
    }
    @Test
    func adjustedNaturalEndAndFourFullFocusesOfferLongRestAcrossRuns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        for _ in 0..<3 {
            try workspace.startPomodoro()
            try workspace.adjustTimer(minutes: -20)
            instant += 301 // Wake late: actual work ends at the deadline, not wake time.
            try workspace.updateTimer()
            #expect(workspace.activeSession?.pomodoro?.stage == .waitingBreak)
            #expect(workspace.activeSession?.pomodoro?.fullPomodoros == 1)
            try workspace.stopSession()
        }
        try workspace.startPomodoro()
        instant += 1500
        try workspace.updateTimer()
        try workspace.startRest()
        #expect(workspace.restRemainingSeconds == 900)
        #expect(workspace.activeSession?.pomodoro?.restIsLong == true)
        instant += 950
        try workspace.updateTimer()
        #expect(workspace.activeSession?.pomodoro?.stage == .waitingNext)
        #expect(workspace.activeSession?.pomodoro?.cycleCount == 0)
        #expect(workspace.elapsedSeconds == 1500)
        #expect(throws: WorkspaceError.sessionOccupied) { try workspace.startTimer(durationSeconds: 60) }
        try workspace.backToWork()
        instant += 300
        try workspace.adjustTimer(minutes: -20) // Manual zero saves partial work, never a full focus.
        #expect(workspace.activeSession?.pomodoro?.fullPomodoros == 1)
        #expect(workspace.activeSession?.pomodoro?.stage == .waitingBreak)
        try workspace.stopSession()
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.timeToolResults.map(\.durationSeconds) == [300, 300, 300, 1800])
        #expect(reopened.timeToolResults.map { $0.pomodoro?.fullPomodoros } == [1, 1, 1, 1])
        #expect(reopened.timeToolResults.first?.endReason == .natural)
    }

    @Test
    func failedNaturalEndRetriesIntoWaitingAndReopenDoesNotChargeAbsence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        try workspace.startPomodoro()
        instant += 1501
        #expect(workspace.elapsedSeconds == 1500)
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        #expect(throws: (any Error).self) { try workspace.updateTimer() }
        #expect(workspace.sessionNeedsSave)
        #expect(workspace.elapsedSeconds == 1500)
        instant += 600
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        try workspace.retrySessionSave()
        #expect(workspace.activeSession?.pomodoro?.stage == .waitingBreak)
        #expect(workspace.timeToolResults.isEmpty)
        try workspace.startRest()
        instant += 60
        try workspace.pauseSession()
        try workspace.resumeSession()
        instant += 40
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.activeSession?.isPaused == true)
        #expect(reopened.restRemainingSeconds == 240)
        #expect(reopened.remainingSeconds == 0)
        try reopened.backToWork()
        instant += 90
        try reopened.stopSession()
        #expect(reopened.timeToolResults.first?.durationSeconds == 1590)
        #expect(reopened.timeToolResults.first?.pomodoro?.fullPomodoros == 1)
    }

    @Test
    func versionTenWeeklyDailySkipNotesLabelsDraftAndTimerFactsSurvivePomodoroMigration() throws {
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
            ALTER TABLE task_occurrences ADD COLUMN period_end TEXT;
            ALTER TABLE task_occurrences ADD COLUMN skipped_at REAL;
            DROP INDEX occurrence_series_day;
            CREATE UNIQUE INDEX occurrence_series_day ON task_occurrences(task_id, series_day, COALESCE(period_end, ''));
            INSERT INTO tasks VALUES ('99999999-9999-9999-9999-999999999999', 'Недельное дело', 1, 'none', NULL, X'', 'Недельная заметка');
            INSERT INTO recurrence_rules VALUES ('99999999-9999-9999-9999-999999999999', '2026-11-02', '{"weekly":{}}');
            INSERT INTO task_occurrences VALUES ('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA', '99999999-9999-9999-9999-999999999999', NULL, 'Asia/Almaty', NULL, '2026-11-02', 1, 0, '2026-11-08', 1794000000);
            INSERT INTO task_occurrences VALUES ('BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB', '99999999-9999-9999-9999-999999999999', NULL, 'Asia/Almaty', NULL, '2026-11-09', 1, 0, '2026-11-15', NULL);
            PRAGMA user_version = 10;

            """]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        var instant = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Almaty")!
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let daily = try #require(workspace.tasks.first { $0.occurrenceID == UUID(uuidString: "22222222-2222-2222-2222-222222222222") })
        #expect(daily.recurrence == .daily && daily.completedAt == Date(timeIntervalSince1970: 1794564060))
        #expect(daily.note == TaskNote(rtf: Data([0, 255]), plainText: "Заметка"))
        #expect(daily.timeZoneIdentifier == "America/New_York")
        #expect(daily.labelIDs == Set(workspace.labels.map(\.id)))
        #expect(try workspace.timerDurationSeconds(taskID: daily.id) == 90)
        let skipped = try #require(workspace.tasks.first { $0.occurrenceID == UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") })
        #expect(skipped.periodEnd == "2026-11-08" && skipped.skippedAt == Date(timeIntervalSince1970: 1794000000))
        let weekly = try #require(workspace.tasks.first { $0.occurrenceID == UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB") })
        #expect(weekly.recurrence == .weekly && weekly.plannedDay == nil && weekly.periodEnd == "2026-11-15")
        let draft = try #require(workspace.creationDraft)
        #expect(draft.plannedDay == "2026-12-01" && draft.dayWasChosen && draft.projectWasChosen && draft.labelsWereChosen)
        #expect(draft.recurrence == .weekdays && draft.note == TaskNote(rtf: Data([0, 254]), plainText: "Текст"))
        let timerResults = workspace.timeToolResults
        #expect(timerResults.map(\.durationSeconds) == [60, 30])
        #expect(timerResults.map(\.endReason) == [.natural, .manual])
        try workspace.startPomodoro(occurrenceID: weekly.occurrenceID)
        instant += 60
        try workspace.startRest()
        #expect(throws: WorkspaceError.activeOwnerRequiresStop) { try workspace.setSkipped(occurrenceID: weekly.occurrenceID, skipped: true) }
        try workspace.pauseSession()
        #expect(throws: WorkspaceError.activeOwnerRequiresStop) { try workspace.setSkipped(occurrenceID: weekly.occurrenceID, skipped: true) }
        try workspace.stopSession()
        try workspace.setSkipped(occurrenceID: weekly.occurrenceID, skipped: true)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.tasks == workspace.tasks)
        #expect(reopened.creationDraft == draft)
        #expect(reopened.timeToolResults.prefix(2).elementsEqual(timerResults))
        #expect(reopened.timeToolResults.last?.durationSeconds == 60)
        #expect(reopened.timeToolResults.last?.pomodoro?.fullPomodoros == 0)
        #expect(reopened.timeToolResults.last?.occurrenceID == weekly.occurrenceID)
    }

    @Test
    func sharedCycleFollowsCommandOrderWhenTheSystemClockMovesBackwardBetweenRuns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        for expectedCount in 1...3 {
            try workspace.startPomodoro()
            instant += 1500
            try workspace.updateTimer()
            #expect(workspace.activeSession?.pomodoro?.cycleCount == expectedCount)
            try workspace.stopSession()
            instant -= 3600
        }
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        try reopened.startPomodoro()
        instant += 1500
        try reopened.updateTimer()
        try reopened.startRest()
        #expect(reopened.restRemainingSeconds == 900)
    }

    @Test
    func stoppingAfterClockMovesBackwardKeepsSavedRestWithinRunBounds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        try workspace.startPomodoro()
        instant += 60
        try workspace.startRest()
        instant += 10
        try workspace.pauseSession()
        instant -= 20
        try workspace.stopSession()
        let reopened = try TaskWorkspace(databaseURL: url)
        let result = try #require(reopened.timeToolResults.first)
        #expect(result.stoppedAt == Date(timeIntervalSince1970: 1070))
        #expect(result.pomodoro?.restSegments.last?.endedAt == Date(timeIntervalSince1970: 1070))
        #expect(result.durationSeconds == 60)
    }

}
