import CoreAudio
import Foundation
import XCTest
@testable import AudioOrbit

final class DiagnosticsTests: XCTestCase {
    func testRecorderIsBoundedAndKeepsNewestEvents() {
        let recorder = DiagnosticsRecorder(capacity: 2)
        recorder.record("first", category: "test")
        recorder.record("second", category: "test")
        recorder.record("third", category: "test")

        XCTAssertEqual(recorder.snapshot().map(\.code), ["second", "third"])
    }

    func testSupportReportContainsHealthButRedactsIdentity() {
        let privateDeviceName = "Snow's Secret Studio Output"
        let privateDeviceUID = "private-device-uid"
        let privateApplicationName = "Confidential Player"
        let privateBundleID = "com.example.confidential"
        let privateDisplayName = "Private Office Display"
        let device = AudioDeviceSnapshot(
            id: 42,
            uid: privateDeviceUID,
            name: privateDeviceName,
            outputChannelCount: 2,
            nominalSampleRate: 48_000,
            transportType: kAudioDeviceTransportTypeUSB,
            volumeScalar: 0.5,
            isVolumeSettable: true,
            isAlive: true,
            isDefault: false
        )
        var metrics = TapProbeMetrics()
        metrics.sourceSampleRate = 44_100
        metrics.outputSampleRate = 48_000
        metrics.targetQueuedFrameCount = 2_048
        metrics.capacityFrameCount = 16_384
        metrics.queuedFrameCount = 2_100
        metrics.maximumQueuedFrameCount = 3_000
        metrics.underflowFrameCount = 12
        let route = ProbeRouteSnapshot(
            id: UUID(),
            sourcePID: 1234,
            sourceName: privateApplicationName,
            audioProcessName: privateApplicationName,
            applicationBundleIdentifier: privateBundleID,
            isAutomatic: true,
            followedDisplayName: privateDisplayName,
            destinationDeviceID: device.id,
            destinationUID: privateDeviceUID,
            destinationName: privateDeviceName,
            state: .running,
            metrics: metrics
        )

        let report = SupportReportBuilder.makeReport(SupportReportInput(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "1.0",
            appBuild: "1",
            operatingSystem: "Test OS",
            appUptimeSeconds: 65,
            accessibilityGranted: true,
            routingEnabled: true,
            displayCount: 2,
            managedDisplayCount: 1,
            headphoneOverrideArmed: true,
            headphoneOverrideActive: false,
            devices: [device],
            routes: [route],
            resources: ProcessResourceSnapshot(
                residentMemoryBytes: 1_024,
                userCPUSeconds: 1,
                systemCPUSeconds: 2
            ),
            events: [DiagnosticEvent(
                timestamp: Date(timeIntervalSince1970: 1),
                level: .warning,
                category: "route",
                code: "buffer-pressure"
            )]
        ))

        XCTAssertTrue(report.contains("Output 1"))
        XCTAssertTrue(report.contains("underflow-frames=12"))
        XCTAssertTrue(report.contains("route.buffer-pressure"))
        XCTAssertFalse(report.contains(privateDeviceName))
        XCTAssertFalse(report.contains(privateDeviceUID))
        XCTAssertFalse(report.contains(privateApplicationName))
        XCTAssertFalse(report.contains(privateBundleID))
        XCTAssertFalse(report.contains(privateDisplayName))
        XCTAssertFalse(report.contains("1234"))
    }
}
