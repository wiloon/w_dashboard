use std::rc::Rc;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use slint::{Color, ComponentHandle, SharedString, Timer, TimerMode, VecModel, Weak};
use w_dashboard_linux::model::{RepoState, RepoStatus, WeatherReport};
use w_dashboard_linux::{config, git, weather};

slint::include_modules!();

fn state_label_color(state: RepoState) -> (&'static str, Color) {
    match state {
        RepoState::Clean => ("Clean", Color::from_rgb_u8(0x4c, 0xaf, 0x50)),
        RepoState::Dirty => ("Dirty", Color::from_rgb_u8(0xff, 0xc1, 0x07)),
        RepoState::NeedsPush => ("Needs Push", Color::from_rgb_u8(0xff, 0xc1, 0x07)),
        RepoState::NeedsPull => ("Needs Pull", Color::from_rgb_u8(0xff, 0xc1, 0x07)),
        RepoState::Diverged => ("Diverged", Color::from_rgb_u8(0xf4, 0x43, 0x36)),
        RepoState::Error => ("Error", Color::from_rgb_u8(0xf4, 0x43, 0x36)),
        RepoState::NoUpstream => ("No Upstream", Color::from_rgb_u8(0xb0, 0xb6, 0xbd)),
    }
}

fn repo_row_from_status(s: &RepoStatus) -> RepoRow {
    let (label, color) = state_label_color(s.state);
    RepoRow {
        name: s.name.clone().into(),
        path: s.path.clone().into(),
        branch: s
            .branch
            .clone()
            .unwrap_or_else(|| "detached".to_string())
            .into(),
        state_label: label.into(),
        state_color: color,
        ahead: s.ahead as i32,
        behind: s.behind as i32,
        staged: s.staged as i32,
        modified: s.modified as i32,
        untracked: s.untracked as i32,
        conflicted: s.conflicted as i32,
        error: s.error.clone().unwrap_or_default().into(),
    }
}

fn repo_entries_from_config(cfg: &config::Config) -> Vec<RepoEntry> {
    cfg.repos
        .iter()
        .map(|r| RepoEntry {
            path: r.path.display().to_string().into(),
            name: r.name.clone().unwrap_or_default().into(),
        })
        .collect()
}

fn spawn_collect_repos(repos: Vec<config::RepoConfig>, fetch_remote: bool, timeout: Duration, tx: mpsc::Sender<Vec<RepoStatus>>) {
    std::thread::spawn(move || {
        let statuses: Vec<RepoStatus> = repos
            .iter()
            .map(|r| git::collect_repo(r, fetch_remote, timeout))
            .collect();
        let _ = tx.send(statuses);
    });
}

/// Reload config from disk, swap it into the shared state, push the repo
/// management list to the UI, and kick off a fresh git collection. Used
/// after any add/remove/update through the "Manage" panel.
fn reload_and_refresh(
    shared_cfg: &Arc<Mutex<config::Config>>,
    cfg_path: &std::path::Path,
    tx: &mpsc::Sender<Vec<RepoStatus>>,
    ui_weak: &Weak<AppWindow>,
) {
    let new_cfg = config::load_config(Some(cfg_path)).unwrap_or_else(|e| {
        eprintln!("config reload error: {e}; keeping previous config");
        shared_cfg.lock().unwrap().clone()
    });

    let (repos, fetch_remote, timeout) = {
        let mut guard = shared_cfg.lock().unwrap();
        *guard = new_cfg.clone();
        (
            guard.repos.clone(),
            guard.fetch_remote,
            Duration::from_secs(guard.command_timeout_secs),
        )
    };

    if let Some(ui) = ui_weak.upgrade() {
        ui.set_repo_entries(Rc::new(VecModel::from(repo_entries_from_config(&new_cfg))).into());
        ui.set_refreshing(true);
    }
    spawn_collect_repos(repos, fetch_remote, timeout, tx.clone());
}

fn clock_rows(clocks: &[config::ClockConfig]) -> Vec<ClockRow> {
    use std::str::FromStr;
    clocks
        .iter()
        .map(|c| {
            let tz = chrono_tz::Tz::from_str(&c.tz).unwrap_or(chrono_tz::UTC);
            let now = chrono::Utc::now().with_timezone(&tz);
            ClockRow {
                label: c.label.clone().into(),
                time: now.format("%H:%M:%S").to_string().into(),
                date: now.format("%Y-%m-%d (%a)").to_string().into(),
            }
        })
        .collect()
}

fn temperature_string(value: f64, unit: &str) -> String {
    let symbol = if unit == "fahrenheit" { "°F" } else { "°C" };
    format!("{value:.1}{symbol}")
}

fn apply_weather_report(ui: &AppWindow, report: &WeatherReport) {
    ui.set_weather_location(report.location_label.clone().into());
    ui.set_weather_current_temp(temperature_string(report.current.temperature, &report.temperature_unit).into());
    ui.set_weather_current_desc(report.current.description.clone().into());
    ui.set_weather_current_icon_index(weather::wmo_icon_index(report.current.weather_code));
    ui.set_weather_error(SharedString::default());
    let days: Vec<WeatherDayRow> = report
        .daily
        .iter()
        .map(|d| WeatherDayRow {
            date: d.date.clone().into(),
            temp_max: temperature_string(d.temp_max, &report.temperature_unit).into(),
            temp_min: temperature_string(d.temp_min, &report.temperature_unit).into(),
            description: d.description.clone().into(),
            precip: d
                .precipitation_probability_max
                .map(|p| format!("precip {p}%"))
                .unwrap_or_default()
                .into(),
            icon_index: weather::wmo_icon_index(d.weather_code),
        })
        .collect();
    ui.set_weather_daily(Rc::new(VecModel::from(days)).into());
}

fn spawn_collect_weather(
    weather_cfg: Option<config::WeatherConfig>,
    timeout: Duration,
    tx: mpsc::Sender<Result<WeatherReport, String>>,
) {
    let Some(weather_cfg) = weather_cfg else {
        return;
    };
    std::thread::spawn(move || {
        let result = weather::fetch_weather(&weather_cfg, timeout).map_err(|e| e.to_string());
        let _ = tx.send(result);
    });
}

fn main() -> anyhow::Result<()> {
    let cfg_path = config::default_config_path();
    let cfg = config::load_config(Some(&cfg_path)).unwrap_or_else(|e| {
        eprintln!("config error: {e}; falling back to defaults");
        config::Config::default()
    });
    let weather_configured = cfg.weather.is_some();
    let shared_cfg = Arc::new(Mutex::new(cfg));

    let ui = AppWindow::new()?;

    // ---------------- Repos ----------------
    let (tx, rx) = mpsc::channel::<Vec<RepoStatus>>();
    {
        let guard = shared_cfg.lock().unwrap();
        ui.set_repo_entries(Rc::new(VecModel::from(repo_entries_from_config(&guard))).into());
        ui.set_refreshing(true);
        spawn_collect_repos(
            guard.repos.clone(),
            guard.fetch_remote,
            Duration::from_secs(guard.command_timeout_secs),
            tx.clone(),
        );
    }

    let ui_weak = ui.as_weak();
    let poll_timer = Timer::default();
    poll_timer.start(TimerMode::Repeated, Duration::from_millis(200), move || {
        if let Ok(statuses) = rx.try_recv() {
            if let Some(ui) = ui_weak.upgrade() {
                let rows: Vec<RepoRow> = statuses.iter().map(repo_row_from_status).collect();
                ui.set_repos(Rc::new(VecModel::from(rows)).into());
                ui.set_refreshing(false);
                ui.set_last_updated(chrono::Local::now().format("%H:%M:%S").to_string().into());
            }
        }
    });

    {
        let shared_cfg = shared_cfg.clone();
        let cfg_path = cfg_path.clone();
        let tx = tx.clone();
        let ui_weak = ui.as_weak();
        ui.on_add_repo(move |raw_path, raw_name| {
            let raw_path = raw_path.trim().to_string();
            let raw_name = raw_name.trim().to_string();
            if raw_path.is_empty() {
                if let Some(ui) = ui_weak.upgrade() {
                    ui.set_repo_form_error("Path cannot be empty".into());
                }
                return;
            }
            let name_opt = if raw_name.is_empty() { None } else { Some(raw_name.as_str()) };
            match config::add_repo(&cfg_path, &raw_path, name_opt) {
                Ok(()) => {
                    reload_and_refresh(&shared_cfg, &cfg_path, &tx, &ui_weak);
                    if let Some(ui) = ui_weak.upgrade() {
                        ui.set_add_repo_path(SharedString::default());
                        ui.set_add_repo_name(SharedString::default());
                        ui.set_repo_form_error(SharedString::default());
                    }
                }
                Err(e) => {
                    if let Some(ui) = ui_weak.upgrade() {
                        ui.set_repo_form_error(e.to_string().into());
                    }
                }
            }
        });
    }

    {
        let shared_cfg = shared_cfg.clone();
        let cfg_path = cfg_path.clone();
        let tx = tx.clone();
        let ui_weak = ui.as_weak();
        ui.on_remove_repo(move |raw_path| {
            let target = config::expand_path(raw_path.as_str());
            match config::remove_repo(&cfg_path, &target) {
                Ok(()) => reload_and_refresh(&shared_cfg, &cfg_path, &tx, &ui_weak),
                Err(e) => {
                    if let Some(ui) = ui_weak.upgrade() {
                        ui.set_repo_form_error(e.to_string().into());
                    }
                }
            }
        });
    }

    {
        let shared_cfg = shared_cfg.clone();
        let cfg_path = cfg_path.clone();
        let tx = tx.clone();
        let ui_weak = ui.as_weak();
        ui.on_update_repo(move |old_raw_path, new_raw_path, new_raw_name| {
            let old_target = config::expand_path(old_raw_path.as_str());
            let new_raw_path = new_raw_path.trim().to_string();
            let new_raw_name = new_raw_name.trim().to_string();
            if new_raw_path.is_empty() {
                if let Some(ui) = ui_weak.upgrade() {
                    ui.set_repo_form_error("Path cannot be empty".into());
                }
                return;
            }
            let name_opt = if new_raw_name.is_empty() { None } else { Some(new_raw_name.as_str()) };
            match config::update_repo(&cfg_path, &old_target, &new_raw_path, name_opt) {
                Ok(()) => {
                    reload_and_refresh(&shared_cfg, &cfg_path, &tx, &ui_weak);
                    if let Some(ui) = ui_weak.upgrade() {
                        ui.set_editing_repo_path(SharedString::default());
                        ui.set_add_repo_path(SharedString::default());
                        ui.set_add_repo_name(SharedString::default());
                        ui.set_repo_form_error(SharedString::default());
                    }
                }
                Err(e) => {
                    if let Some(ui) = ui_weak.upgrade() {
                        ui.set_repo_form_error(e.to_string().into());
                    }
                }
            }
        });
    }

    // ---------------- Weather ----------------
    ui.set_weather_configured(weather_configured);
    let (weather_tx, weather_rx) = mpsc::channel::<Result<WeatherReport, String>>();
    if weather_configured {
        let guard = shared_cfg.lock().unwrap();
        spawn_collect_weather(
            guard.weather.clone(),
            Duration::from_secs(guard.command_timeout_secs),
            weather_tx.clone(),
        );
    }
    let ui_weak = ui.as_weak();
    let weather_poll_timer = Timer::default();
    weather_poll_timer.start(TimerMode::Repeated, Duration::from_millis(300), move || {
        if let Ok(result) = weather_rx.try_recv() {
            if let Some(ui) = ui_weak.upgrade() {
                match result {
                    Ok(report) => apply_weather_report(&ui, &report),
                    Err(e) => ui.set_weather_error(e.into()),
                }
            }
        }
    });

    // A single Refresh action (button or auto-refresh timer) re-collects both
    // repos and weather. Slint callbacks only support one handler, so this
    // must be the only `on_refresh` registration.
    {
        let shared_cfg = shared_cfg.clone();
        let tx = tx.clone();
        let weather_tx = weather_tx.clone();
        let ui_weak = ui.as_weak();
        ui.on_refresh(move || {
            if let Some(ui) = ui_weak.upgrade() {
                ui.set_refreshing(true);
            }
            let guard = shared_cfg.lock().unwrap();
            spawn_collect_repos(
                guard.repos.clone(),
                guard.fetch_remote,
                Duration::from_secs(guard.command_timeout_secs),
                tx.clone(),
            );
            if weather_configured {
                spawn_collect_weather(
                    guard.weather.clone(),
                    Duration::from_secs(guard.command_timeout_secs),
                    weather_tx.clone(),
                );
            }
        });
    }

    // Background auto-refresh per config.refresh_interval_secs (0 = manual only).
    let refresh_interval_secs = shared_cfg.lock().unwrap().refresh_interval_secs;
    let auto_timer = Timer::default();
    if refresh_interval_secs > 0 {
        let shared_cfg = shared_cfg.clone();
        let tx = tx.clone();
        let weather_tx = weather_tx.clone();
        let ui_weak = ui.as_weak();
        auto_timer.start(
            TimerMode::Repeated,
            Duration::from_secs(refresh_interval_secs),
            move || {
                if let Some(ui) = ui_weak.upgrade() {
                    ui.set_refreshing(true);
                }
                let guard = shared_cfg.lock().unwrap();
                spawn_collect_repos(
                    guard.repos.clone(),
                    guard.fetch_remote,
                    Duration::from_secs(guard.command_timeout_secs),
                    tx.clone(),
                );
                if weather_configured {
                    spawn_collect_weather(
                        guard.weather.clone(),
                        Duration::from_secs(guard.command_timeout_secs),
                        weather_tx.clone(),
                    );
                }
            },
        );
    }

    // ---------------- Clocks ----------------
    let clocks_cfg = shared_cfg.lock().unwrap().clocks.clone();
    ui.set_clocks(Rc::new(VecModel::from(clock_rows(&clocks_cfg))).into());
    let ui_weak = ui.as_weak();
    let clock_timer = Timer::default();
    clock_timer.start(TimerMode::Repeated, Duration::from_secs(1), move || {
        if let Some(ui) = ui_weak.upgrade() {
            ui.set_clocks(Rc::new(VecModel::from(clock_rows(&clocks_cfg))).into());
        }
    });

    ui.run()?;
    Ok(())
}
