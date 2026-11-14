import Foundation
import SteadyCore
import Testing

@MainActor
struct TaskWorkspaceTests {
    @Test
    func newerSchemaIsRefusedWithoutChangingExistingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("steady.sqlite")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        fixture.arguments = [url.path, "PRAGMA user_version = 99;"]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        let original = try Data(contentsOf: url)

        #expect(throws: WorkspaceError.unsupportedSchema(99)) { try TaskWorkspace(databaseURL: url) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test
    func guestSpacesDoNotLeakBetweenBaseDirectories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = try TaskWorkspace.guestDatabaseURL(in: directory.appendingPathComponent("first"))
        let secondURL = try TaskWorkspace.guestDatabaseURL(in: directory.appendingPathComponent("second"))
        let first = try TaskWorkspace(databaseURL: firstURL)
        let created = try first.createTask(title: "Только в первом пространстве")
        let second = try TaskWorkspace(databaseURL: secondURL)
        #expect(second.tasks.isEmpty)
        let reopened = try TaskWorkspace(databaseURL: firstURL)
        #expect(reopened.tasks == [created])
    }

    @Test
    func plannedDayUsesTheLocalCalendarAndIdentifiersStayDistinct() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = try Date("2026-11-14T23:30:00Z", strategy: .iso8601)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Almaty"))
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: calendar)
        let first = try workspace.createTask(title: "  Коран: 'чтение' 📖  ")
        let second = try workspace.createTask(title: "Коран: 'чтение' 📖")

        #expect(first.title == "Коран: 'чтение' 📖")
        #expect(first.plannedDay == "2026-11-15")
        #expect(first.timeZoneIdentifier == "Asia/Almaty")
        #expect(Set([first.id, first.occurrenceID, second.id, second.occurrenceID]).count == 4)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.tasks == [first, second])
    }

    @Test
    func failedWriteKeepsExistingTasksAndCanBeRetried() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"))
        let original = try workspace.createTask(title: "Сохранённая задача")
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)

        #expect(throws: (any Error).self) { try workspace.createTask(title: "Повторить сохранение") }
        #expect(workspace.tasks == [original])

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        try workspace.createTask(title: "Повторить сохранение")
        let reopened = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"))
        #expect(reopened.tasks.map(\.title) == ["Сохранённая задача", "Повторить сохранение"])
    }

    @Test
    func repeatedCompletionPreservesTheOriginalTimestamp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let task = try workspace.createTask(title: "Сделать дело")
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        let later = try TaskWorkspace(databaseURL: url, now: { instant.addingTimeInterval(3600) })
        try later.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        #expect(later.tasks.first?.completedAt == instant)
        #expect(throws: WorkspaceError.occurrenceNotFound) {
            try later.setCompleted(occurrenceID: UUID(), completed: true)
        }
        #expect(later.tasks.count == 1)
    }

    @Test
    func corruptExistingFileIsNotReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("steady.sqlite")
        let original = Data("This is not a SQLite database".utf8)
        try original.write(to: url)
        #expect(throws: (any Error).self) { try TaskWorkspace(databaseURL: url) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test
    func embeddedNullIsRejectedInsteadOfSilentlyTruncatingTheTitle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"))
        #expect(throws: WorkspaceError.invalidTitle) { try workspace.createTask(title: "До\0После") }
        #expect(workspace.tasks.isEmpty)
    }

    @Test
    func completionAndUndoSurviveReopeningWithoutChangingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = Date(timeIntervalSince1970: 1_800_000_000.125)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let created = try workspace.createTask(title: "Прочитать главу")

        try workspace.setCompleted(occurrenceID: created.occurrenceID, completed: true)
        let reopened = try TaskWorkspace(databaseURL: url)
        let completed = try #require(reopened.tasks.first)
        #expect(completed.completedAt == instant)
        #expect(completed.id == created.id)
        #expect(completed.occurrenceID == created.occurrenceID)

        try reopened.setCompleted(occurrenceID: created.occurrenceID, completed: false)
        let restored = try TaskWorkspace(databaseURL: url)
        #expect(restored.tasks.first == created)
    }

    @Test(arguments: ["", " \n\t ", "\u{2003}"])
    func blankTitleIsRejectedWithoutCreatingATask(title: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"))

        #expect(throws: WorkspaceError.emptyTitle) { try workspace.createTask(title: title) }
        #expect(workspace.tasks.isEmpty)
    }

    @Test
    func createdTaskSurvivesReopeningTheDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: databaseURL)
        let created = try workspace.createTask(title: "Разобрать заметки")

        let reopened = try TaskWorkspace(databaseURL: databaseURL)
        let restored = try #require(reopened.tasks.first)
        #expect(restored == created)
    }
}
