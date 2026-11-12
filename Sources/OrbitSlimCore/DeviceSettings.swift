import Foundation

/// Camera value written to an AVD's `config.ini`.
///
/// `avdDefault` leaves the config untouched. `avdslim start` disables both
/// cameras unless `avdslim.camera=yes` is present, so any explicit camera
/// other than `off` also flips that flag.
public enum AndroidCameraSetting: String, Codable, CaseIterable, Sendable {
    case avdDefault
    case off
    case virtualScene
    case emulated
    case webcam0
    case webcam1

    public var displayName: String {
        switch self {
        case .avdDefault: return "AVD default"
        case .off: return "Off"
        case .virtualScene: return "Virtual scene"
        case .emulated: return "Emulated"
        case .webcam0: return "Webcam 0"
        case .webcam1: return "Webcam 1"
        }
    }

    public var configValue: String? {
        switch self {
        case .avdDefault: return nil
        case .off: return "none"
        case .virtualScene: return "virtualscene"
        case .emulated: return "emulated"
        case .webcam0: return "webcam0"
        case .webcam1: return "webcam1"
        }
    }
}

public enum AndroidAudioSetting: String, Codable, CaseIterable, Sendable {
    case avdDefault
    case enabled
    case disabled

    public var displayName: String {
        switch self {
        case .avdDefault: return "AVD default"
        case .enabled: return "On"
        case .disabled: return "Off"
        }
    }
}

/// Per-AVD launch overrides. `avdDefault`/`nil` values do not touch the AVD.
public struct AndroidLaunchSettings: Codable, Equatable, Sendable {
    public var cameraBack: AndroidCameraSetting
    public var cameraFront: AndroidCameraSetting
    public var audio: AndroidAudioSetting
    public var ramMB: Int?
    public var lowRAM: Bool

    public init(
        cameraBack: AndroidCameraSetting = .avdDefault,
        cameraFront: AndroidCameraSetting = .avdDefault,
        audio: AndroidAudioSetting = .avdDefault,
        ramMB: Int? = nil,
        lowRAM: Bool = true
    ) {
        self.cameraBack = cameraBack
        self.cameraFront = cameraFront
        self.audio = audio
        self.ramMB = ramMB
        self.lowRAM = lowRAM
    }

    /// Values to merge into `<avd>.avd/config.ini`.
    public var avdConfigOverrides: [String: String] {
        var values: [String: String] = [:]
        let back = cameraBack.configValue
        let front = cameraFront.configValue
        if let back { values["hw.camera.back"] = back }
        if let front { values["hw.camera.front"] = front }

        let explicitCameras = [back, front].compactMap { $0 }
        if explicitCameras.contains(where: { $0 != "none" }) {
            values["avdslim.camera"] = "yes"
        } else if explicitCameras.count == 2 {
            values["avdslim.camera"] = "no"
        }

        switch audio {
        case .avdDefault: break
        case .enabled: values["avdslim.audio"] = "yes"
        case .disabled: values["avdslim.audio"] = "no"
        }
        return values
    }

    /// Extra flags accepted by `avdslim start`.
    public var avdslimArguments: [String] {
        var arguments: [String] = []
        if let ramMB { arguments.append("--ram=\(ramMB)") }
        if !lowRAM { arguments.append("--no-lowram") }
        return arguments
    }

    /// Equivalent flags for the stock `emulator` fallback.
    public func emulatorArguments(defaultRAM: Int = 1536) -> [String] {
        var arguments = ["-memory", "\(ramMB ?? defaultRAM)"]
        if lowRAM { arguments.append("-lowram") }
        if audio == .disabled { arguments.append("-no-audio") }
        return arguments
    }
}

/// Per-simulator simslim options passed to `simslim on`.
public struct SimslimSettings: Codable, Equatable, Sendable {
    /// Category IDs passed to `--except` (left running).
    public var exceptCategories: String
    /// Individual launchd labels passed to `--keep`.
    public var keepDaemons: String

    public init(exceptCategories: String = "", keepDaemons: String = "") {
        self.exceptCategories = exceptCategories
        self.keepDaemons = keepDaemons
    }

    public var arguments: [String] {
        var arguments: [String] = []
        let except = Self.normalized(exceptCategories)
        let keep = Self.normalized(keepDaemons)
        if !except.isEmpty { arguments += ["--except", except] }
        if !keep.isEmpty { arguments += ["--keep", keep] }
        return arguments
    }

    private static func normalized(_ value: String) -> String {
        let parts = value.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        return parts.map(String.init).joined(separator: ",")
    }
}

public struct DeviceSettingsFile: Codable, Sendable {
    public var android: [String: AndroidLaunchSettings]
    public var simslim: [String: SimslimSettings]

    public init(
        android: [String: AndroidLaunchSettings] = [:],
        simslim: [String: SimslimSettings] = [:]
    ) {
        self.android = android
        self.simslim = simslim
    }
}

/// Shared JSON store so the app and `orbitslimctl` see the same per-device
/// settings. Kept outside UserDefaults because the two targets have different
/// bundle identifiers.
public enum DeviceSettingsStore {
    public static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["ORBITSLIM_SETTINGS"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/OrbitSlim", isDirectory: true)
            .appendingPathComponent("device-settings.json")
    }

    public static func load() -> DeviceSettingsFile {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(DeviceSettingsFile.self, from: data) else {
            return DeviceSettingsFile()
        }
        return settings
    }

    public static func save(_ settings: DeviceSettingsFile) throws {
        let url = fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
