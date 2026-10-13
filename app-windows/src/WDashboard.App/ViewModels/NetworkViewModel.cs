// Network tab (docs/sdd.md §12.8, ADR-014): decides *when* to probe / speed
// test and renders the results. Every metric and the health level come from
// WDashboard.Core; link info is display-only (Services/LinkInfo.cs).

using System.Collections.ObjectModel;
using System.Globalization;
using System.Net.NetworkInformation;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using WDashboard.App.Services;
using WDashboard.Core;

namespace WDashboard.App.ViewModels;

/// <summary>One latency table row: a group header or a target.</summary>
public sealed record LatencyRow(
    string Label, string Method, string Median, string Jitter, string Loss,
    bool IsHeader, bool Indented, double Opacity, Brush LossBrush, string Tooltip)
{
    public Windows.UI.Text.FontWeight Weight => IsHeader ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
    public Thickness LabelMargin => new(Indented ? 12 : 0, 0, 0, 0);
}

public sealed partial class NetworkViewModel : ObservableObject, IDisposable
{
    private readonly DispatcherQueue _dispatcher;
    private readonly DispatcherQueueTimer _probeTimer;
    private readonly DispatcherQueueTimer _debounceTimer;
    private NetworkConfig _config;
    private bool _probePending;
    private string? _baseline;
    private bool _started;

    public NetworkViewModel(NetworkConfig config, DispatcherQueue dispatcher)
    {
        _config = config;
        _dispatcher = dispatcher;
        _probeTimer = dispatcher.CreateTimer();
        _probeTimer.Tick += (_, _) => RequestProbe();
        _debounceTimer = dispatcher.CreateTimer();
        _debounceTimer.Interval = TimeSpan.FromSeconds(3);
        _debounceTimer.IsRepeating = false;
        _debounceTimer.Tick += (_, _) => RequestProbe();
        Link = new LinkInfo(true, null, false, null, "");
    }

    public ObservableCollection<LatencyRow> LatencyRows { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HealthTitle), nameof(HealthDetail), nameof(HealthBrush), nameof(ProbedAt),
        nameof(HasReport), nameof(NoReport))]
    public partial NetworkReport? Report { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PathLine), nameof(HasWifi), nameof(NoWifi), nameof(WifiNetwork), nameof(WifiSignal),
        nameof(WifiRate), nameof(WifiChannel), nameof(NeedsLocation))]
    public partial LinkInfo Link { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanRecheck), nameof(CanSpeedtest))]
    public partial bool Probing { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanRecheck), nameof(CanSpeedtest), nameof(SpeedtestRunning), nameof(SpeedtestStepText),
        nameof(DomesticDown), nameof(DomesticUp), nameof(OverseasDown), nameof(OverseasUp))]
    public partial string? SpeedtestStep { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(DomesticDown), nameof(DomesticUp), nameof(OverseasDown), nameof(OverseasUp),
        nameof(DomesticDownBrush), nameof(DomesticUpBrush), nameof(OverseasDownBrush), nameof(OverseasUpBrush),
        nameof(DomesticDownError), nameof(DomesticUpError), nameof(OverseasDownError), nameof(OverseasUpError),
        nameof(TestedAt))]
    public partial SpeedTestReport? SpeedReport { get; private set; }

    // ---- Overview ----

    public bool HasReport => Report is not null;
    public bool NoReport => Report is null;

    public string HealthTitle => Report?.Health switch
    {
        null => "Checking…",
        HealthLevel.Good => "Good",
        HealthLevel.Fair => "Fair",
        HealthLevel.Poor => "Poor",
        HealthLevel.NoInternet => "No internet",
        HealthLevel.CaptivePortal => "Sign-in required",
        HealthLevel.Offline => "Offline",
        _ => "Unknown",
    };

    public string HealthDetail => Report?.Health switch
    {
        null => "Running the first probe…",
        HealthLevel.Good => "Latency, jitter and loss are all within normal range",
        HealthLevel.Fair => "Usable, but latency, jitter or loss is elevated",
        HealthLevel.Poor => "Latency, jitter or loss is well above normal — expect a degraded experience",
        HealthLevel.NoInternet => "Neither domestic nor overseas targets are reachable",
        HealthLevel.CaptivePortal => "Connected to the hotspot, but you must sign in on its web page first",
        HealthLevel.Offline => "No network connection",
        _ => "Domestic targets are unreachable — cannot judge",
    };

    public SolidColorBrush HealthBrush => Palette.Brush(Report is null ? Palette.Gray : Palette.Health(Report.Health));

    public string ProbedAt => Report is null ? "" : "Probed at " + TimeString(Report.ProbedAt);

    public string PathLine
    {
        get
        {
            if (!Link.PathAvailable) return "No network";
            var parts = new List<string>();
            if (Link.Wifi is { } wifi)
                parts.Add(wifi.Ssid is { } ssid ? $"Wi-Fi \"{ssid}\"" : "Wi-Fi (name needs Location permission)");
            else
                parts.Add("Not on Wi-Fi");
            if (Link.VpnName is { } vpn) parts.Add($"via VPN ({vpn})");
            if (Link.SystemProxy) parts.Add("system proxy on");
            return string.Join(" · ", parts);
        }
    }

    public bool CanRecheck => !Probing && SpeedtestStep is null;

    // ---- Wi-Fi ----

    public bool HasWifi => Link.Wifi is not null;
    public bool NoWifi => Link.Wifi is null;
    public bool NeedsLocation => Link.Wifi?.NeedsLocation == true;
    public string WifiNetwork => Link.Wifi?.Ssid ?? "(needs Location permission)";
    public string WifiSignal => Link.Wifi?.Rssi is { } rssi ? $"{rssi} dBm · {RssiLabel(rssi)}" : "—";
    public string WifiRate => Link.Wifi?.RateMbps is { } rate ? rate.ToString("0", CultureInfo.InvariantCulture) + " Mbps" : "—";
    public string WifiChannel
    {
        get
        {
            var parts = new[] { Link.Wifi?.Channel?.ToString(CultureInfo.InvariantCulture), Link.Wifi?.Band }.OfType<string>().ToList();
            return parts.Count == 0 ? "—" : string.Join(" · ", parts);
        }
    }

    // ---- Speed test ----

    public bool CanSpeedtest => SpeedtestStep is null && !Probing;
    public bool SpeedtestRunning => SpeedtestStep is not null;
    public string SpeedtestStepText => SpeedtestStep switch
    {
        null => "",
        "domestic-down" => "Testing domestic download…",
        "domestic-up" => "Testing domestic upload…",
        "overseas-down" => "Testing overseas download…",
        "overseas-up" => "Testing overseas upload…",
        _ => "Testing setup…",
    };

    public string DomesticDown => SpeedText("domestic", "down");
    public string DomesticUp => SpeedText("domestic", "up");
    public string OverseasDown => SpeedText("overseas", "down");
    public string OverseasUp => SpeedText("overseas", "up");
    public Brush DomesticDownBrush => SpeedBrush("domestic", "down");
    public Brush DomesticUpBrush => SpeedBrush("domestic", "up");
    public Brush OverseasDownBrush => SpeedBrush("overseas", "down");
    public Brush OverseasUpBrush => SpeedBrush("overseas", "up");
    public string? DomesticDownError => SpeedItem("domestic", "down")?.Error;
    public string? DomesticUpError => SpeedItem("domestic", "up")?.Error;
    public string? OverseasDownError => SpeedItem("overseas", "down")?.Error;
    public string? OverseasUpError => SpeedItem("overseas", "up")?.Error;

    public string TestedAt => SpeedReport is null ? "" : "Tested at " + TimeString(SpeedReport.StartedAt);

    public string TrafficNote =>
        $"Uses about {_config.SpeedtestMaxMb * 2}–{_config.SpeedtestMaxMb * 4} MB per run. Single stream, so cross-border results may read low.";

    public string LatencyFootnote =>
        "Overseas and Home do not affect the health level. Latency is the HTTP round trip on a reused connection (TCP handshake for Home, ICMP for the gateway).";

    private SpeedItem? SpeedItem(string group, string direction) =>
        SpeedReport?.Items.FirstOrDefault(i => i.Group == group && i.Direction == direction);

    private string SpeedText(string group, string direction)
    {
        var item = SpeedItem(group, direction);
        if (item?.Mbps is { } mbps) return mbps.ToString("0.0", CultureInfo.InvariantCulture) + " Mbps";
        return item?.Error is not null ? "Failed" : "—";
    }

    private Brush SpeedBrush(string group, string direction) =>
        SpeedItem(group, direction)?.Error is not null ? Palette.Brush(Palette.Red) : Palette.TextPrimary;

    // ---- Scheduling (§12.8 step 2) ----

    public void Start()
    {
        if (!_config.Enabled || _started) return;
        _started = true;
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        NetworkChange.NetworkAvailabilityChanged += OnNetworkChanged;
        _ = StartAsync();
    }

    private async Task StartAsync()
    {
        await RefreshLinkAsync();
        _baseline = Link.Signature;
        RequestProbe();
        if (_config.ProbeIntervalSecs > 0)
        {
            _probeTimer.Interval = TimeSpan.FromSeconds(_config.ProbeIntervalSecs);
            _probeTimer.Start();
        }
    }

    public void UpdateConfig(NetworkConfig config)
    {
        _config = config;
        OnPropertyChanged(nameof(TrafficNote));
        _probeTimer.Stop();
        if (_started && config.ProbeIntervalSecs > 0)
        {
            _probeTimer.Interval = TimeSpan.FromSeconds(config.ProbeIntervalSecs);
            _probeTimer.Start();
        }
    }

    private void OnNetworkChanged(object? sender, EventArgs e) => _dispatcher.TryEnqueue(() => _ = OnNetworkChangedAsync());

    private async Task OnNetworkChangedAsync()
    {
        await RefreshLinkAsync();
        var signature = Link.Signature;
        if (_baseline is null || signature == _baseline) return;
        _baseline = signature;
        _debounceTimer.Stop();
        _debounceTimer.Start();
    }

    /// <summary>One light round; while a round or speed test runs, mark one pending re-run instead.</summary>
    [RelayCommand]
    public void RequestProbe()
    {
        if (!_config.Enabled) return;
        if (Probing || SpeedtestStep is not null)
        {
            _probePending = true;
            return;
        }
        _ = ProbeAsync();
    }

    private async Task ProbeAsync()
    {
        Probing = true;
        var config = _config;
        var available = Link.PathAvailable;
        var report = await Task.Run(() => NetworkProbe.ProbeAsync(config, available));
        Report = report;
        RebuildLatencyRows(report);
        Probing = false;
        await RefreshLinkAsync();
        RunPendingProbe();
    }

    private void RunPendingProbe()
    {
        if (!_probePending || SpeedtestStep is not null || Probing) return;
        _probePending = false;
        RequestProbe();
    }

    [RelayCommand]
    private async Task RunSpeedtest()
    {
        if (!_config.Enabled || SpeedtestStep is not null || Probing) return;
        SpeedtestStep = "starting";
        var config = _config;
        var report = await Task.Run(() => NetworkProbe.RunSpeedtestAsync(
            config, step => _dispatcher.TryEnqueue(() =>
            {
                if (SpeedtestStep is not null) SpeedtestStep = step;
            })));
        SpeedReport = report;
        SpeedtestStep = null;
        RunPendingProbe();
    }

    [RelayCommand]
    private static async Task OpenLocationSettings() =>
        await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:privacy-location"));

    private async Task RefreshLinkAsync()
    {
        var link = await Task.Run(LinkInfo.Collect);
        if (link != Link) Link = link;
    }

    // ---- Latency table ----

    private void RebuildLatencyRows(NetworkReport report)
    {
        LatencyRows.Clear();
        if (report.Gateway is { } gateway) LatencyRows.Add(TargetRow(gateway, topLevel: true));
        foreach (var group in new[] { ProbeGroup.Domestic, ProbeGroup.Overseas, ProbeGroup.Home })
        {
            var members = report.Targets.Where(t => t.Group == group).ToList();
            if (members.Count == 0) continue;
            var summary = report.Summary(group);
            LatencyRows.Add(new LatencyRow(
                GroupTitle(group), "", Ms(summary?.MedianMs), Ms(summary?.JitterMs),
                summary is null ? "" : Pct(summary.LossPct), IsHeader: true, Indented: false, Opacity: 1,
                Palette.TextPrimary, ""));
            foreach (var t in members) LatencyRows.Add(TargetRow(t, topLevel: false));
        }
    }

    private static LatencyRow TargetRow(TargetResult t, bool topLevel)
    {
        var failed = t.Stats is null || t.Stats.Received == 0;
        var lossy = (t.Stats?.LossPct ?? 100) > 0;
        return new LatencyRow(
            t.Label,
            t.Method switch { ProbeMethod.Icmp => "ICMP", ProbeMethod.Http => "HTTP", _ => "TCP" },
            Ms(t.Stats?.RttMedianMs),
            Ms(t.Stats?.JitterMs),
            t.Stats is null ? "—" : Pct(t.Stats.LossPct),
            IsHeader: topLevel,
            Indented: !topLevel,
            Opacity: failed ? 0.5 : 1,
            lossy ? Palette.Brush(Palette.Red) : Palette.TextPrimary,
            t.Error is null ? t.Target : $"{t.Target}\n{t.Error}");
    }

    private static string GroupTitle(ProbeGroup g) => g switch
    {
        ProbeGroup.Gateway => "Gateway",
        ProbeGroup.Domestic => "Domestic",
        ProbeGroup.Overseas => "Overseas",
        _ => "Home",
    };

    private static string RssiLabel(int rssi) =>
        rssi >= -60 ? "strong" : rssi >= -70 ? "fair" : rssi >= -80 ? "weak" : "very weak";

    private static string Ms(double? v) => v is { } x ? x.ToString("0.0", CultureInfo.InvariantCulture) + " ms" : "—";

    private static string Pct(double v) => v.ToString("0", CultureInfo.InvariantCulture) + "%";

    private static string TimeString(long unix) =>
        DateTimeOffset.FromUnixTimeSeconds(unix).ToLocalTime().ToString("HH:mm:ss", CultureInfo.InvariantCulture);

    public void Dispose()
    {
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        NetworkChange.NetworkAvailabilityChanged -= OnNetworkChanged;
        _probeTimer.Stop();
        _debounceTimer.Stop();
    }
}
