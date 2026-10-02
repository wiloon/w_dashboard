import SwiftUI

/// Top-level tabs (docs/sdd.md §9, ADR-014).
enum MainTab: Hashable {
    case dashboard
    case network
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showManageRepos = false
    @State private var tab: MainTab = .dashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("w_dashboard")
                    .font(.system(size: 22, weight: .heavy))
                Spacer()
                if appState.config.network.enabled {
                    Picker("", selection: $tab) {
                        Text("Dashboard").tag(MainTab.dashboard)
                        Text("Network").tag(MainTab.network)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
            }

            if let configLoadError = appState.configLoadError {
                Text("Config error: \(configLoadError) — using defaults")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if tab == .network && appState.config.network.enabled {
                NetworkView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        NowPanelView()
                        RepoListView(showManageRepos: $showManageRepos)
                        WeatherView()
                    }
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
