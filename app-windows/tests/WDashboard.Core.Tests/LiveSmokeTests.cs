// Live smoke tests for network probing, the speed test and weather (docs/sdd.md
// §10.1: side-effecting collection gets a light e2e check, not vectors). They
// touch the real network, so they only run with W_DASHBOARD_NET_SMOKE=1.

using Xunit.Abstractions;

namespace WDashboard.Core.Tests;

public sealed class LiveFactAttribute : FactAttribute
{
    public LiveFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("W_DASHBOARD_NET_SMOKE") != "1")
            Skip = "set W_DASHBOARD_NET_SMOKE=1 to run live network smoke tests";
    }
}

public class LiveSmokeTests(ITestOutputHelper output)
{
    [LiveFact]
    public async Task ProbeRoundProducesAResultPerTarget()
    {
        var config = new NetworkConfig();
        output.WriteLine($"adapter: {NetworkProbe.FindPhysicalAdapter()}");
        var report = await NetworkProbe.ProbeAsync(config, pathAvailable: true);

        output.WriteLine($"gateway: {report.Gateway}");
        foreach (var t in report.Targets) output.WriteLine($"target: {t}");
        foreach (var g in report.Groups) output.WriteLine($"group: {g}");
        output.WriteLine($"captive: {report.Captive} health: {report.Health}");

        Assert.Equal(config.Targets.Count, report.Targets.Count);
        Assert.All(report.Targets, t => Assert.Equal(config.ProbeSamples, t.Stats?.Sent));
    }

    [LiveFact]
    public async Task SpeedtestShortRun()
    {
        var config = new NetworkConfig { SpeedtestMaxSecs = 3, SpeedtestMaxMb = 5 };
        var report = await NetworkProbe.RunSpeedtestAsync(config, step => output.WriteLine($"step: {step}"));
        foreach (var item in report.Items) output.WriteLine($"speed: {item}");

        Assert.Equal(4, report.Items.Count);
        Assert.All(report.Items, i => Assert.True(i.Bytes <= 5_000_000 + 1_000_000));
    }

    [LiveFact]
    public async Task WeatherByLocationName()
    {
        using var http = new HttpClient();
        var report = await Weather.FetchAsync(
            http, new WeatherConfig("Beijing", null, null, "celsius", 3), TimeSpan.FromSeconds(20));
        output.WriteLine(report.ToString());
        foreach (var d in report.Daily) output.WriteLine($"day: {d}");

        Assert.Equal("Beijing", report.LocationLabel);
        Assert.Equal(3, report.Daily.Count);
    }
}
