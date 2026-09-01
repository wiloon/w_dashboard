//! e2e smoke for the three explicit sync actions (docs/sdd.md §7.5, ADR-011).
//! Builds throwaway local repos (a bare "remote" + two clones), drives them
//! into NeedsPull / NeedsPush / Diverged, and checks `run_repo_action`.
//! Not a strict contract test — that's `repo-actions` vectors; this just
//! exercises the real subprocess path.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use w_dashboard_linux::config::RepoConfig;
use w_dashboard_linux::git::{collect_repo, run_repo_action, RepoAction};
use w_dashboard_linux::model::RepoState;

fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .output()
        .expect("git spawn");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

fn git_ok() -> bool {
    Command::new("git").arg("--version").output().is_ok()
}

fn workdir(name: &str) -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!("w_dashboard_actions_{name}_{}", std::process::id()));
    fs::remove_dir_all(&p).ok();
    fs::create_dir_all(&p).unwrap();
    p
}

fn commit_file(dir: &Path, file: &str, contents: &str) {
    fs::write(dir.join(file), contents).unwrap();
    git(dir, &["add", "."]);
    git(dir, &["commit", "-m", file]);
}

fn repo_cfg(dir: &Path) -> RepoConfig {
    RepoConfig { path: dir.to_path_buf(), name: None }
}

const TIMEOUT: Duration = Duration::from_secs(20);

/// remote (bare) <- clone `up` seeds one commit; `work` is the repo under test.
fn scaffold(name: &str) -> (PathBuf, PathBuf, PathBuf) {
    let root = workdir(name);
    let remote = root.join("remote.git");
    let up = root.join("up");
    let work = root.join("work");

    git(&root, &["init", "--bare", "-b", "main", remote.to_str().unwrap()]);
    git(&root, &["clone", remote.to_str().unwrap(), up.to_str().unwrap()]);
    git(&up, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    commit_file(&up, "a.txt", "1");
    git(&up, &["push", "-u", "origin", "main"]);

    git(&root, &["clone", remote.to_str().unwrap(), work.to_str().unwrap()]);
    (root, up, work)
}

#[test]
fn pull_ff_only_clears_behind() {
    if !git_ok() {
        eprintln!("git not available; skipping");
        return;
    }
    let (root, up, work) = scaffold("pull");

    // remote moves ahead
    commit_file(&up, "b.txt", "2");
    git(&up, &["push"]);

    let cfg = repo_cfg(&work);
    let before = collect_repo(&cfg, true, TIMEOUT);
    assert_eq!(before.state, RepoState::NeedsPull, "expected NeedsPull, got {before:?}");

    let result = run_repo_action(&cfg, RepoAction::Pull, TIMEOUT);
    assert!(result.ok, "pull should succeed: {result:?}");

    let after = collect_repo(&cfg, false, TIMEOUT);
    assert_eq!(after.state, RepoState::Clean, "expected Clean after pull, got {after:?}");
    assert!(work.join("b.txt").exists(), "pulled file missing");

    fs::remove_dir_all(&root).ok();
}

#[test]
fn push_clears_ahead() {
    if !git_ok() {
        return;
    }
    let (root, _up, work) = scaffold("push");

    commit_file(&work, "local.txt", "local");
    let cfg = repo_cfg(&work);
    let before = collect_repo(&cfg, true, TIMEOUT);
    assert_eq!(before.state, RepoState::NeedsPush, "expected NeedsPush, got {before:?}");

    let result = run_repo_action(&cfg, RepoAction::Push, TIMEOUT);
    assert!(result.ok, "push should succeed: {result:?}");

    let after = collect_repo(&cfg, false, TIMEOUT);
    assert_eq!(after.state, RepoState::Clean, "expected Clean after push, got {after:?}");

    fs::remove_dir_all(&root).ok();
}

#[test]
fn pull_ff_only_fails_cleanly_when_diverged() {
    if !git_ok() {
        return;
    }
    let (root, up, work) = scaffold("diverged");

    // both sides commit -> non-fast-forward
    commit_file(&up, "b.txt", "remote");
    git(&up, &["push"]);
    commit_file(&work, "c.txt", "local");

    let cfg = repo_cfg(&work);
    let before = collect_repo(&cfg, true, TIMEOUT);
    assert_eq!(before.state, RepoState::Diverged, "expected Diverged, got {before:?}");
    let head_before = String::from_utf8(
        Command::new("git").arg("-C").arg(&work).args(["rev-parse", "HEAD"]).output().unwrap().stdout,
    )
    .unwrap();

    let result = run_repo_action(&cfg, RepoAction::Pull, TIMEOUT);
    assert!(!result.ok, "ff-only pull must fail on divergence: {result:?}");
    assert!(result.error.is_some());

    let head_after = String::from_utf8(
        Command::new("git").arg("-C").arg(&work).args(["rev-parse", "HEAD"]).output().unwrap().stdout,
    )
    .unwrap();
    assert_eq!(head_before, head_after, "HEAD must not move on failed ff-only pull");
    assert!(!work.join("b.txt").exists(), "work tree must be untouched");

    fs::remove_dir_all(&root).ok();
}
