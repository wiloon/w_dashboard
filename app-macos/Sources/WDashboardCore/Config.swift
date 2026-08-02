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

public struct Config: Equatable, Sendable {
    public var refreshIntervalSecs: Int
    public var commandTimeoutSecs: Int
    public var fetchRemote: Bool
    public var repos: [RepoConfig]
    public var clocks: [ClockConfig]
    public var weather: WeatherConfig?

    public init(
        refreshIntervalSecs: Int,
        commandTimeoutSecs: Int,
        fetchRemote: Bool,
        repos: [RepoConfig],
        clocks: [ClockConfig],
        weather: WeatherConfig?
    ) {
        self.refreshIntervalSecs = refreshIntervalSecs
        self.commandTimeoutSecs = commandTimeoutSecs
        self.fetchRemote = fetchRemote
        self.repos = repos
        self.clocks = clocks
        self.weather = weather
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

    return Config(
        refreshIntervalSecs: refreshIntervalSecs,
        commandTimeoutSecs: commandTimeoutSecs,
        fetchRemote: fetchRemote,
        repos: repos,
        clocks: clocks,
        weather: weather
    )
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
