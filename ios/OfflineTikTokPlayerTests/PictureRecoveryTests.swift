import XCTest
import AVFoundation
import UIKit
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class PictureRecoveryTests: XCTestCase {
    func testAdvancingNativeClockWithNoNewPicturesRepairsVideoWithoutChangingPCMVisit() async throws {
        let fixture = try await PictureRecoveryFixture(test: self)
        let service = fixture.service
        service.start(playlistIDs: [fixture.playlist], at: fixture.mediaID)
        try await until { service.isVideoReady && service.submittedVideoFrameCount >= 4 && service.audioSnapshot.frame > 12_000 }
        let before = service.audioSnapshot
        let nativeBefore = service.player.currentTime().seconds
        let framesBefore = service.submittedVideoFrameCount
        var repairs = 0
        service.onDebugVideoSeekStamp = { event in
            if event.force {
                repairs += 1
                service.shouldDebugAcquireVideoFrame = nil
            }
        }
        service.shouldDebugAcquireVideoFrame = { _ in false }
        try await until {
            repairs > 0 && service.submittedVideoFrameCount >= framesBefore + 4
                && (service.videoFramePositionSeconds ?? 0) > nativeBefore + 0.5
        }
        let after = service.audioSnapshot
        XCTAssertEqual(repairs, 1)
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

    func testPauseAndAudioOnlyPreventPictureRepair() async throws {
        let fixture = try await PictureRecoveryFixture(test: self)
        let service = fixture.service
        service.start(playlistIDs: [fixture.playlist], at: fixture.mediaID)
        try await until { service.isVideoReady && service.audioSnapshot.frame > 12_000 }
        var repairs = 0
        service.onDebugVideoSeekStamp = { if $0.force { repairs += 1 } }
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
}

/// A small real-service fixture; no cloud, private media or fabricated PCM snapshots.
@MainActor
private final class PictureRecoveryFixture {
    let mediaID = "local:picture-recovery-" + UUID().uuidString
    let playlist = "local:picture-recovery-playlist"
    let service: PlaybackService
    private let directory: URL
    private let window: UIWindow
    private weak var previousWindow: UIWindow?
    private let preferences = ["speakerSound", "automaticPiP", "audioOnly"].map { ($0, UserDefaults.standard.object(forKey: $0)) }

    init(test: XCTestCase) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cloud = OneDriveClient(account: MicrosoftAccount())
        let downloads = try OfflineDownloads(cloud: cloud, network: NetworkStatus(), debugLocalRoot: directory)
        let library = LibraryRepository(cloud: cloud, catalogURL: directory.appendingPathComponent("catalog.json"))
        let source = try XCTUnwrap(Bundle(for: PictureRecoveryTests.self).url(forResource: "test-selection-a", withExtension: "mp4"))
        _ = try await downloads.importLocal(source, mediaID: mediaID)
        try library.install(LibraryCatalog(libraryID: "local:picture-recovery", media: [
            MediaRecord(id: mediaID, title: "Synthetic picture recovery", duration: 30)
        ], playlists: [PlaylistRecord(id: playlist, name: "Synthetic", itemIDs: [mediaID])]))
        service = PlaybackService(library: library, downloads: downloads, cloud: cloud,
            bookmarkURL: directory.appendingPathComponent("playback.json"), activateSession: {})
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
