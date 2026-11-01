import XCTest
import AVFoundation
import UIKit
import CoreVideo
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class PictureRecoveryTests: XCTestCase {
    func testNextPreviousAndRepeatOneKeepRealPicturesAndTheExpectedAudioVisit() async throws {
        let fixture = try await PictureRecoveryFixture(test: self)
        let service = fixture.service
        let layer = try XCTUnwrap(service.surface.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
        service.start(playlistIDs: [fixture.playlist], at: fixture.mediaID)
        try await until { service.isVideoReady && self.pictureIs(layer, red: true) }
        var missingPictures = 0
        func sample(red: Bool) -> Bool {
            if layer.sampleBufferRenderer.displayedPixelBuffer() == nil { missingPictures += 1 }
            return service.isVideoReady && self.pictureIs(layer, red: red)
        }
        service.next()
        try await until { service.queue.currentID == fixture.otherID && sample(red: false) }
        service.previous()
        try await until { service.queue.currentID == fixture.mediaID && sample(red: true) }
        service.cycleRepeat(); service.cycleRepeat()
        XCTAssertEqual(service.queue.repeatMode, .one)
        service.seek(29.6)
        try await until { service.audioSnapshot.frame > 1_420_000 && sample(red: true) }
        let before = service.audioSnapshot
        try await until {
            service.audioSnapshot.visit > before.visit && service.queue.currentID == fixture.mediaID
                && (service.videoFramePositionSeconds ?? 30) < 1 && sample(red: true)
        }
        XCTAssertEqual(service.audioSnapshot.token, before.token)
        XCTAssertEqual(missingPictures, 0, "The real renderer must hold its picture through Next, Previous and loop seeks")
        XCTAssertTrue(service.wantsToPlay)
        XCTAssertNil(service.message)
    }

    func testAdvancingNativeClockWithNoNewPicturesRepairsVideoWithoutChangingPCMVisit() async throws {
        let fixture = try await PictureRecoveryFixture(test: self)
        let service = fixture.service
        service.start(playlistIDs: [fixture.playlist], at: fixture.mediaID)
        try await until { service.isVideoReady && service.submittedVideoFrameCount >= 4 && service.audioSnapshot.frame > 12_000 }
        let before = service.audioSnapshot
        let nativeItem = try XCTUnwrap(service.player.currentItem)
        let output = try XCTUnwrap(nativeItem.outputs.first)
        let nativeBefore = service.player.currentTime().seconds
        let framesBefore = service.submittedVideoFrameCount
        var repairs = 0
        service.onDebugVideoOutputRecovery = {
            repairs += 1
            service.shouldDebugAcquireVideoFrame = nil
        }
        service.shouldDebugAcquireVideoFrame = { _ in false }
        try await until {
            repairs > 0 && service.submittedVideoFrameCount >= framesBefore + 4
                && (service.videoFramePositionSeconds ?? 0) > nativeBefore + 0.5
        }
        let after = service.audioSnapshot
        XCTAssertEqual(repairs, 1)
        XCTAssertTrue(service.player.currentItem === nativeItem)
        XCTAssertEqual(nativeItem.outputs.count, 1)
        XCTAssertFalse(nativeItem.outputs.first === output, "The actual SDK output must be replaced")
        XCTAssertEqual(service.queue.currentID, fixture.mediaID)
        XCTAssertEqual(after.token, before.token)
        XCTAssertEqual(after.visit, before.visit)
        XCTAssertEqual(after.selectionVersion, before.selectionVersion)
        XCTAssertGreaterThan(after.frame, before.frame + 48_000)
        XCTAssertTrue(service.audioEngineRunning)
        XCTAssertTrue(service.wantsToPlay)
        XCTAssertNil(service.message)
        print("IMAGE_PROGRESS_RECOVERY repairs=\(repairs) sameToken=\(after.token == before.token) sameVisit=\(after.visit == before.visit) audioFrames=\(after.frame - before.frame) newVideoFrames=\(service.submittedVideoFrameCount - framesBefore)")
    }

    func testNativeAudioOwnerRecoversItsPictureWithoutSeekingTheAudiblePlayer() async throws {
        let fixture = try await PictureRecoveryFixture(test: self, nativeAudio: true)
        let service = fixture.service
        service.start(playlistIDs: [fixture.playlist], at: fixture.mediaID)
        try await until { service.isVideoReady && service.player.currentTime().seconds > 0.25 }
        let item = try XCTUnwrap(service.player.currentItem)
        let output = try XCTUnwrap(item.outputs.first)
        let before = service.player.currentTime().seconds
        let frames = service.submittedVideoFrameCount
        let jumps = PictureTimeJumpCounter()
        let observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification,
            object: item, queue: .main) { _ in MainActor.assumeIsolated { jumps.value += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        var repairs = 0
        service.onDebugVideoOutputRecovery = {
            repairs += 1
            service.shouldDebugAcquireVideoFrame = nil
        }
        service.shouldDebugAcquireVideoFrame = { _ in false }
        try await until { repairs == 1 && service.submittedVideoFrameCount >= frames + 4 && service.isVideoReady }
        XCTAssertTrue(service.player.currentItem === item)
        XCTAssertEqual(item.outputs.count, 1)
        XCTAssertFalse(item.outputs.first === output)
        XCTAssertGreaterThan(service.player.currentTime().seconds, before + 1)
        XCTAssertEqual(jumps.value, 0, "Replacing a picture output must not seek the streamed/native audio clock")
        XCTAssertFalse(service.player.isMuted)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertTrue(service.wantsToPlay)
        XCTAssertNil(service.message)
    }

    func testPauseAndAudioOnlyPreventPictureRepair() async throws {
        let fixture = try await PictureRecoveryFixture(test: self)
        let service = fixture.service
        service.start(playlistIDs: [fixture.playlist], at: fixture.mediaID)
        try await until { service.isVideoReady && service.audioSnapshot.frame > 12_000 }
        var repairs = 0
        service.onDebugVideoOutputRecovery = { repairs += 1 }
        service.shouldDebugAcquireVideoFrame = { _ in false }
        service.pause()
        try await Task.sleep(for: .milliseconds(1_800))
        XCTAssertEqual(repairs, 0)
        XCTAssertFalse(service.wantsToPlay)
        service.setAudioOnly(true)
        repairs = 0
        service.play()
        let before = service.audioSnapshot
        try await Task.sleep(for: .milliseconds(1_800))
        XCTAssertEqual(repairs, 0)
        XCTAssertGreaterThan(service.audioSnapshot.frame, before.frame + 24_000)
        XCTAssertTrue(service.wantsToPlay)
        XCTAssertEqual(service.queue.currentID, fixture.mediaID)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(7)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Actual picture/audio recovery did not finish")
        if !condition() { throw CatalogError.invalid("Synthetic picture recovery timed out") }
    }

    private func pictureIs(_ layer: AVSampleBufferDisplayLayer, red: Bool) -> Bool {
        guard let pixel = layer.sampleBufferRenderer.displayedPixelBuffer(),
              CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA else { return false }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel), row = CVPixelBufferGetBytesPerRow(pixel)
        var r = 0, g = 0
        for y in stride(from: 0, to: height, by: max(1, height / 16)) {
            for x in stride(from: 0, to: width, by: max(1, width / 16)) {
                r += Int(base[y * row + x * 4 + 2]); g += Int(base[y * row + x * 4 + 1])
            }
        }
        return red ? r > g * 2 : g > r * 2
    }
}

/// A small real-service fixture; no cloud, private media or fabricated PCM snapshots.
@MainActor
private final class PictureRecoveryFixture {
    let mediaID = "local:picture-recovery-" + UUID().uuidString
    let otherID = "local:picture-recovery-other-" + UUID().uuidString
    let playlist = "local:picture-recovery-playlist"
    let service: PlaybackService
    private let directory: URL
    private let window: UIWindow
    private weak var previousWindow: UIWindow?
    private let preferences = ["speakerSound", "automaticPiP", "audioOnly"].map { ($0, UserDefaults.standard.object(forKey: $0)) }

    init(test: XCTestCase, nativeAudio: Bool = false) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cloud = OneDriveClient(account: MicrosoftAccount())
        let downloads = try OfflineDownloads(cloud: cloud, network: NetworkStatus(), debugLocalRoot: directory)
        let library = LibraryRepository(cloud: cloud, catalogURL: directory.appendingPathComponent("catalog.json"))
        for (key, name) in [(mediaID, "test-selection-a"), (otherID, "test-selection-b")] {
            let source = try XCTUnwrap(Bundle(for: PictureRecoveryTests.self).url(forResource: name, withExtension: "mp4"))
            _ = try await downloads.importLocal(source, mediaID: key)
        }
        try library.install(LibraryCatalog(libraryID: "local:picture-recovery", media: [
            MediaRecord(id: mediaID, title: "Synthetic picture recovery A", duration: 30),
            MediaRecord(id: otherID, title: "Synthetic picture recovery B", duration: 30)
        ], playlists: [PlaylistRecord(id: playlist, name: "Synthetic", itemIDs: [mediaID, otherID])]))
        if nativeAudio {
            service = PlaybackService(library: library, downloads: downloads, cloud: cloud,
                bookmarkURL: directory.appendingPathComponent("playback.json"), activateSession: {},
                preparePCM: { _, _, _, _ in throw ContinuousPCMDecoder.Failure.unsupportedPCM })
        } else {
            service = PlaybackService(library: library, downloads: downloads, cloud: cloud,
                bookmarkURL: directory.appendingPathComponent("playback.json"), activateSession: {})
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        service.setAudioOnly(false); service.automaticPiP = false; service.speakerSound = false
        window.frame = scene.coordinateSpace.bounds; window.windowLevel = .alert + 1
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        service.surface.frame = host.view.bounds
        service.surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(service.surface)
        host.view.layoutIfNeeded()
        test.addTeardownBlock { @MainActor [self] in
            service.onDebugVideoSeekStamp = nil
            service.onDebugVideoOutputRecovery = nil
            service.shouldDebugAcquireVideoFrame = nil
            let closed = await withCheckedContinuation { continuation in
                service.debugCloseOwnedPlayback { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(closed, "Owned picture/audio work must close before fixture removal")
            window.isHidden = true; window.rootViewController = nil
            previousWindow?.makeKey()
            for (key, value) in preferences {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            let parent = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
            let owned = directory.standardizedFileURL.resolvingSymlinksInPath()
            if closed, UUID(uuidString: owned.lastPathComponent) != nil,
               owned.deletingLastPathComponent() == parent { try FileManager.default.removeItem(at: owned) }
        }
    }
}

@MainActor private final class PictureTimeJumpCounter { var value = 0 }
