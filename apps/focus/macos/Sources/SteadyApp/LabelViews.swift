import SteadyCore
import SwiftUI

struct LabelChips: View {
    let labels: [LabelRecord]
    let selection: Set<UUID>

    private var selected: [LabelRecord] { labels.filter { selection.contains($0.id) } }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(selected.prefix(2))) { label in
                HStack(spacing: 4) {
                    Text(label.title).lineLimit(1)
                }
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2)))
            }
            if selected.count > 2 { Text("+\(selected.count - 2)") }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .help(selected.map(\.title).joined(separator: ", "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(selected.map(\.title).joined(separator: ", "))
    }
}

struct LabelField: View {
    let workspace: TaskWorkspace
    @Binding var selection: Set<UUID>
    @State private var visible = false
    @State private var query = ""
    @State private var color: ProjectColor?
    @State private var error: String?
    @State private var renamingLabel: LabelRecord?

    private var summary: String {
        let titles = workspace.labels.filter { selection.contains($0.id) }.map(\.title)
        guard !titles.isEmpty else { return "Добавить" }
        let names = titles.prefix(2).joined(separator: ", ")
        return titles.count > 2 ? names + " +\(titles.count - 2)" : names
    }

    var body: some View {
        Button { visible = true } label: {
            PropertyRow(title: "Метки", icon: "tag") {
                HStack(spacing: 8) {
                    Text(summary).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 10))
                }
            }
        }
        .buttonStyle(.plain).accessibilityIdentifier("task-labels")
        .popover(isPresented: $visible) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Метки").font(.headline)
                TextField("Найти или создать метку", text: $query)
                    .accessibilityIdentifier("label-search")
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(workspace.labels.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { label in
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { selection.contains(label.id) },
                                    set: { chosen in
                                        var ids = selection
                                        if chosen { ids.insert(label.id) } else { ids.remove(label.id) }
                                        selection = ids
                                    }
                                )) {
                                    HStack { ProjectMarker(color: label.color); Text(label.title) }
                                }
                                .toggleStyle(.checkbox)
                                Spacer()
                                Button { renamingLabel = label } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Переименовать метку: \(label.title)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                Divider()
                Picker("Цвет новой метки", selection: $color) {
                    Text("Без цвета").tag(ProjectColor?.none)
                    ForEach(ProjectColor.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                Button("Создать и назначить", action: create)
                    .accessibilityIdentifier("create-label-from-picker")
                if let error { Text(error).font(.callout).foregroundStyle(.orange) }
                Button("Готово") { visible = false }
            }
            .padding(18).frame(width: 280)
            .sheet(item: $renamingLabel) { label in
                LabelEditorPanel(workspace: workspace, label: label)
            }
        }
    }

    private func create() {
        do {
            let label = try workspace.createLabel(title: query, color: color)
            selection = selection.union([label.id])
            query = ""
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct LabelEditorPanel: View {
    let workspace: TaskWorkspace?
    let label: LabelRecord?
    @State private var title = ""
    @State private var color: ProjectColor?
    @State private var error: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(label == nil ? "Новая метка" : "Переименовать метку").font(.headline)
            TextField("Название метки", text: $title).focused($titleFocused)
                .onSubmit(save).accessibilityIdentifier("label-title")
            if label == nil {
                Picker("Цвет", selection: $color) {
                    Text("Без цвета").tag(ProjectColor?.none)
                    ForEach(ProjectColor.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Сохранить", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 340)
        .onAppear { title = label?.title ?? ""; titleFocused = true }
    }

    private func save() {
        guard let workspace else { return }
        do {
            if let label { try workspace.renameLabel(id: label.id, title: title) }
            else { try workspace.createLabel(title: title, color: color) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
