import Foundation

public enum SimctlService {
    private static let xcrun = "/usr/bin/xcrun"

    struct ListResponse: Decodable {
        let devices: [String: [Entry]]

        struct Entry: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
        }
    }

    public static func list() async throws -> [SimulatorDevice] {
        let result = try await Shell.run(
            xcrun,
            ["simctl", "list", "devices", "available", "--json"],
            timeout: 30
        )
        guard result.succeeded else {
            throw ShellError.commandFailed(
                command: "simctl list devices",
                status: result.status,
                message: result.combined
            )
        }
        guard let data = result.stdout.data(using: .utf8) else { return [] }
        let response = try JSONDecoder().decode(ListResponse.self, from: data)

        var devices: [SimulatorDevice] = []
        for (runtimeID, entries) in response.devices {
            let runtime = parseRuntime(runtimeID)
            for entry in entries where entry.isAvailable ?? true {
                devices.append(SimulatorDevice(
                    udid: entry.udid,
                    name: entry.name,
                    runtimeName: runtime.version,
                    platformName: runtime.platform,
                    state: entry.state
                ))
            }
        }

        devices.sort {
            if $0.isBooted != $1.isBooted { return $0.isBooted }
            if $0.platformName != $1.platformName { return $0.platformName < $1.platformName }
            if $0.runtimeName != $1.runtimeName { return $0.runtimeName > $1.runtimeName }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return devices
    }

    private static func parseRuntime(_ identifier: String) -> (platform: String, version: String) {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        var raw = identifier
        if raw.hasPrefix(prefix) { raw.removeFirst(prefix.count) }

        let parts = raw.split(separator: "-").map(String.init)
        guard let first = parts.first else { return ("iOS", "") }
        let platform: String
        switch first {
        case "xrOS": platform = "visionOS"
        default: platform = first
        }
        let version = parts.dropFirst().joined(separator: ".")
        return (platform, version)
    }

    public static func isBooted(_ udid: String) async -> Bool {
        guard let result = try? await Shell.run(xcrun, ["simctl", "list", "devices", udid, "--json"], timeout: 15),
              result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(ListResponse.self, from: data) else {
            return false
        }
        return response.devices.values.joined().contains { $0.udid == udid && $0.state == "Booted" }
    }

    public static func boot(_ udid: String) async throws {
        let result = try await Shell.run(xcrun, ["simctl", "boot", udid], timeout: 120)
        if result.succeeded { return }
        // Already booted is not an error for our purposes.
        if result.combined.localizedCaseInsensitiveContains("current state: Booted") { return }
        throw ShellError.commandFailed(
            command: "simctl boot \(udid)",
            status: result.status,
            message: result.combined
        )
    }

    public static func waitUntilBooted(_ udid: String, timeout: TimeInterval = 300) async throws {
        try await Shell.check(
            xcrun,
            ["simctl", "bootstatus", udid, "-b"],
            timeout: timeout
        )
    }

    public static func bootAndWait(_ udid: String) async throws {
        try await boot(udid)
        try await waitUntilBooted(udid)
    }

    public static func shutdown(_ udid: String) async throws {
        let result = try await Shell.run(xcrun, ["simctl", "shutdown", udid], timeout: 60)
        if result.succeeded { return }
        if result.combined.localizedCaseInsensitiveContains("current state: Shutdown") { return }
        throw ShellError.commandFailed(
            command: "simctl shutdown \(udid)",
            status: result.status,
            message: result.combined
        )
    }

    public static func install(_ udid: String, appAt url: URL) async throws {
        guard url.pathExtension.lowercased() == "app" else {
            throw ShellError.commandFailed(
                command: "simctl install",
                status: -1,
                message: "\(url.lastPathComponent) is not a .app bundle."
            )
        }
        try await Shell.check(
            xcrun,
            ["simctl", "install", udid, url.path],
            timeout: 180
        )
    }

    public static func launch(_ udid: String, bundleIdentifier: String) async throws {
        try await Shell.check(
            xcrun,
            ["simctl", "launch", udid, bundleIdentifier],
            timeout: 60
        )
    }

    /// `simctl listapps` emits an OpenStep plist; convert it with plutil and
    /// keep only user-installed apps (ApplicationType = User).
    public static func installedApps(udid: String) async throws -> [InstalledApp] {
        let raw = try await Shell.check(
            xcrun,
            ["simctl", "listapps", udid],
            timeout: 90
        ).stdout

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbitslim-listapps-\(UUID().uuidString).plist")
        try raw.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let json = try await Shell.check(
            "/usr/bin/plutil",
            ["-convert", "json", "-o", "-", temp.path],
            timeout: 60
        ).stdout
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            throw ShellError.commandFailed(
                command: "simctl listapps",
                status: -1,
                message: "Could not parse the installed app list."
            )
        }

        var apps: [InstalledApp] = []
        for (bundleID, info) in object {
            let type = info["ApplicationType"] as? String ?? "User"
            let isSystem = type == "System"
            guard !isSystem else { continue }
            let name = info["CFBundleDisplayName"] as? String
                ?? info["CFBundleName"] as? String
                ?? bundleID
            let version = info["CFBundleShortVersionString"] as? String
                ?? info["CFBundleVersion"].map { "\($0)" }
            apps.append(InstalledApp(
                bundleID: bundleID,
                name: name,
                version: version,
                isSystem: false
            ))
        }

        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return apps
    }

    public static func uninstall(_ udid: String, bundleID: String) async throws {
        try await Shell.check(
            xcrun,
            ["simctl", "uninstall", udid, bundleID],
            timeout: 90
        )
    }

    public static func bundleIdentifier(ofAppAt url: URL) async throws -> String {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            throw ShellError.commandFailed(
                command: "read Info.plist",
                status: -1,
                message: "No Contents/Info.plist inside \(url.lastPathComponent)."
            )
        }
        let result = try await Shell.run(
            "/usr/bin/plutil",
            ["-extract", "CFBundleIdentifier", "raw", "-o", "-", plist.path],
            timeout: 15
        )
        let bundle = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !bundle.isEmpty else {
            throw ShellError.commandFailed(
                command: "read CFBundleIdentifier",
                status: result.status,
                message: result.combined
            )
        }
        return bundle
    }

    /// Xcode 26/27 replaced Simulator.app with DeviceHub.app. Open whichever
    /// exists, resolved relative to the active developer directory.
    public static func openSimulatorApp() async {
        let fm = FileManager.default
        let developerDirectory = (try? await Shell.run(
            "/usr/bin/xcode-select",
            ["-p"],
            timeout: 10
        ))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        var candidates: [String] = []
        if let developerDirectory, !developerDirectory.isEmpty {
            candidates.append(
                URL(fileURLWithPath: developerDirectory)
                    .appendingPathComponent("../Applications/DeviceHub.app")
                    .standardizedFileURL.path
            )
            candidates.append(
                URL(fileURLWithPath: developerDirectory)
                    .appendingPathComponent("Applications/Simulator.app")
                    .standardizedFileURL.path
            )
        }
        candidates.append(contentsOf: [
            "/Applications/Xcode.app/Contents/Applications/DeviceHub.app",
            "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app",
            "/Applications/Xcode-beta.app/Contents/Applications/DeviceHub.app",
            "/Applications/Xcode-beta.app/Contents/Developer/Applications/Simulator.app",
        ])

        for candidate in candidates where fm.fileExists(atPath: candidate) {
            _ = try? await Shell.run("/usr/bin/open", [candidate], timeout: 20)
            return
        }

        // Older Xcode: fall back to LaunchServices name lookup.
        _ = try? await Shell.run("/usr/bin/open", ["-a", "Simulator"], timeout: 20)
    }
}
