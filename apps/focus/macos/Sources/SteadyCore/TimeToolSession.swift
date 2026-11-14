import Foundation

public enum TimeToolKind: String, Sendable {
    case stopwatch, timer
}

public enum TimeToolEndReason: String, Sendable {
    case stopped, natural, manual
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

    public internal(set) var timerBudgetSeconds: TimeInterval? = nil
    public internal(set) var endReason: TimeToolEndReason? = nil

    public func remainingSeconds(at instant: Date) -> TimeInterval? {
        timerBudgetSeconds.map { max(0, $0 - elapsedSeconds(at: instant)) }
    }

    public var isPaused: Bool { stoppedAt == nil && segments.last?.endedAt != nil }
    public var durationSeconds: TimeInterval { elapsedSeconds(at: stoppedAt ?? startedAt) }

    public func elapsedSeconds(at instant: Date) -> TimeInterval {
        segments.reduce(0) { $0 + $1.duration(at: instant) }
    }

    mutating func stop(at instant: Date, reason: TimeToolEndReason = .stopped) {
        endReason = reason
        closeSegment(at: instant)
        stoppedAt = max(instant, segments.last?.endedAt ?? startedAt)
    }

    /// Expiry belongs to the actual deadline, even when the UI wakes up late.
    @discardableResult
    mutating func finishTimerIfNeeded(at instant: Date) -> Bool {
        guard kind == .timer, !isPaused, stoppedAt == nil,
              let budget = timerBudgetSeconds, elapsedSeconds(at: instant) >= budget,
              let last = segments.last else { return false }
        let prior = segments.dropLast().reduce(0) { $0 + $1.duration(at: instant) }
        stop(at: last.startedAt.addingTimeInterval(max(0, budget - prior)), reason: .natural)
        return true
    }

    mutating func closeSegment(at instant: Date) {
        guard let last = segments.indices.last, segments[last].endedAt == nil else { return }
        segments[last].endedAt = max(segments[last].startedAt, instant)
    }
}
