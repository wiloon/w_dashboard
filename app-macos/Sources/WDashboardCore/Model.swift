// Data model per docs/sdd.md §5. Mirrors app-linux/src/model.rs field-for-field;
// only the subset needed for git status + weather is implemented so far
// (chezmoi is not implemented on either end yet).

public enum RepoState: Equatable, Sendable {
    case clean
    case dirty
    case needsPush
    case needsPull
    case diverged
    case noUpstream
    case error
}

public struct RepoStatus: Equatable, Sendable {
    public var name: String
    public var path: String
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var staged: Int
    public var modified: Int
    public var untracked: Int
    public var conflicted: Int
    public var state: RepoState
    public var lastFetchAt: Int64?
    public var error: String?

    public init(name: String, path: String) {
        self.name = name
        self.path = path
        self.branch = nil
        self.upstream = nil
        self.ahead = 0
        self.behind = 0
        self.staged = 0
        self.modified = 0
        self.untracked = 0
        self.conflicted = 0
        self.state = .error
        self.lastFetchAt = nil
        self.error = nil
    }
}

// §5.4 WeatherReport / WeatherNow / WeatherDay.
public struct WeatherReport: Equatable, Sendable {
    public var locationLabel: String
    public var latitude: Double
    public var longitude: Double
    public var fetchedAt: Int64
    public var current: WeatherNow
    public var daily: [WeatherDay]
    public var temperatureUnit: String

    public init(
        locationLabel: String,
        latitude: Double,
        longitude: Double,
        fetchedAt: Int64,
        current: WeatherNow,
        daily: [WeatherDay],
        temperatureUnit: String
    ) {
        self.locationLabel = locationLabel
        self.latitude = latitude
        self.longitude = longitude
        self.fetchedAt = fetchedAt
        self.current = current
        self.daily = daily
        self.temperatureUnit = temperatureUnit
    }
}

public struct WeatherNow: Equatable, Sendable {
    public var temperature: Double
    public var weatherCode: Int
    public var description: String

    public init(temperature: Double, weatherCode: Int, description: String) {
        self.temperature = temperature
        self.weatherCode = weatherCode
        self.description = description
    }
}

public struct WeatherDay: Equatable, Sendable {
    public var date: String
    public var tempMax: Double
    public var tempMin: Double
    public var weatherCode: Int
    public var description: String
    public var precipitationProbabilityMax: Int?

    public init(
        date: String,
        tempMax: Double,
        tempMin: Double,
        weatherCode: Int,
        description: String,
        precipitationProbabilityMax: Int?
    ) {
        self.date = date
        self.tempMax = tempMax
        self.tempMin = tempMin
        self.weatherCode = weatherCode
        self.description = description
        self.precipitationProbabilityMax = precipitationProbabilityMax
    }
}
