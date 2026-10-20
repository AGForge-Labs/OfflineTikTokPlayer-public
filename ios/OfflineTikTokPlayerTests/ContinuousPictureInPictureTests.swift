import XCTest
import AVFoundation
import CoreVideo
@testable import OfflineTikTokPlayer

@MainActor
final class ContinuousPictureInPictureTests: XCTestCase {
    func testPreparedOutputSurvivesSelectionReturnWithoutDuplicatesAndFallbackIsRemoved() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let a = AVPlayerItem(url: url), b = AVPlayerItem(url: url), fallback = AVPlayerItem(url: url)
        for item in [a, b] {
            item.videoComposition = try await ContinuousPictureInPicture.videoCompositionIfNeeded(for: item.asset)
        }
        let aOutput = ContinuousPictureInPicture.prepareVideoOutput(for: a)
        let bOutput = ContinuousPictureInPicture.prepareVideoOutput(for: b)
        XCTAssertTrue(ContinuousPictureInPicture.prepareVideoOutput(for: a) === aOutput)
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        bridge.setCurrentItem(a); bridge.setCurrentItem(b); bridge.setCurrentItem(a)
        XCTAssertTrue(bridge.orientationPrepared)
        XCTAssertTrue(a.outputs.contains { $0 === aOutput })
        XCTAssertTrue(b.outputs.contains { $0 === bOutput })
        XCTAssertEqual(a.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 1)
        XCTAssertEqual(b.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 1)
        XCTAssertFalse(aOutput.suppressesPlayerRendering)
        let monitor = PlaybackFrameMonitor()
        monitor.start(item: a, layer: AVPlayerLayer(), decodedFrameEpoch: { nil }) { XCTFail("No decoded frame is available") }
        XCTAssertEqual(a.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 1,
                       "Even false external evidence must not create a second late output")
        monitor.cancel()
        XCTAssertTrue(a.outputs.contains { $0 === aOutput }, "Observation cannot remove the shared prepared output")
        bridge.setCurrentItem(fallback)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !bridge.orientationPrepared, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(bridge.orientationPrepared)
        XCTAssertEqual(fallback.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 1)
        bridge.setCurrentItem(a)
        XCTAssertTrue(fallback.outputs.isEmpty, "Unprepared fallback outputs retain their existing detach lifecycle")
        XCTAssertTrue(a.outputs.contains { $0 === aOutput })
        bridge.invalidate()
        XCTAssertTrue(a.outputs.isEmpty, "Invalidation detaches the active prepared output")
    }

    func testOnlyExplicitPiPCommandsReachAudioIntent() {
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        var commands: [Bool] = []
        bridge.onSetPlaying = { commands.append($0) }
        bridge.updatePlayback(positionSeconds: 1, durationSeconds: 10, isPlaying: true)
        bridge.suspendFrameFeed()
        bridge.updatePlayback(positionSeconds: 2, durationSeconds: 10, isPlaying: true)
        XCTAssertTrue(bridge.isFrameFeedSuspended)
        XCTAssertTrue(commands.isEmpty)
        bridge.resumeFrameFeed()
        XCTAssertTrue(commands.isEmpty)
        bridge.handleSetPlayingRequest(false)
        bridge.handleSetPlayingRequest(true)
        XCTAssertEqual(commands, [false, true])
        bridge.invalidate()
        bridge.handleSetPlayingRequest(true)
        XCTAssertEqual(commands, [false, true])
    }

    func testSkipAlwaysCompletesAndRejectsInvalidInterval() {
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        var completions = 0
        bridge.handleSkipRequest(15) { completions += 1 }
        XCTAssertEqual(completions, 1)
        var intervals: [Double] = []
        bridge.onSkip = { interval, done in intervals.append(interval); done(); done() }
        bridge.handleSkipRequest(.nan) { completions += 1 }
        bridge.handleSkipRequest(-15) { completions += 1 }
        XCTAssertEqual(intervals, [-15])
        XCTAssertEqual(completions, 3)
    }

    func testRestorationNeverClaimsSuccessWithoutAnActualUICompletion() {
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        var results: [Bool] = []
        bridge.handleRestoreUIRequest { results.append($0) }
        XCTAssertEqual(results, [false])
        var restoreCompletion: ((Bool) -> Void)?
        bridge.onRestoreUI = { restoreCompletion = $0 }
        bridge.handleRestoreUIRequest { results.append($0) }
        XCTAssertEqual(results, [false])
        restoreCompletion?(true)
        restoreCompletion?(false)
        XCTAssertEqual(results, [false, true])
    }

    func testPortraitAndMirrorCompositionProducesOrientedPixelsAndPreservesSourceTiming() async throws {
        let cases: [(CGAffineTransform, CGSize, Bool)] = [
            (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 16, ty: 0), CGSize(width: 16, height: 32), false),
            (CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0), CGSize(width: 32, height: 16), true)
        ]
        for (transform, expectedSize, mirrored) in cases {
            let url = try await makeAsymmetricVideo(transform: transform)
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let duration = try await asset.load(.duration)
            let preparedComposition = try await ContinuousPictureInPicture.videoCompositionIfNeeded(for: asset)
            let composition = try XCTUnwrap(preparedComposition)
            XCTAssertEqual(composition.renderSize, expectedSize)
            XCTAssertEqual(composition.sourceTrackIDForFrameTiming, track.trackID)
            XCTAssertEqual(CMTimeCompare(try XCTUnwrap(composition.instructions.first).timeRange.duration, duration), 0)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks,
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = composition
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            defer { reader.cancelReading() }
            let first = try XCTUnwrap(output.copyNextSampleBuffer())
            let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(first))
            XCTAssertEqual(CVPixelBufferGetWidth(pixel), Int(expectedSize.width))
            XCTAssertEqual(CVPixelBufferGetHeight(pixel), Int(expectedSize.height))
            if mirrored {
                XCTAssertTrue(isBlue(pixel, x: 8, y: 8))
                XCTAssertFalse(isBlue(pixel, x: 24, y: 8))
            } else {
                // Rotation moves the original left/right split onto the vertical axis.
                XCTAssertNotEqual(isBlue(pixel, x: 8, y: 8), isBlue(pixel, x: 8, y: 24))
            }
            let second = try XCTUnwrap(output.copyNextSampleBuffer())
            XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(second)), 1.0 / 24, accuracy: 0.000_01)
        }
    }

    func testChangingItemCancelsOrientationPreparationAndCannotAttachOldOutput() async throws {
        let url = try await makeAsymmetricVideo(transform: .identity)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = AVPlayerItem(url: url)
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        bridge.setCurrentItem(item)
        bridge.setCurrentItem(nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(bridge.orientationPrepared)
        XCTAssertTrue(item.outputs.isEmpty)
        XCTAssertNil(item.videoComposition)
    }

    func testIdentityGeometryKeepsNativeOutputWithoutInstallingACompositor() async throws {
        let url = try await makeAsymmetricVideo(transform: .identity)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let composition = try await ContinuousPictureInPicture.videoCompositionIfNeeded(for: asset)
        XCTAssertNil(composition, "Ordinary identity geometry must not add a video compositor")
        let item = AVPlayerItem(asset: asset)
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        bridge.setCurrentItem(item)
        for _ in 0..<100 where !bridge.orientationPrepared { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(bridge.orientationPrepared)
        XCTAssertFalse(item.outputs.isEmpty)
        XCTAssertNil(item.videoComposition)
        let unchangedDuration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeCompare(unchangedDuration, duration), 0)
    }

    func testIdentityTransformWithNonSquarePixelsStillUsesNormalization() async throws {
        let url = try await makeAsymmetricVideo(transform: .identity, nonSquarePixels: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let composition = try await ContinuousPictureInPicture.videoCompositionIfNeeded(for: AVURLAsset(url: url))
        XCTAssertNotNil(composition, "Identity transform alone cannot bypass pixel-aspect normalization")
    }

    private func makeAsymmetricVideo(transform: CGAffineTransform, nonSquarePixels: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var completed = false
        defer {
            if !completed {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
            }
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 16
        ]
        if nonSquarePixels {
            settings[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: 2,
                                                   AVVideoPixelAspectRatioVerticalSpacingKey: 1]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 16,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: AVFoundationErrorDomain, code: -3) }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, kCVPixelFormatType_32BGRA,
                                           attributes as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<16 {
            for x in 0..<32 {
                let offset = y * rowBytes + x * 4
                bytes[offset] = x < 16 ? 0 : 255
                bytes[offset + 1] = 0
                bytes[offset + 2] = x < 16 ? 255 : 0
                bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for index in 0..<2 {
            var attempts = 0
            while !input.isReadyForMoreMediaData && attempts < 200 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 24))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: AVFoundationErrorDomain, code: -4) }
        completed = true
        return url
    }

    private func isBlue(_ pixel: CVPixelBuffer, x: Int, y: Int) -> Bool {
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { XCTFail("Missing decoded pixels"); return false }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
        return Int(bytes[offset]) > Int(bytes[offset + 2]) + 80
    }
}
