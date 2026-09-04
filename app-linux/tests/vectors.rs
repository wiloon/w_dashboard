//! Contract tests: loads docs/test-vectors/ (the language-agnostic
//! consistency gate, see docs/sdd.md §10) and asserts parse/derive results.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

use w_dashboard_linux::git::{allowed_actions, derive_state, parse_porcelain_v2, DeriveInput};
use w_dashboard_linux::model::RepoState;
use w_dashboard_linux::pomodoro::{
    pomodoro_reduce, pomodoro_view, PomodoroEvent, PomodoroPhase, PomodoroState,
};
use w_dashboard_linux::weather::{parse_forecast_json, wmo_description, wmo_icon_index, WEATHER_ICON_NAMES};

fn vectors_dir(sub: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../docs/test-vectors")
        .join(sub)
}

fn json_files(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("cannot read {dir:?}: {e}"))
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("json"))
        .collect();
    files.sort();
    files
}

#[derive(Deserialize)]
struct PorcelainVector {
    input: String,
    expected: ExpectedParsed,
}

#[derive(Deserialize)]
struct ExpectedParsed {
    branch: Option<String>,
    upstream: Option<String>,
    ahead: u32,
    behind: u32,
    staged: u32,
    modified: u32,
    untracked: u32,
    conflicted: u32,
}

#[test]
fn git_porcelain_vectors() {
    let dir = vectors_dir("git-porcelain");
    let files = json_files(&dir);
    assert!(!files.is_empty(), "no git-porcelain vectors found in {dir:?}");

    for path in files {
        let text = fs::read_to_string(&path).unwrap();
        let vector: PorcelainVector =
            serde_json::from_str(&text).unwrap_or_else(|e| panic!("{path:?}: {e}"));
        let parsed = parse_porcelain_v2(&vector.input);

        assert_eq!(parsed.branch, vector.expected.branch, "branch mismatch in {path:?}");
        assert_eq!(parsed.upstream, vector.expected.upstream, "upstream mismatch in {path:?}");
        assert_eq!(parsed.ahead, vector.expected.ahead, "ahead mismatch in {path:?}");
        assert_eq!(parsed.behind, vector.expected.behind, "behind mismatch in {path:?}");
        assert_eq!(parsed.staged, vector.expected.staged, "staged mismatch in {path:?}");
        assert_eq!(parsed.modified, vector.expected.modified, "modified mismatch in {path:?}");
        assert_eq!(parsed.untracked, vector.expected.untracked, "untracked mismatch in {path:?}");
        assert_eq!(parsed.conflicted, vector.expected.conflicted, "conflicted mismatch in {path:?}");
    }
}

#[derive(Deserialize)]
struct RepoStateVector {
    input: DeriveInputVec,
    expected: String,
}

#[derive(Deserialize)]
struct DeriveInputVec {
    ahead: u32,
    behind: u32,
    staged: u32,
    modified: u32,
    untracked: u32,
    conflicted: u32,
    has_upstream: bool,
    error: Option<String>,
}

fn state_from_str(s: &str, path: &Path) -> RepoState {
    match s {
        "Clean" => RepoState::Clean,
        "Dirty" => RepoState::Dirty,
        "NeedsPush" => RepoState::NeedsPush,
        "NeedsPull" => RepoState::NeedsPull,
        "Diverged" => RepoState::Diverged,
        "NoUpstream" => RepoState::NoUpstream,
        "Error" => RepoState::Error,
        other => panic!("unknown expected state {other:?} in {path:?}"),
    }
}

#[test]
fn repo_state_vectors() {
    let dir = vectors_dir("repo-state");
    let files = json_files(&dir);
    assert!(!files.is_empty(), "no repo-state vectors found in {dir:?}");

    for path in files {
        let text = fs::read_to_string(&path).unwrap();
        let vector: RepoStateVector =
            serde_json::from_str(&text).unwrap_or_else(|e| panic!("{path:?}: {e}"));

        let input = DeriveInput {
            ahead: vector.input.ahead,
            behind: vector.input.behind,
            staged: vector.input.staged,
            modified: vector.input.modified,
            untracked: vector.input.untracked,
            conflicted: vector.input.conflicted,
            has_upstream: vector.input.has_upstream,
            error: vector.input.error,
        };
        let expected = state_from_str(&vector.expected, &path);
        assert_eq!(derive_state(&input), expected, "state mismatch in {path:?}");
    }
}

#[derive(Deserialize)]
struct RepoActionsVector {
    input: String,
    expected: ExpectedActions,
}

#[derive(Deserialize)]
struct ExpectedActions {
    pull: bool,
    push: bool,
    fetch: bool,
}

#[test]
fn repo_actions_vectors() {
    let dir = vectors_dir("repo-actions");
    let files = json_files(&dir);
    assert!(!files.is_empty(), "no repo-actions vectors found in {dir:?}");

    for path in files {
        let text = fs::read_to_string(&path).unwrap();
        let vector: RepoActionsVector =
            serde_json::from_str(&text).unwrap_or_else(|e| panic!("{path:?}: {e}"));
        let state = state_from_str(&vector.input, &path);
        let actions = allowed_actions(state);
        assert_eq!(actions.pull, vector.expected.pull, "pull mismatch in {path:?}");
        assert_eq!(actions.push, vector.expected.push, "push mismatch in {path:?}");
        assert_eq!(actions.fetch, vector.expected.fetch, "fetch mismatch in {path:?}");
    }
}

#[test]
fn wmo_codes_vectors() {
    let dir = vectors_dir("wmo-codes");
    let path = dir.join("mapping.json");
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path:?}: {e}"));
    let mapping: HashMap<String, String> =
        serde_json::from_str(&text).unwrap_or_else(|e| panic!("{path:?}: {e}"));
    assert!(!mapping.is_empty(), "no wmo-codes entries in {path:?}");

    for (code_str, expected_desc) in &mapping {
        let code: i64 = code_str.parse().unwrap_or_else(|e| panic!("{path:?}: bad code {code_str:?}: {e}"));
        assert_eq!(wmo_description(code), expected_desc, "wmo code {code} mismatch");

        let icon_index = wmo_icon_index(code);
        assert!(
            (icon_index as usize) < WEATHER_ICON_NAMES.len(),
            "wmo code {code} maps to out-of-range icon index {icon_index}"
        );
    }
}

#[derive(Deserialize)]
struct WeatherVector {
    location_label: String,
    temperature_unit: String,
    fetched_at: i64,
    input: Value,
    expected: Option<ExpectedWeatherReport>,
}

#[derive(Deserialize, Debug, PartialEq)]
struct ExpectedWeatherReport {
    location_label: String,
    latitude: f64,
    longitude: f64,
    fetched_at: i64,
    temperature_unit: String,
    current: ExpectedWeatherNow,
    daily: Vec<ExpectedWeatherDay>,
}

#[derive(Deserialize, Debug, PartialEq)]
struct ExpectedWeatherNow {
    temperature: f64,
    weather_code: i64,
    description: String,
}

#[derive(Deserialize, Debug, PartialEq)]
struct ExpectedWeatherDay {
    date: String,
    temp_max: f64,
    temp_min: f64,
    weather_code: i64,
    description: String,
    precipitation_probability_max: Option<i64>,
}

#[test]
fn weather_json_vectors() {
    let dir = vectors_dir("weather-json");
    let files = json_files(&dir);
    assert!(!files.is_empty(), "no weather-json vectors found in {dir:?}");

    for path in files {
        let text = fs::read_to_string(&path).unwrap();
        let vector: WeatherVector =
            serde_json::from_str(&text).unwrap_or_else(|e| panic!("{path:?}: {e}"));

        let result = parse_forecast_json(
            &vector.input,
            &vector.location_label,
            &vector.temperature_unit,
            vector.fetched_at,
        );

        match vector.expected {
            None => {
                assert!(result.is_err(), "expected parse error in {path:?}, got {result:?}");
            }
            Some(expected) => {
                let report = result.unwrap_or_else(|e| panic!("{path:?}: unexpected error {e}"));
                assert_eq!(report.location_label, expected.location_label, "location_label mismatch in {path:?}");
                assert_eq!(report.latitude, expected.latitude, "latitude mismatch in {path:?}");
                assert_eq!(report.longitude, expected.longitude, "longitude mismatch in {path:?}");
                assert_eq!(report.fetched_at, expected.fetched_at, "fetched_at mismatch in {path:?}");
                assert_eq!(report.temperature_unit, expected.temperature_unit, "temperature_unit mismatch in {path:?}");
                assert_eq!(report.current.temperature, expected.current.temperature, "current.temperature mismatch in {path:?}");
                assert_eq!(report.current.weather_code, expected.current.weather_code, "current.weather_code mismatch in {path:?}");
                assert_eq!(report.current.description, expected.current.description, "current.description mismatch in {path:?}");
                assert_eq!(report.daily.len(), expected.daily.len(), "daily length mismatch in {path:?}");
                for (day, expected_day) in report.daily.iter().zip(expected.daily.iter()) {
                    assert_eq!(day.date, expected_day.date, "day.date mismatch in {path:?}");
                    assert_eq!(day.temp_max, expected_day.temp_max, "day.temp_max mismatch in {path:?}");
                    assert_eq!(day.temp_min, expected_day.temp_min, "day.temp_min mismatch in {path:?}");
                    assert_eq!(day.weather_code, expected_day.weather_code, "day.weather_code mismatch in {path:?}");
                    assert_eq!(day.description, expected_day.description, "day.description mismatch in {path:?}");
                    assert_eq!(
                        day.precipitation_probability_max, expected_day.precipitation_probability_max,
                        "day.precipitation_probability_max mismatch in {path:?}"
                    );
                }
            }
        }
    }
}

// ---- Pomodoro (docs/sdd.md §11, ADR-012) ----

fn pomo_phase_from_str(s: &str, path: &Path) -> PomodoroPhase {
    match s {
        "Idle" => PomodoroPhase::Idle,
        "Focus" => PomodoroPhase::Focus,
        "Break" => PomodoroPhase::Break,
        "FocusEnded" => PomodoroPhase::FocusEnded,
        "BreakEnded" => PomodoroPhase::BreakEnded,
        other => panic!("unknown pomodoro phase {other:?} in {path:?}"),
    }
}

fn pomo_event_from_str(s: &str, path: &Path) -> PomodoroEvent {
    match s {
        "StartFocus" => PomodoroEvent::StartFocus,
        "StartBreak" => PomodoroEvent::StartBreak,
        "Stop" => PomodoroEvent::Stop,
        "Tick" => PomodoroEvent::Tick,
        other => panic!("unknown pomodoro event {other:?} in {path:?}"),
    }
}

#[derive(Deserialize)]
struct PomodoroStateVec {
    phase: String,
    phase_started_at: Option<i64>,
    focus_secs: i64,
    break_secs: i64,
}

impl PomodoroStateVec {
    fn to_state(&self, path: &Path) -> PomodoroState {
        PomodoroState {
            phase: pomo_phase_from_str(&self.phase, path),
            phase_started_at: self.phase_started_at,
            focus_secs: self.focus_secs,
            break_secs: self.break_secs,
        }
    }
}

#[derive(Deserialize)]
struct PomodoroTransitionVector {
    input: PomodoroTransitionInput,
    expected: PomodoroStateVec,
}

#[derive(Deserialize)]
struct PomodoroTransitionInput {
    state: PomodoroStateVec,
    event: String,
    now: i64,
}

#[test]
fn pomodoro_transition_vectors() {
    let dir = vectors_dir("pomodoro-transition");
    let files = json_files(&dir);
    assert!(!files.is_empty(), "no pomodoro-transition vectors found in {dir:?}");

    for path in files {
        let text = fs::read_to_string(&path).unwrap();
        let vector: PomodoroTransitionVector =
            serde_json::from_str(&text).unwrap_or_else(|e| panic!("{path:?}: {e}"));
        let state = vector.input.state.to_state(&path);
        let event = pomo_event_from_str(&vector.input.event, &path);
        let got = pomodoro_reduce(state, event, vector.input.now);
        let want = vector.expected.to_state(&path);
        assert_eq!(got, want, "pomodoro transition mismatch in {path:?}");
    }
}

#[derive(Deserialize)]
struct PomodoroViewVector {
    input: PomodoroViewInput,
    expected: PomodoroViewExpected,
}

#[derive(Deserialize)]
struct PomodoroViewInput {
    phase: String,
    phase_started_at: Option<i64>,
    focus_secs: i64,
    break_secs: i64,
    now: i64,
}

#[derive(Deserialize)]
struct PomodoroViewExpected {
    phase: String,
    remaining_secs: i64,
    elapsed_secs: i64,
    overtime_secs: i64,
    progress: f64,
    alerting: bool,
}

#[test]
fn pomodoro_view_vectors() {
    let dir = vectors_dir("pomodoro");
    let files = json_files(&dir);
    assert!(!files.is_empty(), "no pomodoro vectors found in {dir:?}");

    for path in files {
        let text = fs::read_to_string(&path).unwrap();
        let vector: PomodoroViewVector =
            serde_json::from_str(&text).unwrap_or_else(|e| panic!("{path:?}: {e}"));
        let state = PomodoroState {
            phase: pomo_phase_from_str(&vector.input.phase, &path),
            phase_started_at: vector.input.phase_started_at,
            focus_secs: vector.input.focus_secs,
            break_secs: vector.input.break_secs,
        };
        let got = pomodoro_view(&state, vector.input.now);
        let exp = &vector.expected;

        assert_eq!(got.phase, pomo_phase_from_str(&exp.phase, &path), "phase mismatch in {path:?}");
        assert_eq!(got.remaining_secs, exp.remaining_secs, "remaining_secs mismatch in {path:?}");
        assert_eq!(got.elapsed_secs, exp.elapsed_secs, "elapsed_secs mismatch in {path:?}");
        assert_eq!(got.overtime_secs, exp.overtime_secs, "overtime_secs mismatch in {path:?}");
        assert_eq!(got.progress, exp.progress, "progress mismatch in {path:?}");
        assert_eq!(got.alerting, exp.alerting, "alerting mismatch in {path:?}");
    }
}
