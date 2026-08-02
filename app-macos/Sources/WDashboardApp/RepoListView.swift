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
                        RepoRowView(repo: repo)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }
}

private struct RepoRowView: View {
    let repo: RepoStatus
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(repo.name).bold()
                Text(repo.branch ?? "detached").foregroundStyle(.secondary).font(.subheadline)
                Spacer()
                Text(stateLabel(repo.state))
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(stateColor(repo.state).opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                Button(expanded ? "Hide" : "Details") { expanded.toggle() }
                    .buttonStyle(.borderless)
                    .font(.caption)
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
}
