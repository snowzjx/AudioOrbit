import CoreAudio
import Foundation

enum DisplayAudioBehavior: String, Codable, Equatable, Sendable {
    case routeToDevice
    case passThrough
}

struct DisplayAudioMapping: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { displayUUID }

    let displayUUID: UUID
    var displayNameHint: String
    var audioDeviceUID: String?
    var audioDeviceNameHint: String?
    var behavior: DisplayAudioBehavior

    static func passThrough(display: DisplaySnapshot) -> DisplayAudioMapping {
        DisplayAudioMapping(
            displayUUID: display.id,
            displayNameHint: display.name,
            audioDeviceUID: nil,
            audioDeviceNameHint: nil,
            behavior: .passThrough
        )
    }

    var isValid: Bool {
        switch behavior {
        case .passThrough:
            audioDeviceUID == nil
        case .routeToDevice:
            audioDeviceUID?.isEmpty == false
        }
    }

    func resolvedDevice(in devices: [AudioDeviceSnapshot]) -> AudioDeviceSnapshot? {
        guard behavior == .routeToDevice, let audioDeviceUID else { return nil }
        return devices.first { $0.uid == audioDeviceUID && $0.isAlive }
    }
}

enum DisplayMappingSelection: Hashable, Sendable {
    case passThrough
    case device(uid: String)
}

struct DisplayMappingRow: Identifiable, Equatable, Sendable {
    let displayUUID: UUID
    let displayName: String
    let isDisplayConnected: Bool
    let isBuiltIn: Bool
    let selection: DisplayMappingSelection
    let unavailableDeviceName: String?

    var id: UUID { displayUUID }
}

struct CachedApplicationRoute: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let applicationBundleIdentifier: String
    var applicationName: String
    var audioProcessName: String
    var lastDisplayUUID: UUID?
    var lastDisplayName: String?
    var lastDeviceUID: String
    var lastDeviceName: String
}

struct PersistedConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var mappings: [DisplayAudioMapping]
    var routingEnabled: Bool
    var cachedRoutes: [CachedApplicationRoute]
    var headphoneOverrideEnabled: Bool
    var headphoneOverrideDeviceUID: String?

    init(
        schemaVersion: Int,
        mappings: [DisplayAudioMapping],
        routingEnabled: Bool,
        cachedRoutes: [CachedApplicationRoute] = [],
        headphoneOverrideEnabled: Bool = false,
        headphoneOverrideDeviceUID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.mappings = mappings
        self.routingEnabled = routingEnabled
        self.cachedRoutes = cachedRoutes
        self.headphoneOverrideEnabled = headphoneOverrideEnabled
        self.headphoneOverrideDeviceUID = headphoneOverrideDeviceUID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mappings
        case routingEnabled
        case cachedRoutes
        case headphoneOverrideEnabled
        case headphoneOverrideDeviceUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        mappings = try container.decode([DisplayAudioMapping].self, forKey: .mappings)
        routingEnabled = try container.decode(Bool.self, forKey: .routingEnabled)
        cachedRoutes = try container.decodeIfPresent(
            [CachedApplicationRoute].self,
            forKey: .cachedRoutes
        ) ?? []
        headphoneOverrideEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .headphoneOverrideEnabled
        ) ?? false
        headphoneOverrideDeviceUID = try container.decodeIfPresent(
            String.self,
            forKey: .headphoneOverrideDeviceUID
        )
    }

    static let safeDefault = PersistedConfiguration(
        schemaVersion: currentSchemaVersion,
        mappings: [],
        routingEnabled: false,
        cachedRoutes: [],
        headphoneOverrideEnabled: false,
        headphoneOverrideDeviceUID: nil
    )

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && mappings.allSatisfy(\.isValid)
            && Set(mappings.map(\.displayUUID)).count == mappings.count
            && cachedRoutes.allSatisfy {
                !$0.applicationBundleIdentifier.isEmpty && !$0.lastDeviceUID.isEmpty
            }
            && Set(cachedRoutes.map(\.applicationBundleIdentifier)).count == cachedRoutes.count
            && (!headphoneOverrideEnabled
                || headphoneOverrideDeviceUID?.isEmpty == false)
    }
}

struct ConfigurationLoadResult: Sendable {
    let configuration: PersistedConfiguration
    let recoveryNotice: String?
}

struct MappingStore: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.fileURL = applicationSupport
                .appendingPathComponent("AudioOrbit", isDirectory: true)
                .appendingPathComponent("configuration-v1.json")
        }
    }

    func load() -> ConfigurationLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ConfigurationLoadResult(configuration: .safeDefault, recoveryNotice: nil)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            var decoded = try JSONDecoder().decode(PersistedConfiguration.self, from: data)
            if decoded.schemaVersion == 1 {
                decoded.schemaVersion = PersistedConfiguration.currentSchemaVersion
            }
            guard decoded.isValid else {
                throw MappingStoreError.unsupportedOrInvalidConfiguration
            }
            return ConfigurationLoadResult(configuration: decoded, recoveryNotice: nil)
        } catch {
            let backupURL = fileURL
                .deletingPathExtension()
                .appendingPathExtension("corrupt-\(UUID().uuidString).json")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            return ConfigurationLoadResult(
                configuration: .safeDefault,
                recoveryNotice: "AudioOrbit found an unreadable display mapping file, preserved it for recovery, and loaded safe pass-through defaults."
            )
        }
    }

    func save(_ configuration: PersistedConfiguration) throws {
        guard configuration.isValid else {
            throw MappingStoreError.unsupportedOrInvalidConfiguration
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
    }
}

enum MappingStoreError: Error, CustomStringConvertible {
    case unsupportedOrInvalidConfiguration

    var description: String {
        "The display mapping configuration is invalid or belongs to an unsupported version."
    }
}
