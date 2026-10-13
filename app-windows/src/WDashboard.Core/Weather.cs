// Open-Meteo forecast parsing and WMO code mapping (docs/sdd.md §7.4). Pure
// functions, locked by docs/test-vectors/weather-json/ and wmo-codes/.

using System.Globalization;
using System.Text.Json;

namespace WDashboard.Core;

/// <summary>A <c>Config</c> or <c>Network</c> weather failure (§6), folded into <c>weather_error</c>.</summary>
public class WeatherException(string message) : Exception(message);

public sealed class WeatherParseException(string message) : WeatherException(message);

public static class Weather
{
    public static string WmoDescription(int code) => code switch
    {
        0 => "Clear sky",
        1 => "Mainly clear",
        2 => "Partly cloudy",
        3 => "Overcast",
        45 => "Fog",
        48 => "Depositing rime fog",
        51 => "Light drizzle",
        53 => "Moderate drizzle",
        55 => "Dense drizzle",
        56 => "Light freezing drizzle",
        57 => "Dense freezing drizzle",
        61 => "Slight rain",
        63 => "Moderate rain",
        65 => "Heavy rain",
        66 => "Light freezing rain",
        67 => "Heavy freezing rain",
        71 => "Slight snow fall",
        73 => "Moderate snow fall",
        75 => "Heavy snow fall",
        77 => "Snow grains",
        80 => "Slight rain showers",
        81 => "Moderate rain showers",
        82 => "Violent rain showers",
        85 => "Slight snow showers",
        86 => "Heavy snow showers",
        95 => "Thunderstorm",
        96 => "Thunderstorm with slight hail",
        99 => "Thunderstorm with heavy hail",
        _ => "Unknown",
    };

    /// <summary>
    /// Parse an Open-Meteo <c>forecast</c> response. <paramref name="locationLabel"/>,
    /// <paramref name="temperatureUnit"/> and <paramref name="fetchedAt"/> come from the
    /// caller; everything else is read from the JSON. A day missing a required field is
    /// dropped rather than failing the whole report.
    /// </summary>
    /// <exception cref="WeatherParseException">Top-level fields or <c>current</c> are missing.</exception>
    public static WeatherReport ParseForecast(JsonElement root, string locationLabel, string temperatureUnit, long fetchedAt)
    {
        if (root.ValueKind != JsonValueKind.Object)
            throw new WeatherParseException("expected a JSON object at the top level");

        var latitude = AsDouble(Prop(root, "latitude")) ?? throw new WeatherParseException("missing `latitude`");
        var longitude = AsDouble(Prop(root, "longitude")) ?? throw new WeatherParseException("missing `longitude`");

        var current = Prop(root, "current");
        if (current is not { ValueKind: JsonValueKind.Object } currentObj)
            throw new WeatherParseException("missing `current`");
        var temperature = AsDouble(Prop(currentObj, "temperature_2m"))
            ?? throw new WeatherParseException("missing `current.temperature_2m`");
        var weatherCode = AsInt(Prop(currentObj, "weather_code"))
            ?? throw new WeatherParseException("missing `current.weather_code`");

        var daily = new List<WeatherDay>();
        if (Prop(root, "daily") is { ValueKind: JsonValueKind.Object } dailyObj)
        {
            var dates = Array(Prop(dailyObj, "time"));
            var codes = Array(Prop(dailyObj, "weather_code"));
            var maxes = Array(Prop(dailyObj, "temperature_2m_max"));
            var mins = Array(Prop(dailyObj, "temperature_2m_min"));
            var precip = Array(Prop(dailyObj, "precipitation_probability_max"));

            for (var i = 0; i < dates.Count; i++)
            {
                if (dates[i].ValueKind != JsonValueKind.String) continue;
                var code = AsInt(At(codes, i));
                var tempMax = AsDouble(At(maxes, i));
                var tempMin = AsDouble(At(mins, i));
                if (code is null || tempMax is null || tempMin is null) continue;

                daily.Add(new WeatherDay(
                    dates[i].GetString()!,
                    tempMax.Value,
                    tempMin.Value,
                    code.Value,
                    WmoDescription(code.Value),
                    AsInt(At(precip, i))));
            }
        }

        return new WeatherReport(
            locationLabel,
            latitude,
            longitude,
            fetchedAt,
            new WeatherNow(temperature, weatherCode, WmoDescription(weatherCode)),
            daily,
            temperatureUnit);
    }

    /// <summary>
    /// Collect one report (§7.4): geocode the location name when no coordinates are
    /// configured, then fetch the forecast.
    /// </summary>
    /// <exception cref="WeatherException">Network, parse or config failure.</exception>
    public static async Task<WeatherReport> FetchAsync(
        HttpClient http, WeatherConfig config, TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        double latitude, longitude;
        string label;
        if (config.Latitude is { } lat && config.Longitude is { } lon)
        {
            (latitude, longitude, label) = (lat, lon, config.Location ?? "");
        }
        else if (!string.IsNullOrEmpty(config.Location))
        {
            (latitude, longitude) = await GeocodeAsync(http, config.Location, timeout, cancellationToken);
            label = config.Location;
        }
        else
        {
            throw new WeatherException("weather: no location or lat/long set");
        }

        var inv = CultureInfo.InvariantCulture;
        var url = "https://api.open-meteo.com/v1/forecast"
            + $"?latitude={latitude.ToString("R", inv)}&longitude={longitude.ToString("R", inv)}"
            + "&current=temperature_2m,weather_code"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            + $"&forecast_days={config.ForecastDays.ToString(inv)}"
            + $"&temperature_unit={Uri.EscapeDataString(config.TemperatureUnit)}"
            + "&timezone=auto";

        using var doc = await GetJsonAsync(http, url, timeout, cancellationToken);
        return ParseForecast(doc.RootElement, label, config.TemperatureUnit, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
    }

    private static async Task<(double, double)> GeocodeAsync(
        HttpClient http, string location, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var url = $"https://geocoding-api.open-meteo.com/v1/search?name={Uri.EscapeDataString(location)}&count=1";
        using var doc = await GetJsonAsync(http, url, timeout, cancellationToken);
        if (Prop(doc.RootElement, "results") is not { ValueKind: JsonValueKind.Array } results
            || results.GetArrayLength() == 0)
        {
            throw new WeatherParseException($"no geocoding results for \"{location}\"");
        }
        var first = results[0];
        var lat = AsDouble(Prop(first, "latitude")) ?? throw new WeatherParseException("geocoding result missing latitude");
        var lon = AsDouble(Prop(first, "longitude")) ?? throw new WeatherParseException("geocoding result missing longitude");
        return (lat, lon);
    }

    private static async Task<JsonDocument> GetJsonAsync(
        HttpClient http, string url, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(timeout);
        try
        {
            using var response = await http.GetAsync(url, cts.Token);
            response.EnsureSuccessStatusCode();
            await using var body = await response.Content.ReadAsStreamAsync(cts.Token);
            return await JsonDocument.ParseAsync(body, cancellationToken: cts.Token);
        }
        catch (JsonException e)
        {
            throw new WeatherParseException(e.Message);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new WeatherException("network error: request timed out");
        }
        catch (HttpRequestException e)
        {
            throw new WeatherException($"network error: {e.Message}");
        }
    }

    private static JsonElement? Prop(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var value) ? value : null;

    private static IReadOnlyList<JsonElement> Array(JsonElement? element) =>
        element is { ValueKind: JsonValueKind.Array } arr ? arr.EnumerateArray().ToList() : [];

    private static JsonElement? At(IReadOnlyList<JsonElement> items, int index) =>
        index < items.Count ? items[index] : null;

    private static double? AsDouble(JsonElement? element) =>
        element is { ValueKind: JsonValueKind.Number } n ? n.GetDouble() : null;

    private static int? AsInt(JsonElement? element)
    {
        if (element is not { ValueKind: JsonValueKind.Number } n) return null;
        return n.TryGetInt32(out var i) ? i : (int)n.GetDouble();
    }
}
