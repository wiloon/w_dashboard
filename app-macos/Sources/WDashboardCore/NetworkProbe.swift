// Network health collection (docs/sdd.md §12.3 / §12.5 / §12.6, ADR-014).
// Side-effecting: ping subprocess, HTTP RTT, TCP connects, captive check and
// speed tests. Not covered by vectors; every result is reduced through the
// pure functions in Network.swift. Measurements follow the *actual path*
// (default route + system proxy); only the captive check binds to the
// physical interface and bypasses proxies.

import CoreWLAN
import Foundation
import Network

let gatewayLabel = "Gateway"

// MARK: - Probe round

/// One light probe round: gateway + every configured target + captive check,
/// all concurrently (samples within one target are sequential). Never fails as
/// a whole — per-target failures land in `TargetResult.error` (SDD §2).
public func probeNetwork(config: NetworkConfig, pathAvailable: Bool) async -> NetworkReport {
    let now = Int64(Date().timeIntervalSince1970)
    guard pathAvailable else {
        let targets = config.targets.map {
            TargetResult(label: $0.label, group: $0.group, method: $0.method, target: $0.displayTarget, stats: nil, error: "no network")
        }
        return NetworkReport(probedAt: now, gateway: nil, targets: targets, groups: [], captive: .unknown, health: .offline)
    }

    let samples = config.probeSamples
    let timeout = TimeInterval(config.probeTimeoutMs) / 1000

    async let gateway = runBlocking { probeGateway(samples: samples, timeout: timeout) }
    async let captive = runBlocking { checkCaptive() }
    let targets = await withTaskGroup(of: (Int, TargetResult).self) { group in
        for (index, target) in config.targets.enumerated() {
            group.addTask {
                (index, await runBlocking { probeTarget(target, samples: samples, timeout: timeout) })
            }
        }
        var results = [TargetResult?](repeating: nil, count: config.targets.count)
        for await (index, result) in group {
            results[index] = result
        }
        return results.compactMap { $0 }
    }

    let gatewayResult = await gateway
    let captiveState = await captive

    let groups: [GroupSummary] = [ProbeGroup.domestic, .overseas, .home].compactMap { group in
        let members = targets.filter { $0.group == group }.compactMap { t in t.stats.map { (label: t.label, stats: $0) } }
        return probeGroupSummary(group, members)
    }
    let health = networkHealth(
        HealthInput(
            pathAvailable: true, captive: captiveState, gateway: gatewayResult.stats,
            domestic: groups.first { $0.group == .domestic },
            overseas: groups.first { $0.group == .overseas }))

    return NetworkReport(
        probedAt: Int64(Date().timeIntervalSince1970), gateway: gatewayResult, targets: targets,
        groups: groups, captive: captiveState, health: health)
}

/// Run blocking work (subprocesses, semaphores) off the cooperative pool.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}

// MARK: - Gateway (ICMP)

/// Name of the Wi-Fi interface, if any (`en0` on most Macs).
public func wifiInterfaceName() -> String? {
    CWWiFiClient.shared().interface()?.interfaceName
}

/// Router of the *physical* interface, not the VPN tunnel (docs/sdd.md §12.3
/// step 1): the Wi-Fi interface first, then other `en*` interfaces.
func physicalGateway() -> String? {
    var candidates: [String] = []
    if let wifi = wifiInterfaceName() { candidates.append(wifi) }
    candidates += (0..<10).map { "en\($0)" }.filter { !candidates.contains($0) }
    for iface in candidates {
        guard let result = try? runProcess("/usr/sbin/ipconfig", args: ["getoption", iface, "router"], timeout: 2),
            result.succeeded
        else { continue }
        let router = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !router.isEmpty { return router }
    }
    return nil
}

func probeGateway(samples: Int, timeout: TimeInterval) -> TargetResult {
    guard let gateway = physicalGateway() else {
        return TargetResult(label: gatewayLabel, group: .gateway, method: .icmp, target: "", stats: nil, error: "no gateway")
    }
    let totalSecs = Int((Double(samples) * 0.2 + timeout).rounded(.up)) + 1
    do {
        // ping exits non-zero when nothing came back; the output is still parsed.
        let result = try runProcess(
            "/sbin/ping", args: ["-c", "\(samples)", "-i", "0.2", "-t", "\(totalSecs)", gateway],
            timeout: TimeInterval(totalSecs + 2))
        let parsed = try parsePing(result.stdout)
        return TargetResult(
            label: gatewayLabel, group: .gateway, method: .icmp, target: gateway,
            stats: probeStats(sent: parsed.sent, rttsMs: parsed.rttsMs), error: nil)
    } catch {
        return TargetResult(label: gatewayLabel, group: .gateway, method: .icmp, target: gateway, stats: nil, error: "\(error)")
    }
}

// MARK: - Remote targets

func probeTarget(_ target: NetworkTarget, samples: Int, timeout: TimeInterval) -> TargetResult {
    let (rtts, error): ([Double], String?)
    switch target.method {
    case .tcp:
        (rtts, error) = tcpSamples(host: target.host ?? "", port: target.port ?? 0, samples: samples, timeout: timeout)
    default:
        (rtts, error) = httpSamples(url: target.url ?? "", samples: samples, timeout: timeout)
    }
    return TargetResult(
        label: target.label, group: target.group, method: target.method, target: target.displayTarget,
        stats: probeStats(sent: samples, rttsMs: rtts), error: error)
}

/// Collects the last metrics + completion of one task; everything runs on the
/// session's serial delegate queue.
private final class HTTPProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var metrics: URLSessionTaskMetrics?
    var error: Error?
    let done = DispatchSemaphore(value: 0)

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics = metrics
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.error = error
        done.signal()
    }
}

private func shortError(_ error: Error) -> String {
    (error as? URLError).map { $0.localizedDescription } ?? "\(error)"
}

/// HTTP RTT (docs/sdd.md §12.3): one uncounted warm-up request, then
/// `samples` sequential GETs on the reused connection; each sample is
/// request start -> response headers. Any HTTP status counts.
func httpSamples(url: String, samples: Int, timeout: TimeInterval) -> ([Double], String?) {
    guard let requestURL = URL(string: url) else { return ([], "invalid url") }

    let configuration = URLSessionConfiguration.ephemeral  // honours the system proxy
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = timeout
    configuration.httpMaximumConnectionsPerHost = 1
    let delegate = HTTPProbeDelegate()
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    defer { session.invalidateAndCancel() }

    var request = URLRequest(url: requestURL)
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

    /// One request; returns its RTT in ms, or the error.
    func once() -> Result<Double, Error> {
        delegate.metrics = nil
        delegate.error = nil
        let task = session.dataTask(with: request)
        task.resume()
        if delegate.done.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            _ = delegate.done.wait(timeout: .now() + 1)
            return .failure(URLError(.timedOut))
        }
        var result: Result<Double, Error> = .failure(URLError(.unknown))
        queue.addOperations(
            [
                BlockOperation {
                    if let error = delegate.error {
                        result = .failure(error)
                    } else if let tx = delegate.metrics?.transactionMetrics.last,
                        let start = tx.requestStartDate, let end = tx.responseStartDate
                    {
                        result = .success(end.timeIntervalSince(start) * 1000)
                    }
                }
            ], waitUntilFinished: true)
        return result
    }

    if case .failure(let error) = once() {
        return ([], shortError(error))
    }
    var rtts: [Double] = []
    var lastError: String?
    for _ in 0..<samples {
        switch once() {
        case .success(let rtt): rtts.append(rtt)
        case .failure(let error): lastError = shortError(error)
        }
    }
    return (rtts, rtts.isEmpty ? lastError : nil)
}

/// Resolve `host` once (untimed) to a numeric address string.
func resolveHost(_ host: String) -> String? {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var info: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return nil }
    defer { freeaddrinfo(info) }
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
    else { return nil }
    return String(cString: buffer)
}

/// TCP handshake time to an already-resolved address; nil on failure/timeout.
func tcpConnectOnce(address: String, port: Int, timeout: TimeInterval) -> Double? {
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
    let connection = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: .tcp)
    let done = DispatchSemaphore(value: 0)
    let queue = DispatchQueue(label: "w_dashboard.tcp-probe")
    var readyAt: Date?
    let start = Date()
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            readyAt = Date()
            done.signal()
        case .failed, .waiting, .cancelled:
            done.signal()
        default:
            break
        }
    }
    connection.start(queue: queue)
    _ = done.wait(timeout: .now() + timeout)
    connection.stateUpdateHandler = nil
    connection.cancel()
    return queue.sync { readyAt.map { $0.timeIntervalSince(start) * 1000 } }
}

func tcpSamples(host: String, port: Int, samples: Int, timeout: TimeInterval) -> ([Double], String?) {
    guard let address = resolveHost(host) else { return ([], "cannot resolve \(host)") }
    var rtts: [Double] = []
    for _ in 0..<samples {
        if let rtt = tcpConnectOnce(address: address, port: port, timeout: timeout) {
            rtts.append(rtt)
        }
    }
    return (rtts, rtts.isEmpty ? "connect failed" : nil)
}

// MARK: - Captive portal

/// The physical Wi-Fi interface, else wired Ethernet. Merely prohibiting
/// tunnel interfaces is not enough: under a full-tunnel VPN the system path
/// only offers `utun*`, so the connection must be pinned to the NIC itself.
func physicalInterface() -> NWInterface? {
    for type in [NWInterface.InterfaceType.wifi, .wiredEthernet] {
        let monitor = NWPathMonitor(requiredInterfaceType: type)
        let updated = DispatchSemaphore(value: 0)
        var found: NWInterface?
        let queue = DispatchQueue(label: "w_dashboard.iface-lookup")
        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied {
                found = path.availableInterfaces.first { $0.type == type }
            }
            updated.signal()
        }
        monitor.start(queue: queue)
        _ = updated.wait(timeout: .now() + 1)
        monitor.cancel()
        if let found = queue.sync(execute: { found }) { return found }
    }
    return nil
}

/// Captive check (docs/sdd.md §12.5): plain HTTP to captive.apple.com pinned
/// to the physical interface (no tunnel, no proxy), no redirect following.
func checkCaptive(timeout: TimeInterval = 5) -> CaptiveState {
    guard let interface = physicalInterface() else { return .unknown }
    let parameters = NWParameters.tcp
    parameters.requiredInterface = interface
    parameters.preferNoProxies = true
    let connection = NWConnection(host: "captive.apple.com", port: 80, using: parameters)
    let queue = DispatchQueue(label: "w_dashboard.captive")
    let done = DispatchSemaphore(value: 0)
    var buffer = Data()

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data { buffer.append(data) }
            if isComplete || error != nil || buffer.count > 256 * 1024 {
                done.signal()
            } else {
                receive()
            }
        }
    }

    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            let request = "GET /hotspot-detect.html HTTP/1.1\r\nHost: captive.apple.com\r\nConnection: close\r\nUser-Agent: CaptiveNetworkSupport\r\n\r\n"
            connection.send(content: request.data(using: .utf8), completion: .contentProcessed { _ in receive() })
        case .failed, .waiting:
            done.signal()
        default:
            break
        }
    }
    connection.start(queue: queue)
    let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
    connection.cancel()
    let response = queue.sync { buffer }
    guard !timedOut || !response.isEmpty, let text = String(data: response, encoding: .utf8) ?? String(data: response, encoding: .isoLatin1)
    else { return .unknown }

    // "HTTP/1.1 200 OK\r\n..." — status code is the second token of line one.
    let statusLine = text.prefix { $0 != "\r" && $0 != "\n" }
    let parts = statusLine.split(separator: " ")
    guard parts.count >= 2, let status = Int(parts[1]) else { return .unknown }
    let body = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
    return classifyCaptive(status: status, body: body)
}

// MARK: - Speed test

/// Run the four manual speed-test steps in order (docs/sdd.md §12.6):
/// domestic down/up, overseas down/up. `onStep` gets each step key
/// ("domestic-down", …) before it starts.
public func runSpeedtest(config: NetworkConfig, onStep: @escaping @Sendable (String) -> Void) async -> SpeedTestReport {
    let started = Int64(Date().timeIntervalSince1970)
    let maxBytes = Int64(config.speedtestMaxMB) * 1_000_000
    let maxSecs = TimeInterval(config.speedtestMaxSecs)
    let steps: [(group: String, direction: String, url: String)] = [
        ("domestic", "down", config.speedtestDomesticDownloadURL),
        ("domestic", "up", config.speedtestDomesticUploadURL),
        ("overseas", "down", config.speedtestOverseasDownloadURL),
        ("overseas", "up", config.speedtestOverseasUploadURL),
    ]
    var items: [SpeedItem] = []
    for step in steps {
        onStep("\(step.group)-\(step.direction)")
        let measured = await runBlocking {
            step.direction == "down"
                ? measureDownload(url: step.url, maxBytes: maxBytes, maxSecs: maxSecs)
                : measureUpload(url: step.url, maxBytes: maxBytes, maxSecs: maxSecs)
        }
        items.append(
            SpeedItem(
                group: step.group, direction: step.direction, bytes: measured.bytes, elapsedMs: measured.elapsedMs,
                mbps: measured.error == nil ? throughputMbps(bytes: measured.bytes, elapsedMs: measured.elapsedMs) : nil,
                error: measured.error))
    }
    return SpeedTestReport(startedAt: started, finishedAt: Int64(Date().timeIntervalSince1970), items: items)
}

struct TransferMeasurement: Sendable {
    var bytes: Int64
    var elapsedMs: Int64
    var error: String?
}

/// Speed-test transfer meter. All state is touched only on `queue` (the
/// session's delegate queue and the stop timer share it).
private final class TransferMeter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "w_dashboard.speedtest")
    let maxBytes: Int64
    let maxSecs: TimeInterval
    let upload: Bool
    var bytes: Int64 = 0
    var startedAt: Date?
    var stoppedAt: Date?
    var stoppedByUs = false
    var error: String?
    let done = DispatchSemaphore(value: 0)

    init(maxBytes: Int64, maxSecs: TimeInterval, upload: Bool) {
        self.maxBytes = maxBytes
        self.maxSecs = maxSecs
        self.upload = upload
    }

    /// Start the clock (download: first body byte; upload: request start) and
    /// arm the time cap.
    func startClock(_ task: URLSessionTask) {
        guard startedAt == nil else { return }
        startedAt = Date()
        queue.asyncAfter(deadline: .now() + maxSecs) { [weak self, weak task] in
            self?.stop(task)
        }
    }

    func stop(_ task: URLSessionTask?) {
        guard stoppedAt == nil else { return }
        stoppedAt = Date()
        stoppedByUs = true
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode), !stoppedByUs {
            error = "HTTP \(http.statusCode)"
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !upload else { return }
        startClock(dataTask)
        bytes += Int64(data.count)
        if bytes >= maxBytes { stop(dataTask) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard upload else { return }
        bytes = totalBytesSent
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if stoppedAt == nil { stoppedAt = Date() }
        if let error, !stoppedByUs, self.error == nil {
            self.error = shortError(error)
        }
        done.signal()
    }

    var measurement: TransferMeasurement {
        guard let startedAt, let stoppedAt else {
            return TransferMeasurement(bytes: bytes, elapsedMs: 0, error: error ?? "no data received")
        }
        let elapsed = Int64((stoppedAt.timeIntervalSince(startedAt) * 1000).rounded())
        return TransferMeasurement(bytes: bytes, elapsedMs: elapsed, error: error)
    }
}

private func speedtestSession(_ meter: TransferMeter) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral  // honours the system proxy
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 10
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.underlyingQueue = meter.queue
    return URLSession(configuration: configuration, delegate: meter, delegateQueue: queue)
}

func measureDownload(url: String, maxBytes: Int64, maxSecs: TimeInterval) -> TransferMeasurement {
    guard let requestURL = URL(string: url) else { return TransferMeasurement(bytes: 0, elapsedMs: 0, error: "invalid url") }
    let meter = TransferMeter(maxBytes: maxBytes, maxSecs: maxSecs, upload: false)
    let session = speedtestSession(meter)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: URLRequest(url: requestURL))
    task.resume()
    // Connect + first byte may take up to the request timeout, then maxSecs.
    if meter.done.wait(timeout: .now() + maxSecs + 15) == .timedOut {
        meter.queue.sync { meter.stop(task) }
        _ = meter.done.wait(timeout: .now() + 2)
    }
    return meter.queue.sync { meter.measurement }
}

/// Pseudo-random payload so a proxy cannot compress it (docs/sdd.md §12.6).
func randomPayload(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    var data = Data(count: count)
    data.withUnsafeMutableBytes { raw in
        let words = raw.bindMemory(to: UInt64.self)
        for i in words.indices { words[i] = generator.next() }
        for i in (words.count * 8)..<count { raw[i] = UInt8.random(in: 0...255, using: &generator) }
    }
    return data
}

func measureUpload(url: String, maxBytes: Int64, maxSecs: TimeInterval) -> TransferMeasurement {
    guard let requestURL = URL(string: url) else { return TransferMeasurement(bytes: 0, elapsedMs: 0, error: "invalid url") }
    let meter = TransferMeter(maxBytes: maxBytes, maxSecs: maxSecs, upload: true)
    let session = speedtestSession(meter)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: requestURL)
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let task = session.uploadTask(with: request, from: randomPayload(Int(maxBytes)))
    meter.queue.sync { meter.startClock(task) }
    task.resume()
    if meter.done.wait(timeout: .now() + maxSecs + 15) == .timedOut {
        meter.queue.sync { meter.stop(task) }
        _ = meter.done.wait(timeout: .now() + 2)
    }
    return meter.queue.sync { meter.measurement }
}
