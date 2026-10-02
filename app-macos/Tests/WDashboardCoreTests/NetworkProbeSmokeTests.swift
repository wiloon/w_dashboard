// Live smoke test for network probing / speed test (docs/sdd.md §12, §10.1:
// side-effecting collection gets a light e2e check, not vectors). Touches the
// real network, so it only runs with W_DASHBOARD_NET_SMOKE=1.

import XCTest

@testable import WDashboardCore

final class NetworkProbeSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["W_DASHBOARD_NET_SMOKE"] == "1",
            "set W_DASHBOARD_NET_SMOKE=1 to run live network smoke tests")
    }

    func testProbeRoundProducesAResultPerTarget() async {
        let config = NetworkConfig()
        let report = await probeNetwork(config: config, pathAvailable: true)
        print("gateway:", report.gateway.map { "\($0.target) \(String(describing: $0.stats)) \($0.error ?? "")" } ?? "nil")
        for t in report.targets {
            print("target:", t.label, t.method, t.stats.map { "median=\(String(describing: $0.rttMedianMs)) jitter=\(String(describing: $0.jitterMs)) loss=\($0.lossPct)" } ?? "nil", t.error ?? "")
        }
        for g in report.groups { print("group:", g) }
        print("captive:", report.captive, "health:", report.health)
        XCTAssertEqual(report.targets.count, config.targets.count)
        XCTAssertTrue(report.targets.allSatisfy { $0.stats?.sent == config.probeSamples })
    }

    func testSpeedtestShortRun() async {
        var config = NetworkConfig()
        config.speedtestMaxSecs = 3
        config.speedtestMaxMB = 5
        let report = await runSpeedtest(config: config) { print("step:", $0) }
        for item in report.items {
            print("speed:", item.group, item.direction, item.bytes, "bytes", item.elapsedMs, "ms", item.mbps.map { "\($0) Mbps" } ?? "-", item.error ?? "")
        }
        XCTAssertEqual(report.items.count, 4)
        XCTAssertTrue(report.items.allSatisfy { $0.bytes <= 5_000_000 + 1_000_000 })
    }
}
