import CSQLite
import Foundation

public enum WorkspaceError: Error, Equatable, LocalizedError {
    case childInheritsParent
    case activeOwnerRequiresStop
    case outsideOccurrenceWeek
    case invalidRecurrence
    case timerDurationRequired
    case invalidTimerDuration
    case invalidTimerIncrement
    case invalidDay
    case sessionOccupied
    case skippedOwner
    case completedOwner
    case emptyTitle
    case invalidTitle
    case emptyLabelTitle
    case duplicateLabel
    case labelNotFound
    case projectNotFound
    case occurrenceNotFound
    case draftChanged
    case storage(String)
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .childInheritsParent: "Один уровень подзадач. Проект и расписание — как у родителя; для своих создайте отдельную задачу."
        case .activeOwnerRequiresStop:
            "Сначала нажмите Stop, затем пропустите выполнение. Сессия на паузе тоже занимает активный инструмент."
        case .outsideOccurrenceWeek:
            "Недельное выполнение можно назначить только на день своей недели, с понедельника по воскресенье."
        case .invalidRecurrence:
            "Выберите хотя бы один день недели."
        case .timerDurationRequired: "Задайте длительность таймера перед запуском."
        case .invalidTimerDuration: "Введите положительную длительность в допустимом числовом диапазоне."
        case .invalidTimerIncrement: "Выберите приращение от −20 до +20 минут."
        case .invalidDay:
            "Выберите существующую календарную дату."
        case .sessionOccupied:
            "Уже есть активная сессия, в том числе на паузе. Остановите её перед новым запуском."
        case .skippedOwner:
            "Выполнение пропущено. Сначала верните его в работу."
        case .completedOwner:
            "Задача уже выполнена. Сначала верните её в работу."
        case .emptyTitle:
            "Введите название задачи."
        case .invalidTitle:
            "Название содержит недопустимый символ. Удалите его и повторите."
        case .emptyLabelTitle:
            "Введите название метки."
        case .duplicateLabel:
            "Метка с таким названием уже существует. Выберите её или измените название."
        case .labelNotFound:
            "Метка больше недоступна. Обновите список и повторите."
        case .projectNotFound:
            "Проект больше недоступен. Обновите список и повторите."
        case .occurrenceNotFound:
            "Задача больше недоступна. Обновите список и повторите."
        case .draftChanged:
            "Черновик изменился. Откройте создание заново и проверьте введённые данные."
        case .storage:
            "Не удалось прочитать или сохранить локальные данные. Проверьте доступ к папке данных и повторите."
        case .unsupportedSchema:
            "Данные созданы более новой версией Steady. Откройте их в обновлённом приложении."
        }
    }
}

final class SQLiteDatabase {
    private var connection: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let result = sqlite3_open_v2(
            url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard result == SQLITE_OK else {
            let error = failure()
            sqlite3_close(connection)
            connection = nil
            throw error
        }
        do {
            try execute("PRAGMA foreign_keys = ON")
            sqlite3_busy_timeout(connection, 1000)
            let version = try statement("PRAGMA user_version") { query in
                guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
                return Int(sqlite3_column_int(query, 0))
            }
            guard version <= 14 else { throw WorkspaceError.unsupportedSchema(version) }
            if version == 0 { try migrateToVersionOne() }
            if version < 2 { try migrateToVersionTwo() }
            if version < 3 { try migrateToVersionThree() }
            if version < 4 { try migrateToVersionFour() }
            if version < 5 { try migrateToVersionFive() }
            if version < 6 { try migrateToVersionSix() }
            if version < 7 { try migrateToVersionSeven() }
            if version < 8 { try migrateToVersionEight() }
            if version < 9 { try migrateToVersionNine() }
            if version < 10 { try migrateToVersionTen() }
            if version < 11 { try migrateToVersionEleven() }
            if version < 12 { try migrateToVersionTwelve() }
            if version < 13 { try migrateToVersionThirteen() }
            if version < 14 { try migrateProfiles() }
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

    private func migrateToVersionThirteen() throws {
        try transaction {
            try execute("CREATE TABLE workspace_preferences (id INTEGER PRIMARY KEY CHECK(id = 1), value TEXT NOT NULL)")
            try execute("PRAGMA user_version = 13")
        }
    }

    func workspacePreferences() throws -> WorkspacePreferences {
        try statement("SELECT value FROM workspace_preferences WHERE id = 1") { query in
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return WorkspacePreferences() }
            guard result == SQLITE_ROW else { throw failure() }
            return try JSONDecoder().decode(WorkspacePreferences.self, from: Data(text(query, 0).utf8))
        }
    }

    func saveWorkspacePreferences(_ preferences: WorkspacePreferences) throws {
        let value = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        try execute("INSERT INTO workspace_preferences (id, value) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET value = excluded.value", [.text(value)])
    }

    private func migrateToVersionTwelve() throws {
        try transaction {
            try execute("ALTER TABLE tasks ADD COLUMN parent_task_id TEXT REFERENCES tasks(id)")
            try execute("ALTER TABLE task_occurrences ADD COLUMN parent_occurrence_id TEXT REFERENCES task_occurrences(id)")
            try execute("CREATE UNIQUE INDEX child_parent_occurrence ON task_occurrences(task_id, parent_occurrence_id) WHERE parent_occurrence_id IS NOT NULL")
            try execute("ALTER TABLE creation_draft ADD COLUMN children BLOB NOT NULL DEFAULT X'5B5D'")
            try execute("PRAGMA user_version = 12")
        }
    }

    private func materializeChildren() throws {
        try statement("SELECT t.id, p.id, p.time_zone FROM tasks t JOIN task_occurrences p ON p.task_id = t.parent_task_id WHERE NOT EXISTS (SELECT 1 FROM task_occurrences c WHERE c.task_id = t.id AND c.parent_occurrence_id = p.id)") { query in
            var result = sqlite3_step(query)
            while result == SQLITE_ROW {
                try execute("INSERT INTO task_occurrences (id, task_id, time_zone, parent_occurrence_id) VALUES (?, ?, ?, ?)", [.text(UUID().uuidString), .text(text(query, 0)), .text(text(query, 2)), .text(text(query, 1))])
                result = sqlite3_step(query)
            }
            guard result == SQLITE_DONE else { throw failure() }
        }
    }

    private func insertChild(_ child: SubtaskDraft, parentID: UUID, at instant: Date, restoringDraft: Bool = false) throws {
        if !restoringDraft { try validateLabels(child.labelIDs) }
        try execute("INSERT INTO tasks (id, title, created_at, priority, note_rtf, note_text, parent_task_id) VALUES (?, ?, ?, 'none', ?, ?, ?)", [.text(child.id.uuidString), .text(child.title.trimmingCharacters(in: .whitespacesAndNewlines)), .number(instant.timeIntervalSince1970), .blob(child.note.rtf), .text(child.note.plainText), .text(parentID.uuidString)])
        try setPomodoroParameters(taskID: child.id, parameters: child.pomodoroParameters)
        for label in child.labelIDs {
            try execute("INSERT INTO task_labels (task_id, label_id) VALUES (?, ?)", [.text(child.id.uuidString), .text(label.uuidString)])
        }
    }

    func addSubtask(parentOccurrenceID: UUID, child: SubtaskDraft, at instant: Date) throws -> [TaskRecord] {
        try transaction {
            guard let parent = try records().first(where: { $0.occurrenceID == parentOccurrenceID }) else { throw WorkspaceError.occurrenceNotFound }
            guard parent.parentTaskID == nil else { throw WorkspaceError.childInheritsParent }
            try insertChild(child, parentID: parent.id, at: instant)
            try materializeChildren()
            return try records()
        }
    }

    private func migrateToVersionTen() throws {
        try transaction {
            try execute("ALTER TABLE task_occurrences ADD COLUMN period_end TEXT")
            try execute("ALTER TABLE task_occurrences ADD COLUMN skipped_at REAL")
            try execute("DROP INDEX occurrence_series_day")
            try execute("CREATE UNIQUE INDEX occurrence_series_day ON task_occurrences(task_id, series_day, COALESCE(period_end, ''))")
            try execute("PRAGMA user_version = 10")
        }
    }

    private func migrateToVersionEight() throws {
        try transaction {
            try execute("CREATE TABLE recurrence_rules (task_id TEXT NOT NULL REFERENCES tasks(id), effective_day TEXT NOT NULL, recurrence TEXT, PRIMARY KEY(task_id, effective_day))")
            try execute("ALTER TABLE task_occurrences ADD COLUMN series_day TEXT")
            try execute("ALTER TABLE task_occurrences ADD COLUMN calendar_frozen INTEGER NOT NULL DEFAULT 0")
            try execute("ALTER TABLE task_occurrences ADD COLUMN individual_override INTEGER NOT NULL DEFAULT 0")
            try execute("CREATE UNIQUE INDEX occurrence_series_day ON task_occurrences(task_id, series_day)")
            try execute("ALTER TABLE creation_draft ADD COLUMN recurrence TEXT")
            try execute("ALTER TABLE creation_draft ADD COLUMN series_start TEXT")
            try execute("PRAGMA user_version = 8")
        }
    }

    private struct RecurrenceRule {
        let day: String
        let recurrence: TaskRecurrence?
    }

    private func encodedRecurrence(_ recurrence: TaskRecurrence?) throws -> Value {
        guard let recurrence else { return .null }
        return .text(String(decoding: try JSONEncoder().encode(recurrence), as: UTF8.self))
    }

    private func decodeRecurrence(_ query: OpaquePointer, _ index: Int32) throws -> TaskRecurrence? {
        guard sqlite3_column_type(query, index) != SQLITE_NULL else { return nil }
        let rule = try JSONDecoder().decode(TaskRecurrence.self, from: Data(text(query, index).utf8))
        try rule.validate()
        return rule
    }

    private func recurrenceRules(taskID: UUID) throws -> [RecurrenceRule] {
        try statement("SELECT effective_day, recurrence FROM recurrence_rules WHERE task_id = ? ORDER BY effective_day", [.text(taskID.uuidString)]) { query in
            var rules: [RecurrenceRule] = []
            var result = sqlite3_step(query)
            while result == SQLITE_ROW {
                rules.append(RecurrenceRule(day: text(query, 0), recurrence: try decodeRecurrence(query, 1)))
                result = sqlite3_step(query)
            }
            guard result == SQLITE_DONE else { throw failure() }
            return rules
        }
    }

    private func insertRule(taskID: UUID, day: String, recurrence: TaskRecurrence?) throws {
        try execute("INSERT INTO recurrence_rules (task_id, effective_day, recurrence) VALUES (?, ?, ?) ON CONFLICT(task_id, effective_day) DO UPDATE SET recurrence = excluded.recurrence", [.text(taskID.uuidString), .text(day), try encodedRecurrence(recurrence)])
    }

    func refreshOccurrences(today: String, timeZone: String, through: String? = nil) throws -> [TaskRecord] {
        try transaction {
            try materialize(today: today, timeZone: timeZone, through: through)
            try materializeChildren()
            return try records()
        }
    }

    private func calendarDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.calendar.timeZone = formatter.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func weekStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: date) + 5) % 7), to: date)!
    }

    /// Calendar dates are enumerated in UTC; local DST cannot skip or repeat a date.
    private func materialize(today: String, timeZone: String, through requested: String?) throws {
        // A prefetched future occurrence adopts the current zone when that period arrives.
        // Historical periods and occurrences with facts keep their original zone.
        try execute("UPDATE task_occurrences SET time_zone = ? WHERE calendar_frozen = 0 AND COALESCE(period_end, series_day) >= ? AND completed_at IS NULL AND NOT EXISTS (SELECT 1 FROM time_tool_runs r WHERE r.occurrence_id = task_occurrences.id)", [.text(timeZone), .text(today)])
        try execute("UPDATE task_occurrences SET calendar_frozen = 1 WHERE series_day <= ?", [.text(today)])
        let ids = try statement("SELECT DISTINCT task_id FROM recurrence_rules") { query in
            var ids: [UUID] = []
            var result = sqlite3_step(query)
            while result == SQLITE_ROW {
                guard let id = UUID(uuidString: text(query, 0)) else { throw failure() }
                ids.append(id)
                result = sqlite3_step(query)
            }
            guard result == SQLITE_DONE else { throw failure() }
            return ids
        }
        let formatter = calendarDayFormatter()
        let calendar = formatter.calendar!
        for id in ids {
            let rules = try recurrenceRules(taskID: id)
            guard let start = rules.first?.day, var date = formatter.date(from: start) else { continue }
            let boundary = max(today, requested ?? today)
            // Every accepted rule has a match within seven calendar days.
            let end = calendar.date(byAdding: .day, value: 7, to: formatter.date(from: max(boundary, start))!)!
            var foundNext = false
            while date <= end {
                let day = formatter.string(from: date)
                let rule = rules.last { $0.day <= day }?.recurrence
                if let rule {
                    let weekly = rule == .weekly
                    let monday = weekStart(date, calendar: calendar)
                    let period = weekly ? formatter.string(from: monday) : day
                    let periodEnd = weekly ? formatter.string(from: calendar.date(byAdding: .day, value: 6, to: monday)!) : nil
                    let matches = weekly ? (day == start || date == monday || rules.contains { $0.day == day }) : rule.weekdays.contains(calendar.component(.weekday, from: date))
                    if matches {
                        if period <= boundary || !foundNext {
                            try execute("INSERT OR IGNORE INTO task_occurrences (id, task_id, planned_day, time_zone, series_day, calendar_frozen, period_end) VALUES (?, ?, ?, ?, ?, ?, ?)", [.text(UUID().uuidString), .text(id.uuidString), weekly ? .null : .text(day), .text(timeZone), .text(period), .number(period <= today ? 1 : 0), periodEnd.map { .text($0) } ?? .null])
                        }
                        if period > boundary { foundNext = true }
                    }
                }
                date = calendar.date(byAdding: .day, value: 1, to: date)!
            }
        }
    }

    func setRecurrence(occurrenceID: UUID, recurrence: TaskRecurrence, today: String, timeZone: String, through: String?) throws -> [TaskRecord] {
        try transaction {
            guard let selected = try records().first(where: { $0.occurrenceID == occurrenceID }) else { throw WorkspaceError.occurrenceNotFound }
            guard selected.parentTaskID == nil else { throw WorkspaceError.childInheritsParent }
            let effective = max(selected.seriesDay ?? selected.plannedDay ?? today, selected.seriesStart ?? "")
            try execute("DELETE FROM recurrence_rules WHERE task_id = ? AND effective_day >= ?", [.text(selected.id.uuidString), .text(effective)])
            try insertRule(taskID: selected.id, day: effective, recurrence: recurrence)
            // Keep matching UUIDs, completed facts, and explicit individual moves.
            let candidates = try records().filter { $0.id == selected.id && (($0.seriesDay ?? $0.plannedDay ?? "") >= effective || $0.occurrenceID == occurrenceID) }
            let formatter = calendarDayFormatter()
            let calendar = formatter.calendar!
            for record in candidates {
                let day = record.seriesDay ?? record.plannedDay ?? effective
                let matches = recurrence == .weekly ? record.periodEnd != nil : (record.periodEnd == nil && recurrence.weekdays.contains(calendar.component(.weekday, from: formatter.date(from: day)!)))
                if !matches {
                    let children = try records().filter { $0.parentOccurrenceID == record.occurrenceID }
                    let protectedChildren = try children.contains { child in
                        if child.completedAt != nil || child.skippedAt != nil { return true }
                        return try statement("SELECT 1 FROM time_tool_runs WHERE occurrence_id = ? LIMIT 1", [.text(child.occurrenceID.uuidString)]) { sqlite3_step($0) == SQLITE_ROW }
                    }
                    let protectedParent = try statement("SELECT 1 FROM task_occurrences o WHERE o.id = ? AND (o.completed_at IS NOT NULL OR o.individual_override = 1 OR EXISTS (SELECT 1 FROM time_tool_runs r WHERE r.occurrence_id = o.id))", [.text(record.occurrenceID.uuidString)]) { sqlite3_step($0) == SQLITE_ROW }
                    if protectedChildren || protectedParent { continue }
                    try execute("DELETE FROM task_occurrences WHERE parent_occurrence_id = ?", [.text(record.occurrenceID.uuidString)])
                    try execute("DELETE FROM task_occurrences WHERE id = ? AND completed_at IS NULL AND individual_override = 0 AND NOT EXISTS (SELECT 1 FROM time_tool_runs r WHERE r.occurrence_id = task_occurrences.id)", [.text(record.occurrenceID.uuidString)])
                } else if record.seriesDay == nil {
                    try execute("UPDATE task_occurrences SET series_day = ?, planned_day = COALESCE(planned_day, ?) WHERE id = ?", [.text(day), .text(day), .text(record.occurrenceID.uuidString)])
                }
            }
            try materialize(today: today, timeZone: timeZone, through: through)
            try materializeChildren()
            return try records()
        }
    }

    private func migrateToVersionFive() throws {
        try transaction {
            try execute("CREATE TABLE task_occurrences_v5 (id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL REFERENCES tasks(id), planned_day TEXT, time_zone TEXT NOT NULL, completed_at REAL)")
            try execute("INSERT INTO task_occurrences_v5 SELECT id, task_id, planned_day, time_zone, completed_at FROM task_occurrences")
            try execute("DROP TABLE task_occurrences")
            try execute("ALTER TABLE task_occurrences_v5 RENAME TO task_occurrences")
            try execute("ALTER TABLE creation_draft ADD COLUMN planned_day TEXT")
            try execute("ALTER TABLE creation_draft ADD COLUMN day_was_chosen INTEGER NOT NULL DEFAULT 0 CHECK(day_was_chosen IN (0, 1))")
            try execute("PRAGMA user_version = 5")
        }
    }

    func setPlannedDay(occurrenceID: UUID, day: String?, timeZone: String, today: String) throws -> [TaskRecord] {
        try transaction {
            guard let record = try records().first(where: { $0.occurrenceID == occurrenceID }) else { throw WorkspaceError.occurrenceNotFound }
            guard record.parentTaskID == nil else { throw WorkspaceError.childInheritsParent }
            if let day, let end = record.periodEnd, let start = record.seriesDay, !(start...end).contains(day) {
                throw WorkspaceError.outsideOccurrenceWeek
            }
            let historicalZone: String? = try statement("""
                SELECT time_zone, calendar_frozen != 0 OR completed_at IS NOT NULL
                    OR planned_day < ? OR COALESCE(period_end, series_day) < ?
                    OR EXISTS (SELECT 1 FROM time_tool_runs r WHERE r.occurrence_id = task_occurrences.id)
                FROM task_occurrences WHERE id = ?
                """, [.text(today), .text(today), .text(occurrenceID.uuidString)]) { query in
                let result = sqlite3_step(query)
                guard result == SQLITE_ROW else {
                    if result == SQLITE_DONE { throw WorkspaceError.occurrenceNotFound }
                    throw failure()
                }
                return sqlite3_column_int(query, 1) != 0 ? text(query, 0) : nil
            }
            try execute("UPDATE task_occurrences SET planned_day = ?, time_zone = ?, calendar_frozen = ?, individual_override = 1 WHERE id = ?", [day.map { .text($0) } ?? .null, .text(historicalZone ?? timeZone), .number(historicalZone == nil ? 0 : 1), .text(occurrenceID.uuidString)])
            return try records()
        }
    }

    private func migrateToVersionSeven() throws {
        try transaction {
            try execute("""
                CREATE TABLE labels (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                    title_key TEXT NOT NULL,
                    color TEXT CHECK(color IN ('purple','blue','green','orange','pink')),
                    created_at REAL NOT NULL,
                    deleted_at REAL,
                    deletion_order INTEGER
                )
                """)
            try execute("CREATE UNIQUE INDEX active_label_title ON labels(title_key) WHERE deleted_at IS NULL")
            try execute("ALTER TABLE creation_draft ADD COLUMN labels_were_chosen INTEGER NOT NULL DEFAULT 0 CHECK(labels_were_chosen IN (0, 1))")
            try execute("CREATE TABLE task_labels (task_id TEXT NOT NULL REFERENCES tasks(id), label_id TEXT NOT NULL REFERENCES labels(id), PRIMARY KEY(task_id, label_id))")
            try execute("CREATE TABLE draft_labels (draft_id INTEGER NOT NULL REFERENCES creation_draft(id) ON DELETE CASCADE, label_id TEXT NOT NULL REFERENCES labels(id), PRIMARY KEY(draft_id, label_id))")
            try execute("PRAGMA user_version = 7")
        }
    }

    func labels() throws -> [LabelRecord] {
        try statement("SELECT id, title, color FROM labels WHERE deleted_at IS NULL ORDER BY created_at, rowid") { query in
            var labels: [LabelRecord] = []
            var result = sqlite3_step(query)
            while result == SQLITE_ROW {
                guard let id = UUID(uuidString: text(query, 0)) else { throw failure() }
                let color = sqlite3_column_type(query, 2) == SQLITE_NULL ? nil : ProjectColor(rawValue: text(query, 2))
                labels.append(LabelRecord(id: id, title: text(query, 1), color: color))
                result = sqlite3_step(query)
            }
            guard result == SQLITE_DONE else { throw failure() }
            return labels
        }
    }

    func lastDeletedLabel() throws -> LabelRecord? {
        try statement("SELECT id, title, color FROM labels WHERE deleted_at IS NOT NULL ORDER BY deletion_order DESC LIMIT 1") { query in
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW, let id = UUID(uuidString: text(query, 0)) else { throw failure() }
            let color = sqlite3_column_type(query, 2) == SQLITE_NULL ? nil : ProjectColor(rawValue: text(query, 2))
            return LabelRecord(id: id, title: text(query, 1), color: color)
        }
    }

    struct LabelState {
        let labels: [LabelRecord]
        let tasks: [TaskRecord]
        let draft: CreationDraft?
        let deleted: LabelRecord?
    }

    private func labelState() throws -> LabelState {
        try LabelState(labels: labels(), tasks: records(), draft: creationDraft(), deleted: lastDeletedLabel())
    }

    func deleteLabel(id: UUID, at instant: Date) throws -> LabelState {
        try transaction {
            guard try labels().contains(where: { $0.id == id }) else { throw WorkspaceError.labelNotFound }
            // Keep hidden associations so Undo restores the same tasks and draft.
            try execute("UPDATE labels SET deleted_at = ?, deletion_order = (SELECT COALESCE(MAX(deletion_order), 0) + 1 FROM labels) WHERE id = ?",
                        [.number(instant.timeIntervalSince1970), .text(id.uuidString)])
            return try labelState()
        }
    }

    func undoLabelDeletion() throws -> LabelState {
        try transaction {
            if let deleted = try lastDeletedLabel() {
                try validateLabelTitle(deleted.title)
                try execute("UPDATE labels SET deleted_at = NULL, deletion_order = NULL WHERE id = ?", [.text(deleted.id.uuidString)])
            }
            return try labelState()
        }
    }

    private func labelTitleKey(_ title: String) -> String {
        title.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private func validateLabelTitle(_ title: String, excluding id: UUID? = nil) throws {
        let key = labelTitleKey(title)
        guard try !labels().contains(where: { $0.id != id && labelTitleKey($0.title) == key }) else {
            throw WorkspaceError.duplicateLabel
        }
    }

    func insertLabel(_ label: LabelRecord, createdAt: Date) throws -> [LabelRecord] {
        try transaction {
            try validateLabelTitle(label.title)
            try execute("INSERT INTO labels (id, title, title_key, color, created_at) VALUES (?, ?, ?, ?, ?)",
                        [.text(label.id.uuidString), .text(label.title), .text(labelTitleKey(label.title)),
                         label.color.map { .text($0.rawValue) } ?? .null, .number(createdAt.timeIntervalSince1970)])
            return try labels()
        }
    }

    func renameLabel(id: UUID, title: String) throws -> [LabelRecord] {
        try transaction {
            guard try labels().contains(where: { $0.id == id }) else { throw WorkspaceError.labelNotFound }
            try validateLabelTitle(title, excluding: id)
            try execute("UPDATE labels SET title = ?, title_key = ? WHERE id = ?", [.text(title), .text(labelTitleKey(title)), .text(id.uuidString)])
            return try labels()
        }
    }

    private func migrateToVersionThree() throws {
        try transaction {
            try execute("""
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                    color TEXT CHECK(color IN ('purple','blue','green','orange','pink')),
                    created_at REAL NOT NULL
                )
                """)
            try execute("ALTER TABLE tasks ADD COLUMN project_id TEXT REFERENCES projects(id)")
            try execute("ALTER TABLE creation_draft ADD COLUMN project_id TEXT REFERENCES projects(id)")
            try execute("ALTER TABLE creation_draft ADD COLUMN project_was_chosen INTEGER NOT NULL DEFAULT 0 CHECK(project_was_chosen IN (0, 1))")
            try execute("PRAGMA user_version = 3")
        }
    }

    func projects() throws -> [ProjectRecord] {
        try statement("SELECT id, title, color FROM projects ORDER BY created_at, rowid") { query in
            var projects: [ProjectRecord] = []
            var result = sqlite3_step(query)
            while result == SQLITE_ROW {
                guard let id = UUID(uuidString: text(query, 0)) else { throw failure() }
                let color = sqlite3_column_type(query, 2) == SQLITE_NULL ? nil : ProjectColor(rawValue: text(query, 2))
                projects.append(ProjectRecord(id: id, title: text(query, 1), color: color))
                result = sqlite3_step(query)
            }
            guard result == SQLITE_DONE else { throw failure() }
            return projects
        }
    }

    func insertProject(_ project: ProjectRecord, createdAt: Date) throws -> [ProjectRecord] {
        try transaction {
            try execute("INSERT INTO projects (id, title, color, created_at) VALUES (?, ?, ?, ?)",
                        [.text(project.id.uuidString), .text(project.title), project.color.map { .text($0.rawValue) } ?? .null,
                         .number(createdAt.timeIntervalSince1970)])
            return try projects()
        }
    }

    func renameProject(id: UUID, title: String) throws -> [ProjectRecord] {
        try transaction {
            guard try projects().contains(where: { $0.id == id }) else { throw WorkspaceError.projectNotFound }
            try execute("UPDATE projects SET title = ? WHERE id = ?", [.text(title), .text(id.uuidString)])
            return try projects()
        }
    }

    func records() throws -> [TaskRecord] {
        try statement("""
            SELECT t.id, o.id, t.title, o.planned_day, o.time_zone, o.completed_at, t.priority, t.project_id, t.note_rtf, t.note_text, o.series_day, o.period_end, o.skipped_at, t.parent_task_id, o.parent_occurrence_id
            FROM tasks t JOIN task_occurrences o ON o.task_id = t.id
            ORDER BY t.created_at, t.rowid, o.planned_day, o.rowid
            """) { query in
            var records: [TaskRecord] = []
            var result = sqlite3_step(query)
            while result == SQLITE_ROW {
                guard let id = UUID(uuidString: text(query, 0)),
                      let occurrenceID = UUID(uuidString: text(query, 1)),
                      let priority = TaskPriority(rawValue: text(query, 6)) else {
                    throw WorkspaceError.storage("Invalid persisted identifier")
                }
                let completedAt = sqlite3_column_type(query, 5) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(query, 5))
                var record = TaskRecord(
                    id: id, occurrenceID: occurrenceID, title: text(query, 2),
                    plannedDay: sqlite3_column_type(query, 3) == SQLITE_NULL ? nil : text(query, 3), timeZoneIdentifier: text(query, 4), completedAt: completedAt,
                    priority: priority, projectID: UUID(uuidString: text(query, 7)),
                    note: TaskNote(rtf: blob(query, 8), plainText: text(query, 9)), labelIDs: try labelIDs(taskID: id)
                )
                record.parentTaskID = UUID(uuidString: text(query, 13))
                record.parentOccurrenceID = UUID(uuidString: text(query, 14))
                let rules = try recurrenceRules(taskID: id)
                record.seriesStart = rules.first?.day
                record.seriesDay = sqlite3_column_type(query, 10) == SQLITE_NULL ? nil : text(query, 10)
                record.skippedAt = sqlite3_column_type(query, 12) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(query, 12))
                record.periodEnd = sqlite3_column_type(query, 11) == SQLITE_NULL ? nil : text(query, 11)
                let day = record.periodEnd ?? max(record.seriesDay ?? record.plannedDay ?? "9999-12-31", rules.first?.day ?? "")
                record.recurrence = rules.last { $0.day <= day }?.recurrence
                records.append(record)
                result = sqlite3_step(query)
            }
            guard result == SQLITE_DONE else { throw failure() }
            let parents = Dictionary(uniqueKeysWithValues: records.filter { $0.parentTaskID == nil }.map { ($0.occurrenceID, $0) })
            return records.map { child in
                guard let parentID = child.parentOccurrenceID, let parent = parents[parentID] else { return child }
                var inherited = TaskRecord(id: child.id, occurrenceID: child.occurrenceID, title: child.title, plannedDay: parent.plannedDay, timeZoneIdentifier: parent.timeZoneIdentifier, completedAt: child.completedAt, priority: child.priority, projectID: parent.projectID, note: child.note, labelIDs: child.labelIDs)
                inherited.parentTaskID = parent.id; inherited.parentOccurrenceID = parentID
                inherited.recurrence = parent.recurrence; inherited.seriesStart = parent.seriesStart
                inherited.seriesDay = parent.seriesDay; inherited.periodEnd = parent.periodEnd; inherited.skippedAt = child.skippedAt
                return inherited
            }
        }
    }

    func insert(_ record: TaskRecord, createdAt: Date, consuming draft: CreationDraft?, today: String, through: String?) throws -> [TaskRecord] {
        try transaction {
            try validateProject(record.projectID)
            try validateLabels(record.labelIDs)
            if let draft, try creationDraft() != draft { throw WorkspaceError.draftChanged }
            try execute(
                "INSERT INTO tasks (id, title, created_at, priority, project_id, note_rtf, note_text) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.text(record.id.uuidString), .text(record.title), .number(createdAt.timeIntervalSince1970),
                 .text(record.priority.rawValue), record.projectID.map { .text($0.uuidString) } ?? .null, .blob(record.note.rtf), .text(record.note.plainText)]
            )
            if let recurrence = record.recurrence, let start = record.seriesStart {
                try insertRule(taskID: record.id, day: start, recurrence: recurrence)
                try materialize(today: today, timeZone: record.timeZoneIdentifier, through: through)
            } else {
                try execute(
                    "INSERT INTO task_occurrences (id, task_id, planned_day, time_zone) VALUES (?, ?, ?, ?)",
                [.text(record.occurrenceID.uuidString), .text(record.id.uuidString),
                 record.plannedDay.map { .text($0) } ?? .null, .text(record.timeZoneIdentifier)]
                )
            }
            for labelID in record.labelIDs {
                try execute("INSERT INTO task_labels (task_id, label_id) VALUES (?, ?)", [.text(record.id.uuidString), .text(labelID.uuidString)])
            }
            if let parameters = draft?.pomodoroParameters { try setPomodoroParameters(taskID: record.id, parameters: parameters) }
            for child in draft == nil ? [] : try rawDraftChildren() { try insertChild(child, parentID: record.id, at: createdAt, restoringDraft: true) }
            try materializeChildren()
            if draft != nil { try execute("DELETE FROM creation_draft") }
            return try records()
        }
    }

    func setCompleted(occurrenceID: UUID, completed: Bool, at instant: Date) throws -> [TaskRecord] {
        try transaction {
            let current = try records()
            guard let record = current.first(where: { $0.occurrenceID == occurrenceID }) else {
                throw WorkspaceError.occurrenceNotFound
            }
            guard (record.completedAt != nil) != completed else { return current }
            if completed, var session = try activeTimeToolSession(), session.occurrenceID == occurrenceID {
                if session.kind == .pomodoro {
                    session.finishPomodoroIfNeeded(at: instant)
                    session.stop(at: instant)
                } else if !session.finishTimerIfNeeded(at: instant) { session.stop(at: instant) }
                try saveTimeToolSession(session)
            }
            let value: Value = completed ? .number(instant.timeIntervalSince1970) : .null
            try execute("UPDATE task_occurrences SET completed_at = ?, skipped_at = NULL WHERE id = ?", [value, .text(occurrenceID.uuidString)])
            return try records()
        }
    }

    func setSkipped(occurrenceID: UUID, skipped: Bool, at instant: Date) throws -> [TaskRecord] {
        try transaction {
            guard let task = try records().first(where: { $0.occurrenceID == occurrenceID }) else { throw WorkspaceError.occurrenceNotFound }
            guard task.periodEnd != nil else { throw WorkspaceError.invalidRecurrence }
            guard (task.skippedAt != nil) != skipped else { return try records() }
            if skipped, try activeTimeToolSession()?.occurrenceID == occurrenceID {
                throw WorkspaceError.activeOwnerRequiresStop
            }
            try execute("UPDATE task_occurrences SET skipped_at = ?, completed_at = NULL, individual_override = 1 WHERE id = ?", [skipped ? .number(instant.timeIntervalSince1970) : .null, .text(occurrenceID.uuidString)])
            return try records()
        }
    }

    func renameTask(id: UUID, title: String) throws -> [TaskRecord] {
        try transaction {
            guard try records().contains(where: { $0.id == id }) else {
                throw WorkspaceError.occurrenceNotFound
            }
            try execute("UPDATE tasks SET title = ? WHERE id = ?", [.text(title), .text(id.uuidString)])
            return try records()
        }
    }

    func setPriority(id: UUID, priority: TaskPriority) throws -> [TaskRecord] {
        try transaction {
            guard try records().contains(where: { $0.id == id }) else {
                throw WorkspaceError.occurrenceNotFound
            }
            try execute("UPDATE tasks SET priority = ? WHERE id = ?", [.text(priority.rawValue), .text(id.uuidString)])
            return try records()
        }
    }

    private func labelIDs(taskID: UUID?) throws -> Set<UUID> {
        let sql = taskID == nil
            ? "SELECT dl.label_id FROM draft_labels dl JOIN labels l ON l.id = dl.label_id WHERE dl.draft_id = 1 AND l.deleted_at IS NULL"
            : "SELECT tl.label_id FROM task_labels tl JOIN labels l ON l.id = tl.label_id WHERE tl.task_id = ? AND l.deleted_at IS NULL"
        return try statement(sql, taskID.map { [.text($0.uuidString)] } ?? []) { query in
            var ids: Set<UUID> = []
            var result = sqlite3_step(query)
            while result == SQLITE_ROW {
                guard let id = UUID(uuidString: text(query, 0)) else { throw failure() }
                ids.insert(id)
                result = sqlite3_step(query)
            }
            guard result == SQLITE_DONE else { throw failure() }
            return ids
        }
    }

    private func validateLabels(_ ids: Set<UUID>) throws {
        guard try ids.isSubset(of: Set(labels().map(\.id))) else { throw WorkspaceError.labelNotFound }
    }

    func setLabels(id: UUID, labelIDs: Set<UUID>) throws -> [TaskRecord] {
        try transaction {
            guard try records().contains(where: { $0.id == id }) else { throw WorkspaceError.occurrenceNotFound }
            try validateLabels(labelIDs)
            try execute("DELETE FROM task_labels WHERE task_id = ?", [.text(id.uuidString)])
            for labelID in labelIDs {
                try execute("INSERT INTO task_labels (task_id, label_id) VALUES (?, ?)", [.text(id.uuidString), .text(labelID.uuidString)])
            }
            return try records()
        }
    }

    private func validateProject(_ projectID: UUID?) throws {
        if let projectID, try !projects().contains(where: { $0.id == projectID }) {
            throw WorkspaceError.projectNotFound
        }
    }

    func setProject(id: UUID, projectID: UUID?) throws -> [TaskRecord] {
        guard try records().first(where: { $0.id == id })?.parentTaskID == nil else { throw WorkspaceError.childInheritsParent }
        return try transaction {
            guard try records().contains(where: { $0.id == id }) else { throw WorkspaceError.occurrenceNotFound }
            try validateProject(projectID)
            try execute("UPDATE tasks SET project_id = ? WHERE id = ?", [projectID.map { .text($0.uuidString) } ?? .null, .text(id.uuidString)])
            return try records()
        }
    }

    func setNote(id: UUID, note: TaskNote) throws -> [TaskRecord] {
        try transaction {
            guard try records().contains(where: { $0.id == id }) else {
                throw WorkspaceError.occurrenceNotFound
            }
            try execute("UPDATE tasks SET note_rtf = ?, note_text = ? WHERE id = ?",
                        [.blob(note.rtf), .text(note.plainText), .text(id.uuidString)])
            return try records()
        }
    }

    private func migrateToVersionFour() throws {
        try transaction {
            for table in ["tasks", "creation_draft"] {
                try execute("ALTER TABLE \(table) ADD COLUMN note_rtf BLOB NOT NULL DEFAULT X''")
                try execute("ALTER TABLE \(table) ADD COLUMN note_text TEXT NOT NULL DEFAULT ''")
            }
            try execute("PRAGMA user_version = 4")
        }
    }

    private func migrateToVersionSix() throws {
        try transaction {
            try execute("""
                CREATE TABLE time_tool_runs (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    task_id TEXT REFERENCES tasks(id),
                    occurrence_id TEXT REFERENCES task_occurrences(id),
                    owner_title TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    time_zone TEXT NOT NULL,
                    stopped_at REAL
                )
                """)
            // Paused sessions also own this slot. SQLite enforces the invariant across windows.
            try execute("CREATE UNIQUE INDEX one_active_time_tool ON time_tool_runs ((1)) WHERE stopped_at IS NULL")
            try execute("""
                CREATE TABLE time_tool_segments (
                    id TEXT PRIMARY KEY NOT NULL,
                    run_id TEXT NOT NULL REFERENCES time_tool_runs(id),
                    position INTEGER NOT NULL,
                    started_at REAL NOT NULL,
                    ended_at REAL CHECK(ended_at >= started_at),
                    UNIQUE(run_id, position)
                )
                """)
            try execute("PRAGMA user_version = 6")
        }
    }

    private func migrateToVersionNine() throws {
        try transaction {
            try execute("ALTER TABLE time_tool_runs ADD COLUMN timer_budget_seconds REAL")
            try execute("ALTER TABLE time_tool_runs ADD COLUMN end_reason TEXT")
            try execute("CREATE TABLE task_timer_settings (task_id TEXT PRIMARY KEY NOT NULL REFERENCES tasks(id), duration_seconds REAL NOT NULL CHECK(duration_seconds > 0))")
            try execute("PRAGMA user_version = 9")
        }
    }

    private func migrateToVersionEleven() throws {
        try transaction {
            try execute("ALTER TABLE time_tool_runs ADD COLUMN pomodoro_state TEXT")
            try execute("CREATE TABLE pomodoro_cycle (id INTEGER PRIMARY KEY CHECK(id = 1), full_intervals INTEGER NOT NULL CHECK(full_intervals >= 0))")
            try execute("INSERT INTO pomodoro_cycle VALUES (1, 0)")
            try execute("PRAGMA user_version = 11")
        }
    }

    func startPomodoro(occurrenceID: UUID?, at instant: Date, timeZone: String) throws {
        try startTimeTool(kind: .pomodoro, occurrenceID: occurrenceID, durationSeconds: nil, at: instant, timeZone: timeZone)
    }

    func timerDurationSeconds(taskID: UUID) throws -> TimeInterval? {
        try statement("SELECT duration_seconds FROM task_timer_settings WHERE task_id = ?", [.text(taskID.uuidString)]) { query in
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw failure() }
            return sqlite3_column_double(query, 0)
        }
    }

    func startTimer(occurrenceID: UUID?, durationSeconds: TimeInterval?, at instant: Date, timeZone: String) throws {
        try startTimeTool(kind: .timer, occurrenceID: occurrenceID, durationSeconds: durationSeconds, at: instant, timeZone: timeZone)
    }

    func startStopwatch(occurrenceID: UUID?, at instant: Date, timeZone: String) throws {
        try startTimeTool(kind: .stopwatch, occurrenceID: occurrenceID, durationSeconds: nil, at: instant, timeZone: timeZone)
    }

    private func startTimeTool(kind: TimeToolKind, occurrenceID: UUID?, durationSeconds: TimeInterval?, at instant: Date, timeZone: String) throws {
        try transaction {
            guard try activeTimeToolSession() == nil else { throw WorkspaceError.sessionOccupied }
            var owner: TaskRecord?
            if let occurrenceID {
                guard let task = try records().first(where: { $0.occurrenceID == occurrenceID }) else {
                    throw WorkspaceError.occurrenceNotFound
                }
                guard task.completedAt == nil else { throw WorkspaceError.completedOwner }
                guard task.skippedAt == nil else { throw WorkspaceError.skippedOwner }
                owner = task
            }
            var duration = durationSeconds
            if kind == .timer {
                if duration == nil, let owner { duration = try timerDurationSeconds(taskID: owner.id) }
                guard let value = duration else { throw WorkspaceError.timerDurationRequired }
                guard value.isFinite, value > 0, value <= TimeToolSession.maximumTimerDurationSeconds else { throw WorkspaceError.invalidTimerDuration }
                if let owner, durationSeconds != nil {
                    try execute("INSERT INTO task_timer_settings (task_id, duration_seconds) VALUES (?, ?) ON CONFLICT(task_id) DO UPDATE SET duration_seconds = excluded.duration_seconds", [.text(owner.id.uuidString), .number(value)])
                }
            }
            var session = TimeToolSession(
                id: UUID(), kind: kind, taskID: owner?.id, occurrenceID: owner?.occurrenceID,
                ownerTitle: owner?.title ?? "Без задачи", startedAt: instant, timeZoneIdentifier: timeZone,
                stoppedAt: nil, segments: [WorkSegment(id: UUID(), startedAt: instant, endedAt: nil)], timerBudgetSeconds: duration
            )
            if kind == .pomodoro {
                let cycleCount = try statement("SELECT full_intervals FROM pomodoro_cycle WHERE id = 1") { query in
                    guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
                    return Int(sqlite3_column_int64(query, 0))
                }
                session.pomodoro = PomodoroState(cycleCount: cycleCount, parameters: try pomodoroParameters(taskID: owner?.id))
            }
            try saveTimeToolSession(session)
        }
    }

    /// Until periodic checkpoints are added, only explicit commands are committed boundaries.
    /// Never charge the open interval (including process absence) after reopening the workspace.
    func restorePausedSession() throws {
        try transaction {
            guard var session = try activeTimeToolSession(), !session.isPaused,
                  let boundary = session.segments.last?.startedAt else { return }
            if session.pomodoro?.stage == .rest {
                let restBoundary = session.pomodoro?.restSegments.last?.startedAt ?? boundary
                session.pomodoro?.closeRest(at: restBoundary)
            } else { session.closeSegment(at: boundary) }
            try saveTimeToolSession(session)
        }
    }

    func savePausedSession(_ session: TimeToolSession) throws {
        try transaction {
            guard try activeTimeToolSession()?.id == session.id else { throw WorkspaceError.sessionOccupied }
            var saved = session
            if saved.kind == .timer, saved.endReason == .natural, let boundary = saved.segments.last?.endedAt {
                saved.stop(at: boundary, reason: .natural)
            }
            try saveTimeToolSession(saved)
        }
    }

    enum SessionCommand { case pause, resume, stop, tick, adjust(Int), startRest, backToWork }

    func changeSession(_ command: SessionCommand, at instant: Date) throws {
        try transaction {
            guard var session = try activeTimeToolSession() else { return }
            if session.kind == .pomodoro {
                try changePomodoro(&session, command: command, at: instant)
                try saveTimeToolSession(session)
                return
            }
            if session.finishTimerIfNeeded(at: instant) {
                try saveTimeToolSession(session)
                return
            }
            switch command {
            case .pause: session.closeSegment(at: instant)
            case .resume:
                guard session.isPaused else { return }
                let start = max(instant, session.segments.last?.endedAt ?? session.startedAt)
                session.segments.append(WorkSegment(id: UUID(), startedAt: start, endedAt: nil))
            case .stop:
                session.stop(at: instant)
            case .tick, .startRest, .backToWork: return
            case .adjust(let minutes):
                try session.adjustRemaining(minutes: minutes, at: instant)
            }
            try saveTimeToolSession(session)
        }
    }

    private func changePomodoro(_ session: inout TimeToolSession, command: SessionCommand, at instant: Date) throws {
        let expired = session.finishPomodoroIfNeeded(at: instant)
        switch command {
        case .stop: session.stop(at: instant)
        case .pause: session.pausePomodoro(at: instant)
        case .resume: session.resumePomodoro(at: instant)
        case .tick: break
        case .startRest: session.startPomodoroRest(at: instant)
        case .backToWork: session.returnToPomodoroWork(at: instant)
        case .adjust(let minutes):
            guard !expired else { return }
            try session.adjustRemaining(minutes: minutes, at: instant)
        }
    }

    func activeTimeToolSession() throws -> TimeToolSession? {
        try timeToolSessions(stopped: false).first
    }

    func timeToolResults() throws -> [TimeToolSession] { try timeToolSessions(stopped: true) }

    private func timeToolSessions(stopped: Bool) throws -> [TimeToolSession] {
        try statement("""
            SELECT id, kind, task_id, occurrence_id, owner_title, started_at, time_zone, stopped_at, timer_budget_seconds, end_reason, pomodoro_state
            FROM time_tool_runs WHERE stopped_at IS \(stopped ? "NOT NULL" : "NULL") ORDER BY started_at, rowid
            """) { query in
            var sessions: [TimeToolSession] = []
            var result = sqlite3_step(query)
            while result == SQLITE_ROW {
                guard let id = UUID(uuidString: text(query, 0)), let kind = TimeToolKind(rawValue: text(query, 1)) else {
                    throw WorkspaceError.storage("Invalid time tool run")
                }
                let segments = try statement("SELECT id, started_at, ended_at FROM time_tool_segments WHERE run_id = ? ORDER BY position", [.text(id.uuidString)]) { segmentQuery in
                    var segments: [WorkSegment] = []
                    var segmentResult = sqlite3_step(segmentQuery)
                    while segmentResult == SQLITE_ROW {
                        guard let segmentID = UUID(uuidString: text(segmentQuery, 0)) else {
                            throw WorkspaceError.storage("Invalid segment identifier")
                        }
                        segments.append(WorkSegment(id: segmentID, startedAt: date(segmentQuery, 1), endedAt: optionalDate(segmentQuery, 2)))
                        segmentResult = sqlite3_step(segmentQuery)
                    }
                    guard segmentResult == SQLITE_DONE else { throw failure() }
                    return segments
                }
                sessions.append(TimeToolSession(
                    id: id, kind: kind, taskID: UUID(uuidString: text(query, 2)),
                    occurrenceID: UUID(uuidString: text(query, 3)), ownerTitle: text(query, 4),
                    startedAt: date(query, 5), timeZoneIdentifier: text(query, 6),
                    stoppedAt: optionalDate(query, 7), segments: segments,
                    timerBudgetSeconds: sqlite3_column_type(query, 8) == SQLITE_NULL ? nil : sqlite3_column_double(query, 8),
                    endReason: TimeToolEndReason(rawValue: text(query, 9)),
                    pomodoro: sqlite3_column_type(query, 10) == SQLITE_NULL ? nil : try decodePomodoro(text(query, 10))
                ))
                result = sqlite3_step(query)
            }
            guard result == SQLITE_DONE else { throw failure() }
            return sessions
        }
    }

    private func saveTimeToolSession(_ session: TimeToolSession) throws {
        try execute("""
            INSERT INTO time_tool_runs (id, kind, task_id, occurrence_id, owner_title, started_at, time_zone, stopped_at, timer_budget_seconds, end_reason, pomodoro_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET stopped_at = excluded.stopped_at, timer_budget_seconds = excluded.timer_budget_seconds, end_reason = excluded.end_reason, pomodoro_state = excluded.pomodoro_state
            """, [.text(session.id.uuidString), .text(session.kind.rawValue),
                  session.taskID.map { .text($0.uuidString) } ?? .null,
                  session.occurrenceID.map { .text($0.uuidString) } ?? .null,
                  .text(session.ownerTitle), .number(session.startedAt.timeIntervalSince1970),
                  .text(session.timeZoneIdentifier), session.stoppedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                  session.timerBudgetSeconds.map { .number($0) } ?? .null,
                  session.endReason.map { .text($0.rawValue) } ?? .null,
                  try session.pomodoro.map { .text(String(decoding: try encodePomodoro($0), as: UTF8.self)) } ?? .null])
        if let state = session.pomodoro {
            try execute("UPDATE pomodoro_cycle SET full_intervals = ? WHERE id = 1", [.number(Double(state.cycleCount))])
        }
        for (position, segment) in session.segments.enumerated() {
            try execute("""
                INSERT INTO time_tool_segments (id, run_id, position, started_at, ended_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET ended_at = excluded.ended_at
                """, [.text(segment.id.uuidString), .text(session.id.uuidString), .number(Double(position)),
                      .number(segment.startedAt.timeIntervalSince1970), segment.endedAt.map { .number($0.timeIntervalSince1970) } ?? .null])
        }
    }

    private func encodePomodoro(_ state: PomodoroState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(state)
    }

    private func decodePomodoro(_ value: String) throws -> PomodoroState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(PomodoroState.self, from: Data(value.utf8))
    }

    private func date(_ query: OpaquePointer, _ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(query, index))
    }

    private func optionalDate(_ query: OpaquePointer, _ index: Int32) -> Date? {
        sqlite3_column_type(query, index) == SQLITE_NULL ? nil : date(query, index)
    }

    private func migrateToVersionTwo() throws {
        try transaction {
            try execute("ALTER TABLE tasks ADD COLUMN priority TEXT NOT NULL DEFAULT 'none' CHECK(priority IN ('none','highest','high','medium','low','lowest'))")
            try execute("""
                CREATE TABLE creation_draft (
                    id INTEGER PRIMARY KEY CHECK(id = 1),
                    title TEXT NOT NULL,
                    priority TEXT NOT NULL CHECK(priority IN ('none','highest','high','medium','low','lowest'))
                )
                """)
            try execute("PRAGMA user_version = 2")
        }
    }

    private func rawDraftChildren() throws -> [SubtaskDraft] {
        try statement("SELECT children FROM creation_draft WHERE id = 1") { query in
            guard sqlite3_step(query) == SQLITE_ROW else { return [] }
            return try JSONDecoder().decode([SubtaskDraft].self, from: blob(query, 0))
        }
    }

    private func visibleDraftChildren(_ children: [SubtaskDraft]) throws -> [SubtaskDraft] {
        let activeIDs = Set(try labels().map(\.id))
        return children.map { child in
            var visible = child
            visible.labelIDs.formIntersection(activeIDs)
            return visible
        }
    }

    func creationDraft() throws -> CreationDraft? {
        try statement("SELECT title, priority, project_id, project_was_chosen, note_rtf, note_text, planned_day, day_was_chosen, recurrence, series_start, labels_were_chosen, children, pomodoro_parameters FROM creation_draft WHERE id = 1") { query in
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW, let priority = TaskPriority(rawValue: text(query, 1)) else {
                throw failure()
            }
            return CreationDraft(title: text(query, 0), priority: priority, projectID: UUID(uuidString: text(query, 2)), projectWasChosen: sqlite3_column_int(query, 3) != 0, plannedDay: sqlite3_column_type(query, 6) == SQLITE_NULL ? nil : text(query, 6), dayWasChosen: sqlite3_column_int(query, 7) != 0, note: TaskNote(rtf: blob(query, 4), plainText: text(query, 5)), labelIDs: try labelIDs(taskID: nil), labelsWereChosen: sqlite3_column_int(query, 10) != 0, recurrence: try decodeRecurrence(query, 8), seriesStart: sqlite3_column_type(query, 9) == SQLITE_NULL ? nil : text(query, 9), children: try visibleDraftChildren(JSONDecoder().decode([SubtaskDraft].self, from: blob(query, 11))), pomodoroParameters: sqlite3_column_type(query, 12) == SQLITE_NULL ? nil : try JSONDecoder().decode(PomodoroParameters.self, from: blob(query, 12)))
        }
    }

    func saveCreationDraft(_ draft: CreationDraft, replacingLabels: Bool, replacingChildLabels: Set<UUID>) throws {
        try transaction {
            try validateProject(draft.projectID)
            try validateLabels(draft.labelIDs)
            let activeIDs = Set(try labels().map(\.id))
            let priorChildren = try rawDraftChildren()
            let persistedChildren = try draft.children.map { child in
                try validateLabels(child.labelIDs)
                var saved = child
                if !replacingChildLabels.contains(child.id), let prior = priorChildren.first(where: { $0.id == child.id }), prior.labelIDs.intersection(activeIDs) == child.labelIDs {
                    saved.labelIDs.formUnion(prior.labelIDs.subtracting(activeIDs))
                }
                return saved
            }
            // Public drafts omit deleted labels; unchanged visible IDs must retain their
            // hidden associations unless the caller explicitly replaces the selection.
            let labelsChanged = try replacingLabels || draft.labelIDs != labelIDs(taskID: nil)
            if draft.isEmpty {
                try execute("DELETE FROM creation_draft")
            } else {
                try execute("""
                    INSERT INTO creation_draft (id, title, priority, project_id, project_was_chosen, note_rtf, note_text, planned_day, day_was_chosen, labels_were_chosen, recurrence, series_start) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET title = excluded.title, priority = excluded.priority, project_id = excluded.project_id, project_was_chosen = excluded.project_was_chosen, note_rtf = excluded.note_rtf, note_text = excluded.note_text, planned_day = excluded.planned_day, day_was_chosen = excluded.day_was_chosen, labels_were_chosen = excluded.labels_were_chosen, recurrence = excluded.recurrence, series_start = excluded.series_start
                    """, [.text(draft.title), .text(draft.priority.rawValue), draft.projectID.map { .text($0.uuidString) } ?? .null, .number(draft.projectWasChosen ? 1 : 0), .blob(draft.note.rtf), .text(draft.note.plainText), draft.plannedDay.map { .text($0) } ?? .null, .number(draft.dayWasChosen ? 1 : 0), .number(draft.labelsWereChosen ? 1 : 0), try encodedRecurrence(draft.recurrence), draft.seriesStart.map { .text($0) } ?? .null])
                try execute("UPDATE creation_draft SET children = ?, pomodoro_parameters = ? WHERE id = 1", [.blob(try JSONEncoder().encode(persistedChildren)), try draft.pomodoroParameters.map { .blob(try JSONEncoder().encode($0)) } ?? .null])
                if labelsChanged {
                    try execute("DELETE FROM draft_labels WHERE draft_id = 1")
                    for labelID in draft.labelIDs {
                        try execute("INSERT INTO draft_labels (draft_id, label_id) VALUES (1, ?)", [.text(labelID.uuidString)])
                    }
                }
            }
        }
    }

    private func migrateToVersionOne() throws {
        try transaction {
            try execute("""
                CREATE TABLE tasks (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                    created_at REAL NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE task_occurrences (
                    id TEXT PRIMARY KEY NOT NULL,
                    task_id TEXT NOT NULL REFERENCES tasks(id),
                    planned_day TEXT NOT NULL,
                    time_zone TEXT NOT NULL,
                    completed_at REAL
                )
                """)
            try execute("PRAGMA user_version = 1")
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private enum Value {
        case text(String)
        case number(Double)
        case blob(Data)
        case null
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        try statement(sql, values) { query in
            guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
        }
    }

    private func statement<T>(_ sql: String, _ values: [Value] = [], _ body: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &prepared, nil) == SQLITE_OK,
              let prepared else { throw failure() }
        defer { sqlite3_finalize(prepared) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                // SQLITE_TRANSIENT copies the UTF-8 string before Swift releases it.
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                result = text.withCString { sqlite3_bind_text(prepared, index, $0, Int32(text.utf8.count), transient) }
            case .blob(let data):
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                result = data.isEmpty ? sqlite3_bind_zeroblob(prepared, index, 0) : data.withUnsafeBytes {
                    sqlite3_bind_blob(prepared, index, $0.baseAddress, Int32($0.count), transient)
                }
            case .number(let number):
                result = sqlite3_bind_double(prepared, index, number)
            case .null:
                result = sqlite3_bind_null(prepared, index)
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        return try body(prepared)
    }

    private func text(_ query: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(query, index) else { return "" }
        let length = Int(sqlite3_column_bytes(query, index))
        return String(decoding: UnsafeBufferPointer(start: value, count: length), as: UTF8.self)
    }

    private func blob(_ query: OpaquePointer, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(query, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, index)))
    }

    private func failure() -> WorkspaceError {
        let message = sqlite3_errmsg(connection).map { String(cString: $0) } ?? "SQLite could not be opened"
        return .storage(message)
    }
}

extension SQLiteDatabase {
    private func migrateProfiles() throws {
        try transaction {
            try execute("CREATE TABLE pomodoro_profiles (id TEXT PRIMARY KEY, title TEXT NOT NULL, parameters BLOB NOT NULL)")
            try execute("CREATE TABLE pomodoro_selection (id INTEGER PRIMARY KEY CHECK(id = 1), profile_id TEXT NOT NULL REFERENCES pomodoro_profiles(id))")
            try execute("CREATE TABLE task_pomodoro_settings (task_id TEXT PRIMARY KEY REFERENCES tasks(id), parameters BLOB NOT NULL)")
            try execute("ALTER TABLE creation_draft ADD COLUMN pomodoro_parameters BLOB")
            let profile = PomodoroProfile(id: UUID(), title: "Обычный", parameters: PomodoroParameters())
            try savePomodoroProfile(profile)
            try selectPomodoroProfile(id: profile.id)
            try execute("PRAGMA user_version = 14")
        }
    }

    func pomodoroProfiles() throws -> [PomodoroProfile] {
        try statement("SELECT id, title, parameters FROM pomodoro_profiles ORDER BY rowid") { query in
            var profiles: [PomodoroProfile] = []
            var result = sqlite3_step(query)
            while result == SQLITE_ROW {
                guard let id = UUID(uuidString: text(query, 0)) else { throw failure() }
                profiles.append(PomodoroProfile(id: id, title: text(query, 1), parameters: try JSONDecoder().decode(PomodoroParameters.self, from: blob(query, 2))))
                result = sqlite3_step(query)
            }
            guard result == SQLITE_DONE else { throw failure() }
            return profiles
        }
    }

    func savePomodoroProfile(_ profile: PomodoroProfile) throws {
        try execute("INSERT INTO pomodoro_profiles VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET title = excluded.title, parameters = excluded.parameters", [.text(profile.id.uuidString), .text(profile.title), .blob(try JSONEncoder().encode(profile.parameters))])
    }

    func selectedPomodoroProfileID() throws -> UUID? {
        try statement("SELECT profile_id FROM pomodoro_selection WHERE id = 1") { query in
            guard sqlite3_step(query) == SQLITE_ROW else { return nil }
            return UUID(uuidString: text(query, 0))
        }
    }

    func selectPomodoroProfile(id: UUID) throws {
        guard try pomodoroProfiles().contains(where: { $0.id == id }) else { throw WorkspaceError.occurrenceNotFound }
        try execute("INSERT INTO pomodoro_selection VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET profile_id = excluded.profile_id", [.text(id.uuidString)])
    }

    func pomodoroOverride(taskID: UUID) throws -> PomodoroParameters? {
        try statement("SELECT parameters FROM task_pomodoro_settings WHERE task_id = ?", [.text(taskID.uuidString)]) { query in
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw failure() }
            return try JSONDecoder().decode(PomodoroParameters.self, from: blob(query, 0))
        }
    }

    func pomodoroParameters(taskID: UUID?) throws -> PomodoroParameters {
        if let taskID {
            guard let task = try records().first(where: { $0.id == taskID }) else { throw WorkspaceError.occurrenceNotFound }
            if let own = try pomodoroOverride(taskID: taskID) { return own }
            if let parent = task.parentTaskID { return try pomodoroParameters(taskID: parent) }
        }
        let selected = try selectedPomodoroProfileID()
        return try pomodoroProfiles().first { $0.id == selected }?.parameters ?? PomodoroParameters()
    }

    func setPomodoroParameters(taskID: UUID, parameters: PomodoroParameters?) throws {
        if let parameters {
            try execute("INSERT INTO task_pomodoro_settings VALUES (?, ?) ON CONFLICT(task_id) DO UPDATE SET parameters = excluded.parameters", [.text(taskID.uuidString), .blob(try JSONEncoder().encode(parameters))])
        } else {
            try execute("DELETE FROM task_pomodoro_settings WHERE task_id = ?", [.text(taskID.uuidString)])
        }
    }
}
