// UI-facing state and refresh orchestration. Mirrors the responsibilities
// of app-linux/src/main.rs (spawn_collect_repos / spawn_collect_weather /
// reload_and_refresh / timers), adapted to SwiftUI's async/await instead of
// mpsc channels + a polling Slint timer.

import Foundation
import SwiftUI
import WDashboardCore

struct ClockRow: Identifiable {
    var id: String { label }
    var label: String
    var time: String
    var date: String
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var config: Config
    @Published var repoStatuses: [RepoStatus] = []
    @Published var clocks: [ClockRow] = []
    @Published var weatherReport: WeatherReport?
    @Published var weatherError: String?
    @Published var weatherConfigured: Bool = false
    @Published var refreshing: Bool = false
    @Published var lastUpdated: String = "never"
    @Published var repoFormError: String = ""
    @Published var configLoadError: String?

    let configPath: String

    private var started = false
    private var clockTimerTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?

    init() {
        let path = defaultConfigPath()
        configPath = path
        do {
            config = try loadConfig(path: path)
        } catch {
            configLoadError = "\(error)"
            config = Config.defaultConfig()
        }
        weatherConfigured = config.weather != nil
        clocks = Self.computeClocks(config.clocks, now: Date())
    }

    /// Called once from `ContentView.onAppear`. Kicks off the first
    /// collection plus the clock/auto-refresh timers.
    func start() {
        guard !started else { return }
        started = true
        refresh()
        startClockTimer()
        startAutoRefreshTimer()
    }

    func refresh() {
        refreshing = true
        let repos = config.repos
        let fetchRemote = config.fetchRemote
        let timeout = TimeInterval(config.commandTimeoutSecs)

        Task.detached(priority: .userInitiated) {
            let statuses = repos.map { collectRepo(repo: $0, fetchRemote: fetchRemote, timeout: timeout) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.repoStatuses = statuses
                self.refreshing = false
                self.lastUpdated = Self.lastUpdatedFormatter.string(from: Date())
            }
        }

        if let weatherConfig = config.weather {
            Task.detached(priority: .userInitiated) {
                do {
                    let report = try fetchWeather(config: weatherConfig, timeout: timeout)
                    await MainActor.run { [weak self] in
                        self?.weatherReport = report
                        self?.weatherError = nil
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.weatherError = "\(error)"
                    }
                }
            }
        }
    }

    // ---------------- Repo management ----------------
    // Mirrors app-linux's on_add_repo/on_remove_repo/on_update_repo handlers.

    func addRepo(rawPath: String, rawName: String) {
        let path = rawPath.trimmingCharacters(in: .whitespaces)
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else {
            repoFormError = "Path cannot be empty"
            return
        }
        do {
            try WDashboardCore.addRepo(configPath: configPath, rawPath: path, name: name.isEmpty ? nil : name)
            repoFormError = ""
            reloadAndRefresh()
        } catch {
            repoFormError = "\(error)"
        }
    }

    func removeRepo(rawPath: String) {
        let target = expandPath(rawPath)
        do {
            try WDashboardCore.removeRepo(configPath: configPath, target: target)
            reloadAndRefresh()
        } catch {
            repoFormError = "\(error)"
        }
    }

    func updateRepo(oldRawPath: String, newRawPath: String, newRawName: String) {
        let oldTarget = expandPath(oldRawPath)
        let newPath = newRawPath.trimmingCharacters(in: .whitespaces)
        let newName = newRawName.trimmingCharacters(in: .whitespaces)
        guard !newPath.isEmpty else {
            repoFormError = "Path cannot be empty"
            return
        }
        do {
            try WDashboardCore.updateRepo(
                configPath: configPath, target: oldTarget, newRawPath: newPath,
                newName: newName.isEmpty ? nil : newName
            )
            repoFormError = ""
            reloadAndRefresh()
        } catch {
            repoFormError = "\(error)"
        }
    }

    private func reloadAndRefresh() {
        if let reloaded = try? loadConfig(path: configPath) {
            config = reloaded
            weatherConfigured = reloaded.weather != nil
            clocks = Self.computeClocks(reloaded.clocks, now: Date())
        }
        refresh()
    }

    // ---------------- Timers ----------------

    private func startClockTimer() {
        clockTimerTask?.cancel()
        clockTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.clocks = Self.computeClocks(self.config.clocks, now: Date())
            }
        }
    }

    private func startAutoRefreshTimer() {
        autoRefreshTask?.cancel()
        let interval = config.refreshIntervalSecs
        guard interval > 0 else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                self?.refresh()
            }
        }
    }

    private static func computeClocks(_ configs: [ClockConfig], now: Date) -> [ClockRow] {
        configs.map { clock in
            let tz = TimeZone(identifier: clock.tz) ?? TimeZone(identifier: "UTC")!
            return ClockRow(label: clock.label, time: timeFormatter(tz).string(from: now), date: dateFormatter(tz).string(from: now))
        }
    }

    private static func timeFormatter(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "HH:mm:ss"
        return f
    }

    private static func dateFormatter(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd (EEE)"
        return f
    }

    private static let lastUpdatedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
