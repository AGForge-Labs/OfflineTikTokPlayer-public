import XCTest
import AVFoundation
import AudioToolbox
@testable import OfflineTikTokPlayer

@MainActor
final class SpeakerAudioTests: XCTestCase {
    func testColdSelectionUsesTheShortOptionalPreparationBudget() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let item = AVPlayerItem(url: url)
        let audio = SpeakerAudioController { _ in
            try? await Task.sleep(for: .seconds(2)); return nil
        }
        audio.update(items: [], enabled: true)
        let start = ContinuousClock.now
        await audio.prepare(item, within: .milliseconds(100))
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(300))
        XCTAssertNil(item.audioMix)
        print("Cold optional speaker preparation elapsed: \(elapsed)")
    }

    func testLoopReplicasKeepIndependentSpeakerProcessingState() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let asset = AVURLAsset(url: url), buffer = PlaybackBuffer(), audio = SpeakerAudioController()
        audio.update(items: [], enabled: true)
        let first = AVPlayerItem(asset: asset), next = AVPlayerItem(asset: asset), reserve = AVPlayerItem(asset: asset)
        await audio.prepare(first); await audio.prepare(next); await audio.prepare(reserve)
        let firstMix = try XCTUnwrap(first.audioMix), nextMix = try XCTUnwrap(next.audioMix), reserveMix = try XCTUnwrap(reserve.audioMix)
        XCTAssertFalse(firstMix === nextMix); XCTAssertFalse(nextMix === reserveMix)
        buffer.replace(with: first, mediaID: "loop")
        defer { buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.stage(.init(mediaID: "loop", item: next, isLocal: true))
        buffer.stageLoopReserve(.init(mediaID: "loop", item: reserve, isLocal: true))
        audio.update(items: buffer.player.items(), enabled: true)
        XCTAssertTrue(first.audioMix === firstMix); XCTAssertTrue(next.audioMix === nextMix); XCTAssertTrue(reserve.audioMix === reserveMix)
        audio.update(items: buffer.player.items(), enabled: false)
        XCTAssertTrue(buffer.player.items().allSatisfy { $0.audioMix == nil })
    }

    func testTimedOutOptionalPreparationRetriesWhenTheItemBecomesReady() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let item = AVPlayerItem(url: url)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        var attempts = 0
        let audio = SpeakerAudioController(preparationBudget: .milliseconds(20)) { _ in
            attempts += 1
            if attempts == 1 { try? await Task.sleep(for: .seconds(1)); return nil }
            return tracks
        }
        audio.update(items: [], enabled: true)
        await audio.prepare(item)
        XCTAssertNil(item.audioMix)
        let player = AVPlayer(playerItem: item)
        defer { player.replaceCurrentItem(with: nil) }
        let deadline = Date().addingTimeInterval(5)
        while item.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(item.status, .readyToPlay)
        audio.update(items: [item], enabled: true)
        let retryDeadline = Date().addingTimeInterval(1)
        while item.audioMix == nil, Date() < retryDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(item.audioMix, "A cold metadata timeout must not disable speaker enhancement for the entire clip")
        XCTAssertEqual(attempts, 2)
        audio.update(items: [item], enabled: false)
        XCTAssertNil(item.audioMix, "Headphones/Bluetooth and Original sound must remove the boost")
    }

    func testSlowPreparationFallsBackWithoutInstallingAMixAfterEnqueue() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let item = AVPlayerItem(url: url)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        var release: CheckedContinuation<Void, Never>?
        let audio = SpeakerAudioController(preparationBudget: .milliseconds(20)) { _ in
            await withCheckedContinuation { release = $0 }
            return tracks
        }
        audio.update(items: [], enabled: true)
        let start = ContinuousClock.now
        await audio.prepare(item)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertNil(item.audioMix)
        let buffer = PlaybackBuffer()
        buffer.replace(with: item); audio.update(items: buffer.player.items(), enabled: true)
        let continuation = try XCTUnwrap(release)
        continuation.resume()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(item.audioMix, "Late metadata must not rebuild the playing item's audio path")
        XCTAssertTrue(buffer.player.currentItem === item)
    }

    func testPreparedMixSurvivesEnqueueAndHandoffWithoutAnotherTrackLoad() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        var loads = 0
        let audio = SpeakerAudioController { item in
            loads += 1
            return try? await item.asset.loadTracks(withMediaType: .audio)
        }
        audio.update(items: [], enabled: true)
        let first = AVPlayerItem(url: url), next = AVPlayerItem(url: url), buffer = PlaybackBuffer()
        await audio.prepare(first)
        let firstMix = try XCTUnwrap(first.audioMix)
        buffer.replace(with: first); audio.update(items: buffer.player.items(), enabled: true)
        XCTAssertTrue(first.audioMix === firstMix)
        await audio.prepare(next)
        let nextMix = try XCTUnwrap(next.audioMix)
        buffer.stage(.init(mediaID: "next", item: next, isLocal: true))
        audio.update(items: buffer.player.items(), enabled: true)
        XCTAssertNotNil(buffer.advance(to: "next"))
        audio.update(items: buffer.player.items(), enabled: true)
        await Task.yield()
        XCTAssertTrue(next.audioMix === nextMix)
        XCTAssertEqual(loads, 2, "Swiping must reuse the configured audio pipeline")
    }

    func testDisablingSpeakerSoundDuringPreparationCannotInstallAStaleMix() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let item = AVPlayerItem(url: url)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        var release: CheckedContinuation<Void, Never>?
        let audio = SpeakerAudioController { _ in
            await withCheckedContinuation { release = $0 }
            return tracks
        }
        audio.update(items: [], enabled: true)
        let task = Task { await audio.prepare(item) }
        let deadline = Date().addingTimeInterval(2)
        while release == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let continuation = try XCTUnwrap(release)
        audio.update(items: [], enabled: false)
        continuation.resume()
        await task.value
        audio.update(items: [item], enabled: false)
        XCTAssertNil(item.audioMix)
    }

    func testAudioMixProcessesDecodedSamplesAndKeepsDurationAndChannels() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let mix = try XCTUnwrap(SpeakerAudioMix.make(tracks: tracks))
        let original = try decode(asset: asset, tracks: tracks, mix: nil)
        let enhanced = try decode(asset: asset, tracks: tracks, mix: mix)
        XCTAssertEqual(enhanced.count, original.count)
        XCTAssertFalse(enhanced.isEmpty)
        XCTAssertNotEqual(enhanced, original, "The native audio tap must actually process PCM")
        XCTAssertTrue(enhanced.allSatisfy { $0.isFinite && abs($0) <= 0.98001 })
        XCTAssertGreaterThan(enhanced.map { abs($0) }.max() ?? 0, 0.01)
        let originalRMS = sqrt(original.reduce(0.0) { $0 + Double($1 * $1) } / Double(original.count))
        let enhancedRMS = sqrt(enhanced.reduce(0.0) { $0 + Double($1 * $1) } / Double(enhanced.count))
        XCTAssertGreaterThan(enhancedRMS, originalRMS)
        XCTAssertLessThanOrEqual(enhanced.map { abs($0) }.max() ?? 0, 0.89001)
        print("Native speaker tap fixture: samples=\(enhanced.count), originalRMS=\(originalRMS), enhancedRMS=\(enhancedRMS), gainDB=\(20 * log10(enhancedRMS / originalRMS))")
    }

    func testRoutePolicyUsesOnlyBuiltInSpeakersAndOriginalChoiceBypasses() {
        XCTAssertTrue(SpeakerAudioMix.shouldEnhance(enabled: true, routes: [.builtInSpeaker]))
        for route: AVAudioSession.Port in [.headphones, .bluetoothA2DP, .airPlay, .builtInReceiver] {
            XCTAssertFalse(SpeakerAudioMix.shouldEnhance(enabled: true, routes: [route]))
        }
        XCTAssertFalse(SpeakerAudioMix.shouldEnhance(enabled: false, routes: [.builtInSpeaker]))
        XCTAssertNil(SpeakerAudioMix.make(tracks: []))
    }

    private func decode(asset: AVAsset, tracks: [AVAssetTrack], mix: AVAudioMix?) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        reader.add(output); XCTAssertTrue(reader.startReading())
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            bytes.withUnsafeBytes { result.append(contentsOf: $0.bindMemory(to: Float.self)) }
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        return result
    }
}
