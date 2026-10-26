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

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Phone playback ownership/recovery condition did not finish")
        if !condition() { throw CatalogError.invalid("Synthetic phone playback regression timed out") }
    }
}
