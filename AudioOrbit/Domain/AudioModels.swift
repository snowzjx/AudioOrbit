import CoreAudio
import Foundation

struct AudioDeviceSnapshot: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let outputChannelCount: UInt32
    let nominalSampleRate: Double
    var transportType: UInt32 = kAudioDeviceTransportTypeUnknown
    var volumeScalar: Float? = nil
    var isVolumeSettable: Bool = false
    let isAlive: Bool
    let isDefault: Bool

    var isWirelessHeadphone: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

struct AudioProcessSnapshot: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String
    let isRunningOutput: Bool
}

struct AudioDiscoverySnapshot: Sendable {
    let devices: [AudioDeviceSnapshot]
    let processes: [AudioProcessSnapshot]
}

enum TapProbeState: Equatable, Sendable {
    case idle
    case starting
    case running
    case switching
    case stopping
    case waitingForDestination
    case reconnecting
    case failed
}

struct TapProbeMetrics: Equatable, Sendable {
    var callbackCount: UInt64 = 0
    var rendererCallbackCount: UInt64 = 0
    var captureRequestedFrameCount: UInt64 = 0
    var renderRequestedFrameCount: UInt64 = 0
    var capturedFrameCount: UInt64 = 0
    var renderedFrameCount: UInt64 = 0
    var nonSilentFrameCount: UInt64 = 0
    var consumedSourceFrameCount: UInt64 = 0
    var queuedFrameCount: UInt64 = 0
    var maximumQueuedFrameCount: UInt64 = 0
    var capacityFrameCount: UInt32 = 0
    var underflowCount: UInt64 = 0
    var underflowFrameCount: UInt64 = 0
    var overflowCount: UInt64 = 0
    var overflowFrameCount: UInt64 = 0
    var targetQueuedFrameCount: UInt32 = 0
    var isPrimed = false
    var sourceSampleRate: Double = 0
    var outputSampleRate: Double = 0
    var rateCorrectionPPM: Double = 0

    var hasCallbacks: Bool { callbackCount > 0 }
    var hasRenderedFrames: Bool { renderedFrameCount > 0 }
}

enum AudioRouteHealthLevel: Equatable, Sendable {
    case observing
    case healthy
    case needsAttention
}

struct AudioRouteHealth: Equatable, Sendable {
    var level: AudioRouteHealthLevel = .observing
    var measuredSeconds: Double = 0
    var estimatedClockDriftPPM: Double?
    var underflowFrameCount: UInt64 = 0
    var overflowFrameCount: UInt64 = 0
    var maximumQueuedFrameCount: UInt64 = 0
    var capacityFrameCount: UInt32 = 0

    var maximumQueueFillRatio: Double {
        guard capacityFrameCount > 0 else { return 0 }
        return min(1, Double(maximumQueuedFrameCount) / Double(capacityFrameCount))
    }
}

struct ProbeRouteSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourcePID: pid_t
    let sourceName: String
    let audioProcessName: String
    var applicationBundleIdentifier: String? = nil
    var isAutomatic: Bool = false
    var isCached: Bool = false
    var followedDisplayName: String?
    var destinationDeviceID: AudioObjectID?
    var destinationUID: String
    var destinationName: String
    var state: TapProbeState
    var metrics: TapProbeMetrics = TapProbeMetrics()
    var health: AudioRouteHealth = AudioRouteHealth()
    var notice: String?
    var error: String?
    var requiresCleanupRetry = false
    var supportsManualReanchor = false

    var isRecovering: Bool {
        state == .waitingForDestination || state == .reconnecting
    }
}

enum AudioRouteProbeError: Error, CustomStringConvertible {
    case unsupportedTapFormat(String)
    case destinationUnavailable
    case invalidDestinationSampleRate
    case unableToAllocateBridge
    case gainRampTimedOut
    case routeLifecycleChanged

    var description: String {
        switch self {
        case .unsupportedTapFormat(let details):
            "The process tap uses an unsupported format (\(details)). This spike currently requires 32-bit floating-point mono or stereo PCM."
        case .destinationUnavailable:
            "The selected output is not currently alive. Reconnect it, press Refresh, and try again."
        case .invalidDestinationSampleRate:
            "The selected output did not report a usable sample rate. Reconnect it or choose another output."
        case .unableToAllocateBridge:
            "AudioOrbit could not allocate the bounded real-time audio buffer."
        case .gainRampTimedOut:
            "The output did not complete its safety ramp in time. The existing route was retained."
        case .routeLifecycleChanged:
            "The route changed while an output switch was in progress. AudioOrbit safely cancelled the switch."
        }
    }
}
