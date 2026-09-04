// UI-facing state and refresh orchestration. Mirrors the responsibilities
// of app-linux/src/main.rs (spawn_collect_repos / spawn_collect_weather /
// reload_and_refresh / timers), adapted to SwiftUI's async/await instead of
// mpsc channels + a polling Slint timer.
//
// Repo collection is incremental (docs/sdd.md §8), like app-linux's worker
// pool: repos are collected a few at a time and each row updates as soon as
// its own result lands, instead of the whole list being replaced at the end.

import AppKit
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
    /// Repo paths whose single-row manual refresh is running (docs/sdd.md §8.1).
    /// Those rows disable every button and show a progress label.
    @Published private(set) var repoRowRefreshingPaths: Set<String> = []
    /// Last action result per repo path, shown inline until the next full
    /// refresh clears it.
    @Published private(set) var repoActionResults: [String: GitActionResult] = [:]
    @Published var lastUpdated: String = "never"
    @Published var repoFormError: String = ""
    @Published var configLoadError: String?

    // ---------------- Pomodoro (docs/sdd.md §11, ADR-012) ----------------
    /// Display data for the panel, recomputed every tick. `pomodoroState` (the
    /// authoritative in-memory state, never persisted) stays private.
    @Published private(set) var pomodoro: PomodoroView =
        PomodoroView(phase: .idle, remainingSecs: 0, elapsedSecs: 0, overtimeSecs: 0, progress: 0, alerting: false)
    private var pomodoroState: PomodoroState = .idle(focusSecs: 1500, breakSecs: 300)
    private var pomodoroTickTask: Task<Void, Never>?

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
        pomodoroState = PomodoroState.idle(
            focusSecs: Int64(config.pomodoro.focusMinutes) * 60,
            breakSecs: Int64(config.pomodoro.breakMinutes) * 60)
        pomodoro = pomodoroView(pomodoroState, now: Self.nowUnix())
    }

    /// Called once from `ContentView.onAppear`. Kicks off the first
    /// collection plus the clock/auto-refresh timers.
    func start() {
        guard !started else { return }
        started = true
        refresh()
        startClockTimer()
        startAutoRefreshTimer()
        startPomodoroTimer()
    }

    // ---------------- Pomodoro ----------------

    /// Notified on every phase change so it can drive the menu-bar icon
    /// (docs/sdd.md §11.4 step 3). Set by the App layer.
    var onPomodoroPhaseChange: ((PomodoroPhase) -> Void)?

    /// Apply one pomodoro event (panel button or, later, a menu item): reduce,
    /// recompute the view, and notify the icon.
    func pomodoroEvent(_ event: PomodoroEvent) {
        applyPomodoro(event: event, now: Self.nowUnix())
    }

    private func startPomodoroTimer() {
        pomodoroTickTask?.cancel()
        guard config.pomodoro.enabled else { return }
        pomodoroTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.applyPomodoro(event: .tick, now: Self.nowUnix())
            }
        }
    }

    private func applyPomodoro(event: PomodoroEvent, now: Int64) {
        let previousPhase = pomodoroState.phase
        pomodoroState = pomodoroReduce(pomodoroState, event, now: now)
        pomodoro = pomodoroView(pomodoroState, now: now)

        let newPhase = pomodoroState.phase
        guard newPhase != previousPhase else { return }

        onPomodoroPhaseChange?(newPhase)

        if newPhase == .focusEnded || newPhase == .breakEnded {
            Self.fireAlert(
                phase: newPhase,
                notify: config.pomodoro.notify,
                sound: config.pomodoro.sound)
        }
    }

    /// Phase-edge side effects (docs/sdd.md §11.4 step 4): one notification, plus
    /// a sound only on `focusEnded`. Best-effort — failures are ignored (SDD §2).
    private static func fireAlert(phase: PomodoroPhase, notify: Bool, sound: Bool) {
        if notify {
            let body =
                phase == .focusEnded
                ? "Focus session done — time to get up and move."
                : "Break's over — ready to focus?"
            let script = "display notification \"\(body)\" with title \"w_dashboard\""
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            try? task.run()
        }
        if sound, phase == .focusEnded {
            NSSound(named: "Glass")?.play()
        }
    }

    private static func nowUnix() -> Int64 {
        Int64(Date().timeIntervalSince1970)
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
        repoRowRefreshingPaths.removeAll()
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

    /// Per-row manual refresh (docs/sdd.md §8, §8.1 "定向单行采集"): re-collect
    /// just this repo with the same params a full refresh uses (honouring
    /// `fetchRemote`), with no git write and no new generation token. Clears any
    /// prior action result on the row.
    func refreshRepoRow(path: String) {
        guard !repoRowRefreshingPaths.contains(path), !repoActionBusyPaths.contains(path) else { return }
        guard let repo = config.repos.first(where: { $0.path == path }) else { return }
        let fetchRemote = config.fetchRemote
        let timeout = TimeInterval(config.commandTimeoutSecs)

        repoRowRefreshingPaths.insert(path)
        repoActionResults.removeValue(forKey: path)

        repoQueue.addOperation { [weak self] in
            let status = collectRepo(repo: repo, fetchRemote: fetchRemote, timeout: timeout)
            Task { @MainActor in
                self?.applyRowRefresh(status: status, path: path)
            }
        }
    }

    private func applyRowRefresh(status: RepoStatus, path: String) {
        repoRowRefreshingPaths.remove(path)
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
