import Foundation
import SteadyCore
import Testing

@MainActor
struct TaskNoteTests {
    @Test
    func noteInCreationDraftSurvivesReopeningAndBecomesTheTaskNote() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        // A fixture with bold, highlight, a link and two paragraphs. Core treats RTF as opaque bytes.
        let note = TaskNote(rtf: Data(#"{\rtf1\ansi{\colortbl;\red255\green255\blue0;}\b Read\b0\par \highlight1 Carefully\highlight0\par {\field{\*\fldinst HYPERLINK "https://example.com"}{\fldrslt Reference}}}"#.utf8), plainText: "Read\nCarefully\nReference")
        try workspace.saveCreationDraft(CreationDraft(note: note))
        let continued = try TaskWorkspace(databaseURL: url)
        #expect(continued.creationDraft?.note == note)
        #expect(continued.tasks.isEmpty)
        #expect(throws: WorkspaceError.emptyTitle) { try continued.createTaskFromDraft() }
        #expect(try TaskWorkspace(databaseURL: url).creationDraft?.note == note)
        try continued.saveCreationDraft(CreationDraft(title: "Read the guide", note: note))
        let created = try continued.createTaskFromDraft()
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.tasks.first?.note == note)
        #expect(reopened.tasks.first?.id == created.id)
        #expect(reopened.creationDraft == nil)
    }
    @Test
    func editingAndClearingTaskNotePreservesTaskAndOccurrenceFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let task = try workspace.createTask(title: "Keep my instructions")
        #expect(task.note == .empty)
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        let completed = try #require(workspace.tasks.first)
        let text = String(repeating: "• Read carefully 📖\n", count: 2_000)
        let note = TaskNote(rtf: Data([0, 255, 13, 10, 42]), plainText: text)
        try workspace.setNote(id: task.id, note: note)
        let reopened = try TaskWorkspace(databaseURL: url)
        let edited = try #require(reopened.tasks.first)
        #expect(edited.note == note)
        #expect(edited.id == completed.id)
        #expect(edited.occurrenceID == completed.occurrenceID)
        #expect(edited.completedAt == completed.completedAt)
        #expect(edited.plannedDay == completed.plannedDay)
        #expect(throws: WorkspaceError.occurrenceNotFound) { try reopened.setNote(id: UUID(), note: note) }
        try reopened.setNote(id: task.id, note: .empty)
        #expect(try TaskWorkspace(databaseURL: url).tasks.first?.note == .empty)
    }

    @Test
    func noteWriteFailureKeepsSavedNoteAndDraftForRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let old = TaskNote(rtf: Data("old rich text".utf8), plainText: "Saved instructions")
        let new = TaskNote(rtf: Data("new rich text".utf8), plainText: "New instructions\nSecond line")
        let task = try workspace.createTask(title: "Instructions", note: old)
        let draft = CreationDraft(title: "Draft", note: old)
        try workspace.saveCreationDraft(draft)
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        #expect(throws: (any Error).self) { try workspace.setNote(id: task.id, note: new) }
        #expect(throws: (any Error).self) { try workspace.saveCreationDraft(CreationDraft(title: "Draft", note: new)) }
        #expect(workspace.tasks.first?.note == old)
        #expect(workspace.creationDraft == draft)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        let recovered = try TaskWorkspace(databaseURL: url)
        #expect(recovered.tasks.first?.note == old)
        #expect(recovered.creationDraft == draft)
        try workspace.setNote(id: task.id, note: new)
        try workspace.saveCreationDraft(CreationDraft(title: "Draft", note: new))
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.tasks.first?.note == new)
        #expect(reopened.creationDraft?.note == new)
    }

    @Test
    func versionTwoTasksAndDraftMigrateWithEmptyNotesAndKeepTheirFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("steady.sqlite")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        fixture.arguments = [url.path, """
            CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, created_at REAL NOT NULL, priority TEXT NOT NULL DEFAULT 'none');
            CREATE TABLE task_occurrences (id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL REFERENCES tasks(id), planned_day TEXT NOT NULL, time_zone TEXT NOT NULL, completed_at REAL);
            CREATE TABLE creation_draft (id INTEGER PRIMARY KEY CHECK(id = 1), title TEXT NOT NULL, priority TEXT NOT NULL);
            INSERT INTO tasks VALUES ('11111111-1111-1111-1111-111111111111', 'Existing', 1800000000, 'high');
            INSERT INTO task_occurrences VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', '2026-11-12', 'Asia/Almaty', 1800000001.125);
            INSERT INTO creation_draft VALUES (1, 'Continue', 'low');
            PRAGMA user_version = 2;
            """]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        let workspace = try TaskWorkspace(databaseURL: url)
        let migrated = try #require(workspace.tasks.first)
        #expect(migrated.note == .empty)
        #expect(migrated.title == "Existing")
        #expect(migrated.priority == .high)
        #expect(migrated.occurrenceID.uuidString == "22222222-2222-2222-2222-222222222222")
        #expect(migrated.plannedDay == "2026-11-12")
        #expect(migrated.timeZoneIdentifier == "Asia/Almaty")
        #expect(migrated.completedAt == Date(timeIntervalSince1970: 1_800_000_001.125))
        #expect(workspace.creationDraft == CreationDraft(title: "Continue", priority: .low))
        let note = TaskNote(rtf: Data("migrated note".utf8), plainText: "New instruction")
        try workspace.setNote(id: migrated.id, note: note)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.tasks.first?.note == note)
        #expect(reopened.creationDraft?.note == .empty)
    }

    @Test
    func changedDraftNoteCannotBeConsumedByAStaleWindow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        try workspace.saveCreationDraft(CreationDraft(title: "Same title"))
        let stale = try TaskWorkspace(databaseURL: url)
        let updated = TaskNote(rtf: Data("updated".utf8), plainText: "Updated instructions")
        try workspace.saveCreationDraft(CreationDraft(title: "Same title", note: updated))
        #expect(throws: WorkspaceError.draftChanged) { try stale.createTaskFromDraft() }
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.tasks.isEmpty)
        #expect(reopened.creationDraft?.note == updated)
    }

}
