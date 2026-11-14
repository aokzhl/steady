import Foundation
import SteadyCore
import Testing

@MainActor
struct PomodoroTests {
    @Test
    func earlyRestReturnsToOneLogicalFocusWithoutCountingRestOrPause() throws {
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
        let owner = try workspace.createTask(title: "Читать")
        try workspace.startPomodoro(occurrenceID: owner.occurrenceID)
        let runID = try #require(workspace.activeSession?.id)
        let focusID = try #require(workspace.activeSession?.pomodoro?.focusID)
        instant += 300
        try workspace.startRest()
        #expect(workspace.elapsedSeconds == 300)
        #expect(workspace.remainingSeconds == 1200)
        #expect(workspace.activeSession?.pomodoro?.fullPomodoros == 0)
        #expect(throws: WorkspaceError.sessionOccupied) { try workspace.startStopwatch() }
        instant += 60
        zone = TimeZone(identifier: "America/New_York")!
        #expect(workspace.restRemainingSeconds == 240)
        try workspace.pauseSession()
        instant += 600
        #expect(workspace.restRemainingSeconds == 240)
        try workspace.backToWork()
        #expect(workspace.activeSession?.pomodoro?.focusID == focusID)
        instant += 1200
        try workspace.updateTimer()
        #expect(workspace.activeSession?.pomodoro?.stage == .waitingBreak)
        #expect(workspace.activeSession?.pomodoro?.fullPomodoros == 1)
        #expect(workspace.tasks.first?.completedAt == nil)
        #expect(workspace.elapsedSeconds == 1500)
        try workspace.stopSession()
        try workspace.stopSession()
        let reopened = try TaskWorkspace(databaseURL: url)
        let result = try #require(reopened.timeToolResults.first)
        #expect(result.id == runID)
        #expect(result.durationSeconds == 1500)
        #expect(result.timeZoneIdentifier == "Asia/Almaty")
        #expect(result.pomodoro?.parameters == PomodoroParameters())
        #expect(result.pomodoro?.fullPomodoros == 1)
        #expect(result.pomodoro?.focusID == focusID)
        #expect(result.pomodoro?.restSegments.first?.endedAt == Date(timeIntervalSince1970: 1_800_000_360))
        #expect(reopened.timeToolResults.count == 1)
    }
    @Test
    func adjustedNaturalEndAndFourFullFocusesOfferLongRestAcrossRuns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        for _ in 0..<3 {
            try workspace.startPomodoro()
            try workspace.adjustTimer(minutes: -20)
            instant += 301 // Wake late: actual work ends at the deadline, not wake time.
            try workspace.updateTimer()
            #expect(workspace.activeSession?.pomodoro?.stage == .waitingBreak)
            #expect(workspace.activeSession?.pomodoro?.fullPomodoros == 1)
            try workspace.stopSession()
        }
        try workspace.startPomodoro()
        instant += 1500
        try workspace.updateTimer()
        try workspace.startRest()
        #expect(workspace.restRemainingSeconds == 900)
        #expect(workspace.activeSession?.pomodoro?.restIsLong == true)
        instant += 950
        try workspace.updateTimer()
        #expect(workspace.activeSession?.pomodoro?.stage == .waitingNext)
        #expect(workspace.activeSession?.pomodoro?.cycleCount == 0)
        #expect(workspace.elapsedSeconds == 1500)
        #expect(throws: WorkspaceError.sessionOccupied) { try workspace.startTimer(durationSeconds: 60) }
        try workspace.backToWork()
        instant += 300
        try workspace.adjustTimer(minutes: -20) // Manual zero saves partial work, never a full focus.
        #expect(workspace.activeSession?.pomodoro?.fullPomodoros == 1)
        #expect(workspace.activeSession?.pomodoro?.stage == .waitingBreak)
        try workspace.stopSession()
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.timeToolResults.map(\.durationSeconds) == [300, 300, 300, 1800])
        #expect(reopened.timeToolResults.map { $0.pomodoro?.fullPomodoros } == [1, 1, 1, 1])
        #expect(reopened.timeToolResults.first?.endReason == .natural)
    }

    @Test
    func failedNaturalEndRetriesIntoWaitingAndReopenDoesNotChargeAbsence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let url = directory.appendingPathComponent("steady.sqlite")
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        try workspace.startPomodoro()
        instant += 1501
        #expect(workspace.elapsedSeconds == 1500)
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        #expect(throws: (any Error).self) { try workspace.updateTimer() }
        #expect(workspace.sessionNeedsSave)
        #expect(workspace.elapsedSeconds == 1500)
        instant += 600
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        try workspace.retrySessionSave()
        #expect(workspace.activeSession?.pomodoro?.stage == .waitingBreak)
        #expect(workspace.timeToolResults.isEmpty)
        try workspace.startRest()
        instant += 60
        try workspace.pauseSession()
        try workspace.resumeSession()
        instant += 40
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.activeSession?.isPaused == true)
        #expect(reopened.restRemainingSeconds == 240)
        #expect(reopened.remainingSeconds == 0)
        try reopened.backToWork()
        instant += 90
        try reopened.stopSession()
        #expect(reopened.timeToolResults.first?.durationSeconds == 1590)
        #expect(reopened.timeToolResults.first?.pomodoro?.fullPomodoros == 1)
    }

}
