// `[network]` + `[[network_targets]]` config (docs/sdd.md §4 / §12.2, ADR-014):
// absent -> defaults (5 built-in targets); any target written -> config list
// replaces the defaults; bad group/method/fields/ranges -> error.

import XCTest

@testable import WDashboardCore

final class ConfigNetworkTests: XCTestCase {
    private func tempConfigPath(_ name: String) -> String {
        NSTemporaryDirectory() + "w_dashboard_net_\(name)_\(ProcessInfo.processInfo.processIdentifier).toml"
    }

    private func load(_ name: String, _ contents: String) throws -> Config {
        let path = tempConfigPath(name)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return try loadConfig(path: path)
    }

    private func assertParseError(_ name: String, _ contents: String, mentions field: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try load(name, contents), file: file, line: line) { error in
            XCTAssertTrue("\(error)".contains(field), "error \"\(error)\" should mention \(field)", file: file, line: line)
        }
    }

    override func tearDown() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [] where f.hasPrefix("w_dashboard_net_") {
            try? fm.removeItem(atPath: NSTemporaryDirectory() + f)
        }
    }

    func testAbsentSectionUsesDefaults() throws {
        let cfg = try load("absent", "[general]\nrefresh_interval_secs = 60\n")
        XCTAssertEqual(cfg.network, NetworkConfig())
        XCTAssertTrue(cfg.network.enabled)
        XCTAssertEqual(cfg.network.probeIntervalSecs, 60)
        XCTAssertEqual(cfg.network.probeSamples, 10)
        XCTAssertEqual(cfg.network.targets.count, 5)
        XCTAssertEqual(cfg.network.targets.last, NetworkTarget(label: "Home", group: .home, method: .tcp, host: "home.wiloon.com", port: 443))
    }

    func testSectionAndCustomTargetsReplaceDefaults() throws {
        let cfg = try load(
            "custom",
            """
            [network]
            enabled = false
            probe_interval_secs = 0
            probe_samples = 5
            speedtest_max_mb = 10
            speedtest_overseas_upload_url = "https://example.com/up"

            [[network_targets]]
            label = "Router"
            group = "home"
            method = "tcp"
            host = "192.168.1.1"
            port = 80

            [[network_targets]]
            label = "Example"
            group = "overseas"
            url = "https://example.com/"
            """)
        XCTAssertFalse(cfg.network.enabled)
        XCTAssertEqual(cfg.network.probeIntervalSecs, 0)
        XCTAssertEqual(cfg.network.probeSamples, 5)
        XCTAssertEqual(cfg.network.speedtestMaxMB, 10)
        XCTAssertEqual(cfg.network.speedtestOverseasUploadURL, "https://example.com/up")
        XCTAssertEqual(cfg.network.speedtestMaxSecs, 8)
        XCTAssertEqual(
            cfg.network.targets,
            [
                NetworkTarget(label: "Router", group: .home, method: .tcp, host: "192.168.1.1", port: 80),
                NetworkTarget(label: "Example", group: .overseas, method: .http, url: "https://example.com/"),
            ])
    }

    func testUnknownGroupIsError() {
        assertParseError("group", "[[network_targets]]\nlabel = \"x\"\ngroup = \"mars\"\nurl = \"https://a/\"\n", mentions: "network_targets[0].group")
    }

    func testUnknownMethodIsError() {
        assertParseError("method", "[[network_targets]]\nlabel = \"x\"\ngroup = \"home\"\nmethod = \"udp\"\n", mentions: "network_targets[0].method")
    }

    func testHttpWithoutURLIsError() {
        assertParseError("nourl", "[[network_targets]]\nlabel = \"x\"\ngroup = \"domestic\"\n", mentions: "network_targets[0].url")
    }

    func testTcpWithoutPortIsError() {
        assertParseError("noport", "[[network_targets]]\nlabel = \"x\"\ngroup = \"home\"\nmethod = \"tcp\"\nhost = \"h\"\n", mentions: "network_targets[0].port")
    }

    func testOutOfRangeSamplesIsError() {
        assertParseError("samples", "[network]\nprobe_samples = 0\n", mentions: "network.probe_samples")
    }

    func testOutOfRangeTimeoutIsError() {
        assertParseError("timeout", "[network]\nprobe_timeout_ms = 50000\n", mentions: "network.probe_timeout_ms")
    }
}
