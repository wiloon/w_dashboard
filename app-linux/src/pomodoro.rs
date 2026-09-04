//! Pomodoro timer pure logic (docs/sdd.md §11, ADR-012).
//!
//! This module is the deterministic core: `pomodoro_reduce` (state machine) and
//! `pomodoro_view` (state -> display data). Both are pure functions locked by the
//! shared test vectors (`docs/test-vectors/pomodoro*/`). The 1s tick, tray icon,
//! notifications and sound live in the UI layer (`main.rs`), never here.

/// After a `*Ended` phase has been unacknowledged for this long, `pomodoro_reduce`
/// returns to `Idle` on its own — the user is assumed to have walked away
/// (docs/sdd.md §11.3 rule 6).
pub const AUTO_STOP_OVERTIME_SECS: i64 = 1800;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PomodoroPhase {
    Idle,
    Focus,
    Break,
    /// Focus time is up, waiting for the user to acknowledge (icon flashes).
    FocusEnded,
    /// Break time is up, waiting for the user to acknowledge (icon flashes).
    BreakEnded,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PomodoroEvent {
    StartFocus,
    StartBreak,
    Stop,
    Tick,
}

/// The single in-memory pomodoro state. Never persisted (ADR-012).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PomodoroState {
    pub phase: PomodoroPhase,
    /// Unix seconds the current `Focus`/`Break` segment started; `None` in `Idle`.
    /// Kept through `*Ended` so overtime can be measured.
    pub phase_started_at: Option<i64>,
    /// Target focus length; the UI writes this from config only while `Idle`, so a
    /// running segment's target is frozen (docs/sdd.md §11.3).
    pub focus_secs: i64,
    pub break_secs: i64,
}

impl PomodoroState {
    /// A fresh idle state with the given segment lengths.
    pub fn idle(focus_secs: i64, break_secs: i64) -> Self {
        PomodoroState {
            phase: PomodoroPhase::Idle,
            phase_started_at: None,
            focus_secs,
            break_secs,
        }
    }
}

/// Display data derived from `state` at `now` (docs/sdd.md §11.2).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PomodoroView {
    pub phase: PomodoroPhase,
    pub remaining_secs: i64,
    pub elapsed_secs: i64,
    pub overtime_secs: i64,
    pub progress: f64,
    pub alerting: bool,
}

/// Display data derived from `state` at `now` (docs/sdd.md §11.2). Pure.
pub fn pomodoro_view(state: &PomodoroState, now: i64) -> PomodoroView {
    let alerting = matches!(
        state.phase,
        PomodoroPhase::FocusEnded | PomodoroPhase::BreakEnded
    );

    let Some(started) = state.phase_started_at else {
        // Only reachable in Idle.
        return PomodoroView {
            phase: state.phase,
            remaining_secs: 0,
            elapsed_secs: 0,
            overtime_secs: 0,
            progress: 0.0,
            alerting,
        };
    };

    let raw = now - started;
    let duration = phase_duration(state);

    match state.phase {
        PomodoroPhase::Idle => PomodoroView {
            phase: state.phase,
            remaining_secs: 0,
            elapsed_secs: 0,
            overtime_secs: 0,
            progress: 0.0,
            alerting,
        },
        PomodoroPhase::Focus | PomodoroPhase::Break => PomodoroView {
            phase: state.phase,
            remaining_secs: (duration - raw).max(0),
            elapsed_secs: raw,
            overtime_secs: 0,
            progress: (raw as f64 / duration as f64).clamp(0.0, 1.0),
            alerting,
        },
        PomodoroPhase::FocusEnded | PomodoroPhase::BreakEnded => PomodoroView {
            phase: state.phase,
            remaining_secs: 0,
            elapsed_secs: duration,
            overtime_secs: (raw - duration).max(0),
            progress: 1.0,
            alerting,
        },
    }
}

/// The frozen target length of the phase's segment: focus side vs break side.
fn phase_duration(state: &PomodoroState) -> i64 {
    match state.phase {
        PomodoroPhase::Focus | PomodoroPhase::FocusEnded => state.focus_secs,
        PomodoroPhase::Break | PomodoroPhase::BreakEnded => state.break_secs,
        PomodoroPhase::Idle => 0,
    }
}

/// State machine (docs/sdd.md §11.3). Pure; reads only `state`, never config.
pub fn pomodoro_reduce(state: PomodoroState, event: PomodoroEvent, now: i64) -> PomodoroState {
    match event {
        PomodoroEvent::StartFocus => PomodoroState {
            phase: PomodoroPhase::Focus,
            phase_started_at: Some(now),
            ..state
        },
        PomodoroEvent::StartBreak => PomodoroState {
            phase: PomodoroPhase::Break,
            phase_started_at: Some(now),
            ..state
        },
        PomodoroEvent::Stop => PomodoroState {
            phase: PomodoroPhase::Idle,
            phase_started_at: None,
            ..state
        },
        PomodoroEvent::Tick => {
            let Some(started) = state.phase_started_at else {
                return state;
            };
            let raw = now - started;
            match state.phase {
                PomodoroPhase::Focus if raw >= state.focus_secs => PomodoroState {
                    phase: PomodoroPhase::FocusEnded,
                    ..state
                },
                PomodoroPhase::Break if raw >= state.break_secs => PomodoroState {
                    phase: PomodoroPhase::BreakEnded,
                    ..state
                },
                PomodoroPhase::FocusEnded | PomodoroPhase::BreakEnded
                    if raw - phase_duration(&state) >= AUTO_STOP_OVERTIME_SECS =>
                {
                    PomodoroState {
                        phase: PomodoroPhase::Idle,
                        phase_started_at: None,
                        ..state
                    }
                }
                _ => state,
            }
        }
    }
}
