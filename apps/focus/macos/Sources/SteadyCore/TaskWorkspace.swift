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
    private let calendar: Calendar

    public init(databaseURL: URL, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) throws {
        self.now = now
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = calendar.timeZone
        self.calendar = localCalendar
        self.database = try SQLiteDatabase(url: databaseURL)
        self.tasks = try database.records()
    }

    @discardableResult
    public func createTask(title: String) throws -> TaskRecord {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WorkspaceError.emptyTitle }
        guard !title.contains("\0") else { throw WorkspaceError.invalidTitle }
        let createdAt = now()
        let task = TaskRecord(
            id: UUID(), occurrenceID: UUID(), title: title,
            plannedDay: dayString(for: createdAt),
            timeZoneIdentifier: calendar.timeZone.identifier, completedAt: nil
        )
        tasks = try database.insert(task, createdAt: createdAt)
        return task
    }

    public func setCompleted(occurrenceID: UUID, completed: Bool) throws {
        tasks = try database.setCompleted(occurrenceID: occurrenceID, completed: completed, at: now())
    }

    public var today: String { dayString(for: now()) }

    public func reload() throws {
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

    private func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
