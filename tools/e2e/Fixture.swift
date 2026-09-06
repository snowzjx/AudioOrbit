import AVFoundation
import AppKit
import CoreMedia

/// Synthetic media only: six seconds of visible motion and a quiet 440 Hz
/// tone embedded in the video track's container, exercising Safari media IO.
func generateFixture(_ url: URL) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ])
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000
    ])
    guard writer.canAdd(video), writer.canAdd(audio) else { throw DriverError("Media encoders unavailable") }
    writer.add(video)
    writer.add(audio)
    guard writer.startWriting() else { throw writer.error ?? DriverError("Cannot start fixture encoding") }
    writer.startSession(atSourceTime: .zero)
    var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
        mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format) == noErr, let format else { throw DriverError("Cannot create audio format") }
    let deadline = Date().addingTimeInterval(60)
    var videoFrame = 0
    var audioFrame = 0
    while videoFrame < 180 || audioFrame < 180 {
        guard writer.status == .writing, Date() < deadline else {
            writer.cancelWriting()
            throw writer.error ?? DriverError("Fixture encoding timed out")
        }
        if videoFrame < 180 && video.isReadyForMoreMediaData {
        let frame = videoFrame
        var pixel: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw DriverError("Cannot allocate fixture frame") }
        CVPixelBufferLockBaseAddress(pixel, [])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 640, height: 360,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw DriverError("Cannot draw fixture") }
        context.setFillColor(CGColor(red: 0.05, green: 0.1, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: frame * 3 % 580, y: 140, width: 60, height: 80))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? DriverError("Cannot append video") }
        videoFrame += 1
        if videoFrame == 180 { video.markAsFinished() }
        }
        if audioFrame < 180 && audio.isReadyForMoreMediaData {
        let frame = audioFrame
        let samples = (0..<1600).map { i in Float(0.04 * sin(2 * Double.pi * 440 * Double(frame * 1600 + i) / 48000)) }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 6400, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 6400, flags: 0, blockBufferOut: &block) == noErr, let block else { throw DriverError("Cannot allocate audio block") }
        let copyStatus = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: 6400)
        }
        guard copyStatus == noErr else { throw DriverError("Cannot copy audio samples") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(value: Int64(frame * 1600), timescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var sampleSize = 4
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1600, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
            let sample, audio.append(sample) else { throw writer.error ?? DriverError("Cannot append audio") }
        audioFrame += 1
        if audioFrame == 180 { audio.markAsFinished() }
        }
        Thread.sleep(forTimeInterval: 0.001)
    }
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    guard finished.wait(timeout: .now() + 30) == .success, writer.status == .completed else { throw writer.error ?? DriverError("Fixture finalization failed") }
}

private final class FixtureValidationResult: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    // The semaphore transfers ownership from the detached task to its caller.
    var result: Result<[String: Any], Error>?
}

func validateFixture(_ url: URL) throws -> [String: Any] {
    let box = FixtureValidationResult()
    Task.detached {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let video = try await asset.loadTracks(withMediaType: .video)
            guard audio.count == 1, video.count == 1, duration >= 5.9, duration < 6.2 else {
                throw DriverError("Fixture must contain six seconds of video and audio")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? DriverError("Cannot decode fixture audio") }
            var peak: Float = 0
            var sampleCount = 0
            while let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let size = CMBlockBufferGetDataLength(block)
                var values = [Float](repeating: 0, count: size / 4)
                let status = values.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: bytes.baseAddress!)
                }
                guard status == noErr else { throw DriverError("Cannot inspect fixture audio") }
                peak = max(peak, values.map(abs).max() ?? 0)
                sampleCount += values.count
            }
            guard reader.status == .completed, sampleCount >= 280000, peak > 0.01, peak < 0.1 else {
                throw DriverError("Fixture audio is missing, silent, truncated, or unexpectedly loud")
            }
            box.result = .success(["duration": duration, "audioSamples": sampleCount, "peak": peak, "videoTracks": video.count, "audioTracks": audio.count])
        } catch { box.result = .failure(error) }
        box.completed.signal()
    }
    guard box.completed.wait(timeout: .now() + 30) == .success, let result = box.result else {
        throw DriverError("Fixture validation timed out")
    }
    return try result.get()
}
