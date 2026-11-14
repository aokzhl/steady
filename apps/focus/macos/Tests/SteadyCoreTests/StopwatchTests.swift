import Foundation
import SteadyCore
import Testing

@MainActor
struct StopwatchTests {
    @Test
    func sevenActiveMinutesExcludePauseAndKeepTheSameRun() throws {
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
        let task = try workspace.createTask(title: "Читать")
        try workspace.startStopwatch(occurrenceID: task.occurrenceID)
        let run = try #require(workspace.activeSession)
        #expect(run.kind == .stopwatch)
        #expect(run.taskID == task.id)
        #expect(run.occurrenceID == task.occurrenceID)
        instant += 180
        try workspace.pauseSession()
        try workspace.pauseSession()
        instant += 600
        #expect(workspace.elapsedSeconds == 180)
        #expect(throws: WorkspaceError.sessionOccupied) { try workspace.startStopwatch() }
        zone = TimeZone(identifier: "America/New_York")!
        try workspace.resumeSession()
        try workspace.resumeSession()
        instant += 240
        #expect(workspace.elapsedSeconds == 420)
        try workspace.stopSession()
        try workspace.stopSession() // A repeated stop must never duplicate the result.
        let saved = try #require(workspace.timeToolResults.first)
        #expect(saved.id == run.id)
        #expect(saved.durationSeconds == 420)
        #expect(saved.timeZoneIdentifier == "Asia/Almaty")
        #expect(saved.segments.count == 2)
        #expect(saved.segments[0].startedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(saved.segments[0].endedAt == Date(timeIntervalSince1970: 1_800_000_180))
        #expect(saved.segments[1].startedAt == Date(timeIntervalSince1970: 1_800_000_780))
        #expect(saved.segments[1].endedAt == Date(timeIntervalSince1970: 1_800_001_020))
        #expect(workspace.tasks.first?.completedAt == nil)
        #expect(workspace.activeSession == nil)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.timeToolResults == [saved])
    }
    @Test
    func completingOnlyTheOwnerSavesTheRunAndCompletionTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let owner = try workspace.createTask(title: "Владелец")
        let other = try workspace.createTask(title: "Другая задача")
        try workspace.startStopwatch(occurrenceID: owner.occurrenceID)
        let id = try #require(workspace.activeSession?.id)
        instant += 60
        try workspace.setCompleted(occurrenceID: other.occurrenceID, completed: true)
        #expect(workspace.activeSession?.id == id)
        #expect(workspace.timeToolResults.isEmpty)
        instant += 60
        try workspace.setCompleted(occurrenceID: owner.occurrenceID, completed: true)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.activeSession == nil)
        #expect(reopened.timeToolResults.first?.id == id)
        #expect(reopened.timeToolResults.first?.durationSeconds == 120)
        #expect(reopened.tasks.first?.completedAt == instant)
        try workspace.setCompleted(occurrenceID: owner.occurrenceID, completed: true)
        #expect(workspace.timeToolResults.count == 1)
    }

    @Test
    func freeRunsOfTenAndFifteenMinutesHaveDistinctPersistentResults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        try workspace.startStopwatch()
        instant += 600
        try workspace.stopSession()
        instant += 120
        try workspace.startStopwatch()
        instant += 900
        try workspace.stopSession()
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.timeToolResults.map(\.durationSeconds) == [600, 900])
        #expect(Set(reopened.timeToolResults.map(\.id)).count == 2)
        #expect(reopened.timeToolResults.allSatisfy { $0.taskID == nil && $0.occurrenceID == nil })
        #expect(reopened.tasks.isEmpty)
    }

    @Test
    func failedStopPausesInMemoryAndRetrySavesOnlyTheMeasuredWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let owner = try workspace.createTask(title: "Сохранить надёжно")
        try workspace.startStopwatch(occurrenceID: owner.occurrenceID)
        instant += 90
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        #expect(throws: (any Error).self) { try workspace.setCompleted(occurrenceID: owner.occurrenceID, completed: true) }
        #expect(workspace.activeSession?.isPaused == true)
        #expect(workspace.tasks.first?.completedAt == nil)
        #expect(workspace.timeToolResults.isEmpty)
        instant += 600
        #expect(workspace.elapsedSeconds == 90)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        try workspace.setCompleted(occurrenceID: owner.occurrenceID, completed: true)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.timeToolResults.first?.durationSeconds == 90)
        #expect(reopened.tasks.first?.completedAt == instant)
        #expect(reopened.timeToolResults.count == 1)
    }

    @Test
    func reopeningPausesAtTheLastCommittedBoundaryWithoutCountingAbsence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        var workspace: TaskWorkspace? = try TaskWorkspace(databaseURL: url, now: { instant })
        try workspace?.startStopwatch()
        let id = try #require(workspace?.activeSession?.id)
        instant += 180
        try workspace?.pauseSession()
        instant += 120
        try workspace?.resumeSession()
        instant += 40
        workspace = nil // Simulate a restart without another explicit command/checkpoint.
        instant += 600
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.activeSession?.id == id)
        #expect(reopened.activeSession?.isPaused == true)
        #expect(reopened.elapsedSeconds == 180)
        #expect(throws: WorkspaceError.sessionOccupied) { try reopened.startStopwatch() }
        try reopened.resumeSession()
        instant += 60
        try reopened.stopSession()
        #expect(reopened.timeToolResults.first?.durationSeconds == 240)
    }

    @Test
    func versionTwoTaskAndDraftSurviveTheTimeToolMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("steady.sqlite")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        fixture.arguments = [url.path, """
            CREATE TABLE tasks (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, created_at REAL NOT NULL, priority TEXT NOT NULL);
            CREATE TABLE task_occurrences (id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL REFERENCES tasks(id), planned_day TEXT NOT NULL, time_zone TEXT NOT NULL, completed_at REAL);
            CREATE TABLE creation_draft (id INTEGER PRIMARY KEY, title TEXT NOT NULL, priority TEXT NOT NULL);
            INSERT INTO tasks VALUES ('11111111-1111-1111-1111-111111111111', 'Существующее дело', 1800000000, 'high');
            INSERT INTO task_occurrences VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', '2026-11-12', 'Asia/Almaty', NULL);
            INSERT INTO creation_draft VALUES (1, 'Черновик', 'low');
            PRAGMA user_version = 2;
            """]
        try fixture.run()
        fixture.waitUntilExit()
        try #require(fixture.terminationStatus == 0)
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let old = try #require(workspace.tasks.first)
        #expect(old.title == "Существующее дело")
        #expect(old.priority == .high)
        #expect(old.plannedDay == "2026-11-12")
        #expect(workspace.creationDraft == CreationDraft(title: "Черновик", priority: .low))
        try workspace.startStopwatch(occurrenceID: old.occurrenceID)
        instant += 75
        try workspace.stopSession()
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.tasks == [old])
        #expect(reopened.creationDraft == CreationDraft(title: "Черновик", priority: .low))
        #expect(reopened.timeToolResults.first?.durationSeconds == 75)
        #expect(reopened.timeToolResults.first?.taskID == old.id)
    }

}
