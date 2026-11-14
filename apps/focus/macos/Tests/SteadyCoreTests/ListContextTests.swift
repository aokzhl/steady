import Foundation
import SteadyCore
import Testing

@MainActor
struct ListContextTests {
    @Test func projectLabelsAndPeriodCombineWithoutCountingContextParents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"))
        let project = try workspace.createProject(title: "Work")
        let first = try workspace.createLabel(title: "Read")
        let second = try workspace.createLabel(title: "Evening")
        let parent = try workspace.createTask(title: "Parent", projectID: project.id, plannedDay: workspace.today)
        let child = try workspace.addSubtask(parentOccurrenceID: parent.occurrenceID, title: "Match", labelIDs: [first.id, second.id])
        _ = try workspace.addSubtask(parentOccurrenceID: parent.occurrenceID, title: "Sibling")
        _ = try workspace.createTask(title: "Other project", plannedDay: workspace.today, labelIDs: [first.id])
        try workspace.setCompleted(occurrenceID: parent.occurrenceID, completed: true)
        var context = TaskListContext(projectID: project.id, labelIDs: [first.id, second.id], period: .today)
        var result = workspace.taskList(in: context)
        #expect(result.matches.map(\.occurrenceID) == [child.occurrenceID])
        #expect(result.roots.map(\.occurrenceID) == [parent.occurrenceID])
        #expect(result.contextParentIDs == [parent.occurrenceID])
        #expect(result.children(of: parent.occurrenceID).map(\.occurrenceID) == [child.occurrenceID])
        context.labelMatch = .all
        result = workspace.taskList(in: context)
        #expect(result.matches.map(\.occurrenceID) == [child.occurrenceID])
        context.labelIDs.insert(UUID())
        #expect(workspace.taskList(in: context).emptyReason == .noMatches)
        context.labelMatch = .any
        #expect(workspace.taskList(in: context).matches.count == 1)
        context.period = .tomorrow
        #expect(workspace.taskList(in: context).emptyReason == .emptyPeriod)
    }
    @Test func preferencesRestoreInsideTheirDatabaseAndTodayFollowsCurrentZone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("steady.sqlite")
        let instant = ISO8601DateFormatter().date(from: "2026-11-14T20:00:00Z")!
        var zone = TimeZone(secondsFromGMT: 0)!
        let calendar = { var value = Calendar(identifier: .gregorian); value.timeZone = zone; return value }
        let workspace = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: calendar)
        #expect(workspace.preferences == WorkspacePreferences())
        #expect(workspace.taskList(in: TaskListContext()).emptyReason == .emptyDatabase)
        let project = try workspace.createProject(title: "Work")
        let label = try workspace.createLabel(title: "Read")
        let parent = try workspace.createTask(title: "Tomorrow", projectID: project.id, plannedDay: "2026-11-15", labelIDs: [label.id])
        let child = try workspace.addSubtask(parentOccurrenceID: parent.occurrenceID, title: "Child")
        var preferences = WorkspacePreferences()
        preferences.context = TaskListContext(projectID: project.id, labelIDs: [label.id], labelMatch: .all)
        preferences.selectedOccurrenceID = child.occurrenceID
        preferences.detailsVisible = true
        preferences.sidebarVisible = false
        preferences.expandedParentIDs = [parent.occurrenceID]
        try workspace.savePreferences(preferences)
        #expect(workspace.taskList(in: preferences.context).emptyReason == .emptyPeriod)
        zone = TimeZone(secondsFromGMT: 5 * 3600)!
        let reopened = try TaskWorkspace(databaseURL: url, now: { instant }, calendar: calendar)
        #expect(reopened.preferences == preferences)
        #expect(reopened.today == "2026-11-15")
        #expect(reopened.taskList(in: reopened.preferences.context).matches.map(\.occurrenceID) == [parent.occurrenceID])
        #expect(try TaskWorkspace(databaseURL: directory.appendingPathComponent("other.sqlite")).preferences == WorkspacePreferences())
    }

    @Test func todaySeparatesOverdueWeeklyUndatedAndProjectGroupsAndMonthMaterializesAllDays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = ISO8601DateFormatter().date(from: "2026-11-14T10:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workspace = try TaskWorkspace(databaseURL: directory.appendingPathComponent("steady.sqlite"), now: { instant }, calendar: { calendar })
        let project = try workspace.createProject(title: "Work")
        let weekly = try workspace.createTask(title: "Weekly", recurrence: .weekly, seriesStart: "2026-11-09")
        let overdue = try workspace.createTask(title: "Overdue", plannedDay: "2026-11-13")
        let daily = try workspace.createTask(title: "Daily", projectID: project.id, recurrence: .daily, seriesStart: "2026-11-14")
        let unassigned = try workspace.createTask(title: "Today", plannedDay: "2026-11-14")
        let today = workspace.taskList(in: TaskListContext())
        #expect(today.groups.map(\.id) == ["overdue", "weekly-undated", project.id.uuidString, "unassigned"])
        #expect(today.groups.map(\.matchCount) == [1, 1, 1, 1])
        #expect(Set(today.matches.map(\.id)) == [weekly.id, overdue.id, daily.id, unassigned.id])
        let month = TaskListContext(projectID: project.id, period: .month)
        try workspace.prepareTaskList(in: month)
        #expect(workspace.taskList(in: month).matches.count == 17)
        #expect(workspace.taskList(in: month).matches.last?.plannedDay == "2026-11-30")
        try workspace.setCompleted(occurrenceID: daily.occurrenceID, completed: true)
        #expect(workspace.taskList(in: TaskListContext(period: .completed)).matches.map(\.occurrenceID) == [daily.occurrenceID])
        #expect(!workspace.taskList(in: TaskListContext(period: .all)).matches.contains { $0.occurrenceID == daily.occurrenceID })
        #expect(workspace.taskList(in: TaskListContext(period: .today, showCompleted: true)).matches.contains { $0.occurrenceID == daily.occurrenceID })
    }

}
