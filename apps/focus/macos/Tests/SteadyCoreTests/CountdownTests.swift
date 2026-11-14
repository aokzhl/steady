import Foundation
import SteadyCore
import Testing

@MainActor
struct CountdownTests {
    @Test
    func unsetDurationDoesNotStartAndConfirmedDurationSurvivesRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let task = try workspace.createTask(title: "Читать")
        #expect(throws: WorkspaceError.timerDurationRequired) { try workspace.startTimer(occurrenceID: task.occurrenceID) }
        #expect(workspace.activeSession == nil)
        try workspace.startTimer(occurrenceID: task.occurrenceID, durationSeconds: 600)
        let id = try #require(workspace.activeSession?.id)
        instant += 120
        try workspace.pauseSession()
        instant += 900
        #expect(workspace.remainingSeconds == 480)
        #expect(workspace.elapsedSeconds == 120)
        try workspace.resumeSession()
        instant += 60
        try workspace.stopSession()
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.timeToolResults.first?.id == id)
        #expect(reopened.timeToolResults.first?.kind == .timer)
        #expect(reopened.timeToolResults.first?.durationSeconds == 180)
        #expect(reopened.timeToolResults.first?.endReason == .stopped)
        #expect(reopened.tasks.first?.completedAt == nil)
        #expect(try reopened.timerDurationSeconds(taskID: task.id) == 600)
        try reopened.startTimer(occurrenceID: task.occurrenceID)
        #expect(reopened.remainingSeconds == 600)
    }
    @Test
    func repeatedDeltasPreserveOwnerAndPauseAndDoNotChangeTheTaskSetting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let task = try workspace.createTask(title: "Читать")
        try workspace.startTimer(occurrenceID: task.occurrenceID, durationSeconds: 600)
        let id = try #require(workspace.activeSession?.id)
        instant += 120
        #expect(try workspace.previewTimerIncrement(minutes: 5) == 780)
        try workspace.adjustTimer(minutes: 5)
        try workspace.adjustTimer(minutes: 5)
        #expect(workspace.remainingSeconds == 1080)
        #expect(workspace.activeSession?.id == id)
        #expect(workspace.activeSession?.isPaused == false)
        #expect(workspace.activeSession?.occurrenceID == task.occurrenceID)
        try workspace.pauseSession()
        instant += 600
        try workspace.adjustTimer(minutes: -1)
        #expect(workspace.remainingSeconds == 1020)
        #expect(workspace.activeSession?.isPaused == true)
        #expect(throws: WorkspaceError.invalidTimerIncrement) { try workspace.adjustTimer(minutes: 21) }
        #expect(throws: WorkspaceError.invalidTimerIncrement) { try workspace.previewTimerIncrement(minutes: -21) }
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.remainingSeconds == 1020)
        #expect(reopened.elapsedSeconds == 120)
        #expect(try reopened.timerDurationSeconds(taskID: task.id) == 600)
        #expect(try reopened.previewTimerIncrement(minutes: -20) == 0)
        try reopened.adjustTimer(minutes: -20)
        #expect(reopened.activeSession == nil)
        #expect(reopened.timeToolResults.first?.endReason == .manual)
        #expect(reopened.timeToolResults.first?.durationSeconds == 120)
        #expect(reopened.tasks.first?.completedAt == nil)
    }
    @Test(arguments: [false, true])
    func naturalEndAndStopSaveOneResultAtTheDeadline(stopFirst: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let owner = try workspace.createTask(title: "Читать")
        try workspace.startTimer(occurrenceID: owner.occurrenceID, durationSeconds: 600)
        instant += 120
        try workspace.pauseSession()
        instant += 300
        try workspace.resumeSession()
        instant += 900 // A delayed delivery must not charge the late 420 seconds.
        #expect(workspace.elapsedSeconds == 600)
        #expect(workspace.remainingSeconds == 0)
        if stopFirst { try workspace.stopSession() }
        try workspace.updateTimer()
        try workspace.stopSession()
        try workspace.updateTimer()
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.activeSession == nil)
        #expect(reopened.timeToolResults.count == 1)
        let result = try #require(reopened.timeToolResults.first)
        #expect(result.endReason == .natural)
        #expect(result.durationSeconds == 600)
        #expect(result.stoppedAt == Date(timeIntervalSince1970: 1_800_000_900))
        #expect(result.segments.count == 2)
        #expect(result.segments.last?.endedAt == result.stoppedAt)
        #expect(reopened.tasks.first?.completedAt == nil)
    }
    @Test
    func failedNaturalEndFreezesAtDeadlineAndRetryNeverChargesAbsence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        try workspace.startTimer(durationSeconds: 60)
        instant += 90
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        #expect(throws: (any Error).self) { try workspace.updateTimer() }
        #expect(workspace.sessionNeedsSave)
        #expect(workspace.activeSession?.isPaused == true)
        #expect(workspace.elapsedSeconds == 60)
        instant += 600
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        try workspace.retrySessionSave()
        try workspace.stopSession()
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.timeToolResults.count == 1)
        #expect(reopened.timeToolResults.first?.durationSeconds == 60)
        #expect(reopened.timeToolResults.first?.endReason == .natural)
        #expect(reopened.timeToolResults.first?.stoppedAt == Date(timeIntervalSince1970: 1_800_000_060))
    }
}
