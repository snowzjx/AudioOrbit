import CoreAudio
import Darwin
import Foundation
import OSLog

enum DiagnosticEventLevel: String, Sendable {
    case info
    case warning
    case error
}

struct DiagnosticEvent: Equatable, Sendable {
    let timestamp: Date
    let level: DiagnosticEventLevel
    let category: String
    let code: String
}

final class DiagnosticsRecorder: @unchecked Sendable {
    static let shared = DiagnosticsRecorder()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.snowzjx.AudioOrbit",
        category: "Lifecycle"
    )
    private let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "me.snowzjx.AudioOrbit",
        category: "Performance"
    )
    private let lock = NSLock()
    private let capacity: Int
    private var events: [DiagnosticEvent] = []

    init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    func record(
        _ code: String,
        category: String,
        level: DiagnosticEventLevel = .info,
        timestamp: Date = Date()
    ) {
        let event = DiagnosticEvent(
            timestamp: timestamp,
            level: level,
            category: category,
            code: code
        )
        lock.lock()
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        lock.unlock()

        switch level {
        case .info:
            // Routine activity stays only in the bounded in-memory support
            // report. Do not persist playback/routing behavior to macOS's
            // unified log by default.
            break
        case .warning:
            logger.warning("\(category, privacy: .public).\(code, privacy: .public)")
        case .error:
            logger.error("\(category, privacy: .public).\(code, privacy: .public)")
        }
    }

    func snapshot() -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func markRefresh() {
        signposter.emitEvent("Hardware refresh")
    }

    func markRouteTransition() {
        signposter.emitEvent("Route transition")
    }
}

struct ProcessResourceSnapshot: Equatable, Sendable {
    let residentMemoryBytes: UInt64
    let userCPUSeconds: Double
    let systemCPUSeconds: Double

    static func current() -> ProcessResourceSnapshot {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return ProcessResourceSnapshot(
                residentMemoryBytes: 0,
                userCPUSeconds: 0,
                systemCPUSeconds: 0
            )
        }
        return ProcessResourceSnapshot(
            residentMemoryBytes: UInt64(max(0, usage.ru_maxrss)),
            userCPUSeconds: seconds(usage.ru_utime),
            systemCPUSeconds: seconds(usage.ru_stime)
        )
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}

struct SupportReportInput: Sendable {
    let generatedAt: Date
    let appVersion: String
    let appBuild: String
    let operatingSystem: String
    let appUptimeSeconds: TimeInterval
    let accessibilityGranted: Bool
    let routingEnabled: Bool
    let displayCount: Int
    let managedDisplayCount: Int
    let headphoneOverrideArmed: Bool
    let headphoneOverrideActive: Bool
    let devices: [AudioDeviceSnapshot]
    let routes: [ProbeRouteSnapshot]
    let resources: ProcessResourceSnapshot
    let events: [DiagnosticEvent]
}

enum SupportReportBuilder {
    static func makeReport(_ input: SupportReportInput) -> String {
        let liveRoutes = input.routes.filter { !$0.isCached }
        var outputIndexByUID: [String: Int] = [:]
        for (index, device) in input.devices.enumerated() {
            outputIndexByUID[device.uid] = index + 1
        }

        var lines = [
            "AudioOrbit Support Report",
            "=========================",
            "",
            "Privacy: This report contains no audio, application names, bundle identifiers, process IDs, device names or UIDs, display names or IDs, window titles, document paths, or user file paths.",
            "",
            "Generated: \(iso8601(input.generatedAt))",
            "App version: \(input.appVersion) (\(input.appBuild))",
            "macOS: \(input.operatingSystem)",
            "App uptime: \(formatDuration(input.appUptimeSeconds))",
            "Accessibility: \(input.accessibilityGranted ? "granted" : "not granted")",
            "Automatic routing: \(input.routingEnabled ? "enabled" : "disabled")",
            "Connected displays: \(input.displayCount)",
            "Mapped displays: \(input.managedDisplayCount)",
            "Connected outputs: \(input.devices.filter(\.isAlive).count)",
            "Live routes: \(liveRoutes.count)",
            "Headphone Override: \(input.headphoneOverrideActive ? "active" : (input.headphoneOverrideArmed ? "armed" : "off"))",
            "",
            "App resources",
            "-------------",
            "Resident memory: \(formatBytes(input.resources.residentMemoryBytes))",
            "User CPU time: \(formatDecimal(input.resources.userCPUSeconds)) s",
            "System CPU time: \(formatDecimal(input.resources.systemCPUSeconds)) s",
            "",
            "Outputs",
            "-------"
        ]

        if input.devices.isEmpty {
            lines.append("None discovered")
        } else {
            for (index, device) in input.devices.enumerated() {
                lines.append(
                    "Output \(index + 1): transport=\(transportName(device.transportType)), alive=\(yesNo(device.isAlive)), default=\(yesNo(device.isDefault)), channels=\(device.outputChannelCount), rate=\(formatRate(device.nominalSampleRate)), software-volume=\(yesNo(device.isVolumeSettable))"
                )
            }
        }

        lines.append(contentsOf: ["", "Routes", "------"])
        if liveRoutes.isEmpty {
            lines.append("None active")
        } else {
            for (index, route) in liveRoutes.enumerated() {
                let destination = outputIndexByUID[route.destinationUID]
                    .map { "Output \($0)" } ?? "unavailable output"
                let estimatedLatencyMilliseconds: Double
                if route.metrics.outputSampleRate > 0 {
                    estimatedLatencyMilliseconds = Double(
                        route.metrics.targetQueuedFrameCount
                    ) / route.metrics.outputSampleRate * 1_000
                } else {
                    estimatedLatencyMilliseconds = 0
                }
                lines.append(
                    "Route \(index + 1): state=\(stateName(route.state)), destination=\(destination), source-rate=\(formatRate(route.metrics.sourceSampleRate)), output-rate=\(formatRate(route.metrics.outputSampleRate)), estimated-buffer-latency=\(formatDecimal(estimatedLatencyMilliseconds)) ms, queue=\(route.metrics.queuedFrameCount)/\(route.metrics.capacityFrameCount), peak=\(route.metrics.maximumQueuedFrameCount), correction=\(formatSigned(route.metrics.rateCorrectionPPM)) ppm, underflow-frames=\(route.metrics.underflowFrameCount), overflow-frames=\(route.metrics.overflowFrameCount)"
                )
            }
        }

        lines.append(contentsOf: ["", "Recent coded events", "-------------------"])
        if input.events.isEmpty {
            lines.append("None recorded in this launch")
        } else {
            for event in input.events.suffix(100) {
                lines.append(
                    "\(iso8601(event.timestamp)) [\(event.level.rawValue)] \(event.category).\(event.code)"
                )
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private static func formatDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func formatSigned(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }

    private static func formatRate(_ value: Double) -> String {
        value > 0 ? String(format: "%.0f Hz", value) : "unknown"
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func transportName(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth: "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: "Bluetooth LE"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        default: "other"
        }
    }

    private static func stateName(_ state: TapProbeState) -> String {
        switch state {
        case .idle: "idle"
        case .starting: "starting"
        case .running: "running"
        case .switching: "switching"
        case .stopping: "stopping"
        case .waitingForDestination: "waiting-for-output"
        case .reconnecting: "reconnecting"
        case .failed: "failed"
        }
    }
}
