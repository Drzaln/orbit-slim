import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
    public var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public enum ShellError: LocalizedError {
    case toolNotFound(String)
    case timeout(command: String, seconds: TimeInterval)
    case commandFailed(command: String, status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "\(tool) not found. Install it or add it to your PATH."
        case .timeout(let command, let seconds):
            return "\(command) timed out after \(Int(seconds))s."
        case .commandFailed(let command, let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(command) failed with exit code \(status)."
                : detail
        }
    }
}

public enum Shell {
    public static var homeDirectory: String {
        NSHomeDirectory()
    }

    /// Android SDK lookup mirrors Expo Orbit: env first, then the macOS default.
    public static func androidSDKRoot() -> String? {
        let fm = FileManager.default
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty,
               fm.fileExists(atPath: value) {
                return value
            }
        }
        let fallback = homeDirectory + "/Library/Android/sdk"
        return fm.fileExists(atPath: fallback) ? fallback : nil
    }

    public static var executableSearchPaths: [String] {
        var paths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            homeDirectory + "/.local/bin",
        ]
        if let sdk = androidSDKRoot() {
            paths.append(sdk + "/platform-tools")
            paths.append(sdk + "/emulator")
            paths.append(sdk + "/cmdline-tools/latest/bin")
        }
        return paths
    }

    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = executableSearchPaths.joined(separator: ":")
        return env
    }

    public static func findTool(_ name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for directory in executableSearchPaths {
            let candidate = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public static func requireTool(_ name: String) throws -> String {
        guard let path = findTool(name) else { throw ShellError.toolNotFound(name) }
        return path
    }

    /// Runs a command, capturing stdout/stderr in temp files so large output
    /// can never deadlock on a pipe buffer. Polls asynchronously for timeout.
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 120,
        environment extraEnvironment: [String: String]? = nil
    ) async throws -> CommandResult {
        let resolved: String
        if executable.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                throw ShellError.toolNotFound(executable)
            }
            resolved = executable
        } else {
            resolved = try requireTool(executable)
        }

        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("orbitslim-\(UUID().uuidString)")
        let outURL = base.appendingPathComponent("stdout")
        let errURL = base.appendingPathComponent("stderr")

        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        guard fm.createFile(atPath: outURL.path, contents: nil),
              fm.createFile(atPath: errURL.path, contents: nil) else {
            throw ShellError.commandFailed(command: resolved, status: -1, message: "Could not create temp files")
        }

        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)

        defer {
            try? outHandle.close()
            try? errHandle.close()
            try? fm.removeItem(at: base)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = arguments
        process.environment = extraEnvironment ?? environment
        process.standardOutput = outHandle
        process.standardError = errHandle

        do {
            try process.run()
        } catch {
            throw ShellError.commandFailed(
                command: resolved,
                status: -1,
                message: error.localizedDescription
            )
        }

        let pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 60_000_000)
        }

        if process.isRunning {
            process.terminate()
            try await Task.sleep(nanoseconds: 300_000_000)
            if process.isRunning {
                kill(pid, SIGKILL)
            }
            throw ShellError.timeout(
                command: ([resolved] + arguments).joined(separator: " "),
                seconds: timeout
            )
        }

        try? outHandle.synchronize()
        try? errHandle.synchronize()
        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// Runs a command and throws with its stderr when it exits non-zero.
    @discardableResult
    public static func check(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 120
    ) async throws -> CommandResult {
        let result = try await run(executable, arguments, timeout: timeout)
        guard result.succeeded else {
            let command = ([executable] + arguments).joined(separator: " ")
            throw ShellError.commandFailed(
                command: command,
                status: result.status,
                message: result.combined
            )
        }
        return result
    }
}
