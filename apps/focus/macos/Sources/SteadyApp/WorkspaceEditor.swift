import AppKit
import Observation
import SteadyCore

/// Window editing state outlives its panels, including unsaved input after a disk error.
@MainActor
@Observable
final class WorkspaceEditor {
    @ObservationIgnored var reopenWindow: (() -> Void)?
    @ObservationIgnored private var timerUpdates: Timer?
    var timerPromptVisible = false
    var timerPromptTask: TaskRecord?
    var timerMinutes = ""
    var timerPromptError: String?
    var workspace: TaskWorkspace?
    var openingError: String?
    var actionError: String?
    var draftError: String?
    private var titleError: String?
    private var priorityError: String?
    private var projectError: String?
    private var noteError: String?
    private var dayError: String?
    private var restoringNavigation = false
    var navigation = WorkspacePreferences() { didSet { if !restoringNavigation { _ = saveNavigation() } } }
    var context: TaskListContext {
        get { navigation.context }
        set { navigation.context = newValue }
    }
    var period: TaskPeriod {
        get { context.period }
        set { context.period = newValue }
    }
    var sidebarVisible: Bool {
        get { navigation.sidebarVisible }
        set { navigation.sidebarVisible = newValue }
    }
    var screen: WorkspaceScreen {
        get { navigation.screen }
        set { navigation.screen = newValue }
    }
    var searchQuery = ""
    private var searchOrigin: WorkspacePreferences?
    private var searchOriginWasCreating = false
    var searchFocusRequest = 0
    var isSearching: Bool { searchOrigin != nil }
    var searchAllTasks: Bool { isSearching && context == TaskListContext(period: .all, showCompleted: true) }
    var listResult: TaskListResult? { workspace?.taskList(in: context, searchQuery: searchQuery) }

    @discardableResult
    func beginSearch() -> Bool {
        guard saveDetails(), !isCreating || saveDraft() else { return false }
        if !isSearching {
            searchOrigin = navigation
            searchOriginWasCreating = isCreating
        }
        isCreating = false
        detailsVisible = false
        screen = .tasks
        presentation = .list
        calendarDay = nil
        searchFocusRequest += 1
        return true
    }

    func searchEverywhere() {
        guard isSearching else { return }
        presentation = .list
        context = TaskListContext(period: .all, showCompleted: true)
        reload()
    }

    func searchEscape() {
        if !searchQuery.isEmpty { searchQuery = "" }
        else { endSearch() }
    }

    @discardableResult
    func endSearch() -> Bool {
        guard let origin = searchOrigin else { return true }
        guard saveDetails(), !isCreating || saveDraft() else { return false }
        searchOrigin = nil
        searchQuery = ""
        navigation = origin
        isCreating = searchOriginWasCreating
        if let task = selectedTask {
            let visible = detailsVisible
            showDetails(for: task)
            detailsVisible = visible
        }
        reload()
        return true
    }
    var presentation: TaskPresentation {
        get { navigation.presentation }
        set { navigation.presentation = newValue; prepareCalendar() }
    }
    var calendarMonth: String {
        guard let workspace else { return "" }
        switch period {
        case .today, .week: return workspace.currentMonth
        case .tomorrow: return String(workspace.tomorrow.prefix(7)) + "-01"
        case .month: return context.namedMonth ?? workspace.currentMonth
        case .all, .completed: return navigation.calendarMonth ?? workspace.currentMonth
        }
    }
    var calendarResult: TaskCalendarResult? { workspace?.taskCalendar(month: calendarMonth, in: context, searchQuery: searchQuery) }
    var calendarDay: String? {
        get { navigation.calendarDay }
        set { navigation.calendarDay = newValue }
    }
    func prepareCalendar() {
        do { try workspace?.prepareCalendar(month: calendarMonth) }
        catch { actionError = error.localizedDescription }
    }
    func moveMonth(_ offset: Int) {
        guard saveDetails(), let workspace else { return }
        let month = workspace.adjacentMonth(calendarMonth, offset: offset)
        navigation.calendarMonth = month
        context.namedMonth = month
        period = .month
        calendarDay = nil
        detailsVisible = false
        prepareCalendar()
    }
    func openCalendarDay(_ day: String) {
        guard saveDetails() else { return }
        if isCreating { closeCreation() }
        calendarDay = day
        detailsVisible = false
    }
    func createOnDay(_ day: String) {
        openCalendarDay(day)
        guard calendarDay == day else { return }
        openCreation()
        draftDay = day
        draftDayWasChosen = true
        _ = saveDraft()
    }
    var contextTitle: String {
        let project = workspace?.projects.first { $0.id == selectedProjectID }?.title
        let labels = workspace?.labels.filter { context.labelIDs.contains($0.id) }.map(\.title) ?? []
        let names = [project].compactMap { $0 } + labels
        return (names.isEmpty ? ["Все задачи"] : names).joined(separator: " · ")
    }
    @discardableResult
    func saveNavigation() -> Bool {
        guard let workspace else { return true }
        do { try workspace.savePreferences(searchOrigin ?? navigation); return true }
        catch { actionError = error.localizedDescription; return false }
    }
    var draftDay: String?
    var draftDayWasChosen = false
    var draftRecurrence: TaskRecurrence?
    var draftSeriesStart: String?
    var detailRecurrence: TaskRecurrence?
    private var recurrenceError: String?
    var detailDay: String?

    var contextDay: String? {
        switch period {
        case .all, .week, .month, .completed: nil
        case .today: workspace?.today
        case .tomorrow: workspace?.tomorrow
        }
    }
    private var labelsError: String?
    var selectedLabelID: UUID? { context.labelIDs.count == 1 ? context.labelIDs.first : nil }
    var draftLabelIDs: Set<UUID> = []
    var draftLabelsWereChosen = false
    private var draftLabelsNeedReplacement = false
    var detailLabelIDs: Set<UUID> = []
    var selectedProjectID: UUID? {
        get { context.projectID }
        set { context.projectID = newValue }
    }
    var draftProjectID: UUID?
    var draftProjectWasChosen = false
    var detailProjectID: UUID?

    var detailError: String? {
        let messages = [titleError, priorityError, projectError, noteError, dayError, recurrenceError, labelsError].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    var draftNote: TaskNote = .empty
    var detailNote: TaskNote = .empty
    var draftChildLabelsNeedReplacement: Set<UUID> = []
    var draftTimerDurationSeconds: TimeInterval?
    var draftPomodoroParameters: PomodoroParameters?
    var detailPomodoroParameters: PomodoroParameters?
    var draftChildren: [SubtaskDraft] = []
    var newChildTitle = ""
    var expandedParents: Set<UUID> {
        get { navigation.expandedParentIDs }
        set { navigation.expandedParentIDs = newValue }
    }
    var draftTitle = ""
    var draftPriority: TaskPriority = .none
    var detailTitle = ""
    var detailPriority: TaskPriority = .none
    var isCreating = false
    var detailsVisible: Bool {
        get { navigation.detailsVisible }
        set { navigation.detailsVisible = newValue }
    }
    var selectedID: UUID? {
        get { navigation.selectedOccurrenceID }
        set { navigation.selectedOccurrenceID = newValue }
    }

    var selectedTask: TaskRecord? {
        workspace?.tasks.first { $0.occurrenceID == selectedID }
    }

    private var draft: CreationDraft { CreationDraft(title: draftTitle, priority: draftPriority, projectID: draftProjectID, projectWasChosen: draftProjectWasChosen, plannedDay: draftDay, dayWasChosen: draftDayWasChosen, note: draftNote, labelIDs: draftLabelIDs, labelsWereChosen: draftLabelsWereChosen, recurrence: draftRecurrence, seriesStart: draftSeriesStart, children: draftChildren, pomodoroParameters: draftPomodoroParameters, timerDurationSeconds: draftTimerDurationSeconds) }

    func openWorkspace() {
        guard workspace == nil else { return }
        do {
            let base = ProcessInfo.processInfo.environment["STEADY_DATA_DIRECTORY"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            let opened = try TaskWorkspace(databaseURL: TaskWorkspace.guestDatabaseURL(in: base))
            workspace = opened
            restoringNavigation = true
            navigation = opened.preferences
            try opened.prepareTaskList(in: context)
            if presentation == .calendar { try opened.prepareCalendar(month: calendarMonth) }
            if let task = selectedTask {
                let visible = navigation.detailsVisible
                showDetails(for: task)
                detailsVisible = visible
            }
            restoringNavigation = false
            timerUpdates = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTimer() }
            }
            draftTimerDurationSeconds = opened.creationDraft?.timerDurationSeconds
            draftPomodoroParameters = opened.creationDraft?.pomodoroParameters
            draftChildren = opened.creationDraft?.children ?? []
            draftTitle = opened.creationDraft?.title ?? ""
            draftPriority = opened.creationDraft?.priority ?? .none
            draftNote = opened.creationDraft?.note ?? .empty
            draftProjectID = opened.creationDraft?.projectID
            draftProjectWasChosen = opened.creationDraft?.projectWasChosen ?? false
            draftDay = opened.creationDraft?.plannedDay
            draftDayWasChosen = opened.creationDraft?.dayWasChosen ?? false
            draftLabelIDs = opened.creationDraft?.labelIDs ?? []
            draftLabelsWereChosen = opened.creationDraft?.labelsWereChosen ?? false
            draftRecurrence = opened.creationDraft?.recurrence
            draftSeriesStart = opened.creationDraft?.seriesStart
            openingError = nil
        } catch { restoringNavigation = false; workspace = nil; openingError = error.localizedDescription }
    }

    func reload() {
        do {
            try workspace?.reload()
            try workspace?.prepareTaskList(in: context)
            if presentation == .calendar { try workspace?.prepareCalendar(month: calendarMonth) }
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    func openCreation() {
        guard saveDetails() else { return }
        guard let workspace, saveDraft() else { isCreating = true; return }
        do {
            let prepared = try workspace.prepareCreationDraft(projectID: selectedProjectID, plannedDay: presentation == .calendar ? (calendarDay ?? contextDay) : contextDay, labelIDs: context.labelIDs)
            draftProjectID = prepared.projectID
            draftDay = prepared.plannedDay
            draftLabelIDs = prepared.labelIDs
            draftRecurrence = prepared.recurrence
            draftSeriesStart = prepared.seriesStart
            draftError = nil
        } catch { draftError = error.localizedDescription }
        isCreating = true
    }

    func closeCreation() {
        // A failed save remains in this model even when the panel is hidden.
        _ = saveDraft()
        isCreating = false
        if isSearching { searchFocusRequest += 1 }
    }

    @discardableResult
    func saveDraft() -> Bool {
        guard let workspace else { return false }
        do {
            if draftLabelsNeedReplacement || !draftChildLabelsNeedReplacement.isEmpty || draft != (workspace.creationDraft ?? CreationDraft()) {
                try workspace.saveCreationDraft(draft, replacingLabels: draftLabelsNeedReplacement, replacingChildLabels: draftChildLabelsNeedReplacement)
            }
            draftChildLabelsNeedReplacement = []
            draftLabelsNeedReplacement = false
            draftError = nil
            return true
        } catch {
            draftError = error.localizedDescription
            return false
        }
    }

    func discardDraft() {
        do {
            try workspace?.discardCreationDraft()
            draftTimerDurationSeconds = nil
            draftPomodoroParameters = nil
            draftChildren = []
            draftTitle = ""
            draftPriority = .none
            draftNote = .empty
            draftProjectID = nil
            draftProjectWasChosen = false
            draftDay = nil
            draftDayWasChosen = false
            draftLabelIDs = []
            draftLabelsWereChosen = false
            draftChildLabelsNeedReplacement = []
            draftLabelsNeedReplacement = false
            draftRecurrence = nil
            draftSeriesStart = nil
            draftError = nil
        } catch { draftError = error.localizedDescription }
    }

    func createTask() {
        guard let workspace, saveDraft() else { return }
        do {
            let task = try workspace.createTaskFromDraft()
            draftTimerDurationSeconds = nil
            draftPomodoroParameters = nil
            draftChildren = []
            draftTitle = ""
            draftPriority = .none
            draftNote = .empty
            draftProjectID = nil
            draftProjectWasChosen = false
            draftDay = nil
            draftDayWasChosen = false
            draftLabelIDs = []
            draftLabelsWereChosen = false
            draftChildLabelsNeedReplacement = []
            draftLabelsNeedReplacement = false
            draftRecurrence = nil
            draftSeriesStart = nil
            draftError = nil
            isCreating = false
            showDetails(for: task)
        } catch { draftError = error.localizedDescription }
    }

    func selectTask(_ task: TaskRecord) {
        guard saveDetails() else { return }
        if isCreating { closeCreation() }
        let saved = workspace?.tasks.first { $0.occurrenceID == task.occurrenceID } ?? task
        showDetails(for: saved)
    }

    private func showDetails(for task: TaskRecord) {
        selectedID = task.occurrenceID
        detailPomodoroParameters = try? workspace?.pomodoroOverride(taskID: task.id)
        detailTitle = task.title
        detailPriority = task.priority
        detailNote = task.note
        noteError = nil
        detailProjectID = task.projectID
        detailDay = task.plannedDay
        detailRecurrence = task.recurrence
        recurrenceError = nil
        dayError = nil
        detailLabelIDs = task.labelIDs
        labelsError = nil
        projectError = nil
        titleError = nil
        priorityError = nil
        detailsVisible = true
    }

    func closeDetails() {
        if saveDetails() {
            detailsVisible = false
            if isSearching { searchFocusRequest += 1 }
        }
    }

    @discardableResult
    func saveTitle() -> Bool {
        guard let task = selectedTask else { return true }
        guard detailTitle != task.title else { titleError = nil; return true }
        do {
            try workspace?.renameTask(id: task.id, title: detailTitle)
            detailTitle = selectedTask?.title ?? detailTitle
            titleError = nil
            return true
        } catch {
            titleError = error.localizedDescription
            return false
        }
    }

    func changePriority(_ priority: TaskPriority) {
        detailPriority = priority
        _ = savePriority()
    }

    private func savePriority() -> Bool {
        guard let task = selectedTask else { return true }
        guard detailPriority != task.priority else { priorityError = nil; return true }
        do {
            try workspace?.setPriority(id: task.id, priority: detailPriority)
            priorityError = nil
            return true
        } catch {
            priorityError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveNote() -> Bool {
        guard let task = selectedTask else { return true }
        guard detailNote != task.note else { noteError = nil; return true }
        do {
            try workspace?.setNote(id: task.id, note: detailNote)
            noteError = nil
            return true
        } catch {
            noteError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveDetails() -> Bool {
        guard saveTitle() else { return false }
        guard savePriority() else { return false }
        guard saveProject() else { return false }
        guard saveNote() else { return false }
        guard saveDay() else { return false }
        guard saveLabels() else { return false }
        return saveRecurrence()
    }

    func selectProject(_ id: UUID?) {
        guard endSearch() else { return }
        guard saveDetails() else { return }
        if isCreating { closeCreation() }
        selectedProjectID = id
        if id == nil { context.labelIDs = []; context.labelMatch = .any }
        screen = .tasks
        detailsVisible = false
    }

    func selectLabel(_ id: UUID) {
        guard endSearch() else { return }
        guard saveDetails() else { return }
        if isCreating { closeCreation() }
        if !context.labelIDs.insert(id).inserted { context.labelIDs.remove(id) }
        screen = .tasks
        detailsVisible = false
    }

    func changeDraftLabels(_ ids: Set<UUID>) {
        draftLabelIDs = ids
        draftLabelsWereChosen = true
        draftLabelsNeedReplacement = true
        _ = saveDraft()
    }

    func changeLabels(_ ids: Set<UUID>) {
        detailLabelIDs = ids
        _ = saveLabels()
    }

    private func saveLabels() -> Bool {
        guard let task = selectedTask else { return true }
        guard detailLabelIDs != task.labelIDs else { labelsError = nil; return true }
        do {
            try workspace?.setLabels(id: task.id, labelIDs: detailLabelIDs)
            labelsError = nil
            return true
        } catch {
            labelsError = error.localizedDescription
            return false
        }
    }

    func deleteLabel(_ label: LabelRecord) {
        guard saveDetails(), saveDraft() else { return }
        do {
            try workspace?.deleteLabel(id: label.id)
            context.labelIDs.remove(label.id)
            synchronizeLabelSelection()
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    func undoLabelDeletion() {
        guard saveDetails(), saveDraft() else { return }
        do {
            try workspace?.undoLabelDeletion()
            synchronizeLabelSelection()
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    private func synchronizeLabelSelection() {
        draftChildren = workspace?.creationDraft?.children ?? []
        draftLabelIDs = workspace?.creationDraft?.labelIDs ?? []
        detailLabelIDs = selectedTask?.labelIDs ?? []
        labelsError = nil
    }

    func changeProject(_ id: UUID?) {
        detailProjectID = id
        _ = saveProject()
    }

    private func saveProject() -> Bool {
        guard let task = selectedTask else { return true }
        guard task.projectID != detailProjectID else { projectError = nil; return true }
        do {
            try workspace?.setProject(id: task.id, projectID: detailProjectID)
            projectError = nil
            return true
        } catch {
            projectError = error.localizedDescription
            return false
        }
    }

    func changeDay(_ day: String?) {
        detailDay = day
        _ = saveDay()
    }

    private func saveDay() -> Bool {
        guard let task = selectedTask else { return true }
        guard detailDay != task.plannedDay else { dayError = nil; return true }
        do {
            try workspace?.setPlannedDay(occurrenceID: task.occurrenceID, day: detailDay)
            dayError = nil
            return true
        } catch {
            dayError = error.localizedDescription
            return false
        }
    }

    func changeDraftRecurrence(_ recurrence: TaskRecurrence?) {
        draftRecurrence = recurrence
        if recurrence != nil, draftSeriesStart == nil { draftSeriesStart = workspace?.today }
        if recurrence == nil { draftSeriesStart = nil }
        _ = saveDraft()
    }

    func changeRecurrence(_ recurrence: TaskRecurrence?) {
        detailRecurrence = recurrence
    }

    @discardableResult
    func saveRecurrence() -> Bool {
        guard let task = selectedTask, let recurrence = detailRecurrence, recurrence != task.recurrence else { recurrenceError = nil; return true }
        do {
            try workspace?.setRecurrence(occurrenceID: task.occurrenceID, recurrence: recurrence)
            detailDay = selectedTask?.plannedDay
            // A changed rule can remove the selected unworked occurrence.
            if selectedTask == nil, let next = workspace?.visibleTasks.first(where: { $0.id == task.id }) { showDetails(for: next) }
            recurrenceError = nil
            return true
        } catch { recurrenceError = error.localizedDescription; return false }
    }

    func selectPeriod(_ value: TaskPeriod) {
        guard saveDetails() else { return }
        if isCreating { closeCreation() }
        do {
            var next = context
            next.period = value
            next.namedMonth = nil
            navigation.calendarMonth = value == .tomorrow ? workspace.map { String($0.tomorrow.prefix(7)) + "-01" } : workspace?.currentMonth
            calendarDay = nil
            try workspace?.prepareTaskList(in: next)
            actionError = nil
            context = next
            if presentation == .calendar { prepareCalendar() }
            detailsVisible = false
        } catch { actionError = error.localizedDescription }
    }

    func cancelTitleEdit() {
        detailTitle = selectedTask?.title ?? ""
        titleError = nil
    }

    func discardDetailEdits() {
        detailTitle = selectedTask?.title ?? ""
        detailPriority = selectedTask?.priority ?? .none
        detailNote = selectedTask?.note ?? .empty
        noteError = nil
        detailProjectID = selectedTask?.projectID
        detailDay = selectedTask?.plannedDay
        detailRecurrence = selectedTask?.recurrence
        recurrenceError = nil
        dayError = nil
        detailLabelIDs = selectedTask?.labelIDs ?? []
        labelsError = nil
        projectError = nil
        titleError = nil
        priorityError = nil
    }

    func toggleSkipped(_ task: TaskRecord) {
        do {
            try workspace?.setSkipped(occurrenceID: task.occurrenceID, skipped: task.skippedAt == nil)
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    func openReport() {
        guard endSearch() else { return }
        guard saveDetails() else { return }
        if isCreating { closeCreation() }
        context.projectID = nil
        context.labelIDs = []
        screen = .report
        detailsVisible = false
    }

    func addChild() {
        guard let parent = selectedTask else { return }
        do {
            _ = try workspace?.addSubtask(parentOccurrenceID: parent.occurrenceID, title: newChildTitle)
            newChildTitle = ""
            expandedParents.insert(parent.occurrenceID)
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    func setCompleted(_ task: TaskRecord) {
        do {
            try workspace?.setCompleted(occurrenceID: task.occurrenceID, completed: task.completedAt == nil)
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    var activeSessionOwner: TaskRecord? {
        guard let occurrenceID = workspace?.activeSession?.occurrenceID else { return nil }
        return workspace?.tasks.first { $0.occurrenceID == occurrenceID }
    }

    func showActiveSessionOwner() {
        guard let owner = activeSessionOwner, saveDetails() else { return }
        if isCreating {
            guard saveDraft() else { return }
            isCreating = false
        }
        let saved = workspace?.tasks.first { $0.occurrenceID == owner.occurrenceID } ?? owner
        context = TaskListContext(projectID: saved.projectID, period: .all, showCompleted: saved.completedAt != nil)
        screen = .tasks
        showDetails(for: saved)
    }

    func requestTimer(_ task: TaskRecord?) {
        do {
            if let task, try workspace?.timerDurationSeconds(taskID: task.id) != nil {
                try workspace?.startTimer(occurrenceID: task.occurrenceID)
                actionError = nil
            } else {
                timerPromptTask = task
                timerMinutes = ""
                timerPromptError = nil
                timerPromptVisible = true
            }
        } catch { actionError = error.localizedDescription }
    }

    func confirmTimer() {
        do {
            let seconds = try timerSeconds(fromMinutes: timerMinutes)
            try workspace?.startTimer(occurrenceID: timerPromptTask?.occurrenceID, durationSeconds: seconds)
            timerPromptVisible = false
            actionError = nil
        } catch { timerPromptError = error.localizedDescription }
    }

    func adjustTimer(minutes: Int) {
        performTimeToolAction { try workspace?.adjustTimer(minutes: minutes) }
    }

    private func updateTimer() {
        do { try workspace?.updateTimer() }
        catch { actionError = error.localizedDescription }
    }

    func changePomodoroParameters(_ parameters: PomodoroParameters?) {
        guard let task = selectedTask else { return }
        do {
            try workspace?.setPomodoroParameters(taskID: task.id, parameters: parameters)
            detailPomodoroParameters = parameters
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    func startPomodoro(_ task: TaskRecord? = nil) {
        performTimeToolAction { try workspace?.startPomodoro(occurrenceID: task?.occurrenceID) }
    }

    func startRest() {
        performTimeToolAction { try workspace?.startRest() }
    }

    func backToWork() {
        performTimeToolAction { try workspace?.backToWork() }
    }

    func startStopwatch(_ task: TaskRecord? = nil) {
        performTimeToolAction { try workspace?.startStopwatch(occurrenceID: task?.occurrenceID) }
    }

    func toggleSessionPause() {
        performTimeToolAction {
            if workspace?.activeSession?.isPaused == true { try workspace?.resumeSession() }
            else { try workspace?.pauseSession() }
        }
    }

    func stopSession() {
        performTimeToolAction { try workspace?.stopSession() }
    }

    func retrySessionSave() {
        performTimeToolAction { try workspace?.retrySessionSave() }
    }

    private func performTimeToolAction(_ action: () throws -> Void) {
        do { try action(); actionError = nil }
        catch { actionError = error.localizedDescription }
    }

    func prepareToTerminate() -> Bool {
        while true {
            let draftSaved = saveDraft()
            let detailsSaved = saveDetails()
            let navigationSaved = saveNavigation()
            var sessionSaved = true
            do { try workspace?.pauseSession() }
            catch { actionError = error.localizedDescription; sessionSaved = false }
            if draftSaved && detailsSaved && navigationSaved && sessionSaved { return true }
            // No editable input exists when opening the database itself failed.
            if workspace == nil { return true }
            let alert = NSAlert()
            alert.messageText = "Есть несохранённые изменения"
            alert.informativeText = "Не удалось сохранить изменения или текущую сессию на Mac. Можно повторить запись, вернуться в приложение или явно выйти без несохранённых изменений. Ранее сохранённые данные останутся."
            alert.addButton(withTitle: "Повторить сохранение")
            alert.addButton(withTitle: "Отмена")
            alert.addButton(withTitle: "Выйти без сохранения")
            NSApp.activate()
            switch alert.runModal() {
            case .alertFirstButtonReturn: continue
            case .alertThirdButtonReturn: return true
            default: return false
            }
        }
    }
}
