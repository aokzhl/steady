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
    @State private var projectEditorVisible = false
    @State private var labelEditorVisible = false
    @State private var editingLabel: LabelRecord?
    @State private var editingProject: ProjectRecord?
    @State private var historyVisible = false
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
            if let workspace = editor.workspace, let session = workspace.activeSession {
                Divider()
                SessionBar(editor: editor, session: session)
            }
        }
        .frame(minWidth: 850, minHeight: 560)
        .background(Palette.background)
        .tint(Palette.accent)
        .sheet(isPresented: $projectEditorVisible) {
            ProjectEditorPanel(workspace: editor.workspace, project: editingProject)
        }
        .sheet(isPresented: $labelEditorVisible) {
            LabelEditorPanel(workspace: editor.workspace, label: editingLabel)
        }
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
            if editor.workspace != nil {
                ToolMenu(editor: editor, task: nil)
                Button { historyVisible.toggle() } label: {
                    Label("История", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $historyVisible) {
                    ScrollView {
                        RunHistory(results: editor.workspace?.timeToolResults ?? [])
                            .padding(20)
                    }
                    .frame(width: 360, height: 400)
                }
            }
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
            Button { editor.selectProject(nil) } label: {
                Label("Все задачи", systemImage: "list.bullet")
                    .font(.system(size: 13, weight: .medium))
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(editor.selectedProjectID == nil && editor.selectedLabelID == nil ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            HStack {
                Text("Проекты").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { editingProject = nil; projectEditorVisible = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).accessibilityLabel("Создать проект")
                    .disabled(editor.workspace == nil)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(editor.workspace?.projects ?? []) { project in
                        Button { editor.selectProject(project.id) } label: {
                            HStack {
                                ProjectMarker(color: project.color)
                                Text(project.title).lineLimit(2)
                                Spacer()
                                Text("\(editor.workspace?.openTaskCount(in: project.id) ?? 0)")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12)).padding(10)
                            .background(editor.selectedProjectID == project.id ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Переименовать проект") { editingProject = project; projectEditorVisible = true }
                        }
                    }
                    Divider().padding(.vertical, 10)
                    HStack {
                        Text("Метки").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button { editingLabel = nil; labelEditorVisible = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).accessibilityLabel("Создать метку")
                            .disabled(editor.workspace == nil)
                    }
                    .padding(.bottom, 8)
                    ForEach(editor.workspace?.labels ?? []) { label in
                        Button { editor.selectLabel(label.id) } label: {
                            HStack {
                                ProjectMarker(color: label.color)
                                Text(label.title).lineLimit(2)
                                Spacer()
                            }
                            .font(.system(size: 12)).padding(10)
                            .background(editor.selectedLabelID == label.id ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Переименовать метку") { editingLabel = label; labelEditorVisible = true }
                            Button("Удалить метку", role: .destructive) { editor.deleteLabel(label) }
                        }
                    }
                }
            }
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
                Text(editor.workspace?.labels.first { $0.id == editor.selectedLabelID }?.title ?? editor.workspace?.projects.first { $0.id == editor.selectedProjectID }?.title ?? "Все задачи")
                    .font(.system(size: 24, weight: .semibold))
                if let project = editor.workspace?.projects.first(where: { $0.id == editor.selectedProjectID }) {
                    Button { editingProject = project; projectEditorVisible = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).accessibilityLabel("Переименовать проект")
                }
                if let label = editor.workspace?.labels.first(where: { $0.id == editor.selectedLabelID }) {
                    Button { editingLabel = label; labelEditorVisible = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).accessibilityLabel("Переименовать метку")
                    Button { editor.deleteLabel(label) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).accessibilityLabel("Удалить метку")
                }
                Spacer()
                Label("Список", systemImage: "list.bullet")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Picker("Период", selection: Binding(get: { editor.period }, set: { editor.selectPeriod($0) })) {
                Text("Все").tag(TaskPeriod.all)
                Text("Сегодня").tag(TaskPeriod.today)
                Text("Завтра").tag(TaskPeriod.tomorrow)
            }
            .pickerStyle(.segmented).frame(maxWidth: 300)


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

                if let removed = workspace.lastDeletedLabel {
                    HStack {
                        Text("Метка «\(removed.title)» удалена").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Отменить удаление", action: editor.undoLabelDeletion)
                            .font(.system(size: 12))
                    }
                }
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
                        let open = workspace.tasks.filter {
                            $0.completedAt == nil && editor.matchesContext($0)
                            && (editor.contextDay == nil || $0.plannedDay == editor.contextDay || (editor.period == .today && $0.plannedDay.map { $0 < workspace.today } == true))
                        }
                        let completed = workspace.tasks.filter {
                            $0.completedAt != nil && editor.matchesContext($0)
                            && (editor.contextDay == nil || (editor.period == .today ? workspace.completedToday.contains($0) : $0.plannedDay == editor.contextDay))
                        }
                        if open.isEmpty, completed.isEmpty {
                            emptyState
                        } else {
                            let overdue = editor.period == .today ? open.filter { $0.plannedDay.map { $0 < workspace.today } == true } : []
                            if !overdue.isEmpty {
                                sectionLabel("Ранее запланировано", count: overdue.count)
                                ForEach(overdue) { taskRow($0) }
                            }
                            let current = open.filter { task in !overdue.contains { $0.id == task.id } }
                            if !current.isEmpty {
                                ForEach(workspace.projects) { project in
                                    let group = current.filter { $0.projectID == project.id }
                                    if !group.isEmpty {
                                        sectionLabel(project.title, count: group.count)
                                        ForEach(group) { taskRow($0) }
                                    }
                                }
                                let unassigned = current.filter { $0.projectID == nil }
                                if !unassigned.isEmpty {
                                    sectionLabel("Без проекта", count: unassigned.count)
                                    ForEach(unassigned) { taskRow($0) }
                                }
                            }
                            if !completed.isEmpty {
                                sectionLabel(editor.period == .today ? "Выполнено сегодня" : "Выполнено", count: completed.count)
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
            Text(editor.workspace?.tasks.isEmpty == true ? "Задач пока нет" : "Нет задач за этот период")
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

            ToolMenu(editor: editor, task: task, compact: true)
            Button { editor.selectTask(task) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title)
                        .font(.system(size: 14))
                        .strikethrough(task.completedAt != nil)
                        .foregroundStyle(task.completedAt == nil ? Color.primary : Color.secondary)
                        .lineLimit(3)
                    if let workspace = editor.workspace, !task.labelIDs.isEmpty {
                        LabelChips(labels: workspace.labels, selection: task.labelIDs)
                    }
                    if task.priority != .none {
                        Label(task.priority.label, systemImage: "flag")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(task.title)
            .accessibilityIdentifier("select-\(task.id)")

            Text(dayLabel(task.plannedDay, today: editor.workspace?.today, tomorrow: editor.workspace?.tomorrow))
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
        ScrollView { panelContent.frame(maxWidth: .infinity) }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            ScheduleField(day: Binding(get: { editor.draftDay }, set: {
                editor.draftDay = $0; editor.draftDayWasChosen = true; editor.saveDraft()
            }), today: editor.workspace?.today, tomorrow: editor.workspace?.tomorrow)
            ProjectField(projects: editor.workspace?.projects ?? [], selection: Binding(
                get: { editor.draftProjectID },
                set: { editor.draftProjectID = $0; editor.draftProjectWasChosen = true; editor.saveDraft() }
            ))
            if let workspace = editor.workspace {
                LabelField(workspace: workspace, selection: Binding(
                    get: { editor.draftLabelIDs },
                    set: { editor.changeDraftLabels($0) }
                ))
            }
            PriorityField(selection: Binding(
                get: { editor.draftPriority },
                set: { editor.draftPriority = $0; editor.saveDraft() }
            ))
            VStack(alignment: .leading, spacing: 8) {
                Text("Заметка").font(.system(size: 12)).foregroundStyle(.secondary)
                TaskNoteEditor(note: Binding(
                    get: { editor.draftNote },
                    set: { editor.draftNote = $0; editor.saveDraft() }
                ), accessibilityID: "creation-note")
                .frame(height: 180)
            }
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
        } message: { Text("Введённые данные и выбранные параметры будут удалены.") }
    }
}

private struct DetailPanel: View {
    @Bindable var editor: WorkspaceEditor
    let task: TaskRecord
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView { panelContent.frame(maxWidth: .infinity) }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            ScheduleField(day: Binding(get: { editor.detailDay }, set: { editor.changeDay($0) }),
                          today: editor.workspace?.today, tomorrow: editor.workspace?.tomorrow)
            ProjectField(projects: editor.workspace?.projects ?? [], selection: Binding(
                get: { editor.detailProjectID }, set: { editor.changeProject($0) }
            ))
            if let workspace = editor.workspace {
                LabelField(workspace: workspace, selection: Binding(
                    get: { editor.detailLabelIDs }, set: { editor.changeLabels($0) }
                ))
            }
            PriorityField(selection: Binding(get: { editor.detailPriority }, set: { editor.changePriority($0) }))
            VStack(alignment: .leading, spacing: 8) {
                Text("Заметка").font(.system(size: 12)).foregroundStyle(.secondary)
                TaskNoteEditor(note: Binding(
                    get: { editor.detailNote },
                    set: { editor.detailNote = $0; editor.saveNote() }
                ), accessibilityID: "detail-note")
                .frame(height: 220)
            }
            ToolMenu(editor: editor, task: task)
            if let error = editor.detailError {
                StorageNotice(message: error)
                Button("Повторить сохранение") { editor.saveDetails() }
                Button("Отменить правки", action: editor.discardDetailEdits)
            }
            Label(task.completedAt == nil ? "Не выполнено" : "Выполнено", systemImage: task.completedAt == nil ? "circle" : "checkmark.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            RunHistory(results: editor.workspace?.timeToolResults.filter { $0.occurrenceID == task.occurrenceID } ?? [])
            Spacer(minLength: 0)
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

private func dayLabel(_ day: String?, today: String?, tomorrow: String?) -> String {
    guard let day else { return "Без даты" }
    if day == today { return "Сегодня" }
    if day == tomorrow { return "Завтра" }
    return day
}

private struct ScheduleField: View {
    @Binding var day: String?
    let today: String?
    let tomorrow: String?
    @State private var choosingDate = false

    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    var body: some View {
        HStack {
            Label("Расписание", systemImage: "calendar").foregroundStyle(.secondary)
            Spacer()
            Menu(dayLabel(day, today: today, tomorrow: tomorrow)) {
                Button("Сегодня") { day = today }
                Button("Завтра") { day = tomorrow }
                Button("Выбрать день…") {
                    if day == nil { day = today }
                    choosingDate = true
                }
                Divider()
                Button("Без даты") { day = nil }
            }
            .accessibilityIdentifier("task-schedule")
            .popover(isPresented: $choosingDate) {
                VStack(alignment: .leading, spacing: 16) {
                    DatePicker("День", selection: Binding(
                        get: { day.flatMap { formatter.date(from: $0) } ?? Date() },
                        set: { day = formatter.string(from: $0) }
                    ), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    Button("Готово") { choosingDate = false }
                }
                .padding().frame(width: 280)
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

private struct ToolMenu: View {
    @Bindable var editor: WorkspaceEditor
    let task: TaskRecord?
    var compact = false

    var body: some View {
        Menu {
            Button("Таймер · Не задано") {}.disabled(true)
            Button("Помодоро · Не задано") {}.disabled(true)
            Button("Секундомер · Счёт вверх") { editor.startStopwatch(task) }
                .disabled(editor.workspace?.activeSession != nil || task?.completedAt != nil)
            if editor.workspace?.activeSession != nil {
                Divider()
                Text("Сначала остановите текущую сессию (в том числе на паузе)")
                if editor.activeSessionOwner != nil {
                    Button("К текущей задаче", action: editor.showActiveSessionOwner)
                }
            } else if task?.completedAt != nil {
                Text("Верните задачу в невыполненные для нового запуска")
            }
        } label: {
            if compact { Image(systemName: "stopwatch") }
            else { Label(task == nil ? "Без задачи" : "Инструменты", systemImage: "stopwatch") }
        }
        .accessibilityLabel(task.map { "Инструменты: " + $0.title } ?? "Инструменты без задачи")
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Выбрать инструмент времени" + (task == nil ? " без задачи" : ""))
        .accessibilityIdentifier(task.map { "task-tools-\($0.id)" } ?? "free-tools")
    }
}

private struct SessionBar: View {
    @Bindable var editor: WorkspaceEditor
    let session: TimeToolSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Image(systemName: "stopwatch").foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Секундомер" + (session.isPaused ? " · Пауза" : " · Работа"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(session.ownerTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let elapsed = durationLabel(editor.workspace?.elapsedSeconds ?? 0)
                    Text(elapsed)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .accessibilityLabel("Прошло активного времени")
                        .accessibilityValue(elapsed)
                        .accessibilityIdentifier("session-elapsed")
                }
                if editor.activeSessionOwner != nil {
                    Button("К текущей задаче", action: editor.showActiveSessionOwner)
                        .accessibilityIdentifier("session-owner")
                }
                Button(session.isPaused ? "Продолжить" : "Пауза", action: editor.toggleSessionPause)
                    .accessibilityIdentifier("session-pause")
                Button("Стоп", action: editor.stopSession)
                    .accessibilityIdentifier("session-stop")
            }
            if editor.workspace?.sessionNeedsSave == true {
                Text("Сессия на паузе: не удалось сохранить работу на Mac.")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                Button("Повторить сохранение", action: editor.retrySessionSave)
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .background(Palette.surface)
    }
}

private struct RunHistory: View {
    let results: [TimeToolSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("История запусков").font(.system(size: 13, weight: .semibold))
            if results.isEmpty {
                Text("Сохранённых запусков пока нет")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(results.reversed()) { result in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("Секундомер", systemImage: "stopwatch")
                        Spacer()
                        Text(durationLabel(result.durationSeconds)).monospacedDigit()
                    }
                    Text(result.ownerTitle)
                    Text(historyDate(result.startedAt, zone: result.timeZoneIdentifier) + " — " + historyDate(result.stoppedAt ?? result.startedAt, zone: result.timeZoneIdentifier))
                        .foregroundStyle(.secondary)
                    Text(result.timeZoneIdentifier).foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func durationLabel(_ seconds: TimeInterval) -> String {
    let value = Int(max(0, seconds))
    return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
}

private func historyDate(_ date: Date, zone: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.timeZone = TimeZone(identifier: zone)
    formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
    return formatter.string(from: date)
}
