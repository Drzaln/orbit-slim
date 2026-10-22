import Foundation

public enum SimslimService {
    struct StatusOutput: Decodable {
        let managedDisabled: Int?
        let managedTotal: Int?
        let booted: Bool?
        let persistent: Bool?
        let verdict: String?
    }

    public static var isInstalled: Bool {
        Shell.findTool("simslim") != nil
    }

    /// Booted simulators: ask simslim for its authoritative live status.
    /// Shutdown simulators: classify the persisted launchd override store
    /// directly, since `simslim status` refuses to read a shutdown device.
    public static func status(for device: SimulatorDevice) async -> SlimState {
        if device.isBooted {
            if let live = await liveStatus(udid: device.udid) { return live }
        }
        return offlineStatus(udid: device.udid)
    }

    public static func liveStatus(udid: String) async -> SlimState? {
        guard isInstalled else { return nil }
        guard let result = try? await Shell.run(
            "simslim",
            ["status", udid, "--json"],
            timeout: 45
        ), result.succeeded, let data = result.stdout.data(using: .utf8) else {
            return nil
        }
        guard let output = try? JSONDecoder().decode(StatusOutput.self, from: data) else {
            return nil
        }
        return classify(
            disabled: output.managedDisabled ?? 0,
            total: output.managedTotal ?? 0,
            verdict: output.verdict
        )
    }

    /// Reads `/private/var/tmp/com.apple.CoreSimulator.SimDevice.<udid>/disabled.plist`,
    /// where launchd_sim persists overrides, and counts only labels simslim manages.
    public static func offlineStatus(udid: String) -> SlimState {
        let path = "/private/var/tmp/com.apple.CoreSimulator.SimDevice.\(udid)/disabled.plist"
        guard FileManager.default.fileExists(atPath: path) else { return .stock }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let entries = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Bool] else {
            return .unknown
        }

        let total = SimslimManagedLabels.all.count
        let disabled = entries.reduce(into: 0) { count, pair in
            if pair.value && SimslimManagedLabels.all.contains(pair.key) {
                count += 1
            }
        }

        if disabled == 0 { return .stock }
        // Runtime differences mean not every managed label exists on every
        // platform; treat ~90% as fully slim.
        if disabled >= Int(Double(total) * 0.9) { return .slim }
        return .partial(disabled: disabled, total: total)
    }

    private static func classify(disabled: Int, total: Int, verdict: String?) -> SlimState {
        if let verdict {
            switch verdict {
            case "slim": return .slim
            case "partially slim": return .partial(disabled: disabled, total: total)
            case "stock": return .stock
            default: break
            }
        }
        if total > 0 && disabled == total { return .slim }
        if disabled > 0 { return .partial(disabled: disabled, total: total) }
        return .stock
    }

    /// Persistent slim + boot. This is also the preferred boot path: it writes
    /// overrides offline when possible and boots once.
    public static func enable(udid: String) async throws {
        guard isInstalled else { throw ShellError.toolNotFound("simslim") }
        let result = try await Shell.run(
            "simslim",
            ["on", udid],
            timeout: 900
        )
        guard result.succeeded else {
            throw ShellError.commandFailed(
                command: "simslim on \(udid)",
                status: result.status,
                message: result.combined
            )
        }
    }

    public static func disable(udid: String) async throws {
        guard isInstalled else { throw ShellError.toolNotFound("simslim") }
        let result = try await Shell.run(
            "simslim",
            ["off", udid],
            timeout: 900
        )
        guard result.succeeded else {
            throw ShellError.commandFailed(
                command: "simslim off \(udid)",
                status: result.status,
                message: result.combined
            )
        }
    }
}
