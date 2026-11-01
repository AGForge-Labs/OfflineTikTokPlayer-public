import XCTest
import AVFoundation
import CoreVideo
import CryptoKit
import UIKit
@testable import OfflineTikTokPlayer

@MainActor
final class VideoPresentationContinuityTests: XCTestCase {
    func testSeekAndSourceAdoptionRetainTheDisplayedPictureWithoutOldFrameCredit() async throws {
        let fixture = try await PresentedVideo.make()
        defer { fixture.close() }
        let ticket = try XCTUnwrap(fixture.bridge.debugAlignedPollState.ticket)
        let original = try fingerprint(fixture.bridge.displayLayer.sampleBufferRenderer.displayedPixelBuffer())
        XCTAssertNotNil(fixture.bridge.currentFrameReceipt(for: ticket))
        let seek = fixture.bridge.beginSeek()
        XCTAssertNil(fixture.bridge.currentFrameReceipt(for: ticket), "Held pixels cannot credit a new seek")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(try fingerprint(fixture.bridge.displayLayer.sampleBufferRenderer.displayedPixelBuffer()), original,
                       "A pending seek must not turn the visible video/PiP image black")
        fixture.bridge.completeSeek(seek)
        let next = AVPlayerItem(url: fixture.url)
        let nextTicket = try XCTUnwrap(fixture.bridge.setCurrentItem(next))
        XCTAssertNil(fixture.bridge.currentFrameReceipt(for: nextTicket))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(try fingerprint(fixture.bridge.displayLayer.sampleBufferRenderer.displayedPixelBuffer()), original,
                       "Keep the displayed picture while the next source prepares")
        fixture.bridge.setCurrentItem(nil)
        let cleared = await until { fixture.bridge.displayLayer.sampleBufferRenderer.displayedPixelBuffer() == nil }
        XCTAssertTrue(cleared, "Intentional stop clears the retained picture")
    }

    func testForegroundFeedDoesNotDropEveryOtherFrameOfSixtyFPSVideo() async throws {
        let fixture = try await PresentedVideo.make()
        defer { fixture.close() }
        let rate = try await measuredRate(fixture)
        XCTAssertGreaterThan(rate, 40, "A 60 fps source must not be limited by a 30 Hz app timer")
    }

    func testNativeGeometryControlPreservesTheSixtyFPSFixtureCadence() async throws {
        let fixture = try await PresentedVideo.make(nativeGeometry: true)
        defer { fixture.close() }
        let rate = try await measuredRate(fixture)
        XCTAssertGreaterThan(rate, 40, "The same source must remain smooth without an unnecessary composition")
    }

    private func measuredRate(_ fixture: PresentedVideo) async throws -> Double {
        let ticket = try XCTUnwrap(fixture.bridge.debugAlignedPollState.ticket)
        let position = fixture.player.currentTime().seconds
        XCTAssertTrue(fixture.bridge.installTimeline(ticket, positionSeconds: position, durationSeconds: 6, isPlaying: true))
        fixture.player.playImmediately(atRate: 1)
        XCTAssertTrue(fixture.bridge.activate(ticket))
        let first = fixture.bridge.submittedFrameCount
        let started = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(1200))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let rate = Double(fixture.bridge.submittedFrameCount - first) / elapsed
        print("VIDEO_PRESENTATION nativeSourceFPS=60 nativeGeometry=\(fixture.nativeGeometry) submittedFPS=\(rate) elapsed=\(elapsed) nativeStart=\(position) nativeEnd=\(fixture.player.currentTime().seconds) requestedEnd=\(fixture.bridge.requestedPositionSeconds) copiedEnd=\(fixture.bridge.lastCopiedFramePositionSeconds ?? -1)")
        XCTAssertEqual(fixture.player.currentItem, fixture.item)
        return rate
    }

    private func fingerprint(_ value: CVPixelBuffer?) throws -> String {
        let pixel = try XCTUnwrap(value, "An actual displayed pixel buffer is required")
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
        let size = CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel)
        return SHA256.hash(data: Data(bytes: base, count: size)).map { String(format: "%02x", $0) }.joined()
    }

    private func until(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

@MainActor
private final class PresentedVideo {
    let bridge = ContinuousPictureInPicture()
    let url: URL
    let item: AVPlayerItem
    let player: AVPlayer
    let window: UIWindow
    private(set) var nativeGeometry = false
    private var oldKey: UIWindow?
    private var resource: ContinuousPictureInPicture.PreparedVideoResource?

    private init(url: URL, scene: UIWindowScene) {
        self.url = url
        item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        window = UIWindow(windowScene: scene)
        oldKey = scene.windows.first(where: \.isKeyWindow)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        bridge.displayLayer.frame = host.view.bounds
        host.view.layer.addSublayer(bridge.displayLayer)
    }

    static func make(nativeGeometry: Bool = false) async throws -> PresentedVideo {
        let url = try XCTUnwrap(Bundle(for: VideoPresentationContinuityTests.self)
            .url(forResource: "test-motion-60", withExtension: "mp4"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = PresentedVideo(url: url, scene: scene)
        fixture.nativeGeometry = nativeGeometry
        do {
            let plan = nativeGeometry
                ? try await ContinuousPictureInPicture.debugPrepareVideoResource(for: fixture.item, nativeGeometry: true)
                : try await ContinuousPictureInPicture.prepareVideoResource(for: fixture.item)
            fixture.resource = try XCTUnwrap(plan.install())
            let ticket = try XCTUnwrap(fixture.bridge.setCurrentItem(fixture.item, preparedVideo: fixture.resource))
            fixture.player.playImmediately(atRate: 1)
            let deadline = ContinuousClock.now + .seconds(5)
            while fixture.item.status != .readyToPlay || fixture.player.currentTime().seconds < 0.2 {
                guard ContinuousClock.now < deadline else { throw PreparationFailed.notReady }
                try await Task.sleep(for: .milliseconds(10))
            }
            fixture.player.pause()
            let position = fixture.player.currentTime().seconds
            XCTAssertTrue(fixture.bridge.installTimeline(ticket, positionSeconds: position, durationSeconds: 6, isPlaying: false))
            XCTAssertTrue(fixture.bridge.activate(ticket))
            while fixture.bridge.currentFrameReceipt(for: ticket) == nil || !fixture.bridge.displayLayer.isReadyForDisplay {
                guard ContinuousClock.now < deadline else { throw PreparationFailed.notReady }
                fixture.bridge.updatePlayback(positionSeconds: position, durationSeconds: 6, isPlaying: false)
                try await Task.sleep(for: .milliseconds(10))
            }
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    func close() {
        bridge.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
        resource?.retire()
        resource = nil
        bridge.displayLayer.removeFromSuperlayer()
        window.isHidden = true
        window.rootViewController = nil
        oldKey?.makeKey()
        oldKey = nil
    }
    private enum PreparationFailed: Error { case notReady }
}
