import AVFoundation
import XCTest
@testable import OfflineTikTokPlayer

@MainActor
final class LocalVideoFrameReaderTests: XCTestCase {
    private let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    func testImportedMotionReturnsNewestDueOriginalFrameAndCancels() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-motion-1080", withExtension: "mp4"))
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let time: (Int64) -> CMTime = { CMTime(value: $0, timescale: 600) }
        let reader = LocalVideoFrameReader(asset: asset, composition: nil, pixelFormat: format, start: time(183))
        defer { reader.cancel() }

        let first = try await frame(reader, at: time(183))
        XCTAssertEqual(CMTimeCompare(first.position, time(180)), 0)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(first.pixel), format)
        let second = try await frame(reader, at: time(453))
        XCTAssertEqual(CMTimeCompare(second.position, time(450)), 0)
        XCTAssertNotEqual(try luma(first.pixel), try luma(second.pixel), "Two different positions must contain different decoded images")
        XCTAssertNil(reader.frame(at: time(183)), "An earlier target must never resurrect a consumed image")

        let jump = time(2_703)
        if let immediate = reader.frame(at: jump) {
            XCTAssertEqual(CMTimeCompare(immediate.position, time(2_700)), 0, "A cold cache must never return its old tail")
        }
        let latest = try await frame(reader, at: jump)
        XCTAssertEqual(CMTimeCompare(latest.position, time(2_700)), 0)
        reader.cancel()
        XCTAssertNil(reader.frame(at: jump))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(reader.frame(at: time(2_710)), "A finishing native read must never republish after cancellation")
    }

    func testAuthoredVariableFrameRemainsCurrentUntilItsSuccessor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeVariableMovie(to: url)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let scale: (Int64) -> CMTime = { CMTime(value: $0, timescale: 600) }
        // The first image after zero begins at 0.1s and lasts to 2.1s.
        let reader = LocalVideoFrameReader(asset: asset, composition: nil, pixelFormat: format, start: scale(780))
        defer { reader.cancel() }
        let held = try await frame(reader, at: scale(780))
        XCTAssertEqual(CMTimeCompare(held.position, scale(60)), 0)
        let beforeBoundary = try await frame(reader, at: scale(1_259))
        XCTAssertEqual(CMTimeCompare(beforeBoundary.position, scale(60)), 0)
        let successor = try await frame(reader, at: scale(1_260))
        XCTAssertEqual(CMTimeCompare(successor.position, scale(1_260)), 0)
        XCTAssertNotEqual(try luma(held.pixel), try luma(successor.pixel))
        XCTAssertNil(reader.frame(at: scale(1_380)), "The last image ends at the authored video endpoint")
    }

    func testReplacementAppliesTheInstalledCompositionAndKeepsItsPixelFormat() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-a", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let original = LocalVideoFrameReader(asset: asset, composition: nil, pixelFormat: format, start: .zero)
        let source = try await frame(original, at: .zero)
        XCTAssertNotEqual(CVPixelBufferGetWidth(source.pixel), CVPixelBufferGetHeight(source.pixel))

        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        composition.renderSize = CGSize(width: size.height, height: size.width)
        composition.sourceTrackIDForFrameTiming = track.trackID
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        let rotated = LocalVideoFrameReader(asset: asset, composition: composition, pixelFormat: format, start: .zero)
        defer { rotated.cancel() }
        XCTAssertNil(original.frame(at: .zero))
        original.cancel()
        let composed = try await frame(rotated, at: .zero)
        XCTAssertEqual(CVPixelBufferGetWidth(composed.pixel), CVPixelBufferGetHeight(source.pixel))
        XCTAssertEqual(CVPixelBufferGetHeight(composed.pixel), CVPixelBufferGetWidth(source.pixel))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(composed.pixel), format)
        XCTAssertEqual(CMTimeCompare(source.position, composed.position), 0)
    }

    private func frame(_ reader: LocalVideoFrameReader, at time: CMTime) async throws -> (pixel: CVPixelBuffer, position: CMTime) {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let result = reader.frame(at: time) { return result }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try XCTUnwrap(reader.frame(at: time), "No decoded image covered \(time.seconds)s")
    }

    private func luma(_ pixel: CVPixelBuffer) throws -> [UInt8] {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let data = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, 0)).assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(pixel, 0), height = CVPixelBufferGetHeightOfPlane(pixel, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
        var samples = [UInt8]()
        for y in stride(from: 0, to: height, by: max(1, height / 32)) {
            for x in stride(from: 0, to: width, by: max(1, width / 32)) { samples.append(data[y * rowBytes + x]) }
        }
        return samples
    }

    private func writeVariableMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]
        ])
        input.mediaTimeScale = 600
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let deadline = ContinuousClock.now + .seconds(5)
        for (index, ticks) in [0, 60, 1_260, 1_320].enumerated() {
            while !input.isReadyForMoreMediaData && writer.status == .writing && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            let image = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(image, [])
            if let base = CVPixelBufferGetBaseAddress(image) { memset(base, Int32(index * 65), CVPixelBufferGetDataSize(image)) }
            CVPixelBufferUnlockBaseAddress(image, [])
            XCTAssertTrue(adaptor.append(image, withPresentationTime: CMTime(value: Int64(ticks), timescale: 600)))
        }
        writer.endSession(atSourceTime: CMTime(value: 1_380, timescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}
