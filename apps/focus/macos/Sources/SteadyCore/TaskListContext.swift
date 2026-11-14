import Foundation

public enum TaskPeriod: String, Codable, CaseIterable, Sendable {
    case all, today, tomorrow, week, month, completed

    public var label: String {
        switch self {
        case .all: "Все"
        case .today: "Сегодня"
        case .tomorrow: "Завтра"
        case .week: "Эта неделя"
        case .month: "Этот месяц"
        case .completed: "Выполненные"
        }
    }
}

public enum LabelMatch: String, Codable, Sendable { case any, all }
public enum WorkspaceScreen: String, Codable, Sendable { case tasks, report }

public struct TaskListContext: Codable, Equatable, Sendable {
    public var projectID: UUID?
    public var labelIDs: Set<UUID>
    public var labelMatch: LabelMatch
    public var period: TaskPeriod
    public var showCompleted: Bool

    public init(projectID: UUID? = nil, labelIDs: Set<UUID> = [], labelMatch: LabelMatch = .any, period: TaskPeriod = .today, showCompleted: Bool = false) {
        self.projectID = projectID
        self.labelIDs = labelIDs
        self.labelMatch = labelMatch
        self.period = period
        self.showCompleted = showCompleted
    }
}

/// Belongs to the database's data space, never to process-wide defaults.
public struct WorkspacePreferences: Codable, Equatable, Sendable {
    public var context = TaskListContext()
    public var screen: WorkspaceScreen = .tasks
    public var selectedOccurrenceID: UUID?
    public var detailsVisible = false
    public var sidebarVisible = true
    public var expandedParentIDs: Set<UUID> = []
    public init() {}
}

public enum TaskListEmptyReason: Sendable { case emptyDatabase, emptyPeriod, noMatches }

public struct TaskListGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let roots: [TaskRecord]
    public let matchCount: Int
}

public struct TaskListResult: Sendable {
    public let matches: [TaskRecord]
    public let roots: [TaskRecord]
    public let contextParentIDs: Set<UUID>
    public let groups: [TaskListGroup]
    public let emptyReason: TaskListEmptyReason?

    public func children(of parentOccurrenceID: UUID) -> [TaskRecord] {
        matches.filter { $0.parentOccurrenceID == parentOccurrenceID }
    }
}
