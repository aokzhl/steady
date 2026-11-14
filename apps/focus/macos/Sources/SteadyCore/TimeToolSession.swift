import Foundation

public enum TimeToolKind: String, Sendable {
    case stopwatch
}

/// A real interval of active work. A nil end belongs only to a running session.
public struct WorkSegment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public internal(set) var endedAt: Date?

    func duration(at instant: Date) -> TimeInterval {
        max(0, (endedAt ?? instant).timeIntervalSince(startedAt))
    }
}

/// The run's UUID remains its result identity after stopping. Durations are seconds;
/// start/end instants are stored as numeric UTC epochs, with the historical zone fixed at start.
public struct TimeToolSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: TimeToolKind
    public let taskID: UUID?
    public let occurrenceID: UUID?
    public let ownerTitle: String
    public let startedAt: Date
    public let timeZoneIdentifier: String
    public internal(set) var stoppedAt: Date?
    public internal(set) var segments: [WorkSegment]

    public var isPaused: Bool { stoppedAt == nil && segments.last?.endedAt != nil }
    public var durationSeconds: TimeInterval { elapsedSeconds(at: stoppedAt ?? startedAt) }

    public func elapsedSeconds(at instant: Date) -> TimeInterval {
        segments.reduce(0) { $0 + $1.duration(at: instant) }
    }

    mutating func stop(at instant: Date) {
        closeSegment(at: instant)
        stoppedAt = max(instant, segments.last?.endedAt ?? startedAt)
    }

    mutating func closeSegment(at instant: Date) {
        guard let last = segments.indices.last, segments[last].endedAt == nil else { return }
        segments[last].endedAt = max(segments[last].startedAt, instant)
    }
}
