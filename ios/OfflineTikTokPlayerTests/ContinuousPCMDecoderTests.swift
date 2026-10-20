import XCTest
import AVFoundation
import AudioToolbox
import Synchronization
import PlayerCore
@testable import OfflineTikTokPlayer

final class ContinuousPCMDecoderTests: XCTestCase {
    func testDecoderPreservesLeadingAndTrailingSourceSilenceAndTheLastFrame() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.caf")
        let expected: [Float] = [0, 0, 0, 0, 0.125, -0.125, 0.25, -0.25, 0, 0, 0.5, -0.5, 0, 0]
        try writePCM(expected, to: url)
        let renderer = ContinuousPCMRenderer(prefixFrames: 16, ringFrames: 32)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let sourceSilence = expectation(description: "Complete source silence measurement")
        sourceSilence.assertForOverFulfill = true
        let observed = Mutex<(Int, ContinuousPCMDecoder.SourceSilence)?>(nil)
        let failures = Mutex<[ContinuousPCMDecoder.Failure]>([])
        decoder.setFailureHandler { _, failure in failures.withLock { $0.append(failure) } }
        decoder.setSourceSilenceHandler { token, analysis in
            observed.withLock { $0 = (token, analysis) }
            sourceSilence.fulfill()
        }
        let prepared = try await decoder.prepare(url: url, token: 1, slot: 0)
        await fulfillment(of: [sourceSilence], timeout: 2)
        let analysis = try XCTUnwrap(observed.withLock { $0 })
        XCTAssertEqual(analysis.0, 1)
        XCTAssertEqual(analysis.1.totalFrames, 7)
        XCTAssertEqual(analysis.1.leadingFrames, 2)
        XCTAssertEqual(analysis.1.trailingFrames, 1)
        XCTAssertEqual(analysis.1.peak, 0.5)
        XCTAssertEqual(prepared.totalFrames, 7)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual = [Float](repeating: .nan, count: 14)
        actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 7) }
        XCTAssertEqual(actual, expected, "Genuine zero samples and the complete tail belong to the source")
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        renderer.setSuccessor(token: 1, for: 1)
        renderer.select(token: 1, frame: 0)
        actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 7) }
        XCTAssertEqual(actual, expected)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(failures.withLock { $0.isEmpty }, "A fully pinned loop must not reopen a reader beyond EOF")
    }

    func testAACPreparationLoopsTheDecodedPresentationWithoutAddingCodecPadding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("compressed.m4a")
        let frameCount = 12_345
        let samples = (0..<frameCount).flatMap { frame -> [Float] in
            let value: Float = frame < 240 || frame >= frameCount - 480 ? 0 : Float(sin(Double(frame) * 0.071)) * 0.2
            return [value, -value]
        }
        try writePCM(samples, to: url, compressed: true)
        let asset = AVURLAsset(url: url)
        let expected = try await independentlyDecode(asset)
        let renderer = ContinuousPCMRenderer(prefixFrames: 24_000, ringFrames: 24_000)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let prepared = try await decoder.prepare(url: url, token: 1, slot: 0)
        XCTAssertEqual(prepared.totalFrames, Int64(frameCount), "Container timing, rather than AAC packet size, defines the presentation")
        XCTAssertEqual(expected.count, frameCount * 2)
        renderer.setSuccessor(token: 1, for: 1)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual = [Float](repeating: .nan, count: expected.count * 3)
        var offset = 0
        while offset < frameCount * 3 {
            let count = min(257, frameCount * 3 - offset)
            actual.withUnsafeMutableBufferPointer {
                renderer.render(interleaved: UnsafeMutableBufferPointer(rebasing: $0[(offset * 2)..<((offset + count) * 2)]), frameCount: count)
            }
            offset += count
        }
        XCTAssertEqual(actual, expected + expected + expected, "Prepared AAC loops must join exact decoded samples, including source silence")
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testRemoteURLIsRejectedBeforeAnyReaderOrNetworkOperation() async throws {
        let renderer = ContinuousPCMRenderer(prefixFrames: 8, ringFrames: 8)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        do {
            _ = try await decoder.prepare(url: URL(string: "https://example.invalid/private.mp4")!, token: 1, slot: 0)
            XCTFail("Only an already-local Saved or verified playback-cache file may enter the PCM decoder")
        } catch let error as ContinuousPCMDecoder.Failure {
            XCTAssertEqual(error, .localFileRequired)
        }
    }

    func testPartialDecodeAndSeekToTheTailDoNotInventSourceSilenceMeasurements() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("partial.caf")
        try writePCM([Float](repeating: 0.25, count: 40_000), to: url)
        let renderer = ContinuousPCMRenderer(prefixFrames: 16, ringFrames: 32)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let reports = Mutex<Int>(0)
        decoder.setSourceSilenceHandler { _, _ in reports.withLock { $0 += 1 } }
        _ = try await decoder.prepare(url: url, token: 1, slot: 0)
        XCTAssertEqual(reports.withLock { $0 }, 0, "A full decode-ahead ring is still only a partial source")
        renderer.select(token: 1, frame: 19_999); renderer.setPlaying(true)
        var lastFrame = [Float](repeating: .nan, count: 2)
        // Publish the seek request to the worker; the unprepared seek may underrun.
        lastFrame.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1) }
        let deadline = Date().addingTimeInterval(2)
        while renderer.source(at: 0).availableStreamFrames != 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(renderer.source(at: 0).availableStreamFrames, 1)
        lastFrame.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1) }
        XCTAssertEqual(lastFrame, [0.25, 0.25])
        XCTAssertEqual(reports.withLock { $0 }, 0, "A tail-only reader cannot know source leading/trailing quiet frames")
    }

    func testPreparedAACAndALACVideosJoinInTheProductionGraphAndReverseWithoutExtraFrames() async throws {
        // The original MP3-in-MP4 asset has no iOS-readable audio track. The
        // archived iPhone compatibility derivative contains lossless ALAC.
        let urls = try ["test-video", "test-slideshow-mp3.iphone"].map {
            try XCTUnwrap(Bundle(for: Self.self).url(forResource: $0, withExtension: "mp4"))
        }
        let first = try await independentlyDecode(AVURLAsset(url: urls[0]))
        let second = try await independentlyDecode(AVURLAsset(url: urls[1]))
        let maximum = max(first.count, second.count) / 2
        guard maximum > 0, maximum <= 960_000 else { throw XCTSkip("Synthetic fixture outside the test's bounded PCM allocation") }
        // Retain these short synthetic sources completely so faster-than-realtime
        // offline rendering tests boundaries, rather than starving a real-time worker.
        let renderer = ContinuousPCMRenderer(prefixFrames: maximum + 1, ringFrames: 512)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let a = try await decoder.prepare(url: urls[0], token: 1, slot: 0)
        let b = try await decoder.prepare(url: urls[1], token: 2, slot: 1)
        XCTAssertEqual(a.totalFrames, Int64(first.count / 2))
        XCTAssertEqual(b.totalFrames, Int64(second.count / 2))
        renderer.setSuccessor(token: 2, for: 1)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        let graph = ContinuousAudioGraph(renderer: renderer)
        try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 257)
        try graph.engine.start()
        defer { graph.engine.stop() }
        let actual = try render(graph, frames: (first.count + second.count) / 2)
        assertSamples(actual, equal: first + second)
        // A prepared Previous changes only the source cursor inside the same graph.
        renderer.select(token: 1, frame: 0)
        assertSamples(try render(graph, frames: min(401, first.count / 2)), equal: Array(first.prefix(802)))
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testSampleRateConversionPreservesTheCompleteDeclaredTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("44100.caf")
        let samples = (0..<9_801).flatMap { frame -> [Float] in
            let value = Float(sin(Double(frame) * 0.071)) * 0.2
            return [value, -value]
        }
        try writePCM(samples, to: url, sampleRate: 44_100)
        let expected = try await independentlyDecode(AVURLAsset(url: url), diagnosticName: "sample-rate-44100-to-48000")
        let renderer = ContinuousPCMRenderer(prefixFrames: 20_000, ringFrames: 512)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let prepared = try await decoder.prepare(url: url, token: 1, slot: 0)
        XCTAssertEqual(prepared.totalFrames, 10_668, "9,801 / 44,100 seconds equals 10,668 samples at 48 kHz")
        XCTAssertEqual(expected.count, 10_668 * 2)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual = [Float](repeating: .nan, count: expected.count)
        actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: expected.count / 2) }
        assertSamples(actual, equal: expected)
    }

    func testStreamingRefillAndLoopReopenPreserveEveryFrameAcrossThePinnedPrefix() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stream.caf")
        let expected = (0..<4_097).flatMap { frame -> [Float] in
            let value = Float(frame % 97) / 128
            return [value, -value]
        }
        try writePCM(expected, to: url)
        let renderer = ContinuousPCMRenderer(prefixFrames: 512, ringFrames: 1_024)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        _ = try await decoder.prepare(url: url, token: 1, slot: 0)
        renderer.setSuccessor(token: 1, for: 1)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual: [Float] = []
        while actual.count < expected.count * 2 {
            let count = min(127, (expected.count * 2 - actual.count) / 2)
            var block = [Float](repeating: .nan, count: count * 2)
            block.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: count) }
            actual.append(contentsOf: block)
            // Give the one production worker time to refill; there is no test-only
            // synchronous decode path and no decoder call from the render thread.
            try await Task.sleep(for: .milliseconds(10))
        }
        assertSamples(actual, equal: expected + expected)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testAnAudioTrackOffsetRemainsPresentationSilenceRatherThanBeingTrimmedAsPriming() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tone.caf")
        let edited = directory.appendingPathComponent("offset.m4a")
        let samples = (0..<12_000).flatMap { frame -> [Float] in
            let value = Float(sin(Double(frame) * 0.071)) * 0.2
            return [value, -value]
        }
        try writePCM(samples, to: source)
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let composition = AVMutableComposition()
        let composed = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try composed.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 12_000, timescale: 48_000)),
            of: track, at: CMTime(value: 4_800, timescale: 48_000))
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A))
        try await export.export(to: edited, as: .m4a)
        let expected = try await independentlyDecode(AVURLAsset(url: edited), diagnosticName: "exported-audio-offset")
        XCTAssertEqual(expected.count, 16_800 * 2)
        XCTAssertTrue(expected.prefix(8_000).allSatisfy { abs($0) < 0.00001 })
        let renderer = ContinuousPCMRenderer(prefixFrames: 20_000, ringFrames: 512)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let prepared = try await decoder.prepare(url: edited, token: 1, slot: 0)
        XCTAssertEqual(prepared.totalFrames, 16_800)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual = [Float](repeating: .nan, count: expected.count)
        actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: expected.count / 2) }
        assertSamples(actual, equal: expected)
    }

    private func writePCM(_ samples: [Float], to url: URL, compressed: Bool = false, sampleRate: Double = 48_000) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / 2))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = samples[frame * 2]
            buffer.floatChannelData![1][frame] = samples[frame * 2 + 1]
        }
        let settings: [String: Any] = compressed
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
            : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private func render(_ graph: ContinuousAudioGraph, frames: Int) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: graph.engine.manualRenderingFormat, frameCapacity: 257)!
        var result: [Float] = []
        var retries = 0
        while result.count < frames * 2 {
            let count = min(257, frames - result.count / 2)
            let status = try graph.engine.renderOffline(AVAudioFrameCount(count), to: buffer)
            if status == .cannotDoInCurrentContext, retries < 10 { retries += 1; continue }
            XCTAssertEqual(status, .success)
            guard status == .success else { throw ContinuousPCMDecoder.Failure.cannotDecode }
            XCTAssertEqual(buffer.frameLength, AVAudioFrameCount(count))
            for frame in 0..<Int(buffer.frameLength) {
                result.append(buffer.floatChannelData![0][frame]); result.append(buffer.floatChannelData![1][frame])
            }
        }
        return result
    }

    private func assertSamples(_ actual: [Float], equal expected: [Float], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        let mismatch = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }
        XCTAssertNil(mismatch.map(\.offset), "First changed/inserted/dropped sample: \(String(describing: mismatch))", file: file, line: line)
    }

    /// Independent decoder comparison deliberately avoids the production timestamp/chunk helpers.
    private func independentlyDecode(_ asset: AVAsset, diagnosticName: String? = nil) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first, "Synthetic fixture needs an iOS-readable audio track")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        var packets = 0
        var firstPacket: [String: Double]?
        var lastPackets: [[String: Double]] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            bytes.withUnsafeBytes { samples.append(contentsOf: $0.bindMemory(to: Float.self)) }
            if diagnosticName != nil {
                func trimSeconds(_ key: CFString) -> Double {
                    guard let dictionary = CMGetAttachment(sample, key: key, attachmentModeOut: nil) as? [String: Any] else { return 0 }
                    return CMTimeMakeFromDictionary(dictionary as CFDictionary).seconds
                }
                let asbd = CMSampleBufferGetFormatDescription(sample).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }
                let packet: [String: Double] = [
                    "packet": Double(packets), "byteFrames": Double(bytes.count / 8),
                    "numSamples": Double(CMSampleBufferGetNumSamples(sample)),
                    "sampleRate": asbd?.pointee.mSampleRate ?? -1,
                    "rawPTS": CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                    "outputPTS": CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds,
                    "rawDuration": CMSampleBufferGetDuration(sample).seconds,
                    "outputDuration": CMSampleBufferGetOutputDuration(sample).seconds,
                    "trimStart": trimSeconds(kCMSampleBufferAttachmentKey_TrimDurationAtStart),
                    "trimEnd": trimSeconds(kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
                ].mapValues { $0.isFinite ? $0 : -1 }
                if firstPacket == nil { firstPacket = packet }
                lastPackets.append(packet)
                if lastPackets.count > 3 { lastPackets.removeFirst() }
                packets += 1
            }
        }
        XCTAssertEqual(reader.status, .completed)
        if let diagnosticName {
            let duration = try await asset.load(.duration)
            let range = try await track.load(.timeRange)
            let metrics: [String: Any] = ["fixture": diagnosticName, "assetSeconds": duration.seconds,
                "trackStartSeconds": range.start.seconds, "trackEndSeconds": range.end.seconds,
                "decodedFrames": samples.count / 2, "packets": packets,
                "first": firstPacket ?? [:], "last": lastPackets]
            let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
            print("PCM_PACKET_DIAGNOSTICS " + String(decoding: data, as: UTF8.self))
        }
        return samples
    }
}
