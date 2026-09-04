// `[pomodoro]` config section (docs/sdd.md §4 / §11, ADR-012):
// absent -> defaults; present -> parsed; non-positive durations -> error.
// Mirrors app-linux/tests/config_pomodoro.rs.

import XCTest

@testable import WDashboardCore

final class ConfigPomodoroTests: XCTestCase {
    private func tempConfigPath(_ name: String) -> String {
        NSTemporaryDirectory() + "w_dashboard_pomo_\(name)_\(ProcessInfo.processInfo.processIdentifier).toml"
    }

    private func write(_ path: String, _ contents: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        // best-effort cleanup
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [] where f.hasPrefix("w_dashboard_pomo_") {
            try? fm.removeItem(atPath: NSTemporaryDirectory() + f)
        }
    }

    func testAbsentSectionUsesDefaults() throws {
        let path = tempConfigPath("absent")
        try write(path, "[general]\nrefresh_interval_secs = 60\n")

        let cfg = try loadConfig(path: path)
        XCTAssertTrue(cfg.pomodoro.enabled)
        XCTAssertEqual(cfg.pomodoro.focusMinutes, 25)
        XCTAssertEqual(cfg.pomodoro.breakMinutes, 5)
        XCTAssertTrue(cfg.pomodoro.notify)
        XCTAssertTrue(cfg.pomodoro.sound)
    }

    func testFullSectionIsParsed() throws {
        let path = tempConfigPath("full")
        try write(
            path,
            "[pomodoro]\nenabled = false\nfocus_minutes = 50\nbreak_minutes = 10\nnotify = false\nsound = false\n")

        let cfg = try loadConfig(path: path)
        XCTAssertFalse(cfg.pomodoro.enabled)
        XCTAssertEqual(cfg.pomodoro.focusMinutes, 50)
        XCTAssertEqual(cfg.pomodoro.breakMinutes, 10)
        XCTAssertFalse(cfg.pomodoro.notify)
        XCTAssertFalse(cfg.pomodoro.sound)
    }

    func testPartialSectionFillsMissingWithDefaults() throws {
        let path = tempConfigPath("partial")
        try write(path, "[pomodoro]\nfocus_minutes = 30\n")

        let cfg = try loadConfig(path: path)
        XCTAssertTrue(cfg.pomodoro.enabled)
        XCTAssertEqual(cfg.pomodoro.focusMinutes, 30)
        XCTAssertEqual(cfg.pomodoro.breakMinutes, 5)
    }

    func testZeroFocusMinutesIsAnError() throws {
        let path = tempConfigPath("zero_focus")
        try write(path, "[pomodoro]\nfocus_minutes = 0\n")

        XCTAssertThrowsError(try loadConfig(path: path)) { error in
            guard case ConfigError.parse(let msg) = error else {
                return XCTFail("expected ConfigError.parse, got \(error)")
            }
            XCTAssertTrue(msg.contains("focus_minutes"), "message should name the field: \(msg)")
        }
    }

    func testNegativeBreakMinutesIsAnError() throws {
        let path = tempConfigPath("neg_break")
        try write(path, "[pomodoro]\nbreak_minutes = -3\n")

        XCTAssertThrowsError(try loadConfig(path: path)) { error in
            guard case ConfigError.parse = error else {
                return XCTFail("expected ConfigError.parse, got \(error)")
            }
        }
    }
}
