import XCTest
import AVFoundation
import AudioToolbox
import UIKit
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class PlaybackContinuityTests: XCTestCase {
    func testAudioSeekCompletesWithoutWaitingForMutedVideoAndPauseWins() async throws {
        let fixture = try await ServiceFixture()
        defer { fixture.remove() }
        let service = PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
            bookmarkURL: fixture.bookmark, activateSession: {}, seekPlayer: { _, _, _ in XCTFail("PCM seek must not wait on AVPlayer") })
        defer { service.pause() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.ids[0])
        try await until { service.audioSnapshot.frame > 2_400 }
        service.seek(0.8); service.seek(0.2); service.pause()
        try await until { abs(service.clock.position - 0.2) < 0.02 && service.audioSnapshot.frame == 9_600 }
        let frame = service.audioSnapshot.frame
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(service.audioSnapshot.frame, frame)
        XCTAssertFalse(service.wantsToPlay)
        service.handleInterruption(began: true)
        service.handleInterruption(began: false, shouldResume: true)
        XCTAssertFalse(service.wantsToPlay)
    }

    func testCoalescedAndDrainedLoopBoundariesReconcileActualCurrentItem() throws {
        for (hasReserve, drain) in [(true, false), (true, true), (false, true)] {
            let buffer = PlaybackBuffer(), original = try item(), reserve = try item()
            defer { buffer.replace(with: nil); buffer.discardPrevious() }
            buffer.replace(with: original, mediaID: "loop")
            buffer.stage(.init(mediaID: "loop", item: hasReserve ? try item() : reserve, isLocal: true))
            if hasReserve { buffer.stageLoopReserve(.init(mediaID: "loop", item: reserve, isLocal: true)) }
            var adopted: PlaybackBuffer.Prepared?
            buffer.didAdvance = { adopted = $0 }
            buffer.player.advanceToNextItem(); buffer.player.advanceToNextItem()
            if hasReserve && drain { buffer.player.advanceToNextItem() }
            buffer.synchronize()
            XCTAssertTrue(adopted?.item === reserve)
            XCTAssertEqual(adopted?.needsRewind, drain)
            XCTAssertTrue(buffer.player.currentItem === reserve)
            XCTAssertNil(buffer.nextMediaID); XCTAssertFalse(buffer.hasLoopReserve)
            XCTAssertEqual(buffer.player.items().count, 1)
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 2)
            buffer.stage(.init(mediaID: "loop", item: try item(), isLocal: true), after: "loop")
            XCTAssertTrue(buffer.hasPrepared("loop"))
        }
    }

    func testPreparedPCMReversalsAreIndependentOfVideoReadinessAndBoundMemory() async throws {
        let fixture = try await ServiceFixture(count: 3)
        defer { fixture.remove() }
        let service = PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
            bookmarkURL: fixture.bookmark, activateSession: {})
        defer { service.pause() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.ids[0])
        try await until { service.audioSnapshot.frame > 2_400 && service.preparedAudioCount >= 2 }
        for _ in 0..<10 {
            var visit = service.audioSnapshot.visit
            service.next()
            try await until { service.audioSnapshot.visit > visit && service.audioSnapshot.frame > 64 }
            // Muted video can stall or pause without changing audio intent/position.
            service.player.pause()
            let frame = service.audioSnapshot.frame
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertGreaterThan(service.audioSnapshot.frame, frame)
            visit = service.audioSnapshot.visit
            service.previous()
            try await until { service.audioSnapshot.visit > visit && service.audioSnapshot.frame > 64 }
            XCTAssertLessThanOrEqual(service.preparedAudioCount, 3)
        }
        XCTAssertEqual(service.audioSnapshot.underrunFrames, 0)
        service.audioOnly = true
        service.pause(); let paused = service.audioSnapshot.frame
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        service.enteredForeground(); service.audioOnly = false
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.audioSnapshot.frame, paused)
    }

    func testPCMOwnsNaturalLoopsAndQueueEndWhenVideoStops() async throws {
        let fixture = try await ServiceFixture()
        defer { fixture.remove() }
        let service = PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
            bookmarkURL: fixture.bookmark, activateSession: {})
        defer { service.pause() }
        service.audioOnly = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.ids[0])
        try await until { service.queue.currentID == fixture.ids[1] }
        try await until { !service.wantsToPlay }
        XCTAssertEqual(service.queue.currentID, fixture.ids[1])
        XCTAssertEqual(service.audioSnapshot.underrunFrames, 0)
        service.cycleRepeat(); service.cycleRepeat() // repeat one
        service.play()
        let visit = service.audioSnapshot.visit
        try await until { service.audioSnapshot.visit >= visit + 3 }
        XCTAssertTrue(service.wantsToPlay)
        XCTAssertEqual(service.audioSnapshot.underrunFrames, 0)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        service.pause()
        let frame = service.audioSnapshot.frame
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        service.enteredForeground()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.audioSnapshot.frame, frame)
        XCTAssertLessThanOrEqual(service.preparedAudioCount, 3)
    }

    func testPausedRestoreAndSeekUseRequestedAudioPositionBeforeEngineStarts() async throws {
        let fixture = try await ServiceFixture()
        defer { fixture.remove() }
        let bookmark = PlaybackBookmark(queue: PlaybackQueue(ids: fixture.ids, startAt: fixture.ids[0]), position: 0.4)
        try JSONEncoder().encode(bookmark).write(to: fixture.bookmark)
        let service = PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
            bookmarkURL: fixture.bookmark, activateSession: {})
        defer { service.pause() }
        service.restore()
        try await until { !service.isLoading && abs(service.player.currentTime().seconds - 0.4) < 0.04 }
        XCTAssertFalse(service.wantsToPlay)
        service.seek(0.8)
        try await until { abs(service.clock.position - 0.8) < 0.02 && abs(service.player.currentTime().seconds - 0.8) < 0.04 }
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.player.rate, 0)
    }

    func testMemoryWarningDuringColdPreparationKeepsTheRequestedCurrent() async throws {
        let fixture = try await ServiceFixture()
        defer { fixture.remove() }
        let service = PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
            bookmarkURL: fixture.bookmark, activateSession: {})
        defer { service.pause() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.ids[0])
        await Task.yield()
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await until { service.audioSnapshot.frame > 2_400 }
        XCTAssertEqual(service.queue.currentID, fixture.ids[0])
        XCTAssertTrue(service.wantsToPlay)
        XCTAssertEqual(service.audioSnapshot.underrunFrames, 0)
    }

    func testRepeatOneStillPreparesSavedExplicitNext() async throws {
        let fixture = try await ServiceFixture()
        defer { fixture.remove() }
        let service = PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
            bookmarkURL: fixture.bookmark, activateSession: {})
        defer { service.pause() }
        service.cycleRepeat(); service.cycleRepeat()
        service.start(playlistIDs: [fixture.playlist], at: fixture.ids[0])
        try await until { service.audioSnapshot.frame > 2_400 && service.preparedAudioCount >= 2 }
        let visit = service.audioSnapshot.visit
        service.next()
        try await until { service.audioSnapshot.visit > visit && service.queue.currentID == fixture.ids[1] }
        XCTAssertEqual(service.audioSnapshot.underrunFrames, 0)
        XCTAssertLessThanOrEqual(service.preparedAudioCount, 3)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Playback condition did not complete in five seconds")
    }

    @MainActor private struct ServiceFixture {
        let temporary: URL
        let cloud: OneDriveClient
        let downloads: OfflineDownloads
        let library: LibraryRepository
        let ids: [String]
        let playlist = "local:service-timing"
        var bookmark: URL { temporary.appendingPathComponent("playback.json") }
        init(count: Int = 2) async throws {
            temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            cloud = OneDriveClient(account: MicrosoftAccount())
            downloads = OfflineDownloads(cloud: cloud, network: NetworkStatus())
            library = LibraryRepository(cloud: cloud, catalogURL: temporary.appendingPathComponent("catalog.json"))
            ids = (0..<count).map { "local:service-\($0)-" + UUID().uuidString }
            let source = try XCTUnwrap(Bundle(for: PlaybackContinuityTests.self).url(forResource: "test-video", withExtension: "mp4"))
            for id in ids { _ = try await downloads.importLocal(source, mediaID: id) }
            try library.install(LibraryCatalog(libraryID: "local:test", media: ids.map { MediaRecord(id: $0, title: "Synthetic", creator: "Fixture", duration: 1.2) },
                playlists: [PlaylistRecord(id: playlist, name: "Synthetic", itemIDs: ids)]))
        }
        func remove() { for id in ids { downloads.remove(id) }; try? FileManager.default.removeItem(at: temporary) }
    }
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
        // Give the same preparation window as an ordinary prepared swipe.
        try await Task.sleep(for: .milliseconds(500))
        let start = ProcessInfo.processInfo.systemUptime
        let previous = try XCTUnwrap(buffer.advance(to: "a"))
        XCTAssertTrue(previous.item === first)
        let rewoundBeforeHandoff = !previous.needsRewind
        XCTAssertTrue(rewoundBeforeHandoff, "The local ready history item should rewind during preparation")
        XCTAssertEqual(buffer.player.rate, 0, "History must not briefly play its former offset")
        if previous.needsRewind {
            let finished = await withCheckedContinuation { continuation in
                buffer.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(finished)
        }
        XCTAssertEqual(first.currentTime().seconds, 0, accuracy: 0.005)
        buffer.player.playImmediately(atRate: 1)
        deadline = Date().addingTimeInterval(5)
        while first.currentTime().seconds < 0.1, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(first.currentTime().seconds, 0.1)
        let previousLatency = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(previousLatency, 2, "Reusing history must not repeatedly resolve the asset URL or metadata")
        print("Previous clock timing fixture: cold=\(cold), retainedPreviousIncludingRewind=\(previousLatency), rewindPreparedBeforeHandoff=\(rewoundBeforeHandoff), retainedItems=\(buffer.retainedItemCount)")
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
        var callbackOffsets: [Double] = [], arrivingPositions: [Double] = []
        var anchorHost: Double?, anchorPosition = 0.0
        buffer.didAdvance = { prepared in
            completeTimes.append(departed.currentTime().seconds)
            let host = ProcessInfo.processInfo.systemUptime
            let arrived = prepared.item.currentTime().seconds
            XCTAssertTrue(arrived.isFinite)
            if let anchorHost {
                let callbackOffset = host - anchorHost - (duration - anchorPosition)
                callbackOffsets.append(callbackOffset)
                // KVO delivery may lag while the incoming item is already playing.
                // Subtract that progress instead of reporting it as a player gap.
                schedulingGaps.append(callbackOffset - arrived)
                arrivingPositions.append(arrived)
            }
            departed = prepared.item
            anchorHost = host
            anchorPosition = arrived
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
            "completedItemTimes": completeTimes, "boundaryClockGapEstimatesSeconds": schedulingGaps,
            "rawCallbackOffsetsSeconds": callbackOffsets, "arrivingItemPositionsSeconds": arrivingPositions]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics, options: .sortedKeys), uniformTypeIdentifier: "public.json")
        attachment.name = "Full-source-loop-boundaries"; attachment.lifetime = .keepAlways; add(attachment)
        print("Full source loop metrics: \(metrics)")
    }
}
