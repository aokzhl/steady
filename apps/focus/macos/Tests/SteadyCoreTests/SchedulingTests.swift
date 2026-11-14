import Foundation
import SteadyCore
import Testing

@MainActor
struct SchedulingTests {
    @Test func explicitDayAndNoDateSurviveReopeningWithoutChangingCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let task = try workspace.createTask(title: "План", plannedDay: "2026-11-10")
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        let completedAt = workspace.tasks.first?.completedAt
        try workspace.setPlannedDay(occurrenceID: task.occurrenceID, day: nil)
        let saved = try #require(TaskWorkspace(databaseURL: url).tasks.first)
        #expect(saved.plannedDay == nil)
        #expect(saved.id == task.id)
        #expect(saved.occurrenceID == task.occurrenceID)
        #expect(saved.completedAt == completedAt)
    }
    @Test func generalCreationIsUndatedAndAnExplicitNoDateDraftIsDurable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let task = try workspace.createTask(title: "Когда-нибудь")
        #expect(task.plannedDay == nil)
        try workspace.saveCreationDraft(CreationDraft(dayWasChosen: true))
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.creationDraft?.dayWasChosen == true)
        #expect(reopened.creationDraft?.plannedDay == nil)
        try reopened.saveCreationDraft(CreationDraft(title: "Потом", plannedDay: "2027-01-02", dayWasChosen: true))
        let resumed = try TaskWorkspace(databaseURL: url)
        let planned = try resumed.createTaskFromDraft()
        #expect(planned.plannedDay == "2027-01-02")
        #expect(try TaskWorkspace(databaseURL: url).tasks == [task, planned])
    }

    @Test func todayAndTomorrowFollowTheCurrentZoneWhileSavedDaysStayFixed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = try Date("2026-12-31T23:30:00Z", strategy: .iso8601)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: { calendar })
        #expect(workspace.today == "2026-12-31")
        #expect(workspace.tomorrow == "2027-01-01")
        let old = try workspace.createTask(title: "Вчера", plannedDay: workspace.today)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Almaty"))
        try workspace.reload()
        #expect(workspace.today == "2027-01-01")
        #expect(workspace.tomorrow == "2027-01-02")
        #expect(workspace.openToday == [old])
        let new = try workspace.createTask(title: "Сегодня", plannedDay: workspace.today)
        #expect(new.timeZoneIdentifier == "Asia/Almaty")
        instant = try Date("2027-01-02T01:00:00Z", strategy: .iso8601)
        try workspace.reload()
        #expect(workspace.openToday.map(\.id) == [old.id, new.id])
        #expect(try TaskWorkspace(databaseURL: url).tasks == [old, new])
    }

    @Test func tomorrowUsesCalendarDaysAcrossDaylightSavingTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let instant = try Date("2026-03-08T04:30:00Z", strategy: .iso8601)
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"), now: { instant }, calendar: { calendar })
        #expect(workspace.today == "2026-03-07")
        #expect(workspace.tomorrow == "2026-03-08")
    }

    @Test(arguments: ["2026-02-30", "2026-2-1", "", "2026-13-01"])
    func invalidDaysCannotChangeSavedFacts(day: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let task = try workspace.createTask(title: "План", plannedDay: "2026-11-14")
        #expect(throws: WorkspaceError.invalidDay) { try workspace.setPlannedDay(occurrenceID: task.occurrenceID, day: day) }
        #expect(throws: WorkspaceError.invalidDay) { try workspace.createTask(title: "План", plannedDay: day) }
        #expect(throws: WorkspaceError.invalidDay) { try workspace.saveCreationDraft(CreationDraft(plannedDay: day)) }
        #expect(try TaskWorkspace(databaseURL: url).tasks == [task])
    }

    @Test func scheduleWriteFailureKeepsSavedDayAndCanBeRetried() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let task = try workspace.createTask(title: "План", plannedDay: "2026-11-14")
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        #expect(throws: (any Error).self) { try workspace.setPlannedDay(occurrenceID: task.occurrenceID, day: nil) }
        #expect(workspace.tasks == [task])
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        try workspace.setPlannedDay(occurrenceID: task.occurrenceID, day: nil)
        #expect(try TaskWorkspace(databaseURL: url).tasks.first?.plannedDay == nil)
        #expect(throws: WorkspaceError.occurrenceNotFound) { try workspace.setPlannedDay(occurrenceID: UUID(), day: nil) }
    }

    @Test(arguments: [3, 4]) func legacyDatesProjectsNotesAndDraftMigrateWithoutLosingFacts(version: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("steady.sqlite")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        fixture.arguments = [url.path, """
            CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, color TEXT, created_at REAL NOT NULL);
            CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, created_at REAL NOT NULL, priority TEXT NOT NULL, project_id TEXT REFERENCES projects(id));
            CREATE TABLE task_occurrences (id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL REFERENCES tasks(id), planned_day TEXT NOT NULL, time_zone TEXT NOT NULL, completed_at REAL);
            CREATE TABLE creation_draft (id INTEGER PRIMARY KEY, title TEXT NOT NULL, priority TEXT NOT NULL, project_id TEXT REFERENCES projects(id), project_was_chosen INTEGER NOT NULL);
            INSERT INTO projects VALUES ('33333333-3333-3333-3333-333333333333', 'Проект', 'blue', 1800000000);
            INSERT INTO tasks VALUES ('11111111-1111-1111-1111-111111111111', 'Старый план', 1800000000, 'high', '33333333-3333-3333-3333-333333333333');
            INSERT INTO task_occurrences VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', '2026-11-12', 'Asia/Almaty', 1800000001.125);
            INSERT INTO creation_draft VALUES (1, 'Старый черновик', 'low', NULL, 1);
            \(version == 4 ? "ALTER TABLE tasks ADD COLUMN note_rtf BLOB NOT NULL DEFAULT X''; ALTER TABLE tasks ADD COLUMN note_text TEXT NOT NULL DEFAULT ''; ALTER TABLE creation_draft ADD COLUMN note_rtf BLOB NOT NULL DEFAULT X''; ALTER TABLE creation_draft ADD COLUMN note_text TEXT NOT NULL DEFAULT ''; UPDATE tasks SET note_rtf = X'00FF7B5C7D', note_text = 'Заметка задачи'; UPDATE creation_draft SET note_rtf = X'00FE7B5C7D', note_text = 'Заметка черновика';" : "")
            PRAGMA user_version = \(version);
            """]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        let workspace = try TaskWorkspace(databaseURL: url)
        let old = try #require(workspace.tasks.first)
        #expect(old.id.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(old.occurrenceID.uuidString == "22222222-2222-2222-2222-222222222222")
        #expect(old.plannedDay == "2026-11-12")
        #expect(old.timeZoneIdentifier == "Asia/Almaty")
        #expect(old.completedAt == Date(timeIntervalSince1970: 1_800_000_001.125))
        #expect(old.priority == .high)
        #expect(old.projectID == workspace.projects.first?.id)
        let oldNote = version == 4 ? TaskNote(rtf: Data([0, 255, 123, 92, 125]), plainText: "Заметка задачи") : .empty
        let oldDraftNote = version == 4 ? TaskNote(rtf: Data([0, 254, 123, 92, 125]), plainText: "Заметка черновика") : .empty
        #expect(old.note == oldNote)
        #expect(workspace.creationDraft == CreationDraft(title: "Старый черновик", priority: .low, projectWasChosen: true, note: oldDraftNote))
        try workspace.setPlannedDay(occurrenceID: old.occurrenceID, day: nil)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.tasks.first?.plannedDay == nil)
        #expect(reopened.tasks.first?.completedAt == old.completedAt)
        #expect(reopened.tasks.first?.note == oldNote)
        #expect(reopened.creationDraft == workspace.creationDraft)
    }

    @Test func creationUsesTheDayContextUntilTheUserExplicitlyChoosesADayOrNoDate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        try workspace.prepareCreationDraft(plannedDay: "2026-11-14")
        #expect(workspace.creationDraft?.plannedDay == "2026-11-14")
        try workspace.prepareCreationDraft()
        #expect(workspace.creationDraft == nil)
        try workspace.saveCreationDraft(CreationDraft(title: "Без даты явно", dayWasChosen: true))
        let reopened = try TaskWorkspace(databaseURL: url)
        try reopened.prepareCreationDraft(plannedDay: "2026-11-15")
        #expect(reopened.creationDraft?.plannedDay == nil)
        let note = TaskNote(rtf: Data([123, 92, 114, 116, 102, 49, 125]), plainText: "Сохранить заметку")
        try reopened.saveCreationDraft(CreationDraft(title: "Выбранный день", plannedDay: "2026-12-01", dayWasChosen: true, note: note))
        try reopened.prepareCreationDraft(plannedDay: "2026-11-15")
        #expect(reopened.creationDraft?.plannedDay == "2026-12-01")
        let created = try reopened.createTaskFromDraft()
        #expect(created.plannedDay == "2026-12-01")
        #expect(created.note == note)
        #expect(try TaskWorkspace(databaseURL: url).tasks == [created])
    }

}
