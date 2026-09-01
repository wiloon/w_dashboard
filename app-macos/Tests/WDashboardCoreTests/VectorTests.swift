// Contract tests: loads docs/test-vectors/ (the language-agnostic
// consistency gate, see docs/sdd.md §10) and asserts parse/derive results.
// Mirrors app-linux/tests/vectors.rs.

import XCTest

@testable import WDashboardCore

final class VectorTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WDashboardCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app-macos
            .deletingLastPathComponent()  // w_dashboard
    }

    private func vectorFiles(_ subpath: String) throws -> [URL] {
        let dir = repoRoot.appendingPathComponent("docs/test-vectors").appendingPathComponent(subpath)
        let files =
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.path < $1.path }
        XCTAssertFalse(files.isEmpty, "no vectors found in \(dir.path)")
        return files
    }

    func testGitPorcelainVectors() throws {
        struct Expected: Decodable {
            var branch: String?
            var upstream: String?
            var ahead: Int
            var behind: Int
            var staged: Int
            var modified: Int
            var untracked: Int
            var conflicted: Int
        }
        struct Vector: Decodable {
            var input: String
            var expected: Expected
        }

        for file in try vectorFiles("git-porcelain") {
            let data = try Data(contentsOf: file)
            let vector = try JSONDecoder().decode(Vector.self, from: data)
            let parsed = parsePorcelainV2(vector.input)
            let name = file.lastPathComponent
            XCTAssertEqual(parsed.branch, vector.expected.branch, "branch mismatch in \(name)")
            XCTAssertEqual(parsed.upstream, vector.expected.upstream, "upstream mismatch in \(name)")
            XCTAssertEqual(parsed.ahead, vector.expected.ahead, "ahead mismatch in \(name)")
            XCTAssertEqual(parsed.behind, vector.expected.behind, "behind mismatch in \(name)")
            XCTAssertEqual(parsed.staged, vector.expected.staged, "staged mismatch in \(name)")
            XCTAssertEqual(parsed.modified, vector.expected.modified, "modified mismatch in \(name)")
            XCTAssertEqual(parsed.untracked, vector.expected.untracked, "untracked mismatch in \(name)")
            XCTAssertEqual(parsed.conflicted, vector.expected.conflicted, "conflicted mismatch in \(name)")
        }
    }

    func testRepoStateVectors() throws {
        struct Input: Decodable {
            var ahead: Int
            var behind: Int
            var staged: Int
            var modified: Int
            var untracked: Int
            var conflicted: Int
            var has_upstream: Bool
            var error: String?
        }
        struct Vector: Decodable {
            var input: Input
            var expected: String
        }

        func state(from s: String, file: String) -> RepoState? {
            switch s {
            case "Clean": return .clean
            case "Dirty": return .dirty
            case "NeedsPush": return .needsPush
            case "NeedsPull": return .needsPull
            case "Diverged": return .diverged
            case "NoUpstream": return .noUpstream
            case "Error": return .error
            default:
                XCTFail("unknown expected state \(s) in \(file)")
                return nil
            }
        }

        for file in try vectorFiles("repo-state") {
            let data = try Data(contentsOf: file)
            let vector = try JSONDecoder().decode(Vector.self, from: data)
            let input = DeriveInput(
                ahead: vector.input.ahead,
                behind: vector.input.behind,
                staged: vector.input.staged,
                modified: vector.input.modified,
                untracked: vector.input.untracked,
                conflicted: vector.input.conflicted,
                hasUpstream: vector.input.has_upstream,
                error: vector.input.error
            )
            guard let expected = state(from: vector.expected, file: file.lastPathComponent) else { continue }
            XCTAssertEqual(deriveState(input), expected, "state mismatch in \(file.lastPathComponent)")
        }
    }

    func testRepoActionsVectors() throws {
        struct Expected: Decodable {
            var pull: Bool
            var push: Bool
            var fetch: Bool
        }
        struct Vector: Decodable {
            var input: String
            var expected: Expected
        }

        func state(from s: String, file: String) -> RepoState? {
            switch s {
            case "Clean": return .clean
            case "Dirty": return .dirty
            case "NeedsPush": return .needsPush
            case "NeedsPull": return .needsPull
            case "Diverged": return .diverged
            case "NoUpstream": return .noUpstream
            case "Error": return .error
            default:
                XCTFail("unknown state \(s) in \(file)")
                return nil
            }
        }

        for file in try vectorFiles("repo-actions") {
            let data = try Data(contentsOf: file)
            let vector = try JSONDecoder().decode(Vector.self, from: data)
            guard let st = state(from: vector.input, file: file.lastPathComponent) else { continue }
            let actions = allowedActions(st)
            let name = file.lastPathComponent
            XCTAssertEqual(actions.pull, vector.expected.pull, "pull mismatch in \(name)")
            XCTAssertEqual(actions.push, vector.expected.push, "push mismatch in \(name)")
            XCTAssertEqual(actions.fetch, vector.expected.fetch, "fetch mismatch in \(name)")
        }
    }

    func testWmoCodesVectors() throws {
        let file = repoRoot.appendingPathComponent("docs/test-vectors/wmo-codes/mapping.json")
        let data = try Data(contentsOf: file)
        let mapping = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertFalse(mapping.isEmpty, "no wmo-codes entries in \(file.path)")

        for (codeStr, expectedDesc) in mapping {
            guard let code = Int(codeStr) else {
                XCTFail("bad code \(codeStr)")
                continue
            }
            XCTAssertEqual(wmoDescription(code), expectedDesc, "wmo code \(code) mismatch")
        }
    }

    func testWeatherJSONVectors() throws {
        for file in try vectorFiles("weather-json") {
            let name = file.lastPathComponent
            let data = try Data(contentsOf: file)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("bad vector \(name)")
                continue
            }
            let locationLabel = root["location_label"] as? String ?? ""
            let temperatureUnit = root["temperature_unit"] as? String ?? ""
            let fetchedAt = Int64(root["fetched_at"] as? Int ?? 0)
            let input = root["input"] as Any
            let expectedAny = root["expected"]

            let result = Result {
                try parseForecastJSON(input, locationLabel: locationLabel, temperatureUnit: temperatureUnit, fetchedAt: fetchedAt)
            }

            if expectedAny == nil || expectedAny is NSNull {
                if case .success(let report) = result {
                    XCTFail("expected parse error in \(name), got \(report)")
                }
                continue
            }

            guard let expected = expectedAny as? [String: Any] else {
                XCTFail("bad expected in \(name)")
                continue
            }

            switch result {
            case .failure(let error):
                XCTFail("\(name): unexpected error \(error)")
            case .success(let report):
                XCTAssertEqual(report.locationLabel, expected["location_label"] as? String, "location_label mismatch in \(name)")
                XCTAssertEqual(report.latitude, expected["latitude"] as? Double ?? .nan, "latitude mismatch in \(name)")
                XCTAssertEqual(report.longitude, expected["longitude"] as? Double ?? .nan, "longitude mismatch in \(name)")
                XCTAssertEqual(report.fetchedAt, Int64(expected["fetched_at"] as? Int ?? -1), "fetched_at mismatch in \(name)")
                XCTAssertEqual(report.temperatureUnit, expected["temperature_unit"] as? String, "temperature_unit mismatch in \(name)")

                guard let expectedCurrent = expected["current"] as? [String: Any] else {
                    XCTFail("missing expected.current in \(name)")
                    continue
                }
                XCTAssertEqual(report.current.temperature, expectedCurrent["temperature"] as? Double ?? .nan, "current.temperature mismatch in \(name)")
                XCTAssertEqual(report.current.weatherCode, expectedCurrent["weather_code"] as? Int ?? Int.min, "current.weather_code mismatch in \(name)")
                XCTAssertEqual(report.current.description, expectedCurrent["description"] as? String, "current.description mismatch in \(name)")

                let expectedDaily = (expected["daily"] as? [Any]) ?? []
                XCTAssertEqual(report.daily.count, expectedDaily.count, "daily length mismatch in \(name)")
                for (day, expectedDayAny) in zip(report.daily, expectedDaily) {
                    guard let expectedDay = expectedDayAny as? [String: Any] else { continue }
                    XCTAssertEqual(day.date, expectedDay["date"] as? String, "day.date mismatch in \(name)")
                    XCTAssertEqual(day.tempMax, expectedDay["temp_max"] as? Double ?? .nan, "day.temp_max mismatch in \(name)")
                    XCTAssertEqual(day.tempMin, expectedDay["temp_min"] as? Double ?? .nan, "day.temp_min mismatch in \(name)")
                    XCTAssertEqual(day.weatherCode, expectedDay["weather_code"] as? Int ?? Int.min, "day.weather_code mismatch in \(name)")
                    XCTAssertEqual(day.description, expectedDay["description"] as? String, "day.description mismatch in \(name)")
                    XCTAssertEqual(
                        day.precipitationProbabilityMax, expectedDay["precipitation_probability_max"] as? Int,
                        "day.precipitation_probability_max mismatch in \(name)"
                    )
                }
            }
        }
    }
}
