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
        XCTAssertTrue(fixture.usedNativeGeometry, "The qualified production path must avoid an unnecessary compositor")
        let rate = try await measuredRate(fixture)
        XCTAssertGreaterThan(rate, 40, "A 60 fps source must not be limited by a 30 Hz app timer")
    }

    func testNativeGeometryControlPreservesTheSixtyFPSFixtureCadence() async throws {
        let fixture = try await PresentedVideo.make(nativeGeometry: true)
        defer { fixture.close() }
        let rate = try await measuredRate(fixture)
        XCTAssertGreaterThan(rate, 40, "The same source must remain smooth without an unnecessary composition")
    }

    func testShortTrailingAudioKeepsNativeVideoAndAFreshLastFrameWhilePaused() async throws {
        let fixture = try await PresentedVideo.make(resourceName: "test-motion-audio-tail", disableAudioTrack: true)
        defer { fixture.close() }
        XCTAssertTrue(fixture.usedNativeGeometry, "A 10 ms audio tail must preserve the native video path")
        XCTAssertNil(fixture.item.videoComposition)
        let ticket = try XCTUnwrap(fixture.bridge.debugAlignedPollState.ticket)
        let before = fixture.bridge.submittedFrameCount
        let seek = fixture.bridge.beginSeek()
        let sought = await fixture.seek(to: 6.005)
        XCTAssertTrue(sought)
        fixture.bridge.completeSeek(seek)
        XCTAssertTrue(fixture.bridge.installTimeline(ticket, positionSeconds: 6.005, durationSeconds: 6.01, isPlaying: false))
        XCTAssertTrue(fixture.bridge.activate(ticket))
        let ready = await until {
            fixture.bridge.updatePlayback(positionSeconds: 6.005, durationSeconds: 6.01, isPlaying: false)
            return fixture.bridge.currentFrameReceipt(for: ticket) != nil
                && fixture.bridge.submittedFrameCount > before
        }
        XCTAssertTrue(ready, "The held departing image cannot replace fresh video-end frame proof")
        XCTAssertGreaterThan(fixture.bridge.lastFramePositionSeconds ?? -1, 5.95)
        XCTAssertLessThanOrEqual(fixture.bridge.lastFramePositionSeconds ?? 10, 6.005)
    }

    func testRetainedOutgoingPixelsCannotCreditAnIncomingImageBeforeItDisplays() async throws {
        let fixture = try await PresentedVideo.make()
        defer { fixture.close() }
        let ticket = try XCTUnwrap(fixture.bridge.debugAlignedPollState.ticket)
        let oldImage = try fingerprint(fixture.bridge.displayLayer.sampleBufferRenderer.displayedPixelBuffer())
        let timebase = try XCTUnwrap(fixture.bridge.displayLayer.controlTimebase)
        let seek = fixture.bridge.beginSeek()
        let sought = await fixture.seek(to: 1.5)
        XCTAssertTrue(sought)
        fixture.bridge.completeSeek(seek)
        var frozen = false
        fixture.bridge.onDebugCopiedPixel = { _, _ in
            // Keep the genuine SDK image queued but not due, like a pause before
            // a submitted future PTS. Do not manufacture an image or receipt.
            if !frozen {
                CMTimebaseSetRate(timebase, rate: 0)
                CMTimebaseSetTime(timebase, time: .zero)
                frozen = true
            }
        }
        XCTAssertTrue(fixture.bridge.installTimeline(ticket, positionSeconds: 1.5, durationSeconds: 6, isPlaying: false))
        XCTAssertTrue(fixture.bridge.activate(ticket))
        let enqueued = await until {
            if !frozen { fixture.bridge.updatePlayback(positionSeconds: 1.5, durationSeconds: 6, isPlaying: false) }
            return fixture.bridge.currentFrameReceipt(for: ticket) != nil
        }
        fixture.bridge.onDebugCopiedPixel = nil
        XCTAssertTrue(enqueued)
        XCTAssertTrue(frozen)
        XCTAssertEqual(try fingerprint(fixture.bridge.displayLayer.sampleBufferRenderer.displayedPixelBuffer()), oldImage)
        let monitor = PlaybackFrameMonitor()
        monitor.debugAutomaticallyTicks = false
        defer { monitor.cancel() }
        let layer = AVPlayerLayer(player: fixture.player)
        var completions = 0
        monitor.start(item: fixture.item, layer: layer, displayLayer: fixture.bridge.displayLayer,
            currentFrameReceipt: { fixture.bridge.currentFrameReceipt(for: ticket) },
            onReady: { _ in completions += 1 })
        monitor.debugTick(displayTime: 10)
        monitor.debugTick(displayTime: 10 + 1.0 / 60)
        XCTAssertEqual(completions, 0, "Sticky layer readiness plus an enqueue cannot prove incoming display")
        CMTimebaseSetTime(timebase, time: CMTime(seconds: 1.5, preferredTimescale: 48_000))
        let displayed = await until {
            guard let image = try? self.fingerprint(fixture.bridge.displayLayer.sampleBufferRenderer.displayedPixelBuffer()) else { return false }
            return image != oldImage
        }
        XCTAssertTrue(displayed)
        monitor.debugTick(displayTime: 11)
        monitor.debugTick(displayTime: 11 + 1.0 / 60)
        XCTAssertEqual(completions, 1)
    }

    private func measuredRate(_ fixture: PresentedVideo) async throws -> Double {
        let ticket = try XCTUnwrap(fixture.bridge.debugAlignedPollState.ticket)
        let position = fixture.player.currentTime().seconds
        XCTAssertTrue(fixture.bridge.installTimeline(ticket, positionSeconds: position, durationSeconds: 6, isPlaying: true))
        fixture.player.playImmediately(atRate: 1)
        XCTAssertTrue(fixture.bridge.activate(ticket))
        let first = fixture.bridge.submittedFrameCount
        var stages: [String: Int] = [:]
        fixture.bridge.onDebugWholeFrame = { event in
            if case .returned(let span) = event { stages[String(describing: span.stage), default: 0] += 1 }
        }
        let started = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(1200))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        fixture.bridge.onDebugWholeFrame = nil
        let rate = Double(fixture.bridge.submittedFrameCount - first) / elapsed
        print("VIDEO_PRESENTATION nativeSourceFPS=60 nativeGeometry=\(fixture.nativeGeometry) submittedFPS=\(rate) elapsed=\(elapsed) nativeStart=\(position) nativeEnd=\(fixture.player.currentTime().seconds) requestedEnd=\(fixture.bridge.requestedPositionSeconds) copiedEnd=\(fixture.bridge.lastCopiedFramePositionSeconds ?? -1)")
        print("VIDEO_PRESENTATION_PULLS stages=\(stages) active=\(UIApplication.shared.applicationState.rawValue) maxScreenFPS=\(fixture.window.screen.maximumFramesPerSecond)")
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
    var usedNativeGeometry: Bool { resource?.debugUsesNativeGeometry ?? false }

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

    static func make(nativeGeometry: Bool = false, resourceName: String = "test-motion-60", disableAudioTrack: Bool = false) async throws -> PresentedVideo {
        let url = try XCTUnwrap(Bundle(for: VideoPresentationContinuityTests.self)
            .url(forResource: resourceName, withExtension: "mp4"))
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
            if disableAudioTrack {
                for track in fixture.item.tracks where track.assetTrack?.mediaType == .audio { track.isEnabled = false }
            }
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

    func seek(to seconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 48_000),
                toleranceBefore: .zero, toleranceAfter: .zero) { finished in continuation.resume(returning: finished) }
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
