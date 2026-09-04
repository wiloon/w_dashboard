//! `[pomodoro]` config section (docs/sdd.md §4 / §11, ADR-012):
//! absent -> defaults; present -> parsed; non-positive durations -> error.

use std::fs;
use std::path::PathBuf;

use w_dashboard_linux::config::{self, ConfigError};

fn temp_config_path(name: &str) -> PathBuf {
    let mut path = std::env::temp_dir();
    path.push(format!("w_dashboard_pomo_{name}_{}.toml", std::process::id()));
    path
}

#[test]
fn absent_section_uses_defaults() {
    let path = temp_config_path("absent");
    fs::write(&path, "[general]\nrefresh_interval_secs = 60\n").unwrap();

    let cfg = config::load_config(Some(&path)).unwrap();
    assert!(cfg.pomodoro.enabled);
    assert_eq!(cfg.pomodoro.focus_minutes, 25);
    assert_eq!(cfg.pomodoro.break_minutes, 5);
    assert!(cfg.pomodoro.notify);
    assert!(cfg.pomodoro.sound);

    fs::remove_file(&path).ok();
}

#[test]
fn full_section_is_parsed() {
    let path = temp_config_path("full");
    fs::write(
        &path,
        "[pomodoro]\nenabled = false\nfocus_minutes = 50\nbreak_minutes = 10\nnotify = false\nsound = false\n",
    )
    .unwrap();

    let cfg = config::load_config(Some(&path)).unwrap();
    assert!(!cfg.pomodoro.enabled);
    assert_eq!(cfg.pomodoro.focus_minutes, 50);
    assert_eq!(cfg.pomodoro.break_minutes, 10);
    assert!(!cfg.pomodoro.notify);
    assert!(!cfg.pomodoro.sound);

    fs::remove_file(&path).ok();
}

#[test]
fn partial_section_fills_missing_with_defaults() {
    let path = temp_config_path("partial");
    fs::write(&path, "[pomodoro]\nfocus_minutes = 30\n").unwrap();

    let cfg = config::load_config(Some(&path)).unwrap();
    assert!(cfg.pomodoro.enabled);
    assert_eq!(cfg.pomodoro.focus_minutes, 30);
    assert_eq!(cfg.pomodoro.break_minutes, 5);
    assert!(cfg.pomodoro.notify);
    assert!(cfg.pomodoro.sound);

    fs::remove_file(&path).ok();
}

#[test]
fn zero_focus_minutes_is_an_error() {
    let path = temp_config_path("zero_focus");
    fs::write(&path, "[pomodoro]\nfocus_minutes = 0\n").unwrap();

    let err = config::load_config(Some(&path)).unwrap_err();
    assert!(matches!(err, ConfigError::Parse(_)), "expected Parse error, got {err:?}");
    assert!(err.to_string().contains("focus_minutes"), "message should name the field: {err}");

    fs::remove_file(&path).ok();
}

#[test]
fn negative_break_minutes_is_an_error() {
    let path = temp_config_path("neg_break");
    fs::write(&path, "[pomodoro]\nbreak_minutes = -3\n").unwrap();

    let err = config::load_config(Some(&path)).unwrap_err();
    assert!(matches!(err, ConfigError::Parse(_)), "expected Parse error, got {err:?}");

    fs::remove_file(&path).ok();
}
