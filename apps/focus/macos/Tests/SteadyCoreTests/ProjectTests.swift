import Foundation
import SteadyCore
import Testing

@MainActor
struct ProjectTests {
    @Test
    func projectsCanBeCreatedRenamedAndReopenedWithoutChangingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let project = try workspace.createProject(title: "  Работа  ", color: .purple)
        #expect(project.title == "Работа")
        #expect(project.color == .purple)
        try workspace.renameProject(id: project.id, title: "  Учёба 📖  ")
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.projects.first?.id == project.id)
        #expect(reopened.projects.first?.title == "Учёба 📖")
        #expect(reopened.projects.first?.color == .purple)
        #expect(throws: (any Error).self) { try workspace.createProject(title: " \n") }
        #expect(throws: (any Error).self) { try workspace.renameProject(id: project.id, title: "До\0После") }
        #expect(throws: WorkspaceError.projectNotFound) { try workspace.renameProject(id: UUID(), title: "Нет") }
        #expect(try TaskWorkspace(databaseURL: url).projects == reopened.projects)
    }
    @Test
    func projectAssignmentAndRemovalPreserveTaskFactsAndCounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let project = try workspace.createProject(title: "Работа")
        let other = try workspace.createProject(title: "Дом")
        let task = try workspace.createTask(title: "Дело", projectID: project.id)
        let unassigned = try workspace.createTask(title: "Без проекта")
        #expect(workspace.tasks(in: project.id).map(\.id) == [task.id])
        #expect(workspace.openTaskCount(in: project.id) == 1)
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        #expect(workspace.openTaskCount(in: project.id) == 0)
        let completed = try #require(workspace.tasks.first)
        try workspace.setProject(id: task.id, projectID: other.id)
        try workspace.renameProject(id: other.id, title: "Личное")
        let reopened = try TaskWorkspace(databaseURL: url)
        let assigned = try #require(reopened.tasks.first)
        #expect(assigned.projectID == other.id)
        #expect(assigned.occurrenceID == task.occurrenceID)
        #expect(assigned.completedAt == completed.completedAt)
        #expect(assigned.plannedDay == task.plannedDay)
        #expect(reopened.tasks(in: project.id).isEmpty)
        #expect(reopened.tasks(in: nil) == [unassigned])
        #expect(throws: WorkspaceError.projectNotFound) { try workspace.setProject(id: task.id, projectID: UUID()) }
        try workspace.setProject(id: task.id, projectID: nil)
        #expect(try TaskWorkspace(databaseURL: url).tasks.first?.projectID == nil)
    }

    @Test
    func projectOnlyDraftPersistsAndCreationConsumesItsExplicitChoice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let project = try workspace.createProject(title: "Учёба")
        try workspace.saveCreationDraft(CreationDraft(projectID: project.id))
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.creationDraft?.projectID == project.id)
        try reopened.saveCreationDraft(CreationDraft(title: "Читать", projectID: project.id))
        let task = try reopened.createTaskFromDraft()
        #expect(task.projectID == project.id)
        #expect(try TaskWorkspace(databaseURL: url).creationDraft == nil)
        try reopened.saveCreationDraft(CreationDraft(title: "Самостоятельно", projectID: nil))
        #expect(try reopened.createTaskFromDraft().projectID == nil)
    }

    @Test
    func versionTwoTaskAndDraftMigrateWithNoProjectAndKeepTheirFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("steady.sqlite")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        fixture.arguments = [url.path, """
            CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, created_at REAL NOT NULL, priority TEXT NOT NULL);
            CREATE TABLE task_occurrences (id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL REFERENCES tasks(id), planned_day TEXT NOT NULL, time_zone TEXT NOT NULL, completed_at REAL);
            CREATE TABLE creation_draft (id INTEGER PRIMARY KEY CHECK(id = 1), title TEXT NOT NULL, priority TEXT NOT NULL);
            INSERT INTO tasks VALUES ('11111111-1111-1111-1111-111111111111', 'Старое дело', 1800000000, 'high');
            INSERT INTO task_occurrences VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', '2026-11-12', 'Asia/Almaty', 1800000001.125);
            INSERT INTO creation_draft VALUES (1, 'Продолжить', 'low');
            PRAGMA user_version = 2;
            """]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        let workspace = try TaskWorkspace(databaseURL: url)
        let task = try #require(workspace.tasks.first)
        #expect(task.id.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(task.occurrenceID.uuidString == "22222222-2222-2222-2222-222222222222")
        #expect(task.projectID == nil)
        #expect(task.plannedDay == "2026-11-12")
        #expect(task.completedAt == Date(timeIntervalSince1970: 1_800_000_001.125))
        #expect(task.priority == .high)
        #expect(workspace.creationDraft == CreationDraft(title: "Продолжить", priority: .low))
        let project = try workspace.createProject(title: "После обновления")
        try workspace.setProject(id: task.id, projectID: project.id)
        #expect(try TaskWorkspace(databaseURL: url).tasks.first?.projectID == project.id)
    }

    @Test
    func failedProjectWritesKeepSavedStateAndCanBeRetried() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let project = try workspace.createProject(title: "Прежнее")
        let task = try workspace.createTask(title: "Дело")
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        #expect(throws: (any Error).self) { try workspace.createProject(title: "Новое") }
        #expect(throws: (any Error).self) { try workspace.renameProject(id: project.id, title: "Правка") }
        #expect(throws: (any Error).self) { try workspace.setProject(id: task.id, projectID: project.id) }
        #expect(workspace.projects == [project])
        #expect(workspace.tasks == [task])
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        try workspace.renameProject(id: project.id, title: "Правка")
        try workspace.setProject(id: task.id, projectID: project.id)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.projects.first?.title == "Правка")
        #expect(reopened.tasks.first?.projectID == project.id)
    }

    @Test
    func explicitlyChoosingNoProjectOnAnEmptyDraftSurvivesReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        try workspace.saveCreationDraft(CreationDraft())
        #expect(try TaskWorkspace(databaseURL: url).creationDraft == nil)
        try workspace.saveCreationDraft(CreationDraft(projectWasChosen: true))
        let reopened = try TaskWorkspace(databaseURL: url)
        let draft = try #require(reopened.creationDraft)
        #expect(draft.projectID == nil)
        #expect(draft.projectWasChosen)
        #expect(reopened.tasks.isEmpty)
        try reopened.saveCreationDraft(CreationDraft(title: "Без проекта", projectID: draft.projectID, projectWasChosen: draft.projectWasChosen))
        #expect(try reopened.createTaskFromDraft().projectID == nil)
        try reopened.saveCreationDraft(CreationDraft(projectWasChosen: true))
        try reopened.discardCreationDraft()
        #expect(try TaskWorkspace(databaseURL: url).creationDraft == nil)
    }

}
