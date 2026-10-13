namespace WDashboard.Core.Tests;

public class PomodoroVectorTests
{
    public static TheoryData<string> TransitionFiles => Vectors.Files("pomodoro-transition");
    public static TheoryData<string> ViewFiles => Vectors.Files("pomodoro");

    private sealed record TransitionInput(PomodoroState State, PomodoroEvent Event, long Now);

    private sealed record ViewInput(PomodoroPhase Phase, long? PhaseStartedAt, long FocusSecs, long BreakSecs, long Now);

    [Theory]
    [MemberData(nameof(TransitionFiles))]
    public void Transition(string file)
    {
        var v = Vectors.Load<Vector<TransitionInput, PomodoroState>>("pomodoro-transition", file);
        Assert.Equal(v.Expected, Pomodoro.Reduce(v.Input.State, v.Input.Event, v.Input.Now));
    }

    [Theory]
    [MemberData(nameof(ViewFiles))]
    public void View(string file)
    {
        var v = Vectors.Load<Vector<ViewInput, PomodoroView>>("pomodoro", file);
        var i = v.Input;
        var state = new PomodoroState(i.Phase, i.PhaseStartedAt, i.FocusSecs, i.BreakSecs);
        Assert.Equal(v.Expected, Pomodoro.View(state, i.Now));
    }
}
