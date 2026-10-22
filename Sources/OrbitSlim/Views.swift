import AppKit
import OrbitSlimCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared components

struct SlimBadge: View {
    let state: SlimState

    private var color: Color {
        switch state {
        case .slim: return .green
        case .partial: return .orange
        case .stock: return .secondary
        case .unknown: return .secondary
        }
    }

    var body: some View {
        Text(state.label)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .foregroundStyle(color)
            .background(color.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
    }
}

struct StateDot: View {
    let running: Bool

    var body: some View {
        Circle()
            .fill(running ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: 7, height: 7)
            .overlay(
                Circle().strokeBorder(
                    (running ? Color.green : Color.secondary).opacity(0.25),
                    lineWidth: 2
                )
                .scaleEffect(1.8)
                .opacity(running ? 1 : 0)
            )
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            content()
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct StatusBar: View {
    @Bindable var store: DeviceStore

    var body: some View {
        HStack(spacing: 8) {
            if let error = store.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .lineLimit(2)
                    .help(error)
                Spacer()
                Button("Dismiss") { store.clearError() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            } else if let message = store.statusMessage {
                if store.activeOperations > 0 {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            } else {
                Text("Slim-native device launcher")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 32)
    }
}

struct DiagnosticsView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Diagnostics")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Close") { dismiss() }
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(width: 520, height: 280)
    }
}

// MARK: - Device rows

struct SimulatorRow: View {
    let device: SimulatorDevice
    @Bindable var store: DeviceStore
    @Environment(\.openWindow) private var openWindow

    private var busy: Bool { store.isBusy("sim:\(device.udid)") }

    var body: some View {
        HStack(spacing: 10) {
            StateDot(running: device.isBooted)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    SlimBadge(state: device.slim)
                }
                Text("\(device.platformName) \(device.runtimeName) · \(device.state)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            }

            Button {
                Task {
                    if device.isBooted {
                        await store.shutdown(simulator: device)
                    } else {
                        await store.boot(simulator: device)
                    }
                }
            } label: {
                Image(systemName: device.isBooted ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .help(device.isBooted ? "Shut down" : "Boot (slim when enabled)")

            Menu {
                Button("Boot (slim)") {
                    Task { await store.boot(simulator: device, slim: true) }
                }
                .disabled(device.isBooted || busy)

                Button("Boot (stock services)") {
                    Task { await store.bootNormally(simulator: device) }
                }
                .disabled(device.isBooted || busy)

                Divider()

                Button(device.slim.isSlim ? "Restore stock services…" : "Slim simulator…") {
                    Task { await store.toggleSlim(simulator: device) }
                }
                .disabled(busy)

                Button("Install & Launch .app…") {
                    guard let url = InstallFilePicker.choose(platform: .ios) else { return }
                    Task { await store.install(file: url, simulator: device) }
                }
                .disabled(busy)

                Button("Installed Apps…") {
                    Task {
                        await store.openApps(simulator: device)
                        openWindow(id: "manager")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .disabled(!device.isBooted || busy)

                Divider()

                Button("Shut down") {
                    Task { await store.shutdown(simulator: device) }
                }
                .disabled(!device.isBooted || busy)

                Button("Copy UDID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(device.udid, forType: .string)
                    store.flash("Copied \(device.udid)")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .disabled(busy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct AndroidRow: View {
    let device: AndroidDevice
    @Bindable var store: DeviceStore
    @Environment(\.openWindow) private var openWindow

    private var busy: Bool { store.isBusy("android:\(device.avdName)") }

    private var detail: String {
        var parts = [device.stateLabel]
        if let memory = device.memoryMB {
            parts.append("\(memory) MB")
        }
        if let serial = device.serial {
            parts.append(serial)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            StateDot(running: device.isRunning)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.avdName)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if device.isRunning {
                        SlimBadge(state: device.slim)
                    }
                    if AndroidService.avdslimInstalled {
                        Text("avdslim")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1), in: Capsule())
                    }
                }
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            }

            Button {
                Task {
                    if device.isRunning {
                        await store.shutdown(emulator: device)
                    } else {
                        await store.boot(emulator: device)
                    }
                }
            } label: {
                Image(systemName: device.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .help(device.isRunning ? "Stop emulator" : "Boot via avdslim")

            Menu {
                Button("Boot via avdslim") {
                    Task { await store.boot(emulator: device) }
                }
                .disabled(device.isRunning || busy)

                Button(device.slim.isSlim ? "Restore stock services…" : "Slim now…") {
                    Task { await store.toggleSlim(emulator: device) }
                }
                .disabled(!device.isRunning || busy)

                Button("Install & Launch .apk…") {
                    guard let url = InstallFilePicker.choose(platform: .android) else { return }
                    Task { await store.install(file: url, emulator: device) }
                }
                .disabled(busy)

                Button("Installed Apps…") {
                    Task {
                        await store.openApps(emulator: device)
                        openWindow(id: "manager")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .disabled(!device.isRunning || busy)

                Divider()

                Button("Stop emulator") {
                    Task { await store.shutdown(emulator: device) }
                }
                .disabled(!device.isRunning || busy)

                if let serial = device.serial {
                    Button("Copy serial") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(serial, forType: .string)
                        store.flash("Copied \(serial)")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .disabled(busy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Drop zone

struct DropZone: View {
    @Bindable var store: DeviceStore
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 20))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text(isTargeted ? "Drop to install" : "Drop a .app or .apk")
                .font(.system(size: 12, weight: .medium))
            Text("Installs and launches on the first booted simulator or running emulator.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.primary.opacity(0.14),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else if let string = item as? String {
                    url = URL(string: string)
                }
                guard let url else { return }
                Task { @MainActor in
                    await store.installDropped(url: url)
                }
            }
            return true
        }
    }
}

// MARK: - Menu bar content

struct MenuContent: View {
    @Bindable var store: DeviceStore
    @Environment(\.openWindow) private var openWindow
    @State private var showDiagnostics = false

    private var emptySimulatorText: String {
        if store.isRefreshing { return "Loading simulators…" }
        if !store.simulators.isEmpty && !store.showShutdownSimulators {
            return "No booted simulators. Enable “Show shutdown simulators” in settings."
        }
        return "No available simulators."
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill")
                    .foregroundStyle(.tint)
                Text("OrbitSlim")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Refresh")

                Button {
                    showDiagnostics = true
                } label: {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Diagnostics")

                SettingsMenu(store: store)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    SectionCard(title: "iOS Simulators", count: store.visibleSimulators.count) {
                        if store.visibleSimulators.isEmpty {
                            EmptyRow(text: emptySimulatorText)
                        } else {
                            ForEach(store.visibleSimulators) { device in
                                SimulatorRow(device: device, store: store)
                                if device.id != store.visibleSimulators.last?.id {
                                    Divider().padding(.leading, 14)
                                }
                            }
                        }
                    }

                    SectionCard(title: "Android Emulators", count: store.emulators.count) {
                        if store.emulators.isEmpty {
                            EmptyRow(text: store.isRefreshing ? "Loading emulators…" : "No AVDs found.")
                        } else {
                            ForEach(store.emulators) { device in
                                AndroidRow(device: device, store: store)
                                if device.id != store.emulators.last?.id {
                                    Divider().padding(.leading, 14)
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
            .frame(height: 430)

            Divider()

            StatusBar(store: store)

            Divider()

            HStack(spacing: 10) {
                Button {
                    openWindow(id: "manager")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Manager", systemImage: "macwindow")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: 410, height: 590)
        .task {
            store.startPolling()
            await store.refresh()
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(text: store.diagnose())
        }
    }
}

struct SettingsMenu: View {
    @Bindable var store: DeviceStore

    var body: some View {
        Menu {
            Toggle("Slim iOS simulators on boot", isOn: Binding(
                get: { store.bootSlim },
                set: { store.bootSlim = $0 }
            ))
            Toggle("Launch app after install", isOn: Binding(
                get: { store.launchAfterInstall },
                set: { store.launchAfterInstall = $0 }
            ))
            Toggle("Show shutdown simulators", isOn: Binding(
                get: { store.showShutdownSimulators },
                set: { store.showShutdownSimulators = $0 }
            ))
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18)
        .help("Settings")
    }
}

struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }
}

// MARK: - Manager window

struct ManagerView: View {
    @Bindable var store: DeviceStore
    @State private var showDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.hexagongrid.fill")
                            .foregroundStyle(.tint)
                        Text("OrbitSlim")
                            .font(.system(size: 19, weight: .bold))
                    }
                    Text("Expo Orbit workflow, native to simslim and avdslim.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                }

                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)

                Button {
                    showDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .controlSize(.small)

                SettingsMenu(store: store)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(spacing: 14) {
                    DropZone(store: store)

                    SectionCard(title: "iOS Simulators", count: store.visibleSimulators.count) {
                        if store.visibleSimulators.isEmpty {
                            EmptyRow(text: store.isRefreshing
                                ? "Loading simulators…"
                                : "No available simulators. Install an Xcode runtime first.")
                        } else {
                            ForEach(store.visibleSimulators) { device in
                                SimulatorRow(device: device, store: store)
                                if device.id != store.visibleSimulators.last?.id {
                                    Divider().padding(.leading, 14)
                                }
                            }
                        }
                    }

                    SectionCard(title: "Android Emulators", count: store.emulators.count) {
                        if store.emulators.isEmpty {
                            EmptyRow(text: store.isRefreshing
                                ? "Loading emulators…"
                                : "No AVDs found. Create one in Android Studio or with `avdslim create`.")
                        } else {
                            ForEach(store.emulators) { device in
                                AndroidRow(device: device, store: store)
                                if device.id != store.emulators.last?.id {
                                    Divider().padding(.leading, 14)
                                }
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("iOS boot applies simslim first when the simulator is not slim. Android boot always goes through `avdslim start`, so low-RAM flags, GPU host and the golden snapshot apply.")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }

            Divider()
            StatusBar(store: store)
        }
        .frame(minWidth: 620, minHeight: 480)
        .task {
            store.startPolling()
            await store.refresh()
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(text: store.diagnose())
        }
        .sheet(item: $store.appBrowser) { _ in
            InstalledAppsView(store: store)
        }
    }
}

// MARK: - Installed apps

struct InstalledAppsView: View {
    @Bindable var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingUninstall: InstalledApp?

    private var browser: AppBrowserState? { store.appBrowser }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installed Apps")
                        .font(.system(size: 14, weight: .semibold))
                    Text(browser?.title ?? "Device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if browser?.isLoading == true {
                    ProgressView().controlSize(.small)
                }

                Button {
                    Task { await store.reloadApps() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(browser?.isLoading == true)
                .help("Reload app list")

                Button("Done") {
                    store.closeApps()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let error = browser?.error, !error.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Retry") { Task { await store.reloadApps() } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                Divider()
            }

            if let browser {
                if browser.isLoading && browser.apps.isEmpty {
                    Spacer()
                    ProgressView("Loading apps…")
                        .font(.caption)
                    Spacer()
                } else if browser.apps.isEmpty {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No third-party apps installed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(browser.apps) { app in
                                HStack(spacing: 10) {
                                    Image(systemName: "app.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.tint)
                                        .frame(width: 22)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            Text(app.bundleID)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            if let version = app.version, !version.isEmpty {
                                                Text("v\(version)")
                                                    .font(.system(size: 9.5))
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }

                                    Spacer()

                                    if browser.uninstalling.contains(app.id) {
                                        ProgressView().controlSize(.small).scaleEffect(0.8)
                                    } else {
                                        Button("Uninstall") {
                                            pendingUninstall = app
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .disabled(browser.uninstalling.contains(app.id))
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)

                                if app.id != browser.apps.last?.id {
                                    Divider().padding(.leading, 48)
                                }
                            }
                        }
                    }
                }
            } else {
                Spacer()
                Text("No device selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Divider()

            HStack {
                Text("Third-party / user apps only.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let count = browser?.apps.count {
                    Text("\(count) installed")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 560, height: 500)
        .confirmationDialog(
            pendingUninstall.map { "Uninstall “\($0.name)”?" } ?? "Uninstall app?",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                guard let app = pendingUninstall else { return }
                pendingUninstall = nil
                Task { await store.uninstall(app: app) }
            }
            Button("Cancel", role: .cancel) {
                pendingUninstall = nil
            }
        } message: {
            Text("This removes the app and its data from the device.")
        }
    }
}

// MARK: - File picker

enum InstallFilePicker {
    @MainActor
    static func choose(platform: DevicePlatform) -> URL? {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = platform == .ios
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Install"

        switch platform {
        case .ios:
            panel.title = "Choose an iOS Simulator .app"
            panel.message = "Select a Simulator-compatible .app bundle."
            if let type = UTType(filenameExtension: "app") {
                panel.allowedContentTypes = [type]
            }
        case .android:
            panel.title = "Choose an Android .apk"
            panel.message = "Select an APK to install."
            if let type = UTType(filenameExtension: "apk") {
                panel.allowedContentTypes = [type]
            }
        }

        guard panel.runModal() == .OK,
              let url = panel.url,
              url.pathExtension.lowercased() == platform.installExtension else {
            return nil
        }
        return url
    }
}
