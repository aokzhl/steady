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
        let child = SubtaskDraft(title: "Child", note: TaskNote(plainText: "Keep this"))
        let draft = CreationDraft(title: "Parent", children: [child])
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
        #expect(reopened.creationDraft == nil)
    }

}
