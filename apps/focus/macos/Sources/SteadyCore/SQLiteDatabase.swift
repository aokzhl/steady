import CSQLite
import Foundation

public enum WorkspaceError: Error, Equatable, LocalizedError {
    case invalidDay
    case emptyTitle
    case invalidTitle
    case projectNotFound
    case occurrenceNotFound
    case draftChanged
    case storage(String)
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDay:
            "Выберите существующую календарную дату."
        case .emptyTitle:
            "Введите название задачи."
        case .invalidTitle:
            "Название содержит недопустимый символ. Удалите его и повторите."
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
            guard version <= 5 else { throw WorkspaceError.unsupportedSchema(version) }
            if version == 0 { try migrateToVersionOne() }
            if version < 2 { try migrateToVersionTwo() }
            if version < 3 { try migrateToVersionThree() }
            if version < 4 { try migrateToVersionFour() }
            if version < 5 { try migrateToVersionFive() }
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

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

    func setPlannedDay(occurrenceID: UUID, day: String?, timeZone: String) throws -> [TaskRecord] {
        try transaction {
            guard try records().contains(where: { $0.occurrenceID == occurrenceID }) else { throw WorkspaceError.occurrenceNotFound }
            try execute("UPDATE task_occurrences SET planned_day = ?, time_zone = ? WHERE id = ?", [day.map { .text($0) } ?? .null, .text(timeZone), .text(occurrenceID.uuidString)])
            return try records()
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
            SELECT t.id, o.id, t.title, o.planned_day, o.time_zone, o.completed_at, t.priority, t.project_id, t.note_rtf, t.note_text
            FROM tasks t JOIN task_occurrences o ON o.task_id = t.id
            ORDER BY t.created_at, t.rowid
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
                records.append(TaskRecord(
                    id: id, occurrenceID: occurrenceID, title: text(query, 2),
                    plannedDay: sqlite3_column_type(query, 3) == SQLITE_NULL ? nil : text(query, 3), timeZoneIdentifier: text(query, 4), completedAt: completedAt,
                    priority: priority, projectID: UUID(uuidString: text(query, 7)),
                    note: TaskNote(rtf: blob(query, 8), plainText: text(query, 9))
                ))
                result = sqlite3_step(query)
            }
            guard result == SQLITE_DONE else { throw failure() }
            return records
        }
    }

    func insert(_ record: TaskRecord, createdAt: Date, consuming draft: CreationDraft?) throws -> [TaskRecord] {
        try transaction {
            try validateProject(record.projectID)
            if let draft, try creationDraft() != draft { throw WorkspaceError.draftChanged }
            try execute(
                "INSERT INTO tasks (id, title, created_at, priority, project_id, note_rtf, note_text) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.text(record.id.uuidString), .text(record.title), .number(createdAt.timeIntervalSince1970),
                 .text(record.priority.rawValue), record.projectID.map { .text($0.uuidString) } ?? .null, .blob(record.note.rtf), .text(record.note.plainText)]
            )
            try execute(
                "INSERT INTO task_occurrences (id, task_id, planned_day, time_zone) VALUES (?, ?, ?, ?)",
                [.text(record.occurrenceID.uuidString), .text(record.id.uuidString),
                 record.plannedDay.map { .text($0) } ?? .null, .text(record.timeZoneIdentifier)]
            )
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
            let value: Value = completed ? .number(instant.timeIntervalSince1970) : .null
            try execute("UPDATE task_occurrences SET completed_at = ? WHERE id = ?", [value, .text(occurrenceID.uuidString)])
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

    private func validateProject(_ projectID: UUID?) throws {
        if let projectID, try !projects().contains(where: { $0.id == projectID }) {
            throw WorkspaceError.projectNotFound
        }
    }

    func setProject(id: UUID, projectID: UUID?) throws -> [TaskRecord] {
        try transaction {
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

    func creationDraft() throws -> CreationDraft? {
        try statement("SELECT title, priority, project_id, project_was_chosen, note_rtf, note_text, planned_day, day_was_chosen FROM creation_draft WHERE id = 1") { query in
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW, let priority = TaskPriority(rawValue: text(query, 1)) else {
                throw failure()
            }
            return CreationDraft(title: text(query, 0), priority: priority, projectID: UUID(uuidString: text(query, 2)), projectWasChosen: sqlite3_column_int(query, 3) != 0, plannedDay: sqlite3_column_type(query, 6) == SQLITE_NULL ? nil : text(query, 6), dayWasChosen: sqlite3_column_int(query, 7) != 0, note: TaskNote(rtf: blob(query, 4), plainText: text(query, 5)))
        }
    }

    func saveCreationDraft(_ draft: CreationDraft) throws {
        try transaction {
            try validateProject(draft.projectID)
            if draft.isEmpty {
                try execute("DELETE FROM creation_draft")
            } else {
                try execute("""
                    INSERT INTO creation_draft (id, title, priority, project_id, project_was_chosen, note_rtf, note_text, planned_day, day_was_chosen) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET title = excluded.title, priority = excluded.priority, project_id = excluded.project_id, project_was_chosen = excluded.project_was_chosen, note_rtf = excluded.note_rtf, note_text = excluded.note_text, planned_day = excluded.planned_day, day_was_chosen = excluded.day_was_chosen
                    """, [.text(draft.title), .text(draft.priority.rawValue), draft.projectID.map { .text($0.uuidString) } ?? .null, .number(draft.projectWasChosen ? 1 : 0), .blob(draft.note.rtf), .text(draft.note.plainText), draft.plannedDay.map { .text($0) } ?? .null, .number(draft.dayWasChosen ? 1 : 0)])
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
