// Subprocess wrapper: PATH resolution + timeout, mirroring
// app-linux/src/git.rs::run_git. Side-effecting — not covered by test
// vectors, only exercised via a live git/chezmoi/etc. binary.

import Foundation

public enum ProcessError: Error, CustomStringConvertible, Sendable {
    case commandNotFound
    case timeout
    case io(String)

    public var description: String {
        switch self {
        case .commandNotFound: return "command not found"
        case .timeout: return "command timed out"
        case .io(let msg): return "command failed: \(msg)"
        }
    }
}

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { exitCode == 0 }
}

/// Resolve `name` against `$PATH`, mirroring the POSIX exec search that
/// Rust's `Command::new` performs. Returns nil if not found (=> "command not
/// found", distinct from a non-zero exit).
func resolveExecutable(_ name: String) -> String? {
    if name.contains("/") {
        return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
    let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in pathVar.split(separator: ":") {
        let candidate = String(dir) + "/" + name
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// Run `executable -C cwd args...` (git/chezmoi style) with a hard timeout,
/// killing the child process if it overruns.
public func runProcess(_ executable: String, args: [String], cwd: String? = nil, timeout: TimeInterval) throws -> ProcessResult {
    guard let resolved = resolveExecutable(executable) else {
        throw ProcessError.commandNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: resolved)
    process.arguments = args
    if let cwd {
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        throw ProcessError.io(error.localizedDescription)
    }

    var stdoutData = Data()
    var stderrData = Data()
    let ioGroup = DispatchGroup()
    ioGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        ioGroup.leave()
    }
    ioGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        ioGroup.leave()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning {
        if Date() > deadline {
            process.terminate()
            process.waitUntilExit()
            _ = ioGroup.wait(timeout: .now() + 2)
            throw ProcessError.timeout
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    process.waitUntilExit()
    ioGroup.wait()

    return ProcessResult(
        exitCode: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}
