import XCTest
import AVFoundation
import UIKit
import CoreVideo
import CoreImage
import AudioToolbox
import MediaToolbox
import Synchronization
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class PictureRecoveryTests: XCTestCase {
    private static let hostModuleNonce = UUID().uuidString.lowercased()
    private let imageReadback = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    func testFullResolutionProductionPlaybackKeepsVideoAndAudioMoving() async throws {
        try await measureProductionHD(actualSessionActivation: false)
    }
    func testFullResolutionProductionPlaybackWithExplicitSessionActivation() async throws {
        try await measureProductionHD(actualSessionActivation: true)
    }
    private func measureProductionHD(actualSessionActivation: Bool) async throws {
        let fixture = try await PictureRecoveryFixture(test: self, firstResourceName: "test-motion-1080", firstDuration: 6,
            actualSessionActivation: actualSessionActivation)
        defer { fixture.dumpSessionEvidence() }
        let service = fixture.service
        let layer = try XCTUnwrap(service.surface.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
        var measuring = false, recording = true, delivered = 0, invalidOwners = 0
        var request = -1, token = 0, visit: Int64 = 0
        var selectedItem: ObjectIdentifier?
        var previous: UInt64 = 0, maximumGap: UInt64 = 0, maximumEnqueue: UInt64 = 0
        var sdk = [CadenceSpan](repeating: CadenceSpan(), count: 8)
        var stages = [Int](repeating: 0, count: ContinuousPictureInPicture.DebugWholeFrameStage.enqueued.rawValue + 1)
        var previousTick: UInt64 = 0, previousReturn: UInt64 = 0, depth = 0
        var tickGap = CadenceSpan(), outsideGap = CadenceSpan()
        var positions: [PlaybackService.DebugVideoPositionRead] = []
        var handoffs: [PlaybackService.DebugVideoRateHandoff] = []
        var seeks: [(UInt64, PlaybackService.DebugVideoSeekStamp)] = []
        var terminals: [(UInt64, PlaybackService.DebugVideoSeekCompletionTerminal)] = []
        var outputChanges = 0, seekChanges = 0, revisionChanges = 0, overflow = false
        var lastOutput: ObjectIdentifier?, lastSeek: UInt64?, lastRevision: Int?
        var sourceChanges: [(UInt64, UInt64, ObjectIdentifier, UInt64, Int)] = []
        sourceChanges.reserveCapacity(16)
        positions.reserveCapacity(128); handoffs.reserveCapacity(16)
        seeks.reserveCapacity(16); terminals.reserveCapacity(16)
        service.onDebugCPPWholeFrame = { stamp in
            guard measuring, stamp.request == request, stamp.generation == request,
                  stamp.observedItem == selectedItem else { return }
            switch stamp.event {
            case .entered(let entry):
                tickGap.record(start: previousTick, end: entry.entryNs)
                if depth == 0 { outsideGap.record(start: previousReturn, end: entry.entryNs) }
                previousTick = entry.entryNs; depth += 1
            case .returned(let span):
                stages[span.stage.rawValue] += 1
                sdk[0].record(start: span.entry.entryNs, end: span.returnNs)
                if let v = span.layerStatus { sdk[1].record(start: v.entryNs, end: v.returnNs) }
                if let v = span.backpressure { sdk[2].record(start: v.entryNs, end: v.returnNs) }
                if let v = span.timebase { sdk[3].record(start: v.entryNs, end: v.returnNs) }
                if let v = span.readinessCommit { sdk[4].record(start: v.entryNs, end: v.returnNs) }
                depth = max(0, depth - 1)
                if depth == 0 { previousReturn = span.returnNs }
            }
        }
        service.onDebugVideoPositionRead = { value in
            guard recording else { return }
            if positions.count < 128 { positions.append(value) } else { overflow = true }
        }
        service.onDebugVideoRateHandoff = { value in
            guard recording else { return }
            if handoffs.count < 16 { handoffs.append(value) } else { overflow = true }
        }
        service.onDebugVideoSeekStamp = { value in
            guard recording else { return }
            if seeks.count < 16 { seeks.append((DispatchTime.now().uptimeNanoseconds, value)) } else { overflow = true }
        }
        service.onDebugVideoSeekCompletionTerminal = { value in
            guard recording else { return }
            if terminals.count < 16 { terminals.append((DispatchTime.now().uptimeNanoseconds, value)) } else { overflow = true }
        }
        service.onDebugCPPNativePullStamp = { stamp in
            guard measuring else { return }
            sdk[5 + stamp.pull.stage.rawValue].record(start: stamp.pull.entryNs, end: stamp.pull.returnNs)
            if lastOutput != stamp.pull.output || lastSeek != stamp.pull.nativeSeekTicket
                || lastRevision != stamp.pull.entryRevision {
                if sourceChanges.count < 16 {
                    sourceChanges.append((stamp.pull.entryNs, stamp.pull.returnNs, stamp.pull.output,
                        stamp.pull.nativeSeekTicket, stamp.pull.entryRevision))
                } else { overflow = true }
            }
            if let lastOutput, lastOutput != stamp.pull.output { outputChanges += 1 }
            if let lastSeek, lastSeek != stamp.pull.nativeSeekTicket { seekChanges += 1 }
            if let lastRevision, lastRevision != stamp.pull.entryRevision { revisionChanges += 1 }
            lastOutput = stamp.pull.output; lastSeek = stamp.pull.nativeSeekTicket; lastRevision = stamp.pull.entryRevision
            guard stamp.pull.stage == .enqueue else { return }
            guard stamp.request == request, stamp.generation == request,
                  stamp.sourceItem == selectedItem, stamp.sourceItemMatches, stamp.observedItemMatches,
                  stamp.presentationMatches, stamp.cachedAudioToken == token, stamp.cachedAudioVisit == visit,
                  stamp.pull.entryOwnerCoherent, stamp.pull.ownerUnchanged,
                  stamp.pull.returnNs >= previous else { invalidOwners += 1; return }
            maximumGap = max(maximumGap, stamp.pull.returnNs - previous)
            maximumEnqueue = max(maximumEnqueue, stamp.pull.returnNs - stamp.pull.entryNs)
            previous = stamp.pull.returnNs; delivered += 1
        }
        defer {
            service.onDebugCPPNativePullStamp = nil; service.onDebugCPPWholeFrame = nil
            service.onDebugVideoPositionRead = nil; service.onDebugVideoRateHandoff = nil
            service.onDebugVideoSeekStamp = nil; service.onDebugVideoSeekCompletionTerminal = nil
        }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.mediaID)
        try await until { service.isVideoReady && service.audioSnapshot.frame > 2_400 }
        let imageReadStart = DispatchTime.now().uptimeNanoseconds
        let oldPicture = try XCTUnwrap(smallPicture(layer))
        let imageReadEnd = DispatchTime.now().uptimeNanoseconds
        let nativeReadStart = DispatchTime.now().uptimeNanoseconds
        let nativeStart = service.player.currentTime().seconds
        let nativeReadEnd = DispatchTime.now().uptimeNanoseconds
        let before = service.audioSnapshot
        XCTAssertTrue(service.player.isMuted)
        XCTAssertEqual(service.queue.currentID, fixture.mediaID)
        request = service.debugAlignedVideoPollState.generation
        selectedItem = ObjectIdentifier(try XCTUnwrap(service.player.currentItem))
        token = before.token; visit = before.visit
        let frameAtStart = service.debugAlignedVideoPollState.frame
        XCTAssertNotNil(frameAtStart.output); XCTAssertNotNil(frameAtStart.ticket)
        lastOutput = frameAtStart.output; lastSeek = frameAtStart.seekSerial
        lastRevision = frameAtStart.ticket?.debugGeneration
        let start = DispatchTime.now().uptimeNanoseconds
        previous = start; previousTick = start; previousReturn = start
        let heartbeat = CadenceHeartbeat(start: start)
        measuring = true
        try await Task.sleep(for: .milliseconds(1200))
        let end = DispatchTime.now().uptimeNanoseconds
        measuring = false; recording = false
        let after = service.audioSnapshot
        maximumGap = max(maximumGap, end - previous)
        tickGap.record(start: previousTick, end: end)
        if depth == 0 { outsideGap.record(start: previousReturn, end: end) }
        let background = heartbeat.stop(end: end)
        let nativeEnd = service.player.currentTime().seconds
        let nativeControl = service.player.timeControlStatus.rawValue
        XCTAssertTrue(service.player.isMuted)
        XCTAssertEqual(service.queue.currentID, fixture.mediaID)
        let newPicture = try XCTUnwrap(smallPicture(layer))
        service.pause()
        let elapsed = Double(end - start) / 1_000_000_000
        let fps = Double(delivered) / elapsed, gapMs = Double(maximumGap) / 1_000_000
        print("PRODUCTION_HD deliveredFPS=\(fps) maximumGapMs=\(gapMs) maximumEnqueueMs=\(Double(maximumEnqueue) / 1_000_000) audioAdvanced=\(after.frame - before.frame) underrunsAdded=\(after.underrunFrames - before.underrunFrames) actualPictureChanged=\(oldPicture != newPicture)")
        print("PRODUCTION_HD_STALL windowNs=[\(start),\(end)] imageReadNs=[\(imageReadStart),\(imageReadEnd)] nativeStartReadNs=[\(nativeReadStart),\(nativeReadEnd)] nativeStart=\(nativeStart) nativeEnd=\(nativeEnd) nativeControl=\(nativeControl) tickMs=\(tickGap.milliseconds) tickNs=[\(tickGap.start),\(tickGap.end)] outsideMs=\(outsideGap.milliseconds) outsideNs=[\(outsideGap.start),\(outsideGap.end)] backgroundTicks=\(background.ticks) backgroundMs=\(background.maximum.milliseconds) backgroundNs=[\(background.maximum.start),\(background.maximum.end)] sdkMs=\(sdk.map(\.milliseconds)) sdkStartsNs=\(sdk.map(\.start)) sdkEndsNs=\(sdk.map(\.end)) stages=\(stages) outputChanges=\(outputChanges) seekChanges=\(seekChanges) revisionChanges=\(revisionChanges)")
        print("PRODUCTION_HD_SOURCE_BASE output=\(String(describing: frameAtStart.output)) seek=\(frameAtStart.seekSerial) revision=\(frameAtStart.ticket?.debugGeneration ?? -1) windowStartNs=\(start) transitionTimes=first-observed-not-exact")
        for v in sourceChanges {
            print("PRODUCTION_HD_SOURCE firstObservedEntryNs=\(v.0) returnNs=\(v.1) output=\(v.2) seek=\(v.3) revision=\(v.4)")
        }
        print("PRODUCTION_HD_HOST schema=1 processID=\(ProcessInfo.processInfo.processIdentifier) moduleNonce=\(Self.hostModuleNonce) explicitActivation=\(actualSessionActivation)")
        for v in positions {
            print("PRODUCTION_HD_POSITION entryNs=\(v.entryNs) returnNs=\(v.returnNs) position=\(v.position) raw=\(v.rawItemTimebasePosition ?? -1) effectiveRate=\(v.itemTimebaseEffectiveRate ?? -1) request=\(v.request) generation=\(v.returnGeneration) owned=\(v.observedItemMatches && v.presentationUnchanged)")
        }
        for v in handoffs {
            print("PRODUCTION_HD_RATE entryNs=\(v.entryNs) returnNs=\(v.returnNs) cause=\(v.cause.rawValue) rate=\(v.requestedRate) position=\(v.anchorTime.seconds) host=\(v.anchorHostTime.seconds) request=\(v.request) generation=\(v.returnGeneration) owned=\(v.presentationUnchanged)")
        }
        for (time, v) in seeks {
            print("PRODUCTION_HD_SEEK observedNs=\(time) reason=\(v.reason.rawValue) ticket=\(v.nativeSeekTicket) target=\(v.requestedPosition) force=\(v.force) request=\(v.request) generation=\(v.generation) token=\(v.cachedAudioToken) visit=\(v.cachedAudioVisit)")
        }
        for (time, v) in terminals {
            print("PRODUCTION_HD_SEEK_END observedNs=\(time) request=\(v.request) ticket=\(v.nativeSeekTicket)")
        }
        XCTAssertEqual(depth, 0); XCTAssertFalse(overflow); XCTAssertFalse(background.overflow)
        XCTAssertGreaterThan(fps, 50, "The actual service must deliver the full-resolution 60fps source")
        XCTAssertLessThan(gapMs, 100, "The actual audio clock must not hide a long video delivery gap")
        XCTAssertEqual(invalidOwners, 0)
        XCTAssertEqual(after.token, before.token); XCTAssertEqual(after.visit, before.visit)
        XCTAssertGreaterThanOrEqual(after.frame - before.frame, Int64(elapsed * 48_000 * 0.85),
            "Video throughput must not hide a stalled audio callback")
        XCTAssertLessThanOrEqual(after.frame - before.frame, Int64(elapsed * 48_000 * 1.15))
        XCTAssertEqual(after.underrunFrames, before.underrunFrames)
        XCTAssertNotEqual(oldPicture, newPicture, "Independently read the actual displayed image before and after")
        XCTAssertNil(service.message)
    }

    private func smallPicture(_ layer: AVSampleBufferDisplayLayer) -> Data? {
        guard let pixel = layer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        let image = CIImage(cvPixelBuffer: pixel).transformed(by: CGAffineTransform(
            scaleX: 8 / CGFloat(CVPixelBufferGetWidth(pixel)), y: 8 / CGFloat(CVPixelBufferGetHeight(pixel))))
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        imageReadback.render(image, toBitmap: &bytes, rowBytes: 8 * 4,
            bounds: CGRect(x: 0, y: 0, width: 8, height: 8), format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        return Data(bytes)
    }
    func testRapidFeedReversalCoversDepartingPixelsUntilReturnedMediaIsReady() async throws {
        let fixture = try await PictureRecoveryFixture(test: self)
        let service = fixture.service
        let layer = try XCTUnwrap(service.surface.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.mediaID)
        try await until { service.isVideoReady && self.pictureIs(layer, red: true) }
        service.feedDidSettle(direction: 1)
        try await until { service.isVideoReady && self.pictureIs(layer, red: false) }
        service.shouldDebugAcquireVideoFrame = { _ in false }
        service.isInteractingWithFeed = true
        service.feedDidSettle(direction: -1)
        XCTAssertEqual(service.queue.currentID, fixture.mediaID)
        XCTAssertFalse(service.isVideoReady)
        XCTAssertFalse(service.hasRetainedVideoFrame,
            "Returned A must keep its poster over retained B pixels until an actual A frame is ready")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(pictureIs(layer, red: false), "Keep PiP's held picture without exposing it as the returned clip")
        XCTAssertFalse(service.isVideoReady || service.hasRetainedVideoFrame)
        service.shouldDebugAcquireVideoFrame = nil
        try await until { service.isVideoReady && self.pictureIs(layer, red: true) }
        XCTAssertNil(service.message)
        XCTAssertTrue(service.wantsToPlay)
    }

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

    func testNativeAudioOwnerRecoversAgainAfterPauseWithoutSeekingTheAudiblePlayer() async throws {
        let fixture = try await PictureRecoveryFixture(test: self, nativeAudio: true)
        let service = fixture.service
        service.start(playlistIDs: [fixture.playlist], at: fixture.mediaID)
        try await until { service.isVideoReady && service.player.currentTime().seconds > 0.25 }
        let item = try XCTUnwrap(service.player.currentItem)
        let audibleOutput = try XCTUnwrap(item.outputs.first)
        let jumps = PictureTimeJumpCounter()
        var completedAudioSeeks = 0
        service.onPlaybackEvent = { if $0.name == "seekCompleted" { completedAudioSeeks += 1 } }
        let observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification,
            object: item, queue: .main) { _ in MainActor.assumeIsolated { jumps.value += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        var repairs = 0
        service.onDebugVideoOutputRecovery = {
            repairs += 1
            service.shouldDebugAcquireVideoFrame = nil
        }
        // A tap changes AVFoundation's audio graph. Preserve an uninstrumented
        // control so the observer cannot accidentally hide the original fault.
        let controlFrames = service.submittedVideoFrameCount
        var controlClock = NativeClockContinuityProbe()
        service.shouldDebugAcquireVideoFrame = { _ in false }
        try await until {
            controlClock.sample(item)
            return repairs == 1 && service.submittedVideoFrameCount >= controlFrames + 4 && service.isVideoReady
        }
        print("NATIVE_AUDIO_UNINSTRUMENTED timeJumpNotifications=\(jumps.value) completedAudioSeeks=\(completedAudioSeeks) clockSamples=\(controlClock.samples) definiteClockJumpSeconds=\(controlClock.maximumDefiniteJump) minimumEffectiveRate=\(controlClock.minimumRate)")
        XCTAssertEqual(jumps.value, 0)
        XCTAssertEqual(completedAudioSeeks, 0)
        XCTAssertGreaterThan(controlClock.samples, 4)
        XCTAssertLessThan(controlClock.maximumDefiniteJump, 0.002)
        XCTAssertGreaterThan(controlClock.minimumRate, 0.99)
        XCTAssertTrue(service.debugUsesIsolatedVideo)
        XCTAssertFalse(service.debugVideoPresentationItem === item)
        XCTAssertTrue(item.outputs.first === audibleOutput, "Promoting picture recovery must leave the audible tap attached")
        service.pause()
        try await Task.sleep(for: .milliseconds(100))
        service.play()
        try await until { service.isVideoReady && service.player.rate > 0 }
        let audioProbe = try await NativeAudioContinuityProbe.attach(to: item)
        try await until { audioProbe.totalFrames.load(ordering: .relaxed) >= 48_000 }
        for attempt in 2...3 {
            let pictureItem = try XCTUnwrap(service.debugVideoPresentationItem)
            XCTAssertFalse(pictureItem === item)
            let output = try XCTUnwrap(pictureItem.outputs.first)
            let before = service.player.currentTime().seconds
            let frames = service.submittedVideoFrameCount
            jumps.value = 0
            let epoch = audioProbe.beginWindow()
            try await until { audioProbe.observedEpoch.load(ordering: .acquiring) == epoch }
            var nativeClock = NativeClockContinuityProbe()
            // Detach the real SDK producer; do not release an application-side
            // acquisition gate when the repair reports completion.
            pictureItem.remove(output)
            try await until {
                nativeClock.sample(item)
                return repairs == attempt && service.submittedVideoFrameCount >= frames + 4 && service.isVideoReady
            }
            XCTAssertTrue(service.player.currentItem === item)
            XCTAssertTrue(item.outputs.first === audibleOutput)
            XCTAssertTrue(service.debugVideoPresentationItem === pictureItem)
            XCTAssertEqual(pictureItem.outputs.count, 1)
            XCTAssertFalse(pictureItem.outputs.first === output)
            XCTAssertGreaterThan(service.player.currentTime().seconds, before + 1)
            XCTAssertEqual(jumps.value, 0, "Replacing a picture output must not seek the streamed/native audio clock")
            print("NATIVE_AUDIO_CONTINUITY attempt=\(attempt) timeJumpNotifications=\(jumps.value) completedAudioSeeks=\(completedAudioSeeks) windowFrames=\(audioProbe.windowFrames.load(ordering: .relaxed)) sourceGapFrames=\(audioProbe.gapFrames.load(ordering: .relaxed)) sourceOverlapFrames=\(audioProbe.overlapFrames.load(ordering: .relaxed)) zeroReturns=\(audioProbe.zeroReturns.load(ordering: .relaxed)) maximumSilentFrames=\(audioProbe.maximumSilentFrames.load(ordering: .relaxed)) readErrors=\(audioProbe.readErrors.load(ordering: .relaxed)) supportedPCM=\(audioProbe.supported.load(ordering: .relaxed)) clockSamples=\(nativeClock.samples) definiteClockJumpSeconds=\(nativeClock.maximumDefiniteJump) minimumEffectiveRate=\(nativeClock.minimumRate)")
            XCTAssertEqual(completedAudioSeeks, 0)
            XCTAssertTrue(audioProbe.supported.load(ordering: .relaxed))
            XCTAssertGreaterThan(audioProbe.windowFrames.load(ordering: .relaxed), 24_000)
            XCTAssertEqual(audioProbe.gapFrames.load(ordering: .relaxed), 0)
            XCTAssertEqual(audioProbe.overlapFrames.load(ordering: .relaxed), 0)
            XCTAssertEqual(audioProbe.readErrors.load(ordering: .relaxed), 0)
            XCTAssertEqual(audioProbe.zeroReturns.load(ordering: .relaxed), 0)
            XCTAssertLessThanOrEqual(audioProbe.maximumSilentFrames.load(ordering: .relaxed), 2)
            XCTAssertGreaterThan(nativeClock.samples, 4)
            XCTAssertLessThan(nativeClock.maximumDefiniteJump, 0.002)
            XCTAssertGreaterThan(nativeClock.minimumRate, 0.99)
            XCTAssertFalse(service.player.isMuted)
            XCTAssertFalse(service.audioEngineRunning)
            XCTAssertTrue(service.wantsToPlay)
            XCTAssertNil(service.message)
            if attempt == 2 {
                let stoppedAt = service.player.currentTime().seconds
                service.pause()
                try await Task.sleep(for: .milliseconds(100))
                service.play()
                try await until { service.isVideoReady && service.player.currentTime().seconds > stoppedAt + 0.25 }
            }
        }
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

    func testPausedIsolatedSeekSurvivesOrdinaryPausedClockUpdates() async throws {
        let (decoder, clock) = try await isolatedDecoder(position: 1.5, rate: 0)
        var completions = 0
        decoder.synchronize(to: clock, playing: false, force: true) { completions += 1 }
        for _ in 0..<6 {
            decoder.synchronize(to: clock, playing: false) { completions += 1 }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await until { completions == 1 && !decoder.isAligning }
        XCTAssertEqual(decoder.debugSeekCount, 1)
        XCTAssertEqual(decoder.player.currentTime().seconds, 1.5, accuracy: 1.0 / 60)
        XCTAssertEqual(decoder.player.rate, 0)
    }

    func testSlowIsolatedNativeStartDoesNotRepeatedlySeekItsStoppedClock() async throws {
        let (decoder, clock) = try await isolatedDecoder(position: 0.2, rate: 1)
        var pendingStart: (() -> Void)?
        decoder.debugScheduleStart = { player, position, host in
            pendingStart = { player.setRate(1, time: position, atHostTime: host) }
        }
        decoder.synchronize(to: clock, playing: true, force: true) {}
        try await until { pendingStart != nil }
        let seeks = decoder.debugSeekCount
        for _ in 0..<35 {
            decoder.synchronize(to: clock, playing: true) {}
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(decoder.debugSeekCount, seeks, "A stopped scheduled clock must get startup grace, not repeated seeks")
        XCTAssertEqual(decoder.item.timebase.map { CMTimebaseGetEffectiveRate($0) }, 0)
        let start = try XCTUnwrap(pendingStart)
        decoder.debugScheduleStart = nil; pendingStart = nil
        start()
        try await until {
            decoder.synchronize(to: clock, playing: true) {}
            return decoder.player.currentTime().seconds > 0.45 && decoder.player.rate > 0
        }
        XCTAssertEqual(decoder.debugSeekCount, seeks)
    }

    private func isolatedDecoder(position: Double, rate: Double) async throws -> (IsolatedVideoRecovery, CMTimebase) {
        let url = try XCTUnwrap(Bundle(for: PictureRecoveryTests.self).url(forResource: "test-motion-60", withExtension: "mp4"))
        let decoder = try await IsolatedVideoRecovery.prepare(from: AVPlayerItem(url: url))
        addTeardownBlock { @MainActor in
            decoder.debugScheduleStart = nil
            if let pending = decoder.close() { await pending.value }
        }
        var created: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &created), noErr)
        let clock = try XCTUnwrap(created)
        CMTimebaseSetTime(clock, time: CMTime(seconds: position, preferredTimescale: 48_000))
        CMTimebaseSetRate(clock, rate: rate)
        return (decoder, clock)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(7)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Actual picture/audio recovery did not finish")
        if !condition() { throw CatalogError.invalid("Synthetic picture recovery timed out") }
    }

    private func pictureIs(_ layer: AVSampleBufferDisplayLayer, red: Bool) -> Bool {
        guard let pixel = layer.sampleBufferRenderer.displayedPixelBuffer() else { return false }
        // Interpret the actual image independently of the decoder's storage format.
        // The synthetic fixture is solid red or green; read its centre in RGB.
        let image = CIImage(cvPixelBuffer: pixel)
        var bytes = [UInt8](repeating: 0, count: 4)
        imageReadback.render(image,
            toBitmap: &bytes, rowBytes: 4,
            bounds: CGRect(x: image.extent.midX.rounded(.down), y: image.extent.midY.rounded(.down), width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let r = Int(bytes[0]), g = Int(bytes[1])
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
    private let activationProbe: PictureActivationProbe
    private weak var previousWindow: UIWindow?
    private let preferences = ["speakerSound", "automaticPiP", "audioOnly"].map { ($0, UserDefaults.standard.object(forKey: $0)) }

    init(test: XCTestCase, nativeAudio: Bool = false,
         firstResourceName: String = "test-selection-a", firstDuration: Double = 30,
         actualSessionActivation: Bool = false) async throws {
        let activation = PictureActivationProbe(actual: actualSessionActivation)
        activationProbe = activation
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cloud = OneDriveClient(account: MicrosoftAccount())
        let downloads = try OfflineDownloads(cloud: cloud, network: NetworkStatus(), debugLocalRoot: directory)
        let library = LibraryRepository(cloud: cloud, catalogURL: directory.appendingPathComponent("catalog.json"))
        for (key, name) in [(mediaID, firstResourceName), (otherID, "test-selection-b")] {
            let source = try XCTUnwrap(Bundle(for: PictureRecoveryTests.self).url(forResource: name, withExtension: "mp4"))
            _ = try await downloads.importLocal(source, mediaID: key)
        }
        try library.install(LibraryCatalog(libraryID: "local:picture-recovery", media: [
            MediaRecord(id: mediaID, title: "Synthetic picture recovery A", duration: firstDuration),
            MediaRecord(id: otherID, title: "Synthetic picture recovery B", duration: 30)
        ], playlists: [PlaylistRecord(id: playlist, name: "Synthetic", itemIDs: [mediaID, otherID])]))
        if nativeAudio {
            service = PlaybackService(library: library, downloads: downloads, cloud: cloud,
                bookmarkURL: directory.appendingPathComponent("playback.json"), activateSession: { try activation.activate() },
                preparePCM: { _, _, _, _ in throw ContinuousPCMDecoder.Failure.unsupportedPCM })
        } else {
            service = PlaybackService(library: library, downloads: downloads, cloud: cloud,
                bookmarkURL: directory.appendingPathComponent("playback.json"), activateSession: { try activation.activate() })
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
            service.onPlaybackEvent = nil
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
    func dumpSessionEvidence() {
        activationProbe.dump()
        // Post-window observation only: these SDK getters cannot move the cadence window.
        let session = AVAudioSession.sharedInstance()
        let start = DispatchTime.now().uptimeNanoseconds
        let category = session.category.rawValue, mode = session.mode.rawValue
        let rate = session.sampleRate, io = session.ioBufferDuration
        let route = session.currentRoute.outputs.map { $0.portType.rawValue }
        let end = DispatchTime.now().uptimeNanoseconds
        print("PRODUCTION_HD_SESSION phase=after-measurement category=\(category) mode=\(mode) sampleRate=\(rate) ioDuration=\(io) route=\(route) readNs=[\(start),\(end)]")
    }
}

@MainActor private final class PictureActivationProbe {
    private let actual: Bool
    private var entries: [(UInt64, UInt64, Bool, Int)] = []
    private var overflow = false
    init(actual: Bool) { self.actual = actual; entries.reserveCapacity(8) }
    func activate() throws {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            if actual { try AVAudioSession.sharedInstance().setActive(true) }
            record(start: start, succeeded: true, code: 0)
        } catch {
            record(start: start, succeeded: false, code: (error as NSError).code)
            throw error
        }
    }
    private func record(start: UInt64, succeeded: Bool, code: Int) {
        if entries.count < 8 { entries.append((start, DispatchTime.now().uptimeNanoseconds, succeeded, code)) }
        else { overflow = true }
    }
    func dump() {
        XCTAssertFalse(overflow)
        XCTAssertFalse(entries.isEmpty); XCTAssertTrue(entries.allSatisfy { $0.2 })
        for (ordinal, value) in entries.enumerated() {
            print("PRODUCTION_HD_ACTIVATION ordinal=\(ordinal) explicit=\(actual) entryNs=\(value.0) returnNs=\(value.1) succeeded=\(value.2) errorCode=\(value.3)")
        }
    }
}

@MainActor private final class PictureTimeJumpCounter { var value = 0 }

/// Observe real native audio supply, leaving every sample unchanged. This is
/// test-only and does not replace the physical-speaker acceptance check.
private final class NativeAudioContinuityProbe: @unchecked Sendable {
    let totalFrames = Atomic<Int64>(0), windowFrames = Atomic<Int64>(0)
    let gapFrames = Atomic<Int64>(0), overlapFrames = Atomic<Int64>(0)
    let zeroReturns = Atomic<Int64>(0), maximumSilentFrames = Atomic<Int64>(0), readErrors = Atomic<Int64>(0)
    let supported = Atomic<Bool>(false)
    private let requestedEpoch = Atomic<Int>(0)
    let observedEpoch = Atomic<Int>(0)
    // prepare/process are serialized by MTAudioProcessingTap; UI reads atomics only.
    private var renderEpoch = 0, channels = 0
    private var rate = 48_000.0, interleaved = false
    private var previousEnd: Int64?, silentRun: Int64 = 0

    func beginWindow() -> Int { requestedEpoch.wrappingAdd(1, ordering: .releasing).newValue }
    private func prepare(_ format: AudioStreamBasicDescription) {
        channels = Int(format.mChannelsPerFrame); rate = format.mSampleRate
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        supported.store(format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && channels > 0 && rate > 0, ordering: .relaxed)
    }
    private func record(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int, range: CMTimeRange, error: OSStatus) {
        let epoch = requestedEpoch.load(ordering: .acquiring)
        if epoch != renderEpoch {
            renderEpoch = epoch; previousEnd = nil; silentRun = 0
            windowFrames.store(0, ordering: .relaxed); gapFrames.store(0, ordering: .relaxed)
            overlapFrames.store(0, ordering: .relaxed); zeroReturns.store(0, ordering: .relaxed)
            maximumSilentFrames.store(0, ordering: .relaxed); readErrors.store(0, ordering: .relaxed)
            observedEpoch.store(epoch, ordering: .releasing)
        }
        guard error == noErr else { _ = readErrors.wrappingAdd(1, ordering: .relaxed); return }
        guard frames > 0 else { _ = zeroReturns.wrappingAdd(1, ordering: .relaxed); return }
        _ = totalFrames.wrappingAdd(Int64(frames), ordering: .relaxed)
        _ = windowFrames.wrappingAdd(Int64(frames), ordering: .relaxed)
        if range.start.isNumeric, range.duration.isNumeric {
            let start = Int64((range.start.seconds * rate).rounded())
            if let previousEnd {
                let delta = start - previousEnd
                if delta > 1 { _ = gapFrames.wrappingAdd(delta, ordering: .relaxed) }
                if delta < -1 { _ = overlapFrames.wrappingAdd(-delta, ordering: .relaxed) }
            }
            previousEnd = Int64((CMTimeRangeGetEnd(range).seconds * rate).rounded())
        } else { _ = readErrors.wrappingAdd(1, ordering: .relaxed) }
        guard supported.load(ordering: .relaxed) else { return }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        let stride = interleaved ? channels : 1
        guard let first = list.first, let raw = first.mData, Int(first.mDataByteSize) >= frames * stride * 4 else {
            _ = readErrors.wrappingAdd(1, ordering: .relaxed); return
        }
        let input = raw.assumingMemoryBound(to: Float.self)
        for index in 0..<frames {
            silentRun = abs(input[index * stride]) < 0.000001 ? silentRun + 1 : 0
            if silentRun > maximumSilentFrames.load(ordering: .relaxed) {
                maximumSilentFrames.store(silentRun, ordering: .relaxed)
            }
        }
    }

    @MainActor static func attach(to item: AVPlayerItem) async throws -> NativeAudioContinuityProbe {
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        let probe = NativeAudioContinuityProbe()
        let retained = Unmanaged.passRetained(probe)
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(), init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<NativeAudioContinuityProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                Unmanaged<NativeAudioContinuityProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            }, unprepare: { _ in }, process: { tap, frames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut)
                Unmanaged<NativeAudioContinuityProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .record(buffers, frames: status == noErr ? framesOut.pointee : 0, range: range, error: status)
                if status != noErr { framesOut.pointee = 0 }
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else { retained.release(); throw CatalogError.invalid("Native audio probe unavailable") }
        let input = AVMutableAudioMixInputParameters(track: track); input.audioTapProcessor = tap
        let mix = AVMutableAudioMix(); mix.inputParameters = [input]; item.audioMix = mix
        return probe
    }
}

@MainActor private struct NativeClockContinuityProbe {
    private var previous: (before: Double, after: Double, position: Double)?
    private(set) var samples = 0
    private(set) var maximumDefiniteJump = 0.0
    private(set) var minimumRate = Double.infinity
    mutating func sample(_ item: AVPlayerItem) {
        guard let timebase = item.timebase else { return }
        let host = CMClockGetHostTimeClock()
        let before = CMClockGetTime(host).seconds
        let position = CMTimebaseGetTime(timebase).seconds
        let rate = CMTimebaseGetEffectiveRate(timebase)
        let after = CMClockGetTime(host).seconds
        guard position.isFinite, before.isFinite, after.isFinite, rate.isFinite else { return }
        samples += 1; minimumRate = min(minimumRate, rate)
        if let previous {
            let progress = position - previous.position
            let earliest = before - previous.after, latest = after - previous.before
            maximumDefiniteJump = max(maximumDefiniteJump, max(earliest - progress, progress - latest))
        }
        previous = (before, after, position)
    }
}
