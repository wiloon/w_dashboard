// Config loading (docs/sdd.md §4 / §11 / §12.2). Mirrors app-macos
// ConfigPomodoroTests / ConfigNetworkTests, plus the Windows-specific rules.

namespace WDashboard.Core.Tests;

public class ConfigTests : IDisposable
{
    private readonly TempDir _dir = new();

    public void Dispose() => _dir.Dispose();

    private Config Load(string contents) => ConfigLoader.Load(_dir.Write("config.toml", contents));

    private void AssertParseError(string contents, string field)
    {
        var e = Assert.Throws<ConfigException>(() => Load(contents));
        Assert.Equal(ConfigErrorKind.Parse, e.Kind);
        Assert.Contains(field, e.Message);
    }

    [Fact]
    public void MissingFileReturnsDefaults()
    {
        var cfg = ConfigLoader.Load(_dir.File("absent.toml"));
        Assert.Equal(900, cfg.RefreshIntervalSecs);
        Assert.Equal(20, cfg.CommandTimeoutSecs);
        Assert.True(cfg.FetchRemote);
        Assert.Empty(cfg.Repos);
        Assert.Equal(["Beijing", "New York"], cfg.Clocks.Select(c => c.Label));
        Assert.Null(cfg.Weather);
        Assert.Equal(new PomodoroConfig(), cfg.Pomodoro);
        Assert.Equal(5, cfg.Network.Targets.Count);
    }

    [Fact]
    public void GeneralReposClocksWeatherAreParsed()
    {
        var cfg = Load("""
            [general]
            refresh_interval_secs = 60
            command_timeout_secs = 5
            fetch_remote = false

            [[repos]]
            path = "C:/src/foo"
            name = "foo"

            [[clocks]]
            label = "Tokyo"
            tz = "Asia/Tokyo"

            [weather]
            latitude = 39.9
            longitude = 116
            temperature_unit = "fahrenheit"
            forecast_days = 3
            """);
        Assert.Equal(60, cfg.RefreshIntervalSecs);
        Assert.Equal(5, cfg.CommandTimeoutSecs);
        Assert.False(cfg.FetchRemote);
        Assert.Equal([new RepoConfig("C:/src/foo", "foo")], cfg.Repos);
        Assert.Equal([new ClockConfig("Tokyo", "Asia/Tokyo")], cfg.Clocks);
        Assert.Equal(new WeatherConfig(null, 39.9, 116.0, "fahrenheit", 3), cfg.Weather);
    }

    [Fact]
    public void CrlfAndBomAreAccepted()
    {
        var path = _dir.File("config.toml");
        File.WriteAllText(path, "[general]\r\nrefresh_interval_secs = 42\r\n", new System.Text.UTF8Encoding(true));
        Assert.Equal(42, ConfigLoader.Load(path).RefreshIntervalSecs);
    }

    [Fact]
    public void RepoPathsAreExpanded()
    {
        Environment.SetEnvironmentVariable("WD_TEST_ROOT", @"D:\code");
        var cfg = Load("""
            [[repos]]
            path = "~/projects/a"

            [[repos]]
            path = "%WD_TEST_ROOT%\\b"

            [[repos]]
            path = "${WD_TEST_ROOT}/c"
            """);
        Assert.Equal(Path.Combine(Paths.Home, "projects/a"), cfg.Repos[0].Path);
        Assert.Equal(@"D:\code\b", cfg.Repos[1].Path);
        Assert.Equal("D:\\code/c", cfg.Repos[2].Path);
    }

    [Fact]
    public void InvalidTomlIsParseError() => AssertParseError("[general\n", "failed to parse config");

    [Fact]
    public void InvalidTimeZoneIsError() =>
        AssertParseError("[[clocks]]\nlabel = \"x\"\ntz = \"Mars/Base\"\n", "Mars/Base");

    [Fact]
    public void WeatherWithoutLocationIsError() => AssertParseError("[weather]\nforecast_days = 3\n", "weather");

    [Fact]
    public void BadTemperatureUnitIsError() =>
        AssertParseError("[weather]\nlocation = \"Beijing\"\ntemperature_unit = \"kelvin\"\n", "weather.temperature_unit");

    // ---- [pomodoro] ----

    [Fact]
    public void PomodoroFullSectionIsParsed()
    {
        var cfg = Load("[pomodoro]\nenabled = false\nfocus_minutes = 50\nbreak_minutes = 10\nnotify = false\nsound = false\nmorning_nudge = false\nmorning_nudge_after = \"08:30\"\n");
        Assert.Equal(new PomodoroConfig
        {
            Enabled = false,
            FocusMinutes = 50,
            BreakMinutes = 10,
            Notify = false,
            Sound = false,
            MorningNudge = false,
            MorningNudgeAfterMinutes = 8 * 60 + 30,
        }, cfg.Pomodoro);
    }

    [Fact]
    public void PomodoroPartialSectionFillsDefaults()
    {
        var cfg = Load("[pomodoro]\nfocus_minutes = 30\n");
        Assert.True(cfg.Pomodoro.Enabled);
        Assert.Equal(30, cfg.Pomodoro.FocusMinutes);
        Assert.Equal(5, cfg.Pomodoro.BreakMinutes);
    }

    [Fact]
    public void PomodoroMalformedNudgeAfterIsError() =>
        AssertParseError("[pomodoro]\nmorning_nudge_after = \"9am\"\n", "morning_nudge_after");

    [Fact]
    public void PomodoroZeroFocusIsError() => AssertParseError("[pomodoro]\nfocus_minutes = 0\n", "focus_minutes");

    [Fact]
    public void PomodoroNegativeBreakIsError() => AssertParseError("[pomodoro]\nbreak_minutes = -3\n", "break_minutes");

    // ---- [network] ----

    [Fact]
    public void NetworkAbsentUsesDefaults()
    {
        var cfg = Load("[general]\nrefresh_interval_secs = 60\n");
        Assert.True(cfg.Network.Enabled);
        Assert.Equal(60, cfg.Network.ProbeIntervalSecs);
        Assert.Equal(10, cfg.Network.ProbeSamples);
        Assert.Equal(5, cfg.Network.Targets.Count);
        Assert.Equal(new NetworkTarget("Home", ProbeGroup.Home, ProbeMethod.Tcp, Host: "home.wiloon.com", Port: 443), cfg.Network.Targets[^1]);
    }

    [Fact]
    public void NetworkCustomTargetsReplaceDefaults()
    {
        var cfg = Load("""
            [network]
            enabled = false
            probe_interval_secs = 0
            probe_samples = 5
            speedtest_max_mb = 10
            speedtest_overseas_upload_url = "https://example.com/up"

            [[network_targets]]
            label = "Router"
            group = "home"
            method = "tcp"
            host = "192.168.1.1"
            port = 80

            [[network_targets]]
            label = "Example"
            group = "overseas"
            url = "https://example.com/"
            """);
        Assert.False(cfg.Network.Enabled);
        Assert.Equal(0, cfg.Network.ProbeIntervalSecs);
        Assert.Equal(5, cfg.Network.ProbeSamples);
        Assert.Equal(10, cfg.Network.SpeedtestMaxMb);
        Assert.Equal("https://example.com/up", cfg.Network.SpeedtestOverseasUploadUrl);
        Assert.Equal(8, cfg.Network.SpeedtestMaxSecs);
        Assert.Equal(
            [
                new NetworkTarget("Router", ProbeGroup.Home, ProbeMethod.Tcp, Host: "192.168.1.1", Port: 80),
                new NetworkTarget("Example", ProbeGroup.Overseas, ProbeMethod.Http, Url: "https://example.com/"),
            ],
            cfg.Network.Targets);
    }

    [Fact]
    public void NetworkUnknownGroupIsError() =>
        AssertParseError("[[network_targets]]\nlabel = \"x\"\ngroup = \"mars\"\nurl = \"https://a/\"\n", "network_targets[0].group");

    [Fact]
    public void NetworkUnknownMethodIsError() =>
        AssertParseError("[[network_targets]]\nlabel = \"x\"\ngroup = \"home\"\nmethod = \"udp\"\n", "network_targets[0].method");

    [Fact]
    public void NetworkHttpWithoutUrlIsError() =>
        AssertParseError("[[network_targets]]\nlabel = \"x\"\ngroup = \"domestic\"\n", "network_targets[0].url");

    [Fact]
    public void NetworkTcpWithoutPortIsError() =>
        AssertParseError("[[network_targets]]\nlabel = \"x\"\ngroup = \"home\"\nmethod = \"tcp\"\nhost = \"h\"\n", "network_targets[0].port");

    [Fact]
    public void NetworkOutOfRangeSamplesIsError() =>
        AssertParseError("[network]\nprobe_samples = 0\n", "network.probe_samples");

    [Fact]
    public void NetworkOutOfRangeTimeoutIsError() =>
        AssertParseError("[network]\nprobe_timeout_ms = 50000\n", "network.probe_timeout_ms");
}
