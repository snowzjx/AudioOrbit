import CoreAudio
import XCTest
@testable import AudioOrbit

final class ProcessWindowAssociationTests: XCTestCase {
    func testRegularAudioProcessUsesItsOwnWindow() throws {
        let music = application(pid: 100, bundle: "com.apple.Music", name: "Music")
        let association = try XCTUnwrap(ProcessWindowAssociationPolicy.resolve(
            audioProcess: audioProcess(pid: 100, bundle: "com.apple.Music", name: "Music"),
            applications: [music],
            parentPID: { _ in nil }
        ))

        XCTAssertEqual(association.windowOwner, music)
        XCTAssertEqual(association.reason, .sameProcess)
    }

    func testSafariMediaHelperUsesParentSafariWindow() throws {
        let safari = application(pid: 200, bundle: "com.apple.Safari", name: "Safari")
        let association = try XCTUnwrap(ProcessWindowAssociationPolicy.resolve(
            audioProcess: audioProcess(
                pid: 220,
                bundle: "com.apple.WebKit.GPU",
                name: "Safari Graphics and Media"
            ),
            applications: [safari],
            parentPID: { pid in pid == 220 ? 200 : nil }
        ))

        XCTAssertEqual(association.windowOwner, safari)
        XCTAssertEqual(association.reason, .parentApplication)
        XCTAssertEqual(association.audioProcess.pid, 220)
    }

    func testLaunchdOwnedSystemSafariMediaHelperUsesSafariWindow() throws {
        let safari = application(pid: 200, bundle: "com.apple.Safari", name: "Safari")
        let association = try XCTUnwrap(ProcessWindowAssociationPolicy.resolve(
            audioProcess: audioProcess(
                pid: 220,
                bundle: "com.apple.WebKit.GPU",
                name: "Safari Graphics and Media"
            ),
            applications: [safari],
            parentPID: { _ in 1 },
            allowsSystemWebKitClientAssociation: true
        ))

        XCTAssertEqual(association.windowOwner, safari)
        XCTAssertEqual(association.reason, .systemWebKitClient)
    }

    func testUntrustedSafariNamedHelperIsNotAssociated() {
        let safari = application(pid: 200, bundle: "com.apple.Safari", name: "Safari")
        XCTAssertNil(ProcessWindowAssociationPolicy.resolve(
            audioProcess: audioProcess(
                pid: 220,
                bundle: "example.fake.helper",
                name: "Safari Graphics and Media"
            ),
            applications: [safari],
            parentPID: { _ in 1 },
            allowsSystemWebKitClientAssociation: false
        ))
    }

    func testSystemWebKitHelperUsesLongestUniqueApplicationPrefix() throws {
        let safari = application(pid: 200, bundle: "com.apple.Safari", name: "Safari")
        let preview = application(
            pid: 201,
            bundle: "com.apple.SafariTechnologyPreview",
            name: "Safari Technology Preview"
        )
        let association = try XCTUnwrap(ProcessWindowAssociationPolicy.resolve(
            audioProcess: audioProcess(
                pid: 220,
                bundle: "com.apple.WebKit.GPU",
                name: "Safari Technology Preview Graphics and Media"
            ),
            applications: [safari, preview],
            parentPID: { _ in 1 },
            allowsSystemWebKitClientAssociation: true
        ))

        XCTAssertEqual(association.windowOwner, preview)
        XCTAssertEqual(association.reason, .systemWebKitClient)
    }

    func testUniqueMatchingBundleAssociatesHelperWithoutNameMatching() throws {
        let safari = application(pid: 200, bundle: "com.apple.Safari", name: "Safari")
        let association = try XCTUnwrap(ProcessWindowAssociationPolicy.resolve(
            audioProcess: audioProcess(
                pid: 220,
                bundle: "com.apple.Safari",
                name: "Localized helper name can differ"
            ),
            applications: [safari],
            parentPID: { _ in nil }
        ))

        XCTAssertEqual(association.windowOwner, safari)
        XCTAssertEqual(association.reason, .matchingBundle)
    }

    func testAmbiguousBundleDoesNotCaptureAnUnrelatedApplication() {
        let first = application(pid: 200, bundle: "example.browser", name: "Browser A")
        let second = application(pid: 201, bundle: "example.browser", name: "Browser B")

        XCTAssertNil(ProcessWindowAssociationPolicy.resolve(
            audioProcess: audioProcess(pid: 220, bundle: "example.browser", name: "Helper"),
            applications: [first, second],
            parentPID: { _ in nil }
        ))
    }

    func testUnrelatedHelperIsNotMatchedBySimilarDisplayName() {
        let safari = application(pid: 200, bundle: "com.apple.Safari", name: "Safari")

        XCTAssertNil(ProcessWindowAssociationPolicy.resolve(
            audioProcess: audioProcess(
                pid: 220,
                bundle: "unrelated.helper",
                name: "Safari Graphics and Media"
            ),
            applications: [safari],
            parentPID: { _ in nil }
        ))
    }

    func testTwoPlayingApplicationsResolveIndependentMappedTargets() throws {
        let leftID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let rightID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let displays = [
            display(id: leftID, name: "Left"),
            display(id: rightID, name: "Right"),
        ]
        let devices = [
            device(id: 10, uid: "left-output"),
            device(id: 20, uid: "right-output"),
        ]
        let mappings = [
            mapping(displayID: leftID, device: devices[0]),
            mapping(displayID: rightID, device: devices[1]),
        ]
        let musicSource = audioProcess(pid: 100, bundle: "music", name: "Music")
        let safariSource = audioProcess(pid: 220, bundle: "webkit", name: "Safari Media")
        let musicAssociation = ProcessWindowAssociation(
            audioProcess: musicSource,
            windowOwner: application(pid: 100, bundle: "music", name: "Music"),
            reason: .sameProcess
        )
        let safariAssociation = ProcessWindowAssociation(
            audioProcess: safariSource,
            windowOwner: application(pid: 200, bundle: "safari", name: "Safari"),
            reason: .parentApplication
        )

        let targets = [
            AutomaticRouteTargetPolicy.resolve(
                source: musicSource,
                association: musicAssociation,
                evidence: evidence(source: musicSource, owner: musicAssociation.windowOwner, display: displays[0]),
                displays: displays,
                mappings: mappings,
                devices: devices
            ),
            AutomaticRouteTargetPolicy.resolve(
                source: safariSource,
                association: safariAssociation,
                evidence: evidence(source: safariSource, owner: safariAssociation.windowOwner, display: displays[1]),
                displays: displays,
                mappings: mappings,
                devices: devices
            ),
        ].compactMap { $0 }

        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(Set(targets.map(\.sourcePID)), [100, 220])
        XCTAssertEqual(Set(targets.map(\.destinationDeviceUID)), ["left-output", "right-output"])
    }

    private func audioProcess(
        pid: pid_t,
        bundle: String,
        name: String
    ) -> AudioProcessSnapshot {
        AudioProcessSnapshot(
            id: AudioObjectID(pid),
            pid: pid,
            bundleIdentifier: bundle,
            name: name,
            isRunningOutput: true
        )
    }

    private func application(
        pid: pid_t,
        bundle: String,
        name: String
    ) -> WindowOwnerSnapshot {
        WindowOwnerSnapshot(
            pid: pid,
            bundleIdentifier: bundle,
            name: name,
            isRegularApplication: true
        )
    }

    private func display(id: UUID, name: String) -> DisplaySnapshot {
        DisplaySnapshot(
            id: id,
            runtimeID: 1,
            name: name,
            frame: .init(x: 0, y: 0, width: 1_000, height: 800),
            scale: 2,
            isMain: false,
            isBuiltIn: false
        )
    }

    private func device(id: AudioObjectID, uid: String) -> AudioDeviceSnapshot {
        AudioDeviceSnapshot(
            id: id,
            uid: uid,
            name: uid,
            outputChannelCount: 2,
            nominalSampleRate: 48_000,
            isAlive: true,
            isDefault: false
        )
    }

    private func mapping(
        displayID: UUID,
        device: AudioDeviceSnapshot
    ) -> DisplayAudioMapping {
        DisplayAudioMapping(
            displayUUID: displayID,
            displayNameHint: "Display",
            audioDeviceUID: device.uid,
            audioDeviceNameHint: device.name,
            behavior: .routeToDevice
        )
    }

    private func evidence(
        source: AudioProcessSnapshot,
        owner: WindowOwnerSnapshot,
        display: DisplaySnapshot
    ) -> WindowDisplayEvidence {
        WindowDisplayEvidence(
            sourcePID: source.pid,
            sourceName: owner.name,
            audioProcessName: source.name,
            windowOwnerPID: owner.pid,
            associationReason: source.pid == owner.pid ? .sameProcess : .parentApplication,
            eligibleWindowCount: 1,
            selectedWindowIdentifier: "window",
            selectionSource: .focused,
            windowFrame: .init(x: 0, y: 0, width: 500, height: 500),
            displayUUID: display.id,
            displayName: display.name,
            issue: nil
        )
    }
}
