import AppKit
import Observation
import SteadyCore

/// Window editing state outlives its panels, including unsaved input after a disk error.
@MainActor
@Observable
final class WorkspaceEditor {
    @ObservationIgnored var reopenWindow: (() -> Void)?
    var workspace: TaskWorkspace?
    var openingError: String?
    var actionError: String?
    var draftError: String?
    private var titleError: String?
    private var priorityError: String?
    private var projectError: String?
    var selectedProjectID: UUID?
    var draftProjectID: UUID?
    var detailProjectID: UUID?

    var detailError: String? {
        let messages = [titleError, priorityError, projectError].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
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

    private var draft: CreationDraft { CreationDraft(title: draftTitle, priority: draftPriority, projectID: draftProjectID) }

    func openWorkspace() {
        guard workspace == nil else { return }
        do {
            let base = ProcessInfo.processInfo.environment["STEADY_DATA_DIRECTORY"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            let opened = try TaskWorkspace(databaseURL: TaskWorkspace.guestDatabaseURL(in: base))
            workspace = opened
            draftTitle = opened.creationDraft?.title ?? ""
            draftPriority = opened.creationDraft?.priority ?? .none
            draftProjectID = opened.creationDraft?.projectID
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
        if workspace?.creationDraft == nil && draftTitle.isEmpty && draftPriority == .none && draftProjectID == nil {
            draftProjectID = selectedProjectID
            _ = saveDraft()
        }
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
            if draft != (workspace.creationDraft ?? CreationDraft()) {
                try workspace.saveCreationDraft(draft)
            }
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
            draftProjectID = nil
            draftError = nil
        } catch { draftError = error.localizedDescription }
    }

    func createTask() {
        guard let workspace, saveDraft() else { return }
        do {
            let task = try workspace.createTaskFromDraft()
            draftTitle = ""
            draftPriority = .none
            draftProjectID = nil
            draftError = nil
            isCreating = false
            showDetails(for: task)
        } catch { draftError = error.localizedDescription }
    }

    func selectTask(_ task: TaskRecord) {
        guard saveDetails() else { return }
        if isCreating { closeCreation() }
        let saved = workspace?.tasks.first { $0.id == task.id } ?? task
        showDetails(for: saved)
    }

    private func showDetails(for task: TaskRecord) {
        selectedID = task.occurrenceID
        detailTitle = task.title
        detailPriority = task.priority
        detailProjectID = task.projectID
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
    func saveDetails() -> Bool {
        guard saveTitle() else { return false }
        guard savePriority() else { return false }
        return saveProject()
    }

    func selectProject(_ id: UUID?) {
        guard saveDetails() else { return }
        if isCreating { closeCreation() }
        selectedProjectID = id
        detailsVisible = false
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

    func cancelTitleEdit() {
        detailTitle = selectedTask?.title ?? ""
        titleError = nil
    }

    func discardDetailEdits() {
        detailTitle = selectedTask?.title ?? ""
        detailPriority = selectedTask?.priority ?? .none
        detailProjectID = selectedTask?.projectID
        projectError = nil
        titleError = nil
        priorityError = nil
    }

    func setCompleted(_ task: TaskRecord) {
        do {
            try workspace?.setCompleted(occurrenceID: task.occurrenceID, completed: task.completedAt == nil)
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    func prepareToTerminate() -> Bool {
        while true {
            let draftSaved = saveDraft()
            let detailsSaved = saveDetails()
            if draftSaved && detailsSaved { return true }
            // No editable input exists when opening the database itself failed.
            if workspace == nil { return true }
            let alert = NSAlert()
            alert.messageText = "Есть несохранённые изменения"
            alert.informativeText = "Не удалось сохранить ввод на Mac. Можно повторить запись, вернуться в приложение или явно выйти без несохранённых изменений. Ранее сохранённые данные останутся."
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
