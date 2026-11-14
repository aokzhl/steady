import Foundation
import SteadyCore
import Testing

@MainActor
struct SearchTests {
    @Test func savedTitlesAndRichNotesSearchWithinContextAndKeepOnlyMatchingChildren() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = ISO8601DateFormatter().date(from: "2026-11-14T10:00:00Z")!
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant })
        let project = try workspace.createProject(title: "Work")
        let label = try workspace.createLabel(title: "Read")
        let parent = try workspace.createTask(title: "Parent", projectID: project.id, plannedDay: workspace.today)
        let note = TaskNote(rtf: Data(#"{\rtf1\ansi\b Caf\'e9\b0\par Reference}"#.utf8), plainText: "Café\nReference")
        let child = try workspace.addSubtask(parentOccurrenceID: parent.occurrenceID, title: String(repeating: "Long title ", count: 100) + "Needle", note: note, labelIDs: [label.id])
        _ = try workspace.addSubtask(parentOccurrenceID: parent.occurrenceID, title: "Sibling")
        let outside = try workspace.createTask(title: "Needle outside", plannedDay: workspace.tomorrow, note: note)
        try workspace.startStopwatch(occurrenceID: parent.occurrenceID)
        let session = workspace.activeSession
        let context = TaskListContext(projectID: project.id, labelIDs: [label.id], period: .today)
        for query in ["needle", "CAFÉ", "reference"] {
            let result = workspace.taskList(in: context, searchQuery: query)
            #expect(result.matches.map(\.occurrenceID) == [child.occurrenceID])
            #expect(result.contextParentIDs == [parent.occurrenceID])
            #expect(result.children(of: parent.occurrenceID).map(\.occurrenceID) == [child.occurrenceID])
            #expect(result.groups.map(\.matchCount) == [1])
        }
        #expect(workspace.activeSession == session)
        #expect(workspace.timeToolResults.isEmpty)
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant })
        #expect(reopened.taskList(in: context, searchQuery: "needle").matches.map(\.occurrenceID) == [child.occurrenceID])
        let all = reopened.taskList(in: TaskListContext(period: .all, showCompleted: true), searchQuery: "reference")
        #expect(Set(all.matches.map(\.occurrenceID)) == [child.occurrenceID, outside.occurrenceID])
        #expect(reopened.taskList(in: TaskListContext(period: .tomorrow), searchQuery: "absent").emptyReason == .noSearchMatches)
        #expect(reopened.taskList(in: context, searchQuery: "  \n").matches.map(\.occurrenceID) == [child.occurrenceID])
        let empty = try TaskWorkspace(databaseURL: directory.appendingPathComponent("empty.sqlite"))
        #expect(empty.taskList(in: context, searchQuery: "needle").emptyReason == .emptyDatabase)
    }

    @Test func parentNoteMatchesDoNotIncludeUnmatchedChildrenAndAllTasksCanFindCompletedMatches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let workspace = try TaskWorkspace(databaseURL: url)
        let task = try workspace.createTask(title: "Book", plannedDay: workspace.today, note: TaskNote(plainText: "Read chapter twenty"))
        _ = try workspace.addSubtask(parentOccurrenceID: task.occurrenceID, title: "Unrelated child")
        try workspace.setCompleted(occurrenceID: task.occurrenceID, completed: true)
        let reopened = try TaskWorkspace(databaseURL: url)
        #expect(reopened.taskList(in: TaskListContext(), searchQuery: "chapter").emptyReason == .noSearchMatches)
        let result = reopened.taskList(in: TaskListContext(period: .all, showCompleted: true), searchQuery: "chapter")
        #expect(result.matches.map(\.occurrenceID) == [task.occurrenceID])
        #expect(result.contextParentIDs.isEmpty)
        #expect(result.children(of: task.occurrenceID).isEmpty)
        #expect(result.groups.map(\.matchCount) == [1])
        let otherSpace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("other.sqlite"))
        _ = try otherSpace.createTask(title: "Other account")
        #expect(otherSpace.taskList(in: TaskListContext(period: .all), searchQuery: "chapter").emptyReason == .noSearchMatches)
    }

}
