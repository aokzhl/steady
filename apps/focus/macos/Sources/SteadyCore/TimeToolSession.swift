import Foundation

public enum TimeToolKind: String, Sendable {
    case stopwatch, timer, pomodoro
}

public enum TimeToolEndReason: String, Sendable {
    case stopped, natural, manual
}

/// A real interval of active work. A nil end belongs only to a running session.
public struct WorkSegment: Identifiable, Codable, Equatable, Sendable {
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
    /// Largest Double seconds count representable by the UI's signed native integer.
    /// This is a numeric representation bound, not a product duration limit.
    public static let maximumTimerDurationSeconds = Double(Int.max).nextDown

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

    public internal(set) var pomodoro: PomodoroState? = nil

    public func remainingSeconds(at instant: Date) -> TimeInterval? {
        if let pomodoro {
            return max(0, pomodoro.focusBudgetSeconds - (elapsedSeconds(at: instant) - pomodoro.focusStartElapsed))
        }
        return timerBudgetSeconds.map { max(0, $0 - elapsedSeconds(at: instant)) }
    }

    public var isPaused: Bool {
        guard stoppedAt == nil else { return false }
        if let pomodoro {
            switch pomodoro.stage {
            case .work: return segments.last?.endedAt != nil
            case .rest: return pomodoro.restSegments.last?.endedAt != nil
            case .waitingBreak, .waitingNext: return false
            }
        }
        return segments.last?.endedAt != nil
    }
    public var durationSeconds: TimeInterval { elapsedSeconds(at: stoppedAt ?? startedAt) }

    public func elapsedSeconds(at instant: Date) -> TimeInterval {
        segments.reduce(0) { $0 + $1.duration(at: instant) }
    }

    mutating func stop(at instant: Date, reason: TimeToolEndReason = .stopped) {
        endReason = reason == .stopped && pomodoro?.focusFinished == true ? (endReason ?? reason) : reason
        closeSegment(at: instant)
        pomodoro?.closeRest(at: instant)
        stoppedAt = max(instant, max(segments.last?.endedAt ?? startedAt, pomodoro?.restSegments.last?.endedAt ?? startedAt))
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

    /// Adjust the current countdown without changing its owner or pause state.
    /// A manual zero ends partial work; only natural Pomodoro expiry awards a full focus.
    mutating func adjustRemaining(minutes: Int, at instant: Date) throws {
        guard (-20...20).contains(minutes) else { throw WorkspaceError.invalidTimerIncrement }
        let budget: TimeInterval
        let elapsed: TimeInterval
        if let state = pomodoro {
            guard state.stage == .work else { return }
            budget = state.focusBudgetSeconds
            elapsed = elapsedSeconds(at: instant) - state.focusStartElapsed
        } else {
            guard kind == .timer, let timerBudgetSeconds else { return }
            budget = timerBudgetSeconds
            elapsed = elapsedSeconds(at: instant)
        }
        let remaining = max(0, budget - elapsed + Double(minutes) * 60)
        let adjustedBudget = elapsed + remaining
        guard adjustedBudget.isFinite, adjustedBudget <= Self.maximumTimerDurationSeconds else {
            throw WorkspaceError.invalidTimerDuration
        }
        if var state = pomodoro {
            state.focusBudgetSeconds = adjustedBudget
            if remaining == 0 {
                closeSegment(at: instant)
                state.focusFinished = true
                state.stage = .waitingBreak
                endReason = .manual
            }
            pomodoro = state
        } else {
            timerBudgetSeconds = adjustedBudget
            if remaining == 0 { stop(at: instant, reason: .manual) }
        }
        if remaining > 0, !isPaused {
            closeSegment(at: instant)
            let start = max(instant, segments.last?.endedAt ?? startedAt)
            segments.append(WorkSegment(id: UUID(), startedAt: start, endedAt: nil))
        }
    }

    mutating func closeSegment(at instant: Date) {
        guard let last = segments.indices.last, segments[last].endedAt == nil else { return }
        segments[last].endedAt = max(segments[last].startedAt, instant)
    }
}

public struct PomodoroParameters: Codable, Equatable, Sendable {
    public let workSeconds: TimeInterval
    public let shortRestSeconds: TimeInterval
    public let longRestSeconds: TimeInterval
    public let longRestAfter: Int
    public let autoBreak: Bool
    public let autoNext: Bool

    public init() {
        workSeconds = 1500
        shortRestSeconds = 300
        longRestSeconds = 900
        longRestAfter = 4
        autoBreak = false
        autoNext = false
    }
}

public enum PomodoroStage: String, Codable, Sendable {
    case work, rest, waitingBreak, waitingNext
}

/// One logical focus survives pauses and early rests. Work always comes from the run's segments.
public struct PomodoroState: Codable, Equatable, Sendable {
    public let parameters: PomodoroParameters
    public internal(set) var focusID: UUID
    public internal(set) var stage: PomodoroStage = .work
    public internal(set) var fullPomodoros = 0
    public internal(set) var cycleCount: Int
    public internal(set) var focusStartElapsed: TimeInterval = 0
    public internal(set) var focusBudgetSeconds: TimeInterval
    public internal(set) var focusFinished = false
    public internal(set) var restSegments: [WorkSegment] = []
    public internal(set) var restStartIndex = 0
    public internal(set) var restIsLong = false

    init(cycleCount: Int) {
        parameters = PomodoroParameters()
        focusID = UUID()
        self.cycleCount = cycleCount
        focusBudgetSeconds = parameters.workSeconds
    }

    func restElapsed(at instant: Date) -> TimeInterval {
        restSegments.dropFirst(restStartIndex).reduce(0) { $0 + $1.duration(at: instant) }
    }

    func restRemaining(at instant: Date) -> TimeInterval {
        max(0, (restIsLong ? parameters.longRestSeconds : parameters.shortRestSeconds) - restElapsed(at: instant))
    }

    mutating func closeRest(at instant: Date) {
        guard let index = restSegments.indices.last, restSegments[index].endedAt == nil else { return }
        restSegments[index].endedAt = max(restSegments[index].startedAt, instant)
    }
}

extension TimeToolSession {
    /// Natural work/rest expiry only changes stage; the run keeps the single active slot.
    @discardableResult
    mutating func finishPomodoroIfNeeded(at instant: Date) -> Bool {
        guard var state = pomodoro, stoppedAt == nil else { return false }
        if state.stage == .work, !isPaused, remainingSeconds(at: instant) == 0,
           let last = segments.last {
            let prior = segments.dropLast().reduce(0) { $0 + $1.duration(at: instant) } - state.focusStartElapsed
            closeSegment(at: last.startedAt.addingTimeInterval(max(0, state.focusBudgetSeconds - prior)))
            endReason = .natural
            state.fullPomodoros += 1
            state.cycleCount += 1
            state.focusFinished = true
            state.stage = .waitingBreak
            pomodoro = state
            return true
        }
        if state.stage == .rest, !isPaused, state.restRemaining(at: instant) == 0,
           let last = state.restSegments.last {
            let duration = state.restIsLong ? state.parameters.longRestSeconds : state.parameters.shortRestSeconds
            let prior = state.restSegments.dropLast().dropFirst(state.restStartIndex).reduce(0) { $0 + $1.duration(at: instant) }
            state.closeRest(at: last.startedAt.addingTimeInterval(max(0, duration - prior)))
            if state.restIsLong { state.cycleCount = 0 }
            state.stage = .waitingNext
            pomodoro = state
            return true
        }
        return false
    }

    mutating func pausePomodoro(at instant: Date) {
        closeSegment(at: instant)
        pomodoro?.closeRest(at: instant)
    }

    mutating func resumePomodoro(at instant: Date) {
        guard var state = pomodoro, isPaused else { return }
        if state.stage == .work {
            let boundary = max(instant, segments.last?.endedAt ?? startedAt)
            segments.append(WorkSegment(id: UUID(), startedAt: boundary, endedAt: nil))
        } else if state.stage == .rest {
            let boundary = max(instant, state.restSegments.last?.endedAt ?? startedAt)
            state.restSegments.append(WorkSegment(id: UUID(), startedAt: boundary, endedAt: nil))
        }
        pomodoro = state
    }

    mutating func startPomodoroRest(at instant: Date) {
        guard var state = pomodoro, state.stage == .work || state.stage == .waitingBreak else { return }
        closeSegment(at: instant)
        state.restIsLong = state.focusFinished && state.cycleCount >= state.parameters.longRestAfter
        state.restStartIndex = state.restSegments.count
        state.restSegments.append(WorkSegment(id: UUID(), startedAt: max(instant, segments.last?.endedAt ?? startedAt), endedAt: nil))
        state.stage = .rest
        pomodoro = state
    }

    mutating func returnToPomodoroWork(at instant: Date) {
        guard var state = pomodoro, state.stage != .work else { return }
        state.closeRest(at: instant)
        // An explicitly skipped long rest also starts a fresh cycle.
        if state.restIsLong || (state.stage == .waitingBreak && state.cycleCount >= state.parameters.longRestAfter) {
            state.cycleCount = 0
        }
        if state.focusFinished {
            state.focusID = UUID()
            state.focusStartElapsed = elapsedSeconds(at: instant)
            state.focusBudgetSeconds = state.parameters.workSeconds
            state.focusFinished = false
        }
        endReason = nil
        state.restIsLong = false
        state.stage = .work
        pomodoro = state
        let boundary = max(instant, max(segments.last?.endedAt ?? startedAt, state.restSegments.last?.endedAt ?? startedAt))
        segments.append(WorkSegment(id: UUID(), startedAt: boundary, endedAt: nil))
    }
}
