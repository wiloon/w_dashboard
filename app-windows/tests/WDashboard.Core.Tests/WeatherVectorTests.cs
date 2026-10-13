using System.Text.Json;

namespace WDashboard.Core.Tests;

public class WeatherVectorTests
{
    public static TheoryData<string> ForecastFiles => Vectors.Files("weather-json");

    public static TheoryData<int, string> WmoMapping
    {
        get
        {
            var mapping = Vectors.Load<Dictionary<string, string>>("wmo-codes", "mapping.json");
            Assert.NotEmpty(mapping);
            var data = new TheoryData<int, string>();
            foreach (var (code, text) in mapping) data.Add(int.Parse(code), text);
            return data;
        }
    }

    [Theory]
    [MemberData(nameof(WmoMapping))]
    public void WmoCode(int code, string expected)
    {
        Assert.Equal(expected, Weather.WmoDescription(code));
    }

    [Theory]
    [MemberData(nameof(ForecastFiles))]
    public void ForecastJson(string file)
    {
        using var doc = Vectors.LoadDocument("weather-json", file);
        var root = doc.RootElement;
        var label = root.GetProperty("location_label").GetString()!;
        var unit = root.GetProperty("temperature_unit").GetString()!;
        var fetchedAt = root.GetProperty("fetched_at").GetInt64();
        var input = root.GetProperty("input");
        var expected = root.GetProperty("expected");

        if (expected.ValueKind == JsonValueKind.Null)
        {
            Assert.Throws<WeatherParseException>(() => Weather.ParseForecast(input, label, unit, fetchedAt));
            return;
        }

        var report = Weather.ParseForecast(input, label, unit, fetchedAt);
        Assert.Equal(expected.GetProperty("location_label").GetString(), report.LocationLabel);
        Assert.Equal(expected.GetProperty("latitude").GetDouble(), report.Latitude);
        Assert.Equal(expected.GetProperty("longitude").GetDouble(), report.Longitude);
        Assert.Equal(expected.GetProperty("fetched_at").GetInt64(), report.FetchedAt);
        Assert.Equal(expected.GetProperty("temperature_unit").GetString(), report.TemperatureUnit);

        var current = expected.GetProperty("current");
        Assert.Equal(current.GetProperty("temperature").GetDouble(), report.Current.Temperature);
        Assert.Equal(current.GetProperty("weather_code").GetInt32(), report.Current.WeatherCode);
        Assert.Equal(current.GetProperty("description").GetString(), report.Current.Description);

        var days = expected.TryGetProperty("daily", out var d) && d.ValueKind == JsonValueKind.Array
            ? d.EnumerateArray().ToList()
            : [];
        Assert.Equal(days.Count, report.Daily.Count);
        foreach (var (day, exp) in report.Daily.Zip(days))
        {
            Assert.Equal(exp.GetProperty("date").GetString(), day.Date);
            Assert.Equal(exp.GetProperty("temp_max").GetDouble(), day.TempMax);
            Assert.Equal(exp.GetProperty("temp_min").GetDouble(), day.TempMin);
            Assert.Equal(exp.GetProperty("weather_code").GetInt32(), day.WeatherCode);
            Assert.Equal(exp.GetProperty("description").GetString(), day.Description);
            int? precip = exp.TryGetProperty("precipitation_probability_max", out var p) && p.ValueKind == JsonValueKind.Number
                ? p.GetInt32()
                : null;
            Assert.Equal(precip, day.PrecipitationProbabilityMax);
        }
    }
}
