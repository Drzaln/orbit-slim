import Foundation
import Observation
import OrbitSlimCore

struct AppBrowserState: Identifiable {
    let id: String
    let title: String
    let platform: DevicePlatform
    let deviceID: String
    var apps: [InstalledApp] = []
    var isLoading = false
    var error: String?
    var uninstalling: Set<String> = []
}

@MainActor
@Observable
final class DeviceStore {
    var simulators: [SimulatorDevice] = []
    var emulators: [AndroidDevice] = []
    var isRefreshing = false
    var lastError: String?
    var statusMessage: String?
    var appBrowser: AppBrowserState?

    var bootSlim: Bool {
        didSet { UserDefaults.standard.set(bootSlim, forKey: Keys.bootSlim) }
    }
    var launchAfterInstall: Bool {
        didSet { UserDefaults.standard.set(launchAfterInstall, forKey: Keys.launchAfterInstall) }
    }
    var showShutdownSimulators: Bool {
        didSet { UserDefaults.standard.set(showShutdownSimulators, forKey: Keys.showShutdown) }
    }

    private var busy: Set<String> = []
    private var pollStarted = false
    private var flashGeneration = 0

    private enum Keys {
        static let bootSlim = "bootSlim"
        static let launchAfterInstall = "launchAfterInstall"
        static let showShutdown = "showShutdownSimulators"
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.bootSlim) == nil {
            defaults.set(true, forKey: Keys.bootSlim)
        }
        if defaults.object(forKey: Keys.launchAfterInstall) == nil {
            defaults.set(true, forKey: Keys.launchAfterInstall)
        }
        if defaults.object(forKey: Keys.showShutdown) == nil {
            defaults.set(true, forKey: Keys.showShutdown)
        }
        bootSlim = defaults.bool(forKey: Keys.bootSlim)
        launchAfterInstall = defaults.bool(forKey: Keys.launchAfterInstall)
        showShutdownSimulators = defaults.bool(forKey: Keys.showShutdown)
    }

    var visibleSimulators: [SimulatorDevice] {
        showShutdownSimulators ? simulators : simulators.filter(\.isBooted)
    }

    var activeOperations: Int { busy.count }

    func isBusy(_ id: String) -> Bool {
        busy.contains(id)
    }

    // MARK: - Refresh

    func startPolling() {
        guard !pollStarted else { return }
        pollStarted = true
        AppLog.write("polling started")
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        AppLog.write("refresh start")
        defer { isRefreshing = false }

        let snapshot = await DeviceCatalog.load()
        AppLog.write(
            "refresh done sims=\(snapshot.simulators.count) avds=\(snapshot.emulators.count) errors=\(snapshot.errors)"
        )
        if !snapshot.simulators.isEmpty || simulators.isEmpty {
            simulators = snapshot.simulators
        }
        emulators = snapshot.emulators
        if let error = snapshot.errors.first {
            lastError = error
        }
    }

    // MARK: - iOS

    func boot(simulator: SimulatorDevice, slim: Bool? = nil) async {
        let key = simID(simulator)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }

        let preferSlim = slim ?? bootSlim
        do {
            if simulator.isBooted && simulator.slim.isSlim {
                await SimctlService.openSimulatorApp()
                flash("\(simulator.name) is already booted and slim.")
                return
            }

            if preferSlim && SimslimService.isInstalled && simulator.slim.needsSlimming {
                flash("Slimming and booting \(simulator.name)…")
                try await SimslimService.enable(udid: simulator.udid)
            } else if !simulator.isBooted {
                flash("Booting \(simulator.name)…")
                try await SimctlService.bootAndWait(simulator.udid)
            } else if preferSlim {
                try await SimslimService.enable(udid: simulator.udid)
            }

            await SimctlService.openSimulatorApp()
            flash("\(simulator.name) is ready.")
        } catch {
            record(error)
        }
        await refresh()
    }

    func bootNormally(simulator: SimulatorDevice) async {
        await boot(simulator: simulator, slim: false)
    }

    func shutdown(simulator: SimulatorDevice) async {
        let key = simID(simulator)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            flash("Shutting down \(simulator.name)…")
            try await SimctlService.shutdown(simulator.udid)
            flash("\(simulator.name) shut down.")
        } catch {
            record(error)
        }
        await refresh()
    }

    func toggleSlim(simulator: SimulatorDevice) async {
        let key = simID(simulator)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }

        do {
            if simulator.slim.isSlim {
                flash("Restoring stock services on \(simulator.name)…")
                try await SimslimService.disable(udid: simulator.udid)
                flash("\(simulator.name) restored to stock.")
            } else {
                flash("Slimming \(simulator.name)… this reboots the simulator.")
                try await SimslimService.enable(udid: simulator.udid)
                flash("\(simulator.name) is slim.")
            }
            await SimctlService.openSimulatorApp()
        } catch {
            record(error)
        }
        await refresh()
    }

    func install(file: URL, simulator: SimulatorDevice) async {
        let key = simID(simulator)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }

        do {
            if !simulator.isBooted {
                if bootSlim && SimslimService.isInstalled && simulator.slim.needsSlimming {
                    flash("Slimming and booting \(simulator.name)…")
                    try await SimslimService.enable(udid: simulator.udid)
                } else {
                    flash("Booting \(simulator.name)…")
                    try await SimctlService.bootAndWait(simulator.udid)
                }
            }

            let bundle = try await SimctlService.bundleIdentifier(ofAppAt: file)
            flash("Installing \(bundle) on \(simulator.name)…")
            try await SimctlService.install(simulator.udid, appAt: file)
            if launchAfterInstall {
                try await SimctlService.launch(simulator.udid, bundleIdentifier: bundle)
            }
            await SimctlService.openSimulatorApp()
            flash(
                launchAfterInstall
                    ? "Launched \(bundle) on \(simulator.name)."
                    : "Installed \(bundle) on \(simulator.name)."
            )
        } catch {
            record(error)
        }
        await refresh()
    }

    // MARK: - Android

    func boot(emulator: AndroidDevice) async {
        let key = androidID(emulator)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }

        do {
            if emulator.isRunning {
                flash("\(emulator.avdName) is already running.")
                return
            }
            flash("Booting \(emulator.avdName) via avdslim…")
            let log = try await AndroidService.start(avd: emulator.avdName)
            let serial = try await AndroidService.waitForRunning(
                avd: emulator.avdName,
                timeout: 300,
                logURL: log
            )
            flash("\(emulator.avdName) is running on \(serial).")
        } catch {
            record(error)
        }
        await refresh()
    }

    func shutdown(emulator: AndroidDevice) async {
        let key = androidID(emulator)
        guard !busy.contains(key), let serial = emulator.serial else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            flash("Stopping \(emulator.avdName)…")
            try await AndroidService.shutdown(serial: serial)
            flash("\(emulator.avdName) stopped.")
        } catch {
            record(error)
        }
        await refresh()
    }

    func toggleSlim(emulator: AndroidDevice) async {
        let key = androidID(emulator)
        guard !busy.contains(key), let serial = emulator.serial else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            if emulator.slim.isSlim {
                flash("Restoring stock services on \(emulator.avdName)…")
                try await AndroidService.restoreStock(serial: serial)
                flash("\(emulator.avdName) restored to stock.")
            } else {
                flash("Slimming \(emulator.avdName)…")
                try await AndroidService.slimNow(serial: serial)
                flash("\(emulator.avdName) is slim.")
            }
        } catch {
            record(error)
        }
        await refresh()
    }

    func install(file: URL, emulator: AndroidDevice) async {
        let key = androidID(emulator)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }

        do {
            let package = try await AndroidService.packageIdentifier(ofAPKAt: file)
            var serial = emulator.serial

            if serial == nil {
                flash("Booting \(emulator.avdName) via avdslim…")
                let log = try await AndroidService.start(avd: emulator.avdName)
                serial = try await AndroidService.waitForRunning(
                    avd: emulator.avdName,
                    timeout: 300,
                    logURL: log
                )
            }

            guard let serial else {
                throw ShellError.commandFailed(
                    command: "install",
                    status: -1,
                    message: "No running emulator for \(emulator.avdName)."
                )
            }

            flash("Installing \(package) on \(emulator.avdName)…")
            try await AndroidService.install(apkAt: file, serial: serial)
            if launchAfterInstall {
                try await AndroidService.launch(package: package, serial: serial)
            }
            flash(
                launchAfterInstall
                    ? "Launched \(package) on \(emulator.avdName)."
                    : "Installed \(package) on \(emulator.avdName)."
            )
        } catch {
            record(error)
        }
        await refresh()
    }

    // MARK: - Installed apps

    func openApps(simulator: SimulatorDevice) async {
        guard simulator.isBooted else { return }
        appBrowser = AppBrowserState(
            id: simulator.udid,
            title: simulator.name,
            platform: .ios,
            deviceID: simulator.udid
        )
        await reloadApps()
    }

    func openApps(emulator: AndroidDevice) async {
        guard let serial = emulator.serial else { return }
        appBrowser = AppBrowserState(
            id: serial,
            title: emulator.avdName,
            platform: .android,
            deviceID: serial
        )
        await reloadApps()
    }

    func reloadApps() async {
        guard var browser = appBrowser, !browser.isLoading else { return }
        browser.isLoading = true
        browser.error = nil
        appBrowser = browser

        do {
            let apps: [InstalledApp]
            switch browser.platform {
            case .ios:
                apps = try await SimctlService.installedApps(udid: browser.deviceID)
            case .android:
                apps = try await AndroidService.installedApps(serial: browser.deviceID)
            }
            guard var latest = appBrowser else { return }
            latest.apps = apps
            latest.isLoading = false
            appBrowser = latest
        } catch {
            guard var latest = appBrowser else { return }
            latest.isLoading = false
            latest.error = error.localizedDescription
            appBrowser = latest
        }
    }

    func uninstall(app: InstalledApp) async {
        guard var browser = appBrowser,
              !browser.uninstalling.contains(app.id) else { return }
        browser.uninstalling.insert(app.id)
        browser.error = nil
        appBrowser = browser

        do {
            switch browser.platform {
            case .ios:
                try await SimctlService.uninstall(browser.deviceID, bundleID: app.id)
            case .android:
                try await AndroidService.uninstall(package: app.id, serial: browser.deviceID)
            }
            if var latest = appBrowser {
                latest.apps.removeAll { $0.id == app.id }
                latest.uninstalling.remove(app.id)
                appBrowser = latest
            }
            flash("Uninstalled \(app.name).")
        } catch {
            if var latest = appBrowser {
                latest.uninstalling.remove(app.id)
                latest.error = error.localizedDescription
                appBrowser = latest
            }
        }
    }

    func closeApps() {
        appBrowser = nil
    }

    // MARK: - Dropped files

    func installDropped(url: URL) async {
        switch url.pathExtension.lowercased() {
        case "app":
            guard let target = simulators.first(where: \.isBooted)
                ?? visibleSimulators.first
                ?? simulators.first else {
                record(message: "No iOS simulators available.")
                return
            }
            await install(file: url, simulator: target)
        case "apk":
            guard let target = emulators.first(where: \.isRunning) ?? emulators.first else {
                record(message: "No Android emulators available.")
                return
            }
            await install(file: url, emulator: target)
        default:
            record(message: "Drop an iOS .app bundle or an Android .apk.")
        }
    }

    // MARK: - Diagnostics

    func diagnose() -> String {
        var lines: [String] = []
        lines.append("simslim: \(Shell.findTool("simslim") ?? "not found")")
        lines.append("avdslim: \(Shell.findTool("avdslim") ?? "not found")")
        lines.append("adb: \(AndroidService.adbPath ?? "not found")")
        lines.append("emulator: \(AndroidService.emulatorPath ?? "not found")")
        lines.append("Android SDK: \(AndroidService.sdkRoot ?? "not found")")
        lines.append("simslim managed labels: \(SimslimManagedLabels.all.count)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func simID(_ device: SimulatorDevice) -> String { "sim:\(device.udid)" }
    private func androidID(_ device: AndroidDevice) -> String { "android:\(device.avdName)" }

    func flash(_ message: String) {
        statusMessage = message
        flashGeneration += 1
        let generation = flashGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.flashGeneration == generation else { return }
            if self.statusMessage == message {
                self.statusMessage = nil
            }
        }
    }

    private func record(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func record(message: String) {
        lastError = message
    }

    func clearError() {
        lastError = nil
    }
}
