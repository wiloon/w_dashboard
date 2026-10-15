// Pomodoro pure logic (docs/sdd.md §11, ADR-012): the state machine and the
// state -> display derivation, locked by docs/test-vectors/pomodoro/ and
// pomodoro-transition/. The 1s tick, tray icon, notification and sound live in
// the app layer.

namespace WDashboard.Core;

public enum PomodoroPhase { Idle, Focus, Break, FocusEnded, BreakEnded }

public enum PomodoroEvent { StartFocus, StartBreak, Stop, Tick }

/// <summary>
/// The single in-memory pomodoro state, never persisted. <see cref="FocusSecs"/> /
/// <see cref="BreakSecs"/> are written from config only while idle, so a running
/// segment's target is frozen (§11.3).
/// </summary>
public sealed record PomodoroState(PomodoroPhase Phase, long? PhaseStartedAt, long FocusSecs, long BreakSecs)
{
    public static PomodoroState Idle(long focusSecs, long breakSecs) =>
        new(PomodoroPhase.Idle, null, focusSecs, breakSecs);
}

public sealed record PomodoroView(
    PomodoroPhase Phase,
    long RemainingSecs,
    long ElapsedSecs,
    long OvertimeSecs,
    double Progress,
    bool Alerting);

public static class Pomodoro
{
    public static bool IsAlerting(PomodoroPhase phase) =>
        phase is PomodoroPhase.FocusEnded or PomodoroPhase.BreakEnded;

    public static PomodoroState Reduce(PomodoroState state, PomodoroEvent ev, long now)
    {
        switch (ev)
        {
            case PomodoroEvent.StartFocus:
                return state with { Phase = PomodoroPhase.Focus, PhaseStartedAt = now };
            case PomodoroEvent.StartBreak:
                return state with { Phase = PomodoroPhase.Break, PhaseStartedAt = now };
            case PomodoroEvent.Stop:
                return state with { Phase = PomodoroPhase.Idle, PhaseStartedAt = null };
        }

        if (state.PhaseStartedAt is not { } started) return state;
        var raw = now - started;
        return state.Phase switch
        {
            PomodoroPhase.Focus when raw >= state.FocusSecs => state with { Phase = PomodoroPhase.FocusEnded },
            PomodoroPhase.Break when raw >= state.BreakSecs => state with { Phase = PomodoroPhase.BreakEnded },
            // *Ended never times out on its own; it keeps alerting until the user acts (§11.3).
            _ => state,
        };
    }

    public static PomodoroView View(PomodoroState state, long now)
    {
        var alerting = IsAlerting(state.Phase);
        if (state.PhaseStartedAt is not { } started || state.Phase == PomodoroPhase.Idle)
            return new PomodoroView(state.Phase, 0, 0, 0, 0.0, alerting);

        var raw = now - started;
        var duration = Duration(state);
        return state.Phase switch
        {
            PomodoroPhase.Focus or PomodoroPhase.Break => new PomodoroView(
                state.Phase,
                RemainingSecs: Math.Max(0, duration - raw),
                ElapsedSecs: raw,
                OvertimeSecs: 0,
                Progress: Math.Clamp((double)raw / duration, 0.0, 1.0),
                alerting),
            _ => new PomodoroView(
                state.Phase,
                RemainingSecs: 0,
                ElapsedSecs: duration,
                OvertimeSecs: Math.Max(0, raw - duration),
                Progress: 1.0,
                alerting),
        };
    }

    private static long Duration(PomodoroState state) => state.Phase switch
    {
        PomodoroPhase.Focus or PomodoroPhase.FocusEnded => state.FocusSecs,
        PomodoroPhase.Break or PomodoroPhase.BreakEnded => state.BreakSecs,
        _ => 0,
    };
}
