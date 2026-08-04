// Weather collection per docs/sdd.md §7.4: geocoding + Open-Meteo forecast,
// WMO weather_code -> text mapping, parsed into `WeatherReport` (§5.4).
// Mirrors app-linux/src/weather.rs. JSON parsing and the WMO mapping are
// pure functions, covered by docs/test-vectors/weather-json/ and
// docs/test-vectors/wmo-codes/.

import Foundation

public enum WeatherError: Error, CustomStringConvertible, Sendable {
    case config(String)
    case network(String)
    case parse(String)

    public var description: String {
        switch self {
        case .config(let msg): return "weather config error: \(msg)"
        case .network(let msg): return "weather network error: \(msg)"
        case .parse(let msg): return "weather parse error: \(msg)"
        }
    }
}

/// WMO weather_code -> text mapping, per docs/sdd.md §10.2 (wmo-codes) /
/// docs/test-vectors/wmo-codes/mapping.json. Pure function.
public func wmoDescription(_ code: Int) -> String {
    switch code {
    case 0: return "Clear sky"
    case 1: return "Mainly clear"
    case 2: return "Partly cloudy"
    case 3: return "Overcast"
    case 45: return "Fog"
    case 48: return "Depositing rime fog"
    case 51: return "Light drizzle"
    case 53: return "Moderate drizzle"
    case 55: return "Dense drizzle"
    case 56: return "Light freezing drizzle"
    case 57: return "Dense freezing drizzle"
    case 61: return "Slight rain"
    case 63: return "Moderate rain"
    case 65: return "Heavy rain"
    case 66: return "Light freezing rain"
    case 67: return "Heavy freezing rain"
    case 71: return "Slight snow fall"
    case 73: return "Moderate snow fall"
    case 75: return "Heavy snow fall"
    case 77: return "Snow grains"
    case 80: return "Slight rain showers"
    case 81: return "Moderate rain showers"
    case 82: return "Violent rain showers"
    case 85: return "Slight snow showers"
    case 86: return "Heavy snow showers"
    case 95: return "Thunderstorm"
    case 96: return "Thunderstorm with slight hail"
    case 99: return "Thunderstorm with heavy hail"
    default: return "Unknown"
    }
}

/// WMO weather_code -> SF Symbol name, for use with
/// `.symbolRenderingMode(.multicolor)` (gives each symbol its natural
/// weather coloring — yellow sun, blue rain, etc. — with no extra styling).
/// Pure function.
public func wmoSymbolName(_ code: Int) -> String {
    switch code {
    case 0, 1: return "sun.max.fill"
    case 2: return "cloud.sun.fill"
    case 3: return "cloud.fill"
    case 45, 48: return "cloud.fog.fill"
    case 51, 53, 55: return "cloud.drizzle.fill"
    case 56, 57, 66, 67: return "cloud.sleet.fill"
    case 61, 63, 65: return "cloud.rain.fill"
    case 71, 73, 75, 77: return "cloud.snow.fill"
    case 80, 81, 82: return "cloud.sun.rain.fill"
    case 85, 86: return "cloud.snow.fill"
    case 95: return "cloud.bolt.fill"
    case 96, 99: return "cloud.bolt.rain.fill"
    default: return "cloud.fill"
    }
}

private func asDouble(_ v: Any?) -> Double? {
    (v as? NSNumber)?.doubleValue
}

private func asInt(_ v: Any?) -> Int? {
    (v as? NSNumber)?.intValue
}

/// Parse an Open-Meteo `forecast` JSON response (as decoded by
/// `JSONSerialization`) into a `WeatherReport`. Pure function — covered by
/// docs/test-vectors/weather-json/. `locationLabel`, `temperatureUnit` and
/// `fetchedAt` come from the caller (config/clock), everything else is read
/// from the JSON itself.
public func parseForecastJSON(_ json: Any, locationLabel: String, temperatureUnit: String, fetchedAt: Int64) throws -> WeatherReport {
    guard let root = json as? [String: Any] else {
        throw WeatherError.parse("expected a JSON object at the top level")
    }
    guard let latitude = asDouble(root["latitude"]) else {
        throw WeatherError.parse("missing `latitude`")
    }
    guard let longitude = asDouble(root["longitude"]) else {
        throw WeatherError.parse("missing `longitude`")
    }
    guard let currentObj = root["current"] as? [String: Any] else {
        throw WeatherError.parse("missing `current`")
    }
    guard let temperature = asDouble(currentObj["temperature_2m"]) else {
        throw WeatherError.parse("missing `current.temperature_2m`")
    }
    guard let weatherCode = asInt(currentObj["weather_code"]) else {
        throw WeatherError.parse("missing `current.weather_code`")
    }
    let current = WeatherNow(temperature: temperature, weatherCode: weatherCode, description: wmoDescription(weatherCode))

    var daily: [WeatherDay] = []
    if let dailyObj = root["daily"] as? [String: Any] {
        let dates = (dailyObj["time"] as? [Any]) ?? []
        let codes = dailyObj["weather_code"] as? [Any]
        let tempMaxes = dailyObj["temperature_2m_max"] as? [Any]
        let tempMins = dailyObj["temperature_2m_min"] as? [Any]
        let precip = dailyObj["precipitation_probability_max"] as? [Any]

        for (i, dateVal) in dates.enumerated() {
            guard let date = dateVal as? String else { continue }
            let code = codes.flatMap { arr in arr.indices.contains(i) ? asInt(arr[i]) : nil }
            let tempMax = tempMaxes.flatMap { arr in arr.indices.contains(i) ? asDouble(arr[i]) : nil }
            let tempMin = tempMins.flatMap { arr in arr.indices.contains(i) ? asDouble(arr[i]) : nil }
            // A day missing any required field is dropped rather than
            // failing the whole report, per SDD §7.4 degradation intent.
            guard let code, let tempMax, let tempMin else { continue }
            let precipitationProbabilityMax = precip.flatMap { arr in arr.indices.contains(i) ? asInt(arr[i]) : nil }
            daily.append(WeatherDay(
                date: date,
                tempMax: tempMax,
                tempMin: tempMin,
                weatherCode: code,
                description: wmoDescription(code),
                precipitationProbabilityMax: precipitationProbabilityMax
            ))
        }
    }

    return WeatherReport(
        locationLabel: locationLabel,
        latitude: latitude,
        longitude: longitude,
        fetchedAt: fetchedAt,
        current: current,
        daily: daily,
        temperatureUnit: temperatureUnit
    )
}

private func httpGetJSON(url: URL, timeout: TimeInterval) throws -> Any {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    let session = URLSession(configuration: config)

    let semaphore = DispatchSemaphore(value: 0)
    var resultData: Data?
    var resultError: Error?
    let task = session.dataTask(with: url) { data, _, error in
        resultData = data
        resultError = error
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()

    if let resultError {
        throw WeatherError.network(resultError.localizedDescription)
    }
    guard let data = resultData else {
        throw WeatherError.network("empty response")
    }
    do {
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        throw WeatherError.parse(error.localizedDescription)
    }
}

/// Resolve a location name to (latitude, longitude) via Open-Meteo geocoding.
private func geocode(location: String, timeout: TimeInterval) throws -> (Double, Double) {
    var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
    components.queryItems = [
        URLQueryItem(name: "name", value: location),
        URLQueryItem(name: "count", value: "1"),
    ]
    guard let url = components.url else {
        throw WeatherError.config("invalid location for geocoding: \(location)")
    }
    let json = try httpGetJSON(url: url, timeout: timeout)
    guard let root = json as? [String: Any],
        let results = root["results"] as? [Any],
        let first = results.first as? [String: Any]
    else {
        throw WeatherError.parse("no geocoding results for \"\(location)\"")
    }
    guard let lat = asDouble(first["latitude"]) else {
        throw WeatherError.parse("geocoding result missing latitude")
    }
    guard let lon = asDouble(first["longitude"]) else {
        throw WeatherError.parse("geocoding result missing longitude")
    }
    return (lat, lon)
}

/// Collect one weather report per docs/sdd.md §7.4. Never crashes; all
/// failures surface as `WeatherError` for the caller to fold into
/// `weather_error`.
public func fetchWeather(config: WeatherConfig, timeout: TimeInterval) throws -> WeatherReport {
    let latitude: Double
    let longitude: Double
    let label: String
    if let lat = config.latitude, let lon = config.longitude {
        latitude = lat
        longitude = lon
        label = config.location ?? ""
    } else {
        guard let location = config.location, !location.isEmpty else {
            throw WeatherError.config("weather: no location or lat/long set")
        }
        (latitude, longitude) = try geocode(location: location, timeout: timeout)
        label = location
    }

    var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    components.queryItems = [
        URLQueryItem(name: "latitude", value: String(latitude)),
        URLQueryItem(name: "longitude", value: String(longitude)),
        URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
        URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
        URLQueryItem(name: "forecast_days", value: String(config.forecastDays)),
        URLQueryItem(name: "temperature_unit", value: config.temperatureUnit),
        URLQueryItem(name: "timezone", value: "auto"),
    ]
    guard let url = components.url else {
        throw WeatherError.config("failed to build forecast URL")
    }
    let json = try httpGetJSON(url: url, timeout: timeout)
    return try parseForecastJSON(json, locationLabel: label, temperatureUnit: config.temperatureUnit, fetchedAt: Int64(Date().timeIntervalSince1970))
}
