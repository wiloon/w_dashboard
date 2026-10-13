// Network health collection (docs/sdd.md §12.3 / §12.5 / §12.6, ADR-014/015).
// Side-effecting: gateway ICMP via the Ping API, HTTP RTT, TCP connects, the
// captive check and speed tests. Results are reduced through the pure
// functions in Network.cs. Measurements follow the actual path (default route
// + system proxy); only the captive check binds to the physical NIC and
// bypasses proxies.

using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace WDashboard.Core;

/// <summary>The Wi-Fi (else wired) adapter that is up and has an IPv4 default gateway.</summary>
public sealed record PhysicalAdapter(string Name, NetworkInterfaceType Type, int IPv4Index, IPAddress Gateway);

public static class NetworkProbe
{
    public const string GatewayLabel = "Gateway";

    private const int IpUnicastIf = 31;
    private static readonly TimeSpan CaptiveTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan SpeedtestConnectTimeout = TimeSpan.FromSeconds(10);
    private static readonly string[] VirtualAdapterMarkers =
        ["Hyper-V", "VirtualBox", "VMware", "WireGuard", "Wintun", "TAP-", "Tailscale", "ZeroTier"];

    /// <summary>
    /// One light probe round: gateway + every target + captive check, concurrently
    /// (samples within one target are sequential). Never fails as a whole.
    /// </summary>
    public static async Task<NetworkReport> ProbeAsync(
        NetworkConfig config, bool pathAvailable, CancellationToken cancellationToken = default)
    {
        if (!pathAvailable)
        {
            var offline = config.Targets
                .Select(t => new TargetResult(t.Label, t.Group, t.Method, t.DisplayTarget, null, "no network"))
                .ToList();
            return new NetworkReport(Now(), null, offline, [], CaptiveState.Unknown, HealthLevel.Offline);
        }

        var samples = config.ProbeSamples;
        var timeout = TimeSpan.FromMilliseconds(config.ProbeTimeoutMs);

        var gatewayTask = ProbeGatewayAsync(samples, timeout, cancellationToken);
        var captiveTask = CheckCaptiveAsync(cancellationToken);
        var targets = await Task.WhenAll(config.Targets.Select(t => ProbeTargetAsync(t, samples, timeout, cancellationToken)));
        var gateway = await gatewayTask;
        var captive = await captiveTask;

        var groups = new[] { ProbeGroup.Domestic, ProbeGroup.Overseas, ProbeGroup.Home }
            .Select(g => Network.ProbeGroupSummary(g, targets
                .Where(t => t.Group == g && t.Stats is not null)
                .Select(t => new LabeledStats(t.Label, t.Stats!))
                .ToList()))
            .OfType<GroupSummary>()
            .ToList();

        var health = Network.Health(new HealthInput(
            PathAvailable: true,
            captive,
            gateway.Stats,
            groups.FirstOrDefault(g => g.Group == ProbeGroup.Domestic),
            groups.FirstOrDefault(g => g.Group == ProbeGroup.Overseas)));

        return new NetworkReport(Now(), gateway, targets, groups, captive, health);
    }

    /// <summary>§12.3 step 1 / §12.5: Wi-Fi first, then wired; virtual and tunnel adapters skipped.</summary>
    public static PhysicalAdapter? FindPhysicalAdapter()
    {
        NetworkInterface[] nics;
        try
        {
            nics = NetworkInterface.GetAllNetworkInterfaces();
        }
        catch (NetworkInformationException)
        {
            return null;
        }

        foreach (var type in new[] { NetworkInterfaceType.Wireless80211, NetworkInterfaceType.Ethernet })
        {
            foreach (var nic in nics)
            {
                if (nic.NetworkInterfaceType != type || nic.OperationalStatus != OperationalStatus.Up) continue;
                if (VirtualAdapterMarkers.Any(m => nic.Description.Contains(m, StringComparison.OrdinalIgnoreCase))) continue;
                if (!nic.Supports(NetworkInterfaceComponent.IPv4)) continue;

                var props = nic.GetIPProperties();
                var gateway = props.GatewayAddresses
                    .Select(g => g.Address)
                    .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !a.Equals(IPAddress.Any));
                if (gateway is null) continue;
                return new PhysicalAdapter(nic.Name, type, props.GetIPv4Properties().Index, gateway);
            }
        }
        return null;
    }

    // ---- Gateway (ICMP) ----

    private static async Task<TargetResult> ProbeGatewayAsync(int samples, TimeSpan timeout, CancellationToken ct)
    {
        var adapter = FindPhysicalAdapter();
        if (adapter is null)
            return new TargetResult(GatewayLabel, ProbeGroup.Gateway, ProbeMethod.Icmp, "", null, "no gateway");

        var rtts = new List<double>();
        using var ping = new Ping();
        for (var i = 0; i < samples; i++)
        {
            if (i > 0) await Task.Delay(200, ct);
            try
            {
                var reply = await ping.SendPingAsync(adapter.Gateway, timeout, cancellationToken: ct);
                if (reply.Status == IPStatus.Success) rtts.Add(reply.RoundtripTime);
            }
            catch (PingException)
            {
                // Counted as lost.
            }
        }
        return new TargetResult(
            GatewayLabel, ProbeGroup.Gateway, ProbeMethod.Icmp, adapter.Gateway.ToString(),
            Network.ProbeStatsOf(samples, rtts), null);
    }

    // ---- Remote targets ----

    private static async Task<TargetResult> ProbeTargetAsync(
        NetworkTarget target, int samples, TimeSpan timeout, CancellationToken ct)
    {
        var (rtts, error) = target.Method == ProbeMethod.Tcp
            ? await TcpSamplesAsync(target.Host ?? "", target.Port ?? 0, samples, timeout, ct)
            : await HttpSamplesAsync(target.Url ?? "", samples, timeout, ct);
        return new TargetResult(
            target.Label, target.Group, target.Method, target.DisplayTarget, Network.ProbeStatsOf(samples, rtts), error);
    }

    /// <summary>
    /// HTTP RTT (§12.3): one uncounted warm-up request, then sequential GETs on the
    /// reused connection; each sample is send → response headers. Any status counts.
    /// </summary>
    private static async Task<(List<double>, string?)> HttpSamplesAsync(
        string url, int samples, TimeSpan timeout, CancellationToken ct)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return ([], "invalid url");

        using var handler = new SocketsHttpHandler
        {
            UseProxy = true,
            AllowAutoRedirect = false,
            MaxConnectionsPerServer = 1,
        };
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };

        async Task<double> Once()
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            var sw = Stopwatch.StartNew();
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            var ms = sw.Elapsed.TotalMilliseconds;
            try
            {
                await response.Content.CopyToAsync(Stream.Null, cts.Token);
            }
            catch (Exception e) when (IsTransferError(e, ct))
            {
                // The sample already has its headers; a slow body only costs connection reuse.
            }
            return ms;
        }

        try
        {
            await Once();
        }
        catch (Exception e) when (IsTransferError(e, ct))
        {
            return ([], ShortError(e));
        }

        var rtts = new List<double>();
        string? lastError = null;
        for (var i = 0; i < samples; i++)
        {
            try
            {
                rtts.Add(await Once());
            }
            catch (Exception e) when (IsTransferError(e, ct))
            {
                lastError = ShortError(e);
            }
        }
        return (rtts, rtts.Count == 0 ? lastError : null);
    }

    private static async Task<(List<double>, string?)> TcpSamplesAsync(
        string host, int port, int samples, TimeSpan timeout, CancellationToken ct)
    {
        IPAddress? address = null;
        try
        {
            address = (await Dns.GetHostAddressesAsync(host, ct)).FirstOrDefault();
        }
        catch (SocketException)
        {
        }
        if (address is null) return ([], $"cannot resolve {host}");

        var rtts = new List<double>();
        for (var i = 0; i < samples; i++)
        {
            using var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            var sw = Stopwatch.StartNew();
            try
            {
                await socket.ConnectAsync(new IPEndPoint(address, port), cts.Token);
                rtts.Add(sw.Elapsed.TotalMilliseconds);
            }
            catch (Exception e) when (e is SocketException || (e is OperationCanceledException && !ct.IsCancellationRequested))
            {
                // Counted as lost.
            }
        }
        return (rtts, rtts.Count == 0 ? "connect failed" : null);
    }

    // ---- Captive portal ----

    /// <summary>
    /// §12.5: plain HTTP to captive.apple.com, pinned to the physical NIC with
    /// <c>IP_UNICAST_IF</c>, no proxy, no redirects. Any request failure → Unknown.
    /// </summary>
    private static async Task<CaptiveState> CheckCaptiveAsync(CancellationToken ct)
    {
        var adapter = FindPhysicalAdapter();
        if (adapter is null) return CaptiveState.Unknown;

        using var handler = new SocketsHttpHandler
        {
            UseProxy = false,
            AllowAutoRedirect = false,
            ConnectCallback = async (context, token) =>
            {
                var addresses = await Dns.GetHostAddressesAsync(context.DnsEndPoint.Host, AddressFamily.InterNetwork, token);
                var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
                try
                {
                    socket.SetSocketOption(
                        SocketOptionLevel.IP, (SocketOptionName)IpUnicastIf, IPAddress.HostToNetworkOrder(adapter.IPv4Index));
                    await socket.ConnectAsync(addresses, context.DnsEndPoint.Port, token);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch
                {
                    socket.Dispose();
                    throw;
                }
            },
        };
        using var client = new HttpClient(handler) { Timeout = CaptiveTimeout };
        using var request = new HttpRequestMessage(HttpMethod.Get, "http://captive.apple.com/hotspot-detect.html");
        request.Headers.UserAgent.ParseAdd("CaptiveNetworkSupport");
        request.Headers.ConnectionClose = true;

        try
        {
            using var response = await client.SendAsync(request, ct);
            var body = await response.Content.ReadAsStringAsync(ct);
            return Network.ClassifyCaptive((int)response.StatusCode, body);
        }
        catch (Exception e) when (IsTransferError(e, ct))
        {
            return CaptiveState.Unknown;
        }
    }

    // ---- Speed test ----

    /// <summary>
    /// The four manual steps in order (§12.6): domestic down/up, overseas down/up.
    /// <paramref name="onStep"/> gets each step key (<c>domestic-down</c>, …) before it starts.
    /// </summary>
    public static async Task<SpeedTestReport> RunSpeedtestAsync(
        NetworkConfig config, Action<string>? onStep = null, CancellationToken cancellationToken = default)
    {
        var started = Now();
        var maxBytes = (long)config.SpeedtestMaxMb * 1_000_000;
        var maxTime = TimeSpan.FromSeconds(config.SpeedtestMaxSecs);
        (string Group, string Direction, string Url)[] steps =
        [
            ("domestic", "down", config.SpeedtestDomesticDownloadUrl),
            ("domestic", "up", config.SpeedtestDomesticUploadUrl),
            ("overseas", "down", config.SpeedtestOverseasDownloadUrl),
            ("overseas", "up", config.SpeedtestOverseasUploadUrl),
        ];

        var items = new List<SpeedItem>();
        foreach (var (group, direction, url) in steps)
        {
            onStep?.Invoke($"{group}-{direction}");
            var m = direction == "down"
                ? await MeasureDownloadAsync(url, maxBytes, maxTime, cancellationToken)
                : await MeasureUploadAsync(url, maxBytes, maxTime, cancellationToken);
            var mbps = m.Error is null ? Network.ThroughputMbps(m.Bytes, m.ElapsedMs) : null;
            items.Add(new SpeedItem(group, direction, m.Bytes, m.ElapsedMs, mbps, m.Error));
        }
        return new SpeedTestReport(started, Now(), items);
    }

    private sealed record TransferMeasurement(long Bytes, long ElapsedMs, string? Error);

    private static HttpClient SpeedtestClient() =>
        new(new SocketsHttpHandler { UseProxy = true, AutomaticDecompression = DecompressionMethods.None })
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };

    /// <summary>Clock runs from the first body byte; stops at <paramref name="maxBytes"/> or <paramref name="maxTime"/>.</summary>
    private static async Task<TransferMeasurement> MeasureDownloadAsync(
        string url, long maxBytes, TimeSpan maxTime, CancellationToken ct)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return new(0, 0, "invalid url");

        using var client = SpeedtestClient();
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(SpeedtestConnectTimeout);
        long bytes = 0;
        Stopwatch? sw = null;
        string? error = null;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            if (!response.IsSuccessStatusCode) return new(0, 0, $"HTTP {(int)response.StatusCode}");

            cts.CancelAfter(SpeedtestConnectTimeout);
            await using var stream = await response.Content.ReadAsStreamAsync(cts.Token);
            var buffer = new byte[81_920];
            while (true)
            {
                var n = await stream.ReadAsync(buffer, cts.Token);
                if (n == 0) break;
                if (sw is null)
                {
                    sw = Stopwatch.StartNew();
                    cts.CancelAfter(maxTime);
                }
                bytes += n;
                if (bytes >= maxBytes || sw.Elapsed >= maxTime) break;
            }
        }
        catch (Exception e) when (IsTransferError(e, ct))
        {
            // After the first byte, a cancellation is our own time cap, not a failure.
            if (sw is null || !cts.IsCancellationRequested) error = ShortError(e);
        }

        sw?.Stop();
        if (sw is null) return new(bytes, 0, error ?? "no data received");
        return new(bytes, (long)Math.Round(sw.Elapsed.TotalMilliseconds, MidpointRounding.AwayFromZero), error);
    }

    /// <summary>Clock runs from the request start; stops at completion or <paramref name="maxTime"/>.</summary>
    private static async Task<TransferMeasurement> MeasureUploadAsync(
        string url, long maxBytes, TimeSpan maxTime, CancellationToken ct)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return new(0, 0, "invalid url");

        using var client = SpeedtestClient();
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        long bytes = 0;
        string? error = null;
        using var content = new RandomPayloadContent(maxBytes, sent => Interlocked.Exchange(ref bytes, sent));
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");

        var sw = Stopwatch.StartNew();
        cts.CancelAfter(maxTime);
        try
        {
            using var response = await client.PostAsync(uri, content, cts.Token);
            if (!response.IsSuccessStatusCode) error = $"HTTP {(int)response.StatusCode}";
        }
        catch (Exception e) when (IsTransferError(e, ct))
        {
            var sent = Interlocked.Read(ref bytes);
            if (!cts.IsCancellationRequested || sent == 0) error = ShortError(e);
        }
        sw.Stop();
        return new(Interlocked.Read(ref bytes), (long)Math.Round(sw.Elapsed.TotalMilliseconds, MidpointRounding.AwayFromZero), error);
    }

    /// <summary>
    /// Pseudo-random body so a proxy cannot compress it (§12.6). A 1 MiB random block is
    /// repeated — far beyond any DEFLATE window.
    /// </summary>
    private sealed class RandomPayloadContent(long length, Action<long> onProgress) : HttpContent
    {
        private const int ChunkSize = 64 * 1024;

        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
            SerializeToStreamAsync(stream, context, CancellationToken.None);

        protected override async Task SerializeToStreamAsync(
            Stream stream, TransportContext? context, CancellationToken cancellationToken)
        {
            var block = new byte[1 << 20];
            Random.Shared.NextBytes(block);
            long sent = 0;
            while (sent < length)
            {
                var offset = (int)(sent % block.Length);
                var n = (int)Math.Min(Math.Min(ChunkSize, length - sent), block.Length - offset);
                await stream.WriteAsync(block.AsMemory(offset, n), cancellationToken);
                sent += n;
                onProgress(sent);
            }
        }

        protected override bool TryComputeLength(out long length1)
        {
            length1 = length;
            return true;
        }
    }

    // ---- Helpers ----

    /// <summary>Network-ish failures that become a per-item error; the caller's own cancellation propagates.</summary>
    private static bool IsTransferError(Exception e, CancellationToken ct) =>
        e is HttpRequestException or IOException or SocketException
        || (e is OperationCanceledException && !ct.IsCancellationRequested);

    private static string ShortError(Exception e) => e switch
    {
        OperationCanceledException => "timed out",
        HttpRequestException { InnerException: SocketException s } => s.Message,
        _ => e.Message,
    };

    private static long Now() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();
}
