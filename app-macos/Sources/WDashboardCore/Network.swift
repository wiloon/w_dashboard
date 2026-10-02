// Network health pure logic and models (docs/sdd.md §12, ADR-014).
//
// `parsePing` / `probeStats` / `probeGroupSummary` / `classifyCaptive` /
// `networkHealth` / `throughputMbps` are pure functions locked by the shared
// test vectors (docs/test-vectors/{ping-output,probe-stats,probe-group,
// captive-portal,network-health,throughput}/). Probing and speed tests live in
// NetworkProbe.swift; link info (Wi-Fi / VPN / proxy) is app-layer only.

import Foundation

public enum ProbeGroup: String, Equatable, Sendable, Codable {
    case gateway = "Gateway"
    case domestic = "Domestic"
    case overseas = "Overseas"
    case home = "Home"
}

public enum ProbeMethod: String, Equatable, Sendable, Codable {
    case icmp = "Icmp"
    case http = "Http"
    case tcp = "Tcp"
}

public enum CaptiveState: String, Equatable, Sendable, Codable {
    case notDetected = "NotDetected"
    case detected = "Detected"
    case unknown = "Unknown"
}

public enum HealthLevel: String, Equatable, Sendable, Codable {
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
    case noInternet = "NoInternet"
    case captivePortal = "CaptivePortal"
    case offline = "Offline"
    case unknown = "Unknown"
}

/// Health thresholds (docs/sdd.md §12.4). All comparisons are strict `>`.
public enum HealthThresholds {
    public static let poorLoss = 5.0
    public static let poorJitter = 50.0
    public static let poorLatency = 150.0
    public static let fairLoss = 1.0
    public static let fairJitter = 20.0
    public static let fairLatency = 60.0
}

public struct ProbeStats: Equatable, Sendable, Codable {
    public var sent: Int
    public var received: Int
    public var lossPct: Double
    public var rttMinMs: Double?
    public var rttMedianMs: Double?
    public var rttMaxMs: Double?
    public var jitterMs: Double?

    public init(
        sent: Int, received: Int, lossPct: Double,
        rttMinMs: Double?, rttMedianMs: Double?, rttMaxMs: Double?, jitterMs: Double?
    ) {
        self.sent = sent
        self.received = received
        self.lossPct = lossPct
        self.rttMinMs = rttMinMs
        self.rttMedianMs = rttMedianMs
        self.rttMaxMs = rttMaxMs
        self.jitterMs = jitterMs
    }

    enum CodingKeys: String, CodingKey {
        case sent, received
        case lossPct = "loss_pct"
        case rttMinMs = "rtt_min_ms"
        case rttMedianMs = "rtt_median_ms"
        case rttMaxMs = "rtt_max_ms"
        case jitterMs = "jitter_ms"
    }
}

public struct TargetResult: Equatable, Sendable, Identifiable {
    public var id: String { "\(group.rawValue)/\(label)/\(target)" }
    public var label: String
    public var group: ProbeGroup
    public var method: ProbeMethod
    /// Gateway IP, URL, or `host:port`.
    public var target: String
    public var stats: ProbeStats?
    public var error: String?

    public init(label: String, group: ProbeGroup, method: ProbeMethod, target: String, stats: ProbeStats?, error: String?) {
        self.label = label
        self.group = group
        self.method = method
        self.target = target
        self.stats = stats
        self.error = error
    }
}

public struct GroupSummary: Equatable, Sendable, Codable {
    public var group: ProbeGroup
    public var sent: Int
    public var received: Int
    public var lossPct: Double
    public var bestLabel: String?
    public var medianMs: Double?
    public var jitterMs: Double?

    public init(
        group: ProbeGroup, sent: Int, received: Int, lossPct: Double,
        bestLabel: String?, medianMs: Double?, jitterMs: Double?
    ) {
        self.group = group
        self.sent = sent
        self.received = received
        self.lossPct = lossPct
        self.bestLabel = bestLabel
        self.medianMs = medianMs
        self.jitterMs = jitterMs
    }

    enum CodingKeys: String, CodingKey {
        case group, sent, received
        case lossPct = "loss_pct"
        case bestLabel = "best_label"
        case medianMs = "median_ms"
        case jitterMs = "jitter_ms"
    }
}

public struct NetworkReport: Equatable, Sendable {
    public var probedAt: Int64
    public var gateway: TargetResult?
    public var targets: [TargetResult]
    public var groups: [GroupSummary]
    public var captive: CaptiveState
    public var health: HealthLevel

    public init(
        probedAt: Int64, gateway: TargetResult?, targets: [TargetResult],
        groups: [GroupSummary], captive: CaptiveState, health: HealthLevel
    ) {
        self.probedAt = probedAt
        self.gateway = gateway
        self.targets = targets
        self.groups = groups
        self.captive = captive
        self.health = health
    }

    public func summary(_ group: ProbeGroup) -> GroupSummary? {
        groups.first { $0.group == group }
    }
}

public struct SpeedItem: Equatable, Sendable, Identifiable {
    public var id: String { "\(group)-\(direction)" }
    /// `domestic` / `overseas`
    public var group: String
    /// `down` / `up`
    public var direction: String
    public var bytes: Int64
    public var elapsedMs: Int64
    public var mbps: Double?
    public var error: String?

    public init(group: String, direction: String, bytes: Int64, elapsedMs: Int64, mbps: Double?, error: String?) {
        self.group = group
        self.direction = direction
        self.bytes = bytes
        self.elapsedMs = elapsedMs
        self.mbps = mbps
        self.error = error
    }
}

public struct SpeedTestReport: Equatable, Sendable {
    public var startedAt: Int64
    public var finishedAt: Int64?
    public var items: [SpeedItem]

    public init(startedAt: Int64, finishedAt: Int64?, items: [SpeedItem]) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.items = items
    }
}

// MARK: - Pure functions

public enum NetworkParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case parse(String)

    public var description: String {
        switch self {
        case .parse(let msg): return "parse error: \(msg)"
        }
    }
}

public struct PingParse: Equatable, Sendable {
    public var sent: Int
    public var rttsMs: [Double]

    public init(sent: Int, rttsMs: [Double]) {
        self.sent = sent
        self.rttsMs = rttsMs
    }
}

/// Round half away from zero to 0.1 (`r1`, docs/sdd.md §12.3).
func r1(_ x: Double) -> Double {
    (x * 10).rounded() / 10
}

/// Leading-digit run immediately before `index` (e.g. "5" in "5 packets").
private func digitsBefore(_ s: Substring) -> String {
    String(s.reversed().prefix { $0.isNumber }.reversed())
}

/// Parse macOS / Linux iputils `ping` output (docs/sdd.md §12.3).
public func parsePing(_ text: String) throws -> PingParse {
    guard let range = text.range(of: " packets transmitted") else {
        throw NetworkParseError.parse("no `packets transmitted` summary")
    }
    guard let sent = Int(digitsBefore(text[..<range.lowerBound])) else {
        throw NetworkParseError.parse("bad `packets transmitted` count")
    }

    var rtts: [Double] = []
    for line in text.split(separator: "\n") {
        guard line.contains("icmp_seq="), !line.contains("DUP!"),
            let timeRange = line.range(of: "time=")
        else { continue }
        let number = line[timeRange.upperBound...].prefix { $0.isNumber || $0 == "." }
        if let value = Double(number) {
            rtts.append(value)
        }
    }
    return PingParse(sent: sent, rttsMs: rtts)
}

private func lossPct(sent: Int, received: Int) -> Double {
    guard sent > 0 else { return 100.0 }
    return r1(Double(max(0, sent - received)) * 100.0 / Double(sent))
}

/// Sample statistics (docs/sdd.md §12.3). `rttsMs` is in arrival order.
public func probeStats(sent: Int, rttsMs: [Double]) -> ProbeStats {
    let n = rttsMs.count
    var stats = ProbeStats(
        sent: sent, received: n, lossPct: lossPct(sent: sent, received: n),
        rttMinMs: nil, rttMedianMs: nil, rttMaxMs: nil, jitterMs: nil)
    if n > 0 {
        let sorted = rttsMs.sorted()
        let median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        stats.rttMinMs = r1(sorted[0])
        stats.rttMedianMs = r1(median)
        stats.rttMaxMs = r1(sorted[n - 1])
    }
    if n >= 2 {
        var acc = 0.0
        for i in 1..<n {
            acc += abs(rttsMs[i] - rttsMs[i - 1])
        }
        stats.jitterMs = r1(acc / Double(n - 1))
    }
    return stats
}

/// Group summary: loss accumulated over the whole group, latency/jitter from
/// the best (lowest-median) target (docs/sdd.md §12.4).
public func probeGroupSummary(_ group: ProbeGroup, _ results: [(label: String, stats: ProbeStats)]) -> GroupSummary? {
    guard !results.isEmpty else { return nil }
    let sent = results.reduce(0) { $0 + $1.stats.sent }
    let received = results.reduce(0) { $0 + $1.stats.received }
    var best: (label: String, stats: ProbeStats)?
    for result in results where result.stats.received > 0 {
        guard let median = result.stats.rttMedianMs else { continue }
        if let current = best, let currentMedian = current.stats.rttMedianMs, currentMedian <= median {
            continue
        }
        best = result
    }
    return GroupSummary(
        group: group, sent: sent, received: received,
        lossPct: lossPct(sent: sent, received: received),
        bestLabel: best?.label, medianMs: best?.stats.rttMedianMs, jitterMs: best?.stats.jitterMs)
}

/// Captive portal decision table (docs/sdd.md §12.5).
public func classifyCaptive(status: Int, body: String) -> CaptiveState {
    if status == 200, body.contains("Success") { return .notDetected }
    if (200...399).contains(status) { return .detected }
    return .unknown
}

public struct HealthInput: Equatable, Sendable, Codable {
    public var pathAvailable: Bool
    public var captive: CaptiveState
    public var gateway: ProbeStats?
    public var domestic: GroupSummary?
    public var overseas: GroupSummary?

    public init(pathAvailable: Bool, captive: CaptiveState, gateway: ProbeStats?, domestic: GroupSummary?, overseas: GroupSummary?) {
        self.pathAvailable = pathAvailable
        self.captive = captive
        self.gateway = gateway
        self.domestic = domestic
        self.overseas = overseas
    }

    enum CodingKeys: String, CodingKey {
        case pathAvailable = "path_available"
        case captive, gateway, domestic, overseas
    }
}

/// Health level decision table, first match wins (docs/sdd.md §12.4).
public func networkHealth(_ input: HealthInput) -> HealthLevel {
    if !input.pathAvailable { return .offline }
    if input.captive == .detected { return .captivePortal }

    let present = [input.domestic, input.overseas].compactMap { $0 }
    if !present.isEmpty, present.allSatisfy({ $0.received == 0 }) { return .noInternet }

    guard let domestic = input.domestic, let latency = domestic.medianMs else { return .unknown }

    // A gateway that drops all ICMP is excluded rather than counted as loss.
    let gateway = input.gateway.flatMap { $0.received > 0 ? $0 : nil }
    let loss = max(domestic.lossPct, gateway?.lossPct ?? 0)
    let jitter = max(domestic.jitterMs ?? 0, gateway?.jitterMs ?? 0)

    if loss > HealthThresholds.poorLoss || jitter > HealthThresholds.poorJitter || latency > HealthThresholds.poorLatency {
        return .poor
    }
    if loss > HealthThresholds.fairLoss || jitter > HealthThresholds.fairJitter || latency > HealthThresholds.fairLatency {
        return .fair
    }
    return .good
}

/// Throughput in Mbps (10^6 bit/s), 0.1 precision (docs/sdd.md §12.6).
public func throughputMbps(bytes: Int64, elapsedMs: Int64) -> Double? {
    guard bytes > 0, elapsedMs > 0 else { return nil }
    return r1(Double(bytes) * 8.0 / (Double(elapsedMs) * 1000.0))
}
