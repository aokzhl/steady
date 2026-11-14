import Foundation
import SteadyCore
import Testing

@MainActor
struct LabelTests {
    @Test
    func globalLabelsPersistRenameAndRejectCaseOnlyDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let label = try workspace.createLabel(title: "  Учёба 📖  ", color: .blue)
        #expect(label.title == "Учёба 📖")
        #expect(label.color == .blue)
        #expect(throws: WorkspaceError.duplicateLabel) { try workspace.createLabel(title: "УЧЁБА 📖") }
        #expect(throws: WorkspaceError.emptyLabelTitle) { try workspace.createLabel(title: " \n") }
        #expect(throws: WorkspaceError.invalidTitle) { try workspace.createLabel(title: "До\0После") }
        let second = try workspace.createLabel(title: "Здоровье")
        #expect(throws: WorkspaceError.duplicateLabel) { try workspace.renameLabel(id: second.id, title: "учёба 📖") }
        try workspace.renameLabel(id: label.id, title: "Читать")
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.labels.map(\.id) == [label.id, second.id])
        #expect(reopened.labels.first?.title == "Читать")
        #expect(reopened.labels.first?.color == .blue)
    }
    @Test
    func multipleGlobalLabelsCrossProjectsAndPersistInTasksAndDrafts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let first = try workspace.createLabel(title: "Чтение")
        let second = try workspace.createLabel(title: "Вечер")
        let project = try workspace.createProject(title: "Учёба")
        let task = try workspace.createTask(title: "Книга", projectID: project.id, labelIDs: [first.id, second.id])
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        let completed = try #require(workspace.tasks.first)
        let other = try workspace.createTask(title: "Дома", labelIDs: [first.id])
        try workspace.saveCreationDraft(CreationDraft(title: "Следующее", projectWasChosen: true, labelIDs: [second.id]))
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.tasks.first?.labelIDs == [first.id, second.id])
        #expect(reopened.tasks.last?.labelIDs == [first.id])
        #expect(reopened.creationDraft?.labelIDs == [second.id])
        let created = try reopened.createTaskFromDraft()
        #expect(created.labelIDs == [second.id])
        #expect(created.projectID == nil)
        try reopened.setLabels(id: task.id, labelIDs: [second.id])
        let edited = try #require(reopened.tasks.first)
        #expect(edited.id == task.id)
        #expect(edited.occurrenceID == task.occurrenceID)
        #expect(edited.projectID == project.id)
        #expect(edited.completedAt == completed.completedAt)
        #expect(edited.labelIDs == [second.id])
        #expect(reopened.tasks[1] == other)
        try reopened.saveCreationDraft(CreationDraft(labelsWereChosen: true))
        #expect(try TaskWorkspace(databaseURL: url).creationDraft == CreationDraft(labelsWereChosen: true))
        #expect(throws: WorkspaceError.labelNotFound) { try reopened.setLabels(id: task.id, labelIDs: [UUID()]) }
        #expect(try TaskWorkspace(databaseURL: url).tasks.first == edited)
    }

    @Test
    func deletingAndUndoingLabelPreservesTasksFactsAndDraftAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let removed = try workspace.createLabel(title: "Читать")
        let kept = try workspace.createLabel(title: "Вечер")
        let task = try workspace.createTask(title: "Дело", labelIDs: [removed.id, kept.id])
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        let completed = try #require(workspace.tasks.first)
        let draft = CreationDraft(title: "Черновик", projectWasChosen: true, labelIDs: [removed.id])
        try workspace.saveCreationDraft(draft)
        try workspace.deleteLabel(id: removed.id)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.labels == [kept])
        #expect(reopened.lastDeletedLabel == removed)
        #expect(reopened.tasks.first?.labelIDs == [kept.id])
        #expect(reopened.tasks.first?.completedAt == completed.completedAt)
        #expect(reopened.tasks.first?.occurrenceID == task.occurrenceID)
        #expect(reopened.creationDraft?.labelIDs.isEmpty == true)
        try reopened.undoLabelDeletion()
        let restored = try TaskWorkspace(databaseURL: url)
        #expect(restored.labels == [removed, kept])
        #expect(restored.tasks == [completed])
        #expect(restored.creationDraft == draft)
        #expect(restored.lastDeletedLabel == nil)
    }

    @Test
    func unrelatedDraftEditsKeepDeletedLabelAssociationsForUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let label = try workspace.createLabel(title: "Читать")
        let project = try workspace.createProject(title: "Учёба")
        let task = try workspace.createTask(title: "Книга", labelIDs: [label.id])
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        let completed = try #require(workspace.tasks.first)
        try workspace.saveCreationDraft(CreationDraft(title: "Черновик", labelIDs: [label.id], labelsWereChosen: true))
        try workspace.deleteLabel(id: label.id)
        let reopened = try TaskWorkspace(databaseURL: url)
        let hidden = try #require(reopened.creationDraft)
        #expect(hidden.labelIDs.isEmpty)
        let note = TaskNote(rtf: Data([0, 128, 255]), plainText: "Новая заметка")
        try reopened.saveCreationDraft(CreationDraft(title: "Новое название", priority: .high, projectID: project.id, projectWasChosen: true, note: note, labelIDs: hidden.labelIDs, labelsWereChosen: hidden.labelsWereChosen))
        let edited = try TaskWorkspace(databaseURL: url)
        #expect(edited.creationDraft?.labelIDs.isEmpty == true)
        try edited.undoLabelDeletion()
        let restored = try TaskWorkspace(databaseURL: url)
        #expect(restored.creationDraft == CreationDraft(title: "Новое название", priority: .high, projectID: project.id, projectWasChosen: true, note: note, labelIDs: [label.id], labelsWereChosen: true))
        #expect(restored.tasks == [completed])
    }

    @Test(arguments: [false, true])
    func explicitDraftLabelReassignmentReplacesDeletedAssociations(chooseEmpty: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let old = try workspace.createLabel(title: "Чтение")
        let other = try workspace.createLabel(title: "Дом")
        let task = try workspace.createTask(title: "Книга", labelIDs: [old.id])
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        let completed = try #require(workspace.tasks.first)
        try workspace.saveCreationDraft(CreationDraft(title: "Черновик", labelIDs: [old.id], labelsWereChosen: true))
        try workspace.deleteLabel(id: old.id)
        let reopened = try TaskWorkspace(databaseURL: url)
        let selection: Set<UUID> = chooseEmpty ? [] : [other.id]
        let reassigned = CreationDraft(title: "Черновик", labelIDs: selection, labelsWereChosen: true)
        try reopened.saveCreationDraft(reassigned, replacingLabels: true)
        let edited = try TaskWorkspace(databaseURL: url)
        try edited.undoLabelDeletion()
        let restored = try TaskWorkspace(databaseURL: url)
        #expect(restored.creationDraft == reassigned)
        #expect(restored.labels == [old, other])
        #expect(restored.tasks == [completed])
    }

    @Test
    func versionFourDataKeepsRichNotesProjectChoiceAndTaskFactsAfterLabelMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("steady.sqlite")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        fixture.arguments = [url.path, """
            CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, color TEXT, created_at REAL NOT NULL);
            CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, created_at REAL NOT NULL, priority TEXT NOT NULL, project_id TEXT REFERENCES projects(id), note_rtf BLOB NOT NULL, note_text TEXT NOT NULL);
            CREATE TABLE task_occurrences (id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL REFERENCES tasks(id), planned_day TEXT NOT NULL, time_zone TEXT NOT NULL, completed_at REAL);
            CREATE TABLE creation_draft (id INTEGER PRIMARY KEY CHECK(id = 1), title TEXT NOT NULL, priority TEXT NOT NULL, project_id TEXT REFERENCES projects(id), project_was_chosen INTEGER NOT NULL DEFAULT 0, note_rtf BLOB NOT NULL, note_text TEXT NOT NULL);
            INSERT INTO projects VALUES ('33333333-3333-3333-3333-333333333333', 'Учёба', 'blue', 1800000000);
            INSERT INTO tasks VALUES ('11111111-1111-1111-1111-111111111111', 'Старое дело', 1800000000, 'high', '33333333-3333-3333-3333-333333333333', X'0001FF', 'Описание');
            INSERT INTO task_occurrences VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', '2026-11-12', 'Asia/Almaty', 1800000001.125);
            INSERT INTO creation_draft VALUES (1, '', 'none', NULL, 1, X'0203', 'Черновая заметка');
            PRAGMA user_version = 4;
            """]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        let workspace = try TaskWorkspace(databaseURL: url)
        let task = try #require(workspace.tasks.first)
        #expect(task.title == "Старое дело")
        #expect(task.occurrenceID.uuidString == "22222222-2222-2222-2222-222222222222")
        #expect(task.projectID?.uuidString == "33333333-3333-3333-3333-333333333333")
        #expect(task.plannedDay == "2026-11-12")
        #expect(task.completedAt == Date(timeIntervalSince1970: 1_800_000_001.125))
        #expect(task.priority == .high)
        #expect(task.labelIDs.isEmpty)
        #expect(task.note == TaskNote(rtf: Data([0, 1, 255]), plainText: "Описание"))
        #expect(workspace.creationDraft == CreationDraft(projectWasChosen: true, note: TaskNote(rtf: Data([2, 3]), plainText: "Черновая заметка")))
        let label = try workspace.createLabel(title: "Новое")
        try workspace.setLabels(id: task.id, labelIDs: [label.id])
        #expect(try TaskWorkspace(databaseURL: url).tasks.first?.labelIDs == [label.id])
    }

    @Test
    func versionSixMigrationKeepsUndatedTasksDraftChoicesAndStopwatchFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("steady.sqlite")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        fixture.arguments = [url.path, """
            CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, color TEXT, created_at REAL NOT NULL);
            CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, created_at REAL NOT NULL, priority TEXT NOT NULL, project_id TEXT REFERENCES projects(id), note_rtf BLOB NOT NULL, note_text TEXT NOT NULL);
            CREATE TABLE task_occurrences (id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL REFERENCES tasks(id), planned_day TEXT, time_zone TEXT NOT NULL, completed_at REAL);
            CREATE TABLE creation_draft (id INTEGER PRIMARY KEY CHECK(id = 1), title TEXT NOT NULL, priority TEXT NOT NULL, project_id TEXT REFERENCES projects(id), project_was_chosen INTEGER NOT NULL DEFAULT 0, note_rtf BLOB NOT NULL, note_text TEXT NOT NULL, planned_day TEXT, day_was_chosen INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE time_tool_runs (id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, task_id TEXT REFERENCES tasks(id), occurrence_id TEXT REFERENCES task_occurrences(id), owner_title TEXT NOT NULL, started_at REAL NOT NULL, time_zone TEXT NOT NULL, stopped_at REAL);
            CREATE UNIQUE INDEX one_active_time_tool ON time_tool_runs ((1)) WHERE stopped_at IS NULL;
            CREATE TABLE time_tool_segments (id TEXT PRIMARY KEY NOT NULL, run_id TEXT NOT NULL REFERENCES time_tool_runs(id), position INTEGER NOT NULL, started_at REAL NOT NULL, ended_at REAL CHECK(ended_at >= started_at), UNIQUE(run_id, position));
            INSERT INTO projects VALUES ('33333333-3333-3333-3333-333333333333', 'Учёба', 'blue', 1800000000);
            INSERT INTO tasks VALUES ('11111111-1111-1111-1111-111111111111', 'Книга', 1800000000, 'high', '33333333-3333-3333-3333-333333333333', X'0001FF', 'Описание');
            INSERT INTO task_occurrences VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', NULL, 'Asia/Almaty', 1800000100);
            INSERT INTO creation_draft VALUES (1, 'Черновик', 'low', NULL, 1, X'0203', 'Заметка', NULL, 1);
            INSERT INTO time_tool_runs VALUES ('44444444-4444-4444-4444-444444444444', 'stopwatch', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'Книга', 1800000000, 'Asia/Almaty', 1800000060);
            INSERT INTO time_tool_segments VALUES ('55555555-5555-5555-5555-555555555555', '44444444-4444-4444-4444-444444444444', 0, 1800000000, 1800000060);
            PRAGMA user_version = 6;
            """]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        let workspace = try TaskWorkspace(databaseURL: url)
        let task = try #require(workspace.tasks.first)
        #expect(task.plannedDay == nil)
        #expect(task.completedAt == Date(timeIntervalSince1970: 1_800_000_100))
        #expect(task.note == TaskNote(rtf: Data([0, 1, 255]), plainText: "Описание"))
        #expect(task.projectID == workspace.projects.first?.id)
        let draft = CreationDraft(title: "Черновик", priority: .low, projectWasChosen: true, dayWasChosen: true, note: TaskNote(rtf: Data([2, 3]), plainText: "Заметка"))
        #expect(workspace.creationDraft == draft)
        let result = try #require(workspace.timeToolResults.first)
        #expect(result.id.uuidString == "44444444-4444-4444-4444-444444444444")
        #expect(result.occurrenceID == task.occurrenceID)
        #expect(result.durationSeconds == 60)
        #expect(result.timeZoneIdentifier == "Asia/Almaty")
        let label = try workspace.createLabel(title: "Читать")
        try workspace.setLabels(id: task.id, labelIDs: [label.id])
        let prepared = try workspace.prepareCreationDraft(plannedDay: "2027-01-02", labelIDs: [label.id])
        #expect(prepared == draft)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.tasks.first?.labelIDs == [label.id])
        #expect(reopened.tasks.first?.plannedDay == nil)
        #expect(reopened.creationDraft == draft)
        #expect(reopened.timeToolResults == [result])
    }

    @Test
    func failedLabelWritesKeepSavedStateAndAllowRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let label = try workspace.createLabel(title: "Сохранено")
        let removed = try workspace.createLabel(title: "Удалено")
        let task = try workspace.createTask(title: "Дело", labelIDs: [label.id])
        let draft = CreationDraft(title: "Черновик", labelIDs: [label.id])
        try workspace.saveCreationDraft(draft)
        try workspace.deleteLabel(id: removed.id)
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        #expect(throws: (any Error).self) { try workspace.createLabel(title: "Новое") }
        #expect(throws: (any Error).self) { try workspace.renameLabel(id: label.id, title: "Правка") }
        #expect(throws: (any Error).self) { try workspace.setLabels(id: task.id, labelIDs: []) }
        #expect(throws: (any Error).self) { try workspace.deleteLabel(id: label.id) }
        #expect(throws: (any Error).self) { try workspace.undoLabelDeletion() }
        #expect(workspace.labels == [label])
        #expect(workspace.tasks == [task])
        #expect(workspace.creationDraft == draft)
        #expect(workspace.lastDeletedLabel == removed)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        try workspace.undoLabelDeletion()
        try workspace.renameLabel(id: label.id, title: "Правка")
        #expect(try TaskWorkspace(databaseURL: url).labels.map(\.title) == ["Правка", "Удалено"])
    }

    @Test
    func undoDoesNotOverwriteNewAssignmentsOrCreateDuplicateLabelNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let old = try workspace.createLabel(title: "Чтение")
        let other = try workspace.createLabel(title: "Дом")
        let task = try workspace.createTask(title: "Книга", labelIDs: [old.id])
        try workspace.deleteLabel(id: old.id)
        let replacement = try workspace.createLabel(title: "ЧТЕНИЕ")
        #expect(throws: WorkspaceError.duplicateLabel) { try workspace.undoLabelDeletion() }
        #expect(workspace.lastDeletedLabel == old)
        try workspace.renameLabel(id: replacement.id, title: "Новое чтение")
        try workspace.setLabels(id: task.id, labelIDs: [other.id])
        try workspace.undoLabelDeletion()
        #expect(workspace.tasks.first?.labelIDs == [other.id])
        #expect(workspace.labels.count == 3)
        #expect(try TaskWorkspace(databaseURL: url).tasks.first?.labelIDs == [other.id])
    }

    @Test
    func labelChangesKeepRichNotesAndOtherDraftFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let project = try workspace.createProject(title: "Работа")
        let label = try workspace.createLabel(title: "Чтение")
        let note = TaskNote(rtf: Data([0, 128, 255]), plainText: "Заметка со ссылкой")
        let draft = CreationDraft(title: "Черновик", priority: .high, projectID: project.id, projectWasChosen: true, note: note, labelIDs: [label.id], labelsWereChosen: true)
        try workspace.saveCreationDraft(draft)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.creationDraft == draft)
        let task = try reopened.createTaskFromDraft()
        #expect(task.note == note)
        #expect(task.projectID == project.id)
        #expect(task.priority == .high)
        try reopened.deleteLabel(id: label.id)
        #expect(reopened.tasks.first?.note == note)
        try reopened.undoLabelDeletion()
        #expect(reopened.tasks == [task])
        try reopened.setLabels(id: task.id, labelIDs: [])
        #expect(try TaskWorkspace(databaseURL: url).tasks.first?.note == note)
    }

}
