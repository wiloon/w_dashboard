// Color semantics (docs/sdd.md §9 / §11.4 / §12.8), same hex values as app-macos.

using Microsoft.UI;
using Microsoft.UI.Xaml.Media;
using WDashboard.Core;
using Windows.UI;

namespace WDashboard.App.ViewModels;

internal static class Palette
{
    public static readonly Color Green = Color.FromArgb(0xFF, 0x4C, 0xAF, 0x50);
    public static readonly Color Yellow = Color.FromArgb(0xFF, 0xFF, 0xC1, 0x07);
    public static readonly Color Red = Color.FromArgb(0xFF, 0xF4, 0x43, 0x36);
    public static readonly Color Gray = Color.FromArgb(0xFF, 0xB0, 0xB6, 0xBD);
    public static readonly Color Orange = Color.FromArgb(0xFF, 0xFF, 0x98, 0x00);
    public static readonly Color Blue = Color.FromArgb(0xFF, 0x21, 0x96, 0xF3);
    public static readonly Color Amber = Color.FromArgb(0xFF, 0xF5, 0xA6, 0x23);

    public static SolidColorBrush Brush(Color c) => new(c);

    public static Color RepoState(RepoState state) => state switch
    {
        Core.RepoState.Clean => Green,
        Core.RepoState.Dirty or Core.RepoState.NeedsPush or Core.RepoState.NeedsPull => Yellow,
        Core.RepoState.Diverged or Core.RepoState.Error => Red,
        _ => Gray,
    };

    public static Color Pomodoro(PomodoroPhase phase) => phase switch
    {
        PomodoroPhase.Focus => Green,
        PomodoroPhase.Break => Blue,
        PomodoroPhase.FocusEnded => Red,
        PomodoroPhase.BreakEnded => Orange,
        _ => Gray,
    };

    public static Color Health(HealthLevel level) => level switch
    {
        HealthLevel.Good => Green,
        HealthLevel.Fair => Yellow,
        HealthLevel.Poor or HealthLevel.NoInternet => Red,
        HealthLevel.CaptivePortal => Orange,
        _ => Gray,
    };

    public static readonly Color Transparent = Colors.Transparent;

    /// <summary>Theme-aware default text color, for cells that are only colored on error.</summary>
    public static Microsoft.UI.Xaml.Media.Brush TextPrimary =>
        (Microsoft.UI.Xaml.Media.Brush)Microsoft.UI.Xaml.Application.Current.Resources["TextFillColorPrimaryBrush"];
}
