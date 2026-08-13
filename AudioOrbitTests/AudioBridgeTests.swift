import AudioToolbox
import XCTest
@testable import AudioOrbit

final class AudioBridgeTests: XCTestCase {
    func testCopiesStereoFramesAndReportsOverflowAndUnderflow() throws {
        let format = stereoFloatFormat(sampleRate: 48_000)
        let bridge = try XCTUnwrap(AOAudioBridgeCreate(format, 48_000, 4, 0))
        defer { AOAudioBridgeDestroy(bridge) }

        var input: [Float] = [
            0.1, -0.1,
            0.2, -0.2,
            0.3, -0.3,
            0.4, -0.4,
            0.5, -0.5,
            0.6, -0.6,
        ]
        input.withUnsafeMutableBufferPointer { samples in
            var inputList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                    mData: samples.baseAddress
                )
            )
            AOAudioBridgeWrite(bridge, &inputList)
        }

        var output = [Float](repeating: 99, count: 12)
        output.withUnsafeMutableBufferPointer { samples in
            var outputList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                    mData: samples.baseAddress
                )
            )
            var flags: AudioUnitRenderActionFlags = []
            var timestamp = AudioTimeStamp()
            XCTAssertEqual(
                AOAudioBridgeRender(
                    UnsafeMutableRawPointer(bridge),
                    &flags,
                    &timestamp,
                    0,
                    6,
                    &outputList
                ),
                noErr
            )
        }

        XCTAssertEqual(Array(output.prefix(8)), Array(input.prefix(8)))
        XCTAssertEqual(Array(output.suffix(4)), [0, 0, 0, 0])

        let snapshot = AOAudioBridgeRead(bridge)
        XCTAssertEqual(snapshot.capturedFrameCount, 4)
        XCTAssertEqual(snapshot.renderedFrameCount, 4)
        XCTAssertEqual(snapshot.captureRequestedFrameCount, 6)
        XCTAssertEqual(snapshot.renderRequestedFrameCount, 6)
        XCTAssertEqual(snapshot.queuedFrameCount, 0)
        XCTAssertEqual(snapshot.maximumQueuedFrameCount, 4)
        XCTAssertEqual(snapshot.capacityFrameCount, 4)
        XCTAssertEqual(snapshot.overflowCount, 1)
        XCTAssertEqual(snapshot.overflowFrameCount, 2)
        XCTAssertEqual(snapshot.underflowCount, 1)
        XCTAssertEqual(snapshot.underflowFrameCount, 2)
    }

    func testStartupGainRampIsAppliedWithoutAllocatingDuringRender() throws {
        let format = stereoFloatFormat(sampleRate: 48_000)
        let bridge = try XCTUnwrap(AOAudioBridgeCreate(format, 48_000, 8, 4))
        defer { AOAudioBridgeDestroy(bridge) }

        var input = [Float](repeating: 1, count: 16)
        input.withUnsafeMutableBufferPointer { samples in
            var inputList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                    mData: samples.baseAddress
                )
            )
            AOAudioBridgeWrite(bridge, &inputList)
        }

        var output = [Float](repeating: 0, count: 8)
        output.withUnsafeMutableBufferPointer { samples in
            var outputList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                    mData: samples.baseAddress
                )
            )
            var flags: AudioUnitRenderActionFlags = []
            var timestamp = AudioTimeStamp()
            _ = AOAudioBridgeRender(
                UnsafeMutableRawPointer(bridge),
                &flags,
                &timestamp,
                0,
                4,
                &outputList
            )
        }

        XCTAssertEqual(output, [0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1])
    }

    func testStartupRampWaitsUntilTheQueueIsPrimed() throws {
        let format = stereoFloatFormat(sampleRate: 48_000)
        let bridge = try XCTUnwrap(AOAudioBridgeCreate(format, 48_000, 16_384, 480))
        defer { AOAudioBridgeDestroy(bridge) }

        write(frames: 512, to: bridge)
        XCTAssertEqual(renderSamples(frames: 512, from: bridge), [Float](repeating: 0, count: 1_024))

        let snapshot = AOAudioBridgeRead(bridge)
        XCTAssertEqual(snapshot.renderedFrameCount, 0)
        XCTAssertEqual(snapshot.underflowFrameCount, 0)
        XCTAssertEqual(snapshot.gainRampRemainingFrameCount, 480)
        XCTAssertEqual(snapshot.isPrimed, 0)
    }

    func testControlPlaneCanRequestFadeOutAndFadeIn() throws {
        let format = stereoFloatFormat(sampleRate: 48_000)
        let bridge = try XCTUnwrap(AOAudioBridgeCreate(format, 48_000, 16, 0))
        defer { AOAudioBridgeDestroy(bridge) }

        func writeFourFrames() {
            var input = [Float](repeating: 1, count: 8)
            input.withUnsafeMutableBufferPointer { samples in
                var inputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                        mData: samples.baseAddress
                    )
                )
                AOAudioBridgeWrite(bridge, &inputList)
            }
        }

        func renderFourFrames() -> [Float] {
            var output = [Float](repeating: 0, count: 8)
            output.withUnsafeMutableBufferPointer { samples in
                var outputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                        mData: samples.baseAddress
                    )
                )
                var flags: AudioUnitRenderActionFlags = []
                var timestamp = AudioTimeStamp()
                _ = AOAudioBridgeRender(
                    UnsafeMutableRawPointer(bridge),
                    &flags,
                    &timestamp,
                    0,
                    4,
                    &outputList
                )
            }
            return output
        }

        write(frames: 12, to: bridge)
        AOAudioBridgeBeginGainRamp(bridge, 0, 4)
        XCTAssertEqual(renderFourFrames(), [0.75, 0.75, 0.5, 0.5, 0.25, 0.25, 0, 0])
        XCTAssertEqual(AOAudioBridgeRead(bridge).gainRampRemainingFrameCount, 0)

        writeFourFrames()
        AOAudioBridgeBeginGainRamp(bridge, 1, 4)
        XCTAssertEqual(renderFourFrames(), [0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1])
        XCTAssertEqual(AOAudioBridgeRead(bridge).gainRampRemainingFrameCount, 0)
    }

    func testQueueWatermarkCanBeginANewObservationWindow() throws {
        let format = stereoFloatFormat(sampleRate: 48_000)
        let bridge = try XCTUnwrap(AOAudioBridgeCreate(format, 48_000, 8, 0))
        defer { AOAudioBridgeDestroy(bridge) }

        write(frames: 6, to: bridge)
        XCTAssertEqual(AOAudioBridgeRead(bridge).maximumQueuedFrameCount, 6)
        render(frames: 6, from: bridge)

        AOAudioBridgeResetQueueWatermark(bridge)
        write(frames: 2, to: bridge)

        let snapshot = AOAudioBridgeRead(bridge)
        XCTAssertEqual(snapshot.queuedFrameCount, 2)
        XCTAssertEqual(snapshot.maximumQueuedFrameCount, 2)
    }

    func testResamplesBetweenDifferentNominalRates() throws {
        let format = stereoFloatFormat(sampleRate: 48_000)
        let bridge = try XCTUnwrap(AOAudioBridgeCreate(format, 24_000, 32, 0))
        defer { AOAudioBridgeDestroy(bridge) }

        var input = (0..<20).flatMap { frame in
            [Float(frame), -Float(frame)]
        }
        input.withUnsafeMutableBufferPointer { samples in
            var inputList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                    mData: samples.baseAddress
                )
            )
            AOAudioBridgeWrite(bridge, &inputList)
        }

        let output = renderSamples(frames: 4, from: bridge)
        XCTAssertEqual(output, [0, 0, 2, -2, 4, -4, 6, -6])

        let snapshot = AOAudioBridgeRead(bridge)
        XCTAssertEqual(snapshot.sourceSampleRate, 48_000)
        XCTAssertEqual(snapshot.outputSampleRate, 24_000)
        XCTAssertEqual(snapshot.consumedSourceFrameCount, 8)
        XCTAssertEqual(snapshot.renderedFrameCount, 4)
        XCTAssertEqual(snapshot.underflowFrameCount, 0)
    }

    func testOutputReconfigurationDiscardsSwitchBacklogAndPrimesFromFreshAudio() throws {
        let format = stereoFloatFormat(sampleRate: 48_000)
        let bridge = try XCTUnwrap(AOAudioBridgeCreate(format, 48_000, 16_384, 480))
        defer { AOAudioBridgeDestroy(bridge) }

        // Model frames accumulating while a replacement output is prepared.
        write(frames: 15_000, to: bridge)
        XCTAssertGreaterThan(Double(AOAudioBridgeRead(bridge).queuedFrameCount) / 16_384, 0.9)

        XCTAssertTrue(AOAudioBridgeConfigureOutputSampleRate(bridge, 44_100))
        var snapshot = AOAudioBridgeRead(bridge)
        XCTAssertEqual(snapshot.queuedFrameCount, 0)
        XCTAssertEqual(snapshot.maximumQueuedFrameCount, 0)
        XCTAssertEqual(snapshot.outputSampleRate, 44_100)
        XCTAssertEqual(snapshot.rateCorrectionPPM, 0)
        XCTAssertEqual(snapshot.isPrimed, 0)

        // Model an external device that accepts the start request but delays
        // its first hardware callback while capture continues. That first
        // callback must discard the second backlog as well.
        write(frames: 512, to: bridge)
        XCTAssertEqual(
            renderSamples(frames: 512, from: bridge),
            [Float](repeating: 0, count: 1_024)
        )
        snapshot = AOAudioBridgeRead(bridge)
        XCTAssertEqual(snapshot.queuedFrameCount, 0)
        XCTAssertEqual(snapshot.underflowFrameCount, 0)
        XCTAssertEqual(snapshot.isPrimed, 0)

        // A single callback captured after hardware startup is not enough to
        // prime, and waiting for more is intentional silence, not underflow.
        write(frames: 512, to: bridge)
        XCTAssertEqual(
            renderSamples(frames: 512, from: bridge),
            [Float](repeating: 0, count: 1_024)
        )
        snapshot = AOAudioBridgeRead(bridge)
        XCTAssertEqual(snapshot.queuedFrameCount, 512)
        XCTAssertEqual(snapshot.underflowFrameCount, 0)
        XCTAssertEqual(snapshot.isPrimed, 0)

        write(frames: 2_560, to: bridge)
        let output = renderSamples(frames: 512, from: bridge)
        snapshot = AOAudioBridgeRead(bridge)
        XCTAssertTrue(output.contains { $0 != 0 })
        XCTAssertLessThan(snapshot.queuedFrameCount, 3_072)
        XCTAssertLessThan(snapshot.maximumQueuedFrameCount, 3_073)
        XCTAssertEqual(snapshot.underflowFrameCount, 0)
        XCTAssertNotEqual(snapshot.isPrimed, 0)
    }

    func testInitialOutputStartDiscardsBacklogThroughFirstHardwareCallback() throws {
        let format = stereoFloatFormat(sampleRate: 48_000)
        let bridge = try XCTUnwrap(AOAudioBridgeCreate(format, 48_000, 16_384, 480))
        defer { AOAudioBridgeDestroy(bridge) }

        // Capture can run before an external output accepts its start request.
        write(frames: 15_000, to: bridge)
        AOAudioBridgePrepareForOutputStart(bridge)
        XCTAssertEqual(AOAudioBridgeRead(bridge).queuedFrameCount, 0)

        // Capture can continue while the external hardware callback is still
        // delayed; the first callback drops this second startup backlog.
        write(frames: 1_024, to: bridge)
        XCTAssertEqual(
            renderSamples(frames: 512, from: bridge),
            [Float](repeating: 0, count: 1_024)
        )

        var snapshot = AOAudioBridgeRead(bridge)
        XCTAssertEqual(snapshot.queuedFrameCount, 0)
        XCTAssertEqual(snapshot.maximumQueuedFrameCount, 0)
        XCTAssertEqual(snapshot.underflowFrameCount, 0)
        XCTAssertEqual(snapshot.isPrimed, 0)

        write(frames: 3_072, to: bridge)
        XCTAssertTrue(renderSamples(frames: 512, from: bridge).contains { $0 != 0 })
        snapshot = AOAudioBridgeRead(bridge)
        XCTAssertLessThan(snapshot.queuedFrameCount, 3_072)
        XCTAssertLessThan(snapshot.maximumQueuedFrameCount, 3_073)
        XCTAssertEqual(snapshot.underflowFrameCount, 0)
        XCTAssertNotEqual(snapshot.isPrimed, 0)
    }

    func testAdaptiveCorrectionPreventsAConsistentlyFasterConsumerFromDrainingQueue() throws {
        let format = stereoFloatFormat(sampleRate: 48_000)
        let bridge = try XCTUnwrap(AOAudioBridgeCreate(format, 48_000, 16_384, 0))
        defer { AOAudioBridgeDestroy(bridge) }

        write(frames: 2_560, to: bridge)
        for _ in 0..<1_000 {
            write(frames: 479, to: bridge)
            render(frames: 480, from: bridge)
        }

        let snapshot = AOAudioBridgeRead(bridge)
        XCTAssertEqual(snapshot.underflowFrameCount, 0)
        XCTAssertGreaterThan(snapshot.queuedFrameCount, 1_000)
        XCTAssertLessThan(snapshot.rateCorrectionPPM, -500)
        XCTAssertTrue(snapshot.isPrimed != 0)
    }

    private func write(frames: UInt32, to bridge: OpaquePointer) {
        var input = [Float](repeating: 1, count: Int(frames) * 2)
        input.withUnsafeMutableBufferPointer { samples in
            var inputList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                    mData: samples.baseAddress
                )
            )
            AOAudioBridgeWrite(bridge, &inputList)
        }
    }

    private func render(frames: UInt32, from bridge: OpaquePointer) {
        _ = renderSamples(frames: frames, from: bridge)
    }

    private func renderSamples(frames: UInt32, from bridge: OpaquePointer) -> [Float] {
        var output = [Float](repeating: 0, count: Int(frames) * 2)
        output.withUnsafeMutableBufferPointer { samples in
            var outputList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                    mData: samples.baseAddress
                )
            )
            var flags: AudioUnitRenderActionFlags = []
            var timestamp = AudioTimeStamp()
            _ = AOAudioBridgeRender(
                UnsafeMutableRawPointer(bridge),
                &flags,
                &timestamp,
                0,
                frames,
                &outputList
            )
        }
        return output
    }

    private func stereoFloatFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
