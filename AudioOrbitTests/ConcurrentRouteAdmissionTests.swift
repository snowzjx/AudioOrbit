import CoreAudio
import XCTest
@testable import AudioOrbit

final class ConcurrentRouteAdmissionTests: XCTestCase {
    func testAllowsDistinctProcessesAndRejectsDuplicateProcessRoutes() {
        let processes = [
            process(id: 10, pid: 100, playing: true),
            process(id: 20, pid: 200, playing: true),
        ]
        let devices = [device(id: 30, uid: "output-a")]

        XCTAssertTrue(ConcurrentRouteAdmission.canStart(
            processID: 20,
            deviceID: 30,
            processes: processes,
            devices: devices,
            activeSourcePIDs: [100]
        ))
        XCTAssertFalse(ConcurrentRouteAdmission.canStart(
            processID: 10,
            deviceID: 30,
            processes: processes,
            devices: devices,
            activeSourcePIDs: [100]
        ))
    }

    func testSuggestionsPreferPlayingUnroutedProcessAndUnusedNondefaultOutput() {
        let processes = [
            process(id: 10, pid: 100, playing: true),
            process(id: 20, pid: 200, playing: true),
            process(id: 30, pid: 300, playing: false),
        ]
        let devices = [
            device(id: 40, uid: "default", isDefault: true),
            device(id: 50, uid: "used"),
            device(id: 60, uid: "unused"),
        ]

        XCTAssertEqual(
            ConcurrentRouteAdmission.suggestedProcessID(
                processes: processes,
                activeSourcePIDs: [100]
            ),
            20
        )
        XCTAssertEqual(
            ConcurrentRouteAdmission.suggestedDeviceID(
                devices: devices,
                activeDestinationUIDs: ["used"]
            ),
            60
        )
    }

    func testUnavailableOutputCannotStartARoute() {
        XCTAssertFalse(ConcurrentRouteAdmission.canStart(
            processID: 10,
            deviceID: 20,
            processes: [process(id: 10, pid: 100, playing: true)],
            devices: [device(id: 20, uid: "missing", isAlive: false)],
            activeSourcePIDs: []
        ))
    }

    private func process(id: AudioObjectID, pid: pid_t, playing: Bool) -> AudioProcessSnapshot {
        AudioProcessSnapshot(
            id: id,
            pid: pid,
            bundleIdentifier: "test.\(pid)",
            name: "Process \(pid)",
            isRunningOutput: playing
        )
    }

    private func device(
        id: AudioObjectID,
        uid: String,
        isAlive: Bool = true,
        isDefault: Bool = false
    ) -> AudioDeviceSnapshot {
        AudioDeviceSnapshot(
            id: id,
            uid: uid,
            name: uid,
            outputChannelCount: 2,
            nominalSampleRate: 48_000,
            isAlive: isAlive,
            isDefault: isDefault
        )
    }
}
