// Repo add/edit/remove form. Mirrors app-linux's Slint "Manage" panel and
// main.rs's on_add_repo/on_remove_repo/on_update_repo handlers.

import SwiftUI
import WDashboardCore

struct ManageReposView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var addPath = ""
    @State private var addName = ""
    @State private var editingPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage repos").font(.title3.bold())

            List {
                ForEach(appState.config.repos, id: \.path) { repo in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(repo.name ?? (repo.path as NSString).lastPathComponent)
                            Text(repo.path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { beginEdit(repo) }
                            .buttonStyle(.borderless)
                        Button("Remove") { appState.removeRepo(rawPath: repo.path) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(minHeight: 160)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(editingPath == nil ? "Add repo" : "Edit repo").font(.subheadline.bold())
                TextField("Path (e.g. ~/workspace/projects/foo)", text: $addPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Display name (optional)", text: $addName)
                    .textFieldStyle(.roundedBorder)
                if !appState.repoFormError.isEmpty {
                    Text(appState.repoFormError).foregroundStyle(.red).font(.caption)
                }
                HStack {
                    if let editingPath {
                        Button("Save") {
                            appState.updateRepo(oldRawPath: editingPath, newRawPath: addPath, newRawName: addName)
                            resetForm()
                        }
                        .keyboardShortcut(.defaultAction)
                        Button("Cancel") {
                            resetForm()
                            appState.repoFormError = ""
                        }
                    } else {
                        Button("Add") {
                            appState.addRepo(rawPath: addPath, rawName: addName)
                            resetForm()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 420)
    }

    private func beginEdit(_ repo: RepoConfig) {
        editingPath = repo.path
        addPath = repo.path
        addName = repo.name ?? ""
    }

    private func resetForm() {
        editingPath = nil
        addPath = ""
        addName = ""
    }
}
