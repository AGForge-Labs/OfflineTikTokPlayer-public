import XCTest
import AVFoundation
import PlayerCore
@testable import OfflineTikTokPlayer

/// Exercise the actual native transport with original synthetic MP4s returned by
/// a fake cloud URL resolver. This tests service/clock ownership, not HTTP or a phone.
@MainActor
final class NativeStreamingPlaybackTests: XCTestCase {
    func testUncachedCloudSelectionPlaysAndNavigatesWithoutAnOfflineCopy() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let service = try await makeStreamService(fixture)
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { !service.isLoading && service.clock.position > 0.15 && service.player.rate > 0 }
        XCTAssertFalse(service.player.isMuted)
        XCTAssertFalse(service.audioEngineRunning, "Native audio must not overlap a PCM engine")
        XCTAssertTrue(fixture.downloads.readyIDs.isEmpty)
        let item = try XCTUnwrap(service.player.currentItem)
        XCTAssertTrue(item.tracks.contains { $0.assetTrack?.mediaType == .audio && $0.isEnabled })
        service.pause()
        service.play()
        try await until { service.player.rate > 0 }
        XCTAssertTrue(service.player.currentItem === item, "Resume must keep the same ready stream")
        service.next()
        try await until { service.queue.currentID == fixture.bID && !service.isLoading && service.clock.position > 0.15 }
        XCTAssertFalse(service.player.isMuted)
        service.previous()
        try await until { service.queue.currentID == fixture.aID && !service.isLoading && service.clock.position > 0.15 }
        XCTAssertFalse(service.player.isMuted)
        XCTAssertTrue(fixture.downloads.readyIDs.isEmpty)
    }

    func testStreamingAudioOnlySeeksAndHonorsCameraPermissionAndExplicitPause() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let service = try await makeStreamService(fixture)
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.bID)
        try await until { !service.isLoading && service.clock.position > 0.15 }
        let item = try XCTUnwrap(service.player.currentItem), player = service.player
        service.setAudioOnly(true)
        XCTAssertNil(service.surface.playerLayer.player, "Audio only releases the visible native video layer")
        let before = service.clock.position
        try await until { service.clock.position > before + 0.1 }
        service.seek(1.5)
        try await until { service.clock.position >= 1.5 && service.player.currentTime().seconds >= 1.5 }
        service.handleInterruption(began: true)
        XCTAssertEqual(service.player.rate, 0)
        service.handleInterruption(began: false, shouldResume: false)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(service.player.rate, 0)
        XCTAssertFalse(service.wantsToPlay)
        service.play()
        try await until { service.player.rate > 0 }
        service.handleInterruption(began: true)
        service.handleInterruption(began: false, shouldResume: true)
        try await until { service.player.rate > 0 }
        service.handleInterruption(began: true)
        service.pause()
        let pausedPosition = service.player.currentTime().seconds
        service.handleInterruption(began: false, shouldResume: true)
        service.setAudioOnly(false)
        service.enteredForeground()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(service.player.rate, 0)
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertTrue(service.player === player)
        XCTAssertTrue(service.player.currentItem === item)
        XCTAssertTrue(service.surface.playerLayer.player === player)
        XCTAssertEqual(service.player.currentTime().seconds, pausedPosition, accuracy: 0.05,
            "Restoring video must not consume audio after explicit Pause")
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertTrue(fixture.downloads.readyIDs.isEmpty)
    }

    private func makeStreamService(_ fixture: SelectionVideoFixture) async throws -> PlaybackService {
        var urls: [String: URL] = [:], records: [MediaRecord] = []
        for (index, id) in fixture.ids.enumerated() {
            let name = index == 0 ? "a" : "b"
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-" + name, withExtension: "mp4"))
            let hash = try AppFiles.hash(url)
            let asset = AssetReference(driveID: "synthetic", itemID: id, fileName: name + ".mp4",
                byteSize: hash.size, sha256: hash.sha256, contentType: "video/mp4")
            records.append(MediaRecord(id: id, title: "Synthetic stream", duration: 30, status: .ready, asset: asset))
            urls[id] = url
            fixture.downloads.remove(id)
        }
        try fixture.library.install(LibraryCatalog(libraryID: "local:streaming-regression", media: records,
            playlists: [PlaylistRecord(id: fixture.playlist, name: "Synthetic stream", itemIDs: fixture.ids)]))
        let sources = urls
        let cache = try PlaybackMediaCache(directory: fixture.temporary.appendingPathComponent("cache"), byteLimit: 1) { _ in
            XCTFail("A rejected optional cache transfer must not be started")
            throw CatalogError.invalid("No full-file cache space")
        }
        let suite = "NativeStreaming-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "speakerSound")
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
            bookmarkURL: fixture.bookmark, activateSession: {}, preferences: preferences,
            mediaCache: cache, resolveRemote: { try XCTUnwrap(sources[$0.itemID]) }))
        try await until { fixture.downloads.network.isConnected }
        return service
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "The actual native streaming ownership condition must complete")
        guard condition() else { throw CatalogError.invalid("Native stream did not become ready") }
    }
}
