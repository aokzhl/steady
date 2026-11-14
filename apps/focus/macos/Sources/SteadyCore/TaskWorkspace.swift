import Foundation
import Observation

public enum TaskPriority: String, CaseIterable, Sendable {
    case none, highest, high, medium, low, lowest

    public var label: String {
        switch self {
        case .none: "Без приоритета"
        case .highest: "Самый высокий"
        case .high: "Высокий"
        case .medium: "Средний"
        case .low: "Низкий"
        case .lowest: "Самый низкий"
        }
    }
}

public enum ProjectColor: String, CaseIterable, Sendable {
    case purple, blue, green, orange, pink

    public var label: String {
        switch self {
        case .purple: "Сиреневый"
        case .blue: "Синий"
        case .green: "Зелёный"
        case .orange: "Оранжевый"
        case .pink: "Розовый"
        }
    }
}

public struct ProjectRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let color: ProjectColor?
}

public struct TaskRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let occurrenceID: UUID
    public let title: String
    public let plannedDay: String
    public let timeZoneIdentifier: String
    public let completedAt: Date?
    public let priority: TaskPriority
    public let projectID: UUID?
}

public struct CreationDraft: Equatable, Sendable {
    public let title: String
    public let priority: TaskPriority

    public let projectID: UUID?

    public init(title: String = "", priority: TaskPriority = .none, projectID: UUID? = nil) {
        self.title = title
        self.priority = priority
        self.projectID = projectID
    }
}

@MainActor
@Observable
public final class TaskWorkspace {
    public private(set) var projects: [ProjectRecord] = []
    public private(set) var tasks: [TaskRecord] = []
    public private(set) var creationDraft: CreationDraft?
    private let database: SQLiteDatabase
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var dayContext: DayContext

    public init(databaseURL: URL, now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current }) throws {
        self.now = now
        self.calendar = calendar
        self.dayContext = DayContext(date: now(), calendar: calendar())
        self.database = try SQLiteDatabase(url: databaseURL)
        self.projects = try database.projects()
        self.tasks = try database.records()
        self.creationDraft = try database.creationDraft()
    }

    @discardableResult
    public func createProject(title: String, color: ProjectColor? = nil) throws -> ProjectRecord {
        let project = ProjectRecord(id: UUID(), title: try validatedTitle(title), color: color)
        projects = try database.insertProject(project, createdAt: now())
        return project
    }

    public func renameProject(id: UUID, title: String) throws {
        projects = try database.renameProject(id: id, title: validatedTitle(title))
    }

    @discardableResult
    public func createTask(title: String, priority: TaskPriority = .none, projectID: UUID? = nil) throws -> TaskRecord {
        try insertTask(title: title, priority: priority, projectID: projectID, consuming: nil)
    }

    @discardableResult
    public func createTaskFromDraft() throws -> TaskRecord {
        guard let draft = creationDraft else { throw WorkspaceError.emptyTitle }
        let task = try insertTask(title: draft.title, priority: draft.priority, projectID: draft.projectID, consuming: draft)
        creationDraft = nil
        return task
    }

    private func insertTask(title: String, priority: TaskPriority, projectID: UUID?, consuming draft: CreationDraft?) throws -> TaskRecord {
        let title = try validatedTitle(title)
        let createdAt = now()
        let context = DayContext(date: createdAt, calendar: calendar())
        let task = TaskRecord(
            id: UUID(), occurrenceID: UUID(), title: title,
            plannedDay: context.day,
            timeZoneIdentifier: context.timeZone.identifier, completedAt: nil, priority: priority, projectID: projectID
        )
        tasks = try database.insert(task, createdAt: createdAt, consuming: draft)
        dayContext = context
        return task
    }

    public func setCompleted(occurrenceID: UUID, completed: Bool) throws {
        let instant = now()
        tasks = try database.setCompleted(occurrenceID: occurrenceID, completed: completed, at: instant)
        dayContext = DayContext(date: instant, calendar: calendar())
    }

    public func renameTask(id: UUID, title: String) throws {
        let title = try validatedTitle(title)
        tasks = try database.renameTask(id: id, title: title)
    }

    private func validatedTitle(_ input: String) throws -> String {
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WorkspaceError.emptyTitle }
        guard !title.contains("\0") else { throw WorkspaceError.invalidTitle }
        return title
    }

    public func setPriority(id: UUID, priority: TaskPriority) throws {
        tasks = try database.setPriority(id: id, priority: priority)
    }

    public func setProject(id: UUID, projectID: UUID?) throws {
        tasks = try database.setProject(id: id, projectID: projectID)
    }

    public func tasks(in projectID: UUID?) -> [TaskRecord] {
        tasks.filter { $0.projectID == projectID }
    }

    public func openTaskCount(in projectID: UUID?) -> Int {
        tasks(in: projectID).filter { $0.completedAt == nil }.count
    }

    public func saveCreationDraft(_ draft: CreationDraft) throws {
        try database.saveCreationDraft(draft)
        creationDraft = draft.title.isEmpty && draft.priority == .none && draft.projectID == nil ? nil : draft
    }

    public func discardCreationDraft() throws {
        try saveCreationDraft(CreationDraft())
    }

    public var today: String { dayContext.day }

    public var openToday: [TaskRecord] {
        let day = dayContext.day
        return tasks.filter { $0.completedAt == nil && $0.plannedDay <= day }
    }

    public var completedToday: [TaskRecord] {
        let context = dayContext
        return tasks.filter { $0.completedAt.map(context.contains) ?? false }
    }

    public func reload() throws {
        dayContext = DayContext(date: now(), calendar: calendar())
        tasks = try database.records()
        projects = try database.projects()
        creationDraft = try database.creationDraft()
    }

    public static func guestDatabaseURL(in baseDirectory: URL? = nil) throws -> URL {
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Steady", isDirectory: true)
        }
        return base.appendingPathComponent("guest", isDirectory: true).appendingPathComponent("steady.sqlite")
    }

    private struct DayContext: Equatable {
        let day: String
        let timeZone: TimeZone

        init(date: Date, calendar: Calendar) {
            timeZone = calendar.timeZone
            day = Self.dayString(for: date, in: timeZone)
        }

        func contains(_ date: Date) -> Bool {
            Self.dayString(for: date, in: timeZone) == day
        }

        private static func dayString(for date: Date, in timeZone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
    }
}
