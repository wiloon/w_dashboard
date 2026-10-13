// Config loading per docs/sdd.md §4 / §11 / §12.2. `[chezmoi]` is accepted but
// ignored, matching the other ends (that panel isn't implemented anywhere yet).

using System.Globalization;
using Tomlyn;
using Tomlyn.Model;

namespace WDashboard.Core;

public enum ConfigErrorKind { Io, Parse }

public sealed class ConfigException(ConfigErrorKind kind, string detail) : Exception(
    kind == ConfigErrorKind.Io ? $"failed to read config: {detail}" : $"failed to parse config: {detail}")
{
    public ConfigErrorKind Kind { get; } = kind;
    public string Detail { get; } = detail;
}

/// <summary><see cref="Path"/> is already expanded (§4); the raw text stays in the file.</summary>
public sealed record RepoConfig(string Path, string? Name);

public sealed record ClockConfig(string Label, string Tz);

public sealed record WeatherConfig(
    string? Location,
    double? Latitude,
    double? Longitude,
    string TemperatureUnit,
    int ForecastDays);

public sealed record PomodoroConfig
{
    public bool Enabled { get; init; } = true;
    public int FocusMinutes { get; init; } = 25;
    public int BreakMinutes { get; init; } = 5;
    public bool Notify { get; init; } = true;
    public bool Sound { get; init; } = true;
    public bool MorningNudge { get; init; } = true;
    /// <summary>Beijing time of day, minutes since midnight (<c>morning_nudge_after</c>).</summary>
    public int MorningNudgeAfterMinutes { get; init; } = 9 * 60;
}

public sealed record NetworkTarget(
    string Label,
    ProbeGroup Group,
    ProbeMethod Method,
    string? Url = null,
    string? Host = null,
    int? Port = null)
{
    /// <summary>URL for <c>http</c>, <c>host:port</c> for <c>tcp</c>.</summary>
    public string DisplayTarget => Method == ProbeMethod.Tcp ? $"{Host}:{Port}" : Url ?? "";
}

public sealed record NetworkConfig
{
    public bool Enabled { get; init; } = true;
    public int ProbeIntervalSecs { get; init; } = 60;
    public int ProbeSamples { get; init; } = 10;
    public int ProbeTimeoutMs { get; init; } = 2000;
    public int SpeedtestMaxSecs { get; init; } = 8;
    public int SpeedtestMaxMb { get; init; } = 25;
    public string SpeedtestDomesticDownloadUrl { get; init; } = "https://mensura.cdn-apple.com/api/v1/gm/large";
    public string SpeedtestDomesticUploadUrl { get; init; } = "https://mensura.cdn-apple.com/api/v1/gm/slurp";
    public string SpeedtestOverseasDownloadUrl { get; init; } = "https://speed.cloudflare.com/__down?bytes=25000000";
    public string SpeedtestOverseasUploadUrl { get; init; } = "https://speed.cloudflare.com/__up";
    public IReadOnlyList<NetworkTarget> Targets { get; init; } = DefaultTargets;

    /// <summary>Used when the file has no <c>[[network_targets]]</c> (§4 / §12.2).</summary>
    public static readonly IReadOnlyList<NetworkTarget> DefaultTargets =
    [
        new("AliDNS", ProbeGroup.Domestic, ProbeMethod.Http, Url: "https://223.5.5.5/"),
        new("Baidu", ProbeGroup.Domestic, ProbeMethod.Http, Url: "https://www.baidu.com/favicon.ico"),
        new("Cloudflare", ProbeGroup.Overseas, ProbeMethod.Http, Url: "https://1.1.1.1/cdn-cgi/trace"),
        new("GitHub", ProbeGroup.Overseas, ProbeMethod.Http, Url: "https://github.com/robots.txt"),
        new("Home", ProbeGroup.Home, ProbeMethod.Tcp, Host: "home.wiloon.com", Port: 443),
    ];
}

public sealed record Config
{
    public int RefreshIntervalSecs { get; init; } = 900;
    public int CommandTimeoutSecs { get; init; } = 20;
    public bool FetchRemote { get; init; } = true;
    public IReadOnlyList<RepoConfig> Repos { get; init; } = [];
    public IReadOnlyList<ClockConfig> Clocks { get; init; } = DefaultClocks;
    public WeatherConfig? Weather { get; init; }
    public PomodoroConfig Pomodoro { get; init; } = new();
    public NetworkConfig Network { get; init; } = new();

    public TimeSpan CommandTimeout => TimeSpan.FromSeconds(CommandTimeoutSecs);

    public static readonly IReadOnlyList<ClockConfig> DefaultClocks =
    [
        new("Beijing", "Asia/Shanghai"),
        new("New York", "America/New_York"),
    ];
}

public static class ConfigLoader
{
    /// <summary>
    /// Load and validate config (§4). A missing file returns the built-in defaults.
    /// </summary>
    /// <exception cref="ConfigException">Unreadable file, invalid TOML or an invalid value.</exception>
    public static Config Load(string? path = null)
    {
        path ??= Paths.DefaultConfigPath();
        var text = ReadIfExists(path);
        return text is null ? new Config() : Parse(text);
    }

    internal static string? ReadIfExists(string path)
    {
        if (!File.Exists(path)) return null;
        try
        {
            // ReadAllText detects and strips a UTF-8 BOM.
            return File.ReadAllText(path, System.Text.Encoding.UTF8);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new ConfigException(ConfigErrorKind.Io, e.Message);
        }
    }

    public static Config Parse(string text)
    {
        TomlTable doc;
        try
        {
            doc = TomlSerializer.Deserialize<TomlTable>(text) ?? new TomlTable();
        }
        catch (TomlException e)
        {
            throw new ConfigException(ConfigErrorKind.Parse, e.Message);
        }

        var general = Table(doc, "general") ?? new TomlTable();

        var repos = TableArray(doc, "repos")
            .Select(r => new RepoConfig(Paths.Expand(Str(r, "path") ?? ""), Str(r, "name")))
            .ToList();

        IReadOnlyList<ClockConfig> clocks = Config.DefaultClocks;
        if (doc.ContainsKey("clocks"))
        {
            var parsed = new List<ClockConfig>();
            foreach (var raw in TableArray(doc, "clocks"))
            {
                var label = Str(raw, "label") ?? "";
                var tz = Str(raw, "tz") ?? "";
                if (!TimeZoneInfo.TryFindSystemTimeZoneById(tz, out _))
                    throw Error($"clocks: invalid IANA tz id \"{tz}\" for label \"{label}\"");
                parsed.Add(new ClockConfig(label, tz));
            }
            clocks = parsed;
        }

        return new Config
        {
            RefreshIntervalSecs = Int(general, "refresh_interval_secs") ?? 900,
            CommandTimeoutSecs = Int(general, "command_timeout_secs") ?? 20,
            FetchRemote = Bool(general, "fetch_remote") ?? true,
            Repos = repos,
            Clocks = clocks,
            Weather = ParseWeather(Table(doc, "weather")),
            Pomodoro = ParsePomodoro(Table(doc, "pomodoro") ?? new TomlTable()),
            Network = ParseNetwork(Table(doc, "network") ?? new TomlTable(), TableArray(doc, "network_targets")),
        };
    }

    private static WeatherConfig? ParseWeather(TomlTable? raw)
    {
        if (raw is null) return null;
        var location = Str(raw, "location");
        var latitude = Double(raw, "latitude");
        var longitude = Double(raw, "longitude");
        if (string.IsNullOrEmpty(location) && (latitude is null || longitude is null))
            throw Error("weather: requires either `location` or both `latitude` and `longitude`");
        var unit = Str(raw, "temperature_unit") ?? "celsius";
        if (unit is not ("celsius" or "fahrenheit"))
            throw Error($"weather.temperature_unit: must be \"celsius\" or \"fahrenheit\", got \"{unit}\"");
        return new WeatherConfig(location, latitude, longitude, unit, Int(raw, "forecast_days") ?? 5);
    }

    private static PomodoroConfig ParsePomodoro(TomlTable raw)
    {
        var d = new PomodoroConfig();

        int Minutes(string field, int fallback)
        {
            if (Int(raw, field) is not { } n) return fallback;
            if (n <= 0) throw Error($"pomodoro.{field}: must be a positive number of minutes, got {n}");
            return n;
        }

        int HhMm(string field, int fallback)
        {
            if (Str(raw, field) is not { } s) return fallback;
            var parts = s.Split(':');
            if (parts.Length == 2
                && int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var h)
                && int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var m)
                && h is >= 0 and < 24 && m is >= 0 and < 60)
            {
                return h * 60 + m;
            }
            throw Error($"pomodoro.{field}: must be a \"HH:MM\" 24-hour time, got \"{s}\"");
        }

        return new PomodoroConfig
        {
            Enabled = Bool(raw, "enabled") ?? d.Enabled,
            FocusMinutes = Minutes("focus_minutes", d.FocusMinutes),
            BreakMinutes = Minutes("break_minutes", d.BreakMinutes),
            Notify = Bool(raw, "notify") ?? d.Notify,
            Sound = Bool(raw, "sound") ?? d.Sound,
            MorningNudge = Bool(raw, "morning_nudge") ?? d.MorningNudge,
            MorningNudgeAfterMinutes = HhMm("morning_nudge_after", d.MorningNudgeAfterMinutes),
        };
    }

    private static NetworkConfig ParseNetwork(TomlTable raw, IReadOnlyList<TomlTable> rawTargets)
    {
        var d = new NetworkConfig();

        int RangedInt(string field, int fallback, int min, int max)
        {
            if (!raw.TryGetValue(field, out var value)) return fallback;
            if (value is long n && n >= min && n <= max) return (int)n;
            throw Error($"network.{field}: must be an integer in {min}...{max}");
        }

        string HttpUrl(string field, string fallback)
        {
            if (!raw.TryGetValue(field, out var value)) return fallback;
            if (value is string s && IsHttpUrl(s)) return s;
            throw Error($"network.{field}: must be an http(s) URL");
        }

        var targets = rawTargets.Count == 0
            ? NetworkConfig.DefaultTargets
            : rawTargets.Select(ParseNetworkTarget).ToList();

        return new NetworkConfig
        {
            Enabled = Bool(raw, "enabled") ?? d.Enabled,
            ProbeIntervalSecs = RangedInt("probe_interval_secs", d.ProbeIntervalSecs, 0, 86_400),
            ProbeSamples = RangedInt("probe_samples", d.ProbeSamples, 1, 50),
            ProbeTimeoutMs = RangedInt("probe_timeout_ms", d.ProbeTimeoutMs, 100, 10_000),
            SpeedtestMaxSecs = RangedInt("speedtest_max_secs", d.SpeedtestMaxSecs, 1, 600),
            SpeedtestMaxMb = RangedInt("speedtest_max_mb", d.SpeedtestMaxMb, 1, 10_000),
            SpeedtestDomesticDownloadUrl = HttpUrl("speedtest_domestic_download_url", d.SpeedtestDomesticDownloadUrl),
            SpeedtestDomesticUploadUrl = HttpUrl("speedtest_domestic_upload_url", d.SpeedtestDomesticUploadUrl),
            SpeedtestOverseasDownloadUrl = HttpUrl("speedtest_overseas_download_url", d.SpeedtestOverseasDownloadUrl),
            SpeedtestOverseasUploadUrl = HttpUrl("speedtest_overseas_upload_url", d.SpeedtestOverseasUploadUrl),
            Targets = targets,
        };
    }

    private static NetworkTarget ParseNetworkTarget(TomlTable raw, int index)
    {
        var at = $"network_targets[{index}]";
        if (Str(raw, "label") is not { Length: > 0 } label) throw Error($"{at}.label: required");

        var groupRaw = Str(raw, "group") ?? "";
        var group = groupRaw switch
        {
            "domestic" => ProbeGroup.Domestic,
            "overseas" => ProbeGroup.Overseas,
            "home" => ProbeGroup.Home,
            _ => throw Error($"{at}.group: must be \"domestic\", \"overseas\" or \"home\", got \"{groupRaw}\""),
        };

        var methodRaw = Str(raw, "method") ?? "http";
        switch (methodRaw)
        {
            case "http":
                if (Str(raw, "url") is not { } url || !IsHttpUrl(url))
                    throw Error($"{at}.url: method \"http\" requires an http(s) `url`");
                return new NetworkTarget(label, group, ProbeMethod.Http, Url: url);
            case "tcp":
                if (Str(raw, "host") is not { Length: > 0 } host)
                    throw Error($"{at}.host: method \"tcp\" requires `host`");
                if (Int(raw, "port") is not { } port || port is < 1 or > 65_535)
                    throw Error($"{at}.port: method \"tcp\" requires `port` in 1...65535");
                return new NetworkTarget(label, group, ProbeMethod.Tcp, Host: host, Port: port);
            default:
                throw Error($"{at}.method: must be \"http\" or \"tcp\", got \"{methodRaw}\"");
        }
    }

    private static bool IsHttpUrl(string s) =>
        s.StartsWith("http://", StringComparison.Ordinal) || s.StartsWith("https://", StringComparison.Ordinal);

    private static ConfigException Error(string detail) => new(ConfigErrorKind.Parse, detail);

    private static TomlTable? Table(TomlTable t, string key) =>
        t.TryGetValue(key, out var v) ? v as TomlTable : null;

    private static IReadOnlyList<TomlTable> TableArray(TomlTable t, string key) =>
        t.TryGetValue(key, out var v) && v is TomlTableArray arr ? arr.ToList() : [];

    private static string? Str(TomlTable t, string key) =>
        t.TryGetValue(key, out var v) ? v as string : null;

    private static int? Int(TomlTable t, string key) =>
        t.TryGetValue(key, out var v) && v is long n && n is >= int.MinValue and <= int.MaxValue ? (int)n : null;

    private static double? Double(TomlTable t, string key) =>
        t.TryGetValue(key, out var v) ? v switch { double d => d, long n => n, _ => null } : null;

    private static bool? Bool(TomlTable t, string key) =>
        t.TryGetValue(key, out var v) && v is bool b ? b : null;
}
