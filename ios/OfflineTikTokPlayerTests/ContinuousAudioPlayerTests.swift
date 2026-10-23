import XCTest
import AVFoundation
import Synchronization
@testable import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class ContinuousAudioPlayerTests: XCTestCase {
    func testSameTokenRenderAnchorWaitsForFreshPublicationAfterRealPauseResume() async throws {
        #if DEBUG
        guard Self.unresolvedRenderAnchorCalibrationOwner == nil else {
            print("RenderAnchorPauseResumeCalibrationRefusal schema=1 ownerSlotOccupied=true newOwnerCreated=false")
            XCTFail("The previous calibration owner has not acknowledged close; no new owner may start")
            throw RenderAnchorCalibrationSetupError.ownerNotClosed
        }
        let accounting = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        let audio = ContinuousAudioPlayer(debugRenderAccounting: accounting)
        // Reserve the one slot before the first await; only an acknowledged close releases it.
        Self.unresolvedRenderAnchorCalibrationOwner = audio
        XCTAssertFalse(accounting.capturesPCMOrigin); XCTAssertFalse(accounting.capturesSourceOutput)
        XCTAssertNil(accounting.callbackLedger)
        let closed = Mutex<Bool?>(nil)
        var shutdownRequested = false, originalError: Error?
        var qualified = false, freshBefore = false, freshAfter = false, wrongTokenRejected = false
        var explicitPauseCorrect = false, freshWrongTokenRejected = false
        var sequenceAtSeed = 0, sequenceBeforeQuery = 0, sequenceAfterQuery = 0
        var resumedAnchor: Double?, resumedPosition: Double?, expectedCursor: Double?
        var callbackBeforeEntered: UInt64 = 0, callbackBeforeCompleted: UInt64 = 0
        var callbackAfterEntered: UInt64 = 0, callbackAfterCompleted: UInt64 = 0
        var callbackCountsQualified = false
        defer {
            if !shutdownRequested {
                qualified = false
                audio.suspend(); audio.graph.engine.stop()
                // The reserved exact owner stays retained; this fallback is never a close ACK.
                audio.debugShutdown { _ in }
            }
        }
        do {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
            audio.setWindow(["a"])
            let entry = try await audio.prepare(id: "a", url: url, currentPriority: true)
            try audio.graph.engine.enableManualRenderingMode(.offline, format: audio.graph.format, maximumFrameCount: 32)
            guard entry.token > 0, entry.token < Int.max, entry.frames > 4_832,
                  audio.select(id: "a", position: 0.1) else {
                XCTFail("A complete real source and selected .1 position must qualify the store calibration")
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            try audio.setPlaying(true)
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.graph.format, frameCapacity: 32))
            guard try audio.graph.engine.renderOffline(32, to: output) == .success else {
                XCTFail("The real source callback must acknowledge the selected PCM before anchor calibration")
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            let before = audio.snapshot
            guard before.token == entry.token, before.visit > 0, before.frame >= 4_832,
                  !before.ended, before.underrunFrames == 0, !audio.isSelectionPending(in: before),
                  audio.graph.engine.isRunning else {
                XCTFail("Actual acknowledged positive-token PCM and a running manual engine are required")
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            // Explicitly synthetic host time enters the actual private publisher.
            // It is not a claimed SDK render timestamp, source callback or measured pause length.
            let seedHost = 1_000.0
            let afterPauseHost = CMTime(seconds: seedHost + 10, preferredTimescale: 1_000_000)
            guard audio.graph.debugPublishSyntheticRenderAnchor(before, hostEnd: seedHost) else {
                XCTFail("Only the sole offline manual-render owner may seed the actual anchor store")
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            sequenceAtSeed = audio.graph.debugRenderAnchorPublicationSequence
            let current = audio.graph.presentationPosition(token: entry.token,
                at: CMTime(seconds: seedHost, preferredTimescale: 1_000_000))
            freshBefore = current?.isFinite == true
            wrongTokenRejected = audio.graph.presentationPosition(token: entry.token + 1, at: afterPauseHost) == nil
            guard sequenceAtSeed > 0, sequenceAtSeed & 1 == 0, freshBefore, wrongTokenRejected else {
                XCTFail("The real query must accept a coherent fresh publication and reject a different token")
                throw RenderAnchorCalibrationSetupError.unqualified
            }

            let callbacksBefore = try XCTUnwrap(accounting.snapshot(), "Source callback accounting must be available before pause")
            callbackBeforeEntered = callbacksBefore.sourceCallbacksEntered
            callbackBeforeCompleted = callbacksBefore.sourceCallbacksCompleted
            guard !callbacksBefore.overflowed, callbackBeforeEntered > 0,
                  callbackBeforeEntered == callbackBeforeCompleted else {
                XCTFail("A completed actual source callback must qualify the pre-pause accounting prefix")
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            audio.suspend() // Real intent changes; the engine is not yet paused by settlePausedState.
            guard audio.graph.engine.isRunning else {
                XCTFail("The explicit-Pause fallback must qualify before the engine stops")
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            let cursor = Double(before.frame) / 48_000
            expectedCursor = cursor
            let explicitPausePosition = audio.presentationPosition(at: afterPauseHost)
            explicitPauseCorrect = abs(explicitPausePosition - cursor) <= 0.5 / 48_000
            XCTAssertEqual(explicitPausePosition, cursor, accuracy: 0.5 / 48_000,
                "Explicit Pause must use the exact cursor even while the graph remains running")
            audio.settlePausedState()
            guard !audio.graph.engine.isRunning else {
                XCTFail("Real paused selection acknowledgment must permit the normal engine pause")
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            try audio.setPlaying(true)
            // No renderOffline call occurs between suspend and these queries. A new
            // publication nevertheless observed here makes setup unavailable, never a RED.
            sequenceBeforeQuery = audio.graph.debugRenderAnchorPublicationSequence
            resumedAnchor = audio.graph.presentationPosition(token: entry.token, at: afterPauseHost)
            resumedPosition = audio.presentationPosition(at: afterPauseHost)
            sequenceAfterQuery = audio.graph.debugRenderAnchorPublicationSequence
            let callbacksAfter = try XCTUnwrap(accounting.snapshot(), "Source callback accounting must remain available after resume queries")
            callbackAfterEntered = callbacksAfter.sourceCallbacksEntered
            callbackAfterCompleted = callbacksAfter.sourceCallbacksCompleted
            callbackCountsQualified = !callbacksAfter.overflowed
                && callbackAfterEntered == callbackBeforeEntered && callbackAfterCompleted == callbackBeforeCompleted
                && callbackAfterEntered == callbackAfterCompleted
            let resumed = audio.snapshot
            qualified = explicitPauseCorrect && callbackCountsQualified && audio.graph.engine.isRunning && sequenceBeforeQuery == sequenceAtSeed
                && sequenceAfterQuery == sequenceAtSeed && resumed.token == before.token
                && resumed.visit == before.visit && resumed.selectionVersion == before.selectionVersion
                && resumed.frame == before.frame && resumed.underrunFrames == before.underrunFrames
                && !resumed.ended && !audio.isSelectionPending(in: resumed)
                && (resumedAnchor == nil || resumedAnchor?.isFinite == true) && resumedPosition?.isFinite == true
            guard qualified else {
                XCTFail("Same source/visit/version/cursor, unchanged completed callback counts and no fresh anchor publication must qualify resume")
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            // Intended RED on the unchanged implementation: same token alone grants
            // the old anchor permission to extrapolate through the synthetic host gap.
            XCTAssertNil(resumedAnchor, "A new playing interval must await its own anchor publication")
            XCTAssertEqual(try XCTUnwrap(resumedPosition), cursor, accuracy: 0.5 / 48_000,
                "Before a fresh publication, resumed presentation must fall back to the real cursor")

            // Positive recovery: the same actual publisher/query remains usable after
            // a fresh current-interval synthetic publication. No SDK callback is fabricated.
            XCTAssertTrue(audio.graph.debugPublishSyntheticRenderAnchor(resumed, hostEnd: seedHost + 10))
            let fresh = audio.graph.presentationPosition(token: entry.token, at: afterPauseHost)
            freshAfter = fresh?.isFinite == true
            XCTAssertTrue(freshAfter)
            freshWrongTokenRejected = audio.graph.presentationPosition(token: entry.token + 1, at: afterPauseHost) == nil
            XCTAssertTrue(freshWrongTokenRejected)
            XCTAssertGreaterThan(audio.graph.debugRenderAnchorPublicationSequence, sequenceAtSeed)
            XCTAssertEqual(audio.snapshot.underrunFrames, 0)
            XCTAssertEqual(audio.renderer.retainedPCMMemoryBytes, 6_912_000)
            XCTAssertEqual(audio.preparedCount, 1)
            qualified = qualified && freshBefore && freshAfter && wrongTokenRejected && freshWrongTokenRejected
                && audio.graph.debugRenderAnchorPublicationSequence > sequenceAtSeed
                && audio.snapshot.underrunFrames == 0 && audio.renderer.retainedPCMMemoryBytes == 6_912_000
                && audio.preparedCount == 1
        } catch { originalError = error }
        audio.suspend(); audio.graph.engine.stop()
        shutdownRequested = true
        audio.debugShutdown { value in closed.withLock { $0 = value } }
        let returned = await Self.capCancellationWait(.seconds(3)) { closed.withLock { $0 != nil } }
        let closeAcknowledged = returned && closed.withLock { $0 == true }
        if closeAcknowledged {
            if Self.unresolvedRenderAnchorCalibrationOwner === audio {
                Self.unresolvedRenderAnchorCalibrationOwner = nil
            } else {
                qualified = false
                if originalError == nil { originalError = RenderAnchorCalibrationSetupError.ownerChanged }
                XCTFail("An acknowledged close cannot release a different calibration owner")
            }
        } else {
            qualified = false // The reserved exact audio owner remains retained in the sole static slot.
            if originalError == nil { originalError = RenderAnchorCalibrationSetupError.closeUnacknowledged }
        }
        XCTAssertTrue(closeAcknowledged, "The owned decoder close must acknowledge within the existing three-second bound; otherwise retain the exact owner and disqualify the RED")
        print("RenderAnchorPauseResumeCalibration schema=1 qualified=\(qualified) freshBefore=\(freshBefore) freshAfter=\(freshAfter) wrongTokenRejected=\(wrongTokenRejected) callbackCountsQualified=\(callbackCountsQualified) callbackBeforeEntered=\(callbackBeforeEntered) callbackBeforeCompleted=\(callbackBeforeCompleted) callbackAfterEntered=\(callbackAfterEntered) callbackAfterCompleted=\(callbackAfterCompleted) ownerRetained=\(Self.unresolvedRenderAnchorCalibrationOwner === audio) seedSequence=\(sequenceAtSeed) beforeQuerySequence=\(sequenceBeforeQuery) afterQuerySequence=\(sequenceAfterQuery) resumedAnchor=\(resumedAnchor.map { String($0) } ?? "nil") resumedPosition=\(resumedPosition.map { String($0) } ?? "unavailable") expectedCursor=\(expectedCursor.map { String($0) } ?? "unavailable") decoderCloseAcknowledged=\(closed.withLock { $0 } == true) originalErrorRetained=\(originalError != nil) syntheticHostSeed=true sdkRenderTimestampProof=false sdkCallbackProof=false physicalPauseDuration=unmeasured latencyAcceptance=false xctestOutcome=external")
        print("RenderAnchorPauseResumeControls schema=1 explicitPauseCorrect=\(explicitPauseCorrect) freshWrongTokenRejected=\(freshWrongTokenRejected) qualifiedIncludesControls=true")
        if let originalError { throw originalError }
        #else
        XCTFail("Render-anchor store calibration requires the DEBUG publisher inspection seam")
        #endif
    }

    func testRenderAnchorRequiresCurrentVisitAndConsumedSelectionVersion() async throws {
        #if DEBUG
        try await withManualAnchorControl("visit-and-selection-owner") { audio, sample in
            let owner = audio.graph
            let host = CMTime(seconds: 1_001, preferredTimescale: 1_000_000)
            let cursor = Double(sample.frame) / 48_000
            XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(sample, hostEnd: 1_000))
            let fresh = audio.presentationPosition(at: host)
            guard fresh.isFinite, fresh > cursor + 0.25 else {
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            let mismatches: [(String, ContinuousPCMRenderer.Snapshot)] = [
                ("visit", .init(token: sample.token, frame: sample.frame, visit: sample.visit + 1,
                    ended: sample.ended, underrunFrames: sample.underrunFrames,
                    selectionVersion: sample.selectionVersion)),
                ("selection-version", .init(token: sample.token, frame: sample.frame, visit: sample.visit,
                    ended: sample.ended, underrunFrames: sample.underrunFrames,
                    selectionVersion: sample.selectionVersion + 2))
            ]
            for (kind, other) in mismatches {
                XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(other, hostEnd: 1_000))
                let observed = audio.presentationPosition(at: host)
                XCTAssertEqual(observed, cursor, accuracy: 0.5 / 48_000,
                    "A matching media token does not authorize another visit or consumed selection")
                print("RenderAnchorOwnerMismatch schema=1 kind=\(kind) expectedToken=\(sample.token) expectedVisit=\(sample.visit) expectedSelectionVersion=\(sample.selectionVersion) publishedVisit=\(other.visit) publishedSelectionVersion=\(other.selectionVersion) actual=\(observed) expectedCursor=\(cursor) freshControl=\(fresh) syntheticPublication=true naturallyCapturedInterleaving=false latencyAcceptance=false")
            }
            XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(sample, hostEnd: 1_000))
            XCTAssertGreaterThan(audio.presentationPosition(at: host), cursor + 0.25)
        }
        #else
        XCTFail("Render-anchor owner calibration requires DEBUG")
        #endif
    }

    func testNewSelectionDuringActualLatencyReadPreservesItsPendingPosition() async throws {
        #if DEBUG
        try await withManualAnchorControl("selection-during-latency-read") { audio, sample in
            let owner = audio.graph
            let host = CMTime(seconds: 1_001, preferredTimescale: 1_000_000)
            XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(sample, hostEnd: 1_000))
            guard audio.presentationPosition(at: host) > Double(sample.frame) / 48_000 + 0.25 else {
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            var issued = false
            owner.debugAfterPresentationLatencyRead = {
                owner.debugAfterPresentationLatencyRead = nil
                issued = audio.select(id: "a", position: 0.05)
            }
            defer { owner.debugAfterPresentationLatencyRead = nil }
            let observed = audio.presentationPosition(at: host)
            XCTAssertTrue(issued, "The real same-item selection is issued after the actual SDK getter")
            XCTAssertTrue(audio.isSelectionPending(in: audio.snapshot))
            XCTAssertEqual(observed, 0.05, accuracy: 0.5 / 48_000,
                "An older clock query must preserve the new pending selection on its return")
            XCTAssertEqual(audio.presentationPosition(at: host), 0.05, accuracy: 0.5 / 48_000)
            print("RenderAnchorSelectionDuringRead schema=1 issued=\(issued) actual=\(observed) pendingPosition=0.05 sourceSnapshotUnchanged=true hook=after-actual-SDK-getter naturallyCapturedReentrancy=false latencyAcceptance=false")
        }
        #else
        XCTFail("Render-anchor selection calibration requires DEBUG")
        #endif
    }

    func testAnchorOwnerSupersededDuringActualLatencyReadCannotCreditTheOldClock() async throws {
        #if DEBUG
        try await withManualAnchorControl("anchor-owner-during-latency-read") { audio, sample in
            let owner = audio.graph
            let host = CMTime(seconds: 1_001, preferredTimescale: 1_000_000)
            let cursor = Double(sample.frame) / 48_000
            XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(sample, hostEnd: 1_000))
            guard audio.presentationPosition(at: host) > cursor + 0.25 else {
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            var matchingRepublished = false
            owner.debugAfterPresentationLatencyRead = {
                owner.debugAfterPresentationLatencyRead = nil
                matchingRepublished = owner.debugPublishSyntheticRenderAnchor(sample, hostEnd: 1_000)
            }
            let matching = audio.presentationPosition(at: host)
            XCTAssertTrue(matchingRepublished)
            XCTAssertGreaterThan(matching, cursor + 0.25,
                "A new publication sequence for the matching owner remains authorized")
            let other = ContinuousPCMRenderer.Snapshot(token: sample.token, frame: sample.frame,
                visit: sample.visit + 1, ended: sample.ended, underrunFrames: sample.underrunFrames,
                selectionVersion: sample.selectionVersion)
            var published = false
            owner.debugAfterPresentationLatencyRead = {
                owner.debugAfterPresentationLatencyRead = nil
                published = owner.debugPublishSyntheticRenderAnchor(other, hostEnd: 1_000)
            }
            defer { owner.debugAfterPresentationLatencyRead = nil }
            let observed = audio.presentationPosition(at: host)
            XCTAssertTrue(published)
            XCTAssertEqual(observed, cursor, accuracy: 0.5 / 48_000,
                "Anchor ownership must still match after the actual SDK getter returns")
            XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(sample, hostEnd: 1_000))
            XCTAssertGreaterThan(audio.presentationPosition(at: host), cursor + 0.25)
            print("RenderAnchorOwnerDuringRead schema=1 published=\(published) actual=\(observed) expectedCursor=\(cursor) sourceSnapshotUnchanged=true syntheticPublication=true hook=after-actual-SDK-getter naturallyCapturedInterleaving=false latencyAcceptance=false")
        }
        #else
        XCTFail("Render-anchor interleaving calibration requires DEBUG")
        #endif
    }

    func testAcknowledgedSameTokenSelectionCannotUseThePreviousVisitAnchor() async throws {
        #if DEBUG
        guard Self.unresolvedRenderAnchorCalibrationOwner == nil else {
            XCTFail("An unacknowledged prior owner forbids another calibration")
            throw RenderAnchorCalibrationSetupError.ownerNotClosed
        }
        let accounting = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        let audio = ContinuousAudioPlayer(debugRenderAccounting: accounting)
        Self.unresolvedRenderAnchorCalibrationOwner = audio
        var originalError: Error?, qualified = false
        var before: ContinuousPCMRenderer.Snapshot?, after: ContinuousPCMRenderer.Snapshot?
        var actual: Double?, cursor: Double?, beforeCallbacks: UInt64 = 0, afterCallbacks: UInt64 = 0
        do {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
            audio.setWindow(["a"])
            let entry = try await audio.prepare(id: "a", url: url, currentPriority: true)
            try audio.graph.engine.enableManualRenderingMode(.offline, format: audio.graph.format, maximumFrameCount: 32)
            guard entry.frames > 4_832, audio.select(id: "a", position: 0.1) else {
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            try audio.setPlaying(true)
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.graph.format, frameCapacity: 32))
            guard try audio.graph.engine.renderOffline(32, to: output) == .success else {
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            let old = audio.snapshot, initial = try XCTUnwrap(accounting.snapshot())
            beforeCallbacks = initial.sourceCallbacksEntered
            guard old.token == entry.token, old.visit > 0, old.frame == 4_832,
                  !old.ended, old.underrunFrames == 0, !audio.isSelectionPending(in: old),
                  beforeCallbacks > 0, beforeCallbacks == initial.sourceCallbacksCompleted, !initial.overflowed else {
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            let owner = audio.graph, interval = owner.debugPlayingInterval
            let host = CMTime(seconds: 1_001, preferredTimescale: 1_000_000)
            XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(old, hostEnd: 1_000))
            guard audio.presentationPosition(at: host) > Double(old.frame) / 48_000 + 0.25 else {
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            let publication = owner.debugRenderAnchorPublicationSequence
            guard audio.select(id: "a", position: 0.05) else { throw RenderAnchorCalibrationSetupError.unqualified }
            // One serial manual render owner. Stage the real kernel's publication
            // before the Graph publication, without replacing an SDK callback.
            var step = [Float](repeating: .nan, count: 64)
            step.withUnsafeMutableBufferPointer { audio.renderer.render(interleaved: $0, frameCount: 32) }
            let current = audio.snapshot, final = try XCTUnwrap(accounting.snapshot())
            afterCallbacks = final.sourceCallbacksEntered
            guard current.token == old.token, current.visit == old.visit + 1,
                  current.selectionVersion == old.selectionVersion + 2, current.frame == 2_432,
                  !current.ended, current.underrunFrames == 0, !audio.isSelectionPending(in: current),
                  step.allSatisfy(\.isFinite), step.contains(where: { $0 != 0 }),
                  owner.debugPlayingInterval == interval, owner.debugRenderAnchorPublicationSequence == publication,
                  afterCallbacks == beforeCallbacks, final.sourceCallbacksCompleted == beforeCallbacks, !final.overflowed else {
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            qualified = true; before = old; after = current
            cursor = Double(current.frame) / 48_000
            actual = audio.presentationPosition(at: host)
            XCTAssertEqual(try XCTUnwrap(actual), try XCTUnwrap(cursor), accuracy: 0.5 / 48_000,
                "The real acknowledged same-token selection cannot use its prior visit's anchor")
            XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(current, hostEnd: 1_000))
            XCTAssertGreaterThan(audio.presentationPosition(at: host), try XCTUnwrap(cursor) + 0.25)
            let retained = audio.snapshot, completed = try XCTUnwrap(accounting.snapshot())
            afterCallbacks = completed.sourceCallbacksEntered
            guard retained.token == current.token, retained.visit == current.visit,
                  retained.selectionVersion == current.selectionVersion, retained.frame == current.frame,
                  retained.underrunFrames == 0, afterCallbacks == beforeCallbacks,
                  completed.sourceCallbacksCompleted == beforeCallbacks, !completed.overflowed else {
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            XCTAssertEqual(audio.renderer.retainedPCMMemoryBytes, 6_912_000); XCTAssertEqual(audio.preparedCount, 1)
        } catch { qualified = false; originalError = error }
        audio.graph.debugAfterPresentationLatencyRead = nil
        audio.suspend(); audio.graph.engine.stop()
        let closed = Mutex<Bool?>(nil)
        audio.debugShutdown { value in closed.withLock { $0 = value } }
        let returned = await Self.capCancellationWait(.seconds(3)) { closed.withLock { $0 != nil } }
        let acknowledged = returned && closed.withLock { $0 == true }
        if acknowledged, Self.unresolvedRenderAnchorCalibrationOwner === audio {
            Self.unresolvedRenderAnchorCalibrationOwner = nil
        } else {
            qualified = false
            if originalError == nil { originalError = RenderAnchorCalibrationSetupError.closeUnacknowledged }
        }
        XCTAssertTrue(acknowledged)
        print("RenderAnchorAcknowledgedSelection schema=1 qualified=\(qualified) token=\(before?.token ?? 0) beforeVisit=\(before?.visit ?? 0) afterVisit=\(after?.visit ?? 0) beforeSelectionVersion=\(before?.selectionVersion ?? 0) afterSelectionVersion=\(after?.selectionVersion ?? 0) actual=\(actual.map { String($0) } ?? "unavailable") expectedCursor=\(cursor.map { String($0) } ?? "unavailable") callbackBefore=\(beforeCallbacks) callbackAfter=\(afterCallbacks) closeAcknowledged=\(acknowledged) ownerRetained=\(Self.unresolvedRenderAnchorCalibrationOwner === audio) realKernelStep=true syntheticHostSeed=true naturallyCapturedSDKCallbackInterleaving=false physicalOutput=false latencyAcceptance=false")
        if let originalError { throw originalError }
        #else
        XCTFail("Render-anchor acknowledged selection calibration requires DEBUG")
        #endif
    }


    func testRenderAnchorRejectsOldAndInactivePublicationsAfterResume() async throws {
        #if DEBUG
        try await withManualAnchorControl("old-and-inactive-publication") { audio, sample in
            let owner = audio.graph, interval = owner.debugPlayingInterval
            XCTAssertGreaterThan(interval, 0)
            audio.suspend(); audio.settlePausedState(); try audio.setPlaying(true)
            XCTAssertGreaterThan(owner.debugPlayingInterval, interval)
            let host = CMTime(seconds: 1_001, preferredTimescale: 1_000_000)
            for captured in [interval, UInt64(0)] {
                XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(sample, hostEnd: 1_000,
                    capturedPlayingInterval: captured))
                XCTAssertNil(owner.presentationPosition(token: sample.token, at: host))
                XCTAssertEqual(audio.presentationPosition(at: host), Double(sample.frame) / 48_000,
                    accuracy: 0.5 / 48_000)
            }
            XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(sample, hostEnd: 1_000))
            XCTAssertNotNil(owner.presentationPosition(token: sample.token, at: host))
        }
        #else
        XCTFail("Clock activity calibration requires DEBUG")
        #endif
    }

    func testRepeatedPlayingPreservesAnchorButEngineRestartRequiresFreshInterval() async throws {
        #if DEBUG
        try await withManualAnchorControl("repeated-true-and-engine-restart") { audio, sample in
            let owner = audio.graph, interval = owner.debugPlayingInterval
            let host = CMTime(seconds: 1_001, preferredTimescale: 1_000_000)
            XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(sample, hostEnd: 1_000))
            try audio.setPlaying(true)
            XCTAssertEqual(owner.debugPlayingInterval, interval)
            XCTAssertNotNil(owner.presentationPosition(token: sample.token, at: host))
            owner.engine.stop() // Real stopped-engine recovery with unchanged requested Play.
            try audio.setPlaying(true)
            XCTAssertTrue(owner.engine.isRunning)
            XCTAssertGreaterThan(owner.debugPlayingInterval, interval)
            XCTAssertNil(owner.presentationPosition(token: sample.token, at: host))
            XCTAssertEqual(audio.presentationPosition(at: host), Double(sample.frame) / 48_000,
                accuracy: 0.5 / 48_000)
            XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(sample, hostEnd: 1_000))
            XCTAssertNotNil(owner.presentationPosition(token: sample.token, at: host))
        }
        #else
        XCTFail("Clock activity calibration requires DEBUG")
        #endif
    }

    func testExplicitPauseDuringActualLatencyReadRejectsTheOldClock() async throws {
        #if DEBUG
        try await withManualAnchorControl("pause-after-actual-latency-read") { audio, sample in
            let owner = audio.graph
            let host = CMTime(seconds: 1_001, preferredTimescale: 1_000_000)
            XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(sample, hostEnd: 1_000))
            var entered = false
            owner.debugAfterPresentationLatencyRead = { [weak audio] in
                entered = true; owner.debugAfterPresentationLatencyRead = nil; audio?.suspend()
            }
            defer { owner.debugAfterPresentationLatencyRead = nil }
            XCTAssertEqual(audio.presentationPosition(at: host), Double(sample.frame) / 48_000,
                accuracy: 0.5 / 48_000)
            XCTAssertTrue(entered, "The actual SDK latency getter must return before calibration invalidation")
            XCTAssertEqual(owner.debugPlayingInterval, 0)
            XCTAssertNil(owner.presentationPosition(token: sample.token, at: host))
            audio.settlePausedState(); XCTAssertFalse(owner.engine.isRunning)
        }
        #else
        XCTFail("Clock activity calibration requires DEBUG")
        #endif
    }

    func testReentrantPlaybackControlPreservesNewerPauseResumeAndGraphOwner() async throws {
        #if DEBUG
        try await withManualAnchorControl("reentrant-sdk-boundaries") { audio, sample in
            let owner = audio.graph
            var pauseObserved = false
            audio.debugPlaybackBoundary = { point in
                guard case .playingRunning = point else { return }
                audio.debugPlaybackBoundary = nil; pauseObserved = true; audio.suspend()
            }
            try audio.setPlaying(true)
            XCTAssertTrue(pauseObserved); XCTAssertEqual(owner.debugPlayingInterval, 0)
            audio.settlePausedState(); XCTAssertFalse(owner.engine.isRunning)

            try audio.setPlaying(true); audio.suspend()
            var resumeObserved = false, callbackError: Error?
            audio.debugPlaybackBoundary = { point in
                guard case .pausedRunning = point else { return }
                audio.debugPlaybackBoundary = nil; resumeObserved = true
                do { try audio.setPlaying(true) } catch { callbackError = error }
            }
            audio.settlePausedState()
            if let callbackError { throw callbackError }
            XCTAssertTrue(resumeObserved); XCTAssertTrue(owner.engine.isRunning)
            XCTAssertGreaterThan(owner.debugPlayingInterval, 0)

            audio.suspend(); audio.settlePausedState()
            var failureObserved = false
            audio.debugAfterEngineStart = {
                audio.debugAfterEngineStart = nil
                try audio.setPlaying(false); try audio.setPlaying(true)
                failureObserved = true
                throw AnchorControlCalibrationFailure.syntheticAfterSuccessfulSDKStart
            }
            try audio.setPlaying(true) // The superseded synthetic failure cannot pause the newer resume.
            XCTAssertTrue(failureObserved); XCTAssertTrue(owner.engine.isRunning)
            XCTAssertGreaterThan(owner.debugPlayingInterval, 0)

            var resetObserved = false
            callbackError = nil
            audio.debugPlaybackBoundary = { point in
                guard case .rebuildStopped = point else { return }
                audio.debugPlaybackBoundary = nil; resetObserved = true
                do { try audio.setPlaying(true) } catch { callbackError = error }
            }
            audio.rebuildAfterMediaServicesReset()
            if let callbackError { throw callbackError }
            XCTAssertTrue(resetObserved); XCTAssertTrue(audio.graph === owner)
            XCTAssertTrue(owner.engine.isRunning)
            XCTAssertTrue(owner.debugPublishSyntheticRenderAnchor(sample, hostEnd: 1_000))
            XCTAssertGreaterThan(audio.presentationPosition(at: CMTime(seconds: 1_001, preferredTimescale: 1_000_000)),
                                 Double(sample.frame) / 48_000 + 0.5, "Newer resume retains permission")
            audio.rebuildAfterMediaServicesReset()
            XCTAssertFalse(audio.graph === owner)
            XCTAssertEqual(owner.debugPlayingInterval, 0)
            XCTAssertEqual(audio.graph.debugPlayingInterval, 0)
            XCTAssertNil(owner.presentationPosition(token: sample.token,
                at: CMTime(seconds: 1_001, preferredTimescale: 1_000_000)))
        }
        #else
        XCTFail("Clock activity calibration requires DEBUG")
        #endif
    }

    func testPlaybackClockAuthorityExhaustionCannotReuseAnOldInterval() async throws {
        #if DEBUG
        try await withManualAnchorControl("control-ticket-exhaustion") { audio, sample in
            audio.suspend(); audio.settlePausedState()
            XCTAssertTrue(audio.debugSetInactiveControlTicket(UInt64.max - 2))
            try audio.setPlaying(true)
            XCTAssertEqual(audio.debugPlaybackControlTicket, UInt64.max - 1)
            do { try audio.setPlaying(true); XCTFail("The unissued sentinel must refuse a new operation") }
            catch ContinuousAudioPlayer.PlaybackControlError.authorityExhausted {}
            XCTAssertEqual(audio.debugPlaybackControlTicket, UInt64.max)
            XCTAssertEqual(audio.graph.debugPlayingInterval, 0)
            audio.suspend(); audio.settlePausedState()
            XCTAssertFalse(audio.graph.engine.isRunning)
            XCTAssertEqual(audio.presentationPosition(at: CMTime(seconds: 1_001, preferredTimescale: 1_000_000)),
                Double(sample.frame) / 48_000, accuracy: 0.5 / 48_000)
        }
        try await withManualAnchorControl("render-interval-exhaustion") { audio, _ in
            audio.suspend(); audio.settlePausedState()
            XCTAssertTrue(audio.graph.debugSetInactiveIntervalIssuer(UInt64.max - 2))
            try audio.setPlaying(true)
            XCTAssertEqual(audio.graph.debugPlayingInterval, UInt64.max - 1)
            audio.suspend(); audio.settlePausedState()
            do { try audio.setPlaying(true); XCTFail("An exhausted clock must not reuse its last interval") }
            catch ContinuousAudioPlayer.PlaybackControlError.renderClockExhausted {}
            XCTAssertEqual(audio.graph.debugPlayingInterval, 0)
            audio.suspend(); audio.settlePausedState()
            XCTAssertFalse(audio.graph.engine.isRunning)
        }
        #else
        XCTFail("Clock activity calibration requires DEBUG")
        #endif
    }

    #if DEBUG
    private enum AnchorControlCalibrationFailure: Error { case syntheticAfterSuccessfulSDKStart }
    private func withManualAnchorControl(_ label: String,
        body: @MainActor (ContinuousAudioPlayer, ContinuousPCMRenderer.Snapshot) throws -> Void) async throws {
        guard Self.unresolvedRenderAnchorCalibrationOwner == nil else {
            XCTFail("An unacknowledged prior owner forbids another calibration")
            throw RenderAnchorCalibrationSetupError.ownerNotClosed
        }
        let accounting = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        let audio = ContinuousAudioPlayer(debugRenderAccounting: accounting)
        Self.unresolvedRenderAnchorCalibrationOwner = audio
        var originalError: Error?, sample: ContinuousPCMRenderer.Snapshot?
        var beforeEntered: UInt64 = 0, afterEntered: UInt64 = 0, afterCompleted: UInt64 = 0
        var setup = false
        do {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
            audio.setWindow(["a"])
            let entry = try await audio.prepare(id: "a", url: url, currentPriority: true)
            try audio.graph.engine.enableManualRenderingMode(.offline, format: audio.graph.format, maximumFrameCount: 32)
            guard entry.frames > 4_832, audio.select(id: "a", position: 0.1) else { throw RenderAnchorCalibrationSetupError.unqualified }
            try audio.setPlaying(true)
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.graph.format, frameCapacity: 32))
            guard try audio.graph.engine.renderOffline(32, to: output) == .success else { throw RenderAnchorCalibrationSetupError.unqualified }
            let observed = audio.snapshot, counters = try XCTUnwrap(accounting.snapshot())
            beforeEntered = counters.sourceCallbacksEntered
            guard observed.token == entry.token, observed.visit > 0, observed.frame >= 4_832,
                  !observed.ended, observed.underrunFrames == 0, !audio.isSelectionPending(in: observed),
                  beforeEntered > 0, beforeEntered == counters.sourceCallbacksCompleted, !counters.overflowed else {
                throw RenderAnchorCalibrationSetupError.unqualified
            }
            setup = true; sample = observed
            try body(audio, observed)
            let after = audio.snapshot, finalCounters = try XCTUnwrap(accounting.snapshot())
            afterEntered = finalCounters.sourceCallbacksEntered; afterCompleted = finalCounters.sourceCallbacksCompleted
            XCTAssertEqual(after.token, observed.token); XCTAssertEqual(after.visit, observed.visit)
            XCTAssertEqual(after.selectionVersion, observed.selectionVersion); XCTAssertEqual(after.frame, observed.frame)
            XCTAssertEqual(after.underrunFrames, 0)
            XCTAssertEqual(afterEntered, beforeEntered); XCTAssertEqual(afterCompleted, beforeEntered)
            XCTAssertFalse(finalCounters.overflowed)
            XCTAssertEqual(audio.renderer.retainedPCMMemoryBytes, 6_912_000); XCTAssertEqual(audio.preparedCount, 1)
        } catch { originalError = error }
        audio.debugPlaybackBoundary = nil; audio.debugAfterEngineStart = nil
        audio.graph.debugAfterPresentationLatencyRead = nil
        audio.suspend(); audio.graph.engine.stop()
        let closed = Mutex<Bool?>(nil)
        audio.debugShutdown { value in closed.withLock { $0 = value } }
        let returned = await Self.capCancellationWait(.seconds(3)) { closed.withLock { $0 != nil } }
        let acknowledged = returned && closed.withLock { $0 == true }
        if acknowledged, Self.unresolvedRenderAnchorCalibrationOwner === audio {
            Self.unresolvedRenderAnchorCalibrationOwner = nil
        } else {
            setup = false
            if originalError == nil { originalError = RenderAnchorCalibrationSetupError.closeUnacknowledged }
        }
        XCTAssertTrue(acknowledged)
        print("RenderAnchorLifecycleControl schema=1 label=\(label) setup=\(setup) callbackBefore=\(beforeEntered) callbackAfter=\(afterEntered) completedAfter=\(afterCompleted) token=\(sample?.token ?? 0) frame=\(sample?.frame ?? 0) closeAcknowledged=\(acknowledged) ownerRetained=\(Self.unresolvedRenderAnchorCalibrationOwner === audio) originalErrorRetained=\(originalError != nil) syntheticPublication=true sdkTimestampProof=false sdkBoundaryHooks=after-real-call bodyAssertions=external latencyAcceptance=false")
        if let originalError { throw originalError }
    }

    // One bounded actor-owned retention slot. No automatic late-ACK retry or new owner starts while occupied.
    private static var unresolvedRenderAnchorCalibrationOwner: ContinuousAudioPlayer?
    private enum RenderAnchorCalibrationSetupError: Error { case unqualified, ownerNotClosed, ownerChanged, closeUnacknowledged }
    #endif

    func testCancelledCoalescedPreparationCallersReleaseWhileLegitimateNativeReadIsHeld() async throws {
        #if DEBUG
        try await assertSharedPreparationCancellation(creatorIsCancelled: false)
        #else
        XCTFail("This native cancellation control requires DEBUG gate seams")
        #endif
    }

    func testCancelledPreparationCreatorReleasesWhileLegitimateCoalescedNativeReadIsHeld() async throws {
        #if DEBUG
        try await assertSharedPreparationCancellation(creatorIsCancelled: true)
        #else
        XCTFail("This native cancellation control requires DEBUG gate seams")
        #endif
    }

    func testSameIDSlotWaitersCoalesceAfterTwoNeighbourSlotsAreReleased() async throws {
        #if DEBUG
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var nativePreparationStarted = false
        defer { if !nativePreparationStarted { try? FileManager.default.removeItem(at: directory) } }
        let ids = ["a", "b", "c", "d"]
        let urls = ids.map { directory.appendingPathComponent("slot-\($0).caf") }
        let expected = (0..<257).flatMap { frame -> [Float] in
            let value = Float((frame % 127) - 63) / 128
            return [value, -value]
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        for index in 0..<4 {
            let file = try AVAudioFile(forWriting: urls[index], settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 257))
            buffer.frameLength = 257
            let scale: Float = index == 3 ? 1 : Float(index + 1) / 8
            for frame in 0..<257 {
                buffer.floatChannelData![0][frame] = expected[frame * 2] * scale
                buffer.floatChannelData![1][frame] = expected[frame * 2 + 1] * scale
            }
            try file.write(from: buffer)
        }
        let audio = ContinuousAudioPlayer()
        let gate = ContinuousPCMDecoder.DebugNativeReadGate()
        let run = CAPBusySlotRun()
        let closed = Mutex<Bool?>(nil)
        let memory = audio.renderer.retainedPCMMemoryBytes
        var jobs = [Task<Void, Never>]()
        var cleanupRequested = false
        func makeCaller(_ index: Int, id: String, url: URL) -> Task<Void, Never> {
            Task { @MainActor in
                do { run.entries[index] = try await audio.prepare(id: id, url: url, currentPriority: false) }
                catch { run.failed[index] = true }
                run.finished[index] = true
            }
        }
        defer {
            gate.release(); jobs.forEach { $0.cancel() }
            audio.suspend(); audio.graph.engine.stop()
            if !cleanupRequested { audio.debugShutdown { _ in } }
        }
        var setupError: Error?
        var slotWaitVerified = false, trimVerified = false, exactSamplesVerified = false
        var expectedDToken = 0, heldActive = -1, heldShared = -1, heldReserved = -1, heldNextToken = -1
        var bothPendingWhileHeld = false
        do {
            audio.setWindow(Set(ids))
            for index in 0..<3 {
                nativePreparationStarted = true
                jobs.append(makeCaller(index, id: ids[index], url: urls[index]))
                let ready = await Self.capCancellationWait(.seconds(2)) { run.finished[index] }
                guard ready, !run.failed[index], let entry = run.entries[index],
                      entry.id == ids[index], entry.frames == 257 else {
                    XCTFail("Initial three real preparations must complete before the slot-wait control")
                    throw CAPCancellationSetupError.invalidSetup
                }
            }
            let a = try XCTUnwrap(run.entries[0])
            guard Set(run.entries.prefix(3).compactMap { $0?.slot }).count == 3,
                  audio.preparedCount == 3, audio.select(id: "a") else {
                XCTFail("Three distinct cached slots and a selected A are required")
                throw CAPCancellationSetupError.invalidSetup
            }
            // Consume A's selection while paused: no engine, head consumption,
            // source samples, or real-time pacing is needed to pin its slot.
            audio.renderer.setPlaying(false)
            var paused = [Float](repeating: .nan, count: 2)
            paused.withUnsafeMutableBufferPointer { audio.renderer.render(interleaved: $0, frameCount: 1) }
            let active = audio.snapshot, idle = audio.debugPreparationState
            guard active.token == a.token, active.frame == 0, !active.ended,
                  active.underrunFrames == 0, !audio.isSelectionPending(in: active),
                  paused.allSatisfy({ $0 == 0 }), idle.activeCalls == 0,
                  idle.sharedTasks == 0, idle.reservedSlots == 0, !idle.counterOverflowed else {
                XCTFail("Paused A must actually own the renderer before releasing neighbours")
                throw CAPCancellationSetupError.invalidSetup
            }
            expectedDToken = idle.nextToken
            guard expectedDToken > 0, expectedDToken < Int.max, gate.arm(token: expectedDToken) else {
                throw CAPCancellationSetupError.invalidSetup
            }
            audio.debugSetNativeReadGate(gate)
            jobs.append(makeCaller(3, id: "d", url: urls[3]))
            jobs.append(makeCaller(4, id: "d", url: urls[3]))
            slotWaitVerified = await Self.capCancellationWait(.seconds(1)) {
                let state = audio.debugPreparationState
                return state.activeCalls == 2 && state.sharedTasks == 0 && state.reservedSlots == 0
                    && state.nextToken == expectedDToken && !state.counterOverflowed
                    && audio.preparedCount == 3 && audio.entry(for: "d") == nil
                    && !run.finished[3] && !run.finished[4] && !gate.didEnter
            }
            guard slotWaitVerified else {
                XCTFail("Both actual D calls must wait with three cached slots, zero shared jobs and zero reservations")
                throw CAPCancellationSetupError.invalidSetup
            }
            // The test only resumes after both calls have suspended. Neither
            // can reserve a slot while the main actor synchronously trims B/C.
            audio.setWindow(["a", "d"])
            let trimmed = audio.debugPreparationState
            trimVerified = audio.preparedCount == 1 && audio.entry(for: "a")?.token == a.token
                && audio.entry(for: "b") == nil && audio.entry(for: "c") == nil
                && audio.snapshot.token == a.token && trimmed.activeCalls == 2
                && trimmed.sharedTasks == 0 && trimmed.reservedSlots == 0
                && trimmed.nextToken == expectedDToken && !trimmed.counterOverflowed
            guard trimVerified else {
                XCTFail("Only B/C must retire, freeing two logical slots while A remains active")
                throw CAPCancellationSetupError.invalidSetup
            }
            let entered = await Self.capCancellationWait(.seconds(2)) { gate.isHolding }
            guard entered, !gate.didTimeOut else {
                XCTFail("The first D job must reach its real controlled native-read boundary")
                throw CAPCancellationSetupError.invalidSetup
            }
            let held = audio.debugPreparationState
            heldActive = held.activeCalls; heldShared = held.sharedTasks
            heldReserved = held.reservedSlots; heldNextToken = held.nextToken
            bothPendingWhileHeld = !run.finished[3] && !run.finished[4]
            XCTAssertTrue(gate.isHolding && !gate.didTimeOut)
            XCTAssertTrue(heldActive == 2 && heldShared == 1 && heldReserved == 1
                && heldNextToken == expectedDToken + 1 && bothPendingWhileHeld && !held.counterOverflowed,
                "Slot waiters must recheck/coalesce into exactly one held D job and reservation")
            gate.release()
            let returned = await Self.capCancellationWait(.seconds(2)) { run.finished[3] && run.finished[4] }
            guard returned, !run.failed[3], !run.failed[4],
                  let first = run.entries[3], let second = run.entries[4] else {
                XCTFail("Both D callers must receive the actual prepared source after release")
                throw CAPCancellationSetupError.invalidSetup
            }
            XCTAssertEqual(first.id, "d"); XCTAssertEqual(second.id, "d")
            XCTAssertEqual(first.token, expectedDToken); XCTAssertEqual(second.token, expectedDToken)
            XCTAssertEqual(first.slot, second.slot); XCTAssertEqual(first.frames, 257); XCTAssertEqual(second.frames, 257)
            let final = audio.debugPreparationState
            XCTAssertEqual(final.nextToken, expectedDToken + 1, "A later slot waiter must not allocate a second job")
            XCTAssertEqual(final.activeCalls, 0); XCTAssertEqual(final.sharedTasks, 0); XCTAssertEqual(final.reservedSlots, 0)
            XCTAssertEqual(audio.entry(for: "d")?.token, expectedDToken, "Both finalizers must leave the one D cache entry intact")
            XCTAssertEqual(audio.preparedCount, 2)
            XCTAssertTrue(audio.select(id: "d"))
            audio.renderer.setPlaying(true)
            var rendered = [Float](repeating: .nan, count: expected.count)
            rendered.withUnsafeMutableBufferPointer { audio.renderer.render(interleaved: $0, frameCount: 257) }
            XCTAssertEqual(rendered, expected); XCTAssertTrue(rendered.contains { abs($0) > 0.01 })
            XCTAssertEqual(audio.snapshot.token, expectedDToken); XCTAssertEqual(audio.snapshot.underrunFrames, 0)
            XCTAssertEqual(audio.renderer.retainedPCMMemoryBytes, memory); XCTAssertFalse(gate.didTimeOut)
            exactSamplesVerified = rendered == expected && audio.snapshot.token == expectedDToken
                && audio.snapshot.underrunFrames == 0
        } catch { setupError = error }

        gate.release(); jobs.forEach { $0.cancel() }
        audio.suspend(); audio.graph.engine.stop(); cleanupRequested = true
        audio.debugShutdown { acknowledged in closed.withLock { $0 = acknowledged } }
        let acknowledged = await Self.capCancellationWait(.seconds(3)) { closed.withLock { $0 } != nil }
        XCTAssertTrue(acknowledged && closed.withLock { $0 } == true, "Native lane close must precede fixture deletion")
        let settled = await Self.capCancellationWait(.seconds(1)) {
            let state = audio.debugPreparationState
            return run.finished.prefix(jobs.count).allSatisfy({ $0 }) && state.activeCalls == 0
                && state.sharedTasks == 0 && state.reservedSlots == 0 && !state.counterOverflowed
        }
        XCTAssertTrue(settled, "All launched caller/metadata/shared work must settle before fixture deletion")
        if closed.withLock({ $0 }) == true, settled { try FileManager.default.removeItem(at: directory) }
        print("CAP_BUSY_SLOT_COALESCING slotWaitVerified=\(slotWaitVerified) trimVerified=\(trimVerified) expectedDToken=\(expectedDToken) heldActive=\(heldActive) heldShared=\(heldShared) heldReserved=\(heldReserved) heldNextToken=\(heldNextToken) bothPendingWhileHeld=\(bothPendingWhileHeld) returnedToken0=\(run.entries[3]?.token ?? 0) returnedToken1=\(run.entries[4]?.token ?? 0) finalCachedToken=\(audio.entry(for: "d")?.token ?? 0) finalNextToken=\(audio.debugPreparationState.nextToken) exactSamplesVerified=\(exactSamplesVerified) nativeCloseAcknowledged=\(closed.withLock { $0 } == true) callersSettled=\(settled) gateTimedOut=\(gate.didTimeOut) maximumCallerTasks=5 gateMaximumSeconds=5 retainedPCMBytes=\(memory) sdkRSS=unmeasured latencyFix=false")
        if let setupError { throw setupError }
        #else
        XCTFail("This native slot-wait control requires DEBUG gate seams")
        #endif
    }

    #if DEBUG
    @MainActor private final class CAPBusySlotRun {
        var entries = [ContinuousAudioPlayer.Entry?](repeating: nil, count: 5)
        var finished = [Bool](repeating: false, count: 5)
        var failed = [Bool](repeating: false, count: 5)
    }
    private func assertSharedPreparationCancellation(creatorIsCancelled: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var nativePreparationStarted = false
        defer { if !nativePreparationStarted { try? FileManager.default.removeItem(at: directory) } }
        let url = directory.appendingPathComponent("shared-preparation-b.caf")
        let expected = (0..<257).flatMap { frame -> [Float] in
            let value = Float((frame % 127) - 63) / 128
            return [value, -value]
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 257))
            buffer.frameLength = 257
            for frame in 0..<257 {
                buffer.floatChannelData![0][frame] = expected[frame * 2]
                buffer.floatChannelData![1][frame] = expected[frame * 2 + 1]
            }
            try file.write(from: buffer)
        }
        let audio = ContinuousAudioPlayer()
        let gate = ContinuousPCMDecoder.DebugNativeReadGate()
        let run = CAPPreparationCancellationRun()
        let closed = Mutex<Bool?>(nil)
        var legitimate: Task<Void, Never>?
        var callers = [Task<Void, Never>]()
        func makeLegitimateCaller() -> Task<Void, Never> {
            Task { @MainActor in
                do { run.legitimateEntry = try await audio.prepare(id: "b", url: url) }
                catch { run.legitimateFailed = true }
                run.legitimateFinished = true
            }
        }
        func makeCancelledCaller(_ index: Int) -> Task<Void, Never> {
            Task { @MainActor in
                let witness = CAPPreparationWitness()
                run.witnesses[index].value = witness
                run.entered += 1
                defer {
                    // This task-local reference is deliberately live across
                    // the real prepare await, and is never owned by run.
                    withExtendedLifetime(witness) {}
                    run.finished += 1
                }
                do {
                    _ = try await audio.prepare(id: "b", url: url)
                    run.returnedEntry += 1
                } catch {
                    if error is CancellationError || (error as? ContinuousPCMDecoder.Failure) == .cancelled {
                        run.cancelled += 1
                    } else { run.otherErrors += 1 }
                }
            }
        }
        var cleanupRequested = false
        defer {
            gate.release(); legitimate?.cancel(); callers.forEach { $0.cancel() }
            audio.suspend(); audio.graph.engine.stop()
            if !cleanupRequested {
                // An unexpected exit releases the gate and requests shutdown,
                // but preserves files: this fallback cannot join actor callers.
                audio.debugShutdown { _ in }
            }
        }
        var setupError: Error?
        var coalescedSetupVerified = false, exactSamplesVerified = false
        var firstCallerRoleVerified = false, legitimateJoinedSecond = false
        var heldFinished = -1, heldCancelled = -1, heldLiveWitnesses = -1, heldActiveCalls = -1
        let token = audio.debugPreparationState.nextToken
        do {
            // Retain B throughout; cancellation of eight callers must not be
            // confused with setWindow cancelling the one legitimate producer.
            audio.setWindow(["b"])
            guard gate.arm(token: token) else { throw CAPCancellationSetupError.invalidSetup }
            audio.debugSetNativeReadGate(gate)
            nativePreparationStarted = true
            if creatorIsCancelled { callers.append(makeCancelledCaller(0)) }
            else { legitimate = makeLegitimateCaller() }
            let entered = await Self.capCancellationWait(.seconds(2)) { gate.isHolding }
            let initial = audio.debugPreparationState
            guard entered, !gate.didTimeOut, initial.activeCalls == 1,
                  initial.sharedTasks == 1, initial.reservedSlots == 1,
                  !initial.counterOverflowed, audio.preparedCount == 0,
                  !run.legitimateFinished else {
                XCTFail("Setup must hold B's first real native read before any prefix publication")
                throw CAPCancellationSetupError.invalidSetup
            }
            // No second task exists before this real native hold/one-call
            // checkpoint, so the first task's creator role is established.
            firstCallerRoleVerified = creatorIsCancelled
                ? callers.count == 1 && legitimate == nil && run.entered == 1 && run.liveWitnesses == 1
                : callers.isEmpty && legitimate != nil && run.entered == 0 && run.liveWitnesses == 0
            guard firstCallerRoleVerified else {
                XCTFail("The first held CAP caller must have the scenario's actual creator role")
                throw CAPCancellationSetupError.invalidSetup
            }
            if creatorIsCancelled {
                legitimate = makeLegitimateCaller()
                let joined = await Self.capCancellationWait(.seconds(1)) {
                    audio.debugPreparationState.activeCalls == 2
                }
                let joinedState = audio.debugPreparationState
                guard joined, gate.isHolding, !gate.didTimeOut,
                      joinedState.sharedTasks == 1, joinedState.reservedSlots == 1,
                      !joinedState.counterOverflowed, !run.legitimateFinished,
                      run.entered == 1, run.liveWitnesses == 1, run.finished == 0 else {
                    XCTFail("Legitimate caller must join the held creator before the remaining seven callers exist")
                    throw CAPCancellationSetupError.invalidSetup
                }
                legitimateJoinedSecond = true
            }
            let firstCoalescedIndex = creatorIsCancelled ? 1 : 0
            for index in firstCoalescedIndex..<8 {
                callers.append(makeCancelledCaller(index))
            }
            let registered = await Self.capCancellationWait(.seconds(1)) {
                run.entered == 8 && run.liveWitnesses == 8 && audio.debugPreparationState.activeCalls == 9
            }
            let registeredState = audio.debugPreparationState
            guard registered, gate.isHolding, !gate.didTimeOut,
                  registeredState.sharedTasks == 1, registeredState.reservedSlots == 1,
                  !registeredState.counterOverflowed else {
                XCTFail("All eight cancellation-target callers must actually enter the same held preparation")
                throw CAPCancellationSetupError.invalidSetup
            }
            coalescedSetupVerified = true
            callers.forEach { $0.cancel() }
            let cancelledWhileHeld = await Self.capCancellationWait(.milliseconds(250)) {
                let state = audio.debugPreparationState
                return run.finished == 8 && run.cancelled == 8 && run.liveWitnesses == 0
                    && run.returnedEntry == 0 && run.otherErrors == 0
                    && state.activeCalls == 1 && state.sharedTasks == 1 && state.reservedSlots == 1
                    && !state.counterOverflowed && !run.legitimateFinished
            }
            heldFinished = run.finished; heldCancelled = run.cancelled
            heldLiveWitnesses = run.liveWitnesses; heldActiveCalls = audio.debugPreparationState.activeCalls
            XCTAssertTrue(gate.isHolding && !gate.didTimeOut, "The cancellation observation must finish before gate release/timeout")
            XCTAssertTrue(cancelledWhileHeld,
                "All eight canceled callers must finish and release task-local owners while legitimate B remains held")

            // Do not throw at the expected RED: still validate real completion,
            // complete PCM and native close, and safely clean up the owned file.
            gate.release()
            let completed = await Self.capCancellationWait(.seconds(2)) {
                run.legitimateFinished && run.finished == 8
            }
            guard completed, !run.legitimateFailed, let entry = run.legitimateEntry else {
                XCTFail("Released legitimate preparation and every registered caller must settle")
                throw CAPCancellationSetupError.invalidSetup
            }
            XCTAssertEqual(entry.id, "b"); XCTAssertEqual(entry.token, token)
            XCTAssertEqual(entry.frames, 257); XCTAssertFalse(gate.didTimeOut)
            XCTAssertEqual(audio.debugPreparationState.activeCalls, 0)
            XCTAssertEqual(audio.debugPreparationState.sharedTasks, 0)
            XCTAssertEqual(audio.debugPreparationState.reservedSlots, 0)
            XCTAssertEqual(run.liveWitnesses, 0)
            XCTAssertTrue(audio.select(id: "b"))
            audio.renderer.setPlaying(true)
            var rendered = [Float](repeating: .nan, count: expected.count)
            rendered.withUnsafeMutableBufferPointer { audio.renderer.render(interleaved: $0, frameCount: 257) }
            XCTAssertEqual(rendered, expected, "The legitimate caller must receive every actual source sample")
            XCTAssertTrue(rendered.contains { abs($0) > 0.01 })
            XCTAssertEqual(audio.snapshot.token, token); XCTAssertEqual(audio.snapshot.underrunFrames, 0)
            exactSamplesVerified = rendered == expected && audio.snapshot.token == token
                && audio.snapshot.underrunFrames == 0 && entry.frames == 257
        } catch { setupError = error }

        gate.release(); legitimate?.cancel(); callers.forEach { $0.cancel() }
        audio.suspend(); audio.graph.engine.stop()
        cleanupRequested = true
        audio.debugShutdown { acknowledged in closed.withLock { $0 = acknowledged } }
        let acknowledged = await Self.capCancellationWait(.seconds(3)) { closed.withLock { $0 } != nil }
        XCTAssertTrue(acknowledged && closed.withLock { $0 } == true,
            "Owned fixture deletion requires the real reader-lane close acknowledgement")
        let callersSettled = await Self.capCancellationWait(.seconds(1)) {
            let state = audio.debugPreparationState
            return (legitimate == nil || run.legitimateFinished)
                && run.finished == callers.count && run.liveWitnesses == 0
                && state.activeCalls == 0 && state.sharedTasks == 0 && state.reservedSlots == 0
                && !state.counterOverflowed
        }
        XCTAssertTrue(callersSettled, "No registered caller may survive test cleanup")
        // A missing/false ACK intentionally retains the UUID-owned fixture;
        // even a failed test never deletes media beneath outstanding SDK work.
        if closed.withLock({ $0 }) == true, callersSettled { try FileManager.default.removeItem(at: directory) }
        let prefix = creatorIsCancelled ? "CAP_SHARED_PREPARATION_CREATOR_CANCELLATION" : "CAP_SHARED_PREPARATION_CANCELLATION"
        print("\(prefix) creatorIsCancelled=\(creatorIsCancelled) firstCallerRoleVerified=\(firstCallerRoleVerified) legitimateJoinedSecond=\(legitimateJoinedSecond) expectedCallers=8 enteredCallers=\(run.entered) coalescedSetupVerified=\(coalescedSetupVerified) heldFinished=\(heldFinished) heldCancelled=\(heldCancelled) heldLiveWitnesses=\(heldLiveWitnesses) heldActiveCalls=\(heldActiveCalls) finalFinished=\(run.finished) finalReturnedEntry=\(run.returnedEntry) finalOtherErrors=\(run.otherErrors) nativeCloseAcknowledged=\(closed.withLock { $0 } == true) callersSettled=\(callersSettled) gateTimedOut=\(gate.didTimeOut) cancellationMaximumMilliseconds=250 gateMaximumSeconds=5 expectedFrames=257 exactSamplesVerified=\(exactSamplesVerified) resourceScope=caller-lifetimes-not-RSS latencyFix=false")
        if let setupError { throw setupError }
    }

    private enum CAPCancellationSetupError: Error { case invalidSetup }
    private final class CAPPreparationWitness {}
    @MainActor private final class CAPWeakPreparationWitness {
        weak var value: CAPPreparationWitness?
    }
    @MainActor private final class CAPPreparationCancellationRun {
        let witnesses = (0..<8).map { _ in CAPWeakPreparationWitness() }
        var entered = 0, finished = 0, cancelled = 0, returnedEntry = 0, otherErrors = 0
        var legitimateFinished = false, legitimateFailed = false
        var legitimateEntry: ContinuousAudioPlayer.Entry?
        var liveWitnesses: Int { witnesses.filter { $0.value != nil }.count }
    }
    private static func capCancellationWait(_ duration: Duration, until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: duration)
        while !condition(), clock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(2)) }
            catch { return false }
        }
        return condition()
    }
    #endif

    func testColdDeselectionRejectsDelayedOldFailureAndPublishesSilenceBeforeRetry() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let audio = ContinuousAudioPlayer()
        defer { audio.suspend(); audio.graph.engine.stop() }
        audio.setWindow(["a", "b"])
        let a = try await audio.prepare(id: "a", url: url)
        XCTAssertTrue(audio.select(id: "a", position: 0.1))
        audio.renderer.setPlaying(true)
        var samples = [Float](repeating: 0, count: 64)
        samples.withUnsafeMutableBufferPointer { audio.renderer.render(interleaved: $0, frameCount: 32) }
        XCTAssertEqual(audio.snapshot.token, a.token)

        audio.clearSelection()
        XCTAssertFalse(audio.isSelected)
        XCTAssertTrue(audio.isSelectionPending(in: audio.snapshot), "The render thread must acknowledge deselection")
        XCTAssertFalse(audio.invalidateForRetry(token: a.token), "A delayed A failure cannot own the requested cold selection")
        samples.withUnsafeMutableBufferPointer { audio.renderer.render(interleaved: $0, frameCount: 32) }
        XCTAssertEqual(audio.snapshot.token, 0)
        XCTAssertFalse(audio.isSelectionPending(in: audio.snapshot))
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
        audio.settlePausedState()
        XCTAssertFalse(audio.graph.engine.isRunning)

        let b = try await audio.prepare(id: "b", url: url)
        XCTAssertTrue(audio.select(id: "b", position: 0.1))
        audio.renderer.setPlaying(true)
        samples.withUnsafeMutableBufferPointer { audio.renderer.render(interleaved: $0, frameCount: 32) }
        XCTAssertEqual(audio.snapshot.token, b.token)
        XCTAssertNotEqual(audio.snapshot.token, a.token)
        XCTAssertTrue(samples.contains { abs($0) > 0.001 })
    }

    func testObsoleteFailureCannotRemoveTheCurrentPreparedLoop() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let audio = ContinuousAudioPlayer()
        defer { audio.suspend(); audio.graph.engine.stop() }
        audio.setWindow(["a", "b"])
        let a = try await audio.prepare(id: "a", url: url)
        let b = try await audio.prepare(id: "b", url: url, currentPriority: true)
        try audio.graph.engine.enableManualRenderingMode(.offline, format: audio.graph.format, maximumFrameCount: 32)
        XCTAssertTrue(audio.select(id: "b", position: Double(b.frames - 1) / 48_000))
        try audio.setPlaying(true)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.graph.format, frameCapacity: 32))
        XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
        audio.setWindow(["b"])
        XCTAssertNil(audio.entry(forToken: a.token))
        audio.follow(from: "b", to: "b")
        XCTAssertFalse(audio.invalidateForRetry(token: a.token), "A callback queued before retirement is obsolete")
        let visit = audio.snapshot.visit
        XCTAssertEqual(try audio.graph.engine.renderOffline(3, to: output), .success)
        XCTAssertGreaterThan(audio.snapshot.visit, visit)
        XCTAssertFalse(audio.snapshot.ended)
        XCTAssertEqual(audio.snapshot.token, b.token)
        XCTAssertEqual(audio.snapshot.underrunFrames, 0)
    }

    func testDecodeFailureUsesPendingSelectionOrActualNaturalSuccessor() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        for explicitSelection in [true, false] {
            let audio = ContinuousAudioPlayer()
            defer { audio.suspend(); audio.graph.engine.stop() }
            audio.setWindow(["a", "b"])
            let a = try await audio.prepare(id: "a", url: url, currentPriority: true)
            let b = try await audio.prepare(id: "b", url: url)
            try audio.graph.engine.enableManualRenderingMode(.offline, format: audio.graph.format, maximumFrameCount: 32)
            XCTAssertTrue(audio.select(id: "a"))
            try audio.setPlaying(true)
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.graph.format, frameCapacity: 32))
            XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
            if explicitSelection {
                XCTAssertTrue(audio.select(id: "b"))
                XCTAssertFalse(audio.invalidateForRetry(token: a.token), "A delayed old-current failure cannot cancel requested B")
                XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
                XCTAssertEqual(audio.snapshot.token, b.token)
                XCTAssertGreaterThan(audio.snapshot.frame, 0)
                XCTAssertTrue(audio.graph.engine.isRunning)
            } else {
                audio.follow(from: "a", to: "b")
                XCTAssertTrue(audio.select(id: "a", position: Double(a.frames - 1) / 48_000))
                XCTAssertEqual(try audio.graph.engine.renderOffline(3, to: output), .success)
                XCTAssertEqual(audio.snapshot.token, b.token)
                XCTAssertEqual(audio.selectedID, "a", "The natural boundary precedes the service poll")
                XCTAssertTrue(audio.invalidateForRetry(token: b.token), "The actual natural successor's failure must stop it")
                XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
                audio.settlePausedState()
                XCTAssertFalse(audio.graph.engine.isRunning)
            }
        }
    }

    func testInvalidatingAPendingSelectionLetsTheSilentEngineSettle() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let audio = ContinuousAudioPlayer()
        audio.setWindow(["a"])
        let entry = try await audio.prepare(id: "a", url: url, currentPriority: true)
        try audio.graph.engine.enableManualRenderingMode(.offline, format: audio.graph.format, maximumFrameCount: 32)
        XCTAssertTrue(audio.select(id: "a"))
        try audio.setPlaying(true)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.graph.format, frameCapacity: 32))
        XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
        _ = audio.seek(0.1)
        XCTAssertTrue(audio.isSelectionPending(in: audio.snapshot))
        XCTAssertTrue(audio.invalidateForRetry(token: entry.token))
        XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
        XCTAssertEqual(audio.snapshot.token, 0)
        XCTAssertFalse(audio.isSelectionPending(in: audio.snapshot))
        audio.settlePausedState()
        XCTAssertFalse(audio.graph.engine.isRunning)
    }

    func testNewCurrentEvictsANeighbourRatherThanWaitingForeverForOldCurrent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
            buffer.frameLength = 128
            for frame in 0..<128 { buffer.floatChannelData![0][frame] = 0.1; buffer.floatChannelData![1][frame] = -0.1 }
            try file.write(from: buffer)
        }
        let audio = ContinuousAudioPlayer()
        audio.setWindow(["a", "b", "c"])
        _ = try await audio.prepare(id: "b", url: url, currentPriority: true)
        _ = try await audio.prepare(id: "a", url: url)
        _ = try await audio.prepare(id: "c", url: url)
        XCTAssertTrue(audio.select(id: "b"))
        var sample = [Float](repeating: 0, count: 2)
        sample.withUnsafeMutableBufferPointer { audio.renderer.render(interleaved: $0, frameCount: 1) }
        audio.setWindow(["a", "d", "c"])
        let prepared = try await audio.prepare(id: "d", url: url, currentPriority: true)
        XCTAssertEqual(prepared.id, "d")
        XCTAssertEqual(audio.preparedCount, 3)
        XCTAssertTrue(audio.select(id: "d", position: 0.001))
        // The engine has not started: paused presentation still uses requested time.
        XCTAssertEqual(audio.presentationPosition(at: CMClockGetTime(CMClockGetHostTimeClock())), 0.001, accuracy: 0.000001)
        audio.trimWindow(preserving: "d")
        XCTAssertNotNil(audio.entry(for: "d"))
        try audio.graph.engine.enableManualRenderingMode(.offline, format: audio.graph.format, maximumFrameCount: 32)
        try audio.setPlaying(true)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.graph.format, frameCapacity: 32))
        XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
        audio.suspend()
        let pausedFrame = audio.snapshot.frame
        XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
        audio.settlePausedState()
        XCTAssertFalse(audio.graph.engine.isRunning, "Explicit Pause must not leave a silent background engine running")
        XCTAssertEqual(audio.snapshot.frame, pausedFrame)
    }
}
