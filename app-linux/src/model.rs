//! Data model per docs/sdd.md §5. Only the subset needed for git status (§5.2) is
//! implemented so far; chezmoi/weather/clocks are not part of this milestone.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepoState {
    Clean,
    Dirty,
    NeedsPush,
    NeedsPull,
    Diverged,
    NoUpstream,
    Error,
}

#[derive(Debug, Clone)]
pub struct RepoStatus {
    pub name: String,
    pub path: String,
    pub branch: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    pub staged: u32,
    pub modified: u32,
    pub untracked: u32,
    pub conflicted: u32,
    pub state: RepoState,
    pub last_fetch_at: Option<i64>,
    pub error: Option<String>,
}

impl RepoStatus {
    pub fn new(name: String, path: String) -> Self {
        RepoStatus {
            name,
            path,
            branch: None,
            upstream: None,
            ahead: 0,
            behind: 0,
            staged: 0,
            modified: 0,
            untracked: 0,
            conflicted: 0,
            state: RepoState::Error,
            last_fetch_at: None,
            error: None,
        }
    }
}

/// §5.4 WeatherReport / WeatherNow / WeatherDay.
#[derive(Debug, Clone)]
pub struct WeatherReport {
    pub location_label: String,
    pub latitude: f64,
    pub longitude: f64,
    pub fetched_at: i64,
    pub current: WeatherNow,
    pub daily: Vec<WeatherDay>,
    pub temperature_unit: String,
}

#[derive(Debug, Clone)]
pub struct WeatherNow {
    pub temperature: f64,
    pub weather_code: i64,
    pub description: String,
}

#[derive(Debug, Clone)]
pub struct WeatherDay {
    pub date: String,
    pub temp_max: f64,
    pub temp_min: f64,
    pub weather_code: i64,
    pub description: String,
    pub precipitation_probability_max: Option<i64>,
}
