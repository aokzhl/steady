import Foundation
import SteadyCore
import Testing

@MainActor struct SubtaskTests {
    @Test func draftChildrenKeepIndependentMetadataAndOccurrenceLinksAfterReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let label = try workspace.createLabel(title: "Child")
        let child = SubtaskDraft(title: "Read", note: TaskNote(plainText: "Child note"), labelIDs: [label.id])
        try workspace.saveCreationDraft(CreationDraft(title: "Study", note: TaskNote(plainText: "Parent note"), children: [child]))
        let resumed = try TaskWorkspace(databaseURL: url)
        #expect(resumed.creationDraft?.children == [child])
        let parent = try resumed.createTaskFromDraft()
        let reopened = try TaskWorkspace(databaseURL: url)
        let saved = try #require(reopened.children(of: parent.occurrenceID).first)
        #expect(saved.id == child.id)
        #expect(saved.id != saved.occurrenceID)
        #expect(saved.parentTaskID == parent.id)
        #expect(saved.parentOccurrenceID == parent.occurrenceID)
        #expect(saved.note == child.note)
        #expect(saved.labelIDs == [label.id])
        try reopened.setCompleted(occurrenceID: parent.occurrenceID, completed: true)
        #expect(reopened.children(of: parent.occurrenceID).first?.completedAt == nil)
        #expect(throws: WorkspaceError.childInheritsParent) { try reopened.addSubtask(parentOccurrenceID: saved.occurrenceID, title: "Too deep") }
    }
    @Test func childWorkProtectsItsParentOccurrenceWhenRulesChangeAndFutureChildrenStartOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = ISO8601DateFormatter().date(from: "2026-11-16T09:00:00Z")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let project = try workspace.createProject(title: "Reading")
        let parent = try workspace.createTask(title: "Study", projectID: project.id, note: TaskNote(plainText: "Parent only"), recurrence: .daily)
        let child = try workspace.addSubtask(parentOccurrenceID: parent.occurrenceID, title: "Read")
        #expect(child.projectID == project.id)
        #expect(child.note == .empty)
        #expect(child.labelIDs.isEmpty)
        #expect(child.recurrence == .daily)
        #expect(throws: WorkspaceError.childInheritsParent) { try workspace.setPlannedDay(occurrenceID: child.occurrenceID, day: "2026-11-17") }
        #expect(throws: WorkspaceError.childInheritsParent) { try workspace.setProject(id: child.id, projectID: nil) }
        try workspace.startStopwatch(occurrenceID: child.occurrenceID)
        instant.addTimeInterval(75)
        try workspace.stopSession()
        try workspace.setCompleted(occurrenceID: child.occurrenceID, completed: true)
        #expect(workspace.tasks.first { $0.occurrenceID == parent.occurrenceID }?.completedAt == nil)
        try workspace.setRecurrence(occurrenceID: parent.occurrenceID, recurrence: .selectedWeekdays([3]))
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.tasks.contains { $0.occurrenceID == parent.occurrenceID })
        #expect(reopened.tasks.first { $0.occurrenceID == child.occurrenceID }?.completedAt != nil)
        #expect(reopened.timeToolResults.first?.occurrenceID == child.occurrenceID)
        #expect(reopened.timeToolResults.first?.elapsedSeconds(at: instant) == 75)
        let next = try #require(reopened.tasks.first { $0.id == parent.id && $0.plannedDay == "2026-11-17" })
        let fresh = try #require(reopened.children(of: next.occurrenceID).first)
        #expect(fresh.id == child.id)
        #expect(fresh.occurrenceID != child.occurrenceID)
        #expect(fresh.completedAt == nil)
        try reopened.setNote(id: child.id, note: TaskNote(plainText: "Shared child instructions"))
        #expect(reopened.children(of: parent.occurrenceID).first?.note.plainText == "Shared child instructions")
        #expect(reopened.children(of: next.occurrenceID).first?.note.plainText == "Shared child instructions")
    }

    @Test func completedParentKeepsUnworkedChildIdentityWhenRecurrenceChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = ISO8601DateFormatter().date(from: "2026-11-16T09:00:00Z")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        let parent = try workspace.createTask(title: "Study", recurrence: .daily)
        let child = try workspace.addSubtask(parentOccurrenceID: parent.occurrenceID, title: "Read")
        try workspace.setCompleted(occurrenceID: parent.occurrenceID, completed: true)
        try workspace.setRecurrence(occurrenceID: parent.occurrenceID, recurrence: .selectedWeekdays([3]))
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(reopened.children(of: parent.occurrenceID).first?.occurrenceID == child.occurrenceID)
    }

    @Test func failedParentCreationKeepsChildDraftForRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: moved) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        var child = SubtaskDraft(title: "Child", note: TaskNote(plainText: "Keep this"))
        child.timerDurationSeconds = 120
        let draft = CreationDraft(title: "Parent", children: [child], timerDurationSeconds: 300)
        try workspace.saveCreationDraft(draft)
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        #expect(throws: (any Error).self) { try workspace.createTaskFromDraft() }
        #expect(workspace.tasks.isEmpty)
        #expect(workspace.creationDraft == draft)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        let retry = try TaskWorkspace(databaseURL: url)
        #expect(retry.creationDraft == draft)
        let parent = try retry.createTaskFromDraft()
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.children(of: parent.occurrenceID).first?.id == child.id)
        #expect(try reopened.timerDurationSeconds(taskID: parent.id) == 300)
        #expect(try reopened.timerDurationSeconds(taskID: child.id) == 120)
        #expect(reopened.creationDraft == nil)
    }

    @Test func versionElevenPomodoroCycleRestAndWeeklyFactsSurviveChildMigration() throws {
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
            INSERT INTO pomodoro_cycle VALUES (1, 4);
            INSERT INTO time_tool_runs VALUES ('EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE', 'pomodoro', '99999999-9999-9999-9999-999999999999', 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB', 'Previous owner', 1794562000, 'Asia/Almaty', 1794563500, NULL, 'natural', '{"parameters":{"workSeconds":1500,"shortRestSeconds":300,"longRestSeconds":900,"longRestAfter":4,"autoBreak":false,"autoNext":false},"focusID":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","stage":"waitingBreak","fullPomodoros":1,"cycleCount":3,"focusStartElapsed":0,"focusBudgetSeconds":1500,"focusFinished":true,"restSegments":[],"restStartIndex":0,"restIsLong":false}');
            INSERT INTO time_tool_segments VALUES ('FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF', 'EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE', 0, 1794562000, 1794563500);
            INSERT INTO time_tool_runs VALUES ('ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB', 'pomodoro', '99999999-9999-9999-9999-999999999999', 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB', 'Active owner', 1794565000, 'Asia/Almaty', NULL, NULL, 'natural', '{"parameters":{"workSeconds":1500,"shortRestSeconds":300,"longRestSeconds":900,"longRestAfter":4,"autoBreak":false,"autoNext":false},"focusID":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","stage":"rest","fullPomodoros":1,"cycleCount":4,"focusStartElapsed":0,"focusBudgetSeconds":1500,"focusFinished":true,"restSegments":[{"id":"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD","startedAt":816259300,"endedAt":816259310}],"restStartIndex":0,"restIsLong":true}');
            INSERT INTO time_tool_segments VALUES ('CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD', 'ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB', 0, 1794565000, 1794566500);
            PRAGMA user_version = 11;
            """]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        let instant = Date(timeIntervalSince1970: 1794567000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let ownerID = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        let owner = try #require(workspace.tasks.first { $0.occurrenceID == ownerID })
        let active = try #require(workspace.activeSession)
        #expect(active.id.uuidString == "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")
        #expect(active.occurrenceID == ownerID && active.ownerTitle == "Active owner")
        #expect(active.pomodoro?.fullPomodoros == 1 && active.pomodoro?.cycleCount == 4)
        #expect(active.pomodoro?.stage == .rest && active.isPaused)
        #expect(workspace.restRemainingSeconds == 890)
        #expect(active.durationSeconds == 1500)
        let prior = try #require(workspace.timeToolResults.first { $0.kind == .pomodoro })
        #expect(prior.pomodoro?.fullPomodoros == 1 && prior.pomodoro?.cycleCount == 3)
        #expect(prior.durationSeconds == 1500)
        let skipped = try #require(workspace.tasks.first { $0.occurrenceID.uuidString == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA" })
        #expect(skipped.skippedAt == Date(timeIntervalSince1970: 1794000000))
        #expect(skipped.periodEnd == "2026-11-08")
        let daily = try #require(workspace.tasks.first { $0.occurrenceID.uuidString == "22222222-2222-2222-2222-222222222222" })
        #expect(daily.note == TaskNote(rtf: Data([0, 255]), plainText: "Заметка"))
        #expect(daily.completedAt == Date(timeIntervalSince1970: 1794564060))
        #expect(daily.labelIDs == Set(workspace.labels.map(\.id)))
        let draft = try #require(workspace.creationDraft)
        #expect(draft.note == TaskNote(rtf: Data([0, 254]), plainText: "Текст"))
        #expect(draft.children.isEmpty && draft.projectWasChosen && draft.labelsWereChosen && draft.dayWasChosen)
        let child = try workspace.addSubtask(parentOccurrenceID: ownerID, title: "New child")
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.activeSession == active)
        #expect(reopened.timeToolResults == workspace.timeToolResults)
        #expect(reopened.creationDraft == draft)
        #expect(reopened.children(of: ownerID).first?.occurrenceID == child.occurrenceID)
        #expect(reopened.children(of: ownerID).first?.parentTaskID == owner.id)
        try reopened.stopSession()
        try reopened.startPomodoro(occurrenceID: child.occurrenceID)
        #expect(reopened.activeSession?.pomodoro?.cycleCount == 4)
    }

    @Test func deletingLabelHidesChildDraftAssociationAndUndoRestoresItAfterCreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let label = try workspace.createLabel(title: "Child label")
        let child = SubtaskDraft(title: "Read", labelIDs: [label.id])
        let clearedChild = SubtaskDraft(title: "Clear this label", labelIDs: [label.id])
        try workspace.saveCreationDraft(CreationDraft(title: "Study", children: [child, clearedChild]))
        try workspace.deleteLabel(id: label.id)
        #expect(workspace.creationDraft?.children.first?.labelIDs.isEmpty == true)
        let reopened = try TaskWorkspace(databaseURL: url)
        let hidden = try #require(reopened.creationDraft)
        try reopened.saveCreationDraft(CreationDraft(title: "Renamed parent", children: hidden.children), replacingChildLabels: [clearedChild.id])
        let parent = try reopened.createTaskFromDraft()
        #expect(reopened.children(of: parent.occurrenceID).first?.labelIDs.isEmpty == true)
        try reopened.undoLabelDeletion()
        #expect(reopened.children(of: parent.occurrenceID).first?.labelIDs == [label.id])
        #expect(reopened.children(of: parent.occurrenceID).last?.labelIDs.isEmpty == true)
    }

}
