// Pomodoro timer pure logic (docs/sdd.md §11, ADR-012).
//
// `pomodoroReduce` (state machine) and `pomodoroView` (state -> display data) are
// pure functions locked by the shared test vectors (docs/test-vectors/pomodoro*/),
// mirroring app-linux/src/pomodoro.rs. The 1s tick, menu-bar icon, notifications
// and sound live in the app layer (AppState / AppDelegate), not here.

/// After a `*Ended` phase has been unacknowledged for this long, `pomodoroReduce`
/// returns to `.idle` on its own — the user is assumed to have walked away
/// (docs/sdd.md §11.3 rule 6).
public let pomodoroAutoStopOvertimeSecs: Int64 = 1800

public enum PomodoroPhase: String, Equatable, Sendable, Codable {
    case idle = "Idle"
    case focus = "Focus"
    case brk = "Break"
    case focusEnded = "FocusEnded"
    case breakEnded = "BreakEnded"
}

public enum PomodoroEvent: String, Equatable, Sendable, Codable {
    case startFocus = "StartFocus"
    case startBreak = "StartBreak"
    case stop = "Stop"
    case tick = "Tick"
}

/// The single in-memory pomodoro state. Never persisted (ADR-012).
public struct PomodoroState: Equatable, Sendable {
    public var phase: PomodoroPhase
    /// Unix seconds the current `.focus`/`.brk` segment started; `nil` in `.idle`.
    /// Kept through `*Ended` so overtime can be measured.
    public var phaseStartedAt: Int64?
    /// Target focus length; the app writes this from config only while `.idle`, so
    /// a running segment's target is frozen (docs/sdd.md §11.3).
    public var focusSecs: Int64
    public var breakSecs: Int64

    public init(phase: PomodoroPhase, phaseStartedAt: Int64?, focusSecs: Int64, breakSecs: Int64) {
        self.phase = phase
        self.phaseStartedAt = phaseStartedAt
        self.focusSecs = focusSecs
        self.breakSecs = breakSecs
    }

    /// A fresh idle state with the given segment lengths.
    public static func idle(focusSecs: Int64, breakSecs: Int64) -> PomodoroState {
        PomodoroState(phase: .idle, phaseStartedAt: nil, focusSecs: focusSecs, breakSecs: breakSecs)
    }
}

/// Display data derived from a `PomodoroState` at `now` (docs/sdd.md §11.2).
public struct PomodoroView: Equatable, Sendable {
    public var phase: PomodoroPhase
    public var remainingSecs: Int64
    public var elapsedSecs: Int64
    public var overtimeSecs: Int64
    public var progress: Double
    public var alerting: Bool

    public init(
        phase: PomodoroPhase, remainingSecs: Int64, elapsedSecs: Int64,
        overtimeSecs: Int64, progress: Double, alerting: Bool
    ) {
        self.phase = phase
        self.remainingSecs = remainingSecs
        self.elapsedSecs = elapsedSecs
        self.overtimeSecs = overtimeSecs
        self.progress = progress
        self.alerting = alerting
    }
}

/// The frozen target length of the phase's segment: focus side vs break side.
private func phaseDuration(_ state: PomodoroState) -> Int64 {
    switch state.phase {
    case .focus, .focusEnded: return state.focusSecs
    case .brk, .breakEnded: return state.breakSecs
    case .idle: return 0
    }
}

private func isAlerting(_ phase: PomodoroPhase) -> Bool {
    phase == .focusEnded || phase == .breakEnded
}

/// State machine (docs/sdd.md §11.3). Pure; reads only `state`, never config.
public func pomodoroReduce(_ state: PomodoroState, _ event: PomodoroEvent, now: Int64) -> PomodoroState {
    var next = state
    switch event {
    case .startFocus:
        next.phase = .focus
        next.phaseStartedAt = now
    case .startBreak:
        next.phase = .brk
        next.phaseStartedAt = now
    case .stop:
        next.phase = .idle
        next.phaseStartedAt = nil
    case .tick:
        guard let started = state.phaseStartedAt else { return state }
        let raw = now - started
        switch state.phase {
        case .focus where raw >= state.focusSecs:
            next.phase = .focusEnded
        case .brk where raw >= state.breakSecs:
            next.phase = .breakEnded
        case .focusEnded, .breakEnded:
            guard raw - phaseDuration(state) >= pomodoroAutoStopOvertimeSecs else { return state }
            next.phase = .idle
            next.phaseStartedAt = nil
        default:
            return state
        }
    }
    return next
}

/// Display data derived from `state` at `now` (docs/sdd.md §11.2). Pure.
public func pomodoroView(_ state: PomodoroState, now: Int64) -> PomodoroView {
    let alerting = isAlerting(state.phase)

    guard let started = state.phaseStartedAt else {
        // Only reachable in .idle.
        return PomodoroView(
            phase: state.phase, remainingSecs: 0, elapsedSecs: 0,
            overtimeSecs: 0, progress: 0.0, alerting: alerting)
    }

    let raw = now - started
    let duration = phaseDuration(state)

    switch state.phase {
    case .idle:
        return PomodoroView(
            phase: state.phase, remainingSecs: 0, elapsedSecs: 0,
            overtimeSecs: 0, progress: 0.0, alerting: alerting)
    case .focus, .brk:
        return PomodoroView(
            phase: state.phase,
            remainingSecs: max(0, duration - raw),
            elapsedSecs: raw,
            overtimeSecs: 0,
            progress: min(1.0, max(0.0, Double(raw) / Double(duration))),
            alerting: alerting)
    case .focusEnded, .breakEnded:
        return PomodoroView(
            phase: state.phase,
            remainingSecs: 0,
            elapsedSecs: duration,
            overtimeSecs: max(0, raw - duration),
            progress: 1.0,
            alerting: alerting)
    }
}
