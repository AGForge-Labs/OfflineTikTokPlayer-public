import XCTest
import AVFoundation
import CoreVideo
import UIKit
@testable import OfflineTikTokPlayer

@MainActor
final class ContinuousPictureInPictureTests: XCTestCase {
    func testOnlyExplicitPiPCommandsReachAudioIntent() {
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        var commands: [Bool] = []
        bridge.onSetPlaying = { commands.append($0) }
        bridge.updatePlayback(positionSeconds: 1, durationSeconds: 10, isPlaying: true)
        bridge.suspendFrameFeed()
        bridge.updatePlayback(positionSeconds: 2, durationSeconds: 10, isPlaying: true)
        XCTAssertTrue(bridge.isFrameFeedSuspended)
        XCTAssertTrue(commands.isEmpty)
        bridge.resumeFrameFeed()
        XCTAssertTrue(commands.isEmpty)
        bridge.handleSetPlayingRequest(false)
        bridge.handleSetPlayingRequest(true)
        XCTAssertEqual(commands, [false, true])
        bridge.invalidate()
        bridge.handleSetPlayingRequest(true)
        XCTAssertEqual(commands, [false, true])
    }

    func testSkipAlwaysCompletesAndRejectsInvalidInterval() {
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        var completions = 0
        bridge.handleSkipRequest(15) { completions += 1 }
        XCTAssertEqual(completions, 1)
        var intervals: [Double] = []
        bridge.onSkip = { interval, done in intervals.append(interval); done(); done() }
        bridge.handleSkipRequest(.nan) { completions += 1 }
        bridge.handleSkipRequest(-15) { completions += 1 }
        XCTAssertEqual(intervals, [-15])
        XCTAssertEqual(completions, 3)
    }

    func testRestorationNeverClaimsSuccessWithoutAnActualUICompletion() {
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        var results: [Bool] = []
        bridge.handleRestoreUIRequest { results.append($0) }
        XCTAssertEqual(results, [false])
        var restoreCompletion: ((Bool) -> Void)?
        bridge.onRestoreUI = { restoreCompletion = $0 }
        bridge.handleRestoreUIRequest { results.append($0) }
        XCTAssertEqual(results, [false])
        restoreCompletion?(true)
        restoreCompletion?(false)
        XCTAssertEqual(results, [false, true])
    }

    func testPortraitAndMirrorCompositionProducesOrientedPixelsAndPreservesSourceTiming() async throws {
        let cases: [(CGAffineTransform, CGSize, Bool)] = [
            (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 16, ty: 0), CGSize(width: 16, height: 32), false),
            (CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0), CGSize(width: 32, height: 16), true)
        ]
        for (transform, expectedSize, mirrored) in cases {
            let url = try await makeAsymmetricVideo(transform: transform)
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let duration = try await asset.load(.duration)
            let composition = try await ContinuousPictureInPicture.makeVideoComposition(for: asset)
            XCTAssertEqual(composition.renderSize, expectedSize)
            XCTAssertEqual(composition.sourceTrackIDForFrameTiming, track.trackID)
            XCTAssertEqual(CMTimeCompare(try XCTUnwrap(composition.instructions.first).timeRange.duration, duration), 0)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks,
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = composition
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            defer { reader.cancelReading() }
            let first = try XCTUnwrap(output.copyNextSampleBuffer())
            let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(first))
            XCTAssertEqual(CVPixelBufferGetWidth(pixel), Int(expectedSize.width))
            XCTAssertEqual(CVPixelBufferGetHeight(pixel), Int(expectedSize.height))
            if mirrored {
                XCTAssertTrue(isBlue(pixel, x: 8, y: 8))
                XCTAssertFalse(isBlue(pixel, x: 24, y: 8))
            } else {
                // Rotation moves the original left/right split onto the vertical axis.
                XCTAssertNotEqual(isBlue(pixel, x: 8, y: 8), isBlue(pixel, x: 8, y: 24))
            }
            let second = try XCTUnwrap(output.copyNextSampleBuffer())
            XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(second)), 1.0 / 24, accuracy: 0.000_01)
        }
    }

    func testChangingItemCancelsOrientationPreparationAndCannotAttachOldOutput() async throws {
        let url = try await makeAsymmetricVideo(transform: .identity)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = AVPlayerItem(url: url)
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        bridge.setCurrentItem(item)
        bridge.setCurrentItem(nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(bridge.orientationPrepared)
        XCTAssertTrue(item.outputs.isEmpty)
        XCTAssertNil(item.videoComposition)
    }

    func testAdoptionCannotAcquireTheDepartingTimelineBeforeActivation() async throws {
        #if DEBUG
        // Two seconds of real 24fps video leaves room for distinct nonzero
        // timelines. This test observes acquisition/submission, not scanout.
        let urlA = try await makeAsymmetricVideo(transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0), frameCount: 48)
        defer { try? FileManager.default.removeItem(at: urlA) }
        let urlB = try await makeAsymmetricVideo(transform: .identity, frameCount: 48)
        defer { try? FileManager.default.removeItem(at: urlB) }
        let itemA = AVPlayerItem(url: urlA), itemB = AVPlayerItem(url: urlB)
        let player = AVPlayer(playerItem: itemB)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        let bridge = ContinuousPictureInPicture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        host.view.backgroundColor = .black
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = host.view.bounds
        host.view.layer.addSublayer(playerLayer)
        bridge.displayLayer.frame = host.view.bounds
        host.view.layer.addSublayer(bridge.displayLayer)
        var requests: [(item: AVPlayerItem, time: CMTime)] = []
        requests.reserveCapacity(1024)
        var requestOverflow = false
        var reportedTargetMask: UInt8 = 0
        bridge.onFrameAcquisition = { item, time in
            if requests.count < 1024 { requests.append((item, time)) }
            else { requestOverflow = true }
        }
        defer {
            bridge.onFrameAcquisition = nil
            bridge.invalidate()
            player.pause(); player.replaceCurrentItem(with: nil)
            playerLayer.player = nil
            bridge.displayLayer.removeFromSuperlayer(); playerLayer.removeFromSuperlayer()
            window.isHidden = true; window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        @MainActor func exerciseGenericUpdates(at position: Double, playing: Bool = false) async {
            for _ in 0..<3 {
                bridge.updatePlayback(positionSeconds: position, durationSeconds: 2, isPlaying: playing)
                bridge.suspendFrameFeed(); bridge.resumeFrameFeed()
                await Task.yield()
            }
        }
        @MainActor func assertClosed(requestCount: Int, submitted: UInt64, _ stage: String) {
            let first: (item: AVPlayerItem, time: CMTime)? = requestCount < requests.count ? requests[requestCount] : nil
            let firstTarget = first.map { $0.time.isNumeric ? $0.time.seconds : -1 } ?? -1
            let stageCode = stage.replacingOccurrences(of: " ", with: "_")
            print("PresentationAdoptionClosed stage=\(stageCode) requestDelta=\(requests.count - requestCount) firstTarget=\(firstTarget) firstIsA=\(first?.item === itemA) firstIsB=\(first?.item === itemB) copied=\(bridge.lastCopiedFramePositionSeconds ?? -1) frame=\(bridge.lastFramePositionSeconds ?? -1) submittedCount=\(bridge.submittedFrameCount) submittedBaseline=\(submitted)")
            XCTAssertEqual(requests.count, requestCount, stage + " must not reach the real output acquisition guard")
            XCTAssertEqual(bridge.submittedFrameCount, submitted, stage + " must not submit a frame")
            XCTAssertNil(bridge.lastCopiedFramePositionSeconds, stage + " must not consume an output frame")
            XCTAssertNil(bridge.lastFramePositionSeconds, stage + " must not enqueue an output frame")
            XCTAssertFalse(requestOverflow)
        }
        @MainActor func hasSubmittedTarget(_ item: AVPlayerItem, target: Double, after submitted: UInt64) -> Bool {
            bridge.updatePlayback(positionSeconds: target, durationSeconds: 2, isPlaying: false)
            guard bridge.submittedFrameCount > submitted,
                  let copied = bridge.lastCopiedFramePositionSeconds,
                  let presented = bridge.lastFramePositionSeconds else { return false }
            let valid = copied <= target + 0.000_01 && presented <= target + 0.000_01
                && abs(copied - target) <= 1.0 / 24 + 0.000_01
                && abs(presented - target) <= 1.0 / 24 + 0.000_01
                && requests.contains { $0.item === item && $0.time.isNumeric && abs($0.time.seconds - target) < 0.000_01 }
            guard valid else { return false }
            let targetBit: UInt8 = target == 0.75 ? 1 : target == 0.25 ? 2 : target == 0.5 ? 4 : target == 0.125 ? 8 : 16
            if reportedTargetMask & targetBit == 0 {
                reportedTargetMask |= targetBit
                print("PresentationAdoptionTarget target=\(target) isA=\(item === itemA) isB=\(item === itemB) copied=\(copied) frame=\(presented) submittedCount=\(bridge.submittedFrameCount) submittedBaseline=\(submitted) acquisitionCount=\(requests.count)")
            }
            return true
        }

        let ticketB = try XCTUnwrap(bridge.setCurrentItem(itemB))
        guard await waitForPresentation({ bridge.orientationPrepared && !itemB.outputs.isEmpty && itemB.status == .readyToPlay }) else {
            XCTFail("B's real video output must attach within the bounded setup window"); return
        }
        guard await seekPresentationPlayer(player, to: 0.75) else { XCTFail("B's real nonzero seek must complete"); return }
        XCTAssertTrue(bridge.installTimeline(ticketB, positionSeconds: 0.75, durationSeconds: 2, isPlaying: false))
        XCTAssertTrue(bridge.activate(ticketB))
        guard await waitForPresentation({ hasSubmittedTarget(itemB, target: 0.75, after: 0) }) else {
            XCTFail("The departing B timeline must first copy and submit an actual nonzero frame"); return
        }
        XCTAssertGreaterThan(try XCTUnwrap(bridge.lastFramePositionSeconds), 0.5)

        let requestsBeforeA = requests.count, submittedBeforeA = bridge.submittedFrameCount
        let ticketA = try XCTUnwrap(bridge.setCurrentItem(itemA))
        player.replaceCurrentItem(with: itemA)
        await exerciseGenericUpdates(at: 0.75, playing: true)
        guard await waitForPresentation({ bridge.orientationPrepared && !itemA.outputs.isEmpty && itemA.status == .readyToPlay }) else {
            XCTFail("A's asynchronous output attachment must finish while its timeline gate remains closed"); return
        }
        await exerciseGenericUpdates(at: 0.75, playing: true)
        XCTAssertTrue(itemB.outputs.isEmpty)
        assertClosed(requestCount: requestsBeforeA, submitted: submittedBeforeA, "A adoption and asynchronous attachment")
        guard await seekPresentationPlayer(player, to: 0.25) else { XCTFail("A's paused target must be decoded by a real seek"); return }
        assertClosed(requestCount: requestsBeforeA, submitted: submittedBeforeA, "A's native seek before timeline installation")
        XCTAssertTrue(bridge.installTimeline(ticketA, positionSeconds: 0.25, durationSeconds: 2, isPlaying: false))
        XCTAssertFalse(bridge.installTimeline(ticketB, positionSeconds: 0.75, durationSeconds: 2, isPlaying: true))
        XCTAssertFalse(bridge.activate(ticketB), "The departing item's ticket cannot open A's gate")
        await exerciseGenericUpdates(at: 0.25)
        assertClosed(requestCount: requestsBeforeA, submitted: submittedBeforeA, "Installing A's timeline without activation")
        XCTAssertTrue(bridge.activate(ticketA))
        guard await waitForPresentation({ hasSubmittedTarget(itemA, target: 0.25, after: submittedBeforeA) }) else {
            XCTFail("Activating A's matching ticket must submit a real paused-target frame"); return
        }

        let heldSeek = bridge.beginSeek()
        let heldRequests = requests.count, heldSubmitted = bridge.submittedFrameCount
        let blockedBefore = bridge.blockedFrameAcquisitionCount
        guard await seekPresentationPlayer(player, to: 0.5) else { XCTFail("Held A seek must actually complete in AVPlayer"); return }
        await exerciseGenericUpdates(at: 0.5)
        assertClosed(requestCount: heldRequests, submitted: heldSubmitted, "A's held seek completion")
        XCTAssertGreaterThan(bridge.blockedFrameAcquisitionCount, blockedBefore)
        XCTAssertFalse(bridge.activate(ticketA), "Activation must not bypass a held native seek completion")
        bridge.completeSeek(heldSeek &+ 1)
        await exerciseGenericUpdates(at: 0.5)
        assertClosed(requestCount: heldRequests, submitted: heldSubmitted, "An unrelated seek completion")
        XCTAssertTrue(bridge.installTimeline(ticketA, positionSeconds: 0.5, durationSeconds: 2, isPlaying: false))
        bridge.completeSeek(heldSeek)
        XCTAssertTrue(bridge.activate(ticketA))
        guard await waitForPresentation({ hasSubmittedTarget(itemA, target: 0.5, after: heldSubmitted) }) else {
            XCTFail("The matching seek completion must allow A's actual paused target"); return
        }

        let abaRequests = requests.count, abaSubmitted = bridge.submittedFrameCount
        let interveningB = try XCTUnwrap(bridge.setCurrentItem(itemB))
        let returnedA = try XCTUnwrap(bridge.setCurrentItem(itemA))
        XCTAssertFalse(bridge.installTimeline(ticketA, positionSeconds: 0.5, durationSeconds: 2, isPlaying: false))
        XCTAssertFalse(bridge.activate(ticketA), "An old A ticket must remain stale after A-B-A")
        XCTAssertFalse(bridge.activate(interveningB))
        guard await waitForPresentation({ bridge.orientationPrepared && !itemA.outputs.isEmpty }) else {
            XCTFail("Returned A must attach a real output"); return
        }
        guard await seekPresentationPlayer(player, to: 0.125) else { XCTFail("Returned A's target seek must complete"); return }
        await exerciseGenericUpdates(at: 0.125)
        assertClosed(requestCount: abaRequests, submitted: abaSubmitted, "A-B-A before the current ticket")
        XCTAssertTrue(bridge.installTimeline(returnedA, positionSeconds: 0.125, durationSeconds: 2, isPlaying: false))
        await exerciseGenericUpdates(at: 0.125)
        assertClosed(requestCount: abaRequests, submitted: abaSubmitted, "Returned A's installed, inactive ticket")
        XCTAssertTrue(bridge.activate(returnedA))
        guard await waitForPresentation({ hasSubmittedTarget(itemA, target: 0.125, after: abaSubmitted) }) else {
            XCTFail("Only returned A's current ticket may submit its actual target frame"); return
        }

        let sameItemRequests = requests.count, sameItemSubmitted = bridge.submittedFrameCount
        let adoptedAgain = try XCTUnwrap(bridge.setCurrentItem(itemA))
        XCTAssertFalse(bridge.installTimeline(returnedA, positionSeconds: 0.5, durationSeconds: 2, isPlaying: false))
        XCTAssertFalse(bridge.activate(returnedA), "Same-item re-adoption must also invalidate the previous presentation ticket")
        await exerciseGenericUpdates(at: 0.125)
        assertClosed(requestCount: sameItemRequests, submitted: sameItemSubmitted, "Same-item re-adoption before a fresh timeline")
        guard await seekPresentationPlayer(player, to: 0.375) else { XCTFail("Same-item re-adoption's distinct target must actually seek"); return }
        XCTAssertTrue(bridge.installTimeline(adoptedAgain, positionSeconds: 0.375, durationSeconds: 2, isPlaying: false))
        assertClosed(requestCount: sameItemRequests, submitted: sameItemSubmitted, "Same-item timeline installed before activation")
        XCTAssertTrue(bridge.activate(adoptedAgain))
        guard await waitForPresentation({ hasSubmittedTarget(itemA, target: 0.375, after: sameItemSubmitted) }) else {
            XCTFail("Same-item re-adoption must still submit its distinct actual target"); return
        }
        XCTAssertFalse(requestOverflow)
        #else
        throw XCTSkip("The real acquisition observer is available in DEBUG native tests")
        #endif
    }

    private func waitForPresentation(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return condition()
    }

    @MainActor
    private final class PresentationSeekCompletion { var result: Bool? }

    private func seekPresentationPlayer(_ player: AVPlayer, to seconds: Double) async -> Bool {
        let completion = PresentationSeekCompletion()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 24), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in completion.result = finished }
        }
        let returned = await waitForPresentation { completion.result != nil }
        return returned && completion.result == true
    }

    private func makeAsymmetricVideo(transform: CGAffineTransform, frameCount: Int = 2) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var completed = false
        defer {
            if !completed {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
            }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 16
        ])
        input.transform = transform
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 16,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: AVFoundationErrorDomain, code: -3) }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, kCVPixelFormatType_32BGRA,
                                           attributes as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<16 {
            for x in 0..<32 {
                let offset = y * rowBytes + x * 4
                bytes[offset] = x < 16 ? 0 : 255
                bytes[offset + 1] = 0
                bytes[offset + 2] = x < 16 ? 255 : 0
                bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for index in 0..<frameCount {
            var attempts = 0
            while !input.isReadyForMoreMediaData && attempts < 200 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 24))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: AVFoundationErrorDomain, code: -4) }
        completed = true
        return url
    }

    private func isBlue(_ pixel: CVPixelBuffer, x: Int, y: Int) -> Bool {
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { XCTFail("Missing decoded pixels"); return false }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
        return Int(bytes[offset]) > Int(bytes[offset + 2]) + 80
    }
}
