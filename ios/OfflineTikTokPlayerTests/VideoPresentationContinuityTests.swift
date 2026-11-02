import XCTest
import AVFoundation
import CoreVideo
import CoreImage
import CryptoKit
import UIKit
import IOSurface
import Dispatch
@testable import OfflineTikTokPlayer

@MainActor
final class VideoPresentationContinuityTests: XCTestCase {
    private static let runtimeHostModuleNonce = UUID().uuidString.lowercased()
    private let imageReadback = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
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
        #if targetEnvironment(simulator)
        let layer = fixture.bridge.displayLayer
        fixture.window.rootViewController?.view.backgroundColor = .black
        layer.backgroundColor = UIColor.black.cgColor
        let displayed = try XCTUnwrap(layer.sampleBufferRenderer.displayedPixelBuffer())
        let size = CGSize(width: CGFloat(CVPixelBufferGetWidth(displayed)), height: CGFloat(CVPixelBufferGetHeight(displayed)))
        let scale = min(layer.bounds.width / size.width, layer.bounds.height / size.height)
        let video = CGRect(x: layer.bounds.midX - size.width * scale / 2,
                           y: layer.bounds.midY - size.height * scale / 2,
                           width: size.width * scale, height: size.height * scale)
        let region = layer.convert(video.insetBy(dx: video.width * 0.1, dy: video.height * 0.1), to: fixture.window.layer)
        let initialBlack = try await compositorBlackFraction(window: fixture.window, region: region, label: "initial-picture")
        XCTAssertLessThan(initialBlack, 0.30, "The initial onscreen video must be visible before testing retention")
        #endif
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
        #if targetEnvironment(simulator)
        let beforeBlack = try await compositorBlackFraction(window: fixture.window, region: region, label: "before-stop")
        XCTAssertLessThan(beforeBlack, 0.30, "The positive control must show the actual coloured test video")
        let attached = layer.superlayer
        let bounds = layer.bounds, frame = layer.frame
        var removed: (Int, UInt64)?
        fixture.bridge.onDebugImageRemovalCompleted = { revision, epoch in removed = (revision, epoch) }
        defer { fixture.bridge.onDebugImageRemovalCompleted = nil }
        let stopStart = ProcessInfo.processInfo.systemUptime
        let stopDeadline = stopStart + 5
        fixture.bridge.setCurrentItem(nil)
        let owner = fixture.bridge.debugImageRemovalOwner
        let count = fixture.bridge.submittedFrameCount
        while removed == nil, ProcessInfo.processInfo.systemUptime < stopDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let removalCompleted = removed != nil && ProcessInfo.processInfo.systemUptime <= stopDeadline
        XCTAssertTrue(removalCompleted, "The SDK must acknowledge the captured image removal")
        XCTAssertEqual(removed?.0, owner.revision); XCTAssertEqual(removed?.1, owner.epoch)
        XCTAssertNil(fixture.bridge.currentFrameReceipt(for: nextTicket))
        XCTAssertNil(fixture.bridge.debugAlignedPollState.ticket)
        XCTAssertNil(fixture.bridge.debugAlignedPollState.output)
        guard removalCompleted else { throw SelectionVideoTestFailure.timeout }
        let afterBlack = try await compositorBlackFraction(window: fixture.window, region: region,
            label: "after-stop", deadline: stopDeadline)
        let witnessEnd = ProcessInfo.processInfo.systemUptime
        XCTAssertLessThanOrEqual(witnessEnd, stopDeadline, "Removal and its compositor witness share the original five-second limit")
        XCTAssertGreaterThan(afterBlack, 0.98, "Intentional stop must remove the actual onscreen picture")
        XCTAssertEqual(fixture.bridge.submittedFrameCount, count, "No post-stop frame may refill the cleared layer")
        XCTAssertTrue(layer.superlayer === attached)
        XCTAssertEqual(layer.bounds, bounds); XCTAssertEqual(layer.frame, frame)
        XCTAssertFalse(layer.isHidden); XCTAssertEqual(layer.opacity, 1)
        XCTAssertFalse(fixture.window.isHidden); XCTAssertTrue(fixture.window.isKeyWindow)
        let cachedBufferRemains = layer.sampleBufferRenderer.displayedPixelBuffer() != nil
        print("REMOVAL_COMPOSITOR elapsedSeconds=\(witnessEnd - stopStart) completed=\(removed != nil) revision=\(owner.revision) epoch=\(owner.epoch) beforeBlack=\(beforeBlack) afterBlack=\(afterBlack) cachedBufferRemains=\(cachedBufferRemains) attached=true hidden=false postStopEnqueues=\(fixture.bridge.submittedFrameCount - count)")
        #else
        throw XCTSkip("The removal witness requires the Simulator host compositor bridge")
        #endif
    }

    func testForegroundFeedDoesNotDropEveryOtherFrameOfSixtyFPSVideo() async throws {
        for trial in 0..<6 {
            let fixture = try await PresentedVideo.make()
            defer { fixture.close() }
            XCTAssertTrue(fixture.usedNativeGeometry, "The qualified production path must avoid an unnecessary compositor")
            print("VIDEO_TRIAL ordinal=\(trial) unusedNativeAudioDisabled=false")
            let rate = try await measuredRate(fixture)
            XCTAssertGreaterThan(rate, 50, "A 60 fps source must not be limited by a 30 Hz app timer")
        }
    }

    func testFullResolutionVideoKeepsItsCadenceAfterStarting() async throws {
        for trial in 0..<3 {
            let fixture = try await PresentedVideo.make(resourceName: "test-motion-1080")
            defer { fixture.close() }
            print("VIDEO_HD_TRIAL ordinal=\(trial)")
            let rate = try await measuredRate(fixture)
            XCTAssertGreaterThan(rate, 50, "1080p60 must exercise real frame throughput")
        }
    }

    func testHDNativeWaitingControlWithAudioTrack() async throws {
        let fixture = try await PresentedVideo.make(resourceName: "test-motion-1080", minimizesStalls: true)
        defer { fixture.close() }
        print("VIDEO_HD_CONTROL unusedNativeAudioDisabled=false waiting=true")
        _ = try await measuredRate(fixture, enforceCadence: false)
    }

    func testHDNativeWaitingControlWithoutAudioTrack() async throws {
        let fixture = try await PresentedVideo.make(resourceName: "test-motion-1080", disableAudioTrack: true, minimizesStalls: true)
        defer { fixture.close() }
        print("VIDEO_HD_CONTROL unusedNativeAudioDisabled=true waiting=true")
        _ = try await measuredRate(fixture, enforceCadence: false)
    }

    func testNativeGeometryControlPreservesTheSixtyFPSFixtureCadence() async throws {
        let fixture = try await PresentedVideo.make(nativeGeometry: true)
        defer { fixture.close() }
        let rate = try await measuredRate(fixture)
        XCTAssertGreaterThan(rate, 50, "The same source must remain smooth without an unnecessary composition")
    }

    func testNativeClockLeadInsideDriftToleranceStillProducesDisplayableFrames() async throws {
        let process = ProcessInfo.processInfo
        let receipt: [String: Any] = ["schema": 1,
            "simulatorUDID": process.environment["SIMULATOR_UDID"] ?? "unknown",
            "pid": Int(process.processIdentifier),
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "moduleNonce": Self.runtimeHostModuleNonce, "testName": self.name]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print("NativeRuntimeHost " + String(decoding: data, as: UTF8.self))
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

    private func measuredRate(_ fixture: PresentedVideo, audioLag: Double = 0, enforceCadence: Bool = true) async throws -> Double {
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
        let displayedPixel = fixture.bridge.displayLayer.sampleBufferRenderer.displayedPixelBuffer()
        let pixelFormat = displayedPixel.map(CVPixelBufferGetPixelFormatType)
        print("VIDEO_PRESENTATION nativeSourceFPS=60 nativeGeometry=\(fixture.usedNativeGeometry) explicitNativeControl=\(fixture.nativeGeometry) submittedFPS=\(rate) elapsed=\(elapsed) nativeStart=\(position) nativeEnd=\(nativeEnd) requestedEnd=\(requestedEnd) copiedEnd=\(copiedEnd)")
        print("VIDEO_FORMAT displayedFourCC=\(pixelFormat ?? 0) planes=\(displayedPixel.map(CVPixelBufferGetPlaneCount) ?? 0) shareableSurface=\(displayedPixel.flatMap(CVPixelBufferGetIOSurface) != nil) waiting=\(fixture.player.automaticallyWaitsToMinimizeStalling) cadenceRequired=\(enforceCadence)")
        print("VIDEO_CADENCE delivered=\(delivered) maximumGapMs=\(frameGap.milliseconds) stageCounts=\(stages)")
        print("VIDEO_STALL windowNs=[\(startNs),\(endNs)] frameGapNs=[\(frameGap.start),\(frameGap.end)] tickGapMs=\(tickGap.milliseconds) tickNs=[\(tickGap.start),\(tickGap.end)] outsideMs=\(outsideGap.milliseconds) outsideNs=[\(outsideGap.start),\(outsideGap.end)] backgroundTicks=\(background.ticks) backgroundMs=\(background.maximum.milliseconds) backgroundNs=[\(background.maximum.start),\(background.maximum.end)] observerMs=\(observer.milliseconds) sdkMs=\(sdk.map(\.milliseconds)) sdkStartsNs=\(sdk.map(\.start)) sdkEndsNs=\(sdk.map(\.end))")
        XCTAssertEqual(fixture.player.currentItem, fixture.item)
        XCTAssertEqual(depth, 0, "The measured render intervals must be complete at the window boundary")
        XCTAssertFalse(background.overflow, "The independent scheduling window must remain fully measured")
        if enforceCadence {
            XCTAssertLessThan(frameGap.milliseconds, 100, "A short average-FPS check must not hide a visible video hitch")
        }
        return rate
    }

    #if targetEnvironment(simulator)
    private func compositorBlackFraction(window: UIWindow, region: CGRect, label: String,
                                         deadline: Double? = nil) async throws -> Double {
        guard window.bounds.width > 0, window.bounds.height > 0,
              region.width > 0, region.height > 0 else { throw SelectionVideoTestFailure.capture }
        window.rootViewController?.view.layoutIfNeeded()
        CATransaction.flush()
        let image = try await HostCompositorCapture.image(in: window, deadline: deadline)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Retained-video-" + label; attachment.lifetime = .keepAlways
        add(attachment)
        let cg = try XCTUnwrap(image.cgImage)
        let sx = CGFloat(cg.width) / window.bounds.width, sy = CGFloat(cg.height) / window.bounds.height
        let pixels = CGRect(x: region.minX * sx, y: region.minY * sy,
                            width: region.width * sx, height: region.height * sy).integral
        guard CGRect(x: 0, y: 0, width: cg.width, height: cg.height).contains(pixels) else {
            throw SelectionVideoTestFailure.capture
        }
        let crop = try XCTUnwrap(cg.cropping(to: pixels))
        var bytes = [UInt8](repeating: 0, count: 64 * 96 * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: 64, height: 96,
                bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 64, height: 96))
            return true
        }
        guard drawn else { throw SelectionVideoTestFailure.capture }
        var black = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[i] < 20 && bytes[i + 1] < 20 && bytes[i + 2] < 20 { black += 1 }
        }
        return Double(black) / (64 * 96)
    }
    #endif

    private func fingerprint(_ value: CVPixelBuffer?) throws -> String {
        let pixel = try XCTUnwrap(value, "An actual displayed pixel buffer is required")
        // Hash visible samples in a canonical format, never plane/row padding.
        // Only tiny synthetic images use this CPU readback, outside cadence measurement.
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        guard width > 0, height > 0, width <= 4096, height <= 4096 else {
            XCTFail("The synthetic image readback must remain bounded")
            throw NSError(domain: "SyntheticImageReadback", code: 1)
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        imageReadback.render(CIImage(cvPixelBuffer: pixel), toBitmap: &bytes, rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
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

    static func make(nativeGeometry: Bool = false, resourceName: String = "test-motion-60", disableAudioTrack: Bool = false,
                     minimizesStalls: Bool = false) async throws -> PresentedVideo {
        let url = try XCTUnwrap(Bundle(for: VideoPresentationContinuityTests.self)
            .url(forResource: resourceName, withExtension: "mp4"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = PresentedVideo(url: url, scene: scene)
        // Match PlaybackBuffer's external-clock/local-file policy. The default
        // AVPlayer waiting policy remains an explicitly labelled control arm.
        fixture.player.automaticallyWaitsToMinimizeStalling = minimizesStalls
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
            while fixture.bridge.currentFrameReceipt(for: ticket)?.matchesDisplayedImage(in: fixture.bridge.displayLayer) != true {
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
