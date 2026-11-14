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

/// Durable rich text is opaque to Core; the projection supports display and future search.
/// The macOS editor encodes `rtf` using the standard RTF interchange format.
public struct TaskNote: Equatable, Sendable {
    public let rtf: Data
    public let plainText: String

    public init(rtf: Data = Data(), plainText: String = "") {
        self.rtf = rtf
        self.plainText = plainText
    }

    public static let empty = TaskNote()
}

public struct LabelRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let color: ProjectColor?
}

public struct TaskRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let occurrenceID: UUID
    public let title: String
    public let plannedDay: String?
    public let timeZoneIdentifier: String
    public let completedAt: Date?
    public let priority: TaskPriority
    public let projectID: UUID?
    public let note: TaskNote
    public let labelIDs: Set<UUID>
}

public struct CreationDraft: Equatable, Sendable {
    public let title: String
    public let priority: TaskPriority
    public let projectID: UUID?
    public let labelIDs: Set<UUID>
    public let projectWasChosen: Bool
    public let plannedDay: String?
    public let dayWasChosen: Bool
    public let note: TaskNote
    public let labelsWereChosen: Bool

    public init(title: String = "", priority: TaskPriority = .none, projectID: UUID? = nil, projectWasChosen: Bool = false, plannedDay: String? = nil, dayWasChosen: Bool = false, note: TaskNote = .empty, labelIDs: Set<UUID> = [], labelsWereChosen: Bool = false) {
        self.title = title
        self.priority = priority
        self.projectID = projectID
        self.projectWasChosen = projectWasChosen
        self.note = note
        self.plannedDay = plannedDay
        self.dayWasChosen = dayWasChosen
        self.labelIDs = labelIDs
        self.labelsWereChosen = labelsWereChosen
    }

    public var isEmpty: Bool {
        title.isEmpty && priority == .none && projectID == nil && !projectWasChosen && note == .empty && plannedDay == nil && !dayWasChosen && labelIDs.isEmpty && !labelsWereChosen
    }
}

@MainActor
@Observable
public final class TaskWorkspace {
    public private(set) var lastDeletedLabel: LabelRecord?
    public private(set) var labels: [LabelRecord] = []
    public private(set) var projects: [ProjectRecord] = []
    public private(set) var tasks: [TaskRecord] = []
    public private(set) var activeSession: TimeToolSession?
    public private(set) var timeToolResults: [TimeToolSession] = []
    public private(set) var creationDraft: CreationDraft?
    private var pendingPausedSession: TimeToolSession?
    public var sessionNeedsSave: Bool { pendingPausedSession != nil }
    private let database: SQLiteDatabase
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var dayContext: DayContext

    public init(databaseURL: URL, now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current }) throws {
        self.now = now
        self.calendar = calendar
        self.dayContext = DayContext(date: now(), calendar: calendar())
        self.database = try SQLiteDatabase(url: databaseURL)
        self.lastDeletedLabel = try database.lastDeletedLabel()
        self.labels = try database.labels()
        self.projects = try database.projects()
        try database.restorePausedSession()
        self.tasks = try database.records()
        self.creationDraft = try database.creationDraft()
        self.activeSession = try database.activeTimeToolSession()
        self.timeToolResults = try database.timeToolResults()
    }

    @discardableResult
    public func createLabel(title: String, color: ProjectColor? = nil) throws -> LabelRecord {
        let label = LabelRecord(id: UUID(), title: try validatedLabelTitle(title), color: color)
        labels = try database.insertLabel(label, createdAt: now())
        return label
    }

    public func renameLabel(id: UUID, title: String) throws {
        labels = try database.renameLabel(id: id, title: validatedLabelTitle(title))
    }

    public func deleteLabel(id: UUID) throws {
        applyLabelState(try database.deleteLabel(id: id, at: now()))
    }

    public func undoLabelDeletion() throws {
        applyLabelState(try database.undoLabelDeletion())
    }

    private func applyLabelState(_ state: SQLiteDatabase.LabelState) {
        labels = state.labels
        tasks = state.tasks
        creationDraft = state.draft
        lastDeletedLabel = state.deleted
    }

    private func validatedLabelTitle(_ input: String) throws -> String {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceError.emptyLabelTitle
        }
        return try validatedTitle(input)
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

    /// General creation is undated. A concrete day context passes its calendar date explicitly.
    @discardableResult
    public func createTask(title: String, priority: TaskPriority = .none, projectID: UUID? = nil, plannedDay: String? = nil, note: TaskNote = .empty, labelIDs: Set<UUID> = []) throws -> TaskRecord {
        try insertTask(title: title, priority: priority, projectID: projectID, plannedDay: plannedDay, note: note, labelIDs: labelIDs, consuming: nil)
    }

    @discardableResult
    public func createTaskFromDraft() throws -> TaskRecord {
        guard let draft = creationDraft else { throw WorkspaceError.emptyTitle }
        let task = try insertTask(title: draft.title, priority: draft.priority, projectID: draft.projectID, plannedDay: draft.plannedDay, note: draft.note, labelIDs: draft.labelIDs, consuming: draft)
        creationDraft = nil
        return task
    }

    private func insertTask(title: String, priority: TaskPriority, projectID: UUID?, plannedDay: String?, note: TaskNote, labelIDs: Set<UUID>, consuming draft: CreationDraft?) throws -> TaskRecord {
        let title = try validatedTitle(title)
        try validateDay(plannedDay)
        let createdAt = now()
        let context = DayContext(date: createdAt, calendar: calendar())
        let task = TaskRecord(
            id: UUID(), occurrenceID: UUID(), title: title,
            plannedDay: plannedDay,
            timeZoneIdentifier: context.timeZone.identifier, completedAt: nil, priority: priority, projectID: projectID, note: note, labelIDs: labelIDs
        )
        tasks = try database.insert(task, createdAt: createdAt, consuming: draft)
        dayContext = context
        return task
    }

    public func setCompleted(occurrenceID: UUID, completed: Bool) throws {
        let instant = now()
        try persistSessionCommand(at: instant) {
            tasks = try database.setCompleted(occurrenceID: occurrenceID, completed: completed, at: instant)
        }
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

    public func setLabels(id: UUID, labelIDs: Set<UUID>) throws {
        tasks = try database.setLabels(id: id, labelIDs: labelIDs)
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

    public func setNote(id: UUID, note: TaskNote) throws {
        tasks = try database.setNote(id: id, note: note)
    }

    /// Seed an untouched form from context; resume an entered draft without changing its day.
    @discardableResult
    public func prepareCreationDraft(projectID: UUID? = nil, plannedDay: String? = nil, labelIDs: Set<UUID> = []) throws -> CreationDraft {
        let saved = creationDraft ?? CreationDraft()
        let hasSavedInput = !saved.title.isEmpty || saved.priority != .none || saved.projectID != nil
            || saved.projectWasChosen || saved.note != .empty || saved.dayWasChosen || !saved.labelIDs.isEmpty || saved.labelsWereChosen
        let prepared = CreationDraft(
            title: saved.title, priority: saved.priority,
            projectID: creationDraft != nil ? saved.projectID : projectID,
            projectWasChosen: saved.projectWasChosen,
            plannedDay: hasSavedInput ? saved.plannedDay : plannedDay,
            dayWasChosen: saved.dayWasChosen, note: saved.note,
            labelIDs: creationDraft != nil ? saved.labelIDs : labelIDs, labelsWereChosen: saved.labelsWereChosen
        )
        try saveCreationDraft(prepared)
        return prepared
    }

    /// Set `replacingLabels` for an explicit picker choice, including an empty selection.
    public func saveCreationDraft(_ draft: CreationDraft, replacingLabels: Bool = false) throws {
        try validateDay(draft.plannedDay)
        try database.saveCreationDraft(draft, replacingLabels: replacingLabels)
        creationDraft = draft.isEmpty ? nil : draft
    }

    public func discardCreationDraft() throws {
        try saveCreationDraft(CreationDraft())
    }

    public var today: String {
        _ = dayContext
        return DayContext(date: now(), calendar: calendar()).day
    }

    public var tomorrow: String {
        _ = dayContext
        let current = calendar()
        return DayContext(date: current.date(byAdding: .day, value: 1, to: now())!, calendar: current).day
    }

    public func setPlannedDay(occurrenceID: UUID, day: String?) throws {
        try validateDay(day)
        tasks = try database.setPlannedDay(occurrenceID: occurrenceID, day: day, timeZone: calendar().timeZone.identifier)
    }

    private func validateDay(_ day: String?) throws {
        guard let day else { return }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: day), formatter.string(from: date) == day else { throw WorkspaceError.invalidDay }
    }

    public var openToday: [TaskRecord] {
        let day = today
        return tasks.filter { $0.completedAt == nil && $0.plannedDay.map { $0 <= day } == true }
    }

    public var completedToday: [TaskRecord] {
        _ = dayContext
        let context = DayContext(date: now(), calendar: calendar())
        return tasks.filter { $0.completedAt.map(context.contains) ?? false }
    }

    public func reload() throws {
        dayContext = DayContext(date: now(), calendar: calendar())
        tasks = try database.records()
        projects = try database.projects()
        labels = try database.labels()
        lastDeletedLabel = try database.lastDeletedLabel()
        creationDraft = try database.creationDraft()
        try loadTimeTools()
    }

    /// Reads the injected clock on demand; UI rendering never increments stored time.
    public var elapsedSeconds: TimeInterval { activeSession?.elapsedSeconds(at: now()) ?? 0 }

    public func startStopwatch(occurrenceID: UUID? = nil) throws {
        try retrySessionSave()
        try database.startStopwatch(occurrenceID: occurrenceID, at: now(), timeZone: calendar().timeZone.identifier)
        try loadTimeTools()
    }

    public func pauseSession() throws {
        let instant = now()
        try persistSessionCommand(at: instant) { try database.changeSession(.pause, at: instant) }
    }

    public func resumeSession() throws {
        let instant = now()
        try persistSessionCommand(at: instant) { try database.changeSession(.resume, at: instant) }
    }

    public func stopSession() throws {
        let instant = now()
        try persistSessionCommand(at: instant) { try database.changeSession(.stop, at: instant) }
    }

    public func retrySessionSave() throws {
        if let pendingPausedSession {
            try database.savePausedSession(pendingPausedSession)
            self.pendingPausedSession = nil
        }
        try loadTimeTools()
    }

    private func persistSessionCommand(at instant: Date, _ command: () throws -> Void) throws {
        do {
            try retrySessionSave()
            try command()
            try loadTimeTools()
        } catch {
            if let failure = error as? WorkspaceError, case .storage = failure, var frozen = activeSession {
                frozen.closeSegment(at: instant)
                activeSession = frozen
                pendingPausedSession = frozen
            }
            throw error
        }
    }

    private func loadTimeTools() throws {
        if pendingPausedSession == nil { activeSession = try database.activeTimeToolSession() }
        timeToolResults = try database.timeToolResults()
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
