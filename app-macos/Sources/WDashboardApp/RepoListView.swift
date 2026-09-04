// Repos section. Color semantics per docs/sdd.md §9: green=Clean,
// yellow=NeedsPush/NeedsPull/Dirty, red=Diverged/Error, gray=NoUpstream.
// Mirrors app-linux/src/main.rs::state_label_color.

import SwiftUI
import WDashboardCore

private func stateLabel(_ state: RepoState) -> String {
    switch state {
    case .clean: return "Clean"
    case .dirty: return "Dirty"
    case .needsPush: return "Needs Push"
    case .needsPull: return "Needs Pull"
    case .diverged: return "Diverged"
    case .noUpstream: return "No Upstream"
    case .error: return "Error"
    }
}

/// Neutral badge for a row whose collection is still in flight (gray, same
/// family as NoUpstream — "no verdict yet", per SDD §9 color semantics).
private let pendingColor = Color(red: 0xb0 / 255, green: 0xb6 / 255, blue: 0xbd / 255)

private func stateColor(_ state: RepoState) -> Color {
    switch state {
    case .clean: return Color(red: 0x4c / 255, green: 0xaf / 255, blue: 0x50 / 255)
    case .dirty, .needsPush, .needsPull: return Color(red: 0xff / 255, green: 0xc1 / 255, blue: 0x07 / 255)
    case .diverged, .error: return Color(red: 0xf4 / 255, green: 0x43 / 255, blue: 0x36 / 255)
    case .noUpstream: return Color(red: 0xb0 / 255, green: 0xb6 / 255, blue: 0xbd / 255)
    }
}

struct RepoListView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showManageRepos: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Repos").font(.headline)
                Spacer()
                Button("Manage…") { showManageRepos = true }
                    .buttonStyle(.borderless)
            }
            if appState.repoStatuses.isEmpty {
                Text("No repos configured").foregroundStyle(.secondary).font(.subheadline)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(appState.repoStatuses.enumerated()), id: \.offset) { index, repo in
                        if index > 0 { Divider() }
                        RepoRowView(
                            repo: repo,
                            pending: appState.pendingRepoIndices.contains(index)
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }
}

private struct RepoRowView: View {
    @EnvironmentObject var appState: AppState
    let repo: RepoStatus
    /// This row's collection is still running: show a neutral "Checking…"
    /// badge rather than a state that may be stale (or not collected yet).
    let pending: Bool
    @State private var expanded = false

    private var busy: Bool { appState.repoActionBusyPaths.contains(repo.path) }
    /// This row's single-row manual refresh is running (SDD §8.1).
    private var rowRefreshing: Bool { appState.repoRowRefreshingPaths.contains(repo.path) }
    private var actionsDisabled: Bool { busy || rowRefreshing || appState.refreshing }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(repo.name).bold()
                Text(repo.branch ?? "detached").foregroundStyle(.secondary).font(.subheadline)
                Spacer()
                if !pending && (repo.error?.isEmpty ?? true) {
                    actionButtons
                }
                Text(pending ? "Checking…" : stateLabel(repo.state))
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background((pending ? pendingColor : stateColor(repo.state)).opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                Button(expanded ? "Hide" : "Details") { expanded.toggle() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                // Single-row refresh, pinned to the far right of the row: re-check
                // just this repo without a full refresh (SDD §8, §8.1). Available
                // in every state, incl. Error. Icon-only; spins while collecting.
                if !pending {
                    Button {
                        appState.refreshRepoRow(path: repo.path)
                    } label: {
                        if rowRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(actionsDisabled)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Refresh this repo")
                }
            }
            if let result = appState.repoActionResults[repo.path] {
                Text(result.ok ? result.summary : (result.error ?? "action failed"))
                    .font(.caption)
                    .foregroundStyle(result.ok ? .green : .red)
            }
            if expanded {
                Text(
                    "ahead \(repo.ahead) · behind \(repo.behind) · staged \(repo.staged) · "
                        + "modified \(repo.modified) · untracked \(repo.untracked) · conflicted \(repo.conflicted)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = repo.error, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let lastFetch = repo.lastFetchAt {
                    Text("last fetch: \(Date(timeIntervalSince1970: TimeInterval(lastFetch)).formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Pull / Push / Fetch buttons per docs/sdd.md §7.5, shown by
    /// `allowedActions(repo.state)`; disabled while this row's action runs or a
    /// full refresh is in flight. Sits inline on the repo's name row.
    @ViewBuilder
    private var actionButtons: some View {
        let allowed = allowedActions(repo.state)
        if allowed.pull {
            Button(busy ? "Pulling…" : "Pull") { appState.repoAction(path: repo.path, action: .pull) }
                .disabled(actionsDisabled)
                .tint(.accentColor)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        if allowed.push {
            Button(busy ? "Pushing…" : "Push") { appState.repoAction(path: repo.path, action: .push) }
                .disabled(actionsDisabled)
                .tint(.accentColor)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        // When `general.fetch_remote` is on (default), every refresh already
        // fetches each repo, so the manual Fetch button is redundant (SDD §7.5).
        if allowed.fetch && !appState.config.fetchRemote {
            Button(busy ? "Fetching…" : "Fetch") { appState.repoAction(path: repo.path, action: .fetch) }
                .disabled(actionsDisabled)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
