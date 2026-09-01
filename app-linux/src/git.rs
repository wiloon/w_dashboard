//! Git collection: subprocess wrapper, `porcelain=v2` parsing and `RepoState`
//! derivation, per docs/sdd.md §7.1/§7.2. Parsing and derivation are pure
//! functions so they can be covered by docs/test-vectors/.

use std::fmt;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::config::RepoConfig;
use crate::model::{RepoState, RepoStatus};

#[derive(Debug)]
pub enum GitError {
    CommandNotFound,
    Timeout,
    Io(String),
}

impl fmt::Display for GitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GitError::CommandNotFound => write!(f, "git command not found"),
            GitError::Timeout => write!(f, "git command timed out"),
            GitError::Io(msg) => write!(f, "git command failed: {msg}"),
        }
    }
}

impl std::error::Error for GitError {}

/// Parsed result of `git status --porcelain=v2 --branch`, before RepoState
/// derivation. See docs/sdd.md §7.1.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedGitStatus {
    pub branch: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    pub staged: u32,
    pub modified: u32,
    pub untracked: u32,
    pub conflicted: u32,
}

/// Parse `git status --porcelain=v2 --branch` output into structured counts.
/// Pure function — covered by docs/test-vectors/git-porcelain/.
pub fn parse_porcelain_v2(text: &str) -> ParsedGitStatus {
    let mut result = ParsedGitStatus::default();

    for line in text.lines() {
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("# branch.head ") {
            result.branch = if rest == "(detached)" {
                None
            } else {
                Some(rest.to_string())
            };
        } else if let Some(rest) = line.strip_prefix("# branch.upstream ") {
            result.upstream = Some(rest.to_string());
        } else if let Some(rest) = line.strip_prefix("# branch.ab ") {
            for tok in rest.split_whitespace() {
                if let Some(n) = tok.strip_prefix('+') {
                    result.ahead = n.parse().unwrap_or(0);
                } else if let Some(n) = tok.strip_prefix('-') {
                    result.behind = n.parse().unwrap_or(0);
                }
            }
        } else if line.starts_with('#') {
            // other header lines (e.g. branch.oid): not needed, ignore.
        } else {
            let mut parts = line.splitn(3, ' ');
            let kind = parts.next().unwrap_or("");
            match kind {
                "1" | "2" => {
                    let xy = parts.next().unwrap_or("");
                    let mut chars = xy.chars();
                    let x = chars.next().unwrap_or('.');
                    let y = chars.next().unwrap_or('.');
                    if x != '.' {
                        result.staged += 1;
                    }
                    if y != '.' {
                        result.modified += 1;
                    }
                }
                "u" => result.conflicted += 1,
                "?" => result.untracked += 1,
                "!" => { /* ignored entries do not count, per SDD §7.1 */ }
                _ => {}
            }
        }
    }

    result
}

/// Inputs to RepoState derivation. Mirrors the fields used by the decision
/// table in docs/sdd.md §7.2.
#[derive(Debug, Clone, Default)]
pub struct DeriveInput {
    pub ahead: u32,
    pub behind: u32,
    pub staged: u32,
    pub modified: u32,
    pub untracked: u32,
    pub conflicted: u32,
    pub has_upstream: bool,
    pub error: Option<String>,
}

/// Derive the single summary `RepoState` per the decision table in
/// docs/sdd.md §7.2 (matched in order, first match wins). Pure function —
/// covered by docs/test-vectors/repo-state/.
pub fn derive_state(input: &DeriveInput) -> RepoState {
    if input.error.is_some() {
        return RepoState::Error;
    }
    if input.conflicted + input.staged + input.modified + input.untracked > 0 {
        return RepoState::Dirty;
    }
    if !input.has_upstream {
        return RepoState::NoUpstream;
    }
    if input.ahead > 0 && input.behind > 0 {
        return RepoState::Diverged;
    }
    if input.behind > 0 {
        return RepoState::NeedsPull;
    }
    if input.ahead > 0 {
        return RepoState::NeedsPush;
    }
    RepoState::Clean
}

/// One of the three explicit, safe sync operations offered per repo
/// (docs/sdd.md §7.5, ADR-011). Nothing here can leave a repo in a state that
/// needs manual cleanup: `pull` is fast-forward-only, `push` only fails
/// cleanly, `fetch` never touches the work tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepoAction {
    Pull,
    Push,
    Fetch,
}

impl RepoAction {
    pub fn parse(s: &str) -> Option<RepoAction> {
        match s {
            "pull" => Some(RepoAction::Pull),
            "push" => Some(RepoAction::Push),
            "fetch" => Some(RepoAction::Fetch),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            RepoAction::Pull => "pull",
            RepoAction::Push => "push",
            RepoAction::Fetch => "fetch",
        }
    }
}

/// Which action buttons a row should offer, given its summary `RepoState`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AllowedActions {
    pub pull: bool,
    pub push: bool,
    pub fetch: bool,
}

/// Pure function mapping `RepoState` to the offered actions, per the table in
/// docs/sdd.md §7.5. Covered by docs/test-vectors/repo-actions/.
pub fn allowed_actions(state: RepoState) -> AllowedActions {
    match state {
        RepoState::Error => AllowedActions { pull: false, push: false, fetch: false },
        RepoState::NeedsPull => AllowedActions { pull: true, push: false, fetch: true },
        RepoState::NeedsPush => AllowedActions { pull: false, push: true, fetch: true },
        // Clean / Dirty / Diverged / NoUpstream: fetch only.
        _ => AllowedActions { pull: false, push: false, fetch: true },
    }
}

/// Outcome of a `run_repo_action` call. `summary` is a one-line message for the
/// UI on success; `error` carries git's stderr first line on failure.
#[derive(Debug, Clone)]
pub struct GitActionResult {
    pub action: RepoAction,
    pub ok: bool,
    pub summary: String,
    pub error: Option<String>,
}

fn first_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("")
        .to_string()
}

fn last_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .rev()
        .find(|l| !l.is_empty())
        .unwrap_or("")
        .to_string()
}

fn truncate_message(mut s: String) -> String {
    const MAX: usize = 160;
    if s.chars().count() > MAX {
        s = s.chars().take(MAX - 1).collect::<String>();
        s.push('…');
    }
    s
}

/// Run one explicit sync operation on a repo (docs/sdd.md §7.5). Side-effecting
/// and network-bound; never panics. `pull` is `--ff-only` so a non-fast-forward
/// simply fails without changing anything.
pub fn run_repo_action(
    repo: &RepoConfig,
    action: RepoAction,
    timeout: Duration,
) -> GitActionResult {
    let args: &[&str] = match action {
        RepoAction::Pull => &["pull", "--ff-only"],
        RepoAction::Push => &["push"],
        RepoAction::Fetch => &["fetch", "--quiet"],
    };

    match run_git(&repo.path, args, timeout) {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let stderr = String::from_utf8_lossy(&out.stderr);
            if out.status.success() {
                let mut summary = last_line(&stdout);
                if summary.is_empty() {
                    summary = last_line(&stderr);
                }
                if summary.is_empty() {
                    summary = match action {
                        RepoAction::Pull => "Already up to date".to_string(),
                        RepoAction::Push => "Everything up-to-date".to_string(),
                        RepoAction::Fetch => "Fetched".to_string(),
                    };
                }
                GitActionResult {
                    action,
                    ok: true,
                    summary: truncate_message(summary),
                    error: None,
                }
            } else {
                let mut err = first_line(&stderr);
                if err.is_empty() {
                    err = first_line(&stdout);
                }
                if err.is_empty() {
                    err = format!("git {} failed", action.as_str());
                }
                GitActionResult {
                    action,
                    ok: false,
                    summary: String::new(),
                    error: Some(truncate_message(err)),
                }
            }
        }
        Err(e) => GitActionResult {
            action,
            ok: false,
            summary: String::new(),
            error: Some(e.to_string()),
        },
    }
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Run `git -C <path> <args>` with a hard timeout, killing the child process
/// if it overruns. Side-effecting — not covered by test vectors.
fn run_git(path: &Path, args: &[&str], timeout: Duration) -> Result<Output, GitError> {
    let mut child = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                GitError::CommandNotFound
            } else {
                GitError::Io(e.to_string())
            }
        })?;

    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => {
                return child
                    .wait_with_output()
                    .map_err(|e| GitError::Io(e.to_string()));
            }
            Ok(None) => {
                if start.elapsed() > timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(GitError::Timeout);
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(e) => return Err(GitError::Io(e.to_string())),
        }
    }
}

/// Collect one repo's status per docs/sdd.md §7.1, then derive its state via
/// §7.2. Never panics; all failures land in `RepoStatus.error`.
pub fn collect_repo(repo: &RepoConfig, fetch_remote: bool, timeout: Duration) -> RepoStatus {
    let name = repo
        .name
        .clone()
        .unwrap_or_else(|| repo.path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| repo.path.display().to_string()));
    let mut status = RepoStatus::new(name, repo.path.display().to_string());

    match run_git(&repo.path, &["rev-parse", "--is-inside-work-tree"], timeout) {
        Ok(out) if out.status.success() => {}
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
            status.error = Some(if stderr.is_empty() {
                "not a git work tree".to_string()
            } else {
                stderr
            });
            status.state = RepoState::Error;
            return status;
        }
        Err(e) => {
            status.error = Some(e.to_string());
            status.state = RepoState::Error;
            return status;
        }
    }

    if fetch_remote {
        match run_git(&repo.path, &["fetch", "--quiet"], timeout) {
            Ok(out) if out.status.success() => {
                status.last_fetch_at = Some(now_unix());
            }
            Ok(out) => {
                let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
                status.error = Some(format!("fetch failed: {stderr}"));
            }
            Err(e) => {
                status.error = Some(format!("fetch failed: {e}"));
            }
        }
    }

    match run_git(&repo.path, &["status", "--porcelain=v2", "--branch"], timeout) {
        Ok(out) if out.status.success() => {
            let text = String::from_utf8_lossy(&out.stdout);
            let parsed = parse_porcelain_v2(&text);
            status.branch = parsed.branch;
            status.ahead = parsed.ahead;
            status.behind = parsed.behind;
            status.staged = parsed.staged;
            status.modified = parsed.modified;
            status.untracked = parsed.untracked;
            status.conflicted = parsed.conflicted;
            status.upstream = parsed.upstream.clone();

            let derive_input = DeriveInput {
                ahead: status.ahead,
                behind: status.behind,
                staged: status.staged,
                modified: status.modified,
                untracked: status.untracked,
                conflicted: status.conflicted,
                has_upstream: status.upstream.is_some(),
                error: status.error.clone(),
            };
            status.state = derive_state(&derive_input);
        }
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
            status.error = Some(if stderr.is_empty() {
                "git status failed".to_string()
            } else {
                stderr
            });
            status.state = RepoState::Error;
        }
        Err(e) => {
            status.error = Some(e.to_string());
            status.state = RepoState::Error;
        }
    }

    status
}
