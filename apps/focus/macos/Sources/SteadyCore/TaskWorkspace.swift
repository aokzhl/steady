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

/// Durable rich text is opaque to Core; the projection supports display and search.
/// The macOS editor encodes `rtf` using the standard RTF interchange format.
public struct TaskNote: Equatable, Sendable, Codable {
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

public enum TaskRecurrence: Equatable, Sendable, Codable {
    case daily
    case weekly
    case weekdays
    /// Calendar weekday numbers: Sunday = 1, Monday = 2, … Saturday = 7.
    case selectedWeekdays(Set<Int>)

    public var label: String {
        switch self {
        case .weekly: "Раз в неделю в любой день"
        case .daily: "Ежедневно"
        case .weekdays: "По будням"
        case .selectedWeekdays: "Выбранные дни"
        }
    }

    var weekdays: Set<Int> {
        switch self {
        case .weekly: Set(1...7)
        case .daily: Set(1...7)
        case .weekdays: Set(2...6)
        case .selectedWeekdays(let days): days
        }
    }

    func validate() throws {
        guard !weekdays.isEmpty, weekdays.isSubset(of: Set(1...7)) else { throw WorkspaceError.invalidRecurrence }
    }
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
    public internal(set) var parentTaskID: UUID? = nil
    public internal(set) var parentOccurrenceID: UUID? = nil
    public internal(set) var recurrence: TaskRecurrence? = nil
    public internal(set) var seriesStart: String? = nil
    public internal(set) var seriesDay: String? = nil
    /// Inclusive Sunday boundary; seriesDay is the Monday identity, independent of plannedDay.
    public internal(set) var periodEnd: String? = nil
    public internal(set) var skippedAt: Date? = nil
}

public struct SubtaskDraft: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var title: String
    public var note: TaskNote
    public var labelIDs: Set<UUID>
    public var pomodoroParameters: PomodoroParameters? = nil
    public init(id: UUID = UUID(), title: String = "", note: TaskNote = .empty, labelIDs: Set<UUID> = []) {
        self.id = id; self.title = title; self.note = note; self.labelIDs = labelIDs
    }
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
    public let recurrence: TaskRecurrence?
    public let seriesStart: String?
    public let children: [SubtaskDraft]
    public let pomodoroParameters: PomodoroParameters?

    public init(title: String = "", priority: TaskPriority = .none, projectID: UUID? = nil, projectWasChosen: Bool = false, plannedDay: String? = nil, dayWasChosen: Bool = false, note: TaskNote = .empty, labelIDs: Set<UUID> = [], labelsWereChosen: Bool = false, recurrence: TaskRecurrence? = nil, seriesStart: String? = nil, children: [SubtaskDraft] = [], pomodoroParameters: PomodoroParameters? = nil) {
        self.pomodoroParameters = pomodoroParameters
        self.children = children
        self.recurrence = recurrence
        self.seriesStart = seriesStart
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
        pomodoroParameters == nil && children.isEmpty && title.isEmpty && priority == .none && projectID == nil && !projectWasChosen && note == .empty && plannedDay == nil && !dayWasChosen && recurrence == nil && seriesStart == nil && labelIDs.isEmpty && !labelsWereChosen
    }
}

@MainActor
@Observable
public final class TaskWorkspace {
    public private(set) var pomodoroProfiles: [PomodoroProfile] = []
    public private(set) var selectedPomodoroProfileID: UUID?
    public private(set) var lastDeletedLabel: LabelRecord?
    public private(set) var labels: [LabelRecord] = []
    public private(set) var projects: [ProjectRecord] = []
    public private(set) var tasks: [TaskRecord] = []
    public private(set) var activeSession: TimeToolSession?
    public private(set) var timeToolResults: [TimeToolSession] = []
    public private(set) var creationDraft: CreationDraft?
    public private(set) var preferences: WorkspacePreferences
    private var pendingPausedSession: TimeToolSession?
    public var sessionNeedsSave: Bool { pendingPausedSession != nil }
    private let database: SQLiteDatabase
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var dayContext: DayContext
    private var preparedThrough: String?

    public init(databaseURL: URL, now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current }) throws {
        self.now = now
        self.calendar = calendar
        self.dayContext = DayContext(date: now(), calendar: calendar())
        self.database = try SQLiteDatabase(url: databaseURL)
        self.preferences = try database.workspacePreferences()
        self.pomodoroProfiles = try database.pomodoroProfiles()
        self.selectedPomodoroProfileID = try database.selectedPomodoroProfileID()
        self.lastDeletedLabel = try database.lastDeletedLabel()
        self.labels = try database.labels()
        self.projects = try database.projects()
        try database.restorePausedSession()
        self.tasks = try database.refreshOccurrences(today: dayContext.day, timeZone: calendar().timeZone.identifier)
        self.creationDraft = try database.creationDraft()
        self.activeSession = try database.activeTimeToolSession()
        self.timeToolResults = try database.timeToolResults()
    }

    public func savePreferences(_ preferences: WorkspacePreferences) throws {
        try database.saveWorkspacePreferences(preferences)
        self.preferences = preferences
    }

    /// Materializes the selected bounded period while keeping read-only list rendering pure.
    public func prepareTaskList(in context: TaskListContext) throws {
        var current = Calendar(identifier: .gregorian)
        current.timeZone = calendar().timeZone
        let date = now()
        let bounds = periodBounds(for: context.period, at: context.namedMonth.flatMap { calendarDate($0) } ?? date, calendar: current)
        tasks = try database.refreshOccurrences(today: today, timeZone: current.timeZone.identifier, through: bounds.end)
        preparedThrough = bounds.end
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
    public func createTask(title: String, priority: TaskPriority = .none, projectID: UUID? = nil, plannedDay: String? = nil, note: TaskNote = .empty, labelIDs: Set<UUID> = [], recurrence: TaskRecurrence? = nil, seriesStart: String? = nil) throws -> TaskRecord {
        try insertTask(title: title, priority: priority, projectID: projectID, plannedDay: plannedDay, note: note, labelIDs: labelIDs, recurrence: recurrence, seriesStart: seriesStart, consuming: nil)
    }

    @discardableResult
    public func createTaskFromDraft() throws -> TaskRecord {
        guard let draft = creationDraft else { throw WorkspaceError.emptyTitle }
        let task = try insertTask(title: draft.title, priority: draft.priority, projectID: draft.projectID, plannedDay: draft.plannedDay, note: draft.note, labelIDs: draft.labelIDs, recurrence: draft.recurrence, seriesStart: draft.seriesStart, consuming: draft)
        creationDraft = nil
        return task
    }

    private func insertTask(title: String, priority: TaskPriority, projectID: UUID?, plannedDay: String?, note: TaskNote, labelIDs: Set<UUID>, recurrence: TaskRecurrence?, seriesStart: String?, consuming draft: CreationDraft?) throws -> TaskRecord {
        let title = try validatedTitle(title)
        try validateDay(plannedDay)
        try validateDay(seriesStart)
        try recurrence?.validate()
        let createdAt = now()
        let context = DayContext(date: createdAt, calendar: calendar())
        var task = TaskRecord(
            id: UUID(), occurrenceID: UUID(), title: title,
            plannedDay: plannedDay,
            timeZoneIdentifier: context.timeZone.identifier, completedAt: nil, priority: priority, projectID: projectID, note: note, labelIDs: labelIDs
        )
        task.recurrence = recurrence
        task.seriesStart = recurrence == nil ? nil : (seriesStart ?? context.day)
        for child in draft?.children ?? [] { _ = try validatedTitle(child.title) }
        tasks = try database.insert(task, createdAt: createdAt, consuming: draft, today: context.day, through: preparedThrough)

        dayContext = context
        return tasks.first { $0.id == task.id && ($0.periodEnd ?? $0.plannedDay ?? "") >= context.day } ?? tasks.first { $0.id == task.id } ?? task
    }

    public func children(of parentOccurrenceID: UUID) -> [TaskRecord] {
        tasks.filter { $0.parentOccurrenceID == parentOccurrenceID }
    }

    @discardableResult
    public func addSubtask(parentOccurrenceID: UUID, title: String, note: TaskNote = .empty, labelIDs: Set<UUID> = []) throws -> TaskRecord {
        let child = SubtaskDraft(title: try validatedTitle(title), note: note, labelIDs: labelIDs)
        tasks = try database.addSubtask(parentOccurrenceID: parentOccurrenceID, child: child, at: now())
        return tasks.first { $0.id == child.id && $0.parentOccurrenceID == parentOccurrenceID }!
    }

    public func setCompleted(occurrenceID: UUID, completed: Bool) throws {
        let instant = now()
        try persistSessionCommand(at: instant) {
            tasks = try database.setCompleted(occurrenceID: occurrenceID, completed: completed, at: instant)
        }
        dayContext = DayContext(date: instant, calendar: calendar())
    }

    public func setSkipped(occurrenceID: UUID, skipped: Bool) throws {
        let instant = now()
        try persistSessionCommand(at: instant) {
            tasks = try database.setSkipped(occurrenceID: occurrenceID, skipped: skipped, at: instant)
        }
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
        visibleTasks.filter { $0.projectID == projectID }.filter { $0.completedAt == nil && $0.skippedAt == nil }.count
    }

    public func setNote(id: UUID, note: TaskNote) throws {
        tasks = try database.setNote(id: id, note: note)
    }

    /// Seed an untouched form from context; resume an entered draft without changing its day.
    @discardableResult
    public func prepareCreationDraft(projectID: UUID? = nil, plannedDay: String? = nil, labelIDs: Set<UUID> = []) throws -> CreationDraft {
        let saved = creationDraft ?? CreationDraft()
        let hasSavedInput = !saved.title.isEmpty || saved.priority != .none || saved.projectID != nil
            || saved.projectWasChosen || saved.note != .empty || saved.dayWasChosen || saved.recurrence != nil || !saved.labelIDs.isEmpty || saved.labelsWereChosen || !saved.children.isEmpty || saved.pomodoroParameters != nil
        let prepared = CreationDraft(
            title: saved.title, priority: saved.priority,
            projectID: creationDraft != nil ? saved.projectID : projectID,
            projectWasChosen: saved.projectWasChosen,
            plannedDay: hasSavedInput ? saved.plannedDay : plannedDay,
            dayWasChosen: saved.dayWasChosen, note: saved.note,
            labelIDs: creationDraft != nil ? saved.labelIDs : labelIDs, labelsWereChosen: saved.labelsWereChosen, recurrence: saved.recurrence, seriesStart: saved.seriesStart, children: saved.children, pomodoroParameters: saved.pomodoroParameters
        )
        try saveCreationDraft(prepared)
        return prepared
    }

    /// Set `replacingLabels` for an explicit picker choice, including an empty selection.
    public func saveCreationDraft(_ draft: CreationDraft, replacingLabels: Bool = false, replacingChildLabels: Set<UUID> = []) throws {
        try draft.pomodoroParameters?.validate()
        for child in draft.children { try child.pomodoroParameters?.validate() }
        try validateDay(draft.plannedDay)
        try validateDay(draft.seriesStart)
        try draft.recurrence?.validate()
        try database.saveCreationDraft(draft, replacingLabels: replacingLabels, replacingChildLabels: replacingChildLabels)
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
        tasks = try database.setPlannedDay(occurrenceID: occurrenceID, day: day, timeZone: calendar().timeZone.identifier, today: today)
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
        return tasks.filter { task in
            guard task.completedAt == nil, task.skippedAt == nil else { return false }
            if let end = task.periodEnd, let start = task.seriesDay {
                return start <= day && day <= end && task.plannedDay.map { $0 <= day } != false
            }
            return task.plannedDay.map { task.seriesStart == nil ? $0 <= day : $0 == day } ?? false
        }
    }

    public var currentWeekTasks: [TaskRecord] {
        _ = dayContext
        var current = Calendar(identifier: .gregorian)
        current.timeZone = calendar().timeZone
        let date = now()
        let offset = (current.component(.weekday, from: date) + 5) % 7
        let monday = current.date(byAdding: .day, value: -offset, to: date)!
        let sunday = current.date(byAdding: .day, value: 6, to: monday)!
        let start = DayContext(date: monday, calendar: current).day
        let end = DayContext(date: sunday, calendar: current).day
        return tasks.filter { task in
            if let periodEnd = task.periodEnd, let periodStart = task.seriesDay { return periodStart <= end && start <= periodEnd }
            return task.plannedDay.map { start <= $0 && $0 <= end } ?? false
        }
    }

    public var completedToday: [TaskRecord] {
        _ = dayContext
        let context = DayContext(date: now(), calendar: calendar())
        return tasks.filter { $0.completedAt.map(context.contains) ?? false }
    }

    public func reload() throws {
        dayContext = DayContext(date: now(), calendar: calendar())
        tasks = try database.refreshOccurrences(today: dayContext.day, timeZone: calendar().timeZone.identifier)
        projects = try database.projects()
        labels = try database.labels()
        lastDeletedLabel = try database.lastDeletedLabel()
        creationDraft = try database.creationDraft()
        try loadTimeTools()
    }

    /// Reads the injected clock on demand; UI rendering never increments stored time.
    public var elapsedSeconds: TimeInterval {
        guard let session = activeSession else { return 0 }
        let measured = session.elapsedSeconds(at: now())
        if let state = session.pomodoro, state.stage == .work {
            return min(state.focusStartElapsed + state.focusBudgetSeconds, measured)
        }
        return session.timerBudgetSeconds.map { min($0, measured) } ?? measured
    }

    public var remainingSeconds: TimeInterval? { activeSession?.remainingSeconds(at: now()) }

    public var restRemainingSeconds: TimeInterval? {
        guard let state = activeSession?.pomodoro, state.stage == .rest else { return nil }
        return state.restRemaining(at: now())
    }

    @discardableResult
    public func savePomodoroProfile(id: UUID? = nil, title: String, parameters: PomodoroParameters) throws -> PomodoroProfile {
        try parameters.validate()
        let profile = PomodoroProfile(id: id ?? UUID(), title: try validatedTitle(title), parameters: parameters)
        try database.savePomodoroProfile(profile)
        pomodoroProfiles = try database.pomodoroProfiles()
        return profile
    }

    public func selectPomodoroProfile(id: UUID) throws {
        try database.selectPomodoroProfile(id: id)
        selectedPomodoroProfileID = id
    }

    public func pomodoroOverride(taskID: UUID) throws -> PomodoroParameters? { try database.pomodoroOverride(taskID: taskID) }
    public func pomodoroParameters(taskID: UUID? = nil) throws -> PomodoroParameters { try database.pomodoroParameters(taskID: taskID) }
    public func setPomodoroParameters(taskID: UUID, parameters: PomodoroParameters?) throws {
        try parameters?.validate()
        try database.setPomodoroParameters(taskID: taskID, parameters: parameters)
    }

    public func startPomodoro(occurrenceID: UUID? = nil) throws {
        try retrySessionSave()
        try database.startPomodoro(occurrenceID: occurrenceID, at: now(), timeZone: calendar().timeZone.identifier)
        try loadTimeTools()
    }

    public func startRest() throws {
        let instant = now()
        try persistSessionCommand(at: instant) { try database.changeSession(.startRest, at: instant) }
    }

    public func backToWork() throws {
        let instant = now()
        try persistSessionCommand(at: instant) { try database.changeSession(.backToWork, at: instant) }
    }

    public func timerDurationSeconds(taskID: UUID) throws -> TimeInterval? {
        try database.timerDurationSeconds(taskID: taskID)
    }

    public func startTimer(occurrenceID: UUID? = nil, durationSeconds: TimeInterval? = nil) throws {
        try retrySessionSave()
        try database.startTimer(occurrenceID: occurrenceID, durationSeconds: durationSeconds, at: now(), timeZone: calendar().timeZone.identifier)
        try loadTimeTools()
    }

    public func previewTimerIncrement(minutes: Int) throws -> TimeInterval? {
        guard (-20...20).contains(minutes) else { throw WorkspaceError.invalidTimerIncrement }
        guard let session = activeSession,
              session.pomodoro == nil || session.pomodoro?.stage == .work,
              let remainingNow = session.remainingSeconds(at: now()) else { return nil }
        let elapsed = session.elapsedSeconds(at: now())
        let remaining = max(0, remainingNow + Double(minutes) * 60)
        guard (elapsed + remaining).isFinite, elapsed + remaining <= TimeToolSession.maximumTimerDurationSeconds else {
            throw WorkspaceError.invalidTimerDuration
        }
        return remaining
    }

    /// Drives natural expiry; repeated notifications and Stop share one persisted transition.
    public func updateTimer() throws {
        guard let session = activeSession, session.kind != .stopwatch, !session.isPaused, !sessionNeedsSave else { return }
        if session.pomodoro?.stage == .rest {
            guard restRemainingSeconds == 0 else { return }
        } else {
            guard session.pomodoro == nil || session.pomodoro?.stage == .work, remainingSeconds == 0 else { return }
        }
        let instant = now()
        try persistSessionCommand(at: instant) { try database.changeSession(.tick, at: instant) }
    }

    public func adjustTimer(minutes: Int) throws {
        guard (-20...20).contains(minutes) else { throw WorkspaceError.invalidTimerIncrement }
        let instant = now()
        try persistSessionCommand(at: instant) { try database.changeSession(.adjust(minutes), at: instant) }
    }

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
                if frozen.finishTimerIfNeeded(at: instant) {
                    frozen.stoppedAt = nil // Frozen for retry; the persisted result still does not exist.
                } else {
                    frozen.finishPomodoroIfNeeded(at: instant)
                    frozen.pausePomodoro(at: instant)
                }
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

    /// One current or nearest future occurrence per series; history stays available separately.
    public var visibleTasks: [TaskRecord] {
        let day = today
        var indices: [UUID: Int] = [:]
        var visible: [TaskRecord] = []
        for task in tasks {
            guard task.seriesStart != nil else { visible.append(task); continue }
            guard let boundary = task.periodEnd ?? task.plannedDay, boundary >= day else { continue }
            if let index = indices[task.id] {
                // A preserved daily fact may share the Monday of a new weekly period.
                if visible[index].periodEnd == nil, task.periodEnd != nil { visible[index] = task }
            } else {
                indices[task.id] = visible.count
                visible.append(task)
            }
        }
        return visible
    }

    public func occurrences(from firstDay: String, through lastDay: String) throws -> [TaskRecord] {
        try validateDay(firstDay)
        try validateDay(lastDay)
        guard firstDay <= lastDay else { throw WorkspaceError.invalidDay }
        tasks = try database.refreshOccurrences(today: today, timeZone: calendar().timeZone.identifier, through: lastDay)
        return tasks.filter { task in
            if let end = task.periodEnd, let start = task.seriesDay { return start <= lastDay && firstDay <= end }
            return task.plannedDay.map { firstDay <= $0 && $0 <= lastDay } ?? false
        }
    }

    public func setRecurrence(occurrenceID: UUID, recurrence: TaskRecurrence) throws {
        try recurrence.validate()
        tasks = try database.setRecurrence(occurrenceID: occurrenceID, recurrence: recurrence, today: today, timeZone: calendar().timeZone.identifier, through: preparedThrough)
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

extension TaskWorkspace {
    /// One calendar definition serves occurrence materialization and list filtering.
    private func periodBounds(for period: TaskPeriod, at date: Date, calendar: Calendar) -> (start: String, end: String) {
        let start: Date
        let end: Date
        switch period {
        case .week:
            let offset = (calendar.component(.weekday, from: date) + 5) % 7
            start = calendar.date(byAdding: .day, value: -offset, to: date)!
            end = calendar.date(byAdding: .day, value: 6, to: start)!
        case .month:
            let month = calendar.dateInterval(of: .month, for: date)!
            start = month.start
            end = calendar.date(byAdding: .day, value: -1, to: month.end)!
        case .tomorrow:
            start = calendar.date(byAdding: .day, value: 1, to: date)!
            end = start
        case .all, .today, .completed:
            start = date
            end = date
        }
        return (DayContext(date: start, calendar: calendar).day, DayContext(date: end, calendar: calendar).day)
    }

    public func taskList(in context: TaskListContext, searchQuery: String = "") -> TaskListResult {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = now()
        var current = Calendar(identifier: .gregorian)
        current.timeZone = calendar().timeZone
        let day = DayContext(date: date, calendar: current)
        let bounds = periodBounds(for: context.period, at: context.namedMonth.flatMap { calendarDate($0) } ?? date, calendar: current)
        let source = context.period == .all ? visibleTasks : tasks
        let periodMatches = source.filter { task in
            if context.period == .completed { return task.completedAt != nil }
            guard task.skippedAt == nil, context.showCompleted || task.completedAt == nil else { return false }
            switch context.period {
            case .all: return true
            case .completed: return false
            case .today:
                if let completedAt = task.completedAt { return day.contains(completedAt) }
                if let end = task.periodEnd, let start = task.seriesDay {
                    return start <= day.day && day.day <= end && task.plannedDay.map { $0 <= day.day } != false
                }
                return task.plannedDay.map { task.seriesStart == nil ? $0 <= day.day : $0 == day.day } ?? false
            case .tomorrow:
                if let end = task.periodEnd, let start = task.seriesDay, task.plannedDay == nil { return start <= bounds.start && bounds.start <= end }
                return task.plannedDay == bounds.start
            case .week, .month:
                if let periodEnd = task.periodEnd, let periodStart = task.seriesDay, task.plannedDay == nil {
                    return periodStart <= bounds.end && bounds.start <= periodEnd
                }
                return task.plannedDay.map { bounds.start <= $0 && $0 <= bounds.end } ?? false
            }
        }
        let matches = periodMatches.filter { task in
            guard context.projectID == nil || task.projectID == context.projectID else { return false }
            guard query.isEmpty || task.title.localizedCaseInsensitiveContains(query) || task.note.plainText.localizedCaseInsensitiveContains(query) else { return false }
            return context.labelIDs.isEmpty || (context.labelMatch == .any ? !task.labelIDs.isDisjoint(with: context.labelIDs) : context.labelIDs.isSubset(of: task.labelIDs))
        }
        let matchIDs = Set(matches.map(\.occurrenceID))
        let parents = Set(matches.compactMap(\.parentOccurrenceID))
        let roots = tasks.filter { $0.parentTaskID == nil && (matchIDs.contains($0.occurrenceID) || parents.contains($0.occurrenceID)) }
        let contextParents = Set(roots.filter { !matchIDs.contains($0.occurrenceID) }.map(\.occurrenceID))
        func count(_ roots: [TaskRecord]) -> Int {
            let ids = Set(roots.map(\.occurrenceID))
            return matches.filter { ids.contains($0.occurrenceID) || $0.parentOccurrenceID.map(ids.contains) == true }.count
        }
        var groups: [TaskListGroup] = []
        let overdue = roots.filter { root in
            matches.contains { task in
                (task.occurrenceID == root.occurrenceID || task.parentOccurrenceID == root.occurrenceID)
                    && task.completedAt == nil && task.seriesStart == nil && task.plannedDay.map { $0 < day.day } == true
            }
        }
        if !overdue.isEmpty { groups.append(TaskListGroup(id: "overdue", title: "Просроченные", roots: overdue, matchCount: count(overdue))) }
        let overdueIDs = Set(overdue.map(\.occurrenceID))
        let weekly = context.period == .today ? roots.filter { root in
            matches.contains { task in
                (task.occurrenceID == root.occurrenceID || task.parentOccurrenceID == root.occurrenceID)
                    && task.periodEnd != nil && task.plannedDay == nil && task.completedAt == nil
            }
        } : []
        if !weekly.isEmpty { groups.append(TaskListGroup(id: "weekly-undated", title: "Можно на этой неделе", roots: weekly, matchCount: count(weekly))) }
        let weeklyIDs = Set(weekly.map(\.occurrenceID))
        let rest = roots.filter { !overdueIDs.contains($0.occurrenceID) && !weeklyIDs.contains($0.occurrenceID) }
        for project in projects {
            let group = rest.filter { $0.projectID == project.id }
            if !group.isEmpty { groups.append(TaskListGroup(id: project.id.uuidString, title: project.title, roots: group, matchCount: count(group))) }
        }
        let unassigned = rest.filter { $0.projectID == nil }
        if !unassigned.isEmpty { groups.append(TaskListGroup(id: "unassigned", title: "Без проекта", roots: unassigned, matchCount: count(unassigned))) }
        let empty: TaskListEmptyReason? = matches.isEmpty ? (tasks.isEmpty ? .emptyDatabase : !query.isEmpty ? .noSearchMatches : periodMatches.isEmpty ? .emptyPeriod : .noMatches) : nil
        return TaskListResult(matches: matches, roots: roots, contextParentIDs: contextParents, groups: groups, emptyReason: empty)
    }
}

extension TaskWorkspace {
    // Calendar dates remain date-only keys; use the same injected calendar zone as period bounds.
    private func calendarDate(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar().timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: day)
    }

    public var currentMonth: String { String(today.prefix(7)) + "-01" }

    public func adjacentMonth(_ month: String, offset: Int) -> String {
        var current = Calendar(identifier: .gregorian)
        current.timeZone = calendar().timeZone
        guard let date = calendarDate(month), let next = current.date(byAdding: .month, value: offset, to: date) else { return currentMonth }
        return String(DayContext(date: next, calendar: current).day.prefix(7)) + "-01"
    }

    private func monthContext(_ month: String) -> (calendar: Calendar, interval: DateInterval)? {
        guard let date = calendarDate(month) else { return nil }
        var value = Calendar(identifier: .gregorian)
        value.timeZone = calendar().timeZone
        guard let interval = value.dateInterval(of: .month, for: date) else { return nil }
        return (value, interval)
    }

    public func prepareCalendar(month: String) throws {
        guard let (value, interval) = monthContext(month) else { return }
        let last = value.date(byAdding: .day, value: -1, to: interval.end)!
        let end = DayContext(date: last, calendar: value).day
        _ = try occurrences(from: DayContext(date: interval.start, calendar: value).day, through: end)
        preparedThrough = end
    }

    public func taskCalendar(month: String, in context: TaskListContext, searchQuery: String = "") -> TaskCalendarResult {
        let (value, interval) = monthContext(month) ?? monthContext(currentMonth)!
        let start = DayContext(date: interval.start, calendar: value).day
        let end = DayContext(date: value.date(byAdding: .day, value: -1, to: interval.end)!, calendar: value).day
        // Use the list's exact period/context predicates, while undated items remain reachable separately.
        var datedContext = context
        if context.period == .all { datedContext.period = .month; datedContext.namedMonth = start }
        let matchingIDs = Set(taskList(in: datedContext, searchQuery: searchQuery).matches.map(\.occurrenceID))
        var all = context
        all.period = context.period == .completed ? .completed : .all
        all.namedMonth = nil
        let allMatches = taskList(in: all, searchQuery: searchQuery).matches
        let undated = allMatches.filter { $0.plannedDay == nil && $0.periodEnd == nil }
        let weekly = tasks.filter { task in
            guard task.plannedDay == nil, let first = task.seriesDay, let last = task.periodEnd else { return false }
            return first <= end && start <= last && matchingIDs.contains(task.occurrenceID)
        }
        let days = (0..<value.range(of: .day, in: .month, for: interval.start)!.count).map { offset in
            let key = DayContext(date: value.date(byAdding: .day, value: offset, to: interval.start)!, calendar: value).day
            let inPeriod: Bool
            switch context.period {
            case .today: inPeriod = key == today
            case .tomorrow: inPeriod = key == tomorrow
            case .week:
                let bounds = periodBounds(for: .week, at: now(), calendar: value)
                inPeriod = bounds.start <= key && key <= bounds.end
            default: inPeriod = true
            }
            return TaskCalendarDay(day: key, tasks: tasks.filter { $0.plannedDay == key && matchingIDs.contains($0.occurrenceID) }, isInPeriod: inPeriod)
        }
        return TaskCalendarResult(month: start, leadingDays: (value.component(.weekday, from: interval.start) + 5) % 7, days: days, undated: undated, weekly: weekly)
    }
}
