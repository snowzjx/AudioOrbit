import CoreAudio
import Foundation

final class ProcessTapProbe {
    private static let ringCapacityFrames: UInt32 = 16_384
    private static let gainRampSeconds = 0.025

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var bridge: OpaquePointer?
    private var outputRenderer: PhysicalOutputRenderer?
    private var tapFormat: AudioStreamBasicDescription?
    private var gainRampFrames: UInt32 = 0
    private(set) var currentDestinationDeviceID: AudioObjectID?

    var isRunning: Bool { ioProcID != nil }
    var hasActiveRoute: Bool {
        isRunning && outputRenderer != nil && bridge != nil
    }
    var requiresCleanup: Bool {
        ioProcID != nil
            || outputRenderer != nil
            || bridge != nil
            || aggregateDeviceID != kAudioObjectUnknown
            || tapID != kAudioObjectUnknown
    }
    var isNormalPlaybackRestored: Bool {
        tapID == kAudioObjectUnknown
    }

    deinit {
        try? stop()
    }

    func metricsSnapshot() -> TapProbeMetrics {
        let bridgeSnapshot = bridge.map(AOAudioBridgeRead) ?? AOAudioBridgeSnapshot()
        return TapProbeMetrics(
            callbackCount: bridgeSnapshot.captureCallbackCount,
            rendererCallbackCount: bridgeSnapshot.renderCallbackCount,
            captureRequestedFrameCount: bridgeSnapshot.captureRequestedFrameCount,
            renderRequestedFrameCount: bridgeSnapshot.renderRequestedFrameCount,
            capturedFrameCount: bridgeSnapshot.capturedFrameCount,
            renderedFrameCount: bridgeSnapshot.renderedFrameCount,
            consumedSourceFrameCount: bridgeSnapshot.consumedSourceFrameCount,
            queuedFrameCount: bridgeSnapshot.queuedFrameCount,
            maximumQueuedFrameCount: bridgeSnapshot.maximumQueuedFrameCount,
            capacityFrameCount: bridgeSnapshot.capacityFrameCount,
            underflowCount: bridgeSnapshot.underflowCount,
            underflowFrameCount: bridgeSnapshot.underflowFrameCount,
            overflowCount: bridgeSnapshot.overflowCount,
            overflowFrameCount: bridgeSnapshot.overflowFrameCount,
            targetQueuedFrameCount: bridgeSnapshot.targetQueuedFrameCount,
            isPrimed: bridgeSnapshot.isPrimed != 0,
            sourceSampleRate: bridgeSnapshot.sourceSampleRate,
            outputSampleRate: bridgeSnapshot.outputSampleRate,
            rateCorrectionPPM: Double(bridgeSnapshot.rateCorrectionPPM)
        )
    }

    func resetHealthObservationWindow() {
        if let bridge {
            AOAudioBridgeResetQueueWatermark(bridge)
        }
    }

    func start(
        processObjectID: AudioObjectID,
        destinationDeviceID: AudioObjectID
    ) throws {
        guard !isRunning else { return }

        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "AudioOrbit Milestone 0 Probe"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        do {
            try requireNoErr(
                AudioHardwareCreateProcessTap(description, &tapID),
                operation: "Create process tap"
            )

            // Use the tap UID published by the HAL instead of assuming the
            // description UUID is the aggregate-device composition UID.
            let tapUID = try CoreAudioProperty.string(
                objectID: tapID,
                selector: kAudioTapPropertyUID
            )

            let aggregateUID = "com.audioorbit.spike.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AudioOrbit Milestone 0 Tap",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                ]],
            ]
            try requireNoErr(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
                operation: "Create private tap aggregate device"
            )

            let tapFormat: AudioStreamBasicDescription = try CoreAudioProperty.value(
                objectID: tapID,
                selector: kAudioTapPropertyFormat
            )
            try validateTapFormat(tapFormat)
            let destinationSampleRate = try validateDestination(destinationDeviceID)
            self.tapFormat = tapFormat

            let gainRampFrames = UInt32(
                max(1, destinationSampleRate * Self.gainRampSeconds)
            )
            self.gainRampFrames = gainRampFrames
            guard let bridge = AOAudioBridgeCreate(
                tapFormat,
                destinationSampleRate,
                Self.ringCapacityFrames,
                gainRampFrames
            ) else {
                throw AudioRouteProbeError.unableToAllocateBridge
            }
            self.bridge = bridge

            let outputRenderer = PhysicalOutputRenderer()
            try outputRenderer.prepare(
                deviceID: destinationDeviceID,
                clientFormat: outputFormat(from: tapFormat, sampleRate: destinationSampleRate),
                bridge: bridge
            )
            self.outputRenderer = outputRenderer

            try requireNoErr(
                AudioDeviceCreateIOProcID(
                    aggregateDeviceID,
                    AOAudioBridgeCaptureIOProc,
                    UnsafeMutableRawPointer(bridge),
                    &ioProcID
                ),
                operation: "Create tap IO procedure"
            )
            guard let ioProcID else {
                throw CoreAudioError(operation: "Create tap IO procedure", status: kAudioHardwareUnspecifiedError)
            }
            try requireNoErr(
                AudioDeviceStart(aggregateDeviceID, ioProcID),
                operation: "Start tap IO"
            )
            // Capture must start first, but an external output may delay its
            // first hardware callback after accepting start. Drop audio queued
            // through that callback, then prime the audible route from fresh
            // frames just as a live destination switch does.
            AOAudioBridgePrepareForOutputStart(bridge)
            try outputRenderer.start()
            currentDestinationDeviceID = destinationDeviceID
        } catch {
            try? tearDown()
            throw error
        }
    }

    func stop() throws {
        try tearDown()
    }

    func switchDestination(to destinationDeviceID: AudioObjectID) async throws {
        guard destinationDeviceID != currentDestinationDeviceID else { return }
        guard let bridge, let tapFormat, let outputRenderer else {
            throw CoreAudioError(
                operation: "Switch an inactive route",
                status: kAudioHardwareNotRunningError
            )
        }

        // Validation occurs before touching the audible route so a bad choice
        // cannot disrupt the currently healthy destination.
        let destinationSampleRate = try validateDestination(destinationDeviceID)

        AOAudioBridgeBeginGainRamp(bridge, 0, gainRampFrames)
        do {
            try await waitForGainRamp(on: bridge, outputRenderer: outputRenderer)
        } catch {
            if routeIsActive(bridge: bridge, outputRenderer: outputRenderer) {
                AOAudioBridgeBeginGainRamp(bridge, 1, gainRampFrames)
            }
            throw error
        }
        guard routeIsActive(bridge: bridge, outputRenderer: outputRenderer) else {
            throw AudioRouteProbeError.routeLifecycleChanged
        }

        do {
            try outputRenderer.stop()
            self.outputRenderer = nil

            let replacementGainRampFrames = UInt32(
                max(1, destinationSampleRate * Self.gainRampSeconds)
            )

            let replacement = PhysicalOutputRenderer()
            try replacement.prepare(
                deviceID: destinationDeviceID,
                clientFormat: outputFormat(from: tapFormat, sampleRate: destinationSampleRate),
                bridge: bridge
            )

            // Preparing Core Audio can take long enough for the tap to fill a
            // substantial part of the queue. Discard that stale handoff audio
            // at the last safe moment, then let the new output prime afresh.
            guard AOAudioBridgeConfigureOutputSampleRate(bridge, destinationSampleRate) else {
                throw AudioRouteProbeError.invalidDestinationSampleRate
            }
            AOAudioBridgeBeginGainRamp(bridge, 1, replacementGainRampFrames)
            try replacement.start()
            self.outputRenderer = replacement
            gainRampFrames = replacementGainRampFrames
            currentDestinationDeviceID = destinationDeviceID
        } catch {
            // Once the old renderer has stopped, a failed replacement must
            // converge to pass-through rather than leave the source muted.
            try? tearDown()
            throw error
        }
    }

    private func tearDown() throws {
        var firstError: Error?
        var captureCallbackDetached = true

        if let ioProcID {
            let stopStatus = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if stopStatus != noErr {
                firstError = CoreAudioError(operation: "Stop tap IO", status: stopStatus)
            }
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            if destroyStatus == noErr {
                self.ioProcID = nil
            } else {
                captureCallbackDetached = false
                if firstError == nil {
                    firstError = CoreAudioError(
                        operation: "Destroy tap IO procedure",
                        status: destroyStatus
                    )
                }
            }
        }

        if let outputRenderer {
            do {
                try outputRenderer.stop()
            } catch {
                if firstError == nil { firstError = error }
            }
            if !outputRenderer.requiresCleanup {
                self.outputRenderer = nil
            }
        }

        // The capture IO procedure owns a raw pointer to the bridge. Preserve
        // the bridge and all HAL objects it depends on until the callback is
        // definitively detached; a later cleanup retry can safely continue.
        guard captureCallbackDetached else {
            throw firstError ?? CoreAudioError(
                operation: "Detach tap IO procedure",
                status: kAudioHardwareUnspecifiedError
            )
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status == noErr {
                aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            } else if firstError == nil {
                firstError = CoreAudioError(
                    operation: "Destroy private aggregate device",
                    status: status
                )
            }
        }

        // The aggregate retains the tap. Do not discard either object ID on a
        // failed destroy, otherwise cleanup cannot be retried and the source
        // may remain muted without an owner in the control plane.
        if aggregateDeviceID == kAudioObjectUnknown,
           tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status == noErr {
                tapID = AudioObjectID(kAudioObjectUnknown)
            } else if firstError == nil {
                firstError = CoreAudioError(
                    operation: "Destroy process tap",
                    status: status
                )
            }
        }

        // Both IO callbacks hold raw bridge pointers. The tap callback was
        // detached above; retain the bridge until the physical renderer has
        // also been disposed successfully.
        if outputRenderer == nil, let bridge {
            AOAudioBridgeDestroy(bridge)
            self.bridge = nil
        }

        if bridge == nil {
            tapFormat = nil
            gainRampFrames = 0
            currentDestinationDeviceID = nil
        }

        if let firstError { throw firstError }
    }

    private func validateDestination(_ destinationDeviceID: AudioObjectID) throws -> Double {
        let destinationSampleRate: Float64 = try CoreAudioProperty.value(
            objectID: destinationDeviceID,
            selector: kAudioDevicePropertyNominalSampleRate
        )
        let destinationIsAlive: UInt32 = try CoreAudioProperty.value(
            objectID: destinationDeviceID,
            selector: kAudioDevicePropertyDeviceIsAlive
        )
        guard destinationIsAlive != 0 else {
            throw AudioRouteProbeError.destinationUnavailable
        }
        guard destinationSampleRate > 0 else {
            throw AudioRouteProbeError.invalidDestinationSampleRate
        }
        return destinationSampleRate
    }

    private func outputFormat(
        from tapFormat: AudioStreamBasicDescription,
        sampleRate: Double
    ) -> AudioStreamBasicDescription {
        var format = tapFormat
        format.mSampleRate = sampleRate
        return format
    }

    private func waitForGainRamp(
        on bridge: OpaquePointer,
        outputRenderer: PhysicalOutputRenderer
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(250))
        while true {
            guard routeIsActive(bridge: bridge, outputRenderer: outputRenderer) else {
                throw AudioRouteProbeError.routeLifecycleChanged
            }
            guard AOAudioBridgeRead(bridge).gainRampRemainingFrameCount > 0 else {
                return
            }
            guard clock.now < deadline else {
                throw AudioRouteProbeError.gainRampTimedOut
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func routeIsActive(
        bridge: OpaquePointer,
        outputRenderer: PhysicalOutputRenderer
    ) -> Bool {
        self.bridge == bridge
            && self.outputRenderer === outputRenderer
            && isRunning
    }

    private func validateTapFormat(_ format: AudioStreamBasicDescription) throws {
        let isFloatPCM = format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format.mBitsPerChannel == 32
        guard isFloatPCM,
              (1...2).contains(format.mChannelsPerFrame),
              format.mBytesPerFrame > 0 else {
            throw AudioRouteProbeError.unsupportedTapFormat(
                "format \(format.mFormatID.fourCC), \(format.mChannelsPerFrame) channels, \(format.mBitsPerChannel)-bit"
            )
        }
    }
}
