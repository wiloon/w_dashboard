// Git collection: `porcelain=v2` parsing and RepoState derivation, per
// docs/sdd.md §7.1/§7.2. Mirrors app-linux/src/git.rs. Parsing and
// derivation are pure functions so they can be covered by
// docs/test-vectors/.

import Foundation

/// Parsed result of `git status --porcelain=v2 --branch`, before RepoState
/// derivation. See docs/sdd.md §7.1.
public struct ParsedGitStatus: Equatable, Sendable {
    public var branch: String?
    public var upstream: String?
    public var ahead: Int = 0
    public var behind: Int = 0
    public var staged: Int = 0
    public var modified: Int = 0
    public var untracked: Int = 0
    public var conflicted: Int = 0
}

/// Parse `git status --porcelain=v2 --branch` output into structured counts.
/// Pure function — covered by docs/test-vectors/git-porcelain/.
public func parsePorcelainV2(_ text: String) -> ParsedGitStatus {
    var result = ParsedGitStatus()

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.isEmpty { continue }
        if let rest = stripPrefix(line, "# branch.head ") {
            result.branch = rest == "(detached)" ? nil : rest
        } else if let rest = stripPrefix(line, "# branch.upstream ") {
            result.upstream = rest
        } else if let rest = stripPrefix(line, "# branch.ab ") {
            for tok in rest.split(separator: " ") {
                if tok.hasPrefix("+") {
                    result.ahead = Int(tok.dropFirst()) ?? 0
                } else if tok.hasPrefix("-") {
                    result.behind = Int(tok.dropFirst()) ?? 0
                }
            }
        } else if line.hasPrefix("#") {
            // other header lines (e.g. branch.oid): not needed, ignore.
        } else {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            let kind = parts.first.map(String.init) ?? ""
            switch kind {
            case "1", "2":
                let xy = parts.count > 1 ? String(parts[1]) : ""
                let chars = Array(xy)
                let x = chars.count > 0 ? chars[0] : "."
                let y = chars.count > 1 ? chars[1] : "."
                if x != "." { result.staged += 1 }
                if y != "." { result.modified += 1 }
            case "u":
                result.conflicted += 1
            case "?":
                result.untracked += 1
            case "!":
                break // ignored entries do not count, per SDD §7.1
            default:
                break
            }
        }
    }

    return result
}

private func stripPrefix(_ line: Substring, _ prefix: String) -> String? {
    guard line.hasPrefix(prefix) else { return nil }
    return String(line.dropFirst(prefix.count))
}

/// Inputs to RepoState derivation. Mirrors the fields used by the decision
/// table in docs/sdd.md §7.2.
public struct DeriveInput: Sendable {
    public var ahead: Int
    public var behind: Int
    public var staged: Int
    public var modified: Int
    public var untracked: Int
    public var conflicted: Int
    public var hasUpstream: Bool
    public var error: String?

    public init(
        ahead: Int,
        behind: Int,
        staged: Int,
        modified: Int,
        untracked: Int,
        conflicted: Int,
        hasUpstream: Bool,
        error: String?
    ) {
        self.ahead = ahead
        self.behind = behind
        self.staged = staged
        self.modified = modified
        self.untracked = untracked
        self.conflicted = conflicted
        self.hasUpstream = hasUpstream
        self.error = error
    }
}

/// Derive the single summary `RepoState` per the decision table in
/// docs/sdd.md §7.2 (matched in order, first match wins). Pure function —
/// covered by docs/test-vectors/repo-state/.
public func deriveState(_ input: DeriveInput) -> RepoState {
    if input.error != nil {
        return .error
    }
    if input.conflicted + input.staged + input.modified + input.untracked > 0 {
        return .dirty
    }
    if !input.hasUpstream {
        return .noUpstream
    }
    if input.ahead > 0 && input.behind > 0 {
        return .diverged
    }
    if input.behind > 0 {
        return .needsPull
    }
    if input.ahead > 0 {
        return .needsPush
    }
    return .clean
}

private func nowUnix() -> Int64 {
    Int64(Date().timeIntervalSince1970)
}

// MARK: - Explicit safe sync actions (docs/sdd.md §7.5, ADR-011)

/// One of the three explicit, safe sync operations offered per repo. Nothing
/// here can leave a repo needing manual cleanup: `pull` is fast-forward-only,
/// `push` only fails cleanly, `fetch` never touches the work tree.
public enum RepoAction: String, Sendable {
    case pull
    case push
    case fetch
}

/// Which action buttons a row should offer, given its summary `RepoState`.
public struct AllowedActions: Equatable, Sendable {
    public var pull: Bool
    public var push: Bool
    public var fetch: Bool

    public init(pull: Bool, push: Bool, fetch: Bool) {
        self.pull = pull
        self.push = push
        self.fetch = fetch
    }
}

/// Pure function mapping `RepoState` to the offered actions, per the table in
/// docs/sdd.md §7.5. Covered by docs/test-vectors/repo-actions/.
public func allowedActions(_ state: RepoState) -> AllowedActions {
    switch state {
    case .error:
        return AllowedActions(pull: false, push: false, fetch: false)
    case .needsPull:
        return AllowedActions(pull: true, push: false, fetch: true)
    case .needsPush:
        return AllowedActions(pull: false, push: true, fetch: true)
    case .clean, .dirty, .diverged, .noUpstream:
        return AllowedActions(pull: false, push: false, fetch: true)
    }
}

/// Outcome of a `runRepoAction` call. `summary` is a one-line message for the
/// UI on success; `error` carries git's stderr first line on failure.
public struct GitActionResult: Sendable {
    public var action: RepoAction
    public var ok: Bool
    public var summary: String
    public var error: String?

    public init(action: RepoAction, ok: Bool, summary: String, error: String?) {
        self.action = action
        self.ok = ok
        self.summary = summary
        self.error = error
    }
}

private func firstLine(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty } ?? ""
}

private func lastLine(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty } ?? ""
}

private func truncatedMessage(_ s: String) -> String {
    let maxLen = 160
    guard s.count > maxLen else { return s }
    return String(s.prefix(maxLen - 1)) + "…"
}

/// Run one explicit sync operation on a repo (docs/sdd.md §7.5). Side-effecting
/// and network-bound; never throws. `pull` is `--ff-only` so a non-fast-forward
/// simply fails without changing anything.
public func runRepoAction(repo: RepoConfig, action: RepoAction, timeout: TimeInterval) -> GitActionResult {
    let extra: [String]
    switch action {
    case .pull: extra = ["pull", "--ff-only"]
    case .push: extra = ["push"]
    case .fetch: extra = ["fetch", "--quiet"]
    }

    do {
        let result = try runProcess("git", args: ["-C", repo.path] + extra, timeout: timeout)
        if result.succeeded {
            var summary = lastLine(result.stdout)
            if summary.isEmpty { summary = lastLine(result.stderr) }
            if summary.isEmpty {
                switch action {
                case .pull: summary = "Already up to date"
                case .push: summary = "Everything up-to-date"
                case .fetch: summary = "Fetched"
                }
            }
            return GitActionResult(action: action, ok: true, summary: truncatedMessage(summary), error: nil)
        } else {
            var err = firstLine(result.stderr)
            if err.isEmpty { err = firstLine(result.stdout) }
            if err.isEmpty { err = "git \(action.rawValue) failed" }
            return GitActionResult(action: action, ok: false, summary: "", error: truncatedMessage(err))
        }
    } catch {
        return GitActionResult(action: action, ok: false, summary: "", error: "\(error)")
    }
}

/// Collect one repo's status per docs/sdd.md §7.1, then derive its state via
/// §7.2. Never throws; all failures land in `RepoStatus.error`.
public func collectRepo(repo: RepoConfig, fetchRemote: Bool, timeout: TimeInterval) -> RepoStatus {
    let name = repo.name ?? (repo.path as NSString).lastPathComponent
    var status = RepoStatus(name: name.isEmpty ? repo.path : name, path: repo.path)

    do {
        let result = try runProcess("git", args: ["-C", repo.path, "rev-parse", "--is-inside-work-tree"], timeout: timeout)
        if !result.succeeded {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            status.error = stderr.isEmpty ? "not a git work tree" : stderr
            status.state = .error
            return status
        }
    } catch {
        status.error = "\(error)"
        status.state = .error
        return status
    }

    if fetchRemote {
        do {
            let result = try runProcess("git", args: ["-C", repo.path, "fetch", "--quiet"], timeout: timeout)
            if result.succeeded {
                status.lastFetchAt = nowUnix()
            } else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                status.error = "fetch failed: \(stderr)"
            }
        } catch {
            status.error = "fetch failed: \(error)"
        }
    }

    do {
        let result = try runProcess("git", args: ["-C", repo.path, "status", "--porcelain=v2", "--branch"], timeout: timeout)
        if result.succeeded {
            let parsed = parsePorcelainV2(result.stdout)
            status.branch = parsed.branch
            status.ahead = parsed.ahead
            status.behind = parsed.behind
            status.staged = parsed.staged
            status.modified = parsed.modified
            status.untracked = parsed.untracked
            status.conflicted = parsed.conflicted
            status.upstream = parsed.upstream

            let input = DeriveInput(
                ahead: status.ahead,
                behind: status.behind,
                staged: status.staged,
                modified: status.modified,
                untracked: status.untracked,
                conflicted: status.conflicted,
                hasUpstream: status.upstream != nil,
                error: status.error
            )
            status.state = deriveState(input)
        } else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            status.error = stderr.isEmpty ? "git status failed" : stderr
            status.state = .error
        }
    } catch {
        status.error = "\(error)"
        status.state = .error
    }

    return status
}
