use std::cell::Cell;
use std::rc::Rc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use slint::{Color, ComponentHandle, Model, SharedString, Timer, TimerMode, VecModel, Weak};
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
    let actions = git::allowed_actions(s.state);
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
        can_pull: actions.pull,
        can_push: actions.push,
        can_fetch: actions.fetch,
        action_busy: false,
        action_note: SharedString::default(),
        action_ok: false,
        row_refreshing: false,
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

/// One repo's collected status, tagged with the refresh generation it belongs
/// to and its row index, so the UI can drop results from a superseded refresh
/// and repaint just that row instead of waiting for the whole batch
/// (docs/sdd.md §8, incremental update).
struct RepoUpdate {
    token: u64,
    index: usize,
    status: RepoStatus,
}

/// A targeted single-row re-collection (docs/sdd.md §8.1 "定向单行采集"): a fresh
/// status for one repo, routed back to its row by `path` (config order may have
/// changed). `result` is `Some` for a Pull/Push/Fetch action (§7.5), `None` for
/// the plain per-row refresh button (§8).
struct RepoActionUpdate {
    path: String,
    result: Option<git::GitActionResult>,
    status: RepoStatus,
}

/// Find the row index whose `path` matches, if any.
fn row_index_by_path(model: &VecModel<RepoRow>, path: &str) -> Option<usize> {
    (0..model.row_count()).find(|&i| {
        model
            .row_data(i)
            .map(|r| r.path.as_str() == path)
            .unwrap_or(false)
    })
}

/// How many repos are collected in parallel. Each worker blocks on git
/// subprocesses, so this caps the thread count no matter how many repos are
/// configured.
const REPO_WORKERS: usize = 4;

fn pending_color() -> Color {
    Color::from_rgb_u8(0xb0, 0xb6, 0xbd)
}

fn now_hms() -> String {
    chrono::Local::now().format("%H:%M:%S").to_string()
}

/// UI-thread state behind the repo list: the row model plus the current
/// refresh generation and how many rows are still outstanding. Only touched
/// from the Slint event loop (callbacks + timers), hence `Cell`.
struct RepoUi {
    model: Rc<VecModel<RepoRow>>,
    token: Cell<u64>,
    pending: Cell<usize>,
}

impl RepoUi {
    fn new() -> Rc<Self> {
        Rc::new(RepoUi {
            model: Rc::new(VecModel::from(Vec::<RepoRow>::new())),
            token: Cell::new(0),
            pending: Cell::new(0),
        })
    }

    /// Start a new refresh generation: re-seed the rows in config order and
    /// return the token that results must carry to be accepted.
    fn begin(&self, ui: &AppWindow, repos: &[config::RepoConfig]) -> u64 {
        let token = self.token.get().wrapping_add(1);
        self.token.set(token);
        self.pending.set(repos.len());
        let rows: Vec<RepoRow> = repos.iter().map(|r| self.seeded_row(r)).collect();
        self.model.set_vec(rows);
        ui.set_refreshing(!repos.is_empty());
        if repos.is_empty() {
            ui.set_last_updated(now_hms().into());
        }
        token
    }

    /// Placeholder row for a repo whose collection is still running: carry
    /// over whatever we already showed for the same path, but replace the
    /// state badge with a neutral "Checking..." so stale values are not read
    /// as fresh ones.
    fn seeded_row(&self, repo: &config::RepoConfig) -> RepoRow {
        let path = repo.path.display().to_string();
        let name = repo.name.clone().unwrap_or_else(|| {
            repo.path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| path.clone())
        });
        let mut row = self
            .model
            .iter()
            .find(|r| r.path.as_str() == path)
            .unwrap_or_else(|| repo_row_from_status(&RepoStatus::new(name.clone(), path.clone())));
        row.name = name.into();
        row.path = path.into();
        row.state_label = "Checking...".into();
        row.state_color = pending_color();
        // A full refresh clears any lingering per-row action result (SDD §7.5).
        row.action_busy = false;
        row.action_note = SharedString::default();
        row.action_ok = false;
        row.row_refreshing = false;
        row
    }

    /// Apply one repo's result. Ignores results from a superseded refresh, and
    /// clears `refreshing` once the last row has landed.
    fn apply(&self, ui: &AppWindow, update: RepoUpdate) {
        if update.token != self.token.get() || update.index >= self.model.row_count() {
            return;
        }
        self.model
            .set_row_data(update.index, repo_row_from_status(&update.status));
        let remaining = self.pending.get().saturating_sub(1);
        self.pending.set(remaining);
        ui.set_last_updated(now_hms().into());
        if remaining == 0 {
            ui.set_refreshing(false);
        }
    }
}

/// Collect every repo on a small worker pool, sending each status as soon as
/// it is ready so the UI can update that row on its own.
fn spawn_collect_repos(
    repos: Vec<config::RepoConfig>,
    fetch_remote: bool,
    timeout: Duration,
    token: u64,
    tx: mpsc::Sender<RepoUpdate>,
) {
    let repos = Arc::new(repos);
    let next = Arc::new(AtomicUsize::new(0));
    for _ in 0..REPO_WORKERS.min(repos.len()) {
        let repos = repos.clone();
        let next = next.clone();
        let tx = tx.clone();
        std::thread::spawn(move || loop {
            let index = next.fetch_add(1, Ordering::Relaxed);
            let Some(repo) = repos.get(index) else {
                break;
            };
            let status = git::collect_repo(repo, fetch_remote, timeout);
            if tx.send(RepoUpdate { token, index, status }).is_err() {
                break;
            }
        });
    }
}

/// Re-seed the repo rows and kick off a fresh collection from the current
/// config. Rows then update one at a time as `RepoUpdate`s arrive.
fn start_repo_refresh(
    shared_cfg: &Arc<Mutex<config::Config>>,
    repo_ui: &Rc<RepoUi>,
    tx: &mpsc::Sender<RepoUpdate>,
    ui_weak: &Weak<AppWindow>,
) {
    let Some(ui) = ui_weak.upgrade() else {
        return;
    };
    let guard = shared_cfg.lock().unwrap();
    // Hide the per-row Fetch button when refreshes already fetch (SDD §7.5).
    ui.set_auto_fetch(guard.fetch_remote);
    let token = repo_ui.begin(&ui, &guard.repos);
    spawn_collect_repos(
        guard.repos.clone(),
        guard.fetch_remote,
        Duration::from_secs(guard.command_timeout_secs),
        token,
        tx.clone(),
    );
}

/// Reload config from disk, swap it into the shared state, push the repo
/// management list to the UI, and kick off a fresh git collection. Used
/// after any add/remove/update through the "Manage" panel.
fn reload_and_refresh(
    shared_cfg: &Arc<Mutex<config::Config>>,
    cfg_path: &std::path::Path,
    repo_ui: &Rc<RepoUi>,
    tx: &mpsc::Sender<RepoUpdate>,
    ui_weak: &Weak<AppWindow>,
) {
    let new_cfg = config::load_config(Some(cfg_path)).unwrap_or_else(|e| {
        eprintln!("config reload error: {e}; keeping previous config");
        shared_cfg.lock().unwrap().clone()
    });

    {
        let mut guard = shared_cfg.lock().unwrap();
        *guard = new_cfg.clone();
    }

    if let Some(ui) = ui_weak.upgrade() {
        ui.set_repo_entries(Rc::new(VecModel::from(repo_entries_from_config(&new_cfg))).into());
    }
    start_repo_refresh(shared_cfg, repo_ui, tx, ui_weak);
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
    let (tx, rx) = mpsc::channel::<RepoUpdate>();
    let (action_tx, action_rx) = mpsc::channel::<RepoActionUpdate>();
    // One long-lived model, so a finished repo can repaint its own row
    // instead of the whole list being replaced at the end of a refresh.
    let repo_ui = RepoUi::new();
    ui.set_repos(repo_ui.model.clone().into());
    {
        let guard = shared_cfg.lock().unwrap();
        ui.set_repo_entries(Rc::new(VecModel::from(repo_entries_from_config(&guard))).into());
        let token = repo_ui.begin(&ui, &guard.repos);
        spawn_collect_repos(
            guard.repos.clone(),
            guard.fetch_remote,
            Duration::from_secs(guard.command_timeout_secs),
            token,
            tx.clone(),
        );
    }

    let ui_weak = ui.as_weak();
    let poll_repo_ui = repo_ui.clone();
    let poll_timer = Timer::default();
    poll_timer.start(TimerMode::Repeated, Duration::from_millis(200), move || {
        while let Ok(update) = rx.try_recv() {
            if let Some(ui) = ui_weak.upgrade() {
                poll_repo_ui.apply(&ui, update);
            }
        }
        // Per-repo action results: repaint just the acted-on row with its fresh
        // status, then overlay the one-line action message (SDD §7.5).
        while let Ok(update) = action_rx.try_recv() {
            let Some(ui) = ui_weak.upgrade() else { continue };
            let Some(idx) = row_index_by_path(&poll_repo_ui.model, &update.path) else {
                continue;
            };
            let mut row = repo_row_from_status(&update.status);
            row.action_busy = false;
            row.row_refreshing = false;
            match &update.result {
                // Pull/Push/Fetch (§7.5): overlay the one-line action message.
                Some(result) if result.ok => {
                    row.action_ok = true;
                    row.action_note = result.summary.clone().into();
                }
                Some(result) => {
                    row.action_ok = false;
                    row.action_note = result
                        .error
                        .clone()
                        .unwrap_or_else(|| "action failed".to_string())
                        .into();
                }
                // Plain per-row refresh (§8): no message; `repo_row_from_status`
                // already left `action_note` empty, clearing any prior result.
                None => {}
            }
            poll_repo_ui.model.set_row_data(idx, row);
            ui.set_last_updated(now_hms().into());
        }
    });

    {
        let shared_cfg = shared_cfg.clone();
        let cfg_path = cfg_path.clone();
        let repo_ui = repo_ui.clone();
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
                    reload_and_refresh(&shared_cfg, &cfg_path, &repo_ui, &tx, &ui_weak);
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
        let repo_ui = repo_ui.clone();
        let tx = tx.clone();
        let ui_weak = ui.as_weak();
        ui.on_remove_repo(move |raw_path| {
            let target = config::expand_path(raw_path.as_str());
            match config::remove_repo(&cfg_path, &target) {
                Ok(()) => reload_and_refresh(&shared_cfg, &cfg_path, &repo_ui, &tx, &ui_weak),
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
        let repo_ui = repo_ui.clone();
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
                    reload_and_refresh(&shared_cfg, &cfg_path, &repo_ui, &tx, &ui_weak);
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

    {
        // One of the three explicit safe sync actions (SDD §7.5): mark the row
        // busy, run the git command on a background thread, re-collect that
        // repo, and route the result back by path.
        let shared_cfg = shared_cfg.clone();
        let repo_ui = repo_ui.clone();
        let action_tx = action_tx.clone();
        ui.on_repo_action(move |raw_path, raw_action| {
            let Some(action) = git::RepoAction::parse(raw_action.as_str()) else {
                return;
            };
            let path = raw_path.to_string();

            let Some(idx) = row_index_by_path(&repo_ui.model, &path) else {
                return;
            };
            let Some(mut row) = repo_ui.model.row_data(idx) else {
                return;
            };
            if row.action_busy {
                return;
            }
            row.action_busy = true;
            row.action_note = SharedString::default();
            repo_ui.model.set_row_data(idx, row);

            let (repo_cfg, timeout) = {
                let guard = shared_cfg.lock().unwrap();
                let repo_cfg = guard
                    .repos
                    .iter()
                    .find(|r| r.path.display().to_string() == path)
                    .cloned();
                (repo_cfg, Duration::from_secs(guard.command_timeout_secs))
            };
            let Some(repo_cfg) = repo_cfg else {
                return;
            };

            let action_tx = action_tx.clone();
            std::thread::spawn(move || {
                let result = git::run_repo_action(&repo_cfg, action, timeout);
                // fetch_remote=false: pull/push/fetch already refreshed refs.
                let status = git::collect_repo(&repo_cfg, false, timeout);
                let _ = action_tx.send(RepoActionUpdate {
                    path: repo_cfg.path.display().to_string(),
                    result: Some(result),
                    status,
                });
            });
        });
    }

    {
        // Per-row manual refresh (SDD §8, §8.1 "定向单行采集"): re-collect just
        // this repo with the same params a full refresh would use (honouring
        // `fetch_remote`), no git write, no new generation token.
        let shared_cfg = shared_cfg.clone();
        let repo_ui = repo_ui.clone();
        let action_tx = action_tx.clone();
        ui.on_repo_refresh(move |raw_path| {
            let path = raw_path.to_string();

            let Some(idx) = row_index_by_path(&repo_ui.model, &path) else {
                return;
            };
            let Some(mut row) = repo_ui.model.row_data(idx) else {
                return;
            };
            if row.action_busy || row.row_refreshing {
                return;
            }
            row.row_refreshing = true;
            row.action_note = SharedString::default();
            repo_ui.model.set_row_data(idx, row);

            let (repo_cfg, fetch_remote, timeout) = {
                let guard = shared_cfg.lock().unwrap();
                let repo_cfg = guard
                    .repos
                    .iter()
                    .find(|r| r.path.display().to_string() == path)
                    .cloned();
                (
                    repo_cfg,
                    guard.fetch_remote,
                    Duration::from_secs(guard.command_timeout_secs),
                )
            };
            let Some(repo_cfg) = repo_cfg else {
                return;
            };

            let action_tx = action_tx.clone();
            std::thread::spawn(move || {
                let status = git::collect_repo(&repo_cfg, fetch_remote, timeout);
                let _ = action_tx.send(RepoActionUpdate {
                    path: repo_cfg.path.display().to_string(),
                    result: None,
                    status,
                });
            });
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
        let repo_ui = repo_ui.clone();
        let tx = tx.clone();
        let weather_tx = weather_tx.clone();
        let ui_weak = ui.as_weak();
        ui.on_refresh(move || {
            start_repo_refresh(&shared_cfg, &repo_ui, &tx, &ui_weak);
            if weather_configured {
                let guard = shared_cfg.lock().unwrap();
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
        let repo_ui = repo_ui.clone();
        let tx = tx.clone();
        let weather_tx = weather_tx.clone();
        let ui_weak = ui.as_weak();
        auto_timer.start(
            TimerMode::Repeated,
            Duration::from_secs(refresh_interval_secs),
            move || {
                start_repo_refresh(&shared_cfg, &repo_ui, &tx, &ui_weak);
                if weather_configured {
                    let guard = shared_cfg.lock().unwrap();
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
