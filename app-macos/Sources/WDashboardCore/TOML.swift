// Minimal, hand-rolled TOML support covering only the subset of syntax used
// by config.example.toml (docs/sdd.md §4): `[section]` tables, `[[array]]`
// array-of-tables, and `key = value` with string/int/float/bool values plus
// `#` comments. This is not a general-purpose TOML implementation.
//
// Two capabilities are provided:
//  - `parseTOML`: read the whole document into a `TOMLDocument`.
//  - `TOMLRepoEditor`: text-level add/remove/update of `[[repos]]` blocks
//    that leaves every other line (including comments and other sections)
//    byte-for-byte untouched. This mirrors the "preserve everything else"
//    behavior `app-linux/src/config.rs` gets from the `toml_edit` crate.

import Foundation

public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

public enum TOMLError: Error, CustomStringConvertible, Sendable {
    case parse(String)

    public var description: String {
        switch self {
        case .parse(let msg): return msg
        }
    }
}

public struct TOMLDocument: Sendable {
    public var general: [String: TOMLValue] = [:]
    public var repos: [[String: TOMLValue]] = []
    public var clocks: [[String: TOMLValue]] = []
    public var weather: [String: TOMLValue]?
    public var chezmoi: [String: TOMLValue]?
}

/// Strip a trailing `# ...` comment that is not inside a quoted string.
private func stripComment(_ line: String) -> String {
    var inString = false
    var escaped = false
    var result = ""
    for ch in line {
        if inString {
            result.append(ch)
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString = false
            }
            continue
        }
        if ch == "\"" {
            inString = true
            result.append(ch)
            continue
        }
        if ch == "#" {
            break
        }
        result.append(ch)
    }
    return result
}

private func parseValue(_ raw: String) throws -> TOMLValue {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("\"") {
        guard s.hasSuffix("\""), s.count >= 2 else {
            throw TOMLError.parse("unterminated string: \(raw)")
        }
        let inner = String(s.dropFirst().dropLast())
        var out = ""
        let chars = Array(inner)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                switch next {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(next)
                }
                i += 2
            } else {
                out.append(c)
                i += 1
            }
        }
        return .string(out)
    }
    if s == "true" { return .bool(true) }
    if s == "false" { return .bool(false) }
    if let i = Int(s) { return .int(i) }
    if let d = Double(s) { return .double(d) }
    throw TOMLError.parse("unrecognized value: \(raw)")
}

private func splitKeyValue(_ line: String) throws -> (String, String) {
    guard let eq = line.firstIndex(of: "=") else {
        throw TOMLError.parse("expected `key = value`, got: \(line)")
    }
    let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
    let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else {
        throw TOMLError.parse("empty key in: \(line)")
    }
    return (key, String(value))
}

public func parseTOML(_ text: String) throws -> TOMLDocument {
    var doc = TOMLDocument()

    enum Target {
        case none
        case general
        case chezmoi
        case weather
        case reposArray
        case clocksArray
        case unknownTable
        case unknownArray
    }

    var target: Target = .none

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let stripped = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty {
            continue
        }
        if stripped.hasPrefix("[[") && stripped.hasSuffix("]]") {
            let name = stripped.dropFirst(2).dropFirst(0).dropLast(2).trimmingCharacters(in: .whitespaces)
            switch name {
            case "repos":
                doc.repos.append([:])
                target = .reposArray
            case "clocks":
                doc.clocks.append([:])
                target = .clocksArray
            default:
                target = .unknownArray
            }
            continue
        }
        if stripped.hasPrefix("[") && stripped.hasSuffix("]") {
            let name = stripped.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            switch name {
            case "general":
                target = .general
            case "chezmoi":
                doc.chezmoi = doc.chezmoi ?? [:]
                target = .chezmoi
            case "weather":
                doc.weather = doc.weather ?? [:]
                target = .weather
            default:
                target = .unknownTable
            }
            continue
        }

        let (key, rawValue) = try splitKeyValue(stripped)
        let value = try parseValue(rawValue)
        switch target {
        case .general:
            doc.general[key] = value
        case .chezmoi:
            doc.chezmoi?[key] = value
        case .weather:
            doc.weather?[key] = value
        case .reposArray:
            guard !doc.repos.isEmpty else { break }
            doc.repos[doc.repos.count - 1][key] = value
        case .clocksArray:
            guard !doc.clocks.isEmpty else { break }
            doc.clocks[doc.clocks.count - 1][key] = value
        case .none, .unknownTable, .unknownArray:
            break
        }
    }

    return doc
}

/// Text-level editing of `[[repos]]` blocks. Every other line in the file is
/// left untouched, matching the "preserve other sections/comments" contract
/// verified by `Tests/WDashboardCoreTests/ConfigRepoCrudTests.swift`.
public enum TOMLRepoEditor {
    private struct Block {
        var headerLineIndex: Int
        var endLineIndexExclusive: Int
        var path: String?
        var name: String?
    }

    private static func isHeaderLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("[")
    }

    private static func findRepoBlocks(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let trimmed = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            if trimmed == "[[repos]]" {
                let start = i
                var j = i + 1
                var path: String?
                var name: String?
                while j < lines.count {
                    let inner = stripComment(lines[j]).trimmingCharacters(in: .whitespaces)
                    if inner.isEmpty {
                        j += 1
                        continue
                    }
                    if isHeaderLine(inner) {
                        break
                    }
                    if let (key, rawValue) = try? splitKeyValue(inner), let value = try? parseValue(rawValue) {
                        if key == "path" { path = value.stringValue }
                        if key == "name" { name = value.stringValue }
                    }
                    j += 1
                }
                blocks.append(Block(headerLineIndex: start, endLineIndexExclusive: j, path: path, name: name))
                i = j
            } else {
                i += 1
            }
        }
        return blocks
    }

    private static func matches(_ block: Block, target: String, expand: (String) -> String) -> Bool {
        guard let path = block.path else { return false }
        return expand(path) == target
    }

    public static func add(text: String, rawPath: String, name: String?) -> String {
        var body = text
        if !body.isEmpty && !body.hasSuffix("\n") {
            body += "\n"
        }
        body += "[[repos]]\n"
        body += "path = \(quote(rawPath))\n"
        if let name, !name.isEmpty {
            body += "name = \(quote(name))\n"
        }
        return body
    }

    public static func remove(text: String, target: String, expand: (String) -> String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let blocks = findRepoBlocks(lines)
        guard let block = blocks.first(where: { matches($0, target: target, expand: expand) }) else {
            return text
        }
        lines.removeSubrange(block.headerLineIndex..<block.endLineIndexExclusive)
        return lines.joined(separator: "\n")
    }

    public static func update(text: String, target: String, newRawPath: String, newName: String?, expand: (String) -> String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let blocks = findRepoBlocks(lines)
        guard let block = blocks.first(where: { matches($0, target: target, expand: expand) }) else {
            return text
        }

        var newBlockLines: [String] = ["[[repos]]", "path = \(quote(newRawPath))"]
        if let newName, !newName.isEmpty {
            newBlockLines.append("name = \(quote(newName))")
        }
        lines.replaceSubrange(block.headerLineIndex..<block.endLineIndexExclusive, with: newBlockLines)
        return lines.joined(separator: "\n")
    }

    private static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
