import XCTest
import AVFoundation
import AudioToolbox
import Synchronization
import PlayerCore
@testable import OfflineTikTokPlayer

final class ContinuousPCMDecoderTests: XCTestCase {
    func testStagedNativeInputMatchesCompleteCallbackPresentationsAcrossCodecsAndRateRatios() async throws {
        #if DEBUG
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var urls: [URL] = []
        for (name, rate, frames, compressed) in [
            ("aac", 48_000.0, 12_345, true),
            ("fractional", 44_100.0, 9_801, false),
            ("upsample-partial", 8_000.0, 1_537, false),
            ("downsample-multirefill", 384_000.0, 65_539, false)
        ] {
            let url = directory.appendingPathComponent(name + (compressed ? ".m4a" : ".caf"))
            let samples = (0..<frames).flatMap { frame -> [Float] in
                let quiet = frame < 17 || (name != "fractional" && frame >= frames - 13)
                let value: Float = quiet ? 0 : Float(sin(Double(frame) * 0.071)) * 0.2
                return [value, -value]
            }
            try writePCM(samples, to: url, compressed: compressed, sampleRate: rate)
            urls.append(url)
        }
        let literal = directory.appendingPathComponent("literal.caf")
        try writePCM([0, 0, 0, 0, 0.125, -0.125, 0.25, -0.25, 0, 0, 0.5, -0.5, 0, 0], to: literal)
        urls.append(literal)
        urls.append(try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "mp3")))
        urls.append(try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-slideshow-mp3.iphone", withExtension: "mp4")))
        for url in urls {
            let expected = try await independentlyDecode(AVURLAsset(url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
            XCTAssertGreaterThan(expected.map { abs($0) }.max() ?? 0, 0.01)
            if url.lastPathComponent == "fractional.caf" {
                XCTAssertEqual(expected.count, 10_668 * 2)
                XCTAssertGreaterThan(abs(try XCTUnwrap(expected.suffix(2).first)), 0.01,
                    "The staged comparison must include the nonzero calculated fractional endpoint")
            }
            let baseline = try await decodePinnedPresentation(url: url, expected: expected, placement: .converterCallback)
            let staged = try await decodePinnedPresentation(url: url, expected: expected, placement: .stagedBeforeConversion)
            assertSamples(staged, equal: baseline)
        }
        #else
        throw XCTSkip("The staged native-input control is compiled only in DEBUG")
        #endif
    }

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
        let expected = try await independentlyDecode(asset, diagnosticName: "generated-aac")
        XCTAssertGreaterThan(expected.map { abs($0) }.max() ?? 0, 0.01, "AAC reference must contain the encoded tone")
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
        let epoch = renderer.source(at: 0).streamRequest.epoch
        let deadline = Date().addingTimeInterval(2)
        while renderer.source(at: 0).availableStreamFrames(for: epoch) != 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(renderer.source(at: 0).availableStreamFrames(for: epoch), 1)
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
        let first = try await independentlyDecode(AVURLAsset(url: urls[0]), diagnosticName: "aac-video")
        let second = try await independentlyDecode(AVURLAsset(url: urls[1]), diagnosticName: "alac-compatibility-video")
        XCTAssertGreaterThan(first.map { abs($0) }.max() ?? 0, 0.01, "AAC graph reference must contain audible tone")
        XCTAssertGreaterThan(second.map { abs($0) }.max() ?? 0, 0.01, "ALAC graph reference must contain audible tone")
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

    func testStandaloneMP3KeepsCompleteDecodedSamplesThroughGraphLoopsNextAndPrevious() async throws {
        let mp3 = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "mp3"))
        let expectedMP3 = try await independentlyDecode(AVURLAsset(url: mp3), diagnosticName: "standalone-mp3")
        XCTAssertGreaterThan(expectedMP3.count, 48_000, "The real MP3 decoder must return the complete synthetic tone")
        XCTAssertLessThan(expectedMP3.count, 192_000)
        XCTAssertGreaterThan(expectedMP3.map { abs($0) }.max() ?? 0, 0.01, "MP3 sample comparisons must exercise audible decoded tone")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let following = directory.appendingPathComponent("following.caf")
        let expectedFollowing: [Float] = [0.25, -0.25, 0.125, -0.125, 0, 0, 0.5, -0.5, 0, 0]
        try writePCM(expectedFollowing, to: following)
        let renderer = ContinuousPCMRenderer(prefixFrames: expectedMP3.count / 2 + 2_048, ringFrames: 512)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let prepared = try await decoder.prepare(url: mp3, token: 1, slot: 0)
        _ = try await decoder.prepare(url: following, token: 2, slot: 1)
        XCTAssertEqual(prepared.totalFrames, Int64(expectedMP3.count / 2), "MP3 loops must use its own decoded presentation, not the source MP4 edit duration")
        renderer.setSuccessor(token: 1, for: 1)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        let graph = ContinuousAudioGraph(renderer: renderer)
        try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 257)
        graph.engine.prepare()
        try graph.engine.start()
        defer { graph.engine.stop() }
        let looped = try render(graph, frames: expectedMP3.count / 2 * 3)
        XCTAssertGreaterThan(looped.map { abs($0) }.max() ?? 0, 0.01, "The production graph must emit audible MP3 samples")
        assertSamples(looped, equal: expectedMP3 + expectedMP3 + expectedMP3)
        renderer.setSuccessor(token: 2, for: 1)
        renderer.select(token: 1, frame: 0)
        assertSamples(try render(graph, frames: (expectedMP3.count + expectedFollowing.count) / 2), equal: expectedMP3 + expectedFollowing)
        // Repeated prepared Previous/Next commands keep the same running graph.
        for _ in 0..<8 {
            renderer.select(token: 1, frame: 0)
            assertSamples(try render(graph, frames: 193), equal: Array(expectedMP3.prefix(386)))
            renderer.select(token: 2, frame: 0)
            assertSamples(try render(graph, frames: expectedFollowing.count / 2), equal: expectedFollowing)
        }
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testRepeatedMP3ReadersAndPreparationsPreserveTheSameFullDeclaredPresentation() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "mp3"))
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        let end = CMTimeCompare(range.end, duration) > 0 ? range.end : duration
        let declaredFrames = CMTimeConvertScale(end, timescale: 48_000, method: .roundHalfAwayFromZero).value
        let expected = try await independentlyDecode(AVURLAsset(url: url), diagnosticName: "repeated-mp3-declared-presentation")
        XCTAssertEqual(expected.count, Int(declaredFrames) * 2, "The standalone fixture's precise declared timeline is authoritative")
        XCTAssertGreaterThan(expected.map { abs($0) }.max() ?? 0, 0.01)
        for _ in 0..<3 {
            let repeated = try await independentlyDecode(AVURLAsset(url: url))
            assertSamples(repeated, equal: expected)
            let renderer = ContinuousPCMRenderer(prefixFrames: 65_000, ringFrames: 512)
            let decoder = ContinuousPCMDecoder(renderer: renderer)
            defer { decoder.shutdown() }
            let prepared = try await decoder.prepare(url: url, token: 1, slot: 0)
            XCTAssertEqual(prepared.totalFrames, declaredFrames)
            XCTAssertEqual(renderer.source(at: 0).totalFrames, declaredFrames)
            renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
            var actual = [Float](repeating: .nan, count: expected.count)
            actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: expected.count / 2) }
            assertSamples(actual, equal: expected)
            XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        }
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
        let asset = AVURLAsset(url: url)
        let expected = try await independentlyDecode(asset, diagnosticName: "sample-rate-44100-to-48000")
        let withoutSupport = try await independentlyDecode(asset, quantizedEndSupport: false)
        XCTAssertEqual(withoutSupport.count, 10_667 * 2, "Characterize the converter's floor-sized termination without native support")
        assertSamples(Array(expected.prefix(withoutSupport.count)), equal: withoutSupport)
        let finalLeft = try XCTUnwrap(expected.suffix(2).first)
        XCTAssertGreaterThan(abs(finalLeft), 0.01,
            "The final fractional frame must be calculated from the source, not padded with an output zero")
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
            try await Self.waitForPreparedFrames(renderer, count: count, totalFrames: 4_097)
            var block = [Float](repeating: .nan, count: count * 2)
            block.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: count) }
            actual.append(contentsOf: block)
        }
        assertSamples(actual, equal: expected + expected)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testResampledStreamingLoopAndSeekRebuildTheOriginalConverterHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stream-44100.caf")
        let native = (0..<9_801).flatMap { frame -> [Float] in
            let value = frame < 42 || frame >= 9_784 ? 0 : Float(sin(Double(frame) * 0.071)) * 0.2
            return [value, -value]
        }
        try writePCM(native, to: url, sampleRate: 44_100)
        let expected = try await independentlyDecode(AVURLAsset(url: url), diagnosticName: "streamed-44100-to-48000")
        XCTAssertEqual(expected.count, 10_668 * 2)
        #if DEBUG
        let placements: [ContinuousPCMDecoder.NativeInputPlacement] = [.converterCallback, .stagedBeforeConversion]
        #else
        let placements: [ContinuousPCMDecoder.NativeInputPlacement] = [.converterCallback]
        #endif
        for placement in placements {
            let renderer = ContinuousPCMRenderer(prefixFrames: 512, ringFrames: 1_024)
            let decoder = ContinuousPCMDecoder(renderer: renderer, nativeInputPlacement: placement)
            defer { decoder.shutdown() }
            _ = try await decoder.prepare(url: url, token: 1, slot: 0)
            renderer.setSuccessor(token: 1, for: 1)
            renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
            var actual: [Float] = []
            while actual.count < expected.count * 3 {
                let count = min(127, (expected.count * 3 - actual.count) / 2)
                try await Self.waitForPreparedFrames(renderer, count: count, totalFrames: 10_668)
                var block = [Float](repeating: .nan, count: count * 2)
                block.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: count) }
                actual.append(contentsOf: block)
            }
            assertSamples(actual, equal: expected + expected + expected)
            // A paused render acknowledges the seek without consuming/starving it.
            renderer.setPlaying(false); renderer.select(token: 1, frame: 7_891)
            var block = [Float](repeating: .nan, count: 386)
            block.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 193) }
            try await Self.waitForPreparedFrames(renderer, count: 193, totalFrames: 10_668)
            renderer.setPlaying(true)
            block.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 193) }
            assertSamples(block, equal: Array(expected[(7_891 * 2)..<((7_891 + 193) * 2)]))
            XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
            #if DEBUG
            if case .stagedBeforeConversion = placement {
                XCTAssertGreaterThan(decoder.progressRecorder.debugStagedNativeReadCount, 0)
            } else {
                XCTAssertEqual(decoder.progressRecorder.debugStagedNativeReadCount, 0)
            }
            #endif
        }
    }

    @MainActor
    func testRetainedPreviousPrewarmsItsStreamingHeadBeforeReturningAcrossThePrefix() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let renderer = ContinuousPCMRenderer()
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let a = try await decoder.prepare(url: XCTUnwrap(fixture.savedURLs[fixture.aID]), token: 1, slot: 0)
        _ = try await decoder.prepare(url: XCTUnwrap(fixture.savedURLs[fixture.bID]), token: 2, slot: 1)
        let source = renderer.source(at: 0)
        let retainedBytes = renderer.retainedPCMMemoryBytes
        XCTAssertEqual(source.prefixFrameCount, 96_000)
        XCTAssertEqual(source.ringCapacityFrames, 192_000)
        XCTAssertEqual(retainedBytes, 3 * (96_000 + 192_000) * 2 * MemoryLayout<Float>.stride)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)

        // Consume A well beyond its pinned prefix so its current ring no longer
        // represents the stream head needed by Previous. Retain only three
        // seconds of reference PCM, with readiness controlling the first pass.
        let referenceFrames = 3 * 48_000, playedFrames = 204_000
        var reference: [Float] = []
        reference.reserveCapacity(referenceFrames * 2)
        var played = 0
        while played < playedFrames {
            let count = min(257, playedFrames - played)
            try await Self.waitForPreparedFrames(renderer, count: count, totalFrames: a.totalFrames)
            var block = [Float](repeating: .nan, count: count * 2)
            block.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: count) }
            let retainedFrames = min(count, max(0, referenceFrames - played))
            reference.append(contentsOf: block.prefix(retainedFrames * 2))
            played += count
        }
        XCTAssertEqual(renderer.snapshot.frame, Int64(playedFrames))
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        XCTAssertEqual(reference.count, referenceFrames * 2)
        XCTAssertGreaterThan(reference.map { abs($0) }.max() ?? 0, 0.01)
        XCTAssertGreaterThan(reference.dropFirst(source.prefixFrameCount * 2).map { abs($0) }.max() ?? 0, 0.01,
            "The reference must contain decoded tone beyond the pinned prefix")
        let oldEpoch = source.streamRequest.epoch

        renderer.select(token: 2, frame: 0)
        var selectedB = [Float](repeating: .nan, count: 512 * 2)
        selectedB.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 512) }
        XCTAssertEqual(renderer.snapshot.token, 2)
        let warmRequest = source.streamRequest
        XCTAssertGreaterThan(warmRequest.epoch, oldEpoch, "Leaving A must request its next frame-zero visit immediately")
        XCTAssertEqual(warmRequest.startFrame, Int64(source.prefixFrameCount))
        guard warmRequest.epoch > oldEpoch else { throw ContinuousPCMDecoder.Failure.cannotDecode }
        let deadline = Date().addingTimeInterval(5)
        let requiredWarmFrames = 3 * 48_000
        while source.availableStreamFrames(for: warmRequest.epoch) < requiredWarmFrames {
            guard Date() < deadline else {
                XCTFail("The actual serial decoder did not prewarm retained A while B was current")
                throw ContinuousPCMDecoder.Failure.cannotDecode
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(renderer.snapshot.token, 2)
        let readyFrames = source.availableStreamFrames(for: warmRequest.epoch)
        let beforeReturnUnderruns = renderer.snapshot.underrunFrames
        XCTAssertEqual(beforeReturnUnderruns, 0)

        // No producer-readiness wait is allowed after Previous. A's prepared
        // stream head must survive selection and supply every sample after its
        // two-second prefix, even when manual rendering runs faster than audio.
        renderer.select(token: 1, frame: 0)
        var returned = [Float](repeating: .nan, count: referenceFrames * 2)
        var rendered = 0
        while rendered < referenceFrames {
            let count = min(257, referenceFrames - rendered)
            returned.withUnsafeMutableBufferPointer {
                renderer.render(interleaved: UnsafeMutableBufferPointer(rebasing: $0[(rendered * 2)..<((rendered + count) * 2)]), frameCount: count)
            }
            rendered += count
        }
        let returnedEpoch = source.streamRequest.epoch
        let underrunDelta = renderer.snapshot.underrunFrames - beforeReturnUnderruns
        XCTAssertEqual(renderer.snapshot.token, 1)
        XCTAssertEqual(renderer.snapshot.frame, Int64(referenceFrames))
        XCTAssertEqual(returnedEpoch, warmRequest.epoch, "Previous must adopt the already-committed stream request")
        XCTAssertEqual(underrunDelta, 0, "Returning to a prepared source must not exhaust its prefix while rewinding")
        XCTAssertGreaterThan(returned.map { abs($0) }.max() ?? 0, 0.01)
        assertSamples(returned, equal: reference)
        XCTAssertEqual(renderer.retainedPCMMemoryBytes, retainedBytes)
        print("PCM_PREWARM_ABA oldEpoch=\(oldEpoch) warmEpoch=\(warmRequest.epoch) returnedEpoch=\(returnedEpoch) readyFrames=\(readyFrames) renderedFrames=\(rendered) underrunDelta=\(underrunDelta) retainedBytes=\(retainedBytes)")
    }

    func testLeavingAFarSeekYieldsToCurrentRefillAndPrewarmsTheRetainedHead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let far = directory.appendingPathComponent("far.caf"), current = directory.appendingPathComponent("current.caf")
        // The two-minute low-rate file is written with one fixed-size buffer.
        // No complete long-source PCM array is retained by this test or decoder.
        try writeConstantPCM(frames: 120 * 8_000, sampleRate: 8_000, value: 0.125, to: far)
        try writePCM([Float](repeating: 0.375, count: 4_097 * 2), to: current)
        let renderer = ContinuousPCMRenderer(prefixFrames: 64, ringFrames: 128)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        _ = try await decoder.prepare(url: far, token: 1, slot: 0)
        _ = try await decoder.prepare(url: current, token: 2, slot: 1)
        renderer.select(token: 1, frame: 119 * 48_000)
        var acknowledged = [Float](repeating: .nan, count: 2)
        acknowledged.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1) }
        let farEpoch = renderer.source(at: 0).streamRequest.epoch
        let firstYield = Date().addingTimeInterval(3)
        while decoder.cooperativeYieldCount == 0, Date() < firstYield {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertGreaterThan(decoder.cooperativeYieldCount, 0, "A far seek must return the serial worker between bounded discard steps")
        // Leaving A supersedes its distant seek with a frame-zero prewarm.
        // B consumes all its prepared PCM and must refill on the same worker.
        renderer.select(token: 2, frame: 0); renderer.setPlaying(true)
        var initial = [Float](repeating: .nan, count: 192 * 2)
        initial.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 192) }
        XCTAssertTrue(initial.allSatisfy { $0 == 0.375 })
        let headRequest = renderer.source(at: 0).streamRequest
        XCTAssertGreaterThan(headRequest.epoch, farEpoch)
        XCTAssertEqual(headRequest.startFrame, 64)
        let currentSource = renderer.source(at: 1), currentEpoch = currentSource.streamRequest.epoch
        let refill = Date().addingTimeInterval(3)
        while currentSource.availableStreamFrames(for: currentEpoch) < 128, Date() < refill {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(currentSource.availableStreamFrames(for: currentEpoch), 128)
        XCTAssertEqual(renderer.source(at: 0).availableStreamFrames(for: farEpoch), 0,
            "The obsolete distant seek must not publish readiness after A is rearmed")
        var next = [Float](repeating: .nan, count: 128 * 2)
        next.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 128) }
        XCTAssertTrue(next.allSatisfy { $0 == 0.375 })
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0, "Retiring distant work must not starve current B")
        let retainedReady = Date().addingTimeInterval(3)
        while renderer.source(at: 0).availableStreamFrames(for: headRequest.epoch) < 128, Date() < retainedReady {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(renderer.source(at: 0).availableStreamFrames(for: headRequest.epoch), 128,
            "The retained source must prepare its next visit instead of finishing an obsolete far seek")
        // A fresh selection requests a fresh epoch; verify it also eventually
        // reaches the exact steady-state PCM after rebuilding the same history.
        renderer.setPlaying(false); renderer.select(token: 1, frame: 119 * 48_000)
        acknowledged.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1) }
        try await Self.waitForPreparedFrames(renderer, count: 16, totalFrames: 120 * 48_000, timeout: 12)
        renderer.setPlaying(true)
        var resumed = [Float](repeating: .nan, count: 16 * 2)
        resumed.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 16) }
        for sample in resumed { XCTAssertEqual(sample, 0.125, accuracy: 0.00001) }
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testAnAudioTrackOffsetRemainsPresentationSilenceRatherThanBeingTrimmedAsPriming() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tone.caf")
        let edited = directory.appendingPathComponent("offset.mov")
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
        // Preserve the PCM and its edit offset without AAC export quantization.
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
            "The offset fixture requires lossless PCM passthrough export")
        guard export.supportedFileTypes.contains(.mov) else {
            XCTFail("Lossless PCM passthrough must support a MOV offset fixture")
            throw ContinuousPCMDecoder.Failure.unsupportedPCM
        }
        try await export.export(to: edited, as: .mov)
        let editedAsset = AVURLAsset(url: edited, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let editedTracks = try await editedAsset.loadTracks(withMediaType: .audio)
        let editedTrack = try XCTUnwrap(editedTracks.first, "The MOV offset fixture must retain its PCM track")
        let range = try await editedTrack.load(.timeRange)
        let duration = try await editedAsset.load(.duration)
        let segments = try await editedTrack.load(.segments)
        let content = try XCTUnwrap(segments.first { !$0.isEmpty },
            "The MOV fixture must retain a nonempty PCM edit segment")
        let contentStart = CMTime(value: 4_800, timescale: 48_000)
        let presentationEnd = CMTime(value: 16_800, timescale: 48_000)
        // The track range includes its leading empty edit; the content segment
        // identifies the exact offset without treating presentation silence as priming.
        XCTAssertEqual(CMTimeCompare(content.timeMapping.target.start, contentStart), 0,
            "The MOV PCM content must start at exactly 0.1 seconds")
        XCTAssertEqual(CMTimeCompare(content.timeMapping.target.end, presentationEnd), 0,
            "The MOV PCM content must retain its complete 12,000-frame span")
        if let first = segments.first, first.isEmpty {
            XCTAssertEqual(CMTimeCompare(first.timeMapping.target.start, .zero), 0,
                "The leading empty edit must begin at presentation zero")
            XCTAssertEqual(CMTimeCompare(first.timeMapping.target.end, contentStart), 0,
                "The leading empty edit must preserve all 4,800 quiet frames")
        }
        XCTAssertEqual(CMTimeCompare(range.end, presentationEnd), 0,
            "The MOV track must end at exactly 0.35 seconds")
        XCTAssertEqual(CMTimeCompare(duration, presentationEnd), 0,
            "The MOV asset must present exactly 16,800 frames at 48 kHz")
        let formats = try await editedTrack.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format))
        XCTAssertEqual(asbd.pointee.mFormatID, kAudioFormatLinearPCM, "The offset fixture must remain lossless PCM")
        XCTAssertEqual(asbd.pointee.mSampleRate, 48_000)
        let expected = try await independentlyDecode(editedAsset, diagnosticName: "exported-audio-offset")
        XCTAssertGreaterThan(expected.map { abs($0) }.max() ?? 0, 0.01, "The edited PCM reference must retain its tone")
        XCTAssertEqual(expected.count, 16_800 * 2)
        XCTAssertTrue(expected.prefix(4_800 * 2).allSatisfy { abs($0) < 0.00001 })
        let renderer = ContinuousPCMRenderer(prefixFrames: 20_000, ringFrames: 512)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let prepared = try await decoder.prepare(url: edited, token: 1, slot: 0)
        XCTAssertEqual(prepared.totalFrames, 16_800)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual = [Float](repeating: .nan, count: 16_800 * 2)
        actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 16_800) }
        assertSamples(actual, equal: expected)
        #if DEBUG
        _ = try await decodePinnedPresentation(url: edited, expected: expected, placement: .stagedBeforeConversion)
        #endif
    }

    #if DEBUG
    private func decodePinnedPresentation(url: URL, expected: [Float], placement: ContinuousPCMDecoder.NativeInputPlacement) async throws -> [Float] {
        let frames = expected.count / 2
        guard frames > 0, frames <= 960_000 else {
            XCTFail("Only bounded public/synthetic fixtures enter this comparison")
            throw ContinuousPCMDecoder.Failure.invalidTimeline
        }
        let renderer = ContinuousPCMRenderer(prefixFrames: frames + 1, ringFrames: 512)
        let decoder = ContinuousPCMDecoder(renderer: renderer, nativeInputPlacement: placement)
        defer { decoder.shutdown() }
        let prepared = try await decoder.prepare(url: url, token: 1, slot: 0)
        XCTAssertEqual(prepared.totalFrames, Int64(frames))
        renderer.setSuccessor(token: 1, for: 1)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual = [Float](repeating: .nan, count: expected.count * 2)
        actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: frames * 2) }
        assertSamples(actual, equal: expected + expected)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        if case .stagedBeforeConversion = placement {
            XCTAssertGreaterThan(decoder.progressRecorder.debugStagedNativeReadCount, 0)
        } else {
            XCTAssertEqual(decoder.progressRecorder.debugStagedNativeReadCount, 0)
        }
        return Array(actual.prefix(expected.count))
    }
    #endif

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

    private func writeConstantPCM(frames: Int, sampleRate: Double, value: Float, to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192))
        for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: value, count: Int(buffer.frameCapacity)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var remaining = frames
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(remaining, Int(buffer.frameCapacity)))
            try file.write(from: buffer); remaining -= Int(buffer.frameLength)
        }
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

    private static func waitForPreparedFrames(_ renderer: ContinuousPCMRenderer, count: Int, totalFrames: Int64, timeout: Double = 3) async throws {
        let source = renderer.source(at: 0)
        let frame = renderer.snapshot.frame
        let streamedStart = max(frame, Int64(source.prefixCapacityFrames))
        let streamedEnd = min(frame + Int64(count), totalFrames)
        let needed = max(0, Int(streamedEnd - streamedStart))
        guard needed > 0 else { return }
        let epoch = source.streamRequest.epoch
        let deadline = Date().addingTimeInterval(timeout)
        while source.availableStreamFrames(for: epoch) < needed {
            guard Date() < deadline else {
                XCTFail("Prepared decoder epoch did not supply the exact next sample span")
                throw ContinuousPCMDecoder.Failure.cannotDecode
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func assertSamples(_ actual: [Float], equal expected: [Float], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        let mismatch = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }
        XCTAssertNil(mismatch.map(\.offset), "First changed/inserted/dropped sample: \(String(describing: mismatch))", file: file, line: line)
    }

    /// Array-backed reference: native PCM first, then a separate converter driver
    /// using 113-frame input and 257-frame output blocks (production uses 4096).
    /// This avoids the implicit AudioMixOutput converter that lost its tail.
    private func independentlyDecode(_ inputAsset: AVAsset, diagnosticName: String? = nil, quantizedEndSupport: Bool = true) async throws -> [Float] {
        let asset: AVAsset
        if let urlAsset = inputAsset as? AVURLAsset {
            asset = AVURLAsset(url: urlAsset.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        } else { asset = inputAsset }
        guard try await asset.load(.providesPreciseDurationAndTiming) else {
            XCTFail("Full-presentation comparisons require precise source timing")
            throw ContinuousPCMDecoder.Failure.unsupportedPCM
        }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first, "Synthetic fixture needs an iOS-readable audio track")
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        let sourceASBD = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description))
        let rate = sourceASBD.pointee.mSampleRate
        let channels = Int(sourceASBD.pointee.mChannelsPerFrame)
        let duration = try await asset.load(.duration)
        let range = try await track.load(.timeRange)
        let readEnd = CMTimeCompare(range.end, duration) > 0 ? range.end : duration
        let nativePresentationFrames = Int(CMTimeConvertScale(readEnd, timescale: CMTimeScale(rate), method: .roundHalfAwayFromZero).value)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: readEnd)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        var packets = 0
        var firstPacket: [String: Double]?
        var lastPackets: [[String: Double]] = []
        var outsidePresentationFrames = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            func trimSeconds(_ key: CFString) -> Double {
                guard let dictionary = CMGetAttachment(sample, key: key, attachmentModeOut: nil) as? [String: Any] else { return 0 }
                return CMTimeMakeFromDictionary(dictionary as CFDictionary).seconds
            }
            let trimStart = Int((trimSeconds(kCMSampleBufferAttachmentKey_TrimDurationAtStart) * rate).rounded())
            let trimEnd = Int((trimSeconds(kCMSampleBufferAttachmentKey_TrimDurationAtEnd) * rate).rounded())
            let packetFrames = bytes.count / (channels * 4)
            let packetStart = Int((CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds * rate).rounded())
            let decodedFrames = packetFrames - trimStart - trimEnd
            XCTAssertGreaterThanOrEqual(decodedFrames, 0)
            guard decodedFrames >= 0 else { throw ContinuousPCMDecoder.Failure.invalidTimeline }
            let validFrames = max(0, min(decodedFrames, nativePresentationFrames - packetStart))
            let included = max(0, min(nativePresentationFrames, packetStart + decodedFrames) - max(0, packetStart))
            outsidePresentationFrames += decodedFrames - included
            let oldFrames = samples.count / channels
            if packetStart > oldFrames {
                samples.append(contentsOf: repeatElement(0, count: (min(packetStart, nativePresentationFrames) - oldFrames) * channels))
            }
            let skipped = max(0, samples.count / channels - packetStart)
            if skipped < validFrames {
                bytes.withUnsafeBytes {
                    let values = $0.bindMemory(to: Float.self)
                    samples.append(contentsOf: values[((trimStart + skipped) * channels)..<((trimStart + validFrames) * channels)])
                }
            }
            if diagnosticName != nil {
                let asbd = CMSampleBufferGetFormatDescription(sample).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }
                let packet: [String: Double] = [
                    "packet": Double(packets), "byteFrames": Double(packetFrames),
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
        let nativeFrames = nativePresentationFrames
        XCTAssertLessThanOrEqual(samples.count / channels, nativeFrames)
        samples.append(contentsOf: repeatElement(0, count: nativeFrames * channels - samples.count))
        let inputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: UInt32(channels), interleaved: true))
        let outputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))
        if channels == 1 { converter.channelMap = [0, 0] }
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 113))
        let outputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 257))
        let presentationFrames = Int(CMTimeConvertScale(readEnd, timescale: 48_000, method: .roundHalfAwayFromZero).value)
        let requiredNative = (Int64(presentationFrames) * Int64(rate) + 47_999) / 48_000
        let supportFrames = quantizedEndSupport ? max(0, Int(requiredNative) - nativeFrames) : 0
        XCTAssertLessThanOrEqual(supportFrames, Int(ceil(rate / 96_000 + 0.5)))
        var suppliedSupport = 0
        var inputOffset = 0, converted: [Float] = [], iterations = 0
        while true {
            iterations += 1
            guard iterations < 100_000 else { throw ContinuousPCMDecoder.Failure.cannotDecode }
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, status in
                guard requested > 0 else { status.pointee = .noDataNow; return nil }
                let count = min(Int(requested), 113, nativeFrames - inputOffset)
                guard count > 0 else {
                    let needed = supportFrames - suppliedSupport
                    if needed > 0 {
                        let count = min(needed, Int(requested), 113)
                        guard count > 0 else { status.pointee = .endOfStream; return nil }
                        inputBuffer.floatChannelData![0].update(repeating: 0, count: count * channels)
                        inputBuffer.frameLength = AVAudioFrameCount(count); suppliedSupport += count
                        status.pointee = .haveData; return inputBuffer
                    }
                    status.pointee = .endOfStream; return nil
                }
                samples.withUnsafeBufferPointer {
                    inputBuffer.floatChannelData![0].update(from: $0.baseAddress!.advanced(by: inputOffset * channels), count: count * channels)
                }
                inputBuffer.frameLength = AVAudioFrameCount(count); inputOffset += count
                status.pointee = .haveData; return inputBuffer
            }
            XCTAssertNil(conversionError)
            XCTAssertNotEqual(status, .error)
            guard status != .error else { throw ContinuousPCMDecoder.Failure.cannotDecode }
            converted.append(contentsOf: UnsafeBufferPointer(start: outputBuffer.floatChannelData![0], count: Int(outputBuffer.frameLength) * 2))
            if status == .endOfStream { break }
        }
        if quantizedEndSupport {
            XCTAssertGreaterThanOrEqual(converted.count, presentationFrames * 2,
                "Native support and explicit flushing must calculate every declared presentation frame")
            XCTAssertLessThanOrEqual(converted.count / 2, presentationFrames + Int(ceil(48_000 / rate)),
                "Only the bounded native support may generate samples outside the declared timeline")
        }
        if let diagnosticName {
            let metrics: [String: Any] = ["fixture": diagnosticName, "assetSeconds": duration.seconds,
                "trackStartSeconds": range.start.seconds, "trackEndSeconds": range.end.seconds,
                "nativeDecodedFrames": samples.count / channels, "convertedFrames": converted.count / 2,
                "presentationFrames": presentationFrames, "nativeSupportFrames": suppliedSupport,
                "outsidePresentationNativeFrames": outsidePresentationFrames, "packets": packets,
                "nativePeak": samples.reduce(0.0) { max($0, Double(abs($1))) },
                "convertedPeak": converted.reduce(0.0) { max($0, Double(abs($1))) },
                "first": firstPacket ?? [:], "last": lastPackets]
            let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
            print("PCM_PACKET_DIAGNOSTICS " + String(decoding: data, as: UTF8.self))
        }
        // Support is outside the original presentation. Its filter response is
        // needed to calculate the final included frame, not to extend playback.
        return quantizedEndSupport ? Array(converted.prefix(presentationFrames * 2)) : converted
    }
}
