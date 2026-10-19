import XCTest
import AVFoundation
import AudioToolbox
@testable import OfflineTikTokPlayer

@MainActor
final class NativeMediaTests: XCTestCase {
    func testVideoAndPhotoRenderHaveAudioAndAreSeekable() async throws {
        for name in ["test-video", "test-slideshow", "test-slideshow-mp3.iphone"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp4"))
            let asset = AVURLAsset(url: url)
            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration).seconds
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertTrue(playable); XCTAssertGreaterThan(duration, 0.8)
            XCTAssertFalse(video.isEmpty); XCTAssertFalse(audio.isEmpty)
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            let deadline = Date().addingTimeInterval(5)
            while player.currentItem?.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(player.currentItem?.status, .readyToPlay)
            let seeked = await withCheckedContinuation { continuation in
                player.seek(to: CMTime(seconds: 0.4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(seeked); XCTAssertEqual(player.currentTime().seconds, 0.4, accuracy: 0.05)
        }
    }

    func testArchivedAudioFormatsDecodeToNonSilentSamples() async throws {
        for name in ["test-video", "test-slideshow", "test-slideshow-mp3.iphone"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp4"))
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { XCTFail(name + " has no iOS-readable audio track"); continue }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(output)
            XCTAssertTrue(reader.startReading(), name)
            var peak: Float = 0
            while let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var bytes = Data(count: CMBlockBufferGetDataLength(block))
                let status = bytes.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                XCTAssertEqual(status, kCMBlockBufferNoErr)
                bytes.withUnsafeBytes { values in
                    for value in values.bindMemory(to: Float.self) { peak = max(peak, abs(value)) }
                }
            }
            XCTAssertEqual(reader.status, .completed, "\(name): \(String(describing: reader.error))")
            XCTAssertGreaterThan(peak, 0.01, name + " decoded silent audio")
        }
    }

    func testFileVerificationUsesActualBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        let digest = try AppFiles.hash(url)
        XCTAssertEqual(digest.size, 3)
        XCTAssertEqual(digest.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testPreparedNextClipBecomesCurrentWithoutReplacingThePlayer() async throws {
        let firstURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let secondURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-slideshow", withExtension: "mp4"))
        let buffer = PlaybackBuffer(), first = AVPlayerItem(url: firstURL), second = AVPlayerItem(url: secondURL)
        let persistentPlayer = buffer.player
        buffer.replace(with: first)
        buffer.stage(.init(mediaID: "second", item: second, isLocal: true))
        XCTAssertTrue(buffer.player.currentItem === first)
        XCTAssertEqual(buffer.player.items().count, 2)
        XCTAssertNil(buffer.advance(to: "wrong-queue-item"))
        XCTAssertTrue(buffer.player.currentItem === first)
        let prepared = try XCTUnwrap(buffer.advance(to: "second"))
        XCTAssertTrue(prepared.isLocal)
        XCTAssertTrue(buffer.player === persistentPlayer)
        XCTAssertTrue(buffer.player.currentItem === second)
        let deadline = Date().addingTimeInterval(5)
        while second.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(second.status, .readyToPlay)
        XCTAssertEqual(buffer.player.currentTime().seconds, 0, accuracy: 0.05)
        XCTAssertEqual(buffer.player.items().count, 1)
    }

    func testChangingUpcomingClipDoesNotDisturbCurrentPlaybackOrGrowTheBuffer() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let buffer = PlaybackBuffer(), current = AVPlayerItem(url: url)
        buffer.replace(with: current)
        for id in 0..<50 { buffer.stage(.init(mediaID: String(id), item: AVPlayerItem(url: url), isLocal: true)) }
        XCTAssertTrue(buffer.player.currentItem === current)
        XCTAssertEqual(buffer.player.items().count, 2)
        XCTAssertNil(buffer.advance(to: "0"))
        XCTAssertNotNil(buffer.advance(to: "49"))
    }

    func testOfflineHandoffRefusesRemoteStageAndAcceptsItsSavedReplacement() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let buffer = PlaybackBuffer(), current = AVPlayerItem(url: url)
        buffer.replace(with: current)
        buffer.stage(.init(mediaID: "next", item: AVPlayerItem(url: url), isLocal: false))
        XCTAssertNil(buffer.advance(to: "next", allowRemote: false))
        XCTAssertTrue(buffer.player.currentItem === current)
        let saved = AVPlayerItem(url: url)
        buffer.stage(.init(mediaID: "next", item: saved, isLocal: true), requireLocal: true)
        XCTAssertNotNil(buffer.advance(to: "next", allowRemote: false))
        XCTAssertTrue(buffer.player.currentItem === saved)
    }

    func testCacheCompletionDoesNotDiscardTheNextItemsPreparedPipeline() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let buffer = PlaybackBuffer(), current = AVPlayerItem(url: url), streaming = AVPlayerItem(url: url)
        buffer.replace(with: current)
        buffer.stage(.init(mediaID: "next", item: streaming, isLocal: false))
        buffer.stage(.init(mediaID: "next", item: AVPlayerItem(url: url), isLocal: true))
        XCTAssertTrue(buffer.player.items().last === streaming,
                      "Finishing a cache transfer must not replace the decoder the next swipe will use")
        XCTAssertTrue(buffer.advance(to: "next")?.item === streaming)
    }

    func testConfiguredQueuedHandoffAndRecordPlaybackClockLatency() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let buffer = PlaybackBuffer(), audio = SpeakerAudioController()
        audio.update(items: [], enabled: true)
        defer { buffer.player.pause(); buffer.replace(with: nil) }
        let coldStart = ProcessInfo.processInfo.systemUptime
        let first = AVPlayerItem(url: url)
        await audio.prepare(first)
        buffer.replace(with: first); audio.update(items: buffer.player.items(), enabled: true)
        buffer.player.playImmediately(atRate: 1)
        try await waitForPlaying(buffer.player)
        let cold = ProcessInfo.processInfo.systemUptime - coldStart
        let next = AVPlayerItem(url: url)
        await audio.prepare(next)
        let mix = try XCTUnwrap(next.audioMix)
        buffer.stage(.init(mediaID: "next", item: next, isLocal: false))
        audio.update(items: buffer.player.items(), enabled: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while next.status == .unknown, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(next.status, .failed)
        let readyBeforeHandoff = next.status == .readyToPlay
        // Simulate a cache transfer finishing immediately before the swipe.
        buffer.stage(.init(mediaID: "next", item: AVPlayerItem(url: url), isLocal: true))
        let warmStart = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(buffer.advance(to: "next")?.item === next)
        audio.update(items: buffer.player.items(), enabled: true)
        buffer.player.playImmediately(atRate: 1)
        try await waitForPlaying(buffer.player)
        let warm = ProcessInfo.processInfo.systemUptime - warmStart
        XCTAssertTrue(next.audioMix === mix)
        XCTAssertLessThan(warm, max(1, cold * 1.5), "A prepared handoff must not restart the media pipeline")
        let metrics: [String: Any] = ["coldClockAdvanceSeconds": cold, "queuedHandoffClockAdvanceSeconds": warm,
                                     "queuedItemReadyBeforeHandoff": readyBeforeHandoff]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics, options: .sortedKeys), uniformTypeIdentifier: "public.json")
        attachment.name = "Playback-startup-latency"; attachment.lifetime = .keepAlways; add(attachment)
        print("Playback clock latency fixture: cold=\(cold), queued=\(warm), readyBeforeHandoff=\(readyBeforeHandoff)")
    }

    private func waitForPlaying(_ player: AVPlayer) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while player.currentTime().seconds < 0.05, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 0.05)
    }
}
