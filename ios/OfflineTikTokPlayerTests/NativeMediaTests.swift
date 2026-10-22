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

    func testPromotingPreviousToNextPreservesExactPreparationAndPlayerPolicy() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        for needsRewind in [false, true] {
            let buffer = PlaybackBuffer(), current = AVPlayerItem(url: url), previous = AVPlayerItem(url: url)
            buffer.automaticAdvancementEnabled = needsRewind
            buffer.usesExternalClock = true
            let player = buffer.player
            let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: previous)
            let resource = try XCTUnwrap(plan.install()), output = try XCTUnwrap(resource.output)
            defer {
                buffer.player.pause(); buffer.replace(with: nil); buffer.discardPrevious(); resource.retire()
                XCTAssertTrue(previous.outputs.isEmpty); XCTAssertNil(previous.videoComposition)
            }
            XCTAssertTrue(buffer.replace(with: current, mediaID: "B"))
            let reachedEnd = !needsRewind
            XCTAssertTrue(buffer.stagePrevious(.init(mediaID: "A", item: previous, isLocal: true,
                needsRewind: needsRewind, reachedEnd: reachedEnd, videoResource: resource)))
            XCTAssertTrue(player.currentItem === current); XCTAssertEqual(player.items().count, 1)
            XCTAssertEqual(buffer.previousMediaID, "A"); XCTAssertNil(buffer.nextMediaID)
            XCTAssertFalse(buffer.hasLoopReserve); XCTAssertTrue(player.canInsert(previous, after: current))
            #if DEBUG
            XCTAssertEqual(buffer.debugPreviousNeedsRewind, needsRewind)
            #endif
            var eligibilityCalls = 0
            XCTAssertTrue(buffer.promotePreviousToNext(mediaID: "A", after: "B", allowRemote: false,
                ifEligible: { eligibilityCalls += 1; return true }))
            XCTAssertEqual(eligibilityCalls, 2, "Initial and post-canInsert precommit eligibility checks")
            XCTAssertTrue(buffer.player === player); XCTAssertTrue(player.currentItem === current)
            XCTAssertEqual(player.items().map(ObjectIdentifier.init), [current, previous].map(ObjectIdentifier.init))
            XCTAssertNil(buffer.previousMediaID, "Promotion transfers the slot; it must not leave a previous/next alias")
            XCTAssertEqual(buffer.nextMediaID, "A"); XCTAssertTrue(buffer.hasPrepared("A")); XCTAssertFalse(buffer.hasLoopReserve)
            XCTAssertEqual(buffer.retainedItemCount, 2); XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(player.actionAtItemEnd, needsRewind ? .advance : .pause)
            XCTAssertFalse(player.automaticallyWaitsToMinimizeStalling)
            XCTAssertTrue(buffer.resource(for: previous) === resource)
            XCTAssertTrue(resource.item === previous); XCTAssertTrue(resource.output === output)
            XCTAssertTrue(resource.isAttached); XCTAssertFalse(resource.isRetired); XCTAssertFalse(resource.isBorrowed)
            XCTAssertEqual(previous.outputs.count, 1); XCTAssertTrue(previous.outputs.first === output)
            XCTAssertFalse(buffer.promotePreviousToNext(mediaID: "A", after: "B"), "No second transfer exists")
            XCTAssertEqual(player.items().map(ObjectIdentifier.init), [current, previous].map(ObjectIdentifier.init))
            let promoted = try XCTUnwrap(buffer.advance(to: "A", allowRemote: false))
            XCTAssertTrue(promoted.item === previous); XCTAssertTrue(promoted.videoResource === resource)
            XCTAssertTrue(promoted.isLocal); XCTAssertEqual(promoted.needsRewind, needsRewind)
            XCTAssertEqual(promoted.reachedEnd, reachedEnd)
            XCTAssertTrue(player.currentItem === previous); XCTAssertEqual(player.items().count, 1)
        }
    }

    func testPromotingPreviousRefusesConflictsAndHonorsSavedEligibility() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        for withReserve in [false, true] {
            let buffer = PlaybackBuffer(), current = AVPlayerItem(url: url), previous = AVPlayerItem(url: url)
            let next = AVPlayerItem(url: url)
            buffer.automaticAdvancementEnabled = false; buffer.usesExternalClock = true
            defer { buffer.player.pause(); buffer.replace(with: nil); buffer.discardPrevious() }
            XCTAssertTrue(buffer.replace(with: current, mediaID: "B"))
            XCTAssertTrue(buffer.stagePrevious(.init(mediaID: "A", item: previous, isLocal: true, needsRewind: true)))
            let nextID = withReserve ? "B" : "C"
            XCTAssertTrue(buffer.stage(.init(mediaID: nextID, item: next, isLocal: true), after: "B"))
            var expectedQueue = [current, next]
            if withReserve {
                let reserve = AVPlayerItem(url: url)
                buffer.stageLoopReserve(.init(mediaID: "B", item: reserve, isLocal: true))
                expectedQueue.append(reserve)
            }
            XCTAssertTrue(buffer.hasPrepared(nextID)); XCTAssertEqual(buffer.hasLoopReserve, withReserve)
            let queue = buffer.player.items().map(ObjectIdentifier.init)
            let retained = Set(buffer.retainedItems.map(ObjectIdentifier.init))
            XCTAssertEqual(queue, expectedQueue.map(ObjectIdentifier.init))
            XCTAssertEqual(retained.count, withReserve ? 4 : 3)
            XCTAssertFalse(buffer.promotePreviousToNext(mediaID: "A", after: "B", allowRemote: false))
            XCTAssertTrue(buffer.player.currentItem === current)
            XCTAssertEqual(buffer.player.items().map(ObjectIdentifier.init), queue)
            XCTAssertEqual(Set(buffer.retainedItems.map(ObjectIdentifier.init)), retained)
            XCTAssertEqual(buffer.previousMediaID, "A"); XCTAssertEqual(buffer.nextMediaID, nextID)
            XCTAssertEqual(buffer.hasLoopReserve, withReserve); XCTAssertTrue(buffer.hasPrepared(nextID))
            XCTAssertEqual(buffer.player.actionAtItemEnd, .pause); XCTAssertFalse(buffer.player.automaticallyWaitsToMinimizeStalling)
            #if DEBUG
            XCTAssertEqual(buffer.debugPreviousNeedsRewind, true)
            #endif
        }
        // As in the existing offline handoff contract, the synthetic local URL is
        // shared; isLocal exercises Saved eligibility without network or waiting.
        for saved in [false, true] {
            let buffer = PlaybackBuffer(), current = AVPlayerItem(url: url), previous = AVPlayerItem(url: url)
            buffer.automaticAdvancementEnabled = false; buffer.usesExternalClock = true
            defer { buffer.player.pause(); buffer.replace(with: nil); buffer.discardPrevious() }
            XCTAssertTrue(buffer.replace(with: current, mediaID: "B"))
            XCTAssertTrue(buffer.stagePrevious(.init(mediaID: "A", item: previous, isLocal: saved, needsRewind: true)))
            if !saved {
                XCTAssertFalse(buffer.promotePreviousToNext(mediaID: "A", after: "B", allowRemote: false))
                XCTAssertTrue(buffer.player.currentItem === current); XCTAssertEqual(buffer.player.items().count, 1)
                XCTAssertEqual(buffer.previousMediaID, "A"); XCTAssertNil(buffer.nextMediaID)
                XCTAssertEqual(buffer.retainedItemCount, 2)
            }
            XCTAssertTrue(buffer.promotePreviousToNext(mediaID: "A", after: "B", allowRemote: !saved))
            XCTAssertTrue(buffer.player.currentItem === current)
            XCTAssertEqual(buffer.player.items().map(ObjectIdentifier.init), [current, previous].map(ObjectIdentifier.init))
            XCTAssertNil(buffer.previousMediaID); XCTAssertEqual(buffer.nextMediaID, "A")
            XCTAssertEqual(buffer.retainedItemCount, 2); XCTAssertFalse(buffer.hasLoopReserve)
            let promoted = try XCTUnwrap(buffer.advance(to: "A", allowRemote: !saved))
            XCTAssertTrue(promoted.item === previous); XCTAssertEqual(promoted.isLocal, saved)
            XCTAssertTrue(promoted.needsRewind); XCTAssertFalse(promoted.reachedEnd)
        }
    }

    func testPromotingPreviousRevalidatesOwnerAfterNativeInsertionEligibility() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let buffer = PlaybackBuffer(), current = AVPlayerItem(url: url), previous = AVPlayerItem(url: url)
        let replacement = AVPlayerItem(url: url), replacementNext = AVPlayerItem(url: url)
        buffer.automaticAdvancementEnabled = false; buffer.usesExternalClock = true
        defer { buffer.player.pause(); buffer.replace(with: nil); buffer.discardPrevious() }
        XCTAssertTrue(buffer.replace(with: current, mediaID: "B"))
        XCTAssertTrue(buffer.stagePrevious(.init(mediaID: "A", item: previous, isLocal: true, needsRewind: true)))
        XCTAssertTrue(buffer.player.canInsert(previous, after: current), "Positive actual SDK insertion precondition")
        var eligibilityCalls = 0, interventions = 0
        let promoted = buffer.promotePreviousToNext(mediaID: "A", after: "B", ifEligible: {
            eligibilityCalls += 1
            if eligibilityCalls == 2 {
                // Pinned API checkpoint: after its actual canInsert, before commit.
                // This is synchronous test reentry, not a claimed native KVO event.
                interventions += 1
                XCTAssertTrue(buffer.replace(with: replacement, mediaID: "C"))
                XCTAssertTrue(buffer.stage(.init(mediaID: "D", item: replacementNext, isLocal: true), after: "C"))
                XCTAssertTrue(buffer.player.currentItem === replacement)
                XCTAssertEqual(buffer.nextMediaID, "D")
            }
            return true // The outer operation must revalidate owners, not just this Boolean.
        })
        XCTAssertEqual(eligibilityCalls, 2); XCTAssertEqual(interventions, 1)
        XCTAssertFalse(promoted)
        XCTAssertTrue(buffer.player.currentItem === replacement)
        XCTAssertEqual(buffer.player.items().map(ObjectIdentifier.init), [replacement, replacementNext].map(ObjectIdentifier.init))
        XCTAssertEqual(buffer.nextMediaID, "D"); XCTAssertTrue(buffer.hasPrepared("D"))
        XCTAssertEqual(buffer.previousMediaID, "B", "The newer owner's previous slot must not be restored to A")
        XCTAssertFalse(buffer.hasPrepared("A")); XCTAssertFalse(buffer.hasLoopReserve)
        XCTAssertEqual(Set(buffer.retainedItems.map(ObjectIdentifier.init)),
            Set([current, replacement, replacementNext].map(ObjectIdentifier.init)))
        XCTAssertEqual(buffer.retainedItemCount, 3)
        XCTAssertFalse(buffer.retainedItems.contains { $0 === previous })
        XCTAssertEqual(buffer.player.actionAtItemEnd, .pause); XCTAssertFalse(buffer.player.automaticallyWaitsToMinimizeStalling)
        XCTAssertEqual(buffer.player.rate, 0)
    }

    func testPromotingPreviousRevalidatesLiveLocalityBeforeCommit() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let buffer = PlaybackBuffer(), current = AVPlayerItem(url: url), previous = AVPlayerItem(url: url)
        buffer.automaticAdvancementEnabled = false; buffer.usesExternalClock = true
        let player = buffer.player
        defer { buffer.player.pause(); buffer.replace(with: nil); buffer.discardPrevious() }
        XCTAssertTrue(buffer.replace(with: current, mediaID: "B"))
        // This exact discard/restage intervention deliberately has no prepared resource:
        // discarding an installed resource would retire it, changing a second variable.
        XCTAssertTrue(buffer.stagePrevious(.init(mediaID: "A", item: previous, isLocal: true,
            needsRewind: true, reachedEnd: true)))
        XCTAssertNil(buffer.resource(for: previous)); XCTAssertTrue(previous.outputs.isEmpty)
        XCTAssertTrue(player.currentItem === current); XCTAssertTrue(player.canInsert(previous, after: current))
        XCTAssertEqual(player.items().map(ObjectIdentifier.init), [ObjectIdentifier(current)])
        var eligibilityCalls = 0, interventions = 0, replacementAccepted = false
        let promoted = buffer.promotePreviousToNext(mediaID: "A", after: "B", allowRemote: false,
            ifEligible: {
                eligibilityCalls += 1
                if eligibilityCalls == 2 {
                    interventions += 1
                    buffer.discardPrevious()
                    replacementAccepted = buffer.stagePrevious(.init(mediaID: "A", item: previous,
                        isLocal: false, needsRewind: true, reachedEnd: true))
                }
                return true // Same item/ID/nil resource/rewind/end flags; only locality changed.
            })
        XCTAssertEqual(eligibilityCalls, 2); XCTAssertEqual(interventions, 1); XCTAssertTrue(replacementAccepted)
        XCTAssertFalse(promoted, "Captured local metadata must not authorize the live remote preparation")
        XCTAssertTrue(buffer.player === player); XCTAssertTrue(player.currentItem === current)
        XCTAssertEqual(player.items().map(ObjectIdentifier.init), [ObjectIdentifier(current)])
        XCTAssertEqual(buffer.previousMediaID, "A"); XCTAssertNil(buffer.nextMediaID)
        XCTAssertFalse(buffer.hasPrepared("A")); XCTAssertFalse(buffer.hasLoopReserve)
        XCTAssertEqual(Set(buffer.retainedItems.map(ObjectIdentifier.init)), Set([current, previous].map(ObjectIdentifier.init)))
        XCTAssertEqual(buffer.retainedItemCount, 2)
        XCTAssertNil(buffer.resource(for: previous)); XCTAssertTrue(previous.outputs.isEmpty)
        XCTAssertEqual(player.rate, 0); XCTAssertEqual(player.actionAtItemEnd, .pause)
        XCTAssertFalse(player.automaticallyWaitsToMinimizeStalling)
        #if DEBUG
        XCTAssertEqual(buffer.debugPreviousNeedsRewind, true)
        #endif
        // The unchanged original handoff must also refuse the retained remote metadata.
        XCTAssertNil(buffer.advance(to: "A", allowRemote: false))
        XCTAssertTrue(player.currentItem === current); XCTAssertEqual(buffer.previousMediaID, "A")
        XCTAssertNil(buffer.nextMediaID)

        // Positive control consumes this exact live remote preparation when allowed.
        var allowedCalls = 0
        XCTAssertTrue(buffer.promotePreviousToNext(mediaID: "A", after: "B", allowRemote: true,
            ifEligible: { allowedCalls += 1; return true }))
        XCTAssertEqual(allowedCalls, 2)
        XCTAssertTrue(buffer.player === player); XCTAssertTrue(player.currentItem === current)
        XCTAssertEqual(player.items().map(ObjectIdentifier.init), [current, previous].map(ObjectIdentifier.init))
        XCTAssertNil(buffer.previousMediaID); XCTAssertEqual(buffer.nextMediaID, "A")
        XCTAssertTrue(buffer.hasPrepared("A")); XCTAssertFalse(buffer.hasLoopReserve)
        XCTAssertEqual(buffer.retainedItemCount, 2)
        XCTAssertNil(buffer.resource(for: previous)); XCTAssertTrue(previous.outputs.isEmpty)
        let accepted = try XCTUnwrap(buffer.advance(to: "A", allowRemote: true))
        XCTAssertTrue(accepted.item === previous); XCTAssertFalse(accepted.isLocal)
        XCTAssertTrue(accepted.needsRewind); XCTAssertTrue(accepted.reachedEnd)
        XCTAssertNil(accepted.videoResource)
        XCTAssertTrue(player.currentItem === previous); XCTAssertEqual(player.items().count, 1)
        XCTAssertEqual(player.rate, 0); XCTAssertEqual(player.actionAtItemEnd, .pause)
        XCTAssertFalse(player.automaticallyWaitsToMinimizeStalling)
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
