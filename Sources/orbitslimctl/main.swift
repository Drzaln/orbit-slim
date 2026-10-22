import Darwin
import Foundation
import OrbitSlimCore

@main
struct OrbitSlimCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printHelp()
            return
        }
        arguments.removeFirst()

        do {
            switch command {
            case "list":
                try await list()
            case "diag":
                diagnose()
            case "boot":
                try await boot(arguments)
            case "shutdown", "stop":
                try await shutdown(arguments)
            case "slim":
                try await setSlim(arguments, slim: true)
            case "unslim", "restore":
                try await setSlim(arguments, slim: false)
            case "install":
                try await install(arguments)
            case "uninstall":
                try await uninstall(arguments)
            case "package", "apkid":
                try await packageIdentifier(arguments)
            case "bundleid":
                try await bundleIdentifier(arguments)
            case "apps":
                try await installedApps(arguments)
            case "debug-android":
                try await debugAndroid()
            case "help", "--help", "-h":
                printHelp()
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n".utf8))
                printHelp()
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data(("Error: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    // MARK: - Commands

    private static func list() async throws {
        let snapshot = await DeviceCatalog.load()

        if !snapshot.errors.isEmpty {
            for error in snapshot.errors {
                FileHandle.standardError.write(Data(("warning: " + error + "\n").utf8))
            }
        }

        print("iOS SIMULATORS")
        if snapshot.simulators.isEmpty {
            print("  (none)")
        } else {
            for device in snapshot.simulators {
                let state = device.isBooted ? "booted" : "shutdown"
                print("  \(device.udid)  \(pad(device.name, 26)) \(pad("\(device.platformName) \(device.runtimeName)", 16)) \(pad(state, 10)) \(device.slim.label)")
            }
        }

        print("\nANDROID EMULATORS")
        if snapshot.emulators.isEmpty {
            print("  (none)")
        } else {
            for device in snapshot.emulators {
                let state = device.isRunning ? (device.serial ?? "running") : "stopped"
                let memory = device.memoryMB.map { "\($0) MB" } ?? "—"
                print("  \(pad(device.avdName, 26)) \(pad(state, 16)) \(pad(memory, 10)) \(device.isRunning ? device.slim.label : "—")")
            }
        }
    }

    private static func diagnose() {
        print("simslim: \(Shell.findTool("simslim") ?? "not found")")
        print("avdslim: \(Shell.findTool("avdslim") ?? "not found")")
        print("adb: \(AndroidService.adbPath ?? "not found")")
        print("emulator: \(AndroidService.emulatorPath ?? "not found")")
        print("Android SDK: \(AndroidService.sdkRoot ?? "not found")")
        print("simslim managed labels: \(SimslimManagedLabels.all.count)")
        print("SIMSLIM_BIN env: \(ProcessInfo.processInfo.environment["SIMSLIM_BIN"] ?? "—")")
    }

    private static func boot(_ arguments: [String]) async throws {
        guard let target = arguments.first(where: { !$0.hasPrefix("--") }) else {
            throw CLIError.usage("boot <udid|avd> [--stock]")
        }
        let stock = arguments.contains("--stock")
        let snapshot = await DeviceCatalog.load()

        if let sim = snapshot.simulators.first(where: { matches($0, target) }) {
            if sim.isBooted && (stock || sim.slim.isSlim) {
                print("\(sim.name) is already booted.")
            } else if !stock, SimslimService.isInstalled, sim.slim.needsSlimming {
                print("Slimming and booting \(sim.name)…")
                try await SimslimService.enable(udid: sim.udid)
            } else {
                print("Booting \(sim.name)…")
                try await SimctlService.bootAndWait(sim.udid)
            }
            await SimctlService.openSimulatorApp()
            print("Ready: \(sim.udid)")
            return
        }

        if let emulator = snapshot.emulators.first(where: { $0.avdName.caseInsensitiveCompare(target) == .orderedSame }) {
            if emulator.isRunning, let serial = emulator.serial {
                print("\(emulator.avdName) is already running on \(serial).")
                return
            }
            print("Booting \(emulator.avdName) via avdslim…")
            let log = try await AndroidService.start(avd: emulator.avdName)
            let serial = try await AndroidService.waitForRunning(
                avd: emulator.avdName,
                timeout: 300,
                logURL: log
            )
            print("Ready: \(serial)")
            return
        }

        throw CLIError.usage("No simulator or AVD matches '\(target)'.")
    }

    private static func shutdown(_ arguments: [String]) async throws {
        guard let target = arguments.first else {
            throw CLIError.usage("shutdown <udid|avd>")
        }
        let snapshot = await DeviceCatalog.load()

        if let sim = snapshot.simulators.first(where: { matches($0, target) }) {
            try await SimctlService.shutdown(sim.udid)
            print("Shut down \(sim.name).")
            return
        }
        if let emulator = snapshot.emulators.first(where: { $0.avdName.caseInsensitiveCompare(target) == .orderedSame }) {
            guard let serial = emulator.serial else {
                print("\(emulator.avdName) is not running.")
                return
            }
            try await AndroidService.shutdown(serial: serial)
            print("Stopped \(emulator.avdName).")
            return
        }
        throw CLIError.usage("No simulator or AVD matches '\(target)'.")
    }

    private static func setSlim(_ arguments: [String], slim: Bool) async throws {
        guard let target = arguments.first else {
            throw CLIError.usage(slim ? "slim <udid|avd>" : "unslim <udid|avd>")
        }
        let snapshot = await DeviceCatalog.load()

        if let sim = snapshot.simulators.first(where: { matches($0, target) }) {
            if slim {
                print("Slimming \(sim.name)…")
                try await SimslimService.enable(udid: sim.udid)
            } else {
                print("Restoring stock services on \(sim.name)…")
                try await SimslimService.disable(udid: sim.udid)
            }
            print("Done: \(sim.name)")
            return
        }

        if let emulator = snapshot.emulators.first(where: { $0.avdName.caseInsensitiveCompare(target) == .orderedSame }) {
            guard let serial = emulator.serial else {
                throw CLIError.usage("\(emulator.avdName) must be running to change guest services.")
            }
            if slim {
                try await AndroidService.slimNow(serial: serial)
            } else {
                try await AndroidService.restoreStock(serial: serial)
            }
            print("Done: \(emulator.avdName)")
            return
        }
        throw CLIError.usage("No simulator or AVD matches '\(target)'.")
    }

    private static func install(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            throw CLIError.usage("install <file.app|file.apk> [udid|avd]")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.usage("File not found: \(url.path)")
        }
        let explicitTarget = arguments.dropFirst().first
        let snapshot = await DeviceCatalog.load()
        let bundle: String

        switch url.pathExtension.lowercased() {
        case "app":
            let sim: SimulatorDevice?
            if let explicitTarget {
                sim = snapshot.simulators.first { matches($0, explicitTarget) }
            } else {
                sim = snapshot.simulators.first(where: \.isBooted) ?? snapshot.simulators.first
            }
            guard let sim else {
                throw CLIError.usage(explicitTarget == nil
                    ? "No iOS simulator available."
                    : "No simulator matches '\(explicitTarget!)'.")
            }
            if !sim.isBooted {
                print("Booting \(sim.name)…")
                if SimslimService.isInstalled && sim.slim.needsSlimming {
                    try await SimslimService.enable(udid: sim.udid)
                } else {
                    try await SimctlService.bootAndWait(sim.udid)
                }
            }
            bundle = try await SimctlService.bundleIdentifier(ofAppAt: url)
            try await SimctlService.install(sim.udid, appAt: url)
            try await SimctlService.launch(sim.udid, bundleIdentifier: bundle)
            await SimctlService.openSimulatorApp()
            print("Installed and launched \(bundle) on \(sim.name).")

        case "apk":
            guard let emulator = snapshot.emulators.first(where: {
                if let explicitTarget { return $0.avdName.caseInsensitiveCompare(explicitTarget) == .orderedSame }
                return $0.isRunning
            }) ?? snapshot.emulators.first else {
                throw CLIError.usage("No Android emulator available.")
            }
            var serial = emulator.serial
            if serial == nil {
                print("Booting \(emulator.avdName)…")
                let log = try await AndroidService.start(avd: emulator.avdName)
                serial = try await AndroidService.waitForRunning(
                    avd: emulator.avdName,
                    timeout: 300,
                    logURL: log
                )
            }
            bundle = try await AndroidService.packageIdentifier(ofAPKAt: url)
            guard let serial else { throw CLIError.usage("No running emulator.") }
            try await AndroidService.install(apkAt: url, serial: serial)
            try await AndroidService.launch(package: bundle, serial: serial)
            print("Installed and launched \(bundle) on \(emulator.avdName).")

        default:
            throw CLIError.usage("Expected a .app bundle or .apk file.")
        }
    }

    private static func packageIdentifier(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            throw CLIError.usage("package <file.apk>")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let package = try await AndroidService.packageIdentifier(ofAPKAt: url)
        print(package)
    }

    private static func bundleIdentifier(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            throw CLIError.usage("bundleid <file.app>")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let bundle = try await SimctlService.bundleIdentifier(ofAppAt: url)
        print(bundle)
    }

    private static func debugAndroid() async throws {
        guard let adb = AndroidService.adbPath else {
            print("adb not found")
            return
        }
        let devices = try await Shell.run(adb, ["devices"], timeout: 20)
        print("adb devices status=\(devices.status)")
        print("stdout:\n\(devices.stdout)")
        print("stderr:\n\(devices.stderr)")

        for line in devices.stdout.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first, first.hasPrefix("emulator-") else { continue }
            let serial = String(first)
            let reply = try await Shell.run(adb, ["-s", serial, "emu", "avd", "name"], timeout: 15)
            print("\(serial) emu-name status=\(reply.status) stdout=\(reply.stdout.debugDescription) stderr=\(reply.stderr.debugDescription)")
        }

        let running = await AndroidService.runningEmulators()
        print("runningEmulators = \(running)")
    }

    private static func uninstall(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            throw CLIError.usage("uninstall <udid|name|avd> <bundle-id|package>")
        }
        let target = arguments[0]
        let identifier = arguments[1]
        let snapshot = await DeviceCatalog.load()

        if let sim = snapshot.simulators.first(where: { matches($0, target) }) {
            try await SimctlService.uninstall(sim.udid, bundleID: identifier)
            print("Uninstalled \(identifier) from \(sim.name).")
            return
        }
        if let emulator = snapshot.emulators.first(where: { $0.avdName.caseInsensitiveCompare(target) == .orderedSame }) {
            guard let serial = emulator.serial else {
                throw CLIError.usage("\(emulator.avdName) must be running to uninstall apps.")
            }
            try await AndroidService.uninstall(package: identifier, serial: serial)
            print("Uninstalled \(identifier) from \(emulator.avdName).")
            return
        }
        throw CLIError.usage("No simulator or AVD matches '\(target)'.")
    }

    private static func installedApps(_ arguments: [String]) async throws {        guard let target = arguments.first else {
            throw CLIError.usage("apps <udid|name|avd>")
        }
        let snapshot = await DeviceCatalog.load()

        if let sim = snapshot.simulators.first(where: { matches($0, target) }) {
            guard sim.isBooted else {
                throw CLIError.usage("\(sim.name) must be booted to list installed apps.")
            }
            let apps = try await SimctlService.installedApps(udid: sim.udid)
            print("\(sim.name): \(apps.count) user apps")
            for app in apps {
                let version = app.version.map { "  v\($0)" } ?? ""
                print("  \(pad(app.name, 26)) \(app.bundleID)\(version)")
            }
            return
        }

        if let emulator = snapshot.emulators.first(where: { $0.avdName.caseInsensitiveCompare(target) == .orderedSame }) {
            guard let serial = emulator.serial else {
                throw CLIError.usage("\(emulator.avdName) must be running to list installed apps.")
            }
            let apps = try await AndroidService.installedApps(serial: serial)
            print("\(emulator.avdName): \(apps.count) third-party packages")
            for app in apps {
                print("  \(app.bundleID)")
            }
            return
        }

        throw CLIError.usage("No simulator or AVD matches '\(target)'.")
    }

    // MARK: - Helpers

    private static func matches(_ sim: SimulatorDevice, _ target: String) -> Bool {
        sim.udid.caseInsensitiveCompare(target) == .orderedSame
            || sim.name.caseInsensitiveCompare(target) == .orderedSame
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        if value.count >= width { return value }
        return value + String(repeating: " ", count: width - value.count)
    }

    private static func printHelp() {
        print("""
        orbitslimctl — CLI companion for OrbitSlim

        USAGE
          orbitslimctl list
          orbitslimctl diag
          orbitslimctl boot <udid|name|avd> [--stock]
          orbitslimctl shutdown <udid|name|avd>
          orbitslimctl slim <udid|name|avd>
          orbitslimctl unslim <udid|name|avd>
          orbitslimctl install <file.app|file.apk> [udid|name|avd]
          orbitslimctl package <file.apk>
          orbitslimctl bundleid <file.app>
          orbitslimctl apps <udid|name|avd>
          orbitslimctl uninstall <udid|name|avd> <bundle-id|package>
          orbitslimctl help

        iOS boot prefers `simslim on` so the simulator boots slim.
        Android boot always uses `avdslim start` when available.
        """)
    }
}

enum CLIError: LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): return message
        }
    }
}
