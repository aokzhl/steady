import AppKit
import Observation
import SteadyCore

enum TaskPeriod: Hashable {
    case all, today, tomorrow, week, history
}

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
    var period: TaskPeriod = .today
    var draftDay: String?
    var draftDayWasChosen = false
    var draftRecurrence: TaskRecurrence?
    var draftSeriesStart: String?
    var detailRecurrence: TaskRecurrence?
    private var recurrenceError: String?
    var detailDay: String?

    var contextDay: String? {
        switch period {
        case .all, .week, .history: nil
        case .today: workspace?.today
        case .tomorrow: workspace?.tomorrow
        }
    }
    private var labelsError: String?
    var selectedLabelID: UUID?
    var draftLabelIDs: Set<UUID> = []
    var draftLabelsWereChosen = false
    private var draftLabelsNeedReplacement = false
    var detailLabelIDs: Set<UUID> = []
    var selectedProjectID: UUID?
    var draftProjectID: UUID?
    var draftProjectWasChosen = false
    var detailProjectID: UUID?

    var detailError: String? {
        let messages = [titleError, priorityError, projectError, noteError, dayError, recurrenceError, labelsError].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    var draftNote: TaskNote = .empty
    var detailNote: TaskNote = .empty
    var draftTitle = ""
    var draftPriority: TaskPriority = .none
    var detailTitle = ""
    var detailPriority: TaskPriority = .none
    var isCreating = false
    var detailsVisible = false
    var selectedID: UUID?

    var selectedTask: TaskRecord? {
        workspace?.tasks.first { $0.occurrenceID == selectedID }
    }

    private var draft: CreationDraft { CreationDraft(title: draftTitle, priority: draftPriority, projectID: draftProjectID, projectWasChosen: draftProjectWasChosen, plannedDay: draftDay, dayWasChosen: draftDayWasChosen, note: draftNote, labelIDs: draftLabelIDs, labelsWereChosen: draftLabelsWereChosen, recurrence: draftRecurrence, seriesStart: draftSeriesStart) }

    func openWorkspace() {
        guard workspace == nil else { return }
        do {
            let base = ProcessInfo.processInfo.environment["STEADY_DATA_DIRECTORY"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            let opened = try TaskWorkspace(databaseURL: TaskWorkspace.guestDatabaseURL(in: base))
            workspace = opened
            timerUpdates = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTimer() }
            }
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
        } catch { openingError = error.localizedDescription }
    }

    func reload() {
        do {
            try workspace?.reload()
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    func openCreation() {
        guard saveDetails() else { return }
        guard let workspace, saveDraft() else { isCreating = true; return }
        do {
            let prepared = try workspace.prepareCreationDraft(projectID: selectedProjectID, plannedDay: contextDay, labelIDs: selectedLabelID.map { [$0] } ?? [])
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
    }

    @discardableResult
    func saveDraft() -> Bool {
        guard let workspace else { return false }
        do {
            if draftLabelsNeedReplacement || draft != (workspace.creationDraft ?? CreationDraft()) {
                try workspace.saveCreationDraft(draft, replacingLabels: draftLabelsNeedReplacement)
            }
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
            draftTitle = ""
            draftPriority = .none
            draftNote = .empty
            draftProjectID = nil
            draftProjectWasChosen = false
            draftDay = nil
            draftDayWasChosen = false
            draftLabelIDs = []
            draftLabelsWereChosen = false
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
            draftTitle = ""
            draftPriority = .none
            draftNote = .empty
            draftProjectID = nil
            draftProjectWasChosen = false
            draftDay = nil
            draftDayWasChosen = false
            draftLabelIDs = []
            draftLabelsWereChosen = false
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
        if saveDetails() { detailsVisible = false }
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
        guard saveDetails() else { return }
        if isCreating { closeCreation() }
        selectedProjectID = id
        selectedLabelID = nil
        detailsVisible = false
    }

    func selectLabel(_ id: UUID) {
        guard saveDetails() else { return }
        if isCreating { closeCreation() }
        selectedLabelID = id
        selectedProjectID = nil
        detailsVisible = false
    }

    func matchesContext(_ task: TaskRecord) -> Bool {
        (selectedProjectID == nil || task.projectID == selectedProjectID)
            && (selectedLabelID.map { task.labelIDs.contains($0) } ?? true)
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
            if selectedLabelID == label.id { selectedLabelID = nil }
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
        period = value
        detailsVisible = false
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

    func matchesPeriod(_ task: TaskRecord) -> Bool {
        guard let workspace else { return false }
        switch period {
        case .all: return true
        case .week: return workspace.currentWeekTasks.contains { $0.occurrenceID == task.occurrenceID }
        case .history: return (task.periodEnd ?? task.plannedDay).map { $0 < workspace.today } ?? false
        case .tomorrow: return task.plannedDay == workspace.tomorrow
        case .today:
            if task.completedAt != nil { return workspace.completedToday.contains { $0.occurrenceID == task.occurrenceID } }
            if task.skippedAt != nil, let end = task.periodEnd, let start = task.seriesDay { return start <= workspace.today && workspace.today <= end }
            return workspace.openToday.contains { $0.occurrenceID == task.occurrenceID }
        }
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
        selectedProjectID = saved.projectID
        period = .all
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
        guard let minutes = Double(timerMinutes.replacingOccurrences(of: ",", with: ".")), minutes.isFinite, minutes > 0 else {
            timerPromptError = "Введите длительность больше нуля в минутах."
            return
        }
        guard (minutes * 60).isFinite, minutes * 60 <= TimeToolSession.maximumTimerDurationSeconds else {
            timerPromptError = WorkspaceError.invalidTimerDuration.localizedDescription
            return
        }
        do {
            try workspace?.startTimer(occurrenceID: timerPromptTask?.occurrenceID, durationSeconds: minutes * 60)
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
            var sessionSaved = true
            do { try workspace?.pauseSession() }
            catch { actionError = error.localizedDescription; sessionSaved = false }
            if draftSaved && detailsSaved && sessionSaved { return true }
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
