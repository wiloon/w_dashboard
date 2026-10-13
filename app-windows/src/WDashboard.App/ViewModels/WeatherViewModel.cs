// Weather section (docs/sdd.md §7.4, §9 item 4). Collected independently of
// the repos; failures degrade to an error line next to the last good report.

using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using WDashboard.Core;

namespace WDashboard.App.ViewModels;

public sealed record WeatherDayRow(string Date, string Icon, string Description, string Max, string Min, string? Precip)
{
    public bool HasPrecip => Precip is not null;
}

public sealed partial class WeatherViewModel : ObservableObject
{
    private static readonly HttpClient Http = new();
    private WeatherConfig? _config;
    private TimeSpan _timeout;
    private int _token;

    public WeatherViewModel(Config config) => UpdateConfig(config);

    public ObservableCollection<WeatherDayRow> Days { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasReport), nameof(Location), nameof(CurrentIcon), nameof(CurrentTemp),
        nameof(CurrentDescription), nameof(ShowLoading), nameof(ShowStandaloneError))]
    public partial WeatherReport? Report { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasError), nameof(ShowLoading), nameof(ShowStandaloneError))]
    public partial string? Error { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowLoading), nameof(ShowStandaloneError), nameof(NotConfigured), nameof(HasReport))]
    public partial bool Configured { get; private set; }

    public bool NotConfigured => !Configured;

    public bool HasReport => Configured && Report is not null;
    public bool HasError => Error is not null;
    public bool ShowStandaloneError => Configured && Report is null && Error is not null;
    public bool ShowLoading => Configured && Report is null && Error is null;

    public string Location => Report?.LocationLabel ?? "";
    public string CurrentIcon => Report is null ? "" : Icon(Report.Current.WeatherCode);
    public string CurrentTemp => Report is null ? "" : Temp(Report.Current.Temperature, Report.TemperatureUnit);
    public string CurrentDescription => Report?.Current.Description ?? "";

    public void UpdateConfig(Config config)
    {
        _config = config.Weather;
        _timeout = config.CommandTimeout;
        Configured = _config is not null;
    }

    public async Task RefreshAsync()
    {
        if (_config is not { } config) return;
        var token = ++_token;
        try
        {
            var report = await Task.Run(() => Weather.FetchAsync(Http, config, _timeout));
            if (token != _token) return;
            Report = report;
            Error = null;
            Days.Clear();
            foreach (var d in report.Daily)
            {
                Days.Add(new WeatherDayRow(
                    d.Date, Icon(d.WeatherCode), d.Description,
                    Temp(d.TempMax, report.TemperatureUnit), Temp(d.TempMin, report.TemperatureUnit),
                    d.PrecipitationProbabilityMax is { } p ? $"precip {p}%" : null));
            }
        }
        catch (WeatherException e)
        {
            if (token == _token) Error = e.Message;
        }
    }

    private static string Temp(double value, string unit) =>
        value.ToString("0.0", CultureInfo.InvariantCulture) + (unit == "fahrenheit" ? "°F" : "°C");

    /// <summary>WMO code → emoji; same grouping as app-macos <c>wmoSymbolName</c>.</summary>
    private static string Icon(int code) => code switch
    {
        0 or 1 => "☀️",
        2 => "⛅",
        3 => "☁️",
        45 or 48 => "🌫️",
        51 or 53 or 55 => "🌦️",
        56 or 57 or 66 or 67 => "🌨️",
        61 or 63 or 65 => "🌧️",
        71 or 73 or 75 or 77 or 85 or 86 => "❄️",
        80 or 81 or 82 => "🌦️",
        95 => "🌩️",
        96 or 99 => "⛈️",
        _ => "☁️",
    };
}
