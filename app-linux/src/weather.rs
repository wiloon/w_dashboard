//! Weather collection per docs/sdd.md §7.4: geocoding + Open-Meteo forecast,
//! WMO weather_code → text mapping, parsed into `WeatherReport` (§5.4).
//! JSON parsing and the WMO mapping are pure functions, covered by
//! docs/test-vectors/weather-json/ and docs/test-vectors/wmo-codes/.

use std::fmt;
use std::time::Duration;

use serde_json::Value;

use crate::config::WeatherConfig;
use crate::model::{WeatherDay, WeatherNow, WeatherReport};

#[derive(Debug)]
pub enum WeatherError {
    Config(String),
    Network(String),
    Parse(String),
}

impl fmt::Display for WeatherError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WeatherError::Config(msg) => write!(f, "weather config error: {msg}"),
            WeatherError::Network(msg) => write!(f, "weather network error: {msg}"),
            WeatherError::Parse(msg) => write!(f, "weather parse error: {msg}"),
        }
    }
}

impl std::error::Error for WeatherError {}

/// WMO weather_code → text mapping, per docs/sdd.md §10.2 (wmo-codes) /
/// docs/test-vectors/wmo-codes/mapping.json. Pure function.
pub fn wmo_description(code: i64) -> &'static str {
    match code {
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
    }
}

/// Parse an Open-Meteo `forecast` JSON response into a `WeatherReport`. Pure
/// function — covered by docs/test-vectors/weather-json/. `location_label`,
/// `temperature_unit` and `fetched_at` come from the caller (config/clock),
/// everything else is read from the JSON itself.
pub fn parse_forecast_json(
    json: &Value,
    location_label: &str,
    temperature_unit: &str,
    fetched_at: i64,
) -> Result<WeatherReport, WeatherError> {
    let latitude = json
        .get("latitude")
        .and_then(Value::as_f64)
        .ok_or_else(|| WeatherError::Parse("missing `latitude`".to_string()))?;
    let longitude = json
        .get("longitude")
        .and_then(Value::as_f64)
        .ok_or_else(|| WeatherError::Parse("missing `longitude`".to_string()))?;

    let current_obj = json
        .get("current")
        .ok_or_else(|| WeatherError::Parse("missing `current`".to_string()))?;
    let temperature = current_obj
        .get("temperature_2m")
        .and_then(Value::as_f64)
        .ok_or_else(|| WeatherError::Parse("missing `current.temperature_2m`".to_string()))?;
    let weather_code = current_obj
        .get("weather_code")
        .and_then(Value::as_i64)
        .ok_or_else(|| WeatherError::Parse("missing `current.weather_code`".to_string()))?;
    let current = WeatherNow {
        temperature,
        weather_code,
        description: wmo_description(weather_code).to_string(),
    };

    let mut daily = Vec::new();
    if let Some(daily_obj) = json.get("daily") {
        let dates = daily_obj
            .get("time")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let codes = daily_obj.get("weather_code").and_then(Value::as_array);
        let temp_maxes = daily_obj.get("temperature_2m_max").and_then(Value::as_array);
        let temp_mins = daily_obj.get("temperature_2m_min").and_then(Value::as_array);
        let precip = daily_obj
            .get("precipitation_probability_max")
            .and_then(Value::as_array);

        for (i, date_val) in dates.iter().enumerate() {
            let date = match date_val.as_str() {
                Some(d) => d.to_string(),
                None => continue,
            };
            let code = codes.and_then(|a| a.get(i)).and_then(Value::as_i64);
            let temp_max = temp_maxes.and_then(|a| a.get(i)).and_then(Value::as_f64);
            let temp_min = temp_mins.and_then(|a| a.get(i)).and_then(Value::as_f64);
            let (code, temp_max, temp_min) = match (code, temp_max, temp_min) {
                (Some(c), Some(mx), Some(mn)) => (c, mx, mn),
                // A day missing any required field is dropped rather than
                // failing the whole report, per SDD §7.4 degradation intent.
                _ => continue,
            };
            let precipitation_probability_max =
                precip.and_then(|a| a.get(i)).and_then(Value::as_i64);
            daily.push(WeatherDay {
                date,
                temp_max,
                temp_min,
                weather_code: code,
                description: wmo_description(code).to_string(),
                precipitation_probability_max,
            });
        }
    }

    Ok(WeatherReport {
        location_label: location_label.to_string(),
        latitude,
        longitude,
        fetched_at,
        current,
        daily,
        temperature_unit: temperature_unit.to_string(),
    })
}

fn now_unix() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn http_get_json(url: &str, timeout: Duration) -> Result<Value, WeatherError> {
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(timeout))
        .build();
    let agent: ureq::Agent = config.into();
    let body = agent
        .get(url)
        .call()
        .map_err(|e| WeatherError::Network(e.to_string()))?
        .body_mut()
        .read_to_string()
        .map_err(|e| WeatherError::Network(e.to_string()))?;
    serde_json::from_str(&body).map_err(|e| WeatherError::Parse(e.to_string()))
}

/// Resolve a location name to (latitude, longitude) via Open-Meteo geocoding.
fn geocode(location: &str, timeout: Duration) -> Result<(f64, f64), WeatherError> {
    let url = format!(
        "https://geocoding-api.open-meteo.com/v1/search?name={}&count=1",
        urlencoding_encode(location)
    );
    let json = http_get_json(&url, timeout)?;
    let first = json
        .get("results")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .ok_or_else(|| WeatherError::Parse(format!("no geocoding results for {location:?}")))?;
    let lat = first
        .get("latitude")
        .and_then(Value::as_f64)
        .ok_or_else(|| WeatherError::Parse("geocoding result missing latitude".to_string()))?;
    let lon = first
        .get("longitude")
        .and_then(Value::as_f64)
        .ok_or_else(|| WeatherError::Parse("geocoding result missing longitude".to_string()))?;
    Ok((lat, lon))
}

/// Minimal percent-encoding sufficient for a location name query param.
fn urlencoding_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Collect one weather report per docs/sdd.md §7.4. Never panics; all
/// failures surface as `WeatherError` for the caller to fold into
/// `weather_error`.
pub fn fetch_weather(cfg: &WeatherConfig, timeout: Duration) -> Result<WeatherReport, WeatherError> {
    let (latitude, longitude, label) = match (cfg.latitude, cfg.longitude) {
        (Some(lat), Some(lon)) => (lat, lon, cfg.location.clone().unwrap_or_default()),
        _ => {
            let location = cfg
                .location
                .as_deref()
                .ok_or_else(|| WeatherError::Config("weather: no location or lat/long set".to_string()))?;
            let (lat, lon) = geocode(location, timeout)?;
            (lat, lon, location.to_string())
        }
    };

    let url = format!(
        "https://api.open-meteo.com/v1/forecast?latitude={latitude}&longitude={longitude}\
         &current=temperature_2m,weather_code\
         &daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max\
         &forecast_days={days}&temperature_unit={unit}&timezone=auto",
        days = cfg.forecast_days,
        unit = cfg.temperature_unit,
    );
    let json = http_get_json(&url, timeout)?;
    parse_forecast_json(&json, &label, &cfg.temperature_unit, now_unix())
}
