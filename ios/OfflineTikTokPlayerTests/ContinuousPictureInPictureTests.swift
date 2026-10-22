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

    func testAbandonTimelineRequiresMatchingOwnerAndPreservesReentrantPresentation() async throws {
        #if DEBUG
        typealias Resource = ContinuousPictureInPicture.PreparedVideoResource
        typealias Ticket = ContinuousPictureInPicture.PresentationTicket
        let urlA = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-a", withExtension: "mp4"))
        let urlB = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-b", withExtension: "mp4"))
        let itemA = AVPlayerItem(url: urlA), itemB = AVPlayerItem(url: urlB)
        let bridge = ContinuousPictureInPicture()
        var ownedA: Resource?, ownedB: Resource?
        // Register before preparing/installing or unwrapping either real resource.
        defer {
            bridge.onCurrentFrameInvalidated = nil
            bridge.invalidate()
            ownedA?.retire(); ownedB?.retire()
            XCTAssertTrue(itemA.outputs.isEmpty); XCTAssertTrue(itemB.outputs.isEmpty)
        }
        let planA = try await ContinuousPictureInPicture.prepareVideoResource(for: itemA)
        ownedA = planA.install()
        let resourceA = try XCTUnwrap(ownedA), outputA = try XCTUnwrap(resourceA.output)
        let planB = try await ContinuousPictureInPicture.prepareVideoResource(for: itemB)
        ownedB = planB.install()
        let resourceB = try XCTUnwrap(ownedB), outputB = try XCTUnwrap(resourceB.output)
        @MainActor func assertResources(selected: AVPlayerItem, feedSuspended: Bool = false) {
            XCTAssertTrue(resourceA.item === itemA); XCTAssertTrue(resourceB.item === itemB)
            XCTAssertTrue(resourceA.output === outputA); XCTAssertTrue(resourceB.output === outputB)
            XCTAssertEqual(itemA.outputs.count, 1); XCTAssertEqual(itemB.outputs.count, 1)
            XCTAssertTrue(itemA.outputs.first === outputA); XCTAssertTrue(itemB.outputs.first === outputB)
            XCTAssertLessThanOrEqual(itemA.outputs.count + itemB.outputs.count, 3)
            XCTAssertTrue(resourceA.isAttached); XCTAssertTrue(resourceB.isAttached)
            XCTAssertFalse(resourceA.isRetired); XCTAssertFalse(resourceB.isRetired)
            XCTAssertEqual(resourceA.isBorrowed, selected === itemA)
            XCTAssertEqual(resourceB.isBorrowed, selected === itemB)
            XCTAssertEqual(bridge.isFrameFeedSuspended, feedSuspended, "Abandonment must preserve the existing feed policy")
        }
        @MainActor func install(_ ticket: Ticket) {
            XCTAssertTrue(bridge.installTimeline(ticket, positionSeconds: 0.5, durationSeconds: 30, isPlaying: false))
        }
        @MainActor func assertEligible(_ ticket: Ticket, output: AVPlayerItemVideoOutput) {
            XCTAssertTrue(bridge.activate(ticket))
            let state = bridge.debugAlignedPollState
            XCTAssertEqual(state.ticket, ticket); XCTAssertEqual(state.output, ObjectIdentifier(output))
            XCTAssertNil(state.activeSeekTicket); XCTAssertTrue(state.coherent)
        }
        // Coherent/activate below describe app-owned timeline eligibility only.
        // No AVPlayer/window, fabricated receipt, frame or audibility proof is used.
        let original = try XCTUnwrap(bridge.setCurrentItem(itemA, preparedVideo: resourceA))
        install(original); assertEligible(original, output: outputA); assertResources(selected: itemA)
        let oldSeek = bridge.beginSeek(), newerSeek = bridge.beginSeek()
        install(original)
        let active = bridge.debugAlignedPollState
        bridge.abandonTimeline(original, for: itemA, afterSeek: oldSeek)
        XCTAssertEqual(bridge.debugNativeSeekState.activeTicket, newerSeek)
        XCTAssertEqual(bridge.debugAlignedPollState.imageEpoch, active.imageEpoch)
        XCTAssertFalse(bridge.activate(original), "The newer seek barrier must remain active")
        bridge.completeSeek(newerSeek)
        assertEligible(original, output: outputA)
        let completed = bridge.debugAlignedPollState
        bridge.abandonTimeline(original, for: itemA, afterSeek: oldSeek)
        XCTAssertEqual(bridge.debugNativeSeekState.serial, newerSeek)
        XCTAssertNil(bridge.debugNativeSeekState.activeTicket)
        XCTAssertEqual(bridge.debugAlignedPollState.imageEpoch, completed.imageEpoch)
        assertEligible(original, output: outputA)
        bridge.abandonTimeline(original, for: itemB, afterSeek: newerSeek)
        XCTAssertEqual(bridge.debugAlignedPollState.imageEpoch, completed.imageEpoch)
        assertEligible(original, output: outputA); assertResources(selected: itemA)

        // Same-item re-adoption isolates the presentation revision from item identity.
        let current = try XCTUnwrap(bridge.setCurrentItem(itemA, preparedVideo: resourceA))
        XCTAssertNotEqual(current, original)
        install(current); assertEligible(current, output: outputA)
        let readopted = bridge.debugAlignedPollState
        bridge.abandonTimeline(original, for: itemA, afterSeek: newerSeek)
        XCTAssertEqual(bridge.debugAlignedPollState.imageEpoch, readopted.imageEpoch)
        assertEligible(current, output: outputA); assertResources(selected: itemA)

        // Both legal matching states (issued and already completed) must close.
        for completeFirst in [false, true] {
            let seek = bridge.beginSeek()
            install(current)
            if completeFirst { bridge.completeSeek(seek); assertEligible(current, output: outputA) }
            if completeFirst { bridge.suspendFrameFeed() }
            let before = bridge.debugAlignedPollState
            bridge.abandonTimeline(current, for: itemA, afterSeek: seek)
            XCTAssertEqual(bridge.debugNativeSeekState.serial, seek)
            XCTAssertEqual(bridge.debugNativeSeekState.activeTicket, completeFirst ? nil : seek)
            XCTAssertGreaterThan(bridge.debugAlignedPollState.imageEpoch, before.imageEpoch)
            XCTAssertFalse(bridge.activate(current), "Exact abandonment must remove timeline eligibility")
            bridge.completeSeek(seek)
            XCTAssertNil(bridge.debugNativeSeekState.activeTicket)
            XCTAssertFalse(bridge.activate(current), "The original completion cannot reopen an abandoned timeline")
            XCTAssertFalse(bridge.debugAlignedPollState.coherent)
            assertResources(selected: itemA, feedSuspended: completeFirst)
            if completeFirst { bridge.resumeFrameFeed() }
        }

        // One synchronous invalidation callback replaces A with the real prepared B.
        let reentrantSeek = bridge.beginSeek()
        install(current)
        var callbacks = 0, callbackOverflow = false
        var replacement: Ticket?, replacementState: ContinuousPictureInPicture.DebugAlignedPollState?
        bridge.onCurrentFrameInvalidated = { [weak bridge] in
            guard let bridge else { return }
            guard callbacks == 0 else { callbackOverflow = true; return }
            callbacks = 1
            bridge.onCurrentFrameInvalidated = nil
            replacement = bridge.setCurrentItem(itemB, preparedVideo: resourceB)
            if let replacement {
                XCTAssertTrue(bridge.installTimeline(replacement, positionSeconds: 0.5, durationSeconds: 30, isPlaying: false))
                XCTAssertTrue(bridge.activate(replacement))
                replacementState = bridge.debugAlignedPollState
            }
        }
        bridge.abandonTimeline(current, for: itemA, afterSeek: reentrantSeek)
        bridge.onCurrentFrameInvalidated = nil
        let replacementTicket = try XCTUnwrap(replacement), established = try XCTUnwrap(replacementState)
        XCTAssertEqual(callbacks, 1); XCTAssertFalse(callbackOverflow)
        XCTAssertTrue(established.coherent)
        bridge.completeSeek(reentrantSeek)
        XCTAssertEqual(bridge.debugAlignedPollState.imageEpoch, established.imageEpoch)
        assertEligible(replacementTicket, output: outputB); assertResources(selected: itemB)
        XCTAssertFalse(bridge.activate(current), "The replaced A presentation cannot reopen")
        #else
        XCTFail("The abandonment ownership contract requires DEBUG cached-state observations")
        #endif
    }

    func testSameItemSeekAfterSuccessfulCopyCannotEnqueueOrCreditTheOldFrame() async throws {
        #if DEBUG
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-a", withExtension: "mp4"))
        let item = AVPlayerItem(url: url)
        let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
        let resource = try XCTUnwrap(plan.install())
        let bridge = ContinuousPictureInPicture()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true; player.automaticallyWaitsToMinimizeStalling = false
        var ownedWindow: UIWindow?, ownedPlayerLayer: AVPlayerLayer?
        weak var previousKeyWindow: UIWindow?
        var heldSeek: UInt64?
        // Cleanup is registered before any optional scene/window/ticket unwrap.
        // The fixture is bundled public synthetic media, so no file is deleted.
        defer {
            bridge.onDebugRenderStamp = nil
            if let heldSeek { bridge.completeSeek(heldSeek) }
            bridge.invalidate()
            item.cancelPendingSeeks(); player.pause(); player.replaceCurrentItem(with: nil)
            resource.retire(); ownedPlayerLayer?.player = nil
            bridge.displayLayer.removeFromSuperlayer(); ownedPlayerLayer?.removeFromSuperlayer()
            ownedWindow?.isHidden = true; ownedWindow?.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        let ticket = try XCTUnwrap(bridge.setCurrentItem(item, preparedVideo: resource))
        let output = try XCTUnwrap(resource.output)
        let outputID = ObjectIdentifier(output), itemID = ObjectIdentifier(item)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        ownedWindow = window
        window.frame = scene.coordinateSpace.bounds; window.windowLevel = .alert + 1
        window.rootViewController = host; host.view.backgroundColor = .black
        window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        let playerLayer = AVPlayerLayer(player: player)
        ownedPlayerLayer = playerLayer
        playerLayer.frame = host.view.bounds; host.view.layer.addSublayer(playerLayer)
        bridge.displayLayer.frame = host.view.bounds; host.view.layer.addSublayer(bridge.displayLayer)
        XCTAssertEqual(item.outputs.count, 1)
        XCTAssertTrue(resource.isBorrowed); XCTAssertTrue(resource.isAttached); XCTAssertFalse(resource.isRetired)

        // Establish actual native readiness and an actually enqueued/display-ready
        // paused CPP image before arming the intervention. No test-side hasNew or
        // copy call is used; all output pulls remain inside the real bridge.
        player.playImmediately(atRate: 1)
        let nativeReady = await waitForPresentation {
            item.status == .readyToPlay && playerLayer.isReadyForDisplay
        }
        player.pause()
        XCTAssertTrue(nativeReady)
        guard nativeReady, await seekPresentationPlayer(player, to: 0.25) else {
            XCTFail("The public fixture must complete a real paused baseline seek"); return
        }
        XCTAssertTrue(bridge.installTimeline(ticket, positionSeconds: 0.25, durationSeconds: 30, isPlaying: false))
        XCTAssertTrue(bridge.activate(ticket))
        let baselineReady = await waitForPresentation {
            bridge.updatePlayback(positionSeconds: 0.25, durationSeconds: 30, isPlaying: false)
            guard let copied = bridge.lastCopiedFramePositionSeconds,
                  let submitted = bridge.lastFramePositionSeconds else { return false }
            return bridge.debugCurrentFrameEpoch(for: ticket) != nil && bridge.displayLayer.isReadyForDisplay
                && copied <= 0.25 + 0.000_01 && submitted <= 0.25 + 0.000_01
                && abs(copied - 0.25) <= 1.0 / 24 + 0.000_01
                && abs(submitted - 0.25) <= 1.0 / 24 + 0.000_01
        }
        XCTAssertTrue(baselineReady)
        guard baselineReady else { XCTFail("An actual displayed paused CPP baseline is required"); return }
        let baselineEpoch = try XCTUnwrap(bridge.debugCurrentFrameEpoch(for: ticket))
        let baselineSubmitted = bridge.submittedFrameCount
        XCTAssertGreaterThan(baselineSubmitted, 0)

        // Prepare a distinct real copy while CPP is inactive. Installing the
        // timeline flushes the baseline image; activation below is the only pull.
        bridge.flushForSeek()
        guard await seekPresentationPlayer(player, to: 0.5) else {
            XCTFail("The distinct pre-intervention native seek must finish"); return
        }
        XCTAssertTrue(bridge.installTimeline(ticket, positionSeconds: 0.5, durationSeconds: 30, isPlaying: false))
        XCTAssertNil(bridge.debugCurrentFrameEpoch(for: ticket))
        let beforeActivation = bridge.debugAlignedPollState
        let originalSeek = bridge.debugNativeSeekState
        XCTAssertEqual(beforeActivation.ticket, ticket); XCTAssertEqual(beforeActivation.output, outputID)
        XCTAssertGreaterThan(beforeActivation.imageEpoch, baselineEpoch)
        XCTAssertNil(originalSeek.activeTicket)
        XCTAssertEqual(bridge.submittedFrameCount, baselineSubmitted)

        var copiedCallbacks = 0, callbackOverflow = false
        var copiedObserved = false, copiedQualified = false
        var copiedStamp: ContinuousPictureInPicture.DebugRenderStamp?
        var copyState: ContinuousPictureInPicture.DebugAlignedPollState?
        var heldState: ContinuousPictureInPicture.DebugAlignedPollState?
        var creditClearedAtBegin = false, nativeSeekIssued = false
        var enqueuedWhileHeld = 0
        let nativeCompletion = PresentationSeekCompletion()
        bridge.onDebugRenderStamp = { [weak bridge, weak player] stamp in
            guard let bridge, let player else { return }
            if stamp.stage == .enqueued {
                if let heldSeek, bridge.debugNativeSeekState.activeTicket == heldSeek {
                    if enqueuedWhileHeld == 0 { enqueuedWhileHeld = 1 }
                    else { callbackOverflow = true }
                }
                return
            }
            guard stamp.stage == .copied else { return }
            guard copiedCallbacks == 0 else { callbackOverflow = true; return }
            copiedCallbacks = 1; copiedObserved = true; copiedStamp = stamp
            let state = bridge.debugAlignedPollState
            copyState = state
            guard let requested = stamp.requestedSeconds, let sample = stamp.sampleSeconds,
                  let copied = stamp.copiedPTS else { return }
            copiedQualified = stamp.ticket == ticket && stamp.ownershipUnchanged && stamp.region == 0
                && stamp.nativeSeekTicket == nil && stamp.resourceOwnership == 2
                && state.ticket == ticket && ticket.debugItemIdentity == itemID && state.output == outputID
                && state.coherent && state.activeSeekTicket == nil && state.seekSerial == originalSeek.serial
                && state.imageEpoch == beforeActivation.imageEpoch
                && resource.item === item && resource.output === output
                && resource.isAttached && resource.isBorrowed && !resource.isRetired
                && requested.isFinite && abs(requested - 0.5) < 0.000_01
                && sample.isFinite && copied.isFinite && abs(copied - sample) < 0.000_01
                && sample <= requested + 0.000_01 && abs(sample - requested) <= 1.0 / 24 + 0.000_01
                && stamp.submittedPTS == nil && stamp.submittedCount == baselineSubmitted
                && bridge.submittedFrameCount == baselineSubmitted
            guard copiedQualified else { return }
            // This event follows a successful real copy and precedes enqueue.
            // It is NOT reentry inside the SDK copy call. Only cached app fields
            // above/below are read; this is the one intentional native seek command.
            let seek = bridge.beginSeek()
            heldSeek = seek
            heldState = bridge.debugAlignedPollState
            creditClearedAtBegin = bridge.debugCurrentFrameEpoch(for: ticket) == nil
            nativeSeekIssued = true
            player.seek(to: CMTime(seconds: 0.75, preferredTimescale: 24),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak nativeCompletion] finished in
                Task { @MainActor [weak nativeCompletion] in nativeCompletion?.result = finished }
            }
            // Deliberately withhold CPP completeSeek even when native completes.
        }
        XCTAssertTrue(bridge.activate(ticket))
        let intercepted = await waitForPresentation {
            if copiedObserved { return true } // Never start a second pull after interception.
            bridge.updatePlayback(positionSeconds: 0.5, durationSeconds: 30, isPlaying: false)
            return copiedObserved
        }
        let after = bridge.debugAlignedPollState
        let currentCredit = bridge.debugCurrentFrameEpoch(for: ticket)
        let afterSubmitted = bridge.submittedFrameCount, afterFrame = bridge.lastFramePositionSeconds
        let requestedLabel = copiedStamp.flatMap { $0.requestedSeconds }.map { String($0) } ?? "unavailable"
        let copiedLabel = copiedStamp.flatMap { $0.sampleSeconds }.map { String($0) } ?? "unavailable"
        print("CPPAfterCopySeekBoundary schema=1 copiedObserved=\(copiedObserved) copiedQualified=\(copiedQualified) copiedCallbacks=\(copiedCallbacks) callbackOverflow=\(callbackOverflow) ticketMatches=\(copyState?.ticket == ticket && heldState?.ticket == ticket && after.ticket == ticket) outputMatches=\(copyState?.output == outputID && heldState?.output == outputID && after.output == outputID) entryEpoch=\(copyState.map { String($0.imageEpoch) } ?? "unavailable") heldEpoch=\(heldState.map { String($0.imageEpoch) } ?? "unavailable") afterEpoch=\(after.imageEpoch) heldSeek=\(heldSeek.map { String($0) } ?? "unavailable") heldActive=\(heldState?.activeSeekTicket == heldSeek && heldSeek != nil) afterActive=\(after.activeSeekTicket == heldSeek && heldSeek != nil) creditClearedAtBegin=\(creditClearedAtBegin) currentCreditPresent=\(currentCredit != nil) nativeSeekIssued=\(nativeSeekIssued) enqueuedWhileHeld=\(enqueuedWhileHeld) submittedBefore=\(baselineSubmitted) submittedAfter=\(afterSubmitted) submittedPTSPresent=\(afterFrame != nil) requested=\(requestedLabel) copied=\(copiedLabel) testDirectOutputQueries=0 testDirectCopies=0 scope=after-real-copy-before-enqueue latencyAcceptance=false physicalPixels=unmeasured")
        XCTAssertTrue(intercepted); XCTAssertTrue(copiedObserved); XCTAssertTrue(copiedQualified)
        XCTAssertEqual(copiedCallbacks, 1); XCTAssertFalse(callbackOverflow)
        guard intercepted, copiedQualified, let heldSeek, let copiedState = copyState,
              let heldState = heldState else {
            XCTFail("The first actual copied event must qualify the exact original owner"); return
        }
        XCTAssertEqual(copiedState.ticket, ticket); XCTAssertEqual(copiedState.output, outputID)
        XCTAssertTrue(copiedState.coherent); XCTAssertNil(copiedState.activeSeekTicket)
        XCTAssertEqual(heldState.ticket, ticket); XCTAssertEqual(heldState.output, outputID)
        XCTAssertEqual(heldState.activeSeekTicket, heldSeek); XCTAssertEqual(heldState.seekSerial, heldSeek)
        XCTAssertGreaterThan(heldState.imageEpoch, copiedState.imageEpoch)
        XCTAssertEqual(after.ticket, ticket); XCTAssertEqual(after.output, outputID)
        XCTAssertEqual(after.activeSeekTicket, heldSeek); XCTAssertEqual(after.seekSerial, heldSeek)
        XCTAssertTrue(nativeSeekIssued); XCTAssertTrue(creditClearedAtBegin)
        // RED: the copy belongs to the pre-seek epoch. A matching item/ticket
        // alone must not let the interrupted render publish into this new epoch.
        XCTAssertEqual(enqueuedWhileHeld, 0, "A copied pre-seek image must not reach enqueue while its seek is active")
        XCTAssertEqual(afterSubmitted, baselineSubmitted)
        XCTAssertNil(afterFrame)
        XCTAssertNil(currentCredit, "A late epoch snapshot must not credit a copied pre-seek image to the new epoch")

        // Positive recovery is deliberately retained after the RED assertions.
        bridge.onDebugRenderStamp = nil
        let nativeFinished = await waitForPresentation { nativeCompletion.result != nil }
        XCTAssertTrue(nativeFinished); XCTAssertEqual(nativeCompletion.result, true)
        guard nativeFinished, nativeCompletion.result == true else {
            XCTFail("The real same-item 0.75 seek must complete before releasing CPP"); return
        }
        let beforeRecovery = bridge.submittedFrameCount
        XCTAssertTrue(bridge.installTimeline(ticket, positionSeconds: 0.75, durationSeconds: 30, isPlaying: false))
        bridge.completeSeek(heldSeek)
        XCTAssertTrue(bridge.activate(ticket))
        let recovered = await waitForPresentation {
            bridge.updatePlayback(positionSeconds: 0.75, durationSeconds: 30, isPlaying: false)
            guard let copied = bridge.lastCopiedFramePositionSeconds,
                  let submitted = bridge.lastFramePositionSeconds else { return false }
            return bridge.submittedFrameCount > beforeRecovery && bridge.debugCurrentFrameEpoch(for: ticket) != nil
                && bridge.displayLayer.isReadyForDisplay && copied <= 0.75 + 0.000_01 && submitted <= 0.75 + 0.000_01
                && abs(copied - 0.75) <= 1.0 / 24 + 0.000_01
                && abs(submitted - 0.75) <= 1.0 / 24 + 0.000_01
        }
        XCTAssertTrue(recovered, "Matching completion must still submit a real paused target in the current epoch")
        XCTAssertTrue(resource.item === item); XCTAssertTrue(resource.output === output)
        XCTAssertTrue(resource.isAttached); XCTAssertTrue(resource.isBorrowed); XCTAssertFalse(resource.isRetired)
        XCTAssertEqual(item.outputs.count, 1)
        #else
        XCTFail("After-copy seek contracts require existing DEBUG render stamps")
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
