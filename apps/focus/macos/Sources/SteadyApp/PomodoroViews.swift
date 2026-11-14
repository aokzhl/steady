import SwiftUI
import SteadyCore

func pomodoroLabel(_ parameters: PomodoroParameters) -> String {
    "\(durationLabel(parameters.workSeconds)) / \(durationLabel(parameters.shortRestSeconds)) / \(durationLabel(parameters.longRestSeconds)) · после \(parameters.longRestAfter)"
}

struct PomodoroParameterEditor: View {
    let initial: PomodoroParameters
    let save: (PomodoroParameters) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var work = ""
    @State private var shortRest = ""
    @State private var longRest = ""
    @State private var count = ""
    @State private var error: String?

    private func seconds(_ text: String) throws -> Double {
        guard let minutes = Double(text.replacingOccurrences(of: ",", with: ".")), minutes.isFinite,
              minutes > 0, (minutes * 60).isFinite, minutes * 60 <= TimeToolSession.maximumTimerDurationSeconds else { throw WorkspaceError.invalidTimerDuration }
        return minutes * 60
    }

    var body: some View {
        Form {
            Text("Параметры помодоро").font(.headline)
            TextField("Работа, мин", text: $work)
            TextField("Короткий отдых, мин", text: $shortRest)
            TextField("Длинный отдых, мин", text: $longRest)
            TextField("Длинный отдых после", text: $count)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    do {
                        guard let count = Int(count), count > 0 else { throw WorkspaceError.invalidTimerDuration }
                        try save(PomodoroParameters(workSeconds: seconds(work), shortRestSeconds: seconds(shortRest), longRestSeconds: seconds(longRest), longRestAfter: count))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420)
        .onAppear {
            work = String(initial.workSeconds / 60)
            shortRest = String(initial.shortRestSeconds / 60)
            longRest = String(initial.longRestSeconds / 60)
            count = String(initial.longRestAfter)
        }
    }
}

struct PomodoroField: View {
    let workspace: TaskWorkspace
    @Binding var parameters: PomodoroParameters?
    let inherited: PomodoroParameters
    var isChild = false
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                Button(isChild ? "Как у родителя" : "Выбранный профиль") { parameters = nil }
                Button("Свои") { editing = true }
                Divider()
                ForEach(workspace.pomodoroProfiles) { profile in
                    Button(profile.title) { parameters = profile.parameters }
                }
            } label: {
                Text("Помодоро · " + (parameters == nil ? (isChild ? "Как у родителя" : "Выбранный профиль") : "Свои"))
            }
            Text(pomodoroLabel(parameters ?? inherited)).font(.caption).foregroundStyle(.secondary)
            Button("Изменить параметры") { editing = true }.font(.caption)
        }
        .sheet(isPresented: $editing) {
            PomodoroParameterEditor(initial: parameters ?? inherited) { parameters = $0 }
        }
    }
}

struct PomodoroProfilesView: View {
    let workspace: TaskWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PomodoroProfile?
    @State private var creating = false
    @State private var title = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Профили помодоро").font(.title2)
            ForEach(workspace.pomodoroProfiles) { profile in
                HStack {
                    Button {
                        do { try workspace.selectPomodoroProfile(id: profile.id); error = nil }
                        catch { self.error = error.localizedDescription }
                    } label: {
                        Label(profile.title, systemImage: workspace.selectedPomodoroProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                    }
                    Text(pomodoroLabel(profile.parameters)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Изменить") { title = profile.title; editing = profile }
                }
            }
            TextField("Название профиля", text: $title)
            Button("Создать профиль") { creating = true }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error { Text(error).foregroundStyle(.orange) }
            Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 650)
        .sheet(item: $editing) { profile in
            VStack {
                TextField("Название профиля", text: $title).padding([.top, .horizontal])
                PomodoroParameterEditor(initial: profile.parameters) { parameters in
                    _ = try workspace.savePomodoroProfile(id: profile.id, title: title, parameters: parameters)
                }
            }
        }
        .sheet(isPresented: $creating) {
            PomodoroParameterEditor(initial: PomodoroParameters()) { parameters in
                let profile = try workspace.savePomodoroProfile(title: title, parameters: parameters)
                try workspace.selectPomodoroProfile(id: profile.id)
            }
        }
    }
}
