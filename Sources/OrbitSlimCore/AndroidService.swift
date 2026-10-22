import Foundation

public enum AndroidService {
    public static var sdkRoot: String? { Shell.androidSDKRoot() }

    public static var emulatorPath: String? {
        if let sdk = sdkRoot {
            let candidate = sdk + "/emulator/emulator"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return Shell.findTool("emulator")
    }

    public static var adbPath: String? {
        Shell.findTool("adb")
    }

    public static var avdslimInstalled: Bool {
        Shell.findTool("avdslim") != nil
    }

    // MARK: - Discovery

    public static func listAVDs() async -> [String] {
        guard let emulator = emulatorPath else { return [] }
        guard let result = try? await Shell.run(emulator, ["-list-avds"], timeout: 30),
              result.succeeded else {
            return []
        }
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
    }

    /// Maps AVD name -> adb serial for every running emulator.
    public static func runningEmulators() async -> [String: String] {
        guard let adb = adbPath else { return [:] }
        guard let result = try? await Shell.run(adb, ["devices"], timeout: 20),
              result.succeeded else {
            return [:]
        }

        let serials = result.stdout
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line -> String? in
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2, parts[0].hasPrefix("emulator-") else { return nil }
                return String(parts[0])
            }

        var mapping: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for serial in serials {
                group.addTask {
                    let reply = try? await Shell.run(adb, ["-s", serial, "emu", "avd", "name"], timeout: 10)
                    guard let stdout = reply?.stdout else { return (serial, nil) }
                    let name = stdout
                        .replacingOccurrences(of: "\r\n", with: "\n")
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty && $0 != "OK" }
                    return (serial, name)
                }
            }
            for await (serial, name) in group {
                if let name { mapping[name] = serial }
            }
        }
        return mapping
    }

    /// qemu host RSS in MB, keyed by AVD name.
    public static func hostMemoryByAVD() async -> [String: Int] {
        guard let result = try? await Shell.run(
            "/bin/ps",
            ["-axo", "pid=,rss=,command="],
            timeout: 20
        ), result.succeeded else {
            return [:]
        }

        var memory: [String: Int] = [:]
        for line in result.stdout.split(separator: "\n") {
            guard line.contains("qemu-system") else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count > 2 else { continue }
            guard let rssKB = Int(tokens[1]) else { continue }

            var avd: String?
            for index in 0..<(tokens.count - 1) where tokens[index] == "-avd" {
                avd = String(tokens[index + 1])
                break
            }
            if avd == nil {
                for token in tokens where token.hasPrefix("@") {
                    avd = String(token.dropFirst())
                    break
                }
            }
            if let avd {
                memory[avd] = rssKB / 1024
            }
        }
        return memory
    }

    public static func snapshot() async -> [AndroidDevice] {
        let avds = await listAVDs()
        guard !avds.isEmpty else { return [] }

        async let runningTask = runningEmulators()
        async let memoryTask = hostMemoryByAVD()
        let (running, memory) = await (runningTask, memoryTask)

        var devices: [AndroidDevice] = []
        await withTaskGroup(of: (String, String?, Int?, SlimState).self) { group in
            for avd in avds {
                let serial = running[avd]
                let mem = memory[avd]
                group.addTask {
                    let slim: SlimState
                    if let serial {
                        slim = await slimState(serial: serial)
                    } else {
                        slim = .unknown
                    }
                    return (avd, serial, mem, slim)
                }
            }
            for await (avd, serial, mem, slim) in group {
                devices.append(AndroidDevice(
                    avdName: avd,
                    serial: serial,
                    memoryMB: mem,
                    slim: slim
                ))
            }
        }

        devices.sort {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.avdName.localizedStandardCompare($1.avdName) == .orderedAscending
        }
        return devices
    }

    /// avdslim disables 45+ packages; stock images expose only a few disabled
    /// system packages. 20 is a safe dividing line between the two.
    public static func slimState(serial: String) async -> SlimState {
        guard let adb = adbPath else { return .unknown }
        guard let result = try? await Shell.run(
            adb,
            ["-s", serial, "shell", "pm", "list", "packages", "-d"],
            timeout: 30
        ), result.succeeded else {
            return .unknown
        }
        let count = result.stdout
            .split(separator: "\n")
            .filter { $0.hasPrefix("package:") }
            .count
        if count >= 20 { return .slim }
        if count > 0 { return .partial(disabled: count, total: 0) }
        return .stock
    }

    // MARK: - Lifecycle

    /// Launch through avdslim when present so `-lowram`, `-memory`, GPU host,
    /// guest debloating and the golden snapshot all apply. Falls back to the
    /// stock emulator with equivalent flags.
    public static func start(avd: String) async throws -> URL? {
        let arguments: [String]
        let executable: String
        if let avdslim = Shell.findTool("avdslim") {
            executable = avdslim
            arguments = ["start", avd]
        } else if let emulator = emulatorPath {
            executable = emulator
            arguments = [
                "@\(avd)",
                "-memory", "1536",
                "-lowram",
                "-gpu", "host",
                "-no-audio",
            ]
        } else {
            throw ShellError.toolNotFound("emulator")
        }

        return try spawnDetached(
            executable: executable,
            arguments: arguments,
            logName: "avd-\(avd).log"
        )
    }

    public static func waitForRunning(
        avd: String,
        timeout: TimeInterval = 300,
        logURL: URL? = nil
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let running = await runningEmulators()
            if let serial = running[avd], await isBootCompleted(serial: serial) {
                return serial
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        var message = "Timed out waiting for \(avd) to boot."
        if let logURL, let tail = logTail(at: logURL) {
            message += "\n\nLast log lines:\n\(tail)"
        }
        throw ShellError.commandFailed(command: "avd \(avd)", status: -1, message: message)
    }

    public static func shutdown(serial: String) async throws {
        guard let adb = adbPath else { throw ShellError.toolNotFound("adb") }
        try await Shell.check(adb, ["-s", serial, "emu", "kill"], timeout: 45)
    }

    public static func isBootCompleted(serial: String) async -> Bool {
        guard let adb = adbPath else { return false }
        guard let result = try? await Shell.run(
            adb,
            ["-s", serial, "shell", "getprop", "sys.boot_completed"],
            timeout: 15
        ), result.succeeded else {
            return false
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    public static func slimNow(serial: String) async throws {
        guard avdslimInstalled else { throw ShellError.toolNotFound("avdslim") }
        try await Shell.check("avdslim", ["on", serial], timeout: 300)
    }

    public static func restoreStock(serial: String) async throws {
        guard avdslimInstalled else { throw ShellError.toolNotFound("avdslim") }
        try await Shell.check("avdslim", ["off", serial], timeout: 300)
    }

    // MARK: - Install / launch

    public static func install(apkAt url: URL, serial: String) async throws {
        guard url.pathExtension.lowercased() == "apk" else {
            throw ShellError.commandFailed(
                command: "adb install",
                status: -1,
                message: "\(url.lastPathComponent) is not an .apk file."
            )
        }
        guard let adb = adbPath else { throw ShellError.toolNotFound("adb") }
        let result = try await Shell.run(
            adb,
            ["-s", serial, "install", "-r", url.path],
            timeout: 300
        )
        guard result.succeeded,
              !result.combined.localizedCaseInsensitiveContains("Failure") else {
            throw ShellError.commandFailed(
                command: "adb install \(url.lastPathComponent)",
                status: result.status,
                message: result.combined
            )
        }
    }

    public static func launch(package: String, serial: String) async throws {
        guard let adb = adbPath else { throw ShellError.toolNotFound("adb") }

        let resolved = try? await Shell.run(
            adb,
            [
                "-s", serial, "shell", "cmd", "package",
                "resolve-activity", "--brief",
                "-c", "android.intent.category.LAUNCHER",
                package,
            ],
            timeout: 30
        )

        let component = resolved?.stdout
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.contains("/") && !$0.contains(" ") }

        if let component {
            let started = try await Shell.run(
                adb,
                ["-s", serial, "shell", "am", "start", "-n", component],
                timeout: 45
            )
            if started.succeeded,
               !started.combined.localizedCaseInsensitiveContains("Error") {
                return
            }
        }

        // Fallback for launchers whose component cannot be resolved.
        try await Shell.check(
            adb,
            [
                "-s", serial, "shell", "monkey",
                "-p", package,
                "-c", "android.intent.category.LAUNCHER",
                "1",
            ],
            timeout: 45
        )
    }

    /// Third-party packages only; system packages are noise for a dev launcher.
    public static func installedApps(serial: String) async throws -> [InstalledApp] {
        guard let adb = adbPath else { throw ShellError.toolNotFound("adb") }

        var result = try await Shell.run(
            adb,
            ["-s", serial, "shell", "pm", "list", "packages", "-3", "--show-versioncode"],
            timeout: 60
        )
        if !result.succeeded {
            result = try await Shell.run(
                adb,
                ["-s", serial, "shell", "pm", "list", "packages", "-3"],
                timeout: 60
            )
        }
        guard result.succeeded else {
            throw ShellError.commandFailed(
                command: "pm list packages",
                status: result.status,
                message: result.combined
            )
        }

        var apps: [InstalledApp] = []
        for line in result.stdout.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard let first = fields.first, first.hasPrefix("package:") else { continue }
            let package = String(first.dropFirst("package:".count))
            let version = fields
                .first { $0.hasPrefix("versionCode:") }
                .map { String($0.dropFirst("versionCode:".count)) }
            apps.append(InstalledApp(bundleID: package, name: package, version: version))
        }

        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return apps
    }

    public static func uninstall(package: String, serial: String) async throws {
        guard let adb = adbPath else { throw ShellError.toolNotFound("adb") }
        let result = try await Shell.run(
            adb,
            ["-s", serial, "uninstall", package],
            timeout: 120
        )
        guard result.succeeded,
              !result.combined.localizedCaseInsensitiveContains("Failure") else {
            throw ShellError.commandFailed(
                command: "adb uninstall \(package)",
                status: result.status,
                message: result.combined
            )
        }
    }

    public static func packageIdentifier(ofAPKAt url: URL) async throws -> String {
        guard url.pathExtension.lowercased() == "apk" else {
            throw ShellError.commandFailed(
                command: "read APK",
                status: -1,
                message: "\(url.lastPathComponent) is not an .apk file."
            )
        }

        // Prefer aapt from the newest build-tools, then aapt2, then apkanalyzer.
        if let sdk = sdkRoot {
            let buildTools = sdk + "/build-tools"
            let versions = (try? FileManager.default.contentsOfDirectory(
                atPath: buildTools
            ))?.sorted { $0.localizedStandardCompare($1) == .orderedDescending } ?? []

            for version in versions {
                for tool in ["aapt", "aapt2"] {
                    let path = "\(buildTools)/\(version)/\(tool)"
                    guard FileManager.default.isExecutableFile(atPath: path) else { continue }
                    if let package = try await badgingPackage(path: path, apk: url) {
                        return package
                    }
                }
            }

            let apkanalyzer = sdk + "/cmdline-tools/latest/bin/apkanalyzer"
            if FileManager.default.isExecutableFile(atPath: apkanalyzer) {
                let result = try? await Shell.run(
                    apkanalyzer,
                    ["manifest", "application-id", url.path],
                    timeout: 60
                )
                let package = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if result?.succeeded == true, !package.isEmpty {
                    return package
                }
            }
        }

        throw ShellError.commandFailed(
            command: "read APK package",
            status: -1,
            message: "Could not read the package id from \(url.lastPathComponent). Is Android build-tools installed?"
        )
    }

    private static func badgingPackage(path: String, apk: URL) async throws -> String? {
        guard let result = try? await Shell.run(
            path,
            ["dump", "badging", apk.path],
            timeout: 60
        ), result.succeeded else {
            return nil
        }
        guard let range = result.stdout.range(
            of: #"package: name='([^']+)'"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let match = String(result.stdout[range])
        return match
            .replacingOccurrences(of: "package: name='", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    // MARK: - Helpers

    @discardableResult
    private static func spawnDetached(
        executable: String,
        arguments: [String],
        logName: String
    ) throws -> URL {
        let fm = FileManager.default
        let logDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/OrbitSlim", isDirectory: true)
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logURL = logDirectory.appendingPathComponent(logName)
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: logURL)
        _ = try handle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Shell.environment
        process.standardOutput = handle
        process.standardError = handle

        LauncherRegistry.shared.retain(process, handle: handle)
        do {
            try process.run()
        } catch {
            LauncherRegistry.shared.release(process, handle: handle)
            throw error
        }
        return logURL
    }

    private static func logTail(at url: URL, lines: Int = 20) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
            .split(separator: "\n")
            .suffix(lines)
            .joined(separator: "\n")
    }
}

/// Keeps detached Process objects (and their log handles) alive until exit.
private final class LauncherRegistry: @unchecked Sendable {
    static let shared = LauncherRegistry()
    private let lock = NSLock()
    private var processes: [Process] = []
    private var handles: [FileHandle] = []

    func retain(_ process: Process, handle: FileHandle) {
        lock.lock()
        processes.append(process)
        handles.append(handle)
        lock.unlock()

        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.lock.lock()
            self.processes.removeAll { $0 === finished }
            if let index = self.handles.firstIndex(where: { $0 === handle }) {
                try? self.handles[index].close()
                self.handles.remove(at: index)
            }
            self.lock.unlock()
        }
    }

    func release(_ process: Process, handle: FileHandle) {
        lock.lock()
        processes.removeAll { $0 === process }
        if let index = handles.firstIndex(where: { $0 === handle }) {
            try? handles[index].close()
            handles.remove(at: index)
        }
        lock.unlock()
    }
}
