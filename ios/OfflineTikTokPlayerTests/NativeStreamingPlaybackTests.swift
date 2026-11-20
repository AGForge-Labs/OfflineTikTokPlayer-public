import XCTest
import AVFoundation
import UIKit
import PlayerCore
@testable import OfflineTikTokPlayer

/// Exercise the actual native transport with original synthetic MP4s returned by
/// a fake cloud URL resolver. This tests service/clock ownership, not HTTP or a phone.
@MainActor
final class NativeStreamingPlaybackTests: XCTestCase {
    func testPlayingFromPersonalListRecordsOnlyStartedVideosInRecencyOrder() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let service = try await makeStreamService(fixture)
        let suite = "PersonalStreamingHistory-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let personal = PersonalLibrary(defaults: preferences)
        service.didPlayMedia = { personal.recordPlayed($0) }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [], at: fixture.bID, within: [fixture.bID, fixture.aID])
        try await until { personal.history == [fixture.bID] }
        service.next()
        try await until { personal.history == [fixture.aID, fixture.bID] }
        service.previous()
        try await until { personal.history == [fixture.bID, fixture.aID] }
        XCTAssertTrue(fixture.downloads.readyIDs.isEmpty)
    }

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

    func testReturningToAHealthyNativeStreamDoesNotRestartItsPicture() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let service = try await makeStreamService(fixture)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        service.surface.frame = host.view.bounds
        service.surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(service.surface)
        service.surface.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; oldKey?.makeKey() }

        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { service.isVideoReady && (service.debugDisplayedVideoPositionSeconds ?? 0) > 0.2 }
        let item = try XCTUnwrap(service.player.currentItem)
        XCTAssertFalse(service.player.isMuted)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let previous = try XCTUnwrap(service.debugDisplayedVideoPositionSeconds)
        try await until {
            guard let image = service.debugDisplayedVideoPositionSeconds, image > previous + 0.1 else { return false }
            return abs(item.currentTime().seconds - image) < 0.1
        }
        let epoch = service.debugAlignedVideoPollState.frame.imageEpoch
        service.enteredForeground()
        XCTAssertEqual(service.debugAlignedVideoPollState.frame.imageEpoch, epoch, "Healthy foreground return must not flush the advancing picture")
        XCTAssertTrue(service.player.currentItem === item)
        try await until { (service.debugDisplayedVideoPositionSeconds ?? 0) > previous + 0.25 }
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
        preferences.set(false, forKey: "automaticPiP")
        preferences.set(false, forKey: "audioOnly")
        let audio = ContinuousAudioPlayer()
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
            bookmarkURL: fixture.bookmark, activateSession: { try AVAudioSession.sharedInstance().setActive(true) },
            continuousAudio: audio, preferences: preferences, mediaCache: cache,
            resolveRemote: { base.appendingPathComponent($0.fileName) }))
        service.speakerSound = false
        // Registered after fixture.own: XCTest runs this before its awaited
        // playback close, including failures before cache release.
        addTeardownBlock { await gate.cancel(); session.invalidateAndCancel() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        service.surface.frame = host.view.bounds
        host.view.addSubview(service.surface)
        host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; oldKey?.makeKey() }
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
        try await until { service.isVideoReady && (service.debugDisplayedVideoPositionSeconds ?? 0) > 0.15 }
        let layer = try XCTUnwrap(service.surface.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
        let held = try XCTUnwrap(service.debugDisplayedVideoPositionSeconds)
        let lastPrimaryPTS = try XCTUnwrap(service.videoFramePositionSeconds)
        let alternate = service.debugAlternateFrameCount
        let faultStart = ContinuousClock.now
        service.debugWithholdItemOutput = true
        while ContinuousClock.now - faultStart < .milliseconds(500),
              service.debugAlternateFrameCount < alternate + 2 || (service.debugDisplayedVideoPositionSeconds ?? 0) <= held {
            try await Task.sleep(for: .milliseconds(8))
        }
        let hold = ContinuousClock.now - faultStart
        // This file is 24 fps, but its blue marker only moves every three frames.
        // Observe a different marker on the displayed surface while the fault is
        // still active: two different PTS can both describe the same picture.
        var firstAlternateMarker: CGPoint?, changedMarker: CGPoint?
        while ContinuousClock.now - faultStart < .milliseconds(500) {
            if let displayed = service.debugDisplayedVideoPositionSeconds, displayed > lastPrimaryPTS,
               let marker = layer.sampleBufferRenderer.displayedPixelBuffer().flatMap(httpFixtureMarker) {
                if let firstAlternateMarker {
                    if abs(marker.x - firstAlternateMarker.x) >= 6 || abs(marker.y - firstAlternateMarker.y) >= 6 {
                        changedMarker = marker
                        break
                    }
                } else { firstAlternateMarker = marker }
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        let visibleHold = ContinuousClock.now - faultStart
        service.debugWithholdItemOutput = false
        XCTAssertGreaterThanOrEqual(service.debugAlternateFrameCount - alternate, 2)
        XCTAssertGreaterThan(try XCTUnwrap(service.debugDisplayedVideoPositionSeconds), held)
        XCTAssertLessThan(hold, .milliseconds(500))
        XCTAssertNotNil(changedMarker, "The blue marker in the displayed HTTP video must actually move")
        XCTAssertLessThan(visibleHold, .milliseconds(500))
        XCTAssertTrue(service.player.currentItem === remoteItem)
        XCTAssertFalse(service.player.isMuted)
        XCTAssertGreaterThan(service.player.currentTime().seconds, held)
        print("HTTP_PICTURE_BRIDGE gap=\(hold) visibleMotion=\(visibleHold) changedPixels=\(changedMarker != nil) advancingAlternateFrames=\(service.debugAlternateFrameCount - alternate) permanentDownloads=\(fixture.downloads.readyIDs.count)")
        try await until { service.player.items().count == 2 }
        let stagedNext = try XCTUnwrap(service.player.items().dropFirst().first)
        XCTAssertEqual((stagedNext.asset as? AVURLAsset)?.url.lastPathComponent, "b.mp4")
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
        XCTAssertTrue(service.player.items().dropFirst().first === stagedNext, "Caching the current clip must not evict the next video")
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertTrue(fixture.downloads.readyIDs.isEmpty)

        service.next()
        let b = try XCTUnwrap(audio.entry(for: fixture.bID))
        try await until { service.audioSnapshot.token == b.token && service.audioSnapshot.frame > 0 && !service.isLoading }
        XCTAssertTrue(service.player.currentItem === stagedNext, "The next selection must reuse its prepared video")
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

    /// The generated 160×96 clip moves a blue 16×24 marker between four rows.
    /// Sample the center line of each row directly, without a color conversion.
    private func httpFixtureMarker(_ pixel: CVPixelBuffer) -> CGPoint? {
        guard CVPixelBufferGetWidth(pixel) == 160, CVPixelBufferGetHeight(pixel) == 96,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let isBlue: (Int, Int) -> Bool
        switch CVPixelBufferGetPixelFormatType(pixel) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard CVPixelBufferGetPlaneCount(pixel) == 2,
                  let address = CVPixelBufferGetBaseAddressOfPlane(pixel, 1) else { return nil }
            let bytes = address.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)
            isBlue = { x, y in
                let offset = y / 2 * stride + x / 2 * 2
                return Int(bytes[offset]) > Int(bytes[offset + 1]) + 60
            }
        case kCVPixelFormatType_32BGRA:
            guard let address = CVPixelBufferGetBaseAddress(pixel) else { return nil }
            let bytes = address.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            isBlue = { x, y in
                let offset = y * stride + x * 4
                return Int(bytes[offset]) > max(Int(bytes[offset + 1]), Int(bytes[offset + 2])) + 60
            }
        default: return nil
        }
        for y in stride(from: 12, to: 96, by: 24) {
            var sum = 0, count = 0
            for x in stride(from: 1, to: 160, by: 2) where isBlue(x, y) { sum += x; count += 1 }
            if (6...10).contains(count) { return CGPoint(x: Double(sum) / Double(count), y: Double(y)) }
        }
        return nil
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
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
            bookmarkURL: fixture.bookmark, activateSession: {}, preferences: preferences,
            mediaCache: cache, resolveRemote: { try XCTUnwrap(sources[$0.itemID]) }))
        service.speakerSound = false
        try await until { fixture.downloads.network.isConnected }
        return service
    }

    func testUnansweredStreamStartupRetriesOnceAndTheSameClipCanPlayAgain() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let source = try XCTUnwrap(fixture.savedURLs[fixture.aID])
        let media = try Data(contentsOf: source)
        let hash = try AppFiles.hash(source)
        fixture.downloads.remove(fixture.aID)
        let asset = AssetReference(driveID: "synthetic-http", itemID: fixture.aID, fileName: "video.mp4",
            byteSize: hash.size, sha256: hash.sha256, contentType: "video/mp4")
        try fixture.library.install(LibraryCatalog(libraryID: "local:http-startup", media: [
            MediaRecord(id: fixture.aID, title: "Synthetic stalled stream", duration: 30, status: .ready, asset: asset)
        ], playlists: [PlaylistRecord(id: fixture.playlist, name: "Synthetic", itemIDs: [fixture.aID])]))
        let server = try HTTPPlaybackFixtureServer(files: ["/video.mp4": media], stalledPaths: ["/first.mp4", "/retry.mp4"])
        let base = try await server.start()
        let cache = try PlaybackMediaCache(directory: fixture.temporary.appendingPathComponent("stalled-http-cache"), byteLimit: 1) { _ in
            throw CatalogError.invalid("No cache is needed to recover a stream")
        }
        var lookups = 0, refreshes = 0
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
            bookmarkURL: fixture.bookmark, activateSession: {}, mediaCache: cache,
            resolveRemote: { _ in
                lookups += 1
                return base.appendingPathComponent(lookups == 1 ? "first.mp4" : "video.mp4")
            },
            refreshRemote: { _ in
                refreshes += 1
                return base.appendingPathComponent("retry.mp4")
            }))
        addTeardownBlock { server.stop() }
        service.setAudioOnly(false)
        service.automaticPiP = false
        service.speakerSound = false
        try await until { fixture.downloads.network.isConnected }
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until(timeout: .seconds(29)) { !service.isLoading && service.message != nil }
        XCTAssertGreaterThanOrEqual(server.snapshot().stalled, 2)
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(service.queue.currentID, fixture.aID)
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertTrue(service.message?.contains("OneDrive") == true)

        service.play()
        try await until { !service.isLoading && service.player.rate > 0 && service.clock.position > 0.15 }
        XCTAssertEqual(service.queue.currentID, fixture.aID)
        XCTAssertEqual(lookups, 2)
        XCTAssertEqual(refreshes, 1)
        XCTAssertNil(service.message)
        print("STREAM_START_RECOVERY freshLookups=\(refreshes) unansweredRequests=\(server.snapshot().stalled) position=\(service.clock.position)")
        service.pause()
    }

    private func until(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "The actual native streaming ownership condition must complete")
        guard condition() else { throw CatalogError.invalid("Native stream did not become ready") }
    }
}
