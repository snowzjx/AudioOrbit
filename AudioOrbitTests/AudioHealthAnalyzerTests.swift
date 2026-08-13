import XCTest
@testable import AudioOrbit

final class AudioHealthAnalyzerTests: XCTestCase {
    func testIgnoresWarmUpFaultsAndBecomesHealthyAfterThirtySeconds() {
        var analyzer = AudioHealthAnalyzer()
        analyzer.reset()

        var metrics = makeMetrics(
            captureRequested: 144_000,
            renderRequested: 144_000,
            underflow: 512,
            peakQueued: 1_024
        )
        XCTAssertEqual(
            analyzer.update(metrics: metrics, elapsedSeconds: 3).level,
            .observing
        )

        metrics.captureRequestedFrameCount += 1_440_000
        metrics.renderRequestedFrameCount += 1_440_000
        let health = analyzer.update(metrics: metrics, elapsedSeconds: 33)

        XCTAssertEqual(health.level, .healthy)
        XCTAssertEqual(health.underflowFrameCount, 0)
        XCTAssertEqual(health.overflowFrameCount, 0)
        XCTAssertEqual(health.estimatedClockDriftPPM, 0)
    }

    func testEstimatesClockDifferenceFromRequestedFrameTotals() throws {
        var analyzer = AudioHealthAnalyzer()
        analyzer.reset()
        let baseline = makeMetrics(
            captureRequested: 144_000,
            renderRequested: 144_000,
            peakQueued: 512
        )
        _ = analyzer.update(metrics: baseline, elapsedSeconds: 3)

        let health = analyzer.update(
            metrics: makeMetrics(
                captureRequested: 3_024_144,
                renderRequested: 3_024_000,
                peakQueued: 1_024
            ),
            elapsedSeconds: 63
        )

        XCTAssertEqual(try XCTUnwrap(health.estimatedClockDriftPPM), 50, accuracy: 0.001)
    }

    func testClockEstimateNormalizesDifferentNominalRates() throws {
        var analyzer = AudioHealthAnalyzer()
        analyzer.reset()
        var baseline = makeMetrics(
            captureRequested: 144_000,
            renderRequested: 132_300,
            peakQueued: 2_048
        )
        baseline.outputSampleRate = 44_100
        _ = analyzer.update(metrics: baseline, elapsedSeconds: 3)

        var later = baseline
        later.captureRequestedFrameCount += 96_000
        later.renderRequestedFrameCount += 88_200
        let health = analyzer.update(metrics: later, elapsedSeconds: 5)

        XCTAssertEqual(try XCTUnwrap(health.estimatedClockDriftPPM), 0, accuracy: 0.001)
    }

    func testReportsAttentionForPostWarmUpBufferFaultOrPressure() {
        var analyzer = AudioHealthAnalyzer()
        analyzer.reset()
        let baseline = makeMetrics(
            captureRequested: 144_000,
            renderRequested: 144_000,
            peakQueued: 512
        )
        _ = analyzer.update(metrics: baseline, elapsedSeconds: 3)

        let fault = analyzer.update(
            metrics: makeMetrics(
                captureRequested: 192_000,
                renderRequested: 192_000,
                underflow: 256,
                peakQueued: 1_024
            ),
            elapsedSeconds: 4
        )
        XCTAssertEqual(fault.level, .needsAttention)
        XCTAssertEqual(fault.underflowFrameCount, 256)

        var pressureAnalyzer = AudioHealthAnalyzer()
        pressureAnalyzer.reset()
        _ = pressureAnalyzer.update(metrics: baseline, elapsedSeconds: 3)
        let pressure = pressureAnalyzer.update(
            metrics: makeMetrics(
                captureRequested: 192_000,
                renderRequested: 192_000,
                peakQueued: 15_000
            ),
            elapsedSeconds: 4
        )
        XCTAssertEqual(pressure.level, .needsAttention)
    }

    func testDoesNotTreatAnIdleSourceAsAClockFailure() {
        var analyzer = AudioHealthAnalyzer()
        analyzer.reset()
        let baseline = makeMetrics(
            captureRequested: 144_000,
            renderRequested: 144_000,
            peakQueued: 512
        )
        _ = analyzer.update(metrics: baseline, elapsedSeconds: 3)

        let idle = analyzer.update(
            metrics: makeMetrics(
                captureRequested: 144_000,
                renderRequested: 1_584_000,
                underflow: 1_440_000,
                peakQueued: 512
            ),
            elapsedSeconds: 33
        )

        XCTAssertEqual(idle.level, .observing)
        XCTAssertEqual(idle.underflowFrameCount, 0)
        XCTAssertNil(idle.estimatedClockDriftPPM)
    }

    private func makeMetrics(
        captureRequested: UInt64,
        renderRequested: UInt64,
        underflow: UInt64 = 0,
        overflow: UInt64 = 0,
        peakQueued: UInt64
    ) -> TapProbeMetrics {
        TapProbeMetrics(
            captureRequestedFrameCount: captureRequested,
            renderRequestedFrameCount: renderRequested,
            maximumQueuedFrameCount: peakQueued,
            capacityFrameCount: 16_384,
            underflowFrameCount: underflow,
            overflowFrameCount: overflow,
            sourceSampleRate: 48_000,
            outputSampleRate: 48_000
        )
    }
}
