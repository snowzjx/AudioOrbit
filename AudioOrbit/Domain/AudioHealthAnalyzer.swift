import Foundation

struct AudioHealthAnalyzer {
    private static let warmUpSeconds = 3.0
    private static let healthyEvidenceSeconds = 30.0
    private static let clockEstimateMinimumFrames: UInt64 = 48_000
    private static let queuePressureThreshold = 0.9

    private var measurementBaseline: TapProbeMetrics?
    private var previousMetrics: TapProbeMetrics?
    private var measurementBaselineSeconds = 0.0
    private var activeCaptureFrameCount: UInt64 = 0
    private var activeRenderFrameCount: UInt64 = 0
    private var activeUnderflowFrameCount: UInt64 = 0
    private var activeOverflowFrameCount: UInt64 = 0

    mutating func reset() {
        measurementBaseline = nil
        previousMetrics = nil
        measurementBaselineSeconds = 0
        activeCaptureFrameCount = 0
        activeRenderFrameCount = 0
        activeUnderflowFrameCount = 0
        activeOverflowFrameCount = 0
    }

    mutating func update(
        metrics: TapProbeMetrics,
        elapsedSeconds: Double
    ) -> AudioRouteHealth {
        if measurementBaseline == nil, elapsedSeconds >= Self.warmUpSeconds {
            measurementBaseline = metrics
            previousMetrics = metrics
            measurementBaselineSeconds = elapsedSeconds
        }

        guard let baseline = measurementBaseline else {
            return AudioRouteHealth(
                measuredSeconds: elapsedSeconds,
                maximumQueuedFrameCount: metrics.maximumQueuedFrameCount,
                capacityFrameCount: metrics.capacityFrameCount
            )
        }

        let measuredSeconds = max(0, elapsedSeconds - measurementBaselineSeconds)
        let previous = previousMetrics ?? baseline
        let intervalCaptureFrames = metrics.captureRequestedFrameCount
            - previous.captureRequestedFrameCount
        if intervalCaptureFrames > 0 {
            activeCaptureFrameCount += intervalCaptureFrames
            activeRenderFrameCount += metrics.renderRequestedFrameCount
                - previous.renderRequestedFrameCount
            activeUnderflowFrameCount += metrics.underflowFrameCount
                - previous.underflowFrameCount
            activeOverflowFrameCount += metrics.overflowFrameCount
                - previous.overflowFrameCount
        }
        previousMetrics = metrics

        let peakQueuedFrames = metrics.maximumQueuedFrameCount
        let capacityFrames = metrics.capacityFrameCount
        let fillRatio = capacityFrames > 0
            ? Double(peakQueuedFrames) / Double(capacityFrames)
            : 0

        let driftPPM: Double?
        if activeRenderFrameCount >= Self.clockEstimateMinimumFrames,
           metrics.sourceSampleRate > 0,
           metrics.outputSampleRate > 0 {
            let captureSeconds = Double(activeCaptureFrameCount) / metrics.sourceSampleRate
            let renderSeconds = Double(activeRenderFrameCount) / metrics.outputSampleRate
            driftPPM = (
                captureSeconds - renderSeconds
            ) / renderSeconds * 1_000_000
        } else {
            driftPPM = nil
        }

        let hasBufferFault = activeUnderflowFrameCount > 0 || activeOverflowFrameCount > 0
        let hasQueuePressure = fillRatio >= Self.queuePressureThreshold
        let level: AudioRouteHealthLevel
        if hasBufferFault || hasQueuePressure {
            level = .needsAttention
        } else if measuredSeconds >= Self.healthyEvidenceSeconds,
                  activeRenderFrameCount >= Self.clockEstimateMinimumFrames {
            level = .healthy
        } else {
            level = .observing
        }

        return AudioRouteHealth(
            level: level,
            measuredSeconds: elapsedSeconds,
            estimatedClockDriftPPM: driftPPM,
            underflowFrameCount: activeUnderflowFrameCount,
            overflowFrameCount: activeOverflowFrameCount,
            maximumQueuedFrameCount: peakQueuedFrames,
            capacityFrameCount: capacityFrames
        )
    }
}
