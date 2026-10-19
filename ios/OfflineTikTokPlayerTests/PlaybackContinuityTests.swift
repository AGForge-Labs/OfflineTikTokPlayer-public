import XCTest
import AVFoundation
import AudioToolbox
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class PlaybackContinuityTests: XCTestCase {
    func testServiceReadinessAndForegroundRespectInterruptionPauseAndActivationFailure() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let cloud = OneDriveClient(account: MicrosoftAccount()), network = NetworkStatus()
        let downloads = OfflineDownloads(cloud: cloud, network: network)
        let library = LibraryRepository(cloud: cloud, catalogURL: temporary.appendingPathComponent("catalog.json"))
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let id = "local:continuity-" + UUID().uuidString
        _ = try await downloads.importLocal(url, mediaID: id)
        defer { downloads.remove(id) }
        try library.install(LibraryCatalog(libraryID: "local:test", media: [MediaRecord(id: id, title: "Synthetic tone", creator: "Fixture", duration: 1.2)], playlists: []))
        var activations = 0, rejectActivation = false
        let service = PlaybackService(library: library, downloads: downloads, cloud: cloud,
            bookmarkURL: temporary.appendingPathComponent("playback.json"), activateSession: {
                activations += 1
                if rejectActivation { throw NSError(domain: "SyntheticBusySession", code: 1) }
            })
        defer { service.pause() }
        service.start(playlistIDs: [], at: id)
        service.handleInterruption(began: true); service.handleInterruption(began: true)
        let deadline = Date().addingTimeInterval(5)
        while service.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.player.rate, 0, "Async readiness must not restart an interrupted session")
        service.enteredForeground()
        service.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(activations, 2)
        service.persist(); service.enteredForeground()
        XCTAssertTrue(service.wantsToPlay, "A normal background/foreground cycle must preserve playback")
        XCTAssertEqual(activations, 2)
        service.handleInterruption(began: true); service.pause()
        service.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(activations, 2, "An explicit pause must cancel automatic reactivation")
        service.enteredForeground(); XCTAssertEqual(service.player.rate, 0)
        rejectActivation = true; service.play()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(service.player.rate, 0)
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.queue.currentID, id)
    }

    private func item() throws -> AVPlayerItem {
        AVPlayerItem(url: try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4")))
    }

    func testPreparedBoundaryAdvancesAutomaticallyWithoutZeroSeek() async throws {
        let buffer = PlaybackBuffer(), first = try item(), second = try item()
        defer { buffer.player.pause(); buffer.replace(with: nil) }
        buffer.replace(with: first, mediaID: "a")
        var transitions = 0
        buffer.didAdvance = { prepared in
            XCTAssertEqual(prepared.mediaID, "b"); transitions += 1
        }
        buffer.stage(.init(mediaID: "b", item: second, isLocal: true))
        XCTAssertEqual(buffer.player.actionAtItemEnd, .advance)
        buffer.player.playImmediately(atRate: 1)
        let deadline = Date().addingTimeInterval(6)
        while transitions == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(transitions, 1)
        XCTAssertTrue(buffer.player.currentItem === second)
        XCTAssertEqual(buffer.player.actionAtItemEnd, .pause, "The final item must remain visible at queue end")
        let end = Date().addingTimeInterval(4)
        while buffer.player.rate != 0, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(buffer.player.rate, 0)
        XCTAssertTrue(buffer.player.currentItem === second)
        XCTAssertEqual(transitions, 1)
    }

    func testRepeatUsesCompletePreparedItemAndExplicitNextCanReplaceIt() throws {
        let buffer = PlaybackBuffer(), original = try item(), repeated = try item(), skipped = try item()
        defer { buffer.replace(with: nil) }
        buffer.replace(with: original, mediaID: "a")
        buffer.stage(.init(mediaID: "a", item: repeated, isLocal: true))
        XCTAssertEqual(repeated.forwardPlaybackEndTime, .invalid)
        XCTAssertEqual(repeated.reversePlaybackEndTime, original.reversePlaybackEndTime)
        buffer.stage(.init(mediaID: "b", item: skipped, isLocal: true))
        XCTAssertTrue(buffer.advance(to: "b")?.item === skipped)
    }

    func testRapidForwardBackwardReusesPreparedPreviousAndBoundsRetainedItems() throws {
        let buffer = PlaybackBuffer()
        buffer.replace(with: try item(), mediaID: "a")
        defer { buffer.replace(with: nil) }
        for _ in 0..<100 {
            buffer.stage(.init(mediaID: "b", item: try item(), isLocal: true))
            XCTAssertNotNil(buffer.advance(to: "b"))
            XCTAssertNotNil(buffer.advance(to: "a"))
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)
            XCTAssertLessThanOrEqual(buffer.player.items().count, 2)
        }
        buffer.discardPrevious()
        XCTAssertLessThanOrEqual(buffer.retainedItemCount, 2)
    }

    func testFeedGestureDefersAutomaticBoundaryAndPauseIsNotLost() throws {
        let buffer = PlaybackBuffer(), original = try item()
        buffer.replace(with: original, mediaID: "a")
        defer { buffer.replace(with: nil) }
        buffer.stage(.init(mediaID: "b", item: try item(), isLocal: true))
        buffer.automaticAdvancementEnabled = false
        XCTAssertEqual(buffer.player.actionAtItemEnd, .pause)
        buffer.player.pause()
        buffer.automaticAdvancementEnabled = true
        XCTAssertEqual(buffer.player.rate, 0)
        XCTAssertTrue(buffer.player.currentItem === original)
        XCTAssertEqual(buffer.player.actionAtItemEnd, .advance)
    }

    func testPreparedPreviousRewindsBeforePlaybackAndMeasuresClockLatency() async throws {
        let buffer = PlaybackBuffer(), first = try item(), second = try item()
        defer { buffer.player.pause(); buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.replace(with: first, mediaID: "a")
        let coldStart = ProcessInfo.processInfo.systemUptime
        buffer.player.playImmediately(atRate: 1)
        var deadline = Date().addingTimeInterval(5)
        while first.currentTime().seconds < 0.1, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(first.currentTime().seconds, 0.1)
        let cold = ProcessInfo.processInfo.systemUptime - coldStart
        buffer.stage(.init(mediaID: "b", item: second, isLocal: true))
        XCTAssertNotNil(buffer.advance(to: "b"))
        let start = ProcessInfo.processInfo.systemUptime
        let previous = try XCTUnwrap(buffer.advance(to: "a"))
        XCTAssertTrue(previous.item === first)
        XCTAssertTrue(previous.needsRewind)
        XCTAssertEqual(buffer.player.rate, 0, "History must not briefly play its former offset")
        let finished = await withCheckedContinuation { continuation in
            buffer.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(first.currentTime().seconds, 0, accuracy: 0.005)
        buffer.player.playImmediately(atRate: 1)
        deadline = Date().addingTimeInterval(5)
        while first.currentTime().seconds < 0.1, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(first.currentTime().seconds, 0.1)
        let previousLatency = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(previousLatency, 2, "Reusing history must not repeatedly resolve the asset URL or metadata")
        print("Previous clock timing fixture: cold=\(cold), retainedPreviousIncludingRewind=\(previousLatency), retainedItems=\(buffer.retainedItemCount)")
    }

    func testStalePreparationCannotAttachAfterAnAlreadyAdvancedBoundary() throws {
        let buffer = PlaybackBuffer(), first = try item(), second = try item()
        defer { buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.replace(with: first, mediaID: "a")
        buffer.stage(.init(mediaID: "b", item: second, isLocal: true), after: "a")
        buffer.player.advanceToNextItem() // KVO is queued, as with a boundary racing a swipe.
        buffer.stage(.init(mediaID: "stale", item: try item(), isLocal: true), after: "a")
        XCTAssertTrue(buffer.player.currentItem === second)
        XCTAssertNil(buffer.nextMediaID)
        XCTAssertEqual(buffer.player.items().count, 1)
        XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)
    }

    func testLoopReserveHasAFixedBoundAndExplicitSkipRemovesIt() throws {
        let buffer = PlaybackBuffer()
        defer { buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.replace(with: try item(), mediaID: "a")
        buffer.stagePrevious(.init(mediaID: "history", item: try item(), isLocal: true))
        buffer.stage(.init(mediaID: "a", item: try item(), isLocal: true))
        for _ in 0..<50 { buffer.stageLoopReserve(.init(mediaID: "a", item: try item(), isLocal: true)) }
        XCTAssertEqual(buffer.player.items().count, 3)
        XCTAssertEqual(buffer.retainedItemCount, 4)
        XCTAssertFalse(buffer.player.automaticallyWaitsToMinimizeStalling)
        buffer.stage(.init(mediaID: "b", item: try item(), isLocal: true))
        XCTAssertFalse(buffer.hasLoopReserve)
        XCTAssertEqual(buffer.player.items().count, 2)
        XCTAssertNotNil(buffer.advance(to: "b"))
        XCTAssertFalse(buffer.hasLoopReserve)
        XCTAssertEqual(buffer.player.actionAtItemEnd, .pause)
        XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)
    }

    func testHTTPPreparationKeepsAutomaticStallRecoveryUntilLocalHandoff() throws {
        let buffer = PlaybackBuffer()
        defer { buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.replace(with: try item(), mediaID: "a", isLocal: false)
        buffer.stage(.init(mediaID: "b", item: try item(), isLocal: false))
        XCTAssertTrue(buffer.player.automaticallyWaitsToMinimizeStalling)
        buffer.stage(.init(mediaID: "b", item: try item(), isLocal: true), requireLocal: true)
        XCTAssertNotNil(buffer.advance(to: "b", allowRemote: false))
        XCTAssertFalse(buffer.player.automaticallyWaitsToMinimizeStalling)
    }

    func testFullDurationLoopsRecordBoundarySchedulingAndEncodedSourceSilence() async throws {
        let first = try item(), asset = first.asset
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1
        ])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var samples = 0, firstAudible: Int?, lastAudible: Int?
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            _ = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            bytes.withUnsafeBytes { data in
                for value in data.bindMemory(to: Float.self) {
                    if abs(value) > 0.001 { if firstAudible == nil { firstAudible = samples }; lastAudible = samples }
                    samples += 1
                }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(samples, 48000)
        let buffer = PlaybackBuffer()
        defer { buffer.player.pause(); buffer.didAdvance = nil; buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.replace(with: first, mediaID: "loop")
        var departed = first, completeTimes: [Double] = [], schedulingGaps: [Double] = []
        var anchorHost: Double?, anchorPosition = 0.0
        buffer.didAdvance = { prepared in
            completeTimes.append(departed.currentTime().seconds)
            if let anchorHost { schedulingGaps.append(ProcessInfo.processInfo.systemUptime - anchorHost - (duration - anchorPosition)) }
            departed = prepared.item
            anchorHost = ProcessInfo.processInfo.systemUptime
            anchorPosition = prepared.item.currentTime().seconds
            if completeTimes.count < 3 {
                buffer.stageLoopReserve(.init(mediaID: "loop", item: AVPlayerItem(asset: asset), isLocal: true))
                XCTAssertLessThanOrEqual(buffer.retainedItemCount, 4)
            }
        }
        buffer.stage(.init(mediaID: "loop", item: AVPlayerItem(asset: asset), isLocal: true))
        buffer.stageLoopReserve(.init(mediaID: "loop", item: AVPlayerItem(asset: asset), isLocal: true))
        XCTAssertEqual(buffer.player.items().count, 3)
        buffer.player.playImmediately(atRate: 1)
        let deadline = Date().addingTimeInterval(10)
        while first.currentTime().seconds < 0.1, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        anchorHost = ProcessInfo.processInfo.systemUptime; anchorPosition = first.currentTime().seconds
        while completeTimes.count < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(completeTimes.count, 3)
        for end in completeTimes { XCTAssertGreaterThanOrEqual(end, duration - 0.025, "Looping must not cut off the source tail") }
        for gap in schedulingGaps { XCTAssertLessThan(abs(gap), 0.15, "Prepared loop scheduling added an observable gap") }
        let metrics: [String: Any] = ["durationSeconds": duration, "decodedSourceSamples48000Hz": samples,
            "sourceLeadingBelowMinus60dBSeconds": Double(firstAudible ?? samples) / 48000,
            "sourceTrailingBelowMinus60dBSeconds": Double(samples - 1 - (lastAudible ?? -1)) / 48000,
            "completedItemTimes": completeTimes, "boundarySchedulingOffsetsSeconds": schedulingGaps]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics, options: .sortedKeys), uniformTypeIdentifier: "public.json")
        attachment.name = "Full-source-loop-boundaries"; attachment.lifetime = .keepAlways; add(attachment)
        print("Full source loop metrics: \(metrics)")
    }
}
