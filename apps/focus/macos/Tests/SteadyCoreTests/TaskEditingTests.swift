import Foundation
import SteadyCore
import Testing

@MainActor
struct TaskEditingTests {
    @Test
    func versionOneTasksMigrateWithoutChangingTheirFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("steady.sqlite")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        fixture.arguments = [url.path, """
            CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL CHECK(length(trim(title)) > 0), created_at REAL NOT NULL);
            CREATE TABLE task_occurrences (id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL REFERENCES tasks(id), planned_day TEXT NOT NULL, time_zone TEXT NOT NULL, completed_at REAL);
            INSERT INTO tasks VALUES ('11111111-1111-1111-1111-111111111111', 'Старая задача', 1800000000);
            INSERT INTO task_occurrences VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', '2026-11-12', 'Asia/Almaty', 1800000001.125);
            PRAGMA user_version = 1;
            """]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        let workspace = try TaskWorkspace(databaseURL: url)
        let old = try #require(workspace.tasks.first)
        #expect(old.title == "Старая задача")
        #expect(old.id.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(old.occurrenceID.uuidString == "22222222-2222-2222-2222-222222222222")
        #expect(old.plannedDay == "2026-11-12")
        #expect(old.timeZoneIdentifier == "Asia/Almaty")
        #expect(old.completedAt == Date(timeIntervalSince1970: 1_800_000_001.125))
        #expect(old.priority == .none)
        #expect(workspace.creationDraft == nil)
        try workspace.saveCreationDraft(CreationDraft(title: "Новый черновик"))
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.tasks == [old])
        #expect(reopened.creationDraft?.title == "Новый черновик")
    }

    @Test(arguments: ["", " \n\t", "\u{2003}", "До\0После"])
    func invalidRenameKeepsTheSavedTask(title: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let task = try workspace.createTask(title: "Сохранённое название")
        #expect(throws: (any Error).self) { try workspace.renameTask(id: task.id, title: title) }
        #expect(throws: WorkspaceError.occurrenceNotFound) { try workspace.renameTask(id: UUID(), title: "Другое") }
        #expect(throws: WorkspaceError.occurrenceNotFound) { try workspace.setPriority(id: UUID(), priority: .high) }
        #expect(try TaskWorkspace(databaseURL: url).tasks == [task])
    }

    @Test
    func writeFailuresKeepTasksAndDraftUntilSuccessfulRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let task = try workspace.createTask(title: "Прежнее дело")
        let savedDraft = CreationDraft(title: "Из черновика", priority: .high)
        try workspace.saveCreationDraft(savedDraft)
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        #expect(throws: (any Error).self) { try workspace.renameTask(id: task.id, title: "Новое название") }
        #expect(throws: (any Error).self) { try workspace.setPriority(id: task.id, priority: .lowest) }
        #expect(throws: (any Error).self) { try workspace.saveCreationDraft(CreationDraft(title: "Новый ввод")) }
        #expect(throws: (any Error).self) { try workspace.discardCreationDraft() }
        #expect(throws: (any Error).self) { try workspace.createTaskFromDraft() }
        #expect(workspace.tasks == [task])
        #expect(workspace.creationDraft == savedDraft)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        let recovered = try TaskWorkspace(databaseURL: url)
        #expect(recovered.creationDraft == savedDraft)
        let created = try workspace.createTaskFromDraft()
        try workspace.renameTask(id: task.id, title: "Новое название")
        try workspace.setPriority(id: task.id, priority: .lowest)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.creationDraft == nil)
        #expect(reopened.tasks.count == 2)
        #expect(reopened.tasks.last == created)
        #expect(reopened.tasks.first?.title == "Новое название")
        #expect(reopened.tasks.first?.priority == .lowest)
    }

    @Test
    func aStaleDraftCannotCreateTheSameTaskTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        try workspace.saveCreationDraft(CreationDraft(title: "Один раз"))
        let stale = try TaskWorkspace(databaseURL: url)
        let task = try workspace.createTaskFromDraft()
        #expect(throws: WorkspaceError.draftChanged) { try stale.createTaskFromDraft() }
        #expect(try TaskWorkspace(databaseURL: url).tasks == [task])
    }

    @Test
    func priorityOnlyDraftAndSeparateGuestSpacesSurviveReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = try TaskWorkspace.guestDatabaseURL(in: directory.appendingPathComponent("first"))
        let secondURL = try TaskWorkspace.guestDatabaseURL(in: directory.appendingPathComponent("second"))
        let workspace = try TaskWorkspace(databaseURL: firstURL)
        try workspace.saveCreationDraft(CreationDraft())
        #expect(try TaskWorkspace(databaseURL: firstURL).creationDraft == nil)
        try workspace.saveCreationDraft(CreationDraft(priority: .low))
        let reopened = try TaskWorkspace(databaseURL: firstURL)
        #expect(reopened.creationDraft == CreationDraft(priority: .low))
        #expect(throws: WorkspaceError.emptyTitle) { try reopened.createTaskFromDraft() }
        #expect(try TaskWorkspace(databaseURL: secondURL).creationDraft == nil)
        #expect(reopened.tasks.isEmpty)
    }

    @Test
    func invalidDraftTextIsKeptExactlyButCannotCreateATask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        try workspace.saveCreationDraft(CreationDraft(title: "До\0После"))
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.creationDraft?.title == "До\0После")
        #expect(throws: WorkspaceError.invalidTitle) { try reopened.createTaskFromDraft() }
        #expect(reopened.tasks.isEmpty)
    }

    @Test
    func creatingFromDraftConsumesItOnceAndDiscardDoesNotCreateTasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        try workspace.saveCreationDraft(CreationDraft(title: "  Создать из черновика  ", priority: .highest))
        let created = try workspace.createTaskFromDraft()
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.creationDraft == nil)
        #expect(reopened.tasks == [created])
        #expect(created.title == "Создать из черновика")
        #expect(created.priority == .highest)
        #expect(throws: WorkspaceError.emptyTitle) { try reopened.createTaskFromDraft() }
        try reopened.saveCreationDraft(CreationDraft(title: "Удалить", priority: .low))
        try reopened.discardCreationDraft()
        let afterDiscard = try TaskWorkspace(databaseURL: url)
        #expect(afterDiscard.creationDraft == nil)
        #expect(afterDiscard.tasks == [created])
    }

    @Test
    func unfinishedDraftSurvivesReopeningWithoutCreatingATask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        #expect(workspace.creationDraft == nil)
        try workspace.saveCreationDraft(CreationDraft(title: "  Продолжить завтра 📖  ", priority: .high))

        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.tasks.isEmpty)
        #expect(reopened.creationDraft?.title == "  Продолжить завтра 📖  ")
        #expect(reopened.creationDraft?.priority == .high)
    }

    @Test
    func priorityIsPersistentMetadataAndDoesNotReorderTasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let first = try workspace.createTask(title: "Первое дело")
        let second = try workspace.createTask(title: "Второе дело")
        #expect(first.priority == .none)
        for priority in TaskPriority.allCases {
            try workspace.setPriority(id: second.id, priority: priority)
            let reopened = try TaskWorkspace(databaseURL: url)
            #expect(reopened.tasks.map(\.id) == [first.id, second.id])
            #expect(reopened.tasks.last?.priority == priority)
            #expect(reopened.tasks.last?.completedAt == nil)
            #expect(reopened.tasks.last?.occurrenceID == second.occurrenceID)
        }
    }

    @Test
    func renameSurvivesReopeningAndPreservesOccurrenceFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let task = try workspace.createTask(title: "До правки")
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        let completed = try #require(workspace.tasks.first)

        try workspace.renameTask(id: task.id, title: "  После правки 📖  ")
        let reopened = try TaskWorkspace(databaseURL: url)
        let edited = try #require(reopened.tasks.first)
        #expect(edited.title == "После правки 📖")
        #expect(edited.id == task.id)
        #expect(edited.occurrenceID == task.occurrenceID)
        #expect(edited.plannedDay == task.plannedDay)
        #expect(edited.timeZoneIdentifier == task.timeZoneIdentifier)
        #expect(edited.completedAt == completed.completedAt)
    }
}
