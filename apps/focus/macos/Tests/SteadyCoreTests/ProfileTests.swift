import Foundation
import Observation
import SteadyCore
import Testing

@MainActor
struct ProfileTests {
    @Test func profilesAndInheritedOverridesPersistAndRunsKeepTheirSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let seeded = try #require(workspace.pomodoroProfiles.first?.parameters)
        #expect(seeded.workSeconds == 1500)
        #expect(seeded.shortRestSeconds == 300)
        #expect(seeded.longRestSeconds == 900)
        #expect(seeded.longRestAfter == 4)
        let custom = PomodoroParameters(workSeconds: 600, shortRestSeconds: 120, longRestSeconds: 420, longRestAfter: 3)
        let profile = try workspace.savePomodoroProfile(title: "Чтение", parameters: custom)
        try await confirmation("Profile selection refreshes the displayed parameters") { notified in
            withObservationTracking { _ = try? workspace.pomodoroParameters() } onChange: { notified() }
            try workspace.selectPomodoroProfile(id: profile.id)
        }
        #expect(try workspace.pomodoroParameters() == custom)
        try workspace.startPomodoro()
        #expect(workspace.remainingSeconds == 600)
        instant += 30
        try await confirmation("Profile editing refreshes the displayed parameters during a run") { notified in
            withObservationTracking { _ = try? workspace.pomodoroParameters() } onChange: { notified() }
            _ = try workspace.savePomodoroProfile(id: profile.id, title: "Чтение", parameters: PomodoroParameters())
        }
        #expect(try workspace.pomodoroParameters() == seeded)
        #expect(workspace.activeSession?.pomodoro?.parameters == custom)
        try workspace.stopSession()
        let child = SubtaskDraft(title: "Глава", note: TaskNote(rtf: Data(), plainText: "Своя заметка"))
        try workspace.saveCreationDraft(CreationDraft(title: "Книга", children: [child], pomodoroParameters: custom))
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.creationDraft?.pomodoroParameters == custom)
        let parent = try reopened.createTaskFromDraft()
        let savedChild = try #require(reopened.tasks.first { $0.id == child.id })
        #expect(try reopened.pomodoroParameters(taskID: savedChild.id) == custom)
        try reopened.startPomodoro(occurrenceID: savedChild.occurrenceID)
        let runID = reopened.activeSession?.id
        try reopened.setPomodoroParameters(taskID: savedChild.id, parameters: PomodoroParameters())
        #expect(reopened.activeSession?.id == runID)
        #expect(reopened.activeSession?.occurrenceID == savedChild.occurrenceID)
        #expect(reopened.activeSession?.pomodoro?.parameters == custom)
        instant += 60
        try reopened.stopSession()
        try reopened.setPomodoroParameters(taskID: savedChild.id, parameters: nil)
        let final = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(try final.pomodoroParameters(taskID: parent.id) == custom)
        #expect(try final.pomodoroParameters(taskID: savedChild.id) == custom)
        #expect(try final.pomodoroOverride(taskID: savedChild.id) == nil)
        #expect(final.tasks.first { $0.id == savedChild.id }?.note.plainText == "Своя заметка")
        #expect(final.timeToolResults.map(\.durationSeconds) == [30, 60])
        #expect(final.pomodoroProfiles.first { $0.id == profile.id }?.parameters == PomodoroParameters())
    }
    @Test func draftTimersPersistAndCreateIndependentParentAndChildSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        var child = SubtaskDraft(title: "Child")
        child.timerDurationSeconds = 120
        let unsetChild = SubtaskDraft(title: "Not set")
        let draft = CreationDraft(title: "Parent", children: [child, unsetChild], timerDurationSeconds: 300)
        try workspace.saveCreationDraft(draft)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.creationDraft == draft)
        #expect(try reopened.prepareCreationDraft(plannedDay: "2026-12-01") == draft)
        let parent = try reopened.createTaskFromDraft()
        #expect(reopened.creationDraft == nil)
        let final = try TaskWorkspace(databaseURL: url)
        let savedChild = try #require(final.tasks.first { $0.id == child.id })
        let savedUnset = try #require(final.tasks.first { $0.id == unsetChild.id })
        #expect(try final.timerDurationSeconds(taskID: parent.id) == 300)
        #expect(try final.timerDurationSeconds(taskID: child.id) == 120)
        #expect(try final.timerDurationSeconds(taskID: unsetChild.id) == nil)
        #expect(throws: WorkspaceError.timerDurationRequired) { try final.startTimer(occurrenceID: savedUnset.occurrenceID) }
        #expect(final.activeSession == nil)
        try final.startTimer(occurrenceID: savedChild.occurrenceID)
        #expect(final.activeSession?.timerBudgetSeconds == 120)
        try final.stopSession()
        try final.startTimer(occurrenceID: parent.occurrenceID)
        #expect(final.activeSession?.timerBudgetSeconds == 300)
    }
    @Test(arguments: [0.0, -1.0, Double.infinity, Double.nan, TimeToolSession.maximumTimerDurationSeconds.nextUp])
    func invalidDraftTimerLeavesSavedDraftAndTasksUnchanged(seconds: Double) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let saved = CreationDraft(timerDurationSeconds: 90)
        try workspace.saveCreationDraft(saved)
        #expect(throws: WorkspaceError.invalidTimerDuration) {
            try workspace.saveCreationDraft(CreationDraft(title: "Invalid parent", timerDurationSeconds: seconds))
        }
        var child = SubtaskDraft(title: "Invalid child")
        child.timerDurationSeconds = seconds
        #expect(throws: WorkspaceError.invalidTimerDuration) {
            try workspace.saveCreationDraft(CreationDraft(title: "Parent", children: [child]))
        }
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.creationDraft == saved)
        #expect(reopened.tasks.isEmpty)
        #expect(reopened.activeSession == nil)
        try reopened.discardCreationDraft()
        #expect(try TaskWorkspace(databaseURL: url).creationDraft == nil)
    }
    @Test(arguments: [12, 13]) func legacyDraftChildrenAndSessionSnapshotsSurviveProfileMigration(version: Int) throws {
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
            ALTER TABLE time_tool_runs ADD COLUMN pomodoro_state TEXT;
            CREATE TABLE pomodoro_cycle (id INTEGER PRIMARY KEY CHECK(id = 1), full_intervals INTEGER NOT NULL CHECK(full_intervals >= 0));
            INSERT INTO pomodoro_cycle VALUES (1, 0);
            ALTER TABLE tasks ADD COLUMN parent_task_id TEXT REFERENCES tasks(id);
            ALTER TABLE task_occurrences ADD COLUMN parent_occurrence_id TEXT REFERENCES task_occurrences(id);
            CREATE UNIQUE INDEX child_parent_occurrence ON task_occurrences(task_id, parent_occurrence_id) WHERE parent_occurrence_id IS NOT NULL;
            ALTER TABLE creation_draft ADD COLUMN children BLOB NOT NULL DEFAULT X'5B5D';
            UPDATE creation_draft SET children = CAST('[{"id":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","title":"Старая подзадача","note":{"rtf":"AP8=","plainText":"Своя заметка"},"labelIDs":["66666666-6666-6666-6666-666666666666"]}]' AS BLOB);
            UPDATE time_tool_runs SET kind = 'pomodoro', pomodoro_state = '{"parameters":{"workSeconds":1500,"shortRestSeconds":300,"longRestSeconds":900,"longRestAfter":4,"autoBreak":false,"autoNext":false},"focusID":"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD","stage":"work","fullPomodoros":0,"cycleCount":0,"focusStartElapsed":0,"focusBudgetSeconds":1500,"focusFinished":false,"restSegments":[],"restStartIndex":0,"restIsLong":false}' WHERE id = '44444444-4444-4444-4444-444444444444';
            INSERT INTO time_tool_runs (id, kind, owner_title, started_at, time_zone, pomodoro_state)
            SELECT 'EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE', 'pomodoro', 'Без задачи', 1794564100, 'Asia/Almaty', pomodoro_state FROM time_tool_runs WHERE id = '44444444-4444-4444-4444-444444444444';
            INSERT INTO time_tool_segments VALUES ('FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF', 'EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE', 0, 1794564100, NULL);
            PRAGMA user_version = 12;

            """]
        if version == 13 {
            let legacy = try #require(fixture.arguments?.last)
            fixture.arguments = [url.path, legacy + """
                CREATE TABLE workspace_preferences (id INTEGER PRIMARY KEY CHECK(id = 1), value TEXT NOT NULL);
                INSERT INTO workspace_preferences VALUES (1, '{"context":{"projectID":"33333333-3333-3333-3333-333333333333","labelIDs":["66666666-6666-6666-6666-666666666666"],"labelMatch":"all","period":"month","showCompleted":true},"screen":"tasks","selectedOccurrenceID":"ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB","detailsVisible":true,"sidebarVisible":false,"expandedParentIDs":["22222222-2222-2222-2222-222222222222"]}');
                INSERT INTO tasks (id, title, created_at, priority, note_rtf, note_text, parent_task_id) VALUES ('ACACACAC-ACAC-ACAC-ACAC-ACACACACACAC', 'Дочерний фокус', 1, 'none', X'', 'Своя заметка', '11111111-1111-1111-1111-111111111111');
                INSERT INTO task_occurrences (id, task_id, time_zone, parent_occurrence_id) VALUES ('ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB', 'ACACACAC-ACAC-ACAC-ACAC-ACACACACACAC', 'Asia/Almaty', '22222222-2222-2222-2222-222222222222');
                UPDATE time_tool_runs SET task_id = 'ACACACAC-ACAC-ACAC-ACAC-ACACACACACAC', occurrence_id = 'ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB', owner_title = 'Дочерний фокус' WHERE id = 'EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE';
                UPDATE time_tool_segments SET ended_at = 1794564130 WHERE run_id = 'EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE';
                PRAGMA user_version = 13;
                """]
        }
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        let instant = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(workspace.activeSession?.id == UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"))
        #expect(workspace.activeSession?.isPaused == true)
        #expect(workspace.activeSession?.pomodoro?.parameters == PomodoroParameters())
        #expect(workspace.elapsedSeconds == (version == 13 ? 30 : 0))
        if version == 13 {
            #expect(workspace.activeSession?.taskID == UUID(uuidString: "ACACACAC-ACAC-ACAC-ACAC-ACACACACACAC"))
            #expect(workspace.preferences.context.period == .month)
            #expect(workspace.preferences.context.labelMatch == .all)
            #expect(workspace.preferences.context.showCompleted)
            #expect(workspace.preferences.context.projectID == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
            #expect(workspace.preferences.context.labelIDs == Set([UUID(uuidString: "66666666-6666-6666-6666-666666666666")!]))
            #expect(workspace.preferences.selectedOccurrenceID == workspace.activeSession?.occurrenceID)
            #expect(workspace.preferences.detailsVisible && !workspace.preferences.sidebarVisible)
        }
        let draft = try #require(workspace.creationDraft)
        #expect(draft.pomodoroParameters == nil)
        #expect(draft.timerDurationSeconds == nil)
        #expect(draft.projectWasChosen && draft.dayWasChosen && draft.labelsWereChosen)
        #expect(draft.note == TaskNote(rtf: Data([0, 254]), plainText: "Текст"))
        #expect(draft.children.first?.id == UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        #expect(draft.children.first?.pomodoroParameters == nil)
        #expect(draft.children.first?.timerDurationSeconds == nil)
        #expect(draft.children.first?.note == TaskNote(rtf: Data([0, 255]), plainText: "Своя заметка"))
        #expect(draft.children.first?.labelIDs == Set(workspace.labels.map(\.id)))
        #expect(workspace.timeToolResults.first?.pomodoro?.parameters == PomodoroParameters())
        #expect(workspace.timeToolResults.first?.durationSeconds == 60)
        _ = try workspace.createTaskFromDraft()
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.tasks.contains { $0.id == UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC") })
        #expect(reopened.timeToolResults == workspace.timeToolResults)
        #expect(reopened.activeSession == workspace.activeSession)
        #expect(reopened.preferences == workspace.preferences)
    }
}
