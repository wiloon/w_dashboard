// Config loading per docs/sdd.md §4. Mirrors app-linux/src/config.rs.
// `[chezmoi]` is accepted but ignored, matching the Linux side (that panel
// isn't implemented on either end yet).

import Foundation

public enum ConfigError: Error, CustomStringConvertible, Sendable {
    case io(String)
    case parse(String)

    public var description: String {
        switch self {
        case .io(let msg): return "failed to read config: \(msg)"
        case .parse(let msg): return "failed to parse config: \(msg)"
        }
    }
}

public struct RepoConfig: Equatable, Sendable {
    public var path: String
    public var name: String?

    public init(path: String, name: String?) {
        self.path = path
        self.name = name
    }
}

public struct ClockConfig: Equatable, Sendable {
    public var label: String
    public var tz: String

    public init(label: String, tz: String) {
        self.label = label
        self.tz = tz
    }
}

public struct WeatherConfig: Equatable, Sendable {
    public var location: String?
    public var latitude: Double?
    public var longitude: Double?
    public var temperatureUnit: String
    public var forecastDays: Int

    public init(location: String?, latitude: Double?, longitude: Double?, temperatureUnit: String, forecastDays: Int) {
        self.location = location
        self.latitude = latitude
        self.longitude = longitude
        self.temperatureUnit = temperatureUnit
        self.forecastDays = forecastDays
    }
}

/// `[pomodoro]` section (docs/sdd.md §11, ADR-012). Always present; an absent
/// section means the defaults below.
public struct PomodoroConfig: Equatable, Sendable {
    public var enabled: Bool
    public var focusMinutes: Int
    public var breakMinutes: Int
    public var notify: Bool
    public var sound: Bool
    /// Flash the menu-bar icon each morning if no focus session has been started
    /// yet that day (docs/sdd.md §11.4 step 8, ADR-012).
    public var morningNudge: Bool
    /// Beijing wall-clock time-of-day, as minutes since midnight, after which the
    /// morning nudge kicks in (`morning_nudge_after` `"HH:MM"` in the file).
    public var morningNudgeAfterMinutes: Int

    public init(
        enabled: Bool = true, focusMinutes: Int = 25, breakMinutes: Int = 5,
        notify: Bool = true, sound: Bool = true,
        morningNudge: Bool = true, morningNudgeAfterMinutes: Int = 9 * 60
    ) {
        self.enabled = enabled
        self.focusMinutes = focusMinutes
        self.breakMinutes = breakMinutes
        self.notify = notify
        self.sound = sound
        self.morningNudge = morningNudge
        self.morningNudgeAfterMinutes = morningNudgeAfterMinutes
    }
}

/// One `[[network_targets]]` entry (docs/sdd.md §12.2).
public struct NetworkTarget: Equatable, Sendable {
    public var label: String
    /// `.domestic` / `.overseas` / `.home` (never `.gateway`).
    public var group: ProbeGroup
    /// `.http` (needs `url`) or `.tcp` (needs `host` + `port`).
    public var method: ProbeMethod
    public var url: String?
    public var host: String?
    public var port: Int?

    public init(label: String, group: ProbeGroup, method: ProbeMethod, url: String? = nil, host: String? = nil, port: Int? = nil) {
        self.label = label
        self.group = group
        self.method = method
        self.url = url
        self.host = host
        self.port = port
    }

    /// URL for `.http`, `host:port` for `.tcp`.
    public var displayTarget: String {
        method == .tcp ? "\(host ?? ""):\(port ?? 0)" : (url ?? "")
    }
}

/// `[network]` section + `[[network_targets]]` (docs/sdd.md §12.2, ADR-014).
/// Always present; an absent section means the defaults below.
public struct NetworkConfig: Equatable, Sendable {
    public var enabled: Bool
    public var probeIntervalSecs: Int
    public var probeSamples: Int
    public var probeTimeoutMs: Int
    public var speedtestMaxSecs: Int
    public var speedtestMaxMB: Int
    public var speedtestDomesticDownloadURL: String
    public var speedtestDomesticUploadURL: String
    public var speedtestOverseasDownloadURL: String
    public var speedtestOverseasUploadURL: String
    public var targets: [NetworkTarget]

    public init(
        enabled: Bool = true, probeIntervalSecs: Int = 60, probeSamples: Int = 10, probeTimeoutMs: Int = 2000,
        speedtestMaxSecs: Int = 8, speedtestMaxMB: Int = 25,
        speedtestDomesticDownloadURL: String = "https://mensura.cdn-apple.com/api/v1/gm/large",
        speedtestDomesticUploadURL: String = "https://mensura.cdn-apple.com/api/v1/gm/slurp",
        speedtestOverseasDownloadURL: String = "https://speed.cloudflare.com/__down?bytes=25000000",
        speedtestOverseasUploadURL: String = "https://speed.cloudflare.com/__up",
        targets: [NetworkTarget] = defaultNetworkTargets()
    ) {
        self.enabled = enabled
        self.probeIntervalSecs = probeIntervalSecs
        self.probeSamples = probeSamples
        self.probeTimeoutMs = probeTimeoutMs
        self.speedtestMaxSecs = speedtestMaxSecs
        self.speedtestMaxMB = speedtestMaxMB
        self.speedtestDomesticDownloadURL = speedtestDomesticDownloadURL
        self.speedtestDomesticUploadURL = speedtestDomesticUploadURL
        self.speedtestOverseasDownloadURL = speedtestOverseasDownloadURL
        self.speedtestOverseasUploadURL = speedtestOverseasUploadURL
        self.targets = targets
    }
}

/// Built-in probe targets used when the file has no `[[network_targets]]`
/// (docs/sdd.md §4 / §12.2).
public func defaultNetworkTargets() -> [NetworkTarget] {
    [
        NetworkTarget(label: "AliDNS", group: .domestic, method: .http, url: "https://223.5.5.5/"),
        NetworkTarget(label: "Baidu", group: .domestic, method: .http, url: "https://www.baidu.com/favicon.ico"),
        NetworkTarget(label: "Cloudflare", group: .overseas, method: .http, url: "https://1.1.1.1/cdn-cgi/trace"),
        NetworkTarget(label: "GitHub", group: .overseas, method: .http, url: "https://github.com/robots.txt"),
        NetworkTarget(label: "Home", group: .home, method: .tcp, host: "home.wiloon.com", port: 443),
    ]
}

public struct Config: Equatable, Sendable {
    public var refreshIntervalSecs: Int
    public var commandTimeoutSecs: Int
    public var fetchRemote: Bool
    public var repos: [RepoConfig]
    public var clocks: [ClockConfig]
    public var weather: WeatherConfig?
    public var pomodoro: PomodoroConfig
    public var network: NetworkConfig

    public init(
        refreshIntervalSecs: Int,
        commandTimeoutSecs: Int,
        fetchRemote: Bool,
        repos: [RepoConfig],
        clocks: [ClockConfig],
        weather: WeatherConfig?,
        pomodoro: PomodoroConfig = PomodoroConfig(),
        network: NetworkConfig = NetworkConfig()
    ) {
        self.refreshIntervalSecs = refreshIntervalSecs
        self.commandTimeoutSecs = commandTimeoutSecs
        self.fetchRemote = fetchRemote
        self.repos = repos
        self.clocks = clocks
        self.weather = weather
        self.pomodoro = pomodoro
        self.network = network
    }

    public static func defaultConfig() -> Config {
        Config(
            refreshIntervalSecs: 900,
            commandTimeoutSecs: 20,
            fetchRemote: true,
            repos: [],
            clocks: defaultClocks(),
            weather: nil
        )
    }
}

public func defaultClocks() -> [ClockConfig] {
    [
        ClockConfig(label: "Beijing", tz: "Asia/Shanghai"),
        ClockConfig(label: "New York", tz: "America/New_York"),
    ]
}

/// Expand `$VAR` / `${VAR}` references using the current environment.
/// Unknown variables are left untouched (literal `$NAME`).
func expandEnv(_ input: String) -> String {
    var result = ""
    let chars = Array(input)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c != "$" {
            result.append(c)
            i += 1
            continue
        }
        if i + 1 < chars.count, chars[i + 1] == "{" {
            var j = i + 2
            var name = ""
            var closed = false
            while j < chars.count {
                if chars[j] == "}" {
                    closed = true
                    j += 1
                    break
                }
                name.append(chars[j])
                j += 1
            }
            if let val = ProcessInfo.processInfo.environment[name] {
                result.append(val)
            } else {
                result.append("${")
                result.append(name)
                if closed {
                    result.append("}")
                }
            }
            i = j
        } else {
            var j = i + 1
            var name = ""
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                name.append(chars[j])
                j += 1
            }
            if name.isEmpty {
                result.append("$")
                i += 1
            } else {
                if let val = ProcessInfo.processInfo.environment[name] {
                    result.append(val)
                } else {
                    result.append("$")
                    result.append(name)
                }
                i = j
            }
        }
    }
    return result
}

func expandTilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" {
        return home
    }
    if path.hasPrefix("~/") {
        return home + "/" + path.dropFirst(2)
    }
    return path
}

public func expandPath(_ raw: String) -> String {
    expandTilde(expandEnv(raw))
}

/// `$XDG_CONFIG_HOME/w_dashboard/config.toml`, falling back to
/// `~/.config/w_dashboard/config.toml`, per docs/sdd.md §4.
public func defaultConfigPath() -> String {
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
        return xdg + "/w_dashboard/config.toml"
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return home + "/.config/w_dashboard/config.toml"
}

private func readFileIfExists(_ path: String) throws -> String? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    do {
        return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        throw ConfigError.io(error.localizedDescription)
    }
}

/// Load and validate config. A missing file returns the built-in default
/// (empty repos), per docs/sdd.md §4.
public func loadConfig(path: String? = nil) throws -> Config {
    let path = path ?? defaultConfigPath()

    guard let text = try readFileIfExists(path) else {
        return Config.defaultConfig()
    }

    let doc: TOMLDocument
    do {
        doc = try parseTOML(text)
    } catch {
        throw ConfigError.parse("\(error)")
    }

    let refreshIntervalSecs = doc.general["refresh_interval_secs"]?.intValue ?? 900
    let commandTimeoutSecs = doc.general["command_timeout_secs"]?.intValue ?? 20
    let fetchRemote = doc.general["fetch_remote"]?.boolValue ?? true

    let repos: [RepoConfig] = doc.repos.map { raw in
        RepoConfig(path: expandPath(raw["path"]?.stringValue ?? ""), name: raw["name"]?.stringValue)
    }

    let clocks: [ClockConfig]
    if doc.clocks.isEmpty && text.range(of: "[[clocks]]") == nil {
        clocks = defaultClocks()
    } else {
        var parsed: [ClockConfig] = []
        for raw in doc.clocks {
            let label = raw["label"]?.stringValue ?? ""
            let tz = raw["tz"]?.stringValue ?? ""
            guard TimeZone(identifier: tz) != nil else {
                throw ConfigError.parse("clocks: invalid IANA tz id \"\(tz)\" for label \"\(label)\"")
            }
            parsed.append(ClockConfig(label: label, tz: tz))
        }
        clocks = parsed
    }

    var weather: WeatherConfig?
    if let rawWeather = doc.weather {
        let location = rawWeather["location"]?.stringValue
        let latitude = rawWeather["latitude"]?.doubleValue
        let longitude = rawWeather["longitude"]?.doubleValue
        let hasLocation = !(location ?? "").isEmpty
        let hasCoords = latitude != nil && longitude != nil
        guard hasLocation || hasCoords else {
            throw ConfigError.parse("weather: requires either `location` or both `latitude` and `longitude`")
        }
        let temperatureUnit = rawWeather["temperature_unit"]?.stringValue ?? "celsius"
        guard temperatureUnit == "celsius" || temperatureUnit == "fahrenheit" else {
            throw ConfigError.parse("weather.temperature_unit: must be \"celsius\" or \"fahrenheit\", got \"\(temperatureUnit)\"")
        }
        let forecastDays = rawWeather["forecast_days"]?.intValue ?? 5
        weather = WeatherConfig(
            location: location,
            latitude: latitude,
            longitude: longitude,
            temperatureUnit: temperatureUnit,
            forecastDays: forecastDays
        )
    }

    let pomodoro = try parsePomodoro(doc.pomodoro)
    let network = try parseNetwork(doc.network, doc.networkTargets)

    return Config(
        refreshIntervalSecs: refreshIntervalSecs,
        commandTimeoutSecs: commandTimeoutSecs,
        fetchRemote: fetchRemote,
        repos: repos,
        clocks: clocks,
        weather: weather,
        pomodoro: pomodoro,
        network: network
    )
}

private func parsePomodoro(_ raw: [String: TOMLValue]?) throws -> PomodoroConfig {
    let raw = raw ?? [:]
    let defaults = PomodoroConfig()

    func minutes(_ field: String, _ fallback: Int) throws -> Int {
        guard let n = raw[field]?.intValue else { return fallback }
        guard n > 0 else {
            throw ConfigError.parse(
                "pomodoro.\(field): must be a positive number of minutes, got \(n)")
        }
        return n
    }

    func hhmm(_ field: String, _ fallback: Int) throws -> Int {
        guard let s = raw[field]?.stringValue else { return fallback }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
            (0..<24).contains(h), (0..<60).contains(m)
        {
            return h * 60 + m
        }
        throw ConfigError.parse("pomodoro.\(field): must be a \"HH:MM\" 24-hour time, got \"\(s)\"")
    }

    return PomodoroConfig(
        enabled: raw["enabled"]?.boolValue ?? defaults.enabled,
        focusMinutes: try minutes("focus_minutes", defaults.focusMinutes),
        breakMinutes: try minutes("break_minutes", defaults.breakMinutes),
        notify: raw["notify"]?.boolValue ?? defaults.notify,
        sound: raw["sound"]?.boolValue ?? defaults.sound,
        morningNudge: raw["morning_nudge"]?.boolValue ?? defaults.morningNudge,
        morningNudgeAfterMinutes: try hhmm("morning_nudge_after", defaults.morningNudgeAfterMinutes)
    )
}

private func parseNetwork(_ raw: [String: TOMLValue]?, _ rawTargets: [[String: TOMLValue]]) throws -> NetworkConfig {
    let raw = raw ?? [:]
    let defaults = NetworkConfig()

    func int(_ field: String, _ fallback: Int, _ range: ClosedRange<Int>) throws -> Int {
        guard let value = raw[field] else { return fallback }
        guard let n = value.intValue, range.contains(n) else {
            throw ConfigError.parse("network.\(field): must be an integer in \(range.lowerBound)...\(range.upperBound)")
        }
        return n
    }

    func url(_ field: String, _ fallback: String) throws -> String {
        guard let value = raw[field] else { return fallback }
        guard let s = value.stringValue, s.hasPrefix("http://") || s.hasPrefix("https://") else {
            throw ConfigError.parse("network.\(field): must be an http(s) URL")
        }
        return s
    }

    var targets = defaults.targets
    if !rawTargets.isEmpty {
        targets = try rawTargets.enumerated().map { index, t in try parseNetworkTarget(t, index: index) }
    }

    return NetworkConfig(
        enabled: raw["enabled"]?.boolValue ?? defaults.enabled,
        probeIntervalSecs: try int("probe_interval_secs", defaults.probeIntervalSecs, 0...86_400),
        probeSamples: try int("probe_samples", defaults.probeSamples, 1...50),
        probeTimeoutMs: try int("probe_timeout_ms", defaults.probeTimeoutMs, 100...10_000),
        speedtestMaxSecs: try int("speedtest_max_secs", defaults.speedtestMaxSecs, 1...600),
        speedtestMaxMB: try int("speedtest_max_mb", defaults.speedtestMaxMB, 1...10_000),
        speedtestDomesticDownloadURL: try url("speedtest_domestic_download_url", defaults.speedtestDomesticDownloadURL),
        speedtestDomesticUploadURL: try url("speedtest_domestic_upload_url", defaults.speedtestDomesticUploadURL),
        speedtestOverseasDownloadURL: try url("speedtest_overseas_download_url", defaults.speedtestOverseasDownloadURL),
        speedtestOverseasUploadURL: try url("speedtest_overseas_upload_url", defaults.speedtestOverseasUploadURL),
        targets: targets
    )
}

private func parseNetworkTarget(_ raw: [String: TOMLValue], index: Int) throws -> NetworkTarget {
    let at = "network_targets[\(index)]"
    guard let label = raw["label"]?.stringValue, !label.isEmpty else {
        throw ConfigError.parse("\(at).label: required")
    }
    let groupRaw = raw["group"]?.stringValue ?? ""
    let group: ProbeGroup
    switch groupRaw {
    case "domestic": group = .domestic
    case "overseas": group = .overseas
    case "home": group = .home
    default:
        throw ConfigError.parse("\(at).group: must be \"domestic\", \"overseas\" or \"home\", got \"\(groupRaw)\"")
    }
    let methodRaw = raw["method"]?.stringValue ?? "http"
    switch methodRaw {
    case "http":
        guard let url = raw["url"]?.stringValue, url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw ConfigError.parse("\(at).url: method \"http\" requires an http(s) `url`")
        }
        return NetworkTarget(label: label, group: group, method: .http, url: url)
    case "tcp":
        guard let host = raw["host"]?.stringValue, !host.isEmpty else {
            throw ConfigError.parse("\(at).host: method \"tcp\" requires `host`")
        }
        guard let port = raw["port"]?.intValue, (1...65_535).contains(port) else {
            throw ConfigError.parse("\(at).port: method \"tcp\" requires `port` in 1...65535")
        }
        return NetworkTarget(label: label, group: group, method: .tcp, host: host, port: port)
    default:
        throw ConfigError.parse("\(at).method: must be \"http\" or \"tcp\", got \"\(methodRaw)\"")
    }
}

private func loadDocumentText(_ path: String) throws -> String {
    guard let text = try readFileIfExists(path) else { return "" }
    return text
}

private func saveDocumentText(_ path: String, _ text: String) throws {
    let dir = (path as NSString).deletingLastPathComponent
    if !dir.isEmpty {
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw ConfigError.io(error.localizedDescription)
        }
    }
    do {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        throw ConfigError.io(error.localizedDescription)
    }
}

/// Append a `[[repos]]` entry to the config file at `configPath`, preserving
/// any other sections/comments already present. Creates the file if missing.
public func addRepo(configPath: String, rawPath: String, name: String?) throws {
    let text = try loadDocumentText(configPath)
    let updated = TOMLRepoEditor.add(text: text, rawPath: rawPath, name: name)
    try saveDocumentText(configPath, updated)
}

/// Remove the `[[repos]]` entry whose (expanded) path matches `target`.
public func removeRepo(configPath: String, target: String) throws {
    let text = try loadDocumentText(configPath)
    let updated = TOMLRepoEditor.remove(text: text, target: target, expand: expandPath)
    try saveDocumentText(configPath, updated)
}

/// Update the `[[repos]]` entry whose (expanded) path matches `target` with a
/// new path/name.
public func updateRepo(configPath: String, target: String, newRawPath: String, newName: String?) throws {
    let text = try loadDocumentText(configPath)
    let updated = TOMLRepoEditor.update(text: text, target: target, newRawPath: newRawPath, newName: newName, expand: expandPath)
    try saveDocumentText(configPath, updated)
}
