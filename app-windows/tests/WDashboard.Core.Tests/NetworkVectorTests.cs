namespace WDashboard.Core.Tests;

// ping-output/ is intentionally not run: Windows uses the Ping API, not ping text (docs/sdd.md §10.2).
public class NetworkVectorTests
{
    public static TheoryData<string> ProbeStatsFiles => Vectors.Files("probe-stats");
    public static TheoryData<string> ProbeGroupFiles => Vectors.Files("probe-group");
    public static TheoryData<string> CaptiveFiles => Vectors.Files("captive-portal");
    public static TheoryData<string> HealthFiles => Vectors.Files("network-health");
    public static TheoryData<string> ThroughputFiles => Vectors.Files("throughput");

    private sealed record ProbeStatsInput(int Sent, List<double> RttsMs);
    private sealed record ProbeGroupInput(ProbeGroup Group, List<LabeledStats> Results);
    private sealed record CaptiveInput(int Status, string Body);
    private sealed record ThroughputInput(long Bytes, long ElapsedMs);
    private sealed record ThroughputExpected(double? Mbps);

    [Theory]
    [MemberData(nameof(ProbeStatsFiles))]
    public void ProbeStatsOf(string file)
    {
        var v = Vectors.Load<Vector<ProbeStatsInput, ProbeStats>>("probe-stats", file);
        Assert.Equal(v.Expected, Network.ProbeStatsOf(v.Input.Sent, v.Input.RttsMs));
    }

    [Theory]
    [MemberData(nameof(ProbeGroupFiles))]
    public void ProbeGroupSummary(string file)
    {
        var v = Vectors.Load<Vector<ProbeGroupInput, GroupSummary?>>("probe-group", file);
        Assert.Equal(v.Expected, Network.ProbeGroupSummary(v.Input.Group, v.Input.Results));
    }

    [Theory]
    [MemberData(nameof(CaptiveFiles))]
    public void CaptivePortal(string file)
    {
        var v = Vectors.Load<Vector<CaptiveInput, CaptiveState>>("captive-portal", file);
        Assert.Equal(v.Expected, Network.ClassifyCaptive(v.Input.Status, v.Input.Body));
    }

    [Theory]
    [MemberData(nameof(HealthFiles))]
    public void NetworkHealth(string file)
    {
        var v = Vectors.Load<Vector<HealthInput, HealthLevel>>("network-health", file);
        Assert.Equal(v.Expected, Network.Health(v.Input));
    }

    [Theory]
    [MemberData(nameof(ThroughputFiles))]
    public void Throughput(string file)
    {
        var v = Vectors.Load<Vector<ThroughputInput, ThroughputExpected>>("throughput", file);
        Assert.Equal(v.Expected.Mbps, Network.ThroughputMbps(v.Input.Bytes, v.Input.ElapsedMs));
    }
}
