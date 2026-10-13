// Network health pure logic and models (docs/sdd.md §12, ADR-014).
//
// ProbeStats / GroupSummary / ClassifyCaptive / Health / ThroughputMbps are
// locked by docs/test-vectors/{probe-stats,probe-group,captive-portal,
// network-health,throughput}/. ping-output/ does not apply: Windows probes
// with System.Net.NetworkInformation.Ping instead of parsing ping text (§12.3).

namespace WDashboard.Core;

public enum ProbeGroup { Gateway, Domestic, Overseas, Home }

public enum ProbeMethod { Icmp, Http, Tcp }

public enum CaptiveState { NotDetected, Detected, Unknown }

public enum HealthLevel { Good, Fair, Poor, NoInternet, CaptivePortal, Offline, Unknown }

/// <summary>Health thresholds (§12.4). All comparisons are strict <c>&gt;</c>.</summary>
public static class HealthThresholds
{
    public const double PoorLoss = 5.0;
    public const double PoorJitter = 50.0;
    public const double PoorLatency = 150.0;
    public const double FairLoss = 1.0;
    public const double FairJitter = 20.0;
    public const double FairLatency = 60.0;
}

public sealed record ProbeStats(
    int Sent,
    int Received,
    double LossPct,
    double? RttMinMs,
    double? RttMedianMs,
    double? RttMaxMs,
    double? JitterMs);

public sealed record TargetResult(
    string Label,
    ProbeGroup Group,
    ProbeMethod Method,
    string Target,
    ProbeStats? Stats,
    string? Error);

public sealed record GroupSummary(
    ProbeGroup Group,
    int Sent,
    int Received,
    double LossPct,
    string? BestLabel,
    double? MedianMs,
    double? JitterMs);

public sealed record NetworkReport(
    long ProbedAt,
    TargetResult? Gateway,
    IReadOnlyList<TargetResult> Targets,
    IReadOnlyList<GroupSummary> Groups,
    CaptiveState Captive,
    HealthLevel Health)
{
    public GroupSummary? Summary(ProbeGroup group) => Groups.FirstOrDefault(g => g.Group == group);
}

public sealed record SpeedItem(string Group, string Direction, long Bytes, long ElapsedMs, double? Mbps, string? Error);

public sealed record SpeedTestReport(long StartedAt, long? FinishedAt, IReadOnlyList<SpeedItem> Items);

public sealed record HealthInput(
    bool PathAvailable,
    CaptiveState Captive,
    ProbeStats? Gateway,
    GroupSummary? Domestic,
    GroupSummary? Overseas);

public sealed record LabeledStats(string Label, ProbeStats Stats);

public static class Network
{
    /// <summary>
    /// Round half away from zero to 0.1 (<c>r1</c>, §12.3). <see cref="Math.Round(double)"/>
    /// defaults to banker's rounding, which would diverge from the other ends.
    /// </summary>
    public static double R1(double x) => Math.Round(x * 10, MidpointRounding.AwayFromZero) / 10;

    private static double LossPct(int sent, int received) =>
        sent <= 0 ? 100.0 : R1(Math.Max(0, sent - received) * 100.0 / sent);

    /// <summary>Sample statistics (§12.3). <paramref name="rttsMs"/> is in arrival order.</summary>
    public static ProbeStats ProbeStatsOf(int sent, IReadOnlyList<double> rttsMs)
    {
        var n = rttsMs.Count;
        double? min = null, median = null, max = null, jitter = null;
        if (n > 0)
        {
            var sorted = rttsMs.Order().ToArray();
            var mid = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
            min = R1(sorted[0]);
            median = R1(mid);
            max = R1(sorted[n - 1]);
        }
        if (n >= 2)
        {
            var acc = 0.0;
            for (var i = 1; i < n; i++)
            {
                acc += Math.Abs(rttsMs[i] - rttsMs[i - 1]);
            }
            jitter = R1(acc / (n - 1));
        }
        return new ProbeStats(sent, n, LossPct(sent, n), min, median, max, jitter);
    }

    /// <summary>
    /// Group summary (§12.4): loss accumulated over the whole group, latency/jitter
    /// from the lowest-median target; ties keep the first in config order.
    /// </summary>
    public static GroupSummary? ProbeGroupSummary(ProbeGroup group, IReadOnlyList<LabeledStats> results)
    {
        if (results.Count == 0) return null;
        var sent = results.Sum(r => r.Stats.Sent);
        var received = results.Sum(r => r.Stats.Received);

        LabeledStats? best = null;
        foreach (var result in results)
        {
            if (result.Stats.Received <= 0 || result.Stats.RttMedianMs is not { } median) continue;
            if (best?.Stats.RttMedianMs is { } bestMedian && bestMedian <= median) continue;
            best = result;
        }

        return new GroupSummary(
            group, sent, received, LossPct(sent, received),
            best?.Label, best?.Stats.RttMedianMs, best?.Stats.JitterMs);
    }

    /// <summary>Captive portal decision table (§12.5).</summary>
    public static CaptiveState ClassifyCaptive(int status, string body)
    {
        if (status == 200 && body.Contains("Success", StringComparison.Ordinal)) return CaptiveState.NotDetected;
        if (status is >= 200 and <= 399) return CaptiveState.Detected;
        return CaptiveState.Unknown;
    }

    /// <summary>Health level decision table, first match wins (§12.4).</summary>
    public static HealthLevel Health(HealthInput input)
    {
        if (!input.PathAvailable) return HealthLevel.Offline;
        if (input.Captive == CaptiveState.Detected) return HealthLevel.CaptivePortal;

        var present = new[] { input.Domestic, input.Overseas }.OfType<GroupSummary>().ToList();
        if (present.Count > 0 && present.All(g => g.Received == 0)) return HealthLevel.NoInternet;

        if (input.Domestic is not { MedianMs: { } latency } domestic) return HealthLevel.Unknown;

        // A gateway that drops all ICMP is excluded rather than counted as loss.
        var gateway = input.Gateway is { Received: > 0 } g ? g : null;
        var loss = Math.Max(domestic.LossPct, gateway?.LossPct ?? 0);
        var jitter = Math.Max(domestic.JitterMs ?? 0, gateway?.JitterMs ?? 0);

        if (loss > HealthThresholds.PoorLoss || jitter > HealthThresholds.PoorJitter || latency > HealthThresholds.PoorLatency)
            return HealthLevel.Poor;
        if (loss > HealthThresholds.FairLoss || jitter > HealthThresholds.FairJitter || latency > HealthThresholds.FairLatency)
            return HealthLevel.Fair;
        return HealthLevel.Good;
    }

    /// <summary>Throughput in Mbps (10^6 bit/s), 0.1 precision (§12.6).</summary>
    public static double? ThroughputMbps(long bytes, long elapsedMs) =>
        bytes > 0 && elapsedMs > 0 ? R1(bytes * 8.0 / (elapsedMs * 1000.0)) : null;
}
