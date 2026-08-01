//! Verifies the "Manage repos" persistence path: add/update/remove must
//! round-trip through the TOML file while leaving other sections/comments
//! untouched, and `load_config` must see the result.

use std::fs;
use std::path::PathBuf;

use w_dashboard_linux::config;

fn temp_config_path(name: &str) -> PathBuf {
    let mut path = std::env::temp_dir();
    path.push(format!("w_dashboard_test_{name}_{}.toml", std::process::id()));
    path
}

#[test]
fn add_then_remove_repo_round_trips_and_preserves_other_sections() {
    let path = temp_config_path("add_remove");
    fs::write(
        &path,
        "# a comment that must survive\n[general]\nrefresh_interval_secs = 60\n",
    )
    .unwrap();

    config::add_repo(&path, "/tmp/some/repo", Some("myrepo")).unwrap();

    let text = fs::read_to_string(&path).unwrap();
    assert!(text.contains("a comment that must survive"), "comment lost:\n{text}");
    assert!(text.contains("refresh_interval_secs = 60"), "general section lost:\n{text}");

    let cfg = config::load_config(Some(&path)).unwrap();
    assert_eq!(cfg.repos.len(), 1);
    assert_eq!(cfg.repos[0].path, PathBuf::from("/tmp/some/repo"));
    assert_eq!(cfg.repos[0].name.as_deref(), Some("myrepo"));
    assert_eq!(cfg.refresh_interval_secs, 60);

    config::remove_repo(&path, &PathBuf::from("/tmp/some/repo")).unwrap();
    let cfg = config::load_config(Some(&path)).unwrap();
    assert_eq!(cfg.repos.len(), 0, "repo should have been removed");

    let text = fs::read_to_string(&path).unwrap();
    assert!(text.contains("a comment that must survive"), "comment lost after remove:\n{text}");

    fs::remove_file(&path).ok();
}

#[test]
fn update_repo_changes_path_and_name_in_place() {
    let path = temp_config_path("update");
    fs::write(&path, "[[repos]]\npath = \"/tmp/old/path\"\nname = \"old-name\"\n").unwrap();

    config::update_repo(
        &path,
        &PathBuf::from("/tmp/old/path"),
        "/tmp/new/path",
        Some("new-name"),
    )
    .unwrap();

    let cfg = config::load_config(Some(&path)).unwrap();
    assert_eq!(cfg.repos.len(), 1, "update must not add a duplicate entry");
    assert_eq!(cfg.repos[0].path, PathBuf::from("/tmp/new/path"));
    assert_eq!(cfg.repos[0].name.as_deref(), Some("new-name"));

    fs::remove_file(&path).ok();
}

#[test]
fn add_repo_creates_missing_file() {
    let path = temp_config_path("create_missing");
    fs::remove_file(&path).ok();
    assert!(!path.exists());

    config::add_repo(&path, "/tmp/fresh/repo", None).unwrap();

    let cfg = config::load_config(Some(&path)).unwrap();
    assert_eq!(cfg.repos.len(), 1);
    assert_eq!(cfg.repos[0].path, PathBuf::from("/tmp/fresh/repo"));
    assert_eq!(cfg.repos[0].name, None);

    fs::remove_file(&path).ok();
}
