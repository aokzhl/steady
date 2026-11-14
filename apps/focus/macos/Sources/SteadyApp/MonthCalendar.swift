import SteadyCore
import SwiftUI

private enum CalendarCellMetrics {
    static let padding: CGFloat = 5
    static let spacing: CGFloat = 3
    static let headerHeight: CGFloat = 14
    static let previewHeight: CGFloat = 19
    static let overflowHeight: CGFloat = 12
    // Header, overflow, and the gaps before overflow / final spacer remain visible.
    static let reservedHeight = padding * 2 + headerHeight + overflowHeight + spacing * 2
    static let previewStride = previewHeight + spacing
}

struct MonthCalendar: View {
    @Bindable var editor: WorkspaceEditor
    @State private var undatedExpanded = false
    @State private var weeklyExpanded = false

    var body: some View {
        if let month = editor.calendarResult {
            VStack(spacing: 8) {
                HStack {
                    Button { editor.moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Предыдущий месяц")
                    Text(monthTitle(month.month)).font(.headline)
                    Button { editor.moveMonth(1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Следующий месяц")
                    Spacer()
                    Button("Сегодня") { editor.selectPeriod(.today) }
                }
                HStack(spacing: 4) {
                    ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) { day in
                        Text(day).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
                GeometryReader { geometry in
                    let rows = (month.leadingDays + month.days.count + 6) / 7
                    let height = max(1, (geometry.size.height - CGFloat(rows - 1) * 4) / CGFloat(rows))
                    let width = max(1, (geometry.size.width - 24) / 7)
                    let previewCount = max(0, Int((height - CalendarCellMetrics.reservedHeight) / CalendarCellMetrics.previewStride))
                    VStack(spacing: 4) {
                        ForEach(0..<rows, id: \.self) { row in
                            HStack(spacing: 4) {
                                ForEach(0..<7, id: \.self) { column in
                                    let index = row * 7 + column - month.leadingDays
                                    if month.days.indices.contains(index) {
                                        dayCell(month.days[index], previewCount: previewCount)
                                            .frame(width: width, height: height, alignment: .topLeading)
                                    } else {
                                        Color.clear.frame(width: width, height: height)
                                    }
                                }
                            }
                        }
                    }
                }
                bucket("Без даты", tasks: month.undated, expanded: $undatedExpanded)
                bucket("На неделе · день не выбран", tasks: month.weekly, expanded: $weeklyExpanded)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func dayCell(_ day: TaskCalendarDay, previewCount: Int) -> some View {
        VStack(alignment: .leading, spacing: CalendarCellMetrics.spacing) {
            HStack(spacing: 3) {
                Button(String(day.day.suffix(2))) { editor.openCalendarDay(day.day) }
                    .accessibilityLabel("Открыть день " + day.day)
                Spacer(minLength: 0)
                Button { editor.createOnDay(day.day) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Создать на " + day.day)
            }.buttonStyle(.plain).font(.system(size: 11))
                .frame(height: CalendarCellMetrics.headerHeight)
            ForEach(Array(day.tasks.prefix(previewCount)), id: \.occurrenceID) { task in
                Button { editor.calendarDay = day.day; editor.selectTask(task) } label: {
                    HStack(spacing: 3) {
                        if task.completedAt != nil { Image(systemName: "checkmark.circle.fill") }
                        Text(task.title).lineLimit(1)
                    }.font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).frame(height: CalendarCellMetrics.previewHeight)
                    .accessibilityLabel(task.title + (task.completedAt == nil ? "" : " · Выполнено"))
            }
            if day.tasks.count > previewCount {
                Button("Ещё \(day.tasks.count - previewCount)") { editor.openCalendarDay(day.day) }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Palette.accent)
                    .frame(height: CalendarCellMetrics.overflowHeight)
                    .accessibilityLabel("Ещё \(day.tasks.count - previewCount) · " + day.day)
            }
            Spacer(minLength: 0)
        }.padding(CalendarCellMetrics.padding)
            .background(day.day == editor.workspace?.today ? Palette.accent.opacity(0.16) : Color.white.opacity(day.isInPeriod ? 0.055 : 0.018), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(day.day == editor.calendarDay ? Palette.accent : Color.clear))
            .clipped()
    }

    private func bucket(_ title: String, tasks: [TaskRecord], expanded: Binding<Bool>) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(tasks, id: \.occurrenceID) { task in
                        HStack {
                            Button { editor.setCompleted(task) } label: { Image(systemName: task.completedAt == nil ? "circle" : "checkmark.circle.fill") }
                                .accessibilityLabel("Выполнение: " + task.title)
                            Button { editor.calendarDay = nil; editor.selectTask(task) } label: {
                                Text(task.title + (task.periodEnd.map { " · до " + $0 } ?? ""))
                            }
                        }.buttonStyle(.plain)
                    }
                    if tasks.isEmpty { Text("Нет задач").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 90)
        } label: { Text(title + " · \(tasks.count)").font(.system(size: 11)) }
    }

    private func monthTitle(_ month: String) -> String {
        let components = month.split(separator: "-")
        let names = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"]
        guard components.count == 3, let number = Int(components[1]), (1...12).contains(number) else { return month }
        return names[number - 1] + " " + components[0]
    }
}
