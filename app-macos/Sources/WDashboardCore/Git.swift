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
