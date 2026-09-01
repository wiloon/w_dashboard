// UI-facing state and refresh orchestration. Mirrors the responsibilities
// of app-linux/src/main.rs (spawn_collect_repos / spawn_collect_weather /
// reload_and_refresh / timers), adapted to SwiftUI's async/await instead of
// mpsc channels + a polling Slint timer.
//
// Repo collection is incremental (docs/sdd.md §8), like app-linux's worker
// pool: repos are collected a few at a time and each row updates as soon as
// its own result lands, instead of the whole list being replaced at the end.

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
    /// Indices into `repoStatuses` whose collection is still running. Rows in
    /// this set show a "Checking…" badge instead of a (stale) state badge.
    @Published private(set) var pendingRepoIndices: Set<Int> = []
    /// Repo paths whose Pull/Push/Fetch action is currently running. Those rows
    /// show a progress label and disabled buttons (docs/sdd.md §7.5).
    @Published private(set) var repoActionBusyPaths: Set<String> = []
    /// Last action result per repo path, shown inline until the next full
    /// refresh clears it.
    @Published private(set) var repoActionResults: [String: GitActionResult] = [:]
    @Published var lastUpdated: String = "never"
    @Published var repoFormError: String = ""
    @Published var configLoadError: String?

    let configPath: String

    private var started = false
    private var clockTimerTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    /// Bumped on every refresh; results carrying an older token are dropped so
    /// a slow run cannot overwrite a newer one.
    private var refreshToken = 0
    /// Repos are collected off the main thread, a few at a time, so one slow
    /// `git fetch` neither blocks the UI nor holds up the other rows.
    private let repoQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "w_dashboard.repo-collect"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

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
        let repos = config.repos
        let fetchRemote = config.fetchRemote
        let timeout = TimeInterval(config.commandTimeoutSecs)

        refreshToken &+= 1
        let token = refreshToken
        repoQueue.cancelAllOperations()

        // A full refresh clears any lingering per-row action state (SDD §7.5).
        repoActionBusyPaths.removeAll()
        repoActionResults.removeAll()

        // Seed the list in config order, carrying over whatever we already
        // know about each repo, so rows appear immediately and are then
        // replaced one by one as each collection finishes.
        repoStatuses = repos.map { seededStatus(for: $0) }
        pendingRepoIndices = Set(repoStatuses.indices)
        refreshing = !repos.isEmpty

        if repos.isEmpty {
            lastUpdated = Self.lastUpdatedFormatter.string(from: Date())
        }

        for (index, repo) in repos.enumerated() {
            repoQueue.addOperation { [weak self] in
                let status = collectRepo(repo: repo, fetchRemote: fetchRemote, timeout: timeout)
                Task { @MainActor in
                    self?.apply(status: status, at: index, token: token)
                }
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

    /// Apply one repo's freshly collected status. Ignores results from a
    /// superseded refresh, and flips `refreshing` off once the last row lands.
    private func apply(status: RepoStatus, at index: Int, token: Int) {
        guard token == refreshToken, repoStatuses.indices.contains(index) else { return }
        repoStatuses[index] = status
        pendingRepoIndices.remove(index)
        lastUpdated = Self.lastUpdatedFormatter.string(from: Date())
        if pendingRepoIndices.isEmpty {
            refreshing = false
        }
    }

    /// Placeholder row shown while a repo is being collected: the previous
    /// status for the same path when we have one, otherwise a bare entry.
    private func seededStatus(for repo: RepoConfig) -> RepoStatus {
        let derivedName = repo.name ?? (repo.path as NSString).lastPathComponent
        let name = derivedName.isEmpty ? repo.path : derivedName
        if var previous = repoStatuses.first(where: { $0.path == repo.path }) {
            previous.name = name
            return previous
        }
        return RepoStatus(name: name, path: repo.path)
    }

    // ---------------- Repo sync actions (SDD §7.5) ----------------

    /// Run one explicit safe action (Pull / Push / Fetch) on the repo at
    /// `path`: mark the row busy, run the git command off the main thread,
    /// re-collect that repo, then update the row and show a one-line result.
    func repoAction(path: String, action: RepoAction) {
        guard !repoActionBusyPaths.contains(path) else { return }
        guard let repo = config.repos.first(where: { $0.path == path }) else { return }
        let timeout = TimeInterval(config.commandTimeoutSecs)

        repoActionBusyPaths.insert(path)
        repoActionResults.removeValue(forKey: path)

        repoQueue.addOperation { [weak self] in
            let result = runRepoAction(repo: repo, action: action, timeout: timeout)
            // fetchRemote=false: pull/push/fetch already refreshed refs.
            let status = collectRepo(repo: repo, fetchRemote: false, timeout: timeout)
            Task { @MainActor in
                self?.applyAction(result: result, status: status, path: path)
            }
        }
    }

    private func applyAction(result: GitActionResult, status: RepoStatus, path: String) {
        repoActionBusyPaths.remove(path)
        repoActionResults[path] = result
        if let index = repoStatuses.firstIndex(where: { $0.path == path }) {
            repoStatuses[index] = status
            pendingRepoIndices.remove(index)
        }
        lastUpdated = Self.lastUpdatedFormatter.string(from: Date())
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
