import SteadyCore
import SwiftUI

struct ProjectMarker: View {
    let color: ProjectColor?

    var body: some View {
        Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
    }

    private var tint: Color {
        switch color {
        case .purple: .purple
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        case nil: .secondary
        }
    }
}

struct ProjectField: View {
    let projects: [ProjectRecord]
    @Binding var selection: UUID?

    var body: some View {
        PropertyRow(title: "Проект", icon: "folder") {
            Menu {
                Button("Без проекта") { selection = nil }
                ForEach(projects) { project in
                    Button(project.title) { selection = project.id }
                }
            } label: {
                PropertyValue(title: projects.first { $0.id == selection }?.title ?? "Без проекта")
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityIdentifier("task-project")
                .accessibilityValue(projects.first { $0.id == selection }?.title ?? "Без проекта")
        }
    }
}

struct ProjectEditorPanel: View {
    let workspace: TaskWorkspace?
    let project: ProjectRecord?
    @State private var title = ""
    @State private var color: ProjectColor?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(project == nil ? "Новый проект" : "Переименовать проект").font(.headline)
            TextField("Название проекта", text: $title)
                .focused($titleFocused).onSubmit(save)
                .accessibilityIdentifier("project-title")
            if project == nil {
                Picker("Цвет", selection: $color) {
                    Text("Без цвета").tag(ProjectColor?.none)
                    ForEach(ProjectColor.allCases, id: \.self) { color in
                        Text(color.label).tag(Optional(color))
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Сохранить", action: save).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 340)
        .onAppear { title = project?.title ?? ""; titleFocused = true }
    }

    private func save() {
        guard let workspace else { return }
        do {
            if let project {
                try workspace.renameProject(id: project.id, title: title)
            } else {
                try workspace.createProject(title: title, color: color)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
