import AppKit
import Foundation
import SteadyCore
import SwiftUI

enum Palette {
    static let background = Color(red: 23/255, green: 23/255, blue: 28/255)
    static let sidebar = Color(red: 27/255, green: 27/255, blue: 33/255)
    static let surface = Color(red: 30/255, green: 30/255, blue: 37/255)
    static let propertyValue = Color(red: 224/255, green: 213/255, blue: 238/255)
    static let accent = Color(red: 199/255, green: 190/255, blue: 252/255)
}

struct WorkspaceView: View {
    @Bindable var editor: WorkspaceEditor
    @FocusState private var searchFocused: Bool
    @State private var projectEditorVisible = false
    @State private var labelEditorVisible = false
    @State private var editingLabel: LabelRecord?
    @State private var editingProject: ProjectRecord?
    @State private var historyVisible = false
    @State private var collapsedGroups: Set<String> = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeometryReader { geometry in
            let isNarrow = geometry.size.width < 1050
            VStack(spacing: 0) {
                header
                Divider()
                HStack(spacing: 0) {
                    if editor.sidebarVisible && !(isNarrow && panelVisible) {
                        sidebar
                        Divider()
                    }
                    if editor.screen == .report {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                Text("Отчёт").font(.system(size: 21, weight: .semibold))
                                RunHistory(results: editor.workspace?.timeToolResults ?? [])
                            }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if !(isNarrow && panelVisible) {
                        taskList
                    }
                    if editor.workspace != nil, editor.screen == .tasks {
                        if editor.isCreating {
                            Divider()
                            CreationPanel(editor: editor, isPage: isNarrow)
                                .frame(width: isNarrow ? nil : 400)
                                .frame(maxWidth: isNarrow ? .infinity : nil)
                                .background(Palette.sidebar)
                        } else if editor.detailsVisible, let task = editor.selectedTask {
                            Divider()
                            VStack(spacing: 0) {
                                if !isNarrow, let day = editor.calendarDay, editor.presentation == .calendar {
                                    Button("Назад к дню · " + day) { editor.closeDetails() }
                                        .buttonStyle(.plain).padding(12)
                                }
                                DetailPanel(editor: editor, task: task, isPage: isNarrow).id(task.occurrenceID)
                            }
                                .frame(width: isNarrow ? nil : 340)
                                .frame(maxWidth: isNarrow ? .infinity : nil)
                                .background(Palette.sidebar)
                        } else if editor.presentation == .calendar, let day = editor.calendarDay {
                            Divider()
                            calendarDayPanel(day, isPage: isNarrow)
                                .frame(width: isNarrow ? nil : 340)
                                .frame(maxWidth: isNarrow ? .infinity : nil)
                                .background(Palette.sidebar)
                        }
                    }
                }
                if let workspace = editor.workspace, let session = workspace.activeSession {
                    Divider()
                    SessionBar(editor: editor, session: session)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 580, minHeight: 500)
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
        .onChange(of: editor.searchFocusRequest) { _, _ in
            Task { @MainActor in
                await Task.yield()
                searchFocused = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { editor.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in editor.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in editor.reload() }
    }

    private var panelVisible: Bool { editor.screen == .tasks && (editor.isCreating || (editor.detailsVisible && editor.selectedTask != nil) || (editor.presentation == .calendar && editor.calendarDay != nil)) }

    private var header: some View {
        HStack(spacing: 14) {
            Button { editor.sidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .help("Показать или скрыть боковую панель")
            .accessibilityLabel("Боковая панель")
            Text("Steady").font(.system(size: 14, weight: .semibold))
            Menu {
                Text("Гость · локально")
                Text("Данные хранятся на этом Mac")
            } label: { Label("Аккаунт", systemImage: "person") }
            .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            if editor.workspace != nil {
                ToolMenu(editor: editor, task: nil, compact: true)
                Button { historyVisible.toggle() } label: {
                    Image(systemName: "clock.arrow.circlepath")
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
            Menu {
                Toggle("Боковая панель", isOn: $editor.sidebarVisible)
                Button("Поиск") { editor.beginSearch() }
                Toggle("Показать выполненные", isOn: $editor.context.showCompleted)
                Button("Сбросить фильтры") { editor.selectProject(nil) }
            } label: { Image(systemName: "gearshape") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Настройки вида")
        }
        .padding(.leading, 94)
        .padding(.trailing, 20)
        .frame(height: 48)
        .background(Palette.sidebar)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if editor.beginSearch() { searchFocused = true }
            } label: {
                Label("Поиск", systemImage: "magnifyingglass")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
            }.buttonStyle(.plain).padding(.bottom, 16)
            .accessibilityIdentifier("task-search-open")
            Button { editor.selectProject(nil) } label: {
                Label("Все задачи", systemImage: "list.bullet")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 9).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(editor.screen == .tasks && editor.selectedProjectID == nil && editor.context.labelIDs.isEmpty ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            Button(action: editor.openReport) {
                Label("Отчёт", systemImage: "chart.bar")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 9).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(editor.screen == .report ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).accessibilityIdentifier("report-navigation")
            HStack {
                Text("Проекты").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { editingProject = nil; projectEditorVisible = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).accessibilityLabel("Создать проект")
                    .disabled(editor.workspace == nil)
            }
            .padding(.horizontal, 9).padding(.top, 20).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(editor.workspace?.projects ?? []) { project in
                        Button { editor.selectProject(project.id) } label: {
                            HStack {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                Text(project.title).lineLimit(2)
                                Spacer()
                                Text("\(editor.workspace?.openTaskCount(in: project.id) ?? 0)")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12)).padding(.horizontal, 9).frame(minHeight: 36)
                            .background(editor.screen == .tasks && editor.selectedProjectID == project.id ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Переименовать проект") { editingProject = project; projectEditorVisible = true }
                        }
                    }
                    Color.clear.frame(height: 24)
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
                                Image(systemName: "tag").foregroundStyle(.secondary)
                                Text(label.title).lineLimit(2)
                                Spacer()
                            }
                            .font(.system(size: 12)).padding(.horizontal, 9).frame(minHeight: 36)
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
            Label("Гость · локально", systemImage: "circle.fill")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(10)
        .padding(.top, 2)
        .frame(width: 192)
        .background(Palette.sidebar)
    }

    private var taskList: some View {
        let result = editor.listResult
        return VStack(alignment: .leading, spacing: 10) {
            if editor.isSearching {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Название или заметка", text: $editor.searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .focused($searchFocused)
                            .onExitCommand { editor.searchEscape() }
                            .accessibilityIdentifier("task-search-query")
                        Button("Назад") { editor.endSearch() }
                            .accessibilityIdentifier("task-search-back")
                    }
                    HStack {
                        Text(editor.searchAllTasks ? "Поиск во всех задачах" : "Поиск в текущем контексте")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        if !editor.searchAllTasks {
                            Button("Искать во всех задачах", action: editor.searchEverywhere)
                                .accessibilityIdentifier("task-search-everywhere")
                        }
                    }
                    Text("Escape: очистить запрос, затем вернуться назад")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(editor.contextTitle)
                    .font(.system(size: editor.isCreating ? 20 : 23, weight: .semibold))
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
                Picker("Вид", selection: $editor.presentation) {
                    Text("Список").tag(TaskPresentation.list)
                    Text("Календарь").tag(TaskPresentation.calendar)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                    .accessibilityLabel("Вид")
                    .accessibilityIdentifier("task-presentation")
            }
            HStack(spacing: 2) {
                ForEach([TaskPeriod.all, .today, .tomorrow], id: \.self) { period in
                    periodButton(period)
                }
                MorePeriods(selected: editor.period, namedMonth: editor.context.namedMonth, select: editor.selectPeriod)
                periodButton(.completed)
                Spacer(minLength: 4)
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
                    Label(editor.context.labelIDs.isEmpty ? "Метки" : "Метки: \(editor.context.labelIDs.count) · \(editor.context.labelMatch == .any ? "любая" : "все")", systemImage: "tag")
                }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
                .accessibilityIdentifier("task-label-filter")
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
                if editor.presentation == .calendar {
                    MonthCalendar(editor: editor)
                } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let result {
                            if result.matches.isEmpty {
                                emptyState
                            } else {
                                ForEach(displayGroups(result.groups)) { group in
                                    if group.id != "unassigned" {
                                        if group.id == "overdue" || group.id == "weekly-undated" {
                                            sectionLabel(group.title, count: group.matchCount)
                                        } else {
                                            Button {
                                                if !collapsedGroups.insert(group.id).inserted {
                                                    collapsedGroups.remove(group.id)
                                                }
                                            } label: {
                                                HStack(spacing: 8) {
                                                    Image(systemName: collapsedGroups.contains(group.id) ? "chevron.right" : "chevron.down").font(.system(size: 9))
                                                    Image(systemName: "folder").font(.system(size: 12))
                                                    sectionLabel(group.title, count: group.matchCount)
                                                }.frame(maxWidth: .infinity, alignment: .leading)
                                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                                        }
                                    }
                                    if !collapsedGroups.contains(group.id) {
                                        ForEach(group.roots, id: \.occurrenceID) { taskRow($0, result: result) }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 20)
                }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, editor.isCreating ? 16 : 20)
        .padding(.top, 24).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func calendarDayPanel(_ day: String, isPage: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelHeader(title: day, isPage: isPage, close: { editor.calendarDay = nil })
            Button("Добавить на этот день") { editor.createOnDay(day) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let tasks = editor.calendarResult?.days.first { $0.day == day }?.tasks ?? []
                    if tasks.isEmpty { Text("Нет задач за этот день").foregroundStyle(.secondary) }
                    ForEach(tasks, id: \.occurrenceID) { task in plainTaskRow(task) }
                }
            }
            Spacer(minLength: 0)
        }.padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.accent)
            Text(editor.listResult?.emptyReason == .emptyDatabase ? "Задач пока нет" : editor.listResult?.emptyReason == .noSearchMatches ? "Поиск не дал совпадений" : editor.listResult?.emptyReason == .noMatches ? "Нет совпадений с фильтрами" : "Нет задач за этот период")
                .font(.system(size: 18, weight: .medium))
            Text(editor.listResult?.emptyReason == .noSearchMatches ? "Измените запрос или ищите во всех задачах." : editor.listResult?.emptyReason == .noMatches ? "Измените проект или выбранные метки." : editor.listResult?.emptyReason == .emptyPeriod ? "Выберите другой период или добавьте задачу." : "Добавьте дело, которым хотите заняться.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Создать задачу", action: editor.openCreation)
                .buttonStyle(.borderedProminent).padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }

    private func displayGroups(_ groups: [TaskListGroup]) -> [TaskListGroup] {
        groups.filter { $0.id == "unassigned" }
            + groups.filter { $0.id != "unassigned" && $0.id != "overdue" }
            + groups.filter { $0.id == "overdue" }
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Text("\(count)").foregroundStyle(.tertiary)
        }
        .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 22).padding(.bottom, 10)
    }

    private func periodButton(_ period: TaskPeriod) -> some View {
        Button { editor.selectPeriod(period) } label: {
            Label(period.label, systemImage: period == .all ? "list.bullet" : period == .completed ? "checkmark" : "calendar").font(.system(size: 11))
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(editor.period == period ? Palette.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(editor.period == period ? .isSelected : [])
    }

    private func taskRow(_ task: TaskRecord, result: TaskListResult) -> some View {
        let children = result.children(of: task.occurrenceID)
        let isContext = result.contextParentIDs.contains(task.occurrenceID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                if isContext {
                    Button { editor.selectTask(task) } label: {
                        HStack {
                            Image(systemName: task.completedAt == nil ? "list.bullet.indent" : "checkmark.circle.fill")
                            Text(task.title)
                            Text("Контекст").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).padding(.vertical, 8)
                } else {
                    plainTaskRow(task, childCount: children.count)
                }
            }
            if task.completedAt != nil && children.contains(where: { $0.completedAt == nil }) {
                Text("Родитель выполнен · \(children.filter { $0.completedAt == nil }.count) подзадач открыто")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if editor.expandedParents.contains(task.occurrenceID) || isContext || !editor.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 8) {
                    ForEach(children, id: \.occurrenceID) { child in plainTaskRow(child) }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1) }
                .padding(.leading, 32)
            }
        }
    }

    private func plainTaskRow(_ task: TaskRecord, childCount: Int = 0) -> some View {
        let isChild = task.parentTaskID != nil
        return HStack(spacing: 10) {
            Button { editor.setCompleted(task) } label: {
                Image(systemName: task.skippedAt != nil ? "forward.end.circle" : (task.completedAt == nil ? "circle" : "checkmark.circle.fill"))
                    .font(.system(size: 20, weight: .ultraLight)).frame(width: 32, height: 36)
                    .foregroundStyle(task.completedAt == nil ? Color.secondary : Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(task.completedAt == nil ? "Выполнить" : "Отменить выполнение"): \(task.title)")
            .accessibilityIdentifier("complete-\(task.occurrenceID)")

            ToolMenu(editor: editor, task: task, compact: true)
            Button { editor.selectTask(task) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title)
                        .font(.system(size: editor.isCreating || isChild ? 13 : 15))
                        .strikethrough(task.completedAt != nil)
                        .foregroundStyle(task.completedAt == nil ? Color.primary : Color.secondary)
                        .lineLimit(2)
                    HStack(spacing: 7) {
                    if let recurrence = task.recurrence {
                        Label(recurrenceLabel(recurrence), systemImage: "arrow.left.arrow.right")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let workspace = editor.workspace, !task.labelIDs.isEmpty {
                        LabelChips(labels: workspace.labels, selection: task.labelIDs)
                    }
                    if task.priority != .none {
                        Label(task.priority.label, systemImage: "flag")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(task.title)
            .accessibilityIdentifier("select-\(task.occurrenceID)")

            if childCount > 0 {
                Button {
                    if !editor.expandedParents.insert(task.occurrenceID).inserted { editor.expandedParents.remove(task.occurrenceID) }
                } label: {
                    Label("\(childCount)", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(minWidth: 42, minHeight: 36)
                }.buttonStyle(.plain).accessibilityLabel("Подзадачи: \(childCount)")
                .accessibilityValue(editor.expandedParents.contains(task.occurrenceID) ? "Раскрыты" : "Свёрнуты")
            }
            Text(occurrenceDayLabel(task, today: editor.workspace?.today, tomorrow: editor.workspace?.tomorrow))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, isChild ? 10 : 14).padding(.vertical, isChild ? 8 : 12)
        .frame(minHeight: isChild ? 56 : 68)
        .background(editor.selectedID == task.occurrenceID ? Color(red: 44/255, green: 38/255, blue: 55/255) : isChild ? Color(red: 26/255, green: 26/255, blue: 33/255) : Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(editor.selectedID == task.occurrenceID ? Palette.accent.opacity(0.19) : .clear, lineWidth: 1)
        }
    }
}

private struct CreationPanel: View {
    @Bindable var editor: WorkspaceEditor
    @FocusState private var titleFocused: Bool
    var isPage = false
    @State private var confirmingDiscard = false
    @State private var scheduleExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Новая задача", isPage: isPage, close: editor.closeCreation)
            ScrollView { panelContent.frame(maxWidth: .infinity) }
            Divider()
            creationFooter.padding(.horizontal, 20).frame(height: 56)
        }
        .background(Color(red: 31/255, green: 29/255, blue: 38/255))
        .onExitCommand {
            if scheduleExpanded { scheduleExpanded = false }
            else { editor.closeCreation() }
        }
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Название").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Что нужно сделать?", text: Binding(
                    get: { editor.draftTitle },
                    set: { editor.draftTitle = $0; editor.saveDraft() }
                ), axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 21, weight: .medium))
                    .lineLimit(1...5).frame(minHeight: 42).focused($titleFocused)
                    .onSubmit(editor.createTask)
                    .accessibilityLabel("Название задачи").accessibilityIdentifier("task-title")
            }
            Divider().padding(.top, 24)
            SchedulePopover(summary: editor.draftRecurrence.map(recurrenceLabel) ?? dayLabel(editor.draftDay, today: editor.workspace?.today, tomorrow: editor.workspace?.tomorrow), expanded: $scheduleExpanded) {
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
            if let workspace = editor.workspace {
                Text("Инструменты").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.top, 16).padding(.bottom, 6)
                TimerField(duration: editor.draftTimerDurationSeconds) { seconds in
                    editor.draftTimerDurationSeconds = seconds
                    guard editor.saveDraft() else { throw WorkspaceError.storage(editor.draftError ?? "Не удалось сохранить черновик") }
                }
                PomodoroField(workspace: workspace, parameters: Binding(
                    get: { editor.draftPomodoroParameters },
                    set: { editor.draftPomodoroParameters = $0; editor.saveDraft() }
                ), inherited: (try? workspace.pomodoroParameters()) ?? PomodoroParameters())
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Заметка").font(.system(size: 12)).foregroundStyle(.secondary)
                TaskNoteEditor(note: Binding(
                    get: { editor.draftNote },
                    set: { editor.draftNote = $0; editor.saveDraft() }
                ), accessibilityID: "creation-note")
                .frame(height: 100)
            }.padding(.top, 20)
            VStack(alignment: .leading, spacing: 12) {
                Text("Подзадачи").font(.system(size: 12, weight: .semibold))
                ForEach(editor.draftChildren) { child in
                    DisclosureGroup(child.title.isEmpty ? "Новая подзадача" : child.title) {
                        TextField("Название подзадачи", text: childBinding(child, \.title))
                        if let workspace = editor.workspace {
                            LabelField(workspace: workspace, selection: childBinding(child, \.labelIDs, replacingLabels: true))
                        }
                        TimerField(duration: childBinding(child, \.timerDurationSeconds).wrappedValue) { seconds in
                            childBinding(child, \.timerDurationSeconds).wrappedValue = seconds
                            if let error = editor.draftError { throw WorkspaceError.storage(error) }
                        }
                        if let workspace = editor.workspace {
                            PomodoroField(workspace: workspace, parameters: childBinding(child, \.pomodoroParameters),
                                inherited: editor.draftPomodoroParameters ?? ((try? workspace.pomodoroParameters()) ?? PomodoroParameters()), isChild: true)
                        }
                        TaskNoteEditor(note: childBinding(child, \.note), accessibilityID: "child-note-\(child.id)").frame(height: 100)
                        Button("Удалить подзадачу") { editor.draftChildren.removeAll { $0.id == child.id }; editor.saveDraft() }
                    }
                }
                Button("Добавить подзадачу") { editor.draftChildren.append(SubtaskDraft()); editor.saveDraft() }
                Text("Проект и повтор — как у родителя. Метки и заметка — свои.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            if let error = editor.draftError {
                StorageNotice(message: error)
                Button("Повторить сохранение черновика") { editor.saveDraft() }
            } else {
                Text("Черновик сохраняется на этом Mac")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .defaultFocus($titleFocused, true)
        .task { await Task.yield(); titleFocused = true }
        .alert("Удалить черновик?", isPresented: $confirmingDiscard) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive, action: editor.discardDraft)
        } message: { Text("Введённые данные и выбранные параметры будут удалены.") }
    }
    private var creationFooter: some View {
            HStack {
                Button("Закрыть", action: editor.closeCreation).buttonStyle(.plain)
                Spacer()
                Button { confirmingDiscard = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).accessibilityLabel("Удалить черновик")
                Spacer()
                Button(editor.draftError == nil ? "Создать" : "Повторить создание", action: editor.createTask)
                    .buttonStyle(.borderedProminent)
                    .disabled(editor.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-task")
            }
    }

}

private struct DetailPanel: View {
    @Bindable var editor: WorkspaceEditor
    let task: TaskRecord
    var isPage = false
    @State private var scheduleExpanded = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Детали задачи", isPage: isPage, close: editor.closeDetails)
            ScrollView { panelContent.frame(maxWidth: .infinity) }
            Divider()
            HStack {
                Button("Закрыть", action: editor.closeDetails).buttonStyle(.plain)
                Spacer()
                ToolMenu(editor: editor, task: task, compact: true)
            }.padding(.horizontal, 24).frame(height: 56)
        }
        .background(Color(red: 29/255, green: 29/255, blue: 36/255))
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            SchedulePopover(summary: task.recurrence.map(recurrenceLabel) ?? dayLabel(task.plannedDay, today: editor.workspace?.today, tomorrow: editor.workspace?.tomorrow), expanded: $scheduleExpanded) {
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
            if let workspace = editor.workspace {
                HStack {
                    Text("Инструменты").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    ToolMenu(editor: editor, task: task, compact: true)
                }.padding(.top, 16).padding(.bottom, 6)
                TimerField(duration: try? workspace.timerDurationSeconds(taskID: task.id)) { seconds in
                    try workspace.setTimerDuration(taskID: task.id, durationSeconds: seconds)
                }
                PomodoroField(workspace: workspace, parameters: Binding(
                    get: { editor.detailPomodoroParameters },
                    set: { editor.changePomodoroParameters($0) }
                ), inherited: (try? workspace.pomodoroParameters(taskID: task.parentTaskID)) ?? PomodoroParameters(), isChild: task.parentTaskID != nil)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Заметка").font(.system(size: 12)).foregroundStyle(.secondary)
                TaskNoteEditor(note: Binding(
                    get: { editor.detailNote },
                    set: { editor.detailNote = $0; editor.saveNote() }
                ), accessibilityID: "detail-note")
                .frame(height: 100)
            }.padding(.top, 20)
            if task.parentTaskID == nil {
                Divider().padding(.vertical, 16)
                Text("Подзадачи").font(.system(size: 12, weight: .semibold))
                ForEach(editor.workspace?.children(of: task.occurrenceID) ?? [], id: \.occurrenceID) { child in
                    HStack {
                        Button { editor.setCompleted(child) } label: { Image(systemName: child.completedAt == nil ? "circle" : "checkmark.circle.fill") }.buttonStyle(.plain)
                        Button(child.title) { editor.selectTask(child) }.buttonStyle(.plain)
                            .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                        ToolMenu(editor: editor, task: child, compact: true)
                    }.frame(minHeight: 44)
                }
                HStack {
                    TextField("Новая подзадача", text: $editor.newChildTitle).onSubmit(editor.addChild)
                    Button("Добавить", action: editor.addChild)
                }
            }
            if let error = editor.detailError {
                StorageNotice(message: error)
                Button("Повторить сохранение") { editor.saveDetails() }
                Button("Отменить правки", action: editor.discardDetailEdits)
            }
            Label(occurrenceStatus(task, today: editor.workspace?.today), systemImage: task.skippedAt != nil ? "forward.end.circle" : (task.completedAt == nil ? "circle" : "checkmark.circle"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Divider().padding(.vertical, 16)
            DisclosureGroup("История запусков") {
                RunHistory(results: editor.workspace?.timeToolResults.filter { $0.occurrenceID == task.occurrenceID } ?? [])
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .onExitCommand {
            if scheduleExpanded { scheduleExpanded = false }
            else { editor.closeDetails() }
        }
    }
}

struct PropertyRow<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            content.font(.system(size: 13))
        }
        .font(.system(size: 12)).frame(minHeight: 42)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.09)).frame(maxWidth: .infinity).frame(height: 1)
        }
    }
}

struct PropertyMenu<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        Menu { actions } label: { Text(title).fontWeight(.regular) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .font(.system(size: 13, weight: .regular))
            .tint(Palette.propertyValue).foregroundStyle(Palette.propertyValue)
            .fixedSize().padding(.trailing, 18)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Palette.propertyValue)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

private struct PanelHeader: View {
    let title: String
    let isPage: Bool
    let close: () -> Void

    var body: some View {
        HStack {
            if isPage {
                Button(action: close) { Label("Назад", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
            Text(title).font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Закрыть")
        }.padding(.horizontal, 20).frame(height: 60)
            .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.09)).frame(maxWidth: .infinity).frame(height: 1)
        }
    }
}

private struct SchedulePopover<Content: View>: View {
    let summary: String
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Button { expanded = true } label: {
            PropertyRow(title: "Расписание", icon: "calendar") {
                HStack(spacing: 8) { Text(summary); Image(systemName: "chevron.right").font(.system(size: 10)) }
            }
        }.buttonStyle(.plain).accessibilityIdentifier("task-schedule-open")
        .popover(isPresented: $expanded) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Расписание").font(.headline)
                content
                HStack { Spacer(); Button("Готово") { expanded = false } }
            }.padding(20).frame(width: 330)
                .background(PopoverEscapeFocus(dismiss: { expanded = false }))
                .onExitCommand { expanded = false }
        }
    }
}

/// The popover owns Escape immediately, before a user clicks one of its fields.
/// This responder is local to the popover and installs no event monitor.
private struct PopoverEscapeFocus: NSViewRepresentable {
    let dismiss: () -> Void
    func makeNSView(context: Context) -> PopoverEscapeView { PopoverEscapeView() }
    func updateNSView(_ view: PopoverEscapeView, context: Context) { view.dismiss = dismiss }
}

private final class PopoverEscapeView: NSView {
    var dismiss: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeKey()
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            dismiss?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private func recurrenceLabel(_ recurrence: TaskRecurrence) -> String {
    switch recurrence {
    case .daily: "Каждый день"
    case .weekdays: "По будням"
    case .selectedWeekdays: "Выбранные дни"
    case .weekly: "Раз в неделю"
    }
}

private struct PriorityField: View {
    @Binding var selection: TaskPriority

    var body: some View {
        PropertyRow(title: "Приоритет", icon: "line.3.horizontal.decrease") {
            PropertyMenu(title: selection.label) {
                ForEach(TaskPriority.allCases, id: \.self) { priority in
                    Button(priority.label) { selection = priority }
                }
            }
                .accessibilityIdentifier("task-priority")
                .accessibilityValue(selection.label)
        }
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

struct StorageNotice: View {
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
    @State private var profilesVisible = false

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
            Button("Помодоро · " + pomodoroLabel((try? editor.workspace?.pomodoroParameters(taskID: task?.id)) ?? PomodoroParameters())) { editor.startPomodoro(task) }
                .disabled(editor.workspace?.activeSession != nil || task?.completedAt != nil || task?.skippedAt != nil)
            Button("Секундомер · Счёт вверх") { editor.startStopwatch(task) }
                .disabled(editor.workspace?.activeSession != nil || task?.completedAt != nil || task?.skippedAt != nil)
            Button("Профили помодоро…") { profilesVisible = true }
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
            if compact { Image(systemName: "play") }
            else { Label(task == nil ? "Без задачи" : "Инструменты", systemImage: "stopwatch") }
        }
        .accessibilityLabel(task.map { "Инструменты: " + $0.title } ?? "Инструменты без задачи")
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // AppKit simplifies Menu labels; draw the compact affordance outside that label.
        .opacity(compact ? 0.01 : 1)
        .frame(width: compact ? 40 : nil, height: compact ? 32 : nil)
        .background {
            if compact {
                Capsule().fill(Color(red: 48/255, green: 47/255, blue: 59/255))
            }
        }
        .overlay {
            if compact {
                HStack(spacing: 4) {
                    Image(systemName: "play").font(.system(size: 11))
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
                .foregroundStyle(Palette.accent)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .fixedSize()
        .help("Выбрать инструмент времени" + (task == nil ? " без задачи" : ""))
        .accessibilityIdentifier(task.map { "task-tools-\($0.id)" } ?? "free-tools")
        .sheet(isPresented: $profilesVisible) {
            if let workspace = editor.workspace { PomodoroProfilesView(workspace: workspace) }
        }
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
            ScrollView(.horizontal) {
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
            }.scrollIndicators(.hidden)
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

func durationLabel(_ seconds: TimeInterval) -> String {
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
    var namedMonth: String? = nil
    let select: (TaskPeriod) -> Void
    @State private var expanded = false
    @State private var keyboardSelection: TaskPeriod = .week

    var body: some View {
        Button { expanded = true } label: {
            Text(selected == .week || selected == .month ? "Ещё · " + (namedMonth.map { String($0.prefix(7)) } ?? selected.label) : "Ещё")
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
                        }
                        .frame(width: 170, alignment: .leading)
                        .padding(5)
                        .background(keyboardSelection == period ? Palette.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            .padding(12)
            .onAppear { keyboardSelection = selected == .month ? .month : .week }
            .background(PeriodMenuKeyboardFocus(
                move: { keyboardSelection = $0 > 0 ? .month : .week },
                apply: {
                    select(keyboardSelection)
                    expanded = false
                },
                dismiss: { expanded = false }
            ))
        }
    }
}

/// Owns the popover's responder while it is visible, independent of macOS's button-navigation preference.
/// This view receives its own key events; it installs no window or application event monitor.
private struct PeriodMenuKeyboardFocus: NSViewRepresentable {
    let move: (Int) -> Void
    let apply: () -> Void
    let dismiss: () -> Void

    func makeNSView(context: Context) -> PeriodMenuKeyboardView { PeriodMenuKeyboardView() }

    func updateNSView(_ view: PeriodMenuKeyboardView, context: Context) {
        view.move = move
        view.apply = apply
        view.dismiss = dismiss
    }
}

private final class PeriodMenuKeyboardView: NSView {
    var move: ((Int) -> Void)?
    var apply: (() -> Void)?
    var dismiss: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI attaches the popover before finishing its responder setup.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeKey()
            window.makeFirstResponder(self)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 125: move?(1)
        case 126: move?(-1)
        case 36, 76: apply?()
        case 53: dismiss?()
        default: super.keyDown(with: event)
        }
    }
}
