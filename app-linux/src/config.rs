//! Config loading per docs/sdd.md §4. `[chezmoi]` is accepted but ignored;
//! that panel isn't implemented yet.

use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use serde::Deserialize;
use toml_edit::{value, ArrayOfTables, DocumentMut, Item, Table};

#[derive(Debug)]
pub enum ConfigError {
    Io(String),
    Parse(String),
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::Io(msg) => write!(f, "failed to read config: {msg}"),
            ConfigError::Parse(msg) => write!(f, "failed to parse config: {msg}"),
        }
    }
}

impl std::error::Error for ConfigError {}

#[derive(Debug, Clone)]
pub struct RepoConfig {
    pub path: PathBuf,
    pub name: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ClockConfig {
    pub label: String,
    pub tz: String,
}

#[derive(Debug, Clone)]
pub struct WeatherConfig {
    pub location: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub temperature_unit: String,
    pub forecast_days: u32,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub refresh_interval_secs: u64,
    pub command_timeout_secs: u64,
    pub fetch_remote: bool,
    pub repos: Vec<RepoConfig>,
    pub clocks: Vec<ClockConfig>,
    pub weather: Option<WeatherConfig>,
}

fn default_clocks() -> Vec<ClockConfig> {
    vec![
        ClockConfig {
            label: "Beijing".to_string(),
            tz: "Asia/Shanghai".to_string(),
        },
        ClockConfig {
            label: "New York".to_string(),
            tz: "America/New_York".to_string(),
        },
    ]
}

impl Default for Config {
    fn default() -> Self {
        Config {
            refresh_interval_secs: 900,
            command_timeout_secs: 20,
            fetch_remote: true,
            repos: Vec::new(),
            clocks: default_clocks(),
            weather: None,
        }
    }
}

#[derive(Debug, Default, Deserialize)]
struct GeneralRaw {
    refresh_interval_secs: Option<u64>,
    command_timeout_secs: Option<u64>,
    fetch_remote: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct RepoConfigRaw {
    path: String,
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ClockConfigRaw {
    label: String,
    tz: String,
}

#[derive(Debug, Deserialize)]
struct WeatherConfigRaw {
    location: Option<String>,
    latitude: Option<f64>,
    longitude: Option<f64>,
    temperature_unit: Option<String>,
    forecast_days: Option<u32>,
}

#[derive(Debug, Default, Deserialize)]
struct ConfigRaw {
    general: Option<GeneralRaw>,
    repos: Option<Vec<RepoConfigRaw>>,
    clocks: Option<Vec<ClockConfigRaw>>,
    weather: Option<WeatherConfigRaw>,
}

/// Expand `$VAR` / `${VAR}` references using the current environment.
/// Unknown variables are left untouched (literal `$NAME`).
fn expand_env(input: &str) -> String {
    let mut result = String::new();
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '$' {
            result.push(c);
            continue;
        }
        if chars.peek() == Some(&'{') {
            chars.next();
            let mut name = String::new();
            let mut closed = false;
            for c2 in chars.by_ref() {
                if c2 == '}' {
                    closed = true;
                    break;
                }
                name.push(c2);
            }
            match std::env::var(&name) {
                Ok(val) => result.push_str(&val),
                Err(_) => {
                    result.push_str("${");
                    result.push_str(&name);
                    if closed {
                        result.push('}');
                    }
                }
            }
        } else {
            let mut name = String::new();
            while let Some(&c2) = chars.peek() {
                if c2.is_alphanumeric() || c2 == '_' {
                    name.push(c2);
                    chars.next();
                } else {
                    break;
                }
            }
            if name.is_empty() {
                result.push('$');
            } else {
                match std::env::var(&name) {
                    Ok(val) => result.push_str(&val),
                    Err(_) => {
                        result.push('$');
                        result.push_str(&name);
                    }
                }
            }
        }
    }
    result
}

fn expand_tilde(path: &str) -> PathBuf {
    if let Some(rest) = path.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    } else if path == "~" {
        if let Some(home) = dirs::home_dir() {
            return home;
        }
    }
    PathBuf::from(path)
}

pub fn expand_path(raw: &str) -> PathBuf {
    expand_tilde(&expand_env(raw))
}

/// `$XDG_CONFIG_HOME/w_dashboard/config.toml`, falling back to
/// `~/.config/w_dashboard/config.toml`, per docs/sdd.md §4.
pub fn default_config_path() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        if !xdg.is_empty() {
            return PathBuf::from(xdg).join("w_dashboard/config.toml");
        }
    }
    dirs::home_dir()
        .unwrap_or_default()
        .join(".config/w_dashboard/config.toml")
}

/// Load and validate config. A missing file returns the built-in default
/// (empty repos), per docs/sdd.md §4.
pub fn load_config(path: Option<&Path>) -> Result<Config, ConfigError> {
    let path = path
        .map(|p| p.to_path_buf())
        .unwrap_or_else(default_config_path);

    if !path.exists() {
        return Ok(Config::default());
    }

    let text = std::fs::read_to_string(&path).map_err(|e| ConfigError::Io(e.to_string()))?;
    let raw: ConfigRaw = toml::from_str(&text).map_err(|e| ConfigError::Parse(e.to_string()))?;

    let general = raw.general.unwrap_or_default();
    let repos = raw
        .repos
        .unwrap_or_default()
        .into_iter()
        .map(|r| RepoConfig {
            path: expand_path(&r.path),
            name: r.name,
        })
        .collect();

    let clocks = match raw.clocks {
        Some(raw_clocks) => {
            let mut clocks = Vec::with_capacity(raw_clocks.len());
            for c in raw_clocks {
                if chrono_tz::Tz::from_str(&c.tz).is_err() {
                    return Err(ConfigError::Parse(format!(
                        "clocks: invalid IANA tz id {:?} for label {:?}",
                        c.tz, c.label
                    )));
                }
                clocks.push(ClockConfig {
                    label: c.label,
                    tz: c.tz,
                });
            }
            clocks
        }
        None => default_clocks(),
    };

    let weather = match raw.weather {
        Some(w) => {
            let has_location = w.location.as_deref().is_some_and(|s| !s.is_empty());
            let has_coords = w.latitude.is_some() && w.longitude.is_some();
            if !has_location && !has_coords {
                return Err(ConfigError::Parse(
                    "weather: requires either `location` or both `latitude` and `longitude`"
                        .to_string(),
                ));
            }
            let temperature_unit = w.temperature_unit.unwrap_or_else(|| "celsius".to_string());
            if temperature_unit != "celsius" && temperature_unit != "fahrenheit" {
                return Err(ConfigError::Parse(format!(
                    "weather.temperature_unit: must be \"celsius\" or \"fahrenheit\", got {temperature_unit:?}"
                )));
            }
            Some(WeatherConfig {
                location: w.location,
                latitude: w.latitude,
                longitude: w.longitude,
                temperature_unit,
                forecast_days: w.forecast_days.unwrap_or(5),
            })
        }
        None => None,
    };

    Ok(Config {
        refresh_interval_secs: general.refresh_interval_secs.unwrap_or(900),
        command_timeout_secs: general.command_timeout_secs.unwrap_or(20),
        fetch_remote: general.fetch_remote.unwrap_or(true),
        repos,
        clocks,
        weather,
    })
}

fn load_document(path: &Path) -> Result<DocumentMut, ConfigError> {
    if path.exists() {
        let text = fs::read_to_string(path).map_err(|e| ConfigError::Io(e.to_string()))?;
        text.parse::<DocumentMut>()
            .map_err(|e| ConfigError::Parse(e.to_string()))
    } else {
        Ok(DocumentMut::new())
    }
}

fn save_document(path: &Path, doc: &DocumentMut) -> Result<(), ConfigError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| ConfigError::Io(e.to_string()))?;
    }
    fs::write(path, doc.to_string()).map_err(|e| ConfigError::Io(e.to_string()))
}

fn repos_array(doc: &mut DocumentMut) -> &mut ArrayOfTables {
    if doc.get("repos").and_then(Item::as_array_of_tables).is_none() {
        doc["repos"] = Item::ArrayOfTables(ArrayOfTables::new());
    }
    doc["repos"].as_array_of_tables_mut().expect("just ensured")
}

fn find_repo_index(arr: &ArrayOfTables, target: &Path) -> Option<usize> {
    (0..arr.len()).find(|&i| {
        arr.get(i)
            .and_then(|t| t.get("path"))
            .and_then(|v| v.as_str())
            .map(|p| expand_path(p) == target)
            .unwrap_or(false)
    })
}

/// Append a `[[repos]]` entry to the config file at `config_path`, preserving
/// any other sections/comments already present. Creates the file if missing.
pub fn add_repo(config_path: &Path, raw_path: &str, name: Option<&str>) -> Result<(), ConfigError> {
    let mut doc = load_document(config_path)?;
    let mut table = Table::new();
    table["path"] = value(raw_path);
    if let Some(n) = name {
        if !n.is_empty() {
            table["name"] = value(n);
        }
    }
    repos_array(&mut doc).push(table);
    save_document(config_path, &doc)
}

/// Remove the `[[repos]]` entry whose (expanded) path matches `target`.
pub fn remove_repo(config_path: &Path, target: &Path) -> Result<(), ConfigError> {
    let mut doc = load_document(config_path)?;
    let arr = repos_array(&mut doc);
    if let Some(idx) = find_repo_index(arr, target) {
        arr.remove(idx);
    }
    save_document(config_path, &doc)
}

/// Update the `[[repos]]` entry whose (expanded) path matches `target` with a
/// new path/name.
pub fn update_repo(
    config_path: &Path,
    target: &Path,
    new_raw_path: &str,
    new_name: Option<&str>,
) -> Result<(), ConfigError> {
    let mut doc = load_document(config_path)?;
    let arr = repos_array(&mut doc);
    if let Some(idx) = find_repo_index(arr, target) {
        let table = arr.get_mut(idx).expect("index from find_repo_index");
        table["path"] = value(new_raw_path);
        match new_name {
            Some(n) if !n.is_empty() => {
                table["name"] = value(n);
            }
            _ => {
                table.remove("name");
            }
        }
    }
    save_document(config_path, &doc)
}
