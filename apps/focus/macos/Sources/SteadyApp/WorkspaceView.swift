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
                if editor.sidebarVisible {
                    sidebar
                    Divider()
                }
                if editor.screen == .report {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            Text("Отчёт").font(.system(size: 24, weight: .semibold))
                            RunHistory(results: editor.workspace?.timeToolResults ?? [])
                        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    taskList
                }
                if editor.workspace != nil, editor.screen == .tasks {
                    if editor.isCreating {
                        Divider()
                        CreationPanel(editor: editor)
                            .frame(width: 300)
                            .background(Palette.sidebar)
                    } else if editor.detailsVisible, let task = editor.selectedTask {
                        Divider()
                        DetailPanel(editor: editor, task: task)
                            .id(task.occurrenceID)
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
        .sheet(isPresented: $editor.timerPromptVisible) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Длительность таймера").font(.headline)
                Text(editor.timerPromptTask?.title ?? "Без задачи")
                TextField("Минуты", text: $editor.timerMinutes)
                    .accessibilityIdentifier("timer-duration-minutes")
                    .onSubmit { editor.confirmTimer() }
                if let error = editor.timerPromptError { StorageNotice(message: error) }
                HStack {
                    Button("Отмена") { editor.timerPromptVisible = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Запустить") { editor.confirmTimer() }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 340)
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
            Button { editor.sidebarVisible.toggle() } label: {
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
                    .background(editor.screen == .tasks && editor.selectedProjectID == nil && editor.context.labelIDs.isEmpty ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            Button(action: editor.openReport) {
                Label("Отчёт", systemImage: "chart.bar")
                    .font(.system(size: 13, weight: .medium))
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(editor.screen == .report ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).accessibilityIdentifier("report-navigation")
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
                            .background(editor.screen == .tasks && editor.selectedProjectID == project.id ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
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
                            .background(editor.screen == .tasks && editor.context.labelIDs.contains(label.id) ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
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
        let result = editor.listResult
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(editor.contextTitle)
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
            HStack(spacing: 8) {
                ForEach([TaskPeriod.all, .today, .tomorrow], id: \.self) { period in
                    periodButton(period)
                }
                MorePeriods(selected: editor.period, select: editor.selectPeriod)
                periodButton(.completed)
            }
            HStack(spacing: 12) {
                Menu {
                    ForEach(editor.workspace?.labels ?? []) { label in
                        Toggle(label.title, isOn: Binding(get: { editor.context.labelIDs.contains(label.id) }, set: { _ in editor.selectLabel(label.id) }))
                    }
                    Divider()
                    Picker("Условие", selection: $editor.context.labelMatch) {
                        Text("Любая из выбранных").tag(LabelMatch.any)
                        Text("Все выбранные").tag(LabelMatch.all)
                    }
                    if !editor.context.labelIDs.isEmpty {
                        Button("Сбросить метки") { editor.context.labelIDs = [] }
                    }
                } label: {
                    Label(editor.context.labelIDs.isEmpty ? "Метки · любая" : "Метки: \(editor.context.labelIDs.count) · \(editor.context.labelMatch == .any ? "любая" : "все")", systemImage: "tag")
                }
                .accessibilityIdentifier("task-label-filter")
                if editor.period != .completed {
                    Toggle("Показать выполненные", isOn: $editor.context.showCompleted)
                        .toggleStyle(.checkbox).font(.system(size: 11))
                }
                if editor.selectedProjectID != nil || !editor.context.labelIDs.isEmpty {
                    Button("Сбросить фильтры") { editor.selectProject(nil) }
                        .buttonStyle(.plain).font(.system(size: 11))
                }
            }



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
                        if let result {
                            if result.matches.isEmpty {
                                emptyState
                            } else {
                                ForEach(result.groups) { group in
                                    sectionLabel(group.title, count: group.matchCount)
                                    ForEach(group.roots, id: \.occurrenceID) { taskRow($0, result: result) }
                                }
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
            Text(editor.listResult?.emptyReason == .emptyDatabase ? "Задач пока нет" : editor.listResult?.emptyReason == .noMatches ? "Нет совпадений с фильтрами" : "Нет задач за этот период")
                .font(.system(size: 18, weight: .medium))
            Text(editor.listResult?.emptyReason == .noMatches ? "Измените проект или выбранные метки." : editor.listResult?.emptyReason == .emptyPeriod ? "Выберите другой период или добавьте задачу." : "Добавьте дело, которым хотите заняться.")
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

    private func periodButton(_ period: TaskPeriod) -> some View {
        Button { editor.selectPeriod(period) } label: {
            Text(period.label).font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(editor.period == period ? Palette.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(editor.period == period ? .isSelected : [])
    }

    private func taskRow(_ task: TaskRecord, result: TaskListResult) -> some View {
        let children = result.children(of: task.occurrenceID)
        let isContext = result.contextParentIDs.contains(task.occurrenceID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !children.isEmpty && !isContext {
                    Button {
                        if !editor.expandedParents.insert(task.occurrenceID).inserted { editor.expandedParents.remove(task.occurrenceID) }
                    } label: {
                        Label("\(children.count)", systemImage: editor.expandedParents.contains(task.occurrenceID) ? "chevron.down" : "chevron.right")
                    }.buttonStyle(.plain).accessibilityLabel("Подзадачи: \(children.count)")
                }
                if isContext {
                    Button { editor.selectTask(task) } label: {
                        HStack {
                            Image(systemName: task.completedAt == nil ? "list.bullet.indent" : "checkmark.circle.fill")
                            Text(task.title)
                            Text("Контекст").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).padding(.vertical, 8)
                } else {
                    plainTaskRow(task)
                }
            }
            if task.completedAt != nil && children.contains(where: { $0.completedAt == nil }) {
                Text("Родитель выполнен · \(children.filter { $0.completedAt == nil }.count) подзадач открыто")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if editor.expandedParents.contains(task.occurrenceID) || isContext {
                ForEach(children, id: \.occurrenceID) { child in plainTaskRow(child).padding(.leading, 28) }
            }
        }
    }

    private func plainTaskRow(_ task: TaskRecord) -> some View {
        HStack(spacing: 14) {
            Button { editor.setCompleted(task) } label: {
                Image(systemName: task.skippedAt != nil ? "forward.end.circle" : (task.completedAt == nil ? "circle" : "checkmark.circle.fill"))
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
            .accessibilityIdentifier("select-\(task.occurrenceID)")

            Text(occurrenceDayLabel(task, today: editor.workspace?.today, tomorrow: editor.workspace?.tomorrow))
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

    /// SwiftUI can retain a child binding after the draft is consumed or a sibling is removed.
    /// Resolve identity on each access so the old view cannot index a changed array.
    private func childBinding<Value>(_ child: SubtaskDraft, _ keyPath: WritableKeyPath<SubtaskDraft, Value>, replacingLabels: Bool = false) -> Binding<Value> {
        Binding(
            get: { (editor.draftChildren.first { $0.id == child.id } ?? child)[keyPath: keyPath] },
            set: { value in
                guard let index = editor.draftChildren.firstIndex(where: { $0.id == child.id }) else { return }
                editor.draftChildren[index][keyPath: keyPath] = value
                if replacingLabels { editor.draftChildLabelsNeedReplacement.insert(child.id) }
                editor.saveDraft()
            }
        )
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
            RecurrenceField(selection: Binding(get: { editor.draftRecurrence }, set: { editor.changeDraftRecurrence($0) }))
            if editor.draftRecurrence != nil {
                ScheduleField(day: Binding(get: { editor.draftSeriesStart ?? editor.workspace?.today }, set: {
                    editor.draftSeriesStart = $0 ?? editor.workspace?.today; editor.saveDraft()
                }), today: editor.workspace?.today, tomorrow: editor.workspace?.tomorrow, title: "Начало серии", allowsUndated: false)
            } else {
            ScheduleField(day: Binding(get: { editor.draftDay }, set: {
                editor.draftDay = $0; editor.draftDayWasChosen = true; editor.saveDraft()
            }), today: editor.workspace?.today, tomorrow: editor.workspace?.tomorrow)
            }
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
            VStack(alignment: .leading, spacing: 12) {
                Text("Подзадачи").font(.headline)
                ForEach(editor.draftChildren) { child in
                    DisclosureGroup(child.title.isEmpty ? "Новая подзадача" : child.title) {
                        TextField("Название подзадачи", text: childBinding(child, \.title))
                        if let workspace = editor.workspace {
                            LabelField(workspace: workspace, selection: childBinding(child, \.labelIDs, replacingLabels: true))
                        }
                        TaskNoteEditor(note: childBinding(child, \.note), accessibilityID: "child-note-\(child.id)").frame(height: 130)
                        Button("Удалить подзадачу") { editor.draftChildren.removeAll { $0.id == child.id }; editor.saveDraft() }
                    }
                }
                Button("Добавить подзадачу") { editor.draftChildren.append(SubtaskDraft()); editor.saveDraft() }
                Text("Проект и повтор — как у родителя. Метки и заметка — свои.").font(.caption).foregroundStyle(.secondary)
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
            if task.parentTaskID != nil {
                if let parent = editor.workspace?.tasks.first(where: { $0.occurrenceID == task.parentOccurrenceID }) {
                    Button("Родитель: \(parent.title)") { editor.selectTask(parent) }
                }
                Text("Проект и расписание — как у родителя. Для своего расписания создайте отдельную задачу.").font(.caption).foregroundStyle(.secondary)
            } else {
            RecurrenceField(selection: Binding(get: { editor.detailRecurrence }, set: { editor.changeRecurrence($0) }), allowsNoRepeat: task.seriesStart == nil)
            if editor.detailRecurrence != task.recurrence {
                Button("Применить: этот и будущие") { editor.saveRecurrence() }
                    .buttonStyle(.bordered)
            }
            if task.seriesStart != nil {
                Text("Начало серии: \(task.seriesStart ?? ""). Изменение повтора сохраняет выполненные экземпляры, работу и индивидуальные переносы.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let end = task.periodEnd, let start = task.seriesDay {
                    Text("Неделя: \(start) — \(end)").font(.system(size: 11)).foregroundStyle(.secondary)
                    ScheduleField(day: Binding(get: { editor.detailDay }, set: { editor.changeDay($0) }),
                                  today: editor.workspace?.today, tomorrow: editor.workspace?.tomorrow,
                                  allowedDays: start...end)
                    Text("День необязателен; выбрать можно только в пределах этой недели.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(task.skippedAt == nil ? "Пропустить выполнение" : "Вернуть в работу") { editor.toggleSkipped(task) }
                        .buttonStyle(.bordered)
                        .disabled(task.skippedAt == nil && editor.workspace?.activeSession?.occurrenceID == task.occurrenceID)
                    if editor.workspace?.activeSession?.occurrenceID == task.occurrenceID {
                        Text("Сначала нажмите Stop, затем пропустите выполнение.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    Label(dayLabel(task.plannedDay, today: editor.workspace?.today, tomorrow: editor.workspace?.tomorrow), systemImage: "calendar")
                        .font(.system(size: 12))
                }
            } else {
            ScheduleField(day: Binding(get: { editor.detailDay }, set: { editor.changeDay($0) }),
                          today: editor.workspace?.today, tomorrow: editor.workspace?.tomorrow)
            }
            ProjectField(projects: editor.workspace?.projects ?? [], selection: Binding(
                get: { editor.detailProjectID }, set: { editor.changeProject($0) }
            ))
            }
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
            if task.parentTaskID == nil {
                Text("Подзадачи").font(.headline)
                ForEach(editor.workspace?.children(of: task.occurrenceID) ?? [], id: \.occurrenceID) { child in
                    HStack {
                        Button { editor.setCompleted(child) } label: { Image(systemName: child.completedAt == nil ? "circle" : "checkmark.circle.fill") }.buttonStyle(.plain)
                        Button(child.title) { editor.selectTask(child) }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Новая подзадача", text: $editor.newChildTitle).onSubmit(editor.addChild)
                    Button("Добавить", action: editor.addChild)
                }
            }
            ToolMenu(editor: editor, task: task)
            if let error = editor.detailError {
                StorageNotice(message: error)
                Button("Повторить сохранение") { editor.saveDetails() }
                Button("Отменить правки", action: editor.discardDetailEdits)
            }
            Label(occurrenceStatus(task, today: editor.workspace?.today), systemImage: task.skippedAt != nil ? "forward.end.circle" : (task.completedAt == nil ? "circle" : "checkmark.circle"))
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

private func occurrenceDayLabel(_ task: TaskRecord, today: String?, tomorrow: String?) -> String {
    if task.periodEnd != nil, task.plannedDay == nil { return "Любой день недели" }
    return dayLabel(task.plannedDay, today: today, tomorrow: tomorrow)
}

private func occurrenceStatus(_ task: TaskRecord, today: String?) -> String {
    if task.skippedAt != nil { return "Пропущено" }
    if task.completedAt != nil { return "Выполнено" }
    if let end = task.periodEnd, let today, end < today { return "Не выполнено за неделю" }
    return "Не выполнено"
}

private struct RecurrenceField: View {
    @Binding var selection: TaskRecurrence?
    var allowsNoRepeat = true
    private let weekdays = [(2, "Пн"), (3, "Вт"), (4, "Ср"), (5, "Чт"), (6, "Пт"), (7, "Сб"), (1, "Вс")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Повтор", selection: Binding(get: {
                switch selection { case nil: 0; case .daily: 1; case .weekdays: 2; case .selectedWeekdays: 3; case .weekly: 4 }
            }, set: { value in
                switch value {
                case 1: selection = .daily
                case 2: selection = .weekdays
                case 3: selection = .selectedWeekdays([2])
                case 4: selection = .weekly
                default: selection = nil
                }
            })) {
                if allowsNoRepeat { Text("Не повторять").tag(0) }
                Text("Ежедневно").tag(1)
                Text("Будни").tag(2)
                Text("Выбранные дни").tag(3)
                Text("Раз в неделю в любой день").tag(4)
            }
            .accessibilityIdentifier("task-recurrence")
            if case .selectedWeekdays(let selected) = selection {
                HStack(spacing: 4) {
                    ForEach(weekdays, id: \.0) { day, label in
                        Button(label) {
                            var days = selected
                            if days.contains(day) { days.remove(day) } else { days.insert(day) }
                            selection = .selectedWeekdays(days)
                        }
                        .buttonStyle(.bordered)
                        .tint(selected.contains(day) ? .purple : .gray)
                        .accessibilityLabel(label)
                        .accessibilityValue(selected.contains(day) ? "Выбран" : "Не выбран")
                    }
                }
            }
        }
        .font(.system(size: 12))
    }
}

private struct ScheduleField: View {
    @Binding var day: String?
    let today: String?
    let tomorrow: String?
    var title = "Расписание"
    var allowsUndated = true
    var allowedDays: ClosedRange<String>? = nil
    @State private var choosingDate = false

    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func allows(_ day: String?) -> Bool {
        guard let allowedDays else { return true }
        return day.map(allowedDays.contains) ?? false
    }

    private var dateRange: ClosedRange<Date> {
        guard let allowedDays, let first = formatter.date(from: allowedDays.lowerBound), let last = formatter.date(from: allowedDays.upperBound) else { return .distantPast ... .distantFuture }
        return first...last
    }

    var body: some View {
        HStack {
            Label(title, systemImage: "calendar").foregroundStyle(.secondary)
            Spacer()
            Menu(dayLabel(day, today: today, tomorrow: tomorrow)) {
                Button("Сегодня") { day = today }.disabled(!allows(today))
                Button("Завтра") { day = tomorrow }.disabled(!allows(tomorrow))
                Button("Выбрать день…") {
                    if day == nil { day = allowedDays?.lowerBound ?? today }
                    choosingDate = true
                }
                Divider()
                if allowsUndated { Button("Без даты") { day = nil } }
            }
            .accessibilityIdentifier("task-schedule")
            .popover(isPresented: $choosingDate) {
                VStack(alignment: .leading, spacing: 16) {
                    DatePicker("День", selection: Binding(
                        get: { day.flatMap { formatter.date(from: $0) } ?? Date() },
                        set: { day = formatter.string(from: $0) }
                    ), in: dateRange, displayedComponents: .date)
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

    private var timerTitle: String {
        guard let task else { return "Таймер · Не задано" }
        do {
            guard let duration = try editor.workspace?.timerDurationSeconds(taskID: task.id) else {
                return "Таймер · Не задано"
            }
            return "Таймер · " + durationLabel(duration)
        } catch { return "Таймер · Недоступно" }
    }

    var body: some View {
        Menu {
            Button(timerTitle) { editor.requestTimer(task) }
                .disabled(editor.workspace?.activeSession != nil || task?.completedAt != nil || task?.skippedAt != nil)
            Button("Помодоро · 25 / 5 / 15 · после 4") { editor.startPomodoro(task) }
                .disabled(editor.workspace?.activeSession != nil || task?.completedAt != nil || task?.skippedAt != nil)
            Button("Секундомер · Счёт вверх") { editor.startStopwatch(task) }
                .disabled(editor.workspace?.activeSession != nil || task?.completedAt != nil || task?.skippedAt != nil)
            if editor.workspace?.activeSession != nil {
                Divider()
                Text("Сначала остановите текущую сессию (в том числе на паузе)")
                if editor.activeSessionOwner != nil {
                    Button("К текущей задаче", action: editor.showActiveSessionOwner)
                }
            } else if task?.completedAt != nil || task?.skippedAt != nil {
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
    @State private var incrementVisible = false
    @State private var increment = 5

    private var canAdjust: Bool {
        session.kind == .timer || session.pomodoro?.stage == .work
    }

    private var sessionStatus: String {
        guard let state = session.pomodoro else {
            return (session.kind == .timer ? "Таймер" : "Секундомер") + (session.isPaused ? " · Пауза" : " · Работа")
        }
        let stage: String
        switch state.stage {
        case .work: stage = "Работа"
        case .rest: stage = state.restIsLong ? "Длинный отдых" : "Отдых"
        case .waitingBreak: stage = "Ожидание отдыха"
        case .waitingNext: stage = state.focusFinished ? "Ожидание фокуса" : "Ожидание возврата к работе"
        }
        return "Помодоро · " + stage + (session.isPaused ? " · Пауза" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Image(systemName: session.kind == .stopwatch ? "stopwatch" : "timer").foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sessionStatus)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(session.ownerTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let elapsed = durationLabel(session.pomodoro?.stage == .rest ? (editor.workspace?.restRemainingSeconds ?? 0) : session.kind != .stopwatch ? (editor.workspace?.remainingSeconds ?? 0) : (editor.workspace?.elapsedSeconds ?? 0))
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(elapsed)
                            .font(.system(size: 24, weight: .medium, design: .monospaced))
                            .accessibilityLabel(session.kind != .stopwatch ? "Осталось времени" : "Прошло активного времени")
                            .accessibilityValue(elapsed)
                            .accessibilityIdentifier("session-elapsed")
                            .onHover { if $0 && canAdjust { incrementVisible = true } }
                        if session.kind != .stopwatch {
                            Text("Факт: " + durationLabel(editor.workspace?.elapsedSeconds ?? 0))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            if let state = session.pomodoro, !state.focusFinished, state.stage != .work {
                                Text("Остаток фокуса: " + durationLabel(editor.workspace?.remainingSeconds ?? 0))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if canAdjust {
                    Button { incrementVisible.toggle() } label: { Image(systemName: "plusminus") }
                        .accessibilityLabel("Изменить оставшееся время")
                        .accessibilityIdentifier("timer-increment")
                        .onHover { if $0 { incrementVisible = true } }
                        .popover(isPresented: $incrementVisible) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Изменить остаток").font(.headline)
                                Stepper("\(increment > 0 ? "+" : "")\(increment) мин", value: $increment, in: -20...20)
                                    .accessibilityIdentifier("timer-increment-minutes")
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    let preview = try? editor.workspace?.previewTimerIncrement(minutes: increment)
                                    Text(preview.map { "Будет: " + durationLabel($0) } ?? "Длительность слишком велика")
                                        .monospacedDigit().accessibilityIdentifier("timer-increment-preview")
                                }
                                Button("Применить") { editor.adjustTimer(minutes: increment) }
                                    .accessibilityIdentifier("timer-increment-apply")
                                    .disabled((try? editor.workspace?.previewTimerIncrement(minutes: increment)) == nil)
                            }.padding(18).frame(width: 260)
                        }
                }
                if editor.activeSessionOwner != nil {
                    Button("К текущей задаче", action: editor.showActiveSessionOwner)
                        .accessibilityIdentifier("session-owner")
                }
                if session.pomodoro?.stage == .work || session.pomodoro?.stage == .rest || session.pomodoro == nil {
                    Button(session.isPaused ? "Продолжить" : "Пауза", action: editor.toggleSessionPause)
                        .accessibilityIdentifier("session-pause")
                }
                if let state = session.pomodoro {
                    if state.stage == .work || state.stage == .waitingBreak {
                        Button(state.stage == .work ? "Ранний отдых" : "Начать отдых", action: editor.startRest)
                            .accessibilityIdentifier("session-rest")
                    }
                    if state.stage != .work {
                        Button(state.focusFinished ? (state.stage == .waitingNext ? "Следующий фокус" : "Пропустить отдых") : "К работе", action: editor.backToWork)
                            .accessibilityIdentifier("session-work")
                    }
                }
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
                        Label(result.kind == .pomodoro ? "Помодоро" : result.kind == .timer ? "Таймер" : "Секундомер", systemImage: result.kind == .stopwatch ? "stopwatch" : "timer")
                        Spacer()
                        Text(durationLabel(result.durationSeconds)).monospacedDigit()
                    }
                    if result.kind == .timer {
                        Text(result.endReason == .natural ? "Время вышло" : result.endReason == .manual ? "Остаток уменьшен до нуля" : "Остановлен вручную")
                            .foregroundStyle(.secondary)
                    }
                    if let state = result.pomodoro {
                        Text("Полных помодоро: \(state.fullPomodoros) · 25 / 5 / 15 · после 4")
                            .foregroundStyle(.secondary)
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
    guard seconds.isFinite, let value = Int(exactly: max(0, seconds).rounded(.towardZero)) else { return "—" }
    let hours = String(value / 3600)
    return (hours.count < 2 ? "0" + hours : hours) + String(format: ":%02d:%02d", (value % 3600) / 60, value % 60)
}

private func historyDate(_ date: Date, zone: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.timeZone = TimeZone(identifier: zone)
    formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
    return formatter.string(from: date)
}

private struct MorePeriods: View {
    let selected: TaskPeriod
    let select: (TaskPeriod) -> Void
    @State private var expanded = false
    @FocusState private var focused: TaskPeriod?

    var body: some View {
        Button { expanded.toggle() } label: {
            Text(selected == .week || selected == .month ? "Ещё · " + selected.label : "Ещё")
                .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7)
                .background(selected == .week || selected == .month ? Palette.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("more-periods")
        .accessibilityAddTraits(selected == .week || selected == .month ? .isSelected : [])
        .onKeyPress(.downArrow) { expanded = true; return .handled }
        .onHover { inside in if inside { expanded = true } }
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach([TaskPeriod.week, .month], id: \.self) { period in
                    Button {
                        select(period)
                        expanded = false
                    } label: {
                        HStack {
                            Text(period.label)
                            Spacer()
                            if selected == period { Image(systemName: "checkmark") }
                        }.frame(width: 170, alignment: .leading)
                    }
                    .focused($focused, equals: period)
                }
            }
            .padding(12)
            .onAppear { focused = selected == .month ? .month : .week }
            .onKeyPress(.downArrow) { focused = .month; return .handled }
            .onKeyPress(.upArrow) { focused = .week; return .handled }
            .onKeyPress(.return) {
                select(focused ?? .week)
                expanded = false
                return .handled
            }
            .onKeyPress(.escape) { expanded = false; return .handled }
        }
    }
}
