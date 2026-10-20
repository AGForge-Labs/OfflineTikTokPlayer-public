import XCTest
import AVFoundation
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class PlaybackSelectionFailureTests: XCTestCase {
    func testFailedChosenSavedClipStopsOldAudioAndRetriesTheSameSelection() async throws {
        let fixture = try await FailureFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        defer { service.pause() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.ids[0])
        try await until { service.audioSnapshot.frame > 2_400 }
        let oldToken = service.audioSnapshot.token
        service.next()
        try await until { !service.isLoading }

        XCTAssertEqual(service.queue.currentID, fixture.ids[1], "A failed chosen clip must not silently select the following video")
        XCTAssertFalse(service.wantsToPlay, "Preparation failure must stop the old clip's audio")
        try await until { !service.audioEngineRunning }
        XCTAssertNotNil(service.message)
        XCTAssertTrue(fixture.downloads.readyIDs.contains(fixture.ids[1]), "Playback failure must not delete Saved media")
        let stopped = service.audioSnapshot.frame
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(service.audioSnapshot.frame, stopped)

        // Replace only this test's invalid Saved fixture, then retry through the UI action.
        _ = try await fixture.downloads.importLocal(fixture.validSource, mediaID: fixture.ids[1])
        service.play()
        try await until { service.audioSnapshot.token != oldToken && service.audioSnapshot.frame > 2_400 && !service.isLoading }
        XCTAssertEqual(service.queue.currentID, fixture.ids[1])
        let selectedURL = await fixture.downloads.localURL(for: try XCTUnwrap(service.current))
        XCTAssertEqual((service.player.currentItem?.asset as? AVURLAsset)?.url, selectedURL)
        XCTAssertTrue(service.wantsToPlay)
        XCTAssertLessThanOrEqual(service.preparedAudioCount, 3)
    }

    func testPauseDuringFailedSelectionSurvivesForegroundAndInterruptionEnd() async throws {
        let fixture = try await FailureFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        defer { service.pause() }
        service.start(playlistIDs: [fixture.playlist], at: fixture.ids[1])
        service.pause()
        try await until { !service.isLoading }
        service.handleInterruption(began: true)
        service.enteredForeground()
        service.handleInterruption(began: false, shouldResume: true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(service.queue.currentID, fixture.ids[1])
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertEqual(service.player.rate, 0)
    }

    func testExternallyClockedServiceKeepsWaitingDisabledWhenRemoteNeighbourIsStaged() async throws {
        let fixture = try await FailureFixture()
        defer { fixture.remove() }
        let buffer = PlaybackBuffer()
        let service = fixture.service(buffer: buffer)
        defer { service.pause() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.ids[0])
        try await until { service.audioSnapshot.frame > 2_400 && service.player.currentItem?.status == .readyToPlay }
        // The remote preparation route marks its staged item nonlocal before download.
        // Use a known local asset here so the regression needs no network or account.
        buffer.stage(.init(mediaID: fixture.ids[1], item: AVPlayerItem(url: fixture.validSource), isLocal: false), after: fixture.ids[0])
        XCTAssertFalse(service.player.automaticallyWaitsToMinimizeStalling,
            "Apple requires waiting disabled before setRate(_:time:atHostTime:)")
        // Stop before Apple's documented invalid-argument exception on the broken build.
        guard !service.player.automaticallyWaitsToMinimizeStalling else { return }
        service.seek(0.4)
        try await until { service.player.currentTime().seconds >= 0.4 }
        XCTAssertEqual(service.queue.currentID, fixture.ids[0])
        XCTAssertTrue(service.wantsToPlay)
        XCTAssertFalse(service.player.automaticallyWaitsToMinimizeStalling)
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Playback condition did not complete in five seconds", file: file, line: line)
    }

    @MainActor private struct FailureFixture {
        let temporary: URL
        let cloud: OneDriveClient
        let downloads: OfflineDownloads
        let library: LibraryRepository
        let ids: [String]
        let validSource: URL
        let invalidSavedURL: URL
        let playlist = "local:selection-failure"
        var bookmark: URL { temporary.appendingPathComponent("playback.json") }

        init() async throws {
            temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            cloud = OneDriveClient(account: MicrosoftAccount())
            downloads = OfflineDownloads(cloud: cloud, network: NetworkStatus())
            library = LibraryRepository(cloud: cloud, catalogURL: temporary.appendingPathComponent("catalog.json"))
            ids = (0..<3).map { "local:failure-\($0)-" + UUID().uuidString }
            validSource = try XCTUnwrap(Bundle(for: PlaybackSelectionFailureTests.self).url(forResource: "test-video", withExtension: "mp4"))
            let invalid = temporary.appendingPathComponent("unreadable-synthetic.mp4")
            // Hash verification succeeds, but AVFoundation cannot decode these unique owned bytes.
            try Data(("Synthetic invalid MP4 " + UUID().uuidString).utf8).write(to: invalid)
            for (index, id) in ids.enumerated() {
                _ = try await downloads.importLocal(index == 1 ? invalid : validSource, mediaID: id)
            }
            let savedInvalid = await downloads.localURL(for:
                MediaRecord(id: ids[1], title: "Synthetic", creator: "Fixture", duration: 1.2))
            invalidSavedURL = try XCTUnwrap(savedInvalid)
            try library.install(LibraryCatalog(libraryID: "local:test", media: ids.map {
                MediaRecord(id: $0, title: "Synthetic selection failure", creator: "Fixture", duration: 1.2)
            }, playlists: [PlaylistRecord(id: playlist, name: "Synthetic failure", itemIDs: ids)]))
        }

        func service(buffer: PlaybackBuffer? = nil) -> PlaybackService {
            PlaybackService(library: library, downloads: downloads, cloud: cloud, bookmarkURL: bookmark,
                activateSession: {}, buffer: buffer)
        }

        func remove() {
            for id in ids { downloads.remove(id) }
            // importLocal can replace a record while leaving its former unique hash on disk.
            try? FileManager.default.removeItem(at: invalidSavedURL)
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
