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
    @State private var workspace: TaskWorkspace?
    @State private var openingError: String?
    @State private var actionError: String?
    @State private var creationError: String?
    @State private var draftTitle = ""
    @State private var isCreating = false
    @State private var sidebarVisible = true
    @State private var selectedID: UUID?
    @Environment(\.scenePhase) private var scenePhase

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
                if isCreating, workspace != nil {
                    Divider()
                    creationPanel
                }
            }
        }
        .frame(minWidth: 850, minHeight: 560)
        .background(Palette.background)
        .tint(Palette.accent)
        .task { openWorkspace() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in reload() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                sidebarVisible.toggle()
            } label: {
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
            HStack(spacing: 7) {
                Circle().fill(.green.opacity(0.65)).frame(width: 5, height: 5)
                Text("Данные на этом Mac").font(.system(size: 11)).foregroundStyle(.secondary)
            }
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Label("Сегодня", systemImage: "calendar")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Palette.accent)

            if let openingError {
                errorNotice(openingError)
                Button("Повторить открытие") { openWorkspace() }
            } else if let workspace {
                Button {
                    isCreating = true
                } label: {
                    Label("Добавить задачу", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("new-task")

                if let actionError {
                    errorNotice(actionError)
                    Button("Обновить список") { reload() }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        let open = workspace.tasks.filter { $0.completedAt == nil && $0.plannedDay <= workspace.today }
                        let completed = workspace.tasks.filter {
                            $0.completedAt.map { Calendar.current.isDateInToday($0) } ?? false
                        }
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
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(workspace?.tasks.isEmpty == true ? "Задач пока нет" : "На сегодня всё")
                .font(.system(size: 18, weight: .medium))
            Text("Добавьте дело, которым хотите заняться.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Создать задачу") { isCreating = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Text("\(count)").foregroundStyle(.tertiary)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }

    private func taskRow(_ task: TaskRecord) -> some View {
        HStack(spacing: 14) {
            Button {
                do {
                    try workspace?.setCompleted(occurrenceID: task.occurrenceID, completed: task.completedAt == nil)
                    actionError = nil
                } catch { actionError = error.localizedDescription }
            } label: {
                Image(systemName: task.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(task.completedAt == nil ? Color.secondary : Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(task.completedAt == nil ? "Выполнить" : "Отменить выполнение"): \(task.title)")
            .accessibilityIdentifier("complete-\(task.occurrenceID)")

            Button { selectedID = task.occurrenceID } label: {
                Text(task.title)
                    .font(.system(size: 14))
                    .strikethrough(task.completedAt != nil)
                    .foregroundStyle(task.completedAt == nil ? Color.primary : Color.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(task.title)

            Text(task.plannedDay == workspace?.today ? "Сегодня" : task.plannedDay)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(selectedID == task.occurrenceID ? Palette.accent.opacity(0.6) : .clear, lineWidth: 1)
        }
    }

    private var creationPanel: some View {
        CreationPanel(title: $draftTitle, error: creationError, create: createTask) {
            isCreating = false
        }
        .frame(width: 300)
        .background(Palette.sidebar)
    }

    private func errorNotice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-error")
    }

    private func createTask() {
        guard let workspace else { return }
        do {
            let task = try workspace.createTask(title: draftTitle)
            selectedID = task.occurrenceID
            draftTitle = ""
            creationError = nil
            isCreating = false
        } catch { creationError = error.localizedDescription }
    }

    private func openWorkspace() {
        do {
            let base = ProcessInfo.processInfo.environment["STEADY_DATA_DIRECTORY"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            workspace = try TaskWorkspace(databaseURL: TaskWorkspace.guestDatabaseURL(in: base))
            openingError = nil
        } catch { openingError = error.localizedDescription }
    }

    private func reload() {
        guard let workspace else { return }
        do {
            try workspace.reload()
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }
}

private struct CreationPanel: View {
    @Binding var title: String
    let error: String?
    let create: () -> Void
    let close: () -> Void
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Новая задача").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Закрыть создание")
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Название").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Что нужно сделать?", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .medium))
                    .lineLimit(1...5)
                    .focused($titleFocused)
                    .onSubmit(create)
                    .accessibilityLabel("Название задачи")
                    .accessibilityIdentifier("task-title")
            }
            Divider()
            HStack {
                Label("Расписание", systemImage: "calendar").foregroundStyle(.secondary)
                Spacer()
                Text("Сегодня")
            }
            .font(.system(size: 12))
            HStack {
                Label("Проект", systemImage: "folder").foregroundStyle(.secondary)
                Spacer()
                Text("Без проекта")
            }
            .font(.system(size: 12))
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Divider()
            HStack {
                Button("Закрыть", action: close).buttonStyle(.plain)
                Spacer()
                Button(error == nil ? "Создать" : "Повторить сохранение", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-task")
            }
        }
        .padding(22)
        .defaultFocus($titleFocused, true)
        .task {
            await Task.yield()
            titleFocused = true
        }
    }
}
