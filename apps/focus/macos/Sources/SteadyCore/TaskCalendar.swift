import Foundation

public struct TaskCalendarDay: Identifiable, Sendable {
    public let day: String
    public let tasks: [TaskRecord]
    public let isInPeriod: Bool
    public var id: String { day }
}

public struct TaskCalendarResult: Sendable {
    public let month: String
    public let leadingDays: Int
    public let days: [TaskCalendarDay]
    public let undated: [TaskRecord]
    public let weekly: [TaskRecord]
}

