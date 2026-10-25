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

    /// Unlike the existing resolver-isolation tests, both AVPlayer and the
    /// verified temporary cache read MP4 bytes over actual loopback HTTP here.
    /// Ownership is observable; cold native-to-PCM sample continuity is not.
    func testHTTPPlaybackWarmsTemporaryFilesAndKeepsNavigationAndRepeatOnOneGraph() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        var files: [String: Data] = [:], records: [MediaRecord] = []
        for (index, id) in fixture.ids.enumerated() {
            let name = index == 0 ? "a" : "b"
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-" + name, withExtension: "mp4"))
            let hash = try AppFiles.hash(source)
            files["/" + name + ".mp4"] = try Data(contentsOf: source)
            let asset = AssetReference(driveID: "synthetic-http", itemID: id, fileName: name + ".mp4",
                byteSize: hash.size, sha256: hash.sha256, contentType: "video/mp4")
            records.append(MediaRecord(id: id, title: "Synthetic HTTP stream", duration: 30, status: .ready, asset: asset))
            fixture.downloads.remove(id)
        }
        try fixture.library.install(LibraryCatalog(libraryID: "local:http-streaming-regression", media: records,
            playlists: [PlaylistRecord(id: fixture.playlist, name: "Synthetic HTTP stream", itemIDs: fixture.ids)]))
        let server = try HTTPPlaybackFixtureServer(files: files)
        let base = try await server.start()
        addTeardownBlock { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        addTeardownBlock { session.invalidateAndCancel() }
        let gate = HTTPPlaybackCacheGate()
        let cache = try PlaybackMediaCache(directory: fixture.temporary.appendingPathComponent("http-cache")) { asset in
            try await gate.wait()
            let (temporary, response) = try await session.download(from: base.appendingPathComponent(asset.fileName))
            do {
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let hash = try AppFiles.hash(temporary)
                guard hash.size == asset.byteSize, hash.sha256 == asset.sha256 else {
                    throw CatalogError.invalid("HTTP fixture checksum mismatch")
                }
                return temporary
            } catch { try? FileManager.default.removeItem(at: temporary); throw error }
        }
        let suite = "HTTPPlayback-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "speakerSound")
        preferences.set(false, forKey: "automaticPiP")
        preferences.set(false, forKey: "audioOnly")
        let audio = ContinuousAudioPlayer()
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
            bookmarkURL: fixture.bookmark, activateSession: { try AVAudioSession.sharedInstance().setActive(true) },
            continuousAudio: audio, preferences: preferences, mediaCache: cache,
            resolveRemote: { base.appendingPathComponent($0.fileName) }))
        // Registered after fixture.own: XCTest runs this before its awaited
        // playback close, including failures before cache release.
        addTeardownBlock { await gate.cancel(); session.invalidateAndCancel() }
        try await until { fixture.downloads.network.isConnected }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { !service.isLoading && service.clock.position > 0.15 && service.player.rate > 0 }
        let remoteItem = try XCTUnwrap(service.player.currentItem)
        let remote = try XCTUnwrap(remoteItem.asset as? AVURLAsset)
        XCTAssertEqual(remote.url.scheme, "http")
        XCTAssertEqual(remote.url.host, "localhost")
        XCTAssertFalse(service.player.isMuted)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertTrue(fixture.downloads.readyIDs.isEmpty)
        let initialHTTP = server.snapshot()
        XCTAssertGreaterThan(initialHTTP.requests, 0)
        XCTAssertGreaterThan(initialHTTP.ranges, 0, "The actual AVPlayer must exercise seekable HTTP ranges")
        let nativeBeforeWarm = service.player.currentTime().seconds
        await gate.release()
        try await until { service.preparedAudioCount == 2 }
        try await until {
            service.player.currentItem === remoteItem && service.player.rate > 0
                && service.player.currentTime().seconds > nativeBeforeWarm + 0.1
        }
        for record in records {
            let cached = await cache.file(for: try XCTUnwrap(record.asset))
            let hash = try AppFiles.hash(try XCTUnwrap(cached))
            XCTAssertEqual(hash.sha256, record.asset?.sha256)
            XCTAssertEqual(hash.size, record.asset?.byteSize)
        }
        XCTAssertTrue(service.player.currentItem === remoteItem, "Warming must preserve the advancing native stream")
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertTrue(fixture.downloads.readyIDs.isEmpty)

        service.next()
        let b = try XCTUnwrap(audio.entry(for: fixture.bID))
        try await until { service.audioSnapshot.token == b.token && service.audioSnapshot.frame > 0 && !service.isLoading }
        XCTAssertTrue(service.player.isMuted, "Prepared PCM must be the sole audible owner")
        XCTAssertTrue(service.audioEngineRunning)
        let engine = ObjectIdentifier(audio.graph.engine)
        service.cycleRepeat(); service.cycleRepeat()
        XCTAssertEqual(service.queue.repeatMode, .one)
        service.isInteractingWithFeed = false
        let beforeSeek = service.audioSnapshot
        let seekFrame = Int64(29.25 * 48_000)
        service.seek(29.25)
        // Bind the baseline to one consumed seek command and visit. Its
        // published target alone does not establish that any PCM was copied.
        var seekOwner: (version: Int, visit: Int64)?
        var qualifiedLoopBaseline: ContinuousPCMRenderer.Snapshot?
        try await until {
            if qualifiedLoopBaseline != nil { return true }
            let sample = service.audioSnapshot
            guard sample.token == b.token, sample.selectionVersion > beforeSeek.selectionVersion,
                  !sample.ended else { return false }
            if seekOwner == nil { seekOwner = (sample.selectionVersion, sample.visit) }
            guard let owner = seekOwner, sample.selectionVersion == owner.version,
                  sample.visit == owner.visit, sample.frame > seekFrame, sample.frame < b.frames else { return false }
            qualifiedLoopBaseline = sample
            return true
        }
        let beforeLoop = try XCTUnwrap(qualifiedLoopBaseline)
        try await until { service.audioSnapshot.visit > beforeLoop.visit && service.audioSnapshot.frame < 2 * 48_000 }
        XCTAssertEqual(service.queue.currentID, fixture.bID)
        XCTAssertEqual(service.audioSnapshot.token, b.token)
        let afterLoop = service.audioSnapshot
        print("HTTPSeekLoopCounters schema=1 beforeSeekUnderruns=\(beforeSeek.underrunFrames) seekTargetFrame=\(seekFrame) baselineFrame=\(beforeLoop.frame) baselineUnderruns=\(beforeLoop.underrunFrames) afterLoopFrame=\(afterLoop.frame) afterLoopUnderruns=\(afterLoop.underrunFrames) baselineRequiresCopiedPCM=true naturalLoopAssertion=unchanged")
        XCTAssertEqual(afterLoop.underrunFrames, beforeLoop.underrunFrames)
        XCTAssertEqual(ObjectIdentifier(audio.graph.engine), engine)

        service.previous()
        let a = try XCTUnwrap(audio.entry(for: fixture.aID))
        try await until { service.audioSnapshot.token == a.token && service.audioSnapshot.frame > 0 && !service.isLoading }
        XCTAssertEqual(service.queue.currentID, fixture.aID)
        XCTAssertTrue(service.player.isMuted)
        XCTAssertTrue(service.audioEngineRunning)
        XCTAssertEqual(ObjectIdentifier(audio.graph.engine), engine)
        XCTAssertTrue(fixture.downloads.readyIDs.isEmpty)
        let finalHTTP = server.snapshot()
        print("HTTPPlaybackBoundary schema=1 requests=\(finalHTTP.requests) rangeResponses=\(finalHTTP.ranges) bytes=\(finalHTTP.bytes) realHTTP=true verifiedTemporaryFiles=2 savedCopies=0 warmedPCMNextPrevious=true repeatSameToken=true sameEngine=true nativeToPCMExactAudioJoin=false physicalOutput=unverified")
        try await fixture.closePlayback(service)
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
