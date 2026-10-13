// Timezone clocks (docs/sdd.md §9 item 1, ADR-006): re-rendered every second.

using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using WDashboard.Core;

namespace WDashboard.App.ViewModels;

public sealed partial class ClockRow(string label, TimeZoneInfo zone) : ObservableObject
{
    public string Label { get; } = label;

    [ObservableProperty]
    public partial string Time { get; private set; } = "";

    [ObservableProperty]
    public partial string Date { get; private set; } = "";

    public void Update(DateTimeOffset now)
    {
        var local = TimeZoneInfo.ConvertTime(now, zone);
        Time = local.ToString("HH:mm:ss", CultureInfo.InvariantCulture);
        Date = local.ToString("yyyy-MM-dd (ddd)", CultureInfo.InvariantCulture);
    }
}

public sealed class ClocksViewModel
{
    public ClocksViewModel(IEnumerable<ClockConfig> clocks) => Reset(clocks);

    public void Reset(IEnumerable<ClockConfig> clocks)
    {
        Rows.Clear();
        foreach (var c in clocks)
        {
            var zone = TimeZoneInfo.TryFindSystemTimeZoneById(c.Tz, out var z) ? z : TimeZoneInfo.Utc;
            Rows.Add(new ClockRow(c.Label, zone));
        }
        Tick();
    }

    public ObservableCollection<ClockRow> Rows { get; } = [];

    public void Tick()
    {
        var now = DateTimeOffset.UtcNow;
        foreach (var row in Rows) row.Update(now);
    }
}
