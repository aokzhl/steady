import Foundation
import Observation

public struct TaskRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let occurrenceID: UUID
    public let title: String
    public let plannedDay: String
    public let timeZoneIdentifier: String
    public let completedAt: Date?
}

@MainActor
@Observable
public final class TaskWorkspace {
    public private(set) var tasks: [TaskRecord] = []
    private let database: SQLiteDatabase
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var dayContext: DayContext

    public init(databaseURL: URL, now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current }) throws {
        self.now = now
        self.calendar = calendar
        self.dayContext = DayContext(date: now(), calendar: calendar())
        self.database = try SQLiteDatabase(url: databaseURL)
        self.tasks = try database.records()
    }

    @discardableResult
    public func createTask(title: String) throws -> TaskRecord {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WorkspaceError.emptyTitle }
        guard !title.contains("\0") else { throw WorkspaceError.invalidTitle }
        let createdAt = now()
        let context = DayContext(date: createdAt, calendar: calendar())
        let task = TaskRecord(
            id: UUID(), occurrenceID: UUID(), title: title,
            plannedDay: context.day,
            timeZoneIdentifier: context.timeZone.identifier, completedAt: nil
        )
        tasks = try database.insert(task, createdAt: createdAt)
        dayContext = context
        return task
    }

    public func setCompleted(occurrenceID: UUID, completed: Bool) throws {
        let instant = now()
        tasks = try database.setCompleted(occurrenceID: occurrenceID, completed: completed, at: instant)
        dayContext = DayContext(date: instant, calendar: calendar())
    }

    public var today: String { dayContext.day }

    public var openToday: [TaskRecord] {
        let day = dayContext.day
        return tasks.filter { $0.completedAt == nil && $0.plannedDay <= day }
    }

    public var completedToday: [TaskRecord] {
        let context = dayContext
        return tasks.filter { $0.completedAt.map(context.contains) ?? false }
    }

    public func reload() throws {
        dayContext = DayContext(date: now(), calendar: calendar())
        tasks = try database.records()
    }

    public static func guestDatabaseURL(in baseDirectory: URL? = nil) throws -> URL {
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Steady", isDirectory: true)
        }
        return base.appendingPathComponent("guest", isDirectory: true).appendingPathComponent("steady.sqlite")
    }

    private struct DayContext: Equatable {
        let day: String
        let timeZone: TimeZone

        init(date: Date, calendar: Calendar) {
            timeZone = calendar.timeZone
            day = Self.dayString(for: date, in: timeZone)
        }

        func contains(_ date: Date) -> Bool {
            Self.dayString(for: date, in: timeZone) == day
        }

        private static func dayString(for date: Date, in timeZone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
    }
}
