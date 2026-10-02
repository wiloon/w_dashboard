import SwiftUI
import WDashboardCore

/// The "Network" tab (docs/sdd.md §12.8, ADR-014): overview, Wi-Fi link, latency
/// table and manual speed test. Pure rendering of `appState.networkReport` /
/// `speedReport` / `linkInfo` — every metric and the health level come from the
/// core.
struct NetworkView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                overview
                wifiCard
                latencyCard
                speedCard
            }
        }
        .onAppear { appState.requestLocationIfNeeded() }
    }

    // MARK: Overview

    private var overview: some View {
        let health = appState.networkReport?.health
        return HStack(alignment: .center, spacing: 16) {
            Circle()
                .fill(health.map(healthColor) ?? .gray)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(health.map(healthTitle) ?? "Checking…")
                    .font(.system(size: 22, weight: .semibold))
                Text(health.map(healthDetail) ?? "Running the first probe…")
                    .foregroundStyle(.secondary)
                Text(pathLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    appState.requestProbe()
                } label: {
                    HStack(spacing: 6) {
                        if appState.networkProbing {
                            ProgressView().controlSize(.small)
                        }
                        Text("Re-check")
                    }
                }
                .disabled(appState.networkProbing || appState.speedtestStep != nil)
                if let report = appState.networkReport {
                    Text("Probed at \(timeString(report.probedAt))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }

    private var pathLine: String {
        let link = appState.linkInfo
        guard link.pathAvailable else { return "No network" }
        var parts: [String] = []
        if let wifi = link.wifi {
            parts.append(wifi.ssid.map { "Wi-Fi \"\($0)\"" } ?? (appState.locationAuthorized ? "Wi-Fi" : "Wi-Fi (name needs Location permission)"))
        } else {
            parts.append("Not on Wi-Fi")
        }
        if let tunnel = link.tunnelInterface { parts.append("via VPN (\(tunnel))") }
        if link.systemProxy { parts.append("system proxy on") }
        return parts.joined(separator: " · ")
    }

    // MARK: Wi-Fi

    private var wifiCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wi-Fi").font(.headline)
            if let wifi = appState.linkInfo.wifi {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        metric("Network", wifi.ssid ?? "(needs Location permission)")
                        metric("Signal", "\(wifi.rssi) dBm · \(rssiLabel(wifi.rssi))")
                        metric("Noise", "\(wifi.noise) dBm")
                    }
                    GridRow {
                        metric("SNR", "\(wifi.snr) dB")
                        metric("Link rate", String(format: "%.0f Mbps", wifi.txRateMbps))
                        metric("Channel", [wifi.channel.map { "\($0)" }, wifi.band].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            } else {
                Text("Not connected via Wi-Fi").foregroundStyle(.secondary).font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded))
        }
    }

    // MARK: Latency

    private var latencyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latency").font(.headline)
            if let report = appState.networkReport {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Target")
                        Text("Method")
                        Text("Median").gridColumnAlignment(.trailing)
                        Text("Jitter").gridColumnAlignment(.trailing)
                        Text("Loss").gridColumnAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let gateway = report.gateway {
                        targetRow(gateway, topLevel: true)
                    }
                    ForEach([ProbeGroup.domestic, .overseas, .home], id: \.self) { group in
                        let members = report.targets.filter { $0.group == group }
                        if !members.isEmpty {
                            groupHeader(groupTitle(group), summary: report.summary(group))
                            ForEach(members) { targetRow($0) }
                        }
                    }
                }
                Text("Overseas and Home do not affect the health level. Latency is the HTTP round trip on a reused connection (TCP handshake for Home, ICMP for the gateway).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Checking…").foregroundStyle(.secondary).font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }

    @ViewBuilder
    private func groupHeader(_ title: String, summary: GroupSummary?) -> some View {
        GridRow {
            Text(title).font(.subheadline.bold())
            Text("")
            Text(ms(summary?.medianMs)).font(.subheadline.bold())
            Text(ms(summary?.jitterMs)).font(.subheadline.bold())
            Text(summary.map { pct($0.lossPct) } ?? "").font(.subheadline.bold())
        }
        .padding(.top, 4)
    }

    /// `topLevel`: the gateway, which has no group summary, renders as its own
    /// group-level row instead of under a header.
    private func targetRow(_ target: TargetResult, topLevel: Bool = false) -> some View {
        let failed = target.stats.map { $0.received == 0 } ?? true
        return GridRow {
            Text(target.label)
                .font(topLevel ? .subheadline.bold() : .body)
                .padding(.leading, topLevel ? 0 : 12)
            Text(methodLabel(target.method)).foregroundStyle(.secondary)
            Text(ms(target.stats?.rttMedianMs))
            Text(ms(target.stats?.jitterMs))
            Text(target.stats.map { pct($0.lossPct) } ?? "—")
                .foregroundStyle((target.stats?.lossPct ?? 100) > 0 ? .red : .primary)
        }
        .font(.system(.body, design: .rounded))
        .opacity(failed ? 0.5 : 1)
        .help(target.error.map { "\(target.target)\n\($0)" } ?? target.target)
    }

    // MARK: Speed test

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Speed test").font(.headline)
                Spacer()
                if let step = appState.speedtestStep {
                    ProgressView().controlSize(.small)
                    Text("Testing \(stepLabel(step))…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Run speed test") { appState.startSpeedtest() }
                    .disabled(appState.speedtestStep != nil || appState.networkProbing)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Download").font(.caption).foregroundStyle(.secondary)
                    Text("Upload").font(.caption).foregroundStyle(.secondary)
                }
                speedRow("Domestic (Apple)", group: "domestic")
                speedRow("Overseas (Cloudflare)", group: "overseas")
            }
            HStack {
                if let report = appState.speedReport {
                    Text("Tested at \(timeString(report.startedAt))")
                }
                Spacer()
                Text("Uses about \(appState.config.network.speedtestMaxMB * 2)–\(appState.config.network.speedtestMaxMB * 4) MB per run. Single stream, so cross-border results may read low.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }

    private func speedRow(_ title: String, group: String) -> some View {
        GridRow {
            Text(title)
            speedValue(group: group, direction: "down")
            speedValue(group: group, direction: "up")
        }
    }

    private func speedValue(group: String, direction: String) -> some View {
        let item = appState.speedReport?.items.first { $0.group == group && $0.direction == direction }
        let text: String
        if let mbps = item?.mbps {
            text = String(format: "%.1f Mbps", mbps)
        } else if item?.error != nil {
            text = "Failed"
        } else {
            text = "—"
        }
        return Text(text)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(item?.error != nil ? .red : .primary)
            .help(item?.error ?? "")
    }

    // MARK: Labels

    private func healthTitle(_ level: HealthLevel) -> String {
        switch level {
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Poor"
        case .noInternet: return "No internet"
        case .captivePortal: return "Sign-in required"
        case .offline: return "Offline"
        case .unknown: return "Unknown"
        }
    }

    private func healthDetail(_ level: HealthLevel) -> String {
        switch level {
        case .good: return "Latency, jitter and loss are all within normal range"
        case .fair: return "Usable, but latency, jitter or loss is elevated"
        case .poor: return "Latency, jitter or loss is well above normal — expect a degraded experience"
        case .noInternet: return "Neither domestic nor overseas targets are reachable"
        case .captivePortal: return "Connected to the hotspot, but you must sign in on its web page first"
        case .offline: return "No network connection"
        case .unknown: return "Domestic targets are unreachable — cannot judge"
        }
    }

    /// docs/sdd.md §12.8 step 4 color semantics.
    private func healthColor(_ level: HealthLevel) -> Color {
        switch level {
        case .good: return .green
        case .fair: return .yellow
        case .poor, .noInternet: return .red
        case .captivePortal: return .orange
        case .offline, .unknown: return .gray
        }
    }

    private func groupTitle(_ group: ProbeGroup) -> String {
        switch group {
        case .gateway: return "Gateway"
        case .domestic: return "Domestic"
        case .overseas: return "Overseas"
        case .home: return "Home"
        }
    }

    private func methodLabel(_ method: ProbeMethod) -> String {
        switch method {
        case .icmp: return "ICMP"
        case .http: return "HTTP"
        case .tcp: return "TCP"
        }
    }

    private func stepLabel(_ step: String) -> String {
        switch step {
        case "domestic-down": return "domestic download"
        case "domestic-up": return "domestic upload"
        case "overseas-down": return "overseas download"
        case "overseas-up": return "overseas upload"
        default: return "setup"
        }
    }

    private func rssiLabel(_ rssi: Int) -> String {
        if rssi >= -60 { return "strong" }
        if rssi >= -70 { return "fair" }
        if rssi >= -80 { return "weak" }
        return "very weak"
    }

    private func ms(_ value: Double?) -> String {
        value.map { String(format: "%.1f ms", $0) } ?? "—"
    }

    private func pct(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func timeString(_ unix: Int64) -> String {
        Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
