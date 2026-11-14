import Foundation
import SteadyCore
import SwiftUI

private enum Palette {
    static let background = Color(red: 0.085, green: 0.085, blue: 0.10)
    static let sidebar = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let surface = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let accent = Color(red: 0.76, green: 0.71, blue: 0.96)
}

struct WorkspaceView: View {
    @Bindable var editor: WorkspaceEditor
    @State private var sidebarVisible = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebar
                    Divider()
                }
                taskList
                if editor.workspace != nil {
                    if editor.isCreating {
                        Divider()
                        CreationPanel(editor: editor)
                            .frame(width: 300)
                            .background(Palette.sidebar)
                    } else if editor.detailsVisible, let task = editor.selectedTask {
                        Divider()
                        DetailPanel(editor: editor, task: task)
                            .id(task.id)
                            .frame(width: 300)
                            .background(Palette.sidebar)
                    }
                }
            }
        }
        .frame(minWidth: 850, minHeight: 560)
        .background(Palette.background)
        .tint(Palette.accent)
        .task { editor.openWorkspace() }
        .onAppear { editor.reopenWindow = { openWindow(id: "main") } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { editor.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in editor.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in editor.reload() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { sidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .help("Показать или скрыть боковую панель")
            .accessibilityLabel("Боковая панель")
            Text("Steady").font(.system(size: 14, weight: .semibold))
            Spacer()
            Label("Гость · локально", systemImage: "person.crop.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 80)
        .padding(.trailing, 22)
        .frame(height: 48)
        .background(Palette.sidebar)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Все задачи", systemImage: "list.bullet")
                .font(.system(size: 13, weight: .medium))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Palette.accent)
            Spacer()
            Label("Данные на этом Mac", systemImage: "internaldrive")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .padding(.top, 12)
        .frame(width: 184)
        .background(Palette.sidebar)
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Все задачи").font(.system(size: 24, weight: .semibold))
                Spacer()
                Label("Список", systemImage: "list.bullet")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Label("Сегодня", systemImage: "calendar")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Palette.accent)

            if let openingError = editor.openingError {
                StorageNotice(message: openingError)
                Button("Повторить открытие") { editor.openWorkspace() }
            } else if let workspace = editor.workspace {
                Button(action: editor.openCreation) {
                    Label("Добавить задачу", systemImage: "plus")
                }
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("new-task")

                if let actionError = editor.actionError {
                    StorageNotice(message: actionError)
                    Button("Обновить список", action: editor.reload)
                }
                if let draftError = editor.draftError, !editor.isCreating {
                    StorageNotice(message: "Черновик не сохранён. " + draftError)
                    Button("Вернуться к черновику", action: editor.openCreation)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        let open = workspace.openToday
                        let completed = workspace.completedToday
                        if open.isEmpty, completed.isEmpty {
                            emptyState
                        } else {
                            if !open.isEmpty {
                                sectionLabel("Без проекта", count: open.count)
                                ForEach(open) { taskRow($0) }
                            }
                            if !completed.isEmpty {
                                sectionLabel("Выполнено сегодня", count: completed.count)
                                    .padding(.top, 16)
                                ForEach(completed) { taskRow($0) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 20)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.accent)
            Text(editor.workspace?.tasks.isEmpty == true ? "Задач пока нет" : "На сегодня всё")
                .font(.system(size: 18, weight: .medium))
            Text("Добавьте дело, которым хотите заняться.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Создать задачу", action: editor.openCreation)
                .buttonStyle(.borderedProminent).padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Text("\(count)").foregroundStyle(.tertiary)
        }
        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 5)
    }

    private func taskRow(_ task: TaskRecord) -> some View {
        HStack(spacing: 14) {
            Button { editor.setCompleted(task) } label: {
                Image(systemName: task.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(task.completedAt == nil ? Color.secondary : Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(task.completedAt == nil ? "Выполнить" : "Отменить выполнение"): \(task.title)")
            .accessibilityIdentifier("complete-\(task.occurrenceID)")

            Button { editor.selectTask(task) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title)
                        .font(.system(size: 14))
                        .strikethrough(task.completedAt != nil)
                        .foregroundStyle(task.completedAt == nil ? Color.primary : Color.secondary)
                        .lineLimit(3)
                    if task.priority != .none {
                        Label(task.priority.label, systemImage: "flag")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(task.title)
            .accessibilityIdentifier("select-\(task.id)")

            Text(task.plannedDay == editor.workspace?.today ? "Сегодня" : task.plannedDay)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(editor.selectedID == task.occurrenceID ? Palette.accent.opacity(0.6) : .clear, lineWidth: 1)
        }
    }
}

private struct CreationPanel: View {
    @Bindable var editor: WorkspaceEditor
    @FocusState private var titleFocused: Bool
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Новая задача").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: editor.closeCreation) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Закрыть создание")
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Название").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Что нужно сделать?", text: Binding(
                    get: { editor.draftTitle },
                    set: { editor.draftTitle = $0; editor.saveDraft() }
                ), axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 19, weight: .medium))
                    .lineLimit(1...5).focused($titleFocused)
                    .onSubmit(editor.createTask)
                    .accessibilityLabel("Название задачи").accessibilityIdentifier("task-title")
            }
            Divider()
            TaskProperties(day: "Сегодня")
            PriorityField(selection: Binding(
                get: { editor.draftPriority },
                set: { editor.draftPriority = $0; editor.saveDraft() }
            ))
            if let error = editor.draftError {
                StorageNotice(message: error)
                Button("Повторить сохранение черновика") { editor.saveDraft() }
            } else {
                Text("Черновик сохраняется на этом Mac")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Divider()
            HStack {
                Button { confirmingDiscard = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).accessibilityLabel("Удалить черновик")
                Button("Закрыть", action: editor.closeCreation).buttonStyle(.plain)
                Spacer()
                Button(editor.draftError == nil ? "Создать" : "Повторить создание", action: editor.createTask)
                    .buttonStyle(.borderedProminent)
                    .disabled(editor.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-task")
            }
        }
        .padding(22)
        .defaultFocus($titleFocused, true)
        .task { await Task.yield(); titleFocused = true }
        .alert("Удалить черновик?", isPresented: $confirmingDiscard) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive, action: editor.discardDraft)
        } message: { Text("Введённое название и выбранный приоритет будут удалены.") }
    }
}

private struct DetailPanel: View {
    @Bindable var editor: WorkspaceEditor
    let task: TaskRecord
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Детали задачи").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: editor.closeDetails) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Закрыть детали")
            }
            Divider()
            TextField("Название задачи", text: $editor.detailTitle, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 19, weight: .medium))
                .lineLimit(1...5).focused($titleFocused)
                .onSubmit { if editor.saveTitle() { titleFocused = false } }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { editor.saveTitle() }
                }
                .onExitCommand { editor.cancelTitleEdit(); titleFocused = false }
                .accessibilityLabel("Изменить название").accessibilityIdentifier("detail-title")
            TaskProperties(day: task.plannedDay == editor.workspace?.today ? "Сегодня" : task.plannedDay)
            PriorityField(selection: Binding(get: { editor.detailPriority }, set: { editor.changePriority($0) }))
            if let error = editor.detailError {
                StorageNotice(message: error)
                Button("Повторить сохранение") { editor.saveDetails() }
                Button("Отменить правки", action: editor.discardDetailEdits)
            }
            Label(task.completedAt == nil ? "Не выполнено" : "Выполнено", systemImage: task.completedAt == nil ? "circle" : "checkmark.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(22)
        .onExitCommand { editor.closeDetails() }
    }
}

private struct PriorityField: View {
    @Binding var selection: TaskPriority

    var body: some View {
        Picker("Приоритет", selection: $selection) {
            ForEach(TaskPriority.allCases, id: \.self) { priority in
                Text(priority.label).tag(priority)
            }
        }
        .pickerStyle(.menu).font(.system(size: 12))
        .accessibilityIdentifier("task-priority")
    }
}

private struct TaskProperties: View {
    let day: String

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("Расписание", systemImage: "calendar").foregroundStyle(.secondary)
                Spacer()
                Text(day)
            }
            HStack {
                Label("Проект", systemImage: "folder").foregroundStyle(.secondary)
                Spacer()
                Text("Без проекта")
            }
        }
        .font(.system(size: 12))
    }
}

private struct StorageNotice: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-error")
    }
}
