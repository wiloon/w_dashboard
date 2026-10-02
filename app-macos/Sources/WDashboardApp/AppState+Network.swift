// Network health scheduling and link info — the app-layer half of
// docs/sdd.md §12 (§12.7 link info, §12.8 UI duties, ADR-014). Probing,
// speed tests and every metric/health decision are in WDashboardCore; this
// file only decides *when* to run them and gathers display-only link info
// (path / VPN / system proxy / Wi-Fi).

import CoreLocation
import CoreWLAN
import Foundation
import Network
import WDashboardCore

struct WifiInfo: Equatable {
    /// nil without Location permission (docs/sdd.md §12.7).
    var ssid: String?
    var rssi: Int
    var noise: Int
    var txRateMbps: Double
    var channel: Int?
    var band: String?

    var snr: Int { rssi - noise }
}

struct LinkInfo: Equatable {
    var pathAvailable = true
    /// Default path runs over this tunnel (`utun*` / `ipsec*` / `ppp*`), if any.
    var tunnelInterface: String?
    var systemProxy = false
    /// nil when not associated to a Wi-Fi network.
    var wifi: WifiInfo?
}

extension AppState {
    /// Called from `start()`: link info, path monitors, the startup probe and the
    /// periodic probe timer (docs/sdd.md §12.8 step 2).
    func startNetwork() {
        guard config.network.enabled else { return }
        startPathMonitors()
        refreshLinkInfo()
        requestProbe()

        networkTimerTask?.cancel()
        let interval = config.network.probeIntervalSecs
        guard interval > 0 else { return }
        networkTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                self?.requestProbe()
            }
        }
    }

    /// One light probe round. A round already running (or a speed test) only
    /// marks one pending re-run, executed once it is done (§12.8 step 2).
    func requestProbe() {
        guard config.network.enabled else { return }
        if networkProbing || speedtestStep != nil {
            probePending = true
            return
        }
        networkProbing = true
        let networkConfig = config.network
        let available = linkInfo.pathAvailable
        Task { [weak self] in
            let report = await probeNetwork(config: networkConfig, pathAvailable: available)
            guard let self else { return }
            self.networkReport = report
            self.networkProbing = false
            self.refreshLinkInfo()
            self.runPendingProbe()
        }
    }

    private func runPendingProbe() {
        guard probePending, speedtestStep == nil, !networkProbing else { return }
        probePending = false
        requestProbe()
    }

    /// Manual speed test (docs/sdd.md §12.6). Light probes are deferred until it
    /// finishes.
    func startSpeedtest() {
        guard config.network.enabled, speedtestStep == nil, !networkProbing else { return }
        speedtestStep = "starting"
        let networkConfig = config.network
        let onStep: @Sendable (String) -> Void = { [weak self] step in
            Task { @MainActor in
                guard let self, self.speedtestStep != nil else { return }
                self.speedtestStep = step
            }
        }
        Task { [weak self] in
            let report = await runSpeedtest(config: networkConfig, onStep: onStep)
            guard let self else { return }
            self.speedReport = report
            self.speedtestStep = nil
            self.runPendingProbe()
        }
    }

    // ---------------- Path monitoring ----------------

    private func startPathMonitors() {
        pathMonitor?.cancel()
        wifiPathMonitor?.cancel()
        let queue = DispatchQueue(label: "w_dashboard.path-monitor")

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.defaultPath = path
                self?.handlePathUpdate()
            }
        }
        let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.wifiPath = path
                self?.handlePathUpdate()
            }
        }
        monitor.start(queue: queue)
        wifiMonitor.start(queue: queue)
        pathMonitor = monitor
        wifiPathMonitor = wifiMonitor
    }

    /// Re-probe ~3s after the network actually changed (docs/sdd.md §12.8 step
    /// 2). The baseline is recorded only once both monitors have reported —
    /// the startup probe already covers it.
    private func handlePathUpdate() {
        refreshLinkInfo()
        guard defaultPath != nil, wifiPath != nil else { return }
        let signature = pathSignature()
        defer { lastPathSignature = signature }
        guard let last = lastPathSignature, last != signature else { return }
        pathDebounceTask?.cancel()
        pathDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.requestProbe()
        }
    }

    private func pathSignature() -> String {
        let general = defaultPath.map { "\($0.status)|\($0.availableInterfaces.map(\.name))" } ?? "-"
        let wifi = wifiPath.map { "\($0.status)|\($0.gateways.map { "\($0)" })" } ?? "-"
        let ssid = linkInfo.wifi?.ssid ?? ""
        let channel = linkInfo.wifi?.channel.map(String.init) ?? ""
        return [general, wifi, ssid, channel].joined(separator: "#")
    }

    // ---------------- Link info (§12.7) ----------------

    func refreshLinkInfo() {
        var info = LinkInfo()
        if let path = defaultPath {
            info.pathAvailable = path.status == .satisfied
            if let primary = path.availableInterfaces.first?.name,
                ["utun", "ipsec", "ppp"].contains(where: { primary.hasPrefix($0) })
            {
                info.tunnelInterface = primary
            }
        }
        info.systemProxy = Self.systemProxyEnabled()
        info.wifi = Self.currentWifi()
        if info != linkInfo {
            linkInfo = info
        }
    }

    private static func systemProxyEnabled() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return false
        }
        let http = settings[kCFNetworkProxiesHTTPEnable as String] as? Int ?? 0
        let https = settings[kCFNetworkProxiesHTTPSEnable as String] as? Int ?? 0
        return http == 1 || https == 1
    }

    private static func currentWifi() -> WifiInfo? {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn(), let channel = iface.wlanChannel() else {
            return nil
        }
        let band: String?
        switch channel.channelBand {
        case .band2GHz: band = "2.4 GHz"
        case .band5GHz: band = "5 GHz"
        case .band6GHz: band = "6 GHz"
        default: band = nil
        }
        return WifiInfo(
            ssid: iface.ssid(), rssi: iface.rssiValue(), noise: iface.noiseMeasurement(),
            txRateMbps: iface.transmitRate(), channel: channel.channelNumber, band: band)
    }

    // ---------------- Location (SSID needs it, §12.7) ----------------

    var locationAuthorized: Bool {
        let status = locationManager.authorizationStatus
        return status == .authorizedAlways || status == .authorized
    }

    /// Ask once, on first visit to the Network tab. Only a bundled `.app` with
    /// the Info.plist usage strings can be granted; `swift run` stays without SSID.
    func requestLocationIfNeeded() {
        guard locationManager.authorizationStatus == .notDetermined else { return }
        locationManager.requestWhenInUseAuthorization()
        Task { [weak self] in
            // No delegate: just re-read link info once the prompt likely resolved.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                self.refreshLinkInfo()
                if self.locationManager.authorizationStatus != .notDetermined { return }
            }
        }
    }
}
