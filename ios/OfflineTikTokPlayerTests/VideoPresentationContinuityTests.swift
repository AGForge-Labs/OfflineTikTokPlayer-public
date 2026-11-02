import XCTest
import AVFoundation
import CoreVideo
import CryptoKit
import UIKit
import IOSurface
import Dispatch
@testable import OfflineTikTokPlayer

@MainActor
final class VideoPresentationContinuityTests: XCTestCase {
    func testRendererPixelIdentityAndMetadataAfterActualIncomingDisplay() async throws {
        let fixture = try await PresentedVideo.make()
        defer { fixture.close() }
        let ticket = try XCTUnwrap(fixture.bridge.debugAlignedPollState.ticket)
        let old = try fingerprint(fixture.bridge.displayLayer.sampleBufferRenderer.displayedPixelBuffer())
        let seek = fixture.bridge.beginSeek()
        let sought = await fixture.seek(to: 1.5)
        XCTAssertTrue(sought)
        fixture.bridge.completeSeek(seek)
        var acquired: CVPixelBuffer?
        fixture.bridge.onDebugCopiedPixel = { pixel, _ in acquired = pixel }
        XCTAssertTrue(fixture.bridge.installTimeline(ticket, positionSeconds: 1.5, durationSeconds: 6, isPlaying: false))
        XCTAssertTrue(fixture.bridge.activate(ticket))
        let changed = await until {
            fixture.bridge.updatePlayback(positionSeconds: 1.5, durationSeconds: 6, isPlaying: false)
            guard let actual = try? self.fingerprint(fixture.bridge.displayLayer.sampleBufferRenderer.displayedPixelBuffer()) else { return false }
            return acquired != nil && actual != old
        }
        fixture.bridge.onDebugCopiedPixel = nil
        XCTAssertTrue(changed)
        let source = try XCTUnwrap(acquired)
        let displayed = try XCTUnwrap(fixture.bridge.displayLayer.sampleBufferRenderer.displayedPixelBuffer())
        let sourceSurface = CVPixelBufferGetIOSurface(source).map { IOSurfaceGetID($0.takeUnretainedValue()) }
        let displayedSurface = CVPixelBufferGetIOSurface(displayed).map { IOSurfaceGetID($0.takeUnretainedValue()) }
        let sourceHash = try fingerprint(source), displayedHash = try fingerprint(displayed)
        let key = "dev.galaxybigbird.OfflineTikTokPlayer.displayEpoch" as CFString
        print("RENDERER_IDENTITY sameBuffer=\(source === displayed) sourceSurface=\(sourceSurface ?? 0) displayedSurface=\(displayedSurface ?? 0) samePixels=\(sourceHash == displayedHash) sourceFormat=\(CVPixelBufferGetPixelFormatType(source)) displayedFormat=\(CVPixelBufferGetPixelFormatType(displayed)) sourceRow=\(CVPixelBufferGetBytesPerRow(source)) displayedRow=\(CVPixelBufferGetBytesPerRow(displayed)) sourceHasEpoch=\(CVBufferCopyAttachment(source, key, nil) != nil) displayedHasEpoch=\(CVBufferCopyAttachment(displayed, key, nil) != nil)")
        XCTAssertEqual(sourceHash, displayedHash, "Actual renderer/source bytes must be independently checked")
    }

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
        for trial in 0..<6 {
            let disabled = trial >= 3
            let fixture = try await PresentedVideo.make(disableAudioTrack: disabled)
            defer { fixture.close() }
            XCTAssertTrue(fixture.usedNativeGeometry, "The qualified production path must avoid an unnecessary compositor")
            print("VIDEO_TRIAL ordinal=\(trial) unusedNativeAudioDisabled=\(disabled)")
            let rate = try await measuredRate(fixture)
            XCTAssertGreaterThan(rate, 50, "A 60 fps source must not be limited by a 30 Hz app timer")
        }
    }

    func testFullResolutionVideoKeepsItsCadenceAfterStarting() async throws {
        for trial in 0..<3 {
            let fixture = try await PresentedVideo.make(resourceName: "test-motion-1080", disableAudioTrack: true)
            defer { fixture.close() }
            print("VIDEO_HD_TRIAL ordinal=\(trial)")
            let rate = try await measuredRate(fixture)
            XCTAssertGreaterThan(rate, 50, "1080p60 must exercise real frame throughput")
        }
    }

    func testNativeGeometryControlPreservesTheSixtyFPSFixtureCadence() async throws {
        let fixture = try await PresentedVideo.make(nativeGeometry: true)
        defer { fixture.close() }
        let rate = try await measuredRate(fixture)
        XCTAssertGreaterThan(rate, 50, "The same source must remain smooth without an unnecessary composition")
    }

    func testNativeClockLeadInsideDriftToleranceStillProducesDisplayableFrames() async throws {
        let fixture = try await PresentedVideo.make()
        defer { fixture.close() }
        let rate = try await measuredRate(fixture, audioLag: 0.055)
        XCTAssertGreaterThan(fixture.clockAlignments, 0, "An unrenderable clock must request owner-qualified alignment")
        XCTAssertGreaterThan(rate, 50, "An accepted native clock lead must not consume and discard every frame")
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
        // Do not retain outgoing/incoming buffers: that changes decoder-pool lifetimes.
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

    private func measuredRate(_ fixture: PresentedVideo, audioLag: Double = 0) async throws -> Double {
        let ticket = try XCTUnwrap(fixture.bridge.debugAlignedPollState.ticket)
        let position = fixture.player.currentTime().seconds - audioLag
        XCTAssertTrue(fixture.bridge.installTimeline(ticket, positionSeconds: position, durationSeconds: 6, isPlaying: true))
        fixture.player.playImmediately(atRate: 1)
        XCTAssertTrue(fixture.bridge.activate(ticket))
        let first = fixture.bridge.submittedFrameCount
        let startNs = DispatchTime.now().uptimeNanoseconds
        var stages = [Int](repeating: 0, count: ContinuousPictureInPicture.DebugWholeFrameStage.enqueued.rawValue + 1)
        var sdk = [CadenceSpan](repeating: CadenceSpan(), count: 8)
        var previousFrame = startNs, previousTick = startNs, previousReturn = startNs, depth = 0
        var frameGap = CadenceSpan(), tickGap = CadenceSpan(), outsideGap = CadenceSpan(), observer = CadenceSpan()
        var delivered = 0
        let heartbeat = CadenceHeartbeat(start: startNs)
        fixture.bridge.onDebugNativePullStamp = { stamp in
            sdk[5 + stamp.stage.rawValue].record(start: stamp.entryNs, end: stamp.returnNs)
            if stamp.stage == .enqueue {
                frameGap.record(start: previousFrame, end: stamp.returnNs)
                previousFrame = stamp.returnNs; delivered += 1
            }
        }
        fixture.bridge.onDebugWholeFrame = { event in
            let callbackStart = DispatchTime.now().uptimeNanoseconds
            switch event {
            case .entered(let entry):
                tickGap.record(start: previousTick, end: entry.entryNs)
                if depth == 0 { outsideGap.record(start: previousReturn, end: entry.entryNs) }
                previousTick = entry.entryNs; depth += 1
            case .returned(let span):
                stages[span.stage.rawValue] += 1
                let entry = span.entry.entryNs
                sdk[0].record(start: entry, end: span.returnNs)
                if let v = span.layerStatus { sdk[1].record(start: v.entryNs, end: v.returnNs) }
                if let v = span.backpressure { sdk[2].record(start: v.entryNs, end: v.returnNs) }
                if let v = span.timebase { sdk[3].record(start: v.entryNs, end: v.returnNs) }
                if let v = span.readinessCommit { sdk[4].record(start: v.entryNs, end: v.returnNs) }
                depth = max(0, depth - 1)
                if depth == 0 { previousReturn = span.returnNs }
            }
            observer.record(start: callbackStart, end: DispatchTime.now().uptimeNanoseconds)
        }
        let started = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(1200))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let endNs = DispatchTime.now().uptimeNanoseconds
        frameGap.record(start: previousFrame, end: endNs)
        tickGap.record(start: previousTick, end: endNs)
        if depth == 0 { outsideGap.record(start: previousReturn, end: endNs) }
        fixture.bridge.onDebugWholeFrame = nil
        fixture.bridge.onDebugNativePullStamp = nil
        let background = heartbeat.stop(end: endNs)
        let rate = Double(fixture.bridge.submittedFrameCount - first) / elapsed
        let nativeEnd = fixture.player.currentTime().seconds
        let requestedEnd = fixture.bridge.requestedPositionSeconds
        let copiedEnd = fixture.bridge.lastCopiedFramePositionSeconds ?? -1
        fixture.player.pause()
        fixture.bridge.updatePlayback(positionSeconds: nativeEnd, durationSeconds: 6, isPlaying: false)
        // All formatting occurs after measurement; callback work is fixed scalar counters.
        print("VIDEO_PRESENTATION nativeSourceFPS=60 nativeGeometry=\(fixture.nativeGeometry) submittedFPS=\(rate) elapsed=\(elapsed) nativeStart=\(position) nativeEnd=\(nativeEnd) requestedEnd=\(requestedEnd) copiedEnd=\(copiedEnd)")
        print("VIDEO_CADENCE delivered=\(delivered) maximumGapMs=\(frameGap.milliseconds) stageCounts=\(stages)")
        print("VIDEO_STALL windowNs=[\(startNs),\(endNs)] frameGapNs=[\(frameGap.start),\(frameGap.end)] tickGapMs=\(tickGap.milliseconds) tickNs=[\(tickGap.start),\(tickGap.end)] outsideMs=\(outsideGap.milliseconds) outsideNs=[\(outsideGap.start),\(outsideGap.end)] backgroundTicks=\(background.ticks) backgroundMs=\(background.maximum.milliseconds) backgroundNs=[\(background.maximum.start),\(background.maximum.end)] observerMs=\(observer.milliseconds) sdkMs=\(sdk.map(\.milliseconds)) sdkStartsNs=\(sdk.map(\.start)) sdkEndsNs=\(sdk.map(\.end))")
        XCTAssertEqual(fixture.player.currentItem, fixture.item)
        XCTAssertEqual(depth, 0, "The measured render intervals must be complete at the window boundary")
        XCTAssertFalse(background.overflow, "The independent scheduling window must remain fully measured")
        XCTAssertLessThan(frameGap.milliseconds, 100, "A short average-FPS check must not hide a visible video hitch")
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

private struct CadenceSpan: Sendable {
    var start: UInt64 = 0, end: UInt64 = 0
    var milliseconds: Double { Double(end - start) / 1_000_000 }
    mutating func record(start: UInt64, end: UInt64) {
        guard end >= start, end - start > self.end - self.start else { return }
        self.start = start; self.end = end
    }
}

/// Independent scheduling probe; no UIKit, frame buffers, or main-actor work.
private final class CadenceHeartbeat: @unchecked Sendable {
    private let queue = DispatchQueue(label: "synthetic.video-cadence", qos: .userInitiated)
    private let timer: DispatchSourceTimer
    private let start: UInt64
    private var stamps = [UInt64](repeating: 0, count: 1024), count = 0
    private var overflow = false
    init(start: UInt64) {
        self.start = start
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.count < self.stamps.count {
                self.stamps[self.count] = DispatchTime.now().uptimeNanoseconds; self.count += 1
            } else { self.overflow = true }
        }
        timer.resume()
    }
    func stop(end: UInt64) -> (ticks: Int, maximum: CadenceSpan, overflow: Bool) {
        timer.cancel()
        return queue.sync {
            var previous = start, maximum = CadenceSpan(), ticks = 0
            for index in 0..<count where stamps[index] <= end {
                maximum.record(start: previous, end: stamps[index]); previous = stamps[index]; ticks += 1
            }
            maximum.record(start: previous, end: end)
            return (ticks, maximum, overflow)
        }
    }
    deinit { timer.cancel() }
}

@MainActor
private final class PresentedVideo {
    let bridge = ContinuousPictureInPicture()
    let url: URL
    let item: AVPlayerItem
    let player: AVPlayer
    let window: UIWindow
    private(set) var nativeGeometry = false
    private(set) var clockAlignments = 0
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
        fixture.bridge.onClockAlignmentRequired = { [weak fixture] ticket in
            guard let fixture else { return }
            fixture.clockAlignments += 1
            let position = fixture.player.currentTime().seconds
            if fixture.bridge.installTimeline(ticket, positionSeconds: position, durationSeconds: 6, isPlaying: true) {
                _ = fixture.bridge.activate(ticket)
            }
        }
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
