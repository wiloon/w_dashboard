import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showManageRepos = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("w_dashboard")
                    .font(.system(size: 22, weight: .heavy))
                Spacer()
                Text("Last updated: \(appState.lastUpdated)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    appState.refresh()
                } label: {
                    if appState.refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(appState.refreshing)
            }

            if let configLoadError = appState.configLoadError {
                Text("Config error: \(configLoadError) — using defaults")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RepoListView(showManageRepos: $showManageRepos)
                    ClocksView()
                    WeatherView()
                }
            }
        }
        .padding(16)
        .frame(minWidth: 760, idealWidth: 920, minHeight: 560, idealHeight: 680)
        .sheet(isPresented: $showManageRepos) {
            ManageReposView()
                .environmentObject(appState)
        }
        .onAppear {
            appState.start()
        }
    }
}
