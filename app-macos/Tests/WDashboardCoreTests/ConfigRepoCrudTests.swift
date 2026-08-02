// Verifies the "Manage repos" persistence path: add/update/remove must
// round-trip through the TOML file while leaving other sections/comments
// untouched, and `loadConfig` must see the result. Mirrors
// app-linux/tests/config_repo_crud.rs.

import XCTest

@testable import WDashboardCore

final class ConfigRepoCrudTests: XCTestCase {
    private func tempConfigPath(_ name: String) -> String {
        let dir = NSTemporaryDirectory()
        let pid = ProcessInfo.processInfo.processIdentifier
        return dir + "w_dashboard_test_\(name)_\(pid).toml"
    }

    func testAddThenRemoveRepoRoundTripsAndPreservesOtherSections() throws {
        let path = tempConfigPath("add_remove")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try "# a comment that must survive\n[general]\nrefresh_interval_secs = 60\n"
            .write(toFile: path, atomically: true, encoding: .utf8)

        try addRepo(configPath: path, rawPath: "/tmp/some/repo", name: "myrepo")

        var text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("a comment that must survive"), "comment lost:\n\(text)")
        XCTAssertTrue(text.contains("refresh_interval_secs = 60"), "general section lost:\n\(text)")

        var cfg = try loadConfig(path: path)
        XCTAssertEqual(cfg.repos.count, 1)
        XCTAssertEqual(cfg.repos[0].path, "/tmp/some/repo")
        XCTAssertEqual(cfg.repos[0].name, "myrepo")
        XCTAssertEqual(cfg.refreshIntervalSecs, 60)

        try removeRepo(configPath: path, target: "/tmp/some/repo")
        cfg = try loadConfig(path: path)
        XCTAssertEqual(cfg.repos.count, 0, "repo should have been removed")

        text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("a comment that must survive"), "comment lost after remove:\n\(text)")
    }

    func testUpdateRepoChangesPathAndNameInPlace() throws {
        let path = tempConfigPath("update")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try "[[repos]]\npath = \"/tmp/old/path\"\nname = \"old-name\"\n"
            .write(toFile: path, atomically: true, encoding: .utf8)

        try updateRepo(configPath: path, target: "/tmp/old/path", newRawPath: "/tmp/new/path", newName: "new-name")

        let cfg = try loadConfig(path: path)
        XCTAssertEqual(cfg.repos.count, 1, "update must not add a duplicate entry")
        XCTAssertEqual(cfg.repos[0].path, "/tmp/new/path")
        XCTAssertEqual(cfg.repos[0].name, "new-name")
    }

    func testAddRepoCreatesMissingFile() throws {
        let path = tempConfigPath("create_missing")
        try? FileManager.default.removeItem(atPath: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        try addRepo(configPath: path, rawPath: "/tmp/fresh/repo", name: nil)

        let cfg = try loadConfig(path: path)
        XCTAssertEqual(cfg.repos.count, 1)
        XCTAssertEqual(cfg.repos[0].path, "/tmp/fresh/repo")
        XCTAssertNil(cfg.repos[0].name)
    }
}
