import Foundation

public enum DevicePlatform: String, Codable, Sendable {
    case ios
    case android

    public var displayName: String {
        switch self {
        case .ios: return "iOS"
        case .android: return "Android"
        }
    }

    public var installExtension: String {
        switch self {
        case .ios: return "app"
        case .android: return "apk"
        }
    }
}

/// How slim a simulator/emulator currently is.
public enum SlimState: Equatable, Sendable {
    case unknown
    /// No managed daemons/packages disabled.
    case stock
    /// Some, but not all, slim overrides applied. `total == 0` means the tool
    /// cannot report a total for this platform.
    case partial(disabled: Int, total: Int)
    case slim

    public var isSlim: Bool {
        if case .slim = self { return true }
        return false
    }

    public var needsSlimming: Bool {
        switch self {
        case .slim: return false
        case .unknown, .stock, .partial: return true
        }
    }

    public var label: String {
        switch self {
        case .unknown: return "—"
        case .stock: return "Stock"
        case .partial(let disabled, let total):
            return total > 0 ? "Partial \(disabled)/\(total)" : "Partial (\(disabled) off)"
        case .slim: return "Slim"
        }
    }
}

public struct SimulatorDevice: Identifiable, Sendable {
    public let udid: String
    public let name: String
    public let runtimeName: String
    public let platformName: String
    public let state: String
    public var slim: SlimState

    public var id: String { udid }
    public var isBooted: Bool { state == "Booted" }
    public var platform: DevicePlatform { .ios }
    public var isAvailable: Bool { true }

    public init(
        udid: String,
        name: String,
        runtimeName: String,
        platformName: String,
        state: String,
        slim: SlimState = .unknown
    ) {
        self.udid = udid
        self.name = name
        self.runtimeName = runtimeName
        self.platformName = platformName
        self.state = state
        self.slim = slim
    }
}

public struct AndroidDevice: Identifiable, Sendable {
    public let avdName: String
    public var serial: String?
    public var memoryMB: Int?
    public var slim: SlimState

    public var id: String { avdName }
    public var isRunning: Bool { serial != nil }
    public var platform: DevicePlatform { .android }
    public var stateLabel: String { isRunning ? "Running" : "Stopped" }

    public init(
        avdName: String,
        serial: String? = nil,
        memoryMB: Int? = nil,
        slim: SlimState = .unknown
    ) {
        self.avdName = avdName
        self.serial = serial
        self.memoryMB = memoryMB
        self.slim = slim
    }
}

public struct CatalogSnapshot: Sendable {
    public var simulators: [SimulatorDevice]
    public var emulators: [AndroidDevice]
    public var errors: [String]

    public init(
        simulators: [SimulatorDevice] = [],
        emulators: [AndroidDevice] = [],
        errors: [String] = []
    ) {
        self.simulators = simulators
        self.emulators = emulators
        self.errors = errors
    }
}

public struct InstalledApp: Identifiable, Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let version: String?
    public let isSystem: Bool

    public var id: String { bundleID }

    public init(bundleID: String, name: String, version: String? = nil, isSystem: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.isSystem = isSystem
    }
}
