namespace WDashboard.App.ViewModels;

/// <summary>Beijing wall clock (<c>Asia/Shanghai</c>), used by the tray tooltip.</summary>
internal static class Beijing
{
    private static readonly TimeZoneInfo Zone = TimeZoneInfo.FindSystemTimeZoneById("Asia/Shanghai");

    public static DateTime Now => TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, Zone).DateTime;
}
