// Data model per docs/sdd.md §5. Field-for-field with app-macos Model.swift /
// app-linux model.rs; chezmoi is not implemented on any end yet.

namespace WDashboard.Core;

public enum RepoState { Clean, Dirty, NeedsPush, NeedsPull, Diverged, NoUpstream, Error }

public sealed record RepoStatus
{
    public required string Name { get; init; }
    public required string Path { get; init; }
    public string? Branch { get; init; }
    public string? Upstream { get; init; }
    public int Ahead { get; init; }
    public int Behind { get; init; }
    public int Staged { get; init; }
    public int Modified { get; init; }
    public int Untracked { get; init; }
    public int Conflicted { get; init; }
    public RepoState State { get; init; } = RepoState.Error;
    public long? LastFetchAt { get; init; }
    public string? Error { get; init; }
}

public sealed record WeatherReport(
    string LocationLabel,
    double Latitude,
    double Longitude,
    long FetchedAt,
    WeatherNow Current,
    IReadOnlyList<WeatherDay> Daily,
    string TemperatureUnit);

public sealed record WeatherNow(double Temperature, int WeatherCode, string Description);

public sealed record WeatherDay(
    string Date,
    double TempMax,
    double TempMin,
    int WeatherCode,
    string Description,
    int? PrecipitationProbabilityMax);
