import CoreAudio
import Foundation
import XCTest
@testable import AudioOrbit

final class DisplayAudioMappingTests: XCTestCase {
    func testPassThroughAndPhysicalDeviceMappingRules() {
        let display = displaySnapshot()
        let passThrough = DisplayAudioMapping.passThrough(display: display)

        XCTAssertTrue(passThrough.isValid)
        XCTAssertEqual(passThrough.behavior, .passThrough)
        XCTAssertNil(passThrough.resolvedDevice(in: [deviceSnapshot()]))

        let routed = DisplayAudioMapping(
            displayUUID: display.id,
            displayNameHint: display.name,
            audioDeviceUID: "output-1",
            audioDeviceNameHint: "Desk Speakers",
            behavior: .routeToDevice
        )
        XCTAssertTrue(routed.isValid)
        XCTAssertEqual(routed.resolvedDevice(in: [deviceSnapshot()])?.uid, "output-1")

        var unavailableDevice = deviceSnapshot()
        unavailableDevice = AudioDeviceSnapshot(
            id: unavailableDevice.id,
            uid: unavailableDevice.uid,
            name: unavailableDevice.name,
            outputChannelCount: unavailableDevice.outputChannelCount,
            nominalSampleRate: unavailableDevice.nominalSampleRate,
            isAlive: false,
            isDefault: unavailableDevice.isDefault
        )
        XCTAssertNil(routed.resolvedDevice(in: [unavailableDevice]))
    }

    func testStoreRoundTripsStableUIDsAndRoutingState() throws {
        let store = try temporaryStore()
        let mapping = DisplayAudioMapping(
            displayUUID: displaySnapshot().id,
            displayNameHint: "Studio Display",
            audioDeviceUID: "output-1",
            audioDeviceNameHint: "Desk Speakers",
            behavior: .routeToDevice
        )
        let configuration = PersistedConfiguration(
            schemaVersion: PersistedConfiguration.currentSchemaVersion,
            mappings: [mapping],
            routingEnabled: true
        )

        try store.save(configuration)
        let result = store.load()

        XCTAssertEqual(result.configuration, configuration)
        XCTAssertNil(result.recoveryNotice)
    }

    func testStoreRoundTripsRememberedRoutesAndHeadphoneOverride() throws {
        let store = try temporaryStore()
        let remembered = CachedApplicationRoute(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            applicationBundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            audioProcessName: "Safari Graphics and Media",
            lastDisplayUUID: displaySnapshot().id,
            lastDisplayName: "Studio Display",
            lastDeviceUID: "output-1",
            lastDeviceName: "Desk Speakers"
        )
        let configuration = PersistedConfiguration(
            schemaVersion: PersistedConfiguration.currentSchemaVersion,
            mappings: [],
            routingEnabled: true,
            cachedRoutes: [remembered],
            ignoredApplications: [
                IgnoredApplication(
                    applicationBundleIdentifier: "com.apple.Music",
                    applicationName: "Music"
                ),
            ],
            headphoneOverrideEnabled: true,
            headphoneOverrideDeviceUID: "headphones-1"
        )

        try store.save(configuration)

        XCTAssertEqual(store.load().configuration, configuration)
    }

    func testVersionOneConfigurationMigratesWithoutLosingMappings() throws {
        let store = try temporaryStore()
        let json = """
        {
          "schemaVersion" : 1,
          "mappings" : [],
          "routingEnabled" : true
        }
        """
        try Data(json.utf8).write(to: store.fileURL)

        let configuration = store.load().configuration

        XCTAssertEqual(configuration.schemaVersion, PersistedConfiguration.currentSchemaVersion)
        XCTAssertTrue(configuration.routingEnabled)
        XCTAssertTrue(configuration.cachedRoutes.isEmpty)
        XCTAssertTrue(configuration.ignoredApplications.isEmpty)
        XCTAssertFalse(configuration.headphoneOverrideEnabled)
        XCTAssertNil(configuration.headphoneOverrideDeviceUID)
    }

    func testVersionTwoConfigurationMigratesWithNoIgnoredApplications() throws {
        let store = try temporaryStore()
        let json = """
        {
          "schemaVersion" : 2,
          "mappings" : [],
          "routingEnabled" : true,
          "cachedRoutes" : [],
          "headphoneOverrideEnabled" : false
        }
        """
        try Data(json.utf8).write(to: store.fileURL)

        let configuration = store.load().configuration

        XCTAssertEqual(configuration.schemaVersion, PersistedConfiguration.currentSchemaVersion)
        XCTAssertTrue(configuration.ignoredApplications.isEmpty)
    }

    func testBluetoothOutputsAreEligibleForHeadphonePresentation() {
        var device = deviceSnapshot()
        device.transportType = kAudioDeviceTransportTypeBluetooth

        XCTAssertTrue(device.isWirelessHeadphone)

        device.transportType = kAudioDeviceTransportTypeUSB
        XCTAssertFalse(device.isWirelessHeadphone)
    }

    func testCorruptStoreFallsBackToPassThroughAndPreservesBackup() throws {
        let store = try temporaryStore()
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: store.fileURL)

        let result = store.load()

        XCTAssertEqual(result.configuration, .safeDefault)
        XCTAssertNotNil(result.recoveryNotice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        let backups = try FileManager.default.contentsOfDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backups.filter { $0.lastPathComponent.contains("corrupt-") }.count, 1)
    }

    func testConfigurationRejectsDuplicateDisplaysAndInvalidNilDeviceRoute() {
        let displayID = displaySnapshot().id
        let invalidRoute = DisplayAudioMapping(
            displayUUID: displayID,
            displayNameHint: "Display",
            audioDeviceUID: nil,
            audioDeviceNameHint: nil,
            behavior: .routeToDevice
        )
        XCTAssertFalse(PersistedConfiguration(
            schemaVersion: 1,
            mappings: [invalidRoute],
            routingEnabled: true
        ).isValid)

        let valid = DisplayAudioMapping(
            displayUUID: displayID,
            displayNameHint: "Display",
            audioDeviceUID: nil,
            audioDeviceNameHint: nil,
            behavior: .passThrough
        )
        XCTAssertFalse(PersistedConfiguration(
            schemaVersion: 1,
            mappings: [valid, valid],
            routingEnabled: false
        ).isValid)

        let ignored = IgnoredApplication(
            applicationBundleIdentifier: "com.apple.Music",
            applicationName: "Music"
        )
        XCTAssertFalse(PersistedConfiguration(
            schemaVersion: PersistedConfiguration.currentSchemaVersion,
            mappings: [],
            routingEnabled: false,
            ignoredApplications: [ignored, ignored]
        ).isValid)
    }

    private func temporaryStore() throws -> MappingStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioOrbitMappingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return MappingStore(fileURL: directory.appendingPathComponent("configuration.json"))
    }

    private func displaySnapshot() -> DisplaySnapshot {
        DisplaySnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            runtimeID: 1,
            name: "Studio Display",
            frame: .init(x: 0, y: 0, width: 1_920, height: 1_080),
            scale: 2,
            isMain: true,
            isBuiltIn: false
        )
    }

    private func deviceSnapshot() -> AudioDeviceSnapshot {
        AudioDeviceSnapshot(
            id: 10,
            uid: "output-1",
            name: "Desk Speakers",
            outputChannelCount: 2,
            nominalSampleRate: 48_000,
            isAlive: true,
            isDefault: false
        )
    }
}
