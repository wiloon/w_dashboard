// Pomodoro panel state (docs/sdd.md §11.4 steps 1, 2, 8). All transitions go
// through WDashboard.Core.Pomodoro; this class owns the 1s tick, the idle
// nudge and the phase-edge events the tray layer listens to.

using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media;
using WDashboard.Core;

namespace WDashboard.App.ViewModels;

public sealed partial class PomodoroViewModel : ObservableObject
{
    private readonly PomodoroConfig _config;
    private readonly DispatcherQueueTimer _timer;
    private PomodoroState _state;

    public PomodoroViewModel(PomodoroConfig config, DispatcherQueue dispatcher)
    {
        _config = config;
        _state = PomodoroState.Idle(config.FocusMinutes * 60L, config.BreakMinutes * 60L);
        View = Pomodoro.View(_state, Now());
        _timer = dispatcher.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(1);
        _timer.Tick += (_, _) => Apply(PomodoroEvent.Tick);
    }

    /// <summary>Raised on every phase change with (previous, current).</summary>
    public event Action<PomodoroPhase, PomodoroPhase>? PhaseChanged;

    /// <summary>Raised when the idle nudge turns on or off.</summary>
    public event Action<bool>? NudgeChanged;

    public bool Enabled => _config.Enabled;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PhaseLabel), nameof(TimeLabel), nameof(ProgressPercent), nameof(AccentBrush),
        nameof(LabelBrush), nameof(BorderBrush), nameof(PrimaryButtonBrush), nameof(PrimaryLabel), nameof(CanStop))]
    public partial PomodoroView View { get; private set; }

    [ObservableProperty]
    public partial bool IdleNudge { get; private set; }

    public PomodoroPhase Phase => View.Phase;

    public string PhaseLabel => View.Phase switch
    {
        PomodoroPhase.Focus => "Focus",
        PomodoroPhase.Break => "Break",
        PomodoroPhase.FocusEnded => "Focus done",
        PomodoroPhase.BreakEnded => "Break done",
        _ => "Idle",
    };

    public string TimeLabel => View.Phase switch
    {
        PomodoroPhase.Focus or PomodoroPhase.Break => MmSs(View.RemainingSecs),
        PomodoroPhase.FocusEnded or PomodoroPhase.BreakEnded => "+" + MmSs(View.OvertimeSecs),
        _ => "--:--",
    };

    public double ProgressPercent => Math.Clamp(View.Progress, 0, 1) * 100;

    public SolidColorBrush AccentBrush => Palette.Brush(Palette.Pomodoro(View.Phase));

    public Brush LabelBrush => View.Alerting ? AccentBrush : Palette.TextPrimary;

    /// <summary>Only <c>*Ended</c> highlights the panel; the idle nudge lives on the tray icon (§11.4 step 8).</summary>
    public SolidColorBrush BorderBrush => Palette.Brush(View.Alerting ? Palette.Pomodoro(View.Phase) : Palette.Transparent);

    public Brush PrimaryButtonBrush => View.Alerting ? AccentBrush : AccentFill;

    private static Brush AccentFill =>
        (Brush)Microsoft.UI.Xaml.Application.Current.Resources["AccentFillColorDefaultBrush"];

    private PomodoroEvent PrimaryEvent =>
        View.Phase is PomodoroPhase.Focus or PomodoroPhase.FocusEnded ? PomodoroEvent.StartBreak : PomodoroEvent.StartFocus;

    public string PrimaryLabel => PrimaryEvent == PomodoroEvent.StartBreak ? "Start break" : "Start focus";

    public bool CanStop => View.Phase != PomodoroPhase.Idle;

    public void Start()
    {
        if (!_config.Enabled) return;
        Apply(PomodoroEvent.Tick);
        _timer.Start();
    }

    public void Stop() => _timer.Stop();

    [RelayCommand]
    private void Primary() => Apply(PrimaryEvent);

    [RelayCommand]
    private void StopPomodoro() => Apply(PomodoroEvent.Stop);

    public void StartFocus() => Apply(PomodoroEvent.StartFocus);

    public void StartBreak() => Apply(PomodoroEvent.StartBreak);

    public void StopSession() => Apply(PomodoroEvent.Stop);

    private void Apply(PomodoroEvent ev)
    {
        var now = Now();
        var previous = _state.Phase;
        _state = Pomodoro.Reduce(_state, ev, now);
        View = Pomodoro.View(_state, now);
        if (_state.Phase != previous) PhaseChanged?.Invoke(previous, _state.Phase);

        var nudge = NudgeActive();
        if (nudge != IdleNudge)
        {
            IdleNudge = nudge;
            NudgeChanged?.Invoke(nudge);
        }
    }

    private bool NudgeActive() =>
        _config.Enabled && _config.IdleNudge && _state.Phase == PomodoroPhase.Idle;

    private static long Now() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    public static string MmSs(long secs)
    {
        var s = Math.Max(0, secs);
        return $"{s / 60}:{s % 60:00}";
    }
}
