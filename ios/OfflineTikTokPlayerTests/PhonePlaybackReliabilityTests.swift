import XCTest
import AVFoundation
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class PhonePlaybackReliabilityTests: XCTestCase {
    func testNativePlayableSavedVideoSurvivesPCMPreparationRejection() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        var attempts = 0
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads,
            cloud: fixture.cloud, bookmarkURL: fixture.bookmark, activateSession: {},
            preparePCM: { _, _, _, _ in attempts += 1; throw ContinuousPCMDecoder.Failure.unsupportedPCM }))
        service.speakerSound = false
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { service.player.currentItem?.status == .readyToPlay && service.player.rate > 0 && service.clock.position > 0.1 }
        XCTAssertEqual(service.queue.currentID, fixture.aID)
        XCTAssertNil(service.message)
        XCTAssertFalse(service.player.isMuted)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertEqual(attempts, 1)
        service.pause()
    }

    func testNaturalSuccessorFailureBeforeAdoptionRecoversThatVideoAtItsOwnPosition() async throws {
        let fixture = try await SelectionVideoFixture(test: self, shortLoopFixture: true)
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer()
        let service = fixture.service(continuousAudio: audio)
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { service.audioSnapshot.frame > 2400 && audio.entry(for: fixture.bID) != nil }
        let a = try XCTUnwrap(audio.entry(for: fixture.aID))
        let b = try XCTUnwrap(audio.entry(for: fixture.bID))
        service.shouldDebugDeferAudioVisit = { _ in true }
        audio.suspend(); audio.graph.engine.stop()
        try audio.graph.engine.enableManualRenderingMode(.offline, format: audio.graph.format, maximumFrameCount: 32)
        audio.follow(from: fixture.aID, to: fixture.bID)
        XCTAssertTrue(audio.select(id: fixture.aID, position: Double(a.frames - 1) / 48_000))
        try audio.setPlaying(true)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.graph.format, frameCapacity: 32))
        XCTAssertEqual(try audio.graph.engine.renderOffline(3, to: output), .success)
        XCTAssertEqual(audio.snapshot.token, b.token)
        XCTAssertEqual(service.queue.currentID, fixture.aID, "Hold the service before adoption")
        service.handleDecodeFailure(token: b.token)
        XCTAssertEqual(service.queue.currentID, fixture.bID, "Recover the failed rendered successor, never preceding A")
        XCTAssertLessThan(service.clock.position, 0.1)
        XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
        audio.graph.engine.stop(); audio.graph.engine.disableManualRenderingMode()
        service.shouldDebugDeferAudioVisit = nil
        try await until { service.player.currentItem?.status == .readyToPlay && service.player.rate > 0 }
        XCTAssertFalse(service.player.isMuted)
        XCTAssertEqual(service.previousID, fixture.aID)
        XCTAssertNil(service.message)
        service.pause()
    }

    func testKnownNativeSourceCannotBePreparedAgainByRepeatOneWarmup() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer()
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads,
            cloud: fixture.cloud, bookmarkURL: fixture.bookmark, activateSession: {}, continuousAudio: audio,
            preparePCM: { _, _, _, _ in throw ContinuousPCMDecoder.Failure.unsupportedPCM }))
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { service.player.rate > 0 && service.clock.position > 0.1 }
        service.cycleRepeat(); service.cycleRepeat()
        try await until { audio.entry(for: fixture.bID) != nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(audio.entry(for: fixture.aID), "Repeat-one must not re-admit a rejected PCM source")
        XCTAssertFalse(service.player.isMuted)
        XCTAssertEqual(service.queue.repeatMode, .one)
        service.pause()
    }

    func testPauseDuringPCMRejectionSurvivesNativeRecovery() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        var entered = false, released = false
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads,
            cloud: fixture.cloud, bookmarkURL: fixture.bookmark, activateSession: {},
            preparePCM: { _, _, _, _ in
                entered = true
                while !released { try await Task.sleep(for: .milliseconds(5)) }
                throw ContinuousPCMDecoder.Failure.unsupportedPCM
            }))
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { entered }
        service.pause(); released = true
        try await until { service.player.currentItem?.status == .readyToPlay }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(service.queue.currentID, fixture.aID)
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.player.rate, 0)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertNil(service.message)
    }

    func testPiPSkipNavigatesHistoryAndOverridesRepeatOneWithoutTenSecondSeek() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let service = fixture.service()
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { service.audioSnapshot.frame > 2400 && !service.isLoading }
        service.cycleRepeat(); service.cycleRepeat()
        XCTAssertEqual(service.queue.repeatMode, .one)
        var completions = 0
        service.handlePiPSkip(10) { completions += 1 }
        try await until { service.queue.currentID == fixture.bID && !service.isLoading && completions == 1 }
        XCTAssertLessThan(service.clock.position, 2)
        service.handlePiPSkip(-10) { completions += 1 }
        try await until { service.queue.currentID == fixture.aID && !service.isLoading && completions == 2 }
        XCTAssertLessThan(service.clock.position, 2)
        XCTAssertEqual(service.queue.repeatMode, .one)
        service.pause()
    }

    func testPiPSkipKeepsPausedStateAndAlwaysCompletesAtQueueEdges() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let service = fixture.service()
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { service.audioSnapshot.frame > 2400 && !service.isLoading }
        service.pause()
        var completions = 0
        service.handlePiPSkip(10) { completions += 1 }
        try await until { service.queue.currentID == fixture.bID && completions == 1 }
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.player.rate, 0)
        service.handlePiPSkip(10) { completions += 1 }
        service.handlePiPSkip(0) { completions += 1 }
        service.handlePiPSkip(.nan) { completions += 1 }
        try await until { completions == 4 }
        XCTAssertEqual(service.queue.currentID, fixture.bID)
        XCTAssertFalse(service.wantsToPlay)
    }

    func testColdRemoteResolutionFailureRefreshesOnceAndPlaysChosenVideo() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let source = try XCTUnwrap(fixture.savedURLs[fixture.aID])
        let hash = try AppFiles.hash(source)
        let original = fixture.temporary.appendingPathComponent("cold-resolution-original.mp4")
        try FileManager.default.copyItem(at: source, to: original)
        fixture.downloads.remove(fixture.aID)
        let asset = AssetReference(driveID: "synthetic", itemID: fixture.aID, fileName: "original.mp4",
            byteSize: hash.size, sha256: hash.sha256, contentType: "video/mp4")
        try fixture.library.install(LibraryCatalog(libraryID: "local:cold-resolution", media: [
            MediaRecord(id: fixture.aID, title: "Synthetic cold resolution", duration: 30, status: .ready, asset: asset)
        ], playlists: [PlaylistRecord(id: fixture.playlist, name: "Synthetic", itemIDs: [fixture.aID])]))
        let cache = try PlaybackMediaCache(directory: fixture.temporary.appendingPathComponent("no-cold-cache"), byteLimit: 1) { _ in
            throw CatalogError.invalid("Whole-file warming is optional")
        }
        var ordinary = 0, refreshed = 0
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads,
            cloud: fixture.cloud, bookmarkURL: fixture.bookmark, activateSession: {}, mediaCache: cache,
            resolveRemote: { _ in
                ordinary += 1
                if ordinary == 1 { throw URLError(.networkConnectionLost) }
                return original
            },
            refreshRemote: { _ in refreshed += 1; return original }))
        service.setAudioOnly(false)
        service.speakerSound = false
        service.automaticPiP = false
        try await until { fixture.downloads.network.isConnected }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        // A returned bad URL already has coverage below. This error happens before
        // an AVPlayerItem exists, so recovery must also cover cold source resolution.
        try await until {
            service.message != nil || (service.player.currentItem?.status == .readyToPlay
                && service.player.rate > 0 && service.clock.position > 0.1)
        }
        XCTAssertEqual(service.queue.currentID, fixture.aID)
        XCTAssertEqual(ordinary, 1)
        XCTAssertEqual(refreshed, 1, "A cold transient failure must request one fresh source URL")
        XCTAssertNil(service.message, "Recoverable source resolution must not raise a preparation alert")
        XCTAssertEqual(service.player.currentItem?.status, .readyToPlay)
        XCTAssertGreaterThan(service.player.rate, 0)
        XCTAssertGreaterThan(service.clock.position, 0.1)
        XCTAssertTrue(service.wantsToPlay)
        service.pause()
    }

    func testColdRemoteResolutionRetriesOnlyOnceForTransientErrorsAndNeverForPermanentErrors() async throws {
        let cases: [(name: String, error: Error, expectedFresh: Int)] = [
            ("transient exhausted", URLError(.networkConnectionLost), 1),
            ("permanent", AppError.message("Synthetic permanent source failure"), 0)
        ]
        for control in cases {
            let fixture = try await SelectionVideoFixture(test: self)
            defer { fixture.remove() }
            let source = try XCTUnwrap(fixture.savedURLs[fixture.aID])
            let hash = try AppFiles.hash(source)
            fixture.downloads.remove(fixture.aID)
            let asset = AssetReference(driveID: "synthetic", itemID: fixture.aID, fileName: "original.mp4",
                byteSize: hash.size, sha256: hash.sha256, contentType: "video/mp4")
            try fixture.library.install(LibraryCatalog(libraryID: "local:cold-resolution-control", media: [
                MediaRecord(id: fixture.aID, title: "Synthetic cold failure", duration: 30, status: .ready, asset: asset)
            ], playlists: [PlaylistRecord(id: fixture.playlist, name: "Synthetic", itemIDs: [fixture.aID])]))
            let cache = try PlaybackMediaCache(directory: fixture.temporary.appendingPathComponent("no-control-cache"), byteLimit: 1) { _ in
                throw CatalogError.invalid("Whole-file warming is optional")
            }
            var ordinary = 0, refreshed = 0
            let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads,
                cloud: fixture.cloud, bookmarkURL: fixture.bookmark, activateSession: {}, mediaCache: cache,
                resolveRemote: { _ in ordinary += 1; throw control.error },
                refreshRemote: { _ in refreshed += 1; throw URLError(.networkConnectionLost) }))
            try await until { fixture.downloads.network.isConnected }
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await until { !service.isLoading && service.message != nil }
            XCTAssertEqual(service.queue.currentID, fixture.aID, control.name)
            XCTAssertEqual(ordinary, 1, control.name)
            XCTAssertEqual(refreshed, control.expectedFresh, control.name)
            XCTAssertFalse(service.wantsToPlay, control.name)
            XCTAssertFalse(service.audioEngineRunning, control.name)
            XCTAssertNil(service.player.currentItem, control.name)
            XCTAssertNotNil(service.message, control.name)
            try await fixture.close()
        }
    }

    func testPendingColdRemoteRefreshHonorsPauseAndSupersedingSelection() async throws {
        for supersedesSelection in [false, true] {
            let fixture = try await SelectionVideoFixture(test: self)
            defer { fixture.remove() }
            let source = try XCTUnwrap(fixture.savedURLs[fixture.aID])
            let savedB = try XCTUnwrap(fixture.savedURLs[fixture.bID])
            let hash = try AppFiles.hash(source)
            let original = fixture.temporary.appendingPathComponent("pending-refresh-original.mp4")
            try FileManager.default.copyItem(at: source, to: original)
            fixture.downloads.remove(fixture.aID)
            let asset = AssetReference(driveID: "synthetic", itemID: fixture.aID, fileName: "original.mp4",
                byteSize: hash.size, sha256: hash.sha256, contentType: "video/mp4")
            let replacementPlaylist = fixture.playlist + "-replacement"
            try fixture.library.install(LibraryCatalog(libraryID: "local:pending-cold-resolution", media: [
                MediaRecord(id: fixture.aID, title: "Synthetic pending refresh", duration: 30, status: .ready, asset: asset),
                MediaRecord(id: fixture.bID, title: "Synthetic Saved replacement", duration: 30, status: .ready)
            ], playlists: [
                PlaylistRecord(id: fixture.playlist, name: "Pending", itemIDs: [fixture.aID]),
                PlaylistRecord(id: replacementPlaylist, name: "Replacement", itemIDs: [fixture.bID])
            ]))
            let cache = try PlaybackMediaCache(directory: fixture.temporary.appendingPathComponent("no-pending-cache"), byteLimit: 1) { _ in
                throw CatalogError.invalid("Whole-file warming is optional")
            }
            var ordinary = 0, refreshed = 0, freshReturned = false
            var pending: CheckedContinuation<URL, Error>?
            defer { pending?.resume(throwing: CancellationError()) }
            let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads,
                cloud: fixture.cloud, bookmarkURL: fixture.bookmark, activateSession: {}, mediaCache: cache,
                resolveRemote: { _ in ordinary += 1; throw URLError(.networkConnectionLost) },
                refreshRemote: { _ in
                    refreshed += 1
                    // Deliberately return late even if the requesting task is cancelled.
                    let url: URL = try await withCheckedThrowingContinuation { pending = $0 }
                    freshReturned = true
                    return url
                }))
            service.setAudioOnly(false)
            service.speakerSound = false
            service.automaticPiP = false
            service.isInteractingWithFeed = true
            try await until { fixture.downloads.network.isConnected }
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await until { pending != nil || service.message != nil }
            guard pending != nil else {
                XCTFail("The transient failure must reach the held fresh resolution")
                throw CatalogError.invalid("Fresh source resolution was never requested")
            }
            XCTAssertNil(service.message)
            if supersedesSelection {
                service.start(playlistIDs: [replacementPlaylist], at: fixture.bID)
            } else {
                service.pause()
            }
            let release = try XCTUnwrap(pending)
            pending = nil
            release.resume(returning: original)
            try await until {
                freshReturned && service.player.currentItem?.status == .readyToPlay
                    && (supersedesSelection ? service.audioSnapshot.frame > 2_400 : !service.isLoading)
            }
            XCTAssertEqual(ordinary, 1)
            XCTAssertEqual(refreshed, 1)
            XCTAssertNil(service.message)
            if supersedesSelection {
                XCTAssertEqual(service.queue.currentID, fixture.bID)
                XCTAssertEqual((service.player.currentItem?.asset as? AVURLAsset)?.url, savedB)
                XCTAssertTrue(service.wantsToPlay)
                XCTAssertTrue(service.audioEngineRunning)
                XCTAssertGreaterThan(service.audioSnapshot.frame, 2_400)
            } else {
                XCTAssertEqual(service.queue.currentID, fixture.aID)
                XCTAssertFalse(service.wantsToPlay)
                XCTAssertFalse(service.audioEngineRunning)
                XCTAssertEqual(service.player.rate, 0)
            }
            try await fixture.close()
        }
    }

    func testFailedRemoteItemUsesFreshResolverOnceAndKeepsChosenVideo() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let source = try XCTUnwrap(fixture.savedURLs[fixture.aID])
        let hash = try AppFiles.hash(source)
        let invalid = fixture.temporary.appendingPathComponent("expired-link-response.mp4")
        try Data("Synthetic expired-link response".utf8).write(to: invalid)
        let asset = AssetReference(driveID: "synthetic", itemID: fixture.aID, fileName: "original.mp4",
            byteSize: hash.size, sha256: hash.sha256, contentType: "video/mp4")
        // Keep a valid standalone file while removing the fixture's Saved record.
        let original = fixture.temporary.appendingPathComponent("valid-original.mp4")
        try FileManager.default.copyItem(at: source, to: original)
        fixture.downloads.remove(fixture.aID)
        try fixture.library.install(LibraryCatalog(libraryID: "local:expired-link", media: [
            MediaRecord(id: fixture.aID, title: "Synthetic expired link", duration: 30, status: .ready, asset: asset)
        ], playlists: [PlaylistRecord(id: fixture.playlist, name: "Synthetic", itemIDs: [fixture.aID])]))
        let cache = try PlaybackMediaCache(directory: fixture.temporary.appendingPathComponent("no-cache"), byteLimit: 1) { _ in
            throw CatalogError.invalid("Whole-file warming is optional")
        }
        var ordinary = 0, refreshed = 0
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads,
            cloud: fixture.cloud, bookmarkURL: fixture.bookmark, activateSession: {}, mediaCache: cache,
            resolveRemote: { _ in ordinary += 1; return invalid },
            refreshRemote: { _ in refreshed += 1; return original }))
        try await until { fixture.downloads.network.isConnected }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { refreshed == 1 && service.player.rate > 0 && service.clock.position > 0.1 }
        XCTAssertEqual(service.queue.currentID, fixture.aID)
        XCTAssertEqual(ordinary, 1)
        XCTAssertEqual(refreshed, 1)
        XCTAssertNil(service.message)
        service.pause()
    }

    func testStoppedEstablishedVideoRecoversWhilePCMContinues() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let service = fixture.service()
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until {
            service.isVideoReady && service.submittedVideoFrameCount >= 3
                && service.audioSnapshot.frame > 12_000
        }
        let before = service.audioSnapshot
        // Reproduce a video-only stop after startup has already shown moving frames.
        // Audio remains on the real production PCM engine throughout this test.
        service.player.pause()
        let stoppedPosition = service.player.currentTime().seconds
        let stoppedFrames = service.submittedVideoFrameCount
        try await until {
            service.player.rate > 0 && service.submittedVideoFrameCount >= stoppedFrames + 4
                && (service.videoFramePositionSeconds ?? 0) > stoppedPosition + 0.15
        }
        let after = service.audioSnapshot
        XCTAssertEqual(service.queue.currentID, fixture.aID)
        XCTAssertEqual(after.token, before.token)
        XCTAssertEqual(after.visit, before.visit)
        XCTAssertGreaterThan(after.frame, before.frame + 12_000)
        XCTAssertTrue(service.wantsToPlay)
        XCTAssertTrue(service.audioEngineRunning)
        XCTAssertNil(service.message)
        print("EstablishedVideoRecovery audioTokenUnchanged=\(after.token == before.token) audioFrames=\(after.frame - before.frame) videoFrames=\(service.submittedVideoFrameCount - stoppedFrames)")
        service.pause()
    }


    func testStoppedInitialVideoClockRecoversWithoutSkippingTheSelection() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let service = fixture.service()
        service.isInteractingWithFeed = true
        var stoppedInitialStart = false
        service.onDebugVideoRateHandoff = { [weak service] event in
            if event.cause == .initialReady && !stoppedInitialStart {
                stoppedInitialStart = true
                service?.player.pause()
            }
        }
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { stoppedInitialStart && service.audioSnapshot.frame > 12_000 }
        try await until {
            service.isVideoReady && service.player.rate > 0 && service.submittedVideoFrameCount >= 4
                && (service.videoFramePositionSeconds ?? 0) > 0.25
        }
        XCTAssertEqual(service.queue.currentID, fixture.aID)
        XCTAssertTrue(service.wantsToPlay)
        XCTAssertTrue(service.audioEngineRunning)
        XCTAssertNil(service.message)
        service.onDebugVideoRateHandoff = nil
        service.pause()
    }

    func testUnexpectedAudioEngineStopRecoversSameClipAndRespectsPause() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer()
        let service = fixture.service(continuousAudio: audio)
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { service.audioSnapshot.frame > 12_000 && service.isVideoReady }
        let before = service.audioSnapshot
        audio.graph.engine.stop()
        XCTAssertFalse(service.audioEngineRunning)
        try await until { service.audioEngineRunning && service.audioSnapshot.frame > before.frame + 12_000 }
        XCTAssertEqual(service.audioSnapshot.token, before.token)
        XCTAssertEqual(service.audioSnapshot.visit, before.visit)
        XCTAssertEqual(service.queue.currentID, fixture.aID)
        XCTAssertTrue(service.wantsToPlay)
        XCTAssertNil(service.message)
        audio.graph.engine.stop()
        service.pause()
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertFalse(service.audioEngineRunning, "Recovery must never override explicit Pause")
    }


    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Phone playback ownership/recovery condition did not finish")
        if !condition() { throw CatalogError.invalid("Synthetic phone playback regression timed out") }
    }
}
