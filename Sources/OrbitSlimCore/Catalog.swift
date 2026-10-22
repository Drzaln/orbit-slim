import Foundation

public enum DeviceCatalog {
    /// Fetches simulators and AVDs in parallel, attaches slim state, and keeps
    /// partial failures from blanking the UI.
    public static func load() async -> CatalogSnapshot {
        async let simulatorTask = loadSimulators()
        async let emulatorTask = AndroidService.snapshot()
        let (simResult, emulators) = await (simulatorTask, emulatorTask)

        return CatalogSnapshot(
            simulators: simResult.devices,
            emulators: emulators,
            errors: simResult.errors
        )
    }

    private static func loadSimulators() async -> (devices: [SimulatorDevice], errors: [String]) {
        do {
            var devices = try await SimctlService.list()
            await withTaskGroup(of: (Int, SlimState).self) { group in
                for (index, device) in devices.enumerated() {
                    group.addTask {
                        (index, await SimslimService.status(for: device))
                    }
                }
                for await (index, slim) in group {
                    devices[index].slim = slim
                }
            }
            return (devices, [])
        } catch {
            return ([], [error.localizedDescription])
        }
    }
}
