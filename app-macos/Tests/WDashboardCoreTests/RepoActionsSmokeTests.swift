// e2e smoke for the three explicit sync actions (docs/sdd.md §7.5, ADR-011).
// Builds throwaway local repos (a bare "remote" + two clones), drives them
// into NeedsPull / NeedsPush / Diverged, and checks `runRepoAction`.
// Mirrors app-linux/tests/repo_actions_smoke.rs.

import XCTest

@testable import WDashboardCore

final class RepoActionsSmokeTests: XCTestCase {
    private let timeout: TimeInterval = 20

    private func git(_ dir: String, _ args: [String], file: StaticString = #filePath, line: UInt = #line) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir] + args
        p.environment = [
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("git \(args) failed: \(msg)", file: file, line: line)
        }
    }

    private func work(_ name: String) -> String {
        let dir = NSTemporaryDirectory() + "w_dashboard_actions_\(name)_\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func commitFile(_ dir: String, _ file: String, _ contents: String) {
        try? contents.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        git(dir, ["add", "."])
        git(dir, ["commit", "-m", file])
    }

    private func headOf(_ dir: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir, "rev-parse", "HEAD"]
        p.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Returns (root, up, work). `up` seeds one commit on `main`; `work` is the
    /// repo under test.
    private func scaffold(_ name: String) -> (String, String, String) {
        let root = work(name)
        let remote = root + "/remote.git"
        let up = root + "/up"
        let workDir = root + "/work"

        git(root, ["init", "--bare", "-b", "main", remote])
        git(root, ["clone", remote, up])
        git(up, ["symbolic-ref", "HEAD", "refs/heads/main"])
        commitFile(up, "a.txt", "1")
        git(up, ["push", "-u", "origin", "main"])
        git(root, ["clone", remote, workDir])
        return (root, up, workDir)
    }

    func testPullFastForwardClearsBehind() throws {
        let (root, up, workDir) = scaffold("pull")
        defer { try? FileManager.default.removeItem(atPath: root) }

        commitFile(up, "b.txt", "2")
        git(up, ["push"])

        let repo = RepoConfig(path: workDir, name: nil)
        let before = collectRepo(repo: repo, fetchRemote: true, timeout: timeout)
        XCTAssertEqual(before.state, .needsPull, "expected NeedsPull, got \(before)")

        let result = runRepoAction(repo: repo, action: .pull, timeout: timeout)
        XCTAssertTrue(result.ok, "pull should succeed: \(result)")

        let after = collectRepo(repo: repo, fetchRemote: false, timeout: timeout)
        XCTAssertEqual(after.state, .clean, "expected Clean after pull, got \(after)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workDir + "/b.txt"))
    }

    func testPushClearsAhead() throws {
        let (root, _, workDir) = scaffold("push")
        defer { try? FileManager.default.removeItem(atPath: root) }

        commitFile(workDir, "local.txt", "local")
        let repo = RepoConfig(path: workDir, name: nil)
        let before = collectRepo(repo: repo, fetchRemote: true, timeout: timeout)
        XCTAssertEqual(before.state, .needsPush, "expected NeedsPush, got \(before)")

        let result = runRepoAction(repo: repo, action: .push, timeout: timeout)
        XCTAssertTrue(result.ok, "push should succeed: \(result)")

        let after = collectRepo(repo: repo, fetchRemote: false, timeout: timeout)
        XCTAssertEqual(after.state, .clean, "expected Clean after push, got \(after)")
    }

    func testPullFfOnlyFailsCleanlyWhenDiverged() throws {
        let (root, up, workDir) = scaffold("diverged")
        defer { try? FileManager.default.removeItem(atPath: root) }

        commitFile(up, "b.txt", "remote")
        git(up, ["push"])
        commitFile(workDir, "c.txt", "local")

        let repo = RepoConfig(path: workDir, name: nil)
        let before = collectRepo(repo: repo, fetchRemote: true, timeout: timeout)
        XCTAssertEqual(before.state, .diverged, "expected Diverged, got \(before)")
        let headBefore = headOf(workDir)

        let result = runRepoAction(repo: repo, action: .pull, timeout: timeout)
        XCTAssertFalse(result.ok, "ff-only pull must fail on divergence: \(result)")
        XCTAssertNotNil(result.error)
        XCTAssertEqual(headBefore, headOf(workDir), "HEAD must not move on failed ff-only pull")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir + "/b.txt"), "work tree untouched")
    }
}
