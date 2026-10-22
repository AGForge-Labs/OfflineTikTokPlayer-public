import XCTest
import SwiftUI
import UIKit
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreFoundation
import CoreVideo
import PlayerCore
@testable import OfflineTikTokPlayer

/// Service/render integration regressions. The opaque magenta poster deliberately differs from
/// both generated movies, so a decoded asset or advancing audio clock cannot satisfy visibility.
@MainActor
final class PlaybackSelectionVideoRegressionTests: XCTestCase {
    // Stop targeted arms from creating more owners after an unacknowledged close.
    private static var targetedFixtureOwnershipLost = false
    private static var preparedPrerollToken: UInt64 = 0
    private static var unresolvedPreparedPrerollOwner: PreparedNextPrerollOwner?
    // One test-module nonce per app process, not an operating-system birth timestamp.
    private static let runtimeHostModuleNonce = UUID().uuidString.lowercased()
    private var prerollCaseStartUTC: String?
    #if DEBUG
    // Test-only immutable per-arm input to the unchanged benchmark signature.
    private var acceptedPCMOriginBenchmarkMode: Bool?
    #endif

    private func recordRuntimeHost() throws {
        let process = ProcessInfo.processInfo
        var receipt: [String: Any] = ["schema": 1,
            "simulatorUDID": process.environment["SIMULATOR_UDID"] ?? "unknown",
            "pid": Int(process.processIdentifier),
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "moduleNonce": Self.runtimeHostModuleNonce, "testName": self.name]
        if let prerollCaseStartUTC { receipt["caseStartUTC"] = prerollCaseStartUTC }
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print("NativeRuntimeHost " + String(decoding: data, as: UTF8.self))
    }
    func testOrdinaryVideoDriftUsesItemTimebaseAndPreservesForcedOwnership() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await requireNativeClockContractOwner(service, fixture: fixture, audio: audio, screen: screen, id: fixture.aID)
            try await require({ buffer.hasPrepared(fixture.bID) }, "Real B must be staged before the owner-reentry control")
            service.pause()
            try await require({ service.player.rate == 0 && !service.audioEngineRunning
                && service.debugInitialVideoReadyState.syncingVideoGeneration == nil }, "A must settle paused")
            let item = try XCTUnwrap(service.player.currentItem)
            let itemID = ObjectIdentifier(item)
            var reads: [PlaybackService.DebugVideoPositionRead] = []
            var attempts: [PlaybackService.DebugVideoPositionReadKind] = []
            var seeks: [PlaybackService.DebugVideoSeekStamp] = []
            var overflow = false
            defer {
                service.onDebugVideoPositionReadAttempt = nil; service.onDebugVideoPositionRead = nil
                service.onDebugVideoSeekStamp = nil
            }
            service.onDebugVideoSeekStamp = { stamp in
                if seeks.count < 16 { seeks.append(stamp) } else { overflow = true }
            }
            service.onDebugVideoPositionReadAttempt = { kind, raw in
                XCTAssertEqual(raw, itemID)
                if attempts.count < 4 { attempts.append(kind) } else { overflow = true }
            }
            service.onDebugVideoPositionRead = { read in
                if reads.count < 4 { reads.append(read) } else { overflow = true }
            }
            service.debugSynchronizeVideoToAudio()
            service.onDebugVideoPositionReadAttempt = nil; service.onDebugVideoPositionRead = nil
            // Synchronous assertions cannot accidentally count a later automatic poll.
            XCTAssertEqual(attempts, [.itemTimebase], "Ordinary service drift must use the real item's timebase")
            XCTAssertEqual(reads.count, 1)
            if let read = reads.first {
                XCTAssertEqual(read.kind, .itemTimebase); XCTAssertEqual(read.item, itemID)
                XCTAssertEqual(read.request, read.returnGeneration)
                XCTAssertTrue(read.observedItemMatches); XCTAssertTrue(read.presentationUnchanged)
                XCTAssertGreaterThanOrEqual(read.returnNs, read.entryNs); XCTAssertTrue(read.position.isFinite)
                print("NativePositionSourceContract kind=\(read.kind.rawValue) request=\(read.request) item=\(read.item) entryNs=\(read.entryNs) returnNs=\(read.returnNs) position=\(read.position)")
            }

            try await require({ service.debugInitialVideoReadyState.syncingVideoGeneration == nil },
                              "Any ordinary correction must finish before the independent forced control")
            let submitted = service.submittedVideoFrameCount
            var forcedReads = 0
            service.onDebugVideoPositionReadAttempt = { _, _ in forcedReads += 1 }
            service.seek(0.65)
            service.onDebugVideoPositionReadAttempt = nil
            XCTAssertEqual(forcedReads, 0, "A forced paused seek must bypass both ordinary position APIs")
            XCTAssertTrue(seeks.contains { $0.force && $0.reason == .userPausedSeek
                && abs($0.requestedPosition - 0.65) < 0.5 / 48_000 })
            try await require({
                service.debugInitialVideoReadyState.syncingVideoGeneration == nil
                    && abs(service.player.currentTime().seconds - 0.65) < 0.04
                    && service.submittedVideoFrameCount > submitted
                    && service.videoFramePositionSeconds.map { abs($0 - 0.65) < 0.08 } == true
            }, "The forced command must complete a real paused native seek and submit its target")
            XCTAssertFalse(service.wantsToPlay); XCTAssertFalse(service.audioEngineRunning)

            let oldRequest = service.debugInitialVideoReadyState.generation
            var changedOwner = false
            let seekStart = seeks.count
            service.onDebugVideoPositionReadAttempt = { _, raw in
                guard !changedOwner else { return }
                XCTAssertEqual(raw, itemID); changedOwner = true
                service.start(playlistIDs: [fixture.playlist], at: fixture.bID)
            }
            service.debugSynchronizeVideoToAudio()
            service.onDebugVideoPositionReadAttempt = nil
            XCTAssertTrue(changedOwner)
            XCTAssertGreaterThan(service.debugInitialVideoReadyState.generation, oldRequest)
            XCTAssertFalse(seeks.dropFirst(seekStart).contains { $0.request == oldRequest },
                           "A source changed at the actual read boundary must reject the old correction")
            try await requireNativeClockContractOwner(service, fixture: fixture, audio: audio, screen: screen, id: fixture.bID)
            XCTAssertFalse(overflow); XCTAssertLessThanOrEqual(reads.count, 4); XCTAssertLessThanOrEqual(seeks.count, 16)
        }
        #else
        XCTFail("Native position contracts require DEBUG seams")
        #endif
    }

    func testOrdinaryDriftRejectsStoppedNativeClockAndPreservesForcedRecovery() async throws {
        #if DEBUG
        var setupReceipt: String?
        defer { if let setupReceipt { print(setupReceipt) } }
        try await withOwnedNaturalFixture { fixture, audio, service, screen in
            let setupDeadline = ProcessInfo.processInfo.systemUptime + 3
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await requireNativeClockContractOwner(service, fixture: fixture, audio: audio, screen: screen, id: fixture.aID)
            let item = try XCTUnwrap(service.player.currentItem)
            let timebase = try XCTUnwrap(item.timebase)
            let setupState = service.debugInitialVideoReadyState
            let setupOwner = service.debugAlignedVideoPollState
            let setupSample = audio.renderer.snapshot
            var reads: [PlaybackService.DebugVideoPositionRead] = []
            var seeks: [PlaybackService.DebugVideoSeekStamp] = []
            var overflow = false
            defer { service.onDebugVideoPositionRead = nil; service.onDebugVideoSeekStamp = nil }

            // Keep the real PCM engine running and the playback intent unchanged.
            // This isolated control deliberately withholds MainActor polling for
            // one fixed 200 ms sleep; no CPU spin or benchmark budget is changed.
            service.player.pause()
            let pauseReturnNativeRate = CMTimebaseGetEffectiveRate(timebase)
            var qualificationRate: Double?, qualificationOwner = false, qualifiedWithinDeadline = false
            let stoppedSetup = await waitUntil(timeout: max(0, setupDeadline - ProcessInfo.processInfo.systemUptime)) {
                qualifiedWithinDeadline = ProcessInfo.processInfo.systemUptime < setupDeadline
                guard qualifiedWithinDeadline else { return false }
                guard service.player.currentItem === item, let currentTimebase = item.timebase,
                      currentTimebase === timebase else { qualificationOwner = false; return false }
                qualificationRate = CMTimebaseGetEffectiveRate(currentTimebase)
                let state = service.debugInitialVideoReadyState, owner = service.debugAlignedVideoPollState
                let sample = audio.renderer.snapshot
                qualificationOwner = state.generation == setupState.generation
                    && state.readyGeneration == state.generation && state.syncingVideoGeneration == nil
                    && owner.generation == setupOwner.generation && owner.request == setupOwner.request
                    && setupOwner.frame.ticket != nil && owner.frame.ticket == setupOwner.frame.ticket
                    && setupOwner.frame.output != nil && owner.frame.output == setupOwner.frame.output
                    && owner.presentationMatches && owner.observedItemMatches && owner.frame.coherent
                    && owner.frame.activeSeekTicket == nil && owner.frame.seekSerial == setupOwner.frame.seekSerial
                    && service.queue.currentID == fixture.aID && audio.selectedID == fixture.aID
                    && audio.entry(for: fixture.aID)?.token == sample.token && sample.token == setupSample.token
                    && sample.visit == setupSample.visit && sample.selectionVersion == setupSample.selectionVersion
                    && !sample.ended && !audio.isSelectionPending(in: sample)
                    && service.wantsToPlay && service.audioEngineRunning && !service.isLoading && !service.audioOnly
                qualifiedWithinDeadline = ProcessInfo.processInfo.systemUptime < setupDeadline
                return qualificationOwner && qualificationRate == 0 && qualifiedWithinDeadline
            }
            setupReceipt = "StoppedNativeClockSetup schema=1 qualified=\(stoppedSetup) ownerMatches=\(qualificationOwner) withinDeadline=\(qualifiedWithinDeadline) pauseReturnEffectiveRate=\(pauseReturnNativeRate) qualificationEffectiveRate=\(qualificationRate.map { String($0) } ?? "missing") request=\(setupState.generation) token=\(setupSample.token) visit=\(setupSample.visit) selectionVersion=\(setupSample.selectionVersion) setupBudgetMs=3000 boundedMainActorHoldMs=200 latencyAcceptance=false"
            XCTAssertTrue(stoppedSetup, "The exact current owner must settle to a real stopped native clock within the original setup deadline")
            guard stoppedSetup else { throw SelectionVideoTestFailure.timeout }
            let initialNativeRate = CMTimebaseGetEffectiveRate(timebase)
            if let receipt = setupReceipt { setupReceipt = receipt + " preHoldEffectiveRate=\(initialNativeRate)" }
            XCTAssertEqual(initialNativeRate, 0)
            guard initialNativeRate == 0 else { throw SelectionVideoTestFailure.timeout }
            // Automatic polls during setup are not the isolated measured read.
            // Install the original bounded observers only after setup qualifies.
            service.onDebugVideoPositionRead = { value in
                if reads.count < 8 { reads.append(value) } else { overflow = true }
            }
            service.onDebugVideoSeekStamp = { value in
                if seeks.count < 8 { seeks.append(value) } else { overflow = true }
            }
            let before = audio.renderer.snapshot
            holdMainActorForStoppedNativeClockControl()
            let after = audio.renderer.snapshot
            let native = CMTimebaseGetTime(timebase).seconds
            let goal = audio.presentationPosition(at: CMClockGetTime(CMClockGetHostTimeClock()))
            XCTAssertTrue(service.wantsToPlay); XCTAssertTrue(service.audioEngineRunning)
            XCTAssertEqual(before.token, after.token); XCTAssertEqual(before.visit, after.visit)
            XCTAssertGreaterThan(Double(after.frame - before.frame) / 48_000, 0.080)
            XCTAssertEqual(after.underrunFrames, before.underrunFrames)
            XCTAssertTrue(native.isFinite && goal.isFinite)
            XCTAssertGreaterThan(goal - native, 0.080, "The real stopped clock must exceed the unchanged drift threshold")
            let stoppedNativeRate = CMTimebaseGetEffectiveRate(timebase)
            XCTAssertEqual(stoppedNativeRate, 0)
            service.debugSynchronizeVideoToAudio()
            XCTAssertEqual(reads.count, 1)
            XCTAssertEqual(reads.first?.itemTimebaseEffectiveRate, 0)
            XCTAssertTrue(reads.first?.position.isNaN == true,
                          "A stopped playing clock is unavailable for ordinary drift comparison")
            XCTAssertEqual(seeks.count, 0, "Waiting for a native clock must not flush a current frame through a drift seek")
            XCTAssertNil(service.debugInitialVideoReadyState.syncingVideoGeneration)
            let stoppedPhaseSeeks = seeks.count

            let submitted = service.submittedVideoFrameCount
            let readCount = reads.count
            service.debugSynchronizeVideoToAudio(force: true)
            XCTAssertEqual(reads.count, readCount, "Explicit recovery must retain its ordinary-clock bypass")
            XCTAssertEqual(seeks.filter(\.force).count, 1)
            service.onDebugVideoPositionRead = nil
            var recoveredActualFrame = false
            try await require({
                guard service.player.currentItem === item, let currentTimebase = item.timebase,
                      let frame = service.videoFramePositionSeconds else { return false }
                let freshGoal = audio.presentationPosition(at: CMClockGetTime(CMClockGetHostTimeClock()))
                let recovered = service.debugInitialVideoReadyState.syncingVideoGeneration == nil
                    && CMTimebaseGetEffectiveRate(currentTimebase) > 0
                    && service.submittedVideoFrameCount > submitted && abs(frame - freshGoal) <= 0.080
                if recovered { recoveredActualFrame = true }
                return recovered
            }, "A forced actual native seek must recover advancing, newly submitted video")
            service.onDebugVideoPositionRead = { value in
                if reads.count < 8 { reads.append(value) } else { overflow = true }
            }
            service.debugSynchronizeVideoToAudio()
            service.onDebugVideoPositionRead = nil
            XCTAssertEqual(reads.count, readCount + 1)
            XCTAssertTrue(reads.last?.position.isFinite == true)
            XCTAssertGreaterThan(reads.last?.itemTimebaseEffectiveRate ?? -.infinity, 0,
                                 "An actually advancing playing clock must remain available for drift correction")
            XCTAssertFalse(overflow); XCTAssertLessThanOrEqual(reads.count, 8); XCTAssertLessThanOrEqual(seeks.count, 8)
            print("StoppedNativeClockControl schema=1 native=\(native) audioGoal=\(goal) beforeFrame=\(before.frame) afterFrame=\(after.frame) initialEffectiveRate=\(initialNativeRate) stoppedEffectiveRate=\(stoppedNativeRate) stoppedOrdinarySeeks=\(stoppedPhaseSeeks) forcedSeekObserved=\(seeks.contains(where: \.force)) recoveredActualFrame=\(recoveredActualFrame) boundedMainActorHoldMs=200 latencyAcceptance=false")
        }
        #else
        XCTFail("Stopped native clock contract requires DEBUG ownership seams")
        #endif
    }

    #if DEBUG
    private func holdMainActorForStoppedNativeClockControl() {
        Thread.sleep(forTimeInterval: 0.2)
    }
    #endif

    func testPeriodicVideoClockSkipsPCMAndPreservesLegacyOwnership() async throws {
        #if DEBUG
        try await withOwnedNaturalFixture { fixture, audio, service, screen in
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await requireNativeClockContractOwner(service, fixture: fixture, audio: audio, screen: screen, id: fixture.aID)
            service.pause()
            try await require({ service.player.rate == 0 && !service.audioEngineRunning
                && service.debugInitialVideoReadyState.syncingVideoGeneration == nil }, "A must settle paused")
            let item = try XCTUnwrap(service.player.currentItem)
            let native = item.currentTime().seconds
            XCTAssertTrue(native.isFinite && native >= 0 && native < 30)
            let sentinel = native < 15 ? 25.0 : 1.0
            XCTAssertGreaterThan(abs(sentinel - native), 1)
            let raw = ObjectIdentifier(item)
            var attempts = 0
            defer { service.onDebugPeriodicCurrentItemReadAttempt = nil }
            service.clock.reset(position: sentinel, duration: 30)
            service.onDebugPeriodicCurrentItemReadAttempt = { observed in XCTAssertEqual(observed, raw); attempts += 1 }
            service.debugSampleNativeVideoClock()
            service.onDebugPeriodicCurrentItemReadAttempt = nil
            let pcmReads = attempts
            XCTAssertEqual(attempts, 0, "PCM-selected periodic callbacks must not query native ownership")
            XCTAssertEqual(service.clock.position, sentinel)

            // Retain the exact native item while removing only PCM ownership.
            audio.clearSelection()
            attempts = 0
            service.clock.reset(position: sentinel, duration: 30)
            service.onDebugPeriodicCurrentItemReadAttempt = { observed in XCTAssertEqual(observed, raw); attempts += 1 }
            service.debugSampleNativeVideoClock()
            service.onDebugPeriodicCurrentItemReadAttempt = nil
            let legacyReads = attempts
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(service.clock.position, native, accuracy: 0.005,
                           "The non-PCM path must still sample the real paused item")

            var selectedInRead = false
            attempts = 0
            service.clock.reset(position: sentinel, duration: 30)
            service.onDebugPeriodicCurrentItemReadAttempt = { observed in
                XCTAssertEqual(observed, raw); attempts += 1
                selectedInRead = audio.select(id: fixture.aID, position: native)
            }
            service.debugSampleNativeVideoClock()
            service.onDebugPeriodicCurrentItemReadAttempt = nil
            XCTAssertEqual(attempts, 1); XCTAssertTrue(selectedInRead); XCTAssertTrue(audio.isSelected)
            XCTAssertTrue(service.player.currentItem === item)
            XCTAssertEqual(service.clock.position, sentinel,
                           "The retained late PCM guard must reject selection changed by SDK reentry")
            print("PeriodicNativeClockContract pcmReads=\(pcmReads) legacyReads=\(legacyReads) reentrantReads=\(attempts) sameNativeItem=\(service.player.currentItem === item)")
        }
        #else
        XCTFail("Periodic clock contracts require DEBUG seams")
        #endif
    }

    func testNativeItemTimebaseCalibratesAcrossPlaybackSeekAndReinsertion() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        var playingBrackets: [PlayingNativeClockBracket] = []
        defer {
            // withOwnedNaturalFixture has completed its original cleanup before this dump.
            for value in playingBrackets { value.dump() }
            XCTAssertLessThanOrEqual(playingBrackets.count, 6)
        }
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            var probeRequest: Int?
            var probeHandoff: PlaybackService.DebugVideoRateHandoff?
            var probeReads = 0
            service.onDebugVideoRateHandoff = { value in
                if value.request == probeRequest, probeHandoff == nil { probeHandoff = value }
            }
            service.onDebugVideoPositionRead = { value in
                if value.request == probeRequest { probeReads = min(1_025, probeReads + 1) }
            }
            defer {
                service.onDebugVideoRateHandoff = nil; service.onDebugVideoPositionRead = nil
                XCTAssertLessThanOrEqual(probeReads, 1_024)
            }
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await requireNativeClockContractOwner(service, fixture: fixture, audio: audio, screen: screen, id: fixture.aID)
            try await require({ buffer.hasPrepared(fixture.bID) }, "Real B must be staged for A-B-A calibration")
            service.pause()
            try await require({ service.player.rate == 0 && !service.audioEngineRunning
                && service.debugInitialVideoReadyState.syncingVideoGeneration == nil }, "Calibration A must settle paused")
            let firstA = try XCTUnwrap(service.player.currentItem)
            let firstRequest = service.debugInitialVideoReadyState.generation
            for target in [0.65, 0.25] {
                service.seek(target)
                try await require({
                    service.debugInitialVideoReadyState.syncingVideoGeneration == nil
                        && abs(service.player.currentTime().seconds - target) < 0.04
                        && service.videoFramePositionSeconds.map { abs($0 - target) < 0.08 } == true
                }, "Each actual paused forward/backwards native seek must complete")
                try sampleItemTimebaseContract(service, item: firstA, label: "paused-A-\(target)", paused: true)
            }
            let frame = service.audioSnapshot.frame
            let pausedNative = firstA.currentTime().seconds
            XCTAssertTrue(pausedNative.isFinite)
            service.play()
            try await require({
                guard service.player.currentItem === firstA, service.player.rate > 0,
                      let timebase = firstA.timebase else { return false }
                let time = CMTimebaseGetTime(timebase)
                return service.audioSnapshot.frame >= frame + 2_400
                    && service.debugInitialVideoReadyState.syncingVideoGeneration == nil
                    && time.isNumeric && time.seconds.isFinite && time.seconds >= pausedNative + 0.025
            }, "Both real PCM and the native item clock must advance before the playing bracket")
            try sampleItemTimebaseContract(service, item: firstA, label: "playing-A", paused: false)
            try await samplePlayingNativeClockPair(service, audio: audio, item: firstA,
                label: "settled-existing-A", into: &playingBrackets)

            probeRequest = service.debugInitialVideoReadyState.generation + 1
            probeHandoff = nil; probeReads = 0
            service.next()
            try await require({ probeHandoff != nil }, "B must return its real rate handoff before the isolated probe")
            let playingB = try XCTUnwrap(service.player.currentItem)
            try await samplePlayingNativeClockPair(service, audio: audio, item: playingB,
                label: "selected-B-handoff", handoff: probeHandoff, ordinaryReads: { probeReads }, into: &playingBrackets)
            try await requireNativeClockContractOwner(service, fixture: fixture, audio: audio, screen: screen, id: fixture.bID)
            try await require({ buffer.previousMediaID == fixture.aID }, "The original A item must be retained")
            service.pause()
            try await require({ service.player.rate == 0 && !service.audioEngineRunning
                && service.debugInitialVideoReadyState.syncingVideoGeneration == nil }, "B must settle paused")
            let b = try XCTUnwrap(service.player.currentItem)
            XCTAssertFalse(b === firstA)
            try sampleItemTimebaseContract(service, item: b, label: "paused-B", paused: true)
            // Previous must also exercise the real playing handoff, rather than only
            // the existing paused reinserted-item equivalence bracket.
            service.play()
            probeRequest = service.debugInitialVideoReadyState.generation + 1
            probeHandoff = nil; probeReads = 0
            service.previous()
            try await require({ probeHandoff != nil }, "Returned A must return its real rate handoff before the isolated probe")
            let playingReturnedA = try XCTUnwrap(service.player.currentItem)
            XCTAssertTrue(playingReturnedA === firstA)
            try await samplePlayingNativeClockPair(service, audio: audio, item: playingReturnedA,
                label: "reinserted-A-handoff", handoff: probeHandoff, ordinaryReads: { probeReads }, into: &playingBrackets)
            try await requireNativeClockContractOwner(service, fixture: fixture, audio: audio, screen: screen, id: fixture.aID)
            service.pause()
            try await require({ service.player.rate == 0 && !service.audioEngineRunning
                && service.debugInitialVideoReadyState.syncingVideoGeneration == nil }, "Returned A must settle paused")
            let returnedA = try XCTUnwrap(service.player.currentItem)
            XCTAssertTrue(returnedA === firstA, "Calibration must cover actual item reinsertion, not a replacement A")
            XCTAssertGreaterThan(service.debugInitialVideoReadyState.generation, firstRequest)
            try sampleItemTimebaseContract(service, item: returnedA, label: "reinserted-A", paused: true)
        }
        #else
        XCTFail("Real item timebase calibration requires DEBUG ownership seams")
        #endif
    }

    #if DEBUG
    private struct PlayingNativeClockBracket {
        let label: String, ordinal: Int
        let item: ObjectIdentifier, timebase: ObjectIdentifier
        let request: Int, returnRequest: Int, sameOwner: Bool
        let handoffReturn: UInt64?, handoffItemMatches: Bool?, ordinaryReadsBeforeProbe: Int
        let syncingBefore: Int?, syncingAfter: Int?
        let begin: UInt64, lookupReturn: UInt64, nativeEntry: UInt64, nativeReturn: UInt64, end: UInt64
        let beforeTime: Double, nativeTime: Double, afterTime: Double
        let beforeRate: Double, afterRate: Double, playerRate: Float
        let control: Int, waiting: String
        let before: ContinuousPCMRenderer.Snapshot, after: ContinuousPCMRenderer.Snapshot
        func dump() {
            print("PlayingNativeClockProbeScope schema=1 label=\(label) ordinal=\(ordinal) handoffReturnNs=\(handoffReturn.map { String($0) } ?? "settled-control") handoffItemMatches=\(handoffItemMatches.map { String($0) } ?? "unavailable") ordinaryReadsBeforeProbe=\(ordinaryReadsBeforeProbe) additionalNativeProbesBeforeThis=\(ordinal) requiredCustomFrameBeforeProbe=\(handoffReturn == nil) deliveryMayFollowOrdinaryRead=true priorSDKFallbackReads=unverified")
            print("PlayingNativeClockBracket schema=1 label=\(label) ordinal=\(ordinal) item=\(item) timebase=\(timebase) request=\(request) returnRequest=\(returnRequest) sameOwner=\(sameOwner) syncingBefore=\(syncingBefore.map { String($0) } ?? "none") syncingAfter=\(syncingAfter.map { String($0) } ?? "none") beginNs=\(begin) lookupReturnNs=\(lookupReturn) nativeEntryNs=\(nativeEntry) nativeReturnNs=\(nativeReturn) endNs=\(end) beforeTime=\(beforeTime) nativeTime=\(nativeTime) afterTime=\(afterTime) effectiveRateBefore=\(beforeRate) effectiveRateAfter=\(afterRate) playerRate=\(playerRate) timeControl=\(control) waiting=\(waiting) beforeToken=\(before.token) afterToken=\(after.token) beforeVisit=\(before.visit) afterVisit=\(after.visit) beforeFrame=\(before.frame) afterFrame=\(after.frame) underrunBefore=\(before.underrunFrames) underrunAfter=\(after.underrunFrames) additionalNativeReads=1 probeMayPerturbSDK=true performanceAcceptance=false clock=DispatchTime")
        }
    }

    private func samplePlayingNativeClockPair(_ service: PlaybackService, audio: ContinuousAudioPlayer,
        item: AVPlayerItem, label: String, handoff: PlaybackService.DebugVideoRateHandoff? = nil,
        ordinaryReads: () -> Int = { 0 }, into values: inout [PlayingNativeClockBracket]) async throws {
        for ordinal in 0..<2 {
            if ordinal == 1 { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertLessThan(values.count, 6)
            guard values.count < 6 else { return }
            let owner = service.debugInitialVideoReadyState
            let previousReads = ordinaryReads()
            let before = audio.renderer.snapshot
            let begin = DispatchTime.now().uptimeNanoseconds
            let timebase = try XCTUnwrap(item.timebase)
            let lookupReturn = DispatchTime.now().uptimeNanoseconds
            let beforeTime = CMTimebaseGetTime(timebase)
            let beforeRate = CMTimebaseGetEffectiveRate(timebase)
            let nativeEntry = DispatchTime.now().uptimeNanoseconds
            let native = item.currentTime() // Exactly one additional native getter in this bracket.
            let nativeReturn = DispatchTime.now().uptimeNanoseconds
            let afterTime = CMTimebaseGetTime(timebase)
            let afterRate = CMTimebaseGetEffectiveRate(timebase)
            let rate = service.player.rate
            let control = service.player.timeControlStatus.rawValue
            let waiting = service.player.reasonForWaitingToPlay?.rawValue ?? "none"
            let after = audio.renderer.snapshot
            let finalOwner = service.debugInitialVideoReadyState
            let sameOwner = service.player.currentItem === item
                && owner.generation == finalOwner.generation
                && before.token == after.token && before.visit == after.visit
                && before.selectionVersion == after.selectionVersion
            let end = DispatchTime.now().uptimeNanoseconds
            values.append(PlayingNativeClockBracket(label: label, ordinal: ordinal,
                item: ObjectIdentifier(item), timebase: ObjectIdentifier(timebase),
                request: owner.generation, returnRequest: finalOwner.generation, sameOwner: sameOwner,
                handoffReturn: handoff?.returnNs,
                handoffItemMatches: handoff.map { $0.item == ObjectIdentifier(item) && $0.request == owner.generation },
                ordinaryReadsBeforeProbe: previousReads,
                syncingBefore: owner.syncingVideoGeneration, syncingAfter: finalOwner.syncingVideoGeneration,
                begin: begin, lookupReturn: lookupReturn, nativeEntry: nativeEntry, nativeReturn: nativeReturn, end: end,
                beforeTime: beforeTime.seconds, nativeTime: native.seconds, afterTime: afterTime.seconds,
                beforeRate: beforeRate, afterRate: afterRate, playerRate: rate,
                control: Int(control), waiting: waiting, before: before, after: after))
            XCTAssertTrue(sameOwner, "The isolated bracket must keep its actual selected native/PCM owner")
            if let handoff {
                XCTAssertEqual(handoff.item, ObjectIdentifier(item)); XCTAssertEqual(handoff.request, owner.generation)
                XCTAssertGreaterThanOrEqual(begin, handoff.returnNs)
            }
            XCTAssertTrue(beforeTime.isNumeric && native.isNumeric && afterTime.isNumeric)
            XCTAssertTrue(beforeRate.isFinite && afterRate.isFinite)
            // Zero rate or a native/timebase mismatch is diagnostic evidence. It
            // never relaxes the benchmark's original readiness or alignment gates.
        }
    }

    private func requireNativeClockContractOwner(_ service: PlaybackService, fixture: SelectionVideoFixture,
        audio: ContinuousAudioPlayer, screen: SelectionVideoScreen, id: String) async throws {
        try await require({
            let owner = service.debugInitialVideoReadyState
            guard let frame = service.videoFramePositionSeconds, let copied = service.copiedVideoFramePositionSeconds,
                  let expected = audio.entry(for: id), service.player.currentItem?.status == .readyToPlay else { return false }
            return service.queue.currentID == id && audio.selectedID == id
                && service.audioSnapshot.token == expected.token && !service.audioSnapshot.ended
                && owner.readyGeneration == owner.generation && owner.syncingVideoGeneration == nil
                && service.isVideoReady && !service.isLoading && service.submittedVideoFrameCount > 0
                && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                && abs(frame - service.videoRequestedPositionSeconds) <= 0.080 && abs(copied - frame) <= 0.080
                && screen.customVideoLayer?.isReadyForDisplay == true
        }, "An exact real selected item, rendered source, and aligned custom frame must qualify the clock contract")
        assertSelection(service, fixture: fixture, id: id)
    }

    private func sampleItemTimebaseContract(_ service: PlaybackService, item: AVPlayerItem,
        label: String, paused: Bool) throws {
        let owner = service.debugInitialVideoReadyState
        XCTAssertTrue(service.player.currentItem === item)
        XCTAssertNil(owner.syncingVideoGeneration)
        if !paused { XCTAssertGreaterThan(service.player.rate, 0) }
        let lookupEntry = DispatchTime.now().uptimeNanoseconds
        let timebase = try XCTUnwrap(item.timebase, "A ready real current item must expose a timebase")
        let lookupReturn = DispatchTime.now().uptimeNanoseconds
        let readEntry = DispatchTime.now().uptimeNanoseconds
        let before = CMTimebaseGetTime(timebase)
        let readReturn = DispatchTime.now().uptimeNanoseconds
        let nativeEntry = DispatchTime.now().uptimeNanoseconds
        let native = item.currentTime()
        let nativeReturn = DispatchTime.now().uptimeNanoseconds
        let after = CMTimebaseGetTime(timebase)
        let finalOwner = service.debugInitialVideoReadyState
        XCTAssertTrue(service.player.currentItem === item)
        XCTAssertEqual(finalOwner.generation, owner.generation); XCTAssertNil(finalOwner.syncingVideoGeneration)
        if !paused { XCTAssertGreaterThan(service.player.rate, 0) }
        XCTAssertTrue(before.isNumeric && native.isNumeric && after.isNumeric)
        XCTAssertEqual(before.epoch, native.epoch); XCTAssertEqual(after.epoch, native.epoch)
        let low = min(before.seconds, after.seconds), high = max(before.seconds, after.seconds)
        XCTAssertTrue(low.isFinite && high.isFinite && native.seconds.isFinite)
        XCTAssertGreaterThanOrEqual(after.seconds, before.seconds - 0.005)
        XCTAssertGreaterThanOrEqual(native.seconds, low - 0.005)
        XCTAssertLessThanOrEqual(native.seconds, high + 0.005)
        if paused {
            XCTAssertEqual(service.player.rate, 0)
            XCTAssertEqual(native.seconds, before.seconds, accuracy: 0.005)
            XCTAssertEqual(native.seconds, after.seconds, accuracy: 0.005)
        }
        print("NativeItemTimebaseCalibration schema=1 label=\(label) request=\(owner.generation) item=\(ObjectIdentifier(item)) paused=\(paused) before=\(before.seconds) native=\(native.seconds) after=\(after.seconds) bracketMs=\((high - low) * 1000) toleranceMs=5 lookupSpanNs=\(lookupReturn - lookupEntry) timebaseReadSpanNs=\(readReturn - readEntry) nativeReadSpanNs=\(nativeReturn - nativeEntry) performanceAcceptance=false")
    }
    #endif

    /// Real mixer output and actual custom-layer submission, without screenshot or SDK-position probes.
    /// This is selected-frame readiness evidence, not compositor pixels or physical speaker output.
    func testProductionSelectionLatencyAndStreamingContinuityWithoutCapture() async throws {
        try await runProductionSelectionBenchmark(traceVideoSeeks: true)
    }

    func testDefaultProductionSelectionLatencyAndStreamingContinuityWithoutCapture() async throws {
        try await runProductionSelectionBenchmark(traceVideoSeeks: false)
    }

    func testPCMSourceCopyFailureTraceOffThenOn() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, enabled) in [false, true].enumerated() {
            let armID = UUID().uuidString.lowercased()
            var helperReturned = false
            print("PCMSourceCopyFailureTraceArm schema=1 armID=\(armID) order=off-then-on ordinal=\(ordinal) enabled=\(enabled) targetVisit=3 nativeRefillTrace=\(enabled) videoSeekTrace=false monitor=current-default otherAlternatives=unset captures=unchanged output=after-cleanup independentDomains=true causalProof=false")
            defer { print("PCMSourceCopyFailureTraceArmEnd schema=1 armID=\(armID) ordinal=\(ordinal) helperReturned=\(helperReturned) xctestOutcome=external noFailure=inconclusive") }
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false,
                traceNativeRefill: enabled, traceFirstSourceFailure: enabled)
            helperReturned = true
        }
        #else
        XCTFail("First source-copy failure trace requires DEBUG")
        #endif
    }

    func testPCMSourceCopyFailureTraceOnThenOff() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, enabled) in [true, false].enumerated() {
            let armID = UUID().uuidString.lowercased()
            var helperReturned = false
            print("PCMSourceCopyFailureTraceArm schema=1 armID=\(armID) order=on-then-off ordinal=\(ordinal) enabled=\(enabled) targetVisit=3 nativeRefillTrace=\(enabled) videoSeekTrace=false monitor=current-default otherAlternatives=unset captures=unchanged output=after-cleanup independentDomains=true causalProof=false")
            defer { print("PCMSourceCopyFailureTraceArmEnd schema=1 armID=\(armID) ordinal=\(ordinal) helperReturned=\(helperReturned) xctestOutcome=external noFailure=inconclusive") }
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false,
                traceNativeRefill: enabled, traceFirstSourceFailure: enabled)
            helperReturned = true
        }
        #else
        XCTFail("First source-copy failure trace requires DEBUG")
        #endif
    }

    func testPreparedNativeGeometryOffThenOn() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, enabled) in [false, true].enumerated() {
            let armID = UUID().uuidString.lowercased()
            var helperReturned = false
            print("PreparedNativeGeometryArm schema=1 armID=\(armID) order=off-then-on ordinal=\(ordinal) nativeGeometry=\(enabled) suppressesPlayerRendering=false otherInstrumentation=unset preparation=explicit-validated-file-only defaultPrepareAPI=composed captures=post-each-stream design=ordered-fresh-fixture-not-causal-proof acceptance=unchanged")
            defer { print("PreparedNativeGeometryArmEnd schema=1 armID=\(armID) ordinal=\(ordinal) helperReturned=\(helperReturned) xctestOutcome=external causalBenefit=unproven") }
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false, nativeVideoGeometry: enabled)
            helperReturned = true
        }
        #else
        XCTFail("Native geometry comparison requires DEBUG")
        #endif
    }

    func testPreparedNativeGeometryOnThenOff() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, enabled) in [true, false].enumerated() {
            let armID = UUID().uuidString.lowercased()
            var helperReturned = false
            print("PreparedNativeGeometryArm schema=1 armID=\(armID) order=on-then-off ordinal=\(ordinal) nativeGeometry=\(enabled) suppressesPlayerRendering=false otherInstrumentation=unset preparation=explicit-validated-file-only defaultPrepareAPI=composed captures=post-each-stream design=ordered-fresh-fixture-not-causal-proof acceptance=unchanged")
            defer { print("PreparedNativeGeometryArmEnd schema=1 armID=\(armID) ordinal=\(ordinal) helperReturned=\(helperReturned) xctestOutcome=external causalBenefit=unproven") }
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false, nativeVideoGeometry: enabled)
            helperReturned = true
        }
        #else
        XCTFail("Native geometry comparison requires DEBUG")
        #endif
    }

    func testPreparedVideoRenderingSuppressionOffThenOn() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, enabled) in [false, true].enumerated() {
            let armID = UUID().uuidString.lowercased()
            var helperReturned = false
            print("PreparedRenderingSuppressionArm schema=1 armID=\(armID) order=off-then-on ordinal=\(ordinal) suppressesPlayerRendering=\(enabled) immutableBufferPolicy=true currentCPPMonitor=true otherInstrumentation=unset fallback=reject-unprepared-comparison captures=post-each-stream design=ordered-fresh-fixture-not-causal-proof acceptance=unchanged")
            defer { print("PreparedRenderingSuppressionArmEnd schema=1 armID=\(armID) ordinal=\(ordinal) helperReturned=\(helperReturned) xctestOutcome=external causalBenefit=unproven") }
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false,
                suppressNativePlayerRendering: enabled)
            helperReturned = true
        }
        #else
        XCTFail("Prepared rendering suppression control requires DEBUG")
        #endif
    }

    func testPreparedVideoRenderingSuppressionOnThenOff() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, enabled) in [true, false].enumerated() {
            let armID = UUID().uuidString.lowercased()
            var helperReturned = false
            print("PreparedRenderingSuppressionArm schema=1 armID=\(armID) order=on-then-off ordinal=\(ordinal) suppressesPlayerRendering=\(enabled) immutableBufferPolicy=true currentCPPMonitor=true otherInstrumentation=unset fallback=reject-unprepared-comparison captures=post-each-stream design=ordered-fresh-fixture-not-causal-proof acceptance=unchanged")
            defer { print("PreparedRenderingSuppressionArmEnd schema=1 armID=\(armID) ordinal=\(ordinal) helperReturned=\(helperReturned) xctestOutcome=external causalBenefit=unproven") }
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false,
                suppressNativePlayerRendering: enabled)
            helperReturned = true
        }
        #else
        XCTFail("Prepared rendering suppression control requires DEBUG")
        #endif
    }

    func testPreviousBundleRetainedThenFresh() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, fresh) in [false, true].enumerated() {
            print("PreviousBundleArm schema=1 order=retained-then-fresh ordinal=\(ordinal) fresh=\(fresh) traceVideoSeeks=false treatment=bundle-history acceptance=unchanged")
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false,
                                                       freshPreviousBundle: fresh)
        }
        #else
        XCTFail("Previous-bundle controls require DEBUG test support")
        #endif
    }

    func testPreviousBundleFreshThenRetained() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, fresh) in [true, false].enumerated() {
            print("PreviousBundleArm schema=1 order=fresh-then-retained ordinal=\(ordinal) fresh=\(fresh) traceVideoSeeks=false treatment=bundle-history acceptance=unchanged")
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false,
                                                       freshPreviousBundle: fresh)
        }
        #else
        XCTFail("Previous-bundle controls require DEBUG test support")
        #endif
    }

    func testPreviousQueueLeadOffThenOn() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, enabled) in [false, true].enumerated() {
            let armID = UUID().uuidString.lowercased()
            var helperReturned = false
            print("PreviousQueueLeadArm schema=1 armID=\(armID) order=off-then-on ordinal=\(ordinal) queuedPreviousLead=\(enabled) traceVideoSeeks=false otherInstrumentation=unset itemResourceOutput=retained-rewound adoptionRoute=queued-advance fixedSetupLeadMs=250 acceptance=unchanged")
            defer { print("PreviousQueueLeadArmEnd schema=1 armID=\(armID) ordinal=\(ordinal) helperReturned=\(helperReturned) xctestOutcome=external causalBenefit=unproven") }
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false,
                                                       queuedPreviousLead: enabled)
            helperReturned = true
        }
        #else
        XCTFail("Previous queue lead comparison requires DEBUG")
        #endif
    }

    func testPreviousQueueLeadOnThenOff() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, enabled) in [true, false].enumerated() {
            let armID = UUID().uuidString.lowercased()
            var helperReturned = false
            print("PreviousQueueLeadArm schema=1 armID=\(armID) order=on-then-off ordinal=\(ordinal) queuedPreviousLead=\(enabled) traceVideoSeeks=false otherInstrumentation=unset itemResourceOutput=retained-rewound adoptionRoute=queued-advance fixedSetupLeadMs=250 acceptance=unchanged")
            defer { print("PreviousQueueLeadArmEnd schema=1 armID=\(armID) ordinal=\(ordinal) helperReturned=\(helperReturned) xctestOutcome=external causalBenefit=unproven") }
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false,
                                                       queuedPreviousLead: enabled)
            helperReturned = true
        }
        #else
        XCTFail("Previous queue lead comparison requires DEBUG")
        #endif
    }

    func testNativeClockHandoffOffThenOn() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, enabled) in [false, true].enumerated() {
            print("NativeClockHandoffArm schema=1 order=off-then-on ordinal=\(ordinal) enabled=\(enabled) acceptance=unchanged")
            try await runProductionSelectionBenchmark(traceVideoSeeks: enabled, recordHost: false,
                traceClockHandoff: enabled)
        }
        #else
        XCTFail("Native clock handoff diagnostic requires DEBUG")
        #endif
    }

    func testNativeClockHandoffOnThenOff() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, enabled) in [true, false].enumerated() {
            print("NativeClockHandoffArm schema=1 order=on-then-off ordinal=\(ordinal) enabled=\(enabled) acceptance=unchanged")
            try await runProductionSelectionBenchmark(traceVideoSeeks: enabled, recordHost: false,
                traceClockHandoff: enabled)
        }
        #else
        XCTFail("Native clock handoff diagnostic requires DEBUG")
        #endif
    }

    func testDefaultProductionRenderAccountingBaseline() async throws {
        try await runProductionSelectionBenchmark(traceVideoSeeks: false, renderAccounting: false)
    }

    func testProductionRenderDemandAccountingOffThenOn() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, enabled) in [false, true].enumerated() {
            let armID = UUID().uuidString.lowercased()
            var helperReturned = false
            print("ProductionRenderDemandAccountingArm schema=2 armID=\(armID) order=off-then-on ordinal=\(ordinal) enabled=\(enabled) actualClockHandoffMode=unset noActiveClockObservers=true clockObserverScope=optional-handoff-diagnostics explicitFalseEquivalence=unproven traceVideoSeeks=false defaultMonitor=true fullSavedAAuditRequested=\(enabled) offFullAuditSupported=false design=ordered-fresh-fixture-not-causal-proof noRecurrence=inconclusive acceptance=unchanged")
            defer {
                print("ProductionRenderDemandAccountingArmEnd schema=2 armID=\(armID) order=off-then-on ordinal=\(ordinal) enabled=\(enabled) helperReturned=\(helperReturned) xctestOutcome=external fullApplicationAcceptance=not-inferred")
            }
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false,
                renderAccounting: enabled, auditSavedAAfterCleanup: enabled)
            helperReturned = true
        }
        #else
        XCTFail("Production render-demand accounting controls require DEBUG")
        #endif
    }

    func testProductionRenderDemandAccountingOnThenOff() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, enabled) in [true, false].enumerated() {
            let armID = UUID().uuidString.lowercased()
            var helperReturned = false
            print("ProductionRenderDemandAccountingArm schema=2 armID=\(armID) order=on-then-off ordinal=\(ordinal) enabled=\(enabled) actualClockHandoffMode=unset noActiveClockObservers=true clockObserverScope=optional-handoff-diagnostics explicitFalseEquivalence=unproven traceVideoSeeks=false defaultMonitor=true fullSavedAAuditRequested=\(enabled) offFullAuditSupported=false design=ordered-fresh-fixture-not-causal-proof noRecurrence=inconclusive acceptance=unchanged")
            defer {
                print("ProductionRenderDemandAccountingArmEnd schema=2 armID=\(armID) order=on-then-off ordinal=\(ordinal) enabled=\(enabled) helperReturned=\(helperReturned) xctestOutcome=external fullApplicationAcceptance=not-inferred")
            }
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false,
                renderAccounting: enabled, auditSavedAAfterCleanup: enabled)
            helperReturned = true
        }
        #else
        XCTFail("Production render-demand accounting controls require DEBUG")
        #endif
    }

    func testDefaultProductionRenderAccountingEnabled() async throws {
        #if DEBUG
        try await runProductionSelectionBenchmark(traceVideoSeeks: false, renderAccounting: true,
            auditSavedAAfterCleanup: true)
        #else
        XCTFail("Render accounting diagnostic requires DEBUG")
        #endif
    }

    func testDefaultAcceptedPCMOriginOffThenOn() async throws {
        try recordRuntimeHost()
        #if DEBUG
        defer { acceptedPCMOriginBenchmarkMode = nil }
        for (ordinal, enabled) in [false, true].enumerated() {
            acceptedPCMOriginBenchmarkMode = enabled
            print("AcceptedPCMOriginArm schema=1 order=off-then-on ordinal=\(ordinal) enabled=\(enabled) defaultMonitor=true videoSeekTrace=false design=ordered-fresh-arm-not-causal-proof")
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false)
        }
        #else
        XCTFail("Accepted PCM origin diagnostic requires DEBUG")
        #endif
    }

    func testDefaultAcceptedPCMOriginOnThenOff() async throws {
        try recordRuntimeHost()
        #if DEBUG
        defer { acceptedPCMOriginBenchmarkMode = nil }
        for (ordinal, enabled) in [true, false].enumerated() {
            acceptedPCMOriginBenchmarkMode = enabled
            print("AcceptedPCMOriginArm schema=1 order=on-then-off ordinal=\(ordinal) enabled=\(enabled) defaultMonitor=true videoSeekTrace=false design=ordered-fresh-arm-not-causal-proof")
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false)
        }
        #else
        XCTFail("Accepted PCM origin diagnostic requires DEBUG")
        #endif
    }

    func testDefaultFrameMonitorReadTimingUntracedThenTraced() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for enabled in [false, true] {
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false,
                                                       traceDefaultFrameMonitor: enabled)
        }
        #else
        XCTFail("Default-monitor timing diagnostic requires DEBUG")
        #endif
    }

    func testDefaultFrameMonitorReadTimingTracedThenUntraced() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for enabled in [true, false] {
            try await runProductionSelectionBenchmark(traceVideoSeeks: false, recordHost: false,
                                                       traceDefaultFrameMonitor: enabled)
        }
        #else
        XCTFail("Default-monitor timing diagnostic requires DEBUG")
        #endif
    }

    func testFrameReadinessMonitorBenchmarkDefaultThenCurrentCustomFrame() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, alternative) in [false, true].enumerated() {
            print("FrameMonitorBenchmarkArm schema=1 order=default-then-custom ordinal=\(ordinal) alternative=\(alternative) serviceTracing=true nativeRefillTrace=false playbackAcceptance=unchanged physicalPixels=unmeasured")
            try await runProductionSelectionBenchmark(traceVideoSeeks: true, frameMonitorAlternative: alternative,
                                                       recordHost: false)
        }
        #else
        XCTFail("Frame-monitor diagnostic requires DEBUG controls")
        #endif
    }

    func testFrameReadinessMonitorBenchmarkCurrentCustomFrameThenDefault() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, alternative) in [true, false].enumerated() {
            print("FrameMonitorBenchmarkArm schema=1 order=custom-then-default ordinal=\(ordinal) alternative=\(alternative) serviceTracing=true nativeRefillTrace=false playbackAcceptance=unchanged physicalPixels=unmeasured")
            try await runProductionSelectionBenchmark(traceVideoSeeks: true, frameMonitorAlternative: alternative,
                                                       recordHost: false)
        }
        #else
        XCTFail("Frame-monitor diagnostic requires DEBUG controls")
        #endif
    }

    func testNativeRefillTraceCurrentCustomFrameThenDefault() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, alternative) in [true, false].enumerated() {
            print("FrameMonitorBenchmarkArm schema=1 order=custom-then-default ordinal=\(ordinal) alternative=\(alternative) serviceTracing=true nativeRefillTrace=true playbackAcceptance=unchanged physicalPixels=unmeasured")
            try await runProductionSelectionBenchmark(traceVideoSeeks: true, frameMonitorAlternative: alternative,
                                                       recordHost: false, traceNativeRefill: true)
        }
        #else
        XCTFail("Native-refill diagnostic requires DEBUG controls")
        #endif
    }

    func testNativeRefillTraceDefaultThenCurrentCustomFrame() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, alternative) in [false, true].enumerated() {
            print("FrameMonitorBenchmarkArm schema=1 order=default-then-custom ordinal=\(ordinal) alternative=\(alternative) serviceTracing=true nativeRefillTrace=true playbackAcceptance=unchanged physicalPixels=unmeasured")
            try await runProductionSelectionBenchmark(traceVideoSeeks: true, frameMonitorAlternative: alternative,
                                                       recordHost: false, traceNativeRefill: true)
        }
        #else
        XCTFail("Native-refill diagnostic requires DEBUG controls")
        #endif
    }

    /// Capability only: copying B consumes its output. This arm never measures Next.
    func testPreparedNextVideoFirstFrameCapabilityBeforeSelection() async throws {
        try await runPreparedNextVideoFirstFrameCapabilityBeforeSelection()
    }

    private func runPreparedNextVideoFirstFrameCapabilityBeforeSelection(
        prerollOwner: PreparedNextPrerollOwner? = nil) async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer, additionalCleanupAcknowledged: { @MainActor in
            prerollOwner?.mayRemoveFixture ?? true
        }) { fixture, audio, service, screen in
            let tap = ProductionSelectionOutputTap()
            let seeks = ProductionSelectionSeekRecorder()
            let startup = ProductionVideoStartupTrace(serviceTracing: false)
            let originalSources = (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }
            let originalBytes = audio.renderer.retainedPCMMemoryBytes
            audio.graph.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil) { value, time in
                tap.append(value, time: time)
            }
            defer {
                tap.stop()
                audio.graph.engine.mainMixerNode.removeTap(onBus: 0)
            }

            // Match the untouched benchmark's cold A measurement and eight-second stream.
            let cold = try await self.measureProductionSelection(service, screen: screen, fixture: fixture,
                audio: audio, tap: tap, seeks: seeks, startup: startup, phase: 0, id: fixture.aID,
                frequency: 440, prepared: false, preparedBefore: true) {
                    service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
                }
            let baseline = audio.renderer.snapshot
            let streamBefore = self.productionSelectionState(service, fixture: fixture, audio: audio, id: fixture.aID)
            let probe = ProductionRendererProbe(renderer: audio.renderer)
            try? await Task.sleep(for: .seconds(8))
            let streamResult = probe.stop()
            let streamFinal = audio.renderer.snapshot
            let streamAfter = self.productionSelectionState(service, fixture: fixture, audio: audio, id: fixture.aID)
            let stream = ProductionSelectionStream(phase: 0, baseline: baseline, final: streamFinal,
                before: streamBefore, after: streamAfter, quantum: service.audioRenderQuantumFrames,
                result: streamResult, memoryBytes: audio.renderer.retainedPCMMemoryBytes,
                sameStorage: originalSources == (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) })
            // Keep assertions and logs outside the capability acquisition bracket.
            defer {
                self.assertProductionSelection(cold, tap: tap)
                self.assertProductionStream(stream)
                XCTAssertEqual(originalBytes, 6_912_000)
                XCTAssertEqual(audio.renderer.retainedPCMMemoryBytes, originalBytes)
                XCTAssertEqual(originalSources, (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) })
                seeks.assertUnused()
            }

            // This is exactly the existing phase-1 PCM gate and 120 ms lead.
            // Never wait for video staging, readyToPlay, or an output to become available.
            let preparedBefore = await self.waitUntil(timeout: 5) {
                service.preparedAudioCount == 2 && audio.entry(for: fixture.bID) != nil
            }
            let capabilityFirst = tap.begin()
            try await Task.sleep(for: .milliseconds(120))
            let checkpoint = DispatchTime.now().uptimeNanoseconds
            let checkpointAudio = audio.renderer.snapshot
            let queued = buffer.player.items()
            let currentA = queued.first
            let queuedB = queued.dropFirst().first
            let resource = queuedB.flatMap { buffer.resource(for: $0) }
            let output = resource?.output
            let aURLMatches = (currentA?.asset as? AVURLAsset)?.url.standardizedFileURL
                == fixture.savedURLs[fixture.aID]?.standardizedFileURL
            let bURLMatches = (queuedB?.asset as? AVURLAsset)?.url.standardizedFileURL
                == fixture.savedURLs[fixture.bID]?.standardizedFileURL
            let outputsAtCheckpoint = queuedB?.outputs.count ?? -1
            let retainedAtCheckpoint = buffer.retainedItemCount
            let stagedAtCheckpoint = buffer.hasPrepared(fixture.bID)
            let currentToken = audio.entry(for: fixture.aID)?.token ?? 0
            let nextToken = audio.entry(for: fixture.bID)?.token ?? 0

            guard preparedBefore, queued.count == 2, let currentA, let queuedB, let resource, let output,
                  aURLMatches, bURLMatches, stagedAtCheckpoint, outputsAtCheckpoint == 1,
                  resource.item === queuedB, resource.isAttached, !resource.isRetired, !resource.isBorrowed,
                  queuedB.outputs.contains(where: { $0 === output }),
                  service.player.currentItem === currentA, service.queue.currentID == fixture.aID,
                  audio.selectedID == fixture.aID, currentToken > 0, nextToken > 0,
                  checkpointAudio.token == currentToken, !checkpointAudio.ended,
                  retainedAtCheckpoint <= 3 else {
                print("PreparedNextFrameCapability schema=1 checkpointNs=\(checkpoint) pcmPrepared=\(preparedBefore) queueCount=\(queued.count) aURLMatches=\(aURLMatches) bURLMatches=\(bURLMatches) staged=\(stagedAtCheckpoint) outputPresent=\(output != nil) outputs=\(outputsAtCheckpoint) retainedItems=\(retainedAtCheckpoint) queryCount=0 copyCount=0 setupValid=false availability=unmeasured latencyEvidence=false compositorPixels=unmeasured")
                XCTFail("The exact pre-Next checkpoint did not contain the required A/B owners; no extra preparation wait is allowed")
                return
            }
            let initialBStatus = queuedB.status.rawValue
            @MainActor func ownsPreparedB() -> Bool {
                let items = buffer.player.items()
                return service.queue.currentID == fixture.aID && audio.selectedID == fixture.aID
                    && service.player.currentItem === currentA && items.count == 2
                    && items.first === currentA && items.dropFirst().first === queuedB
                    && buffer.nextMediaID == fixture.bID && buffer.resource(for: queuedB) === resource
                    && resource.item === queuedB && resource.output === output
                    && resource.isAttached && !resource.isRetired && !resource.isBorrowed
                    && queuedB.outputs.count == 1 && queuedB.outputs.contains(where: { $0 === output })
            }

            var experimentOwnersStable: (@MainActor () -> Bool)?
            var capabilityQueryCount = 0, capabilityCopyCount = 0
            let helperProbe = prerollOwner.map { _ in ProductionRendererProbe(renderer: audio.renderer) }
            defer {
                if let helperProbe {
                    self.assertPreparedNextPrerollContinuity(helperProbe.stop(), tap: tap, first: capabilityFirst,
                        audio: audio, service: service, fixture: fixture, baseline: checkpointAudio)
                    XCTAssertTrue(experimentOwnersStable?() ?? false)
                }
            }
            if let prerollOwner {
                let transfer = try await self.transferPreparedNextForPreroll(prerollOwner,
                    fixture: fixture, audio: audio, service: service, buffer: buffer, a: currentA, b: queuedB,
                    resource: resource, output: output, checkpoint: checkpointAudio, nextToken: nextToken,
                    originalSources: originalSources)
                experimentOwnersStable = transfer.ownersStable
                guard ownsPreparedB(), experimentOwnersStable?() == true else {
                    print("PreparedNextPrerollProbe schema=1 token=\(prerollOwner.token) queryCount=0 copyCount=0 setupValid=false ownerStable=false latencyEvidence=false compositorPixels=unmeasured")
                    XCTFail("Exact restored B and finalized callback owners must be valid after the transfer await, before availability")
                    throw SelectionVideoTestFailure.timeout
                }
                switch transfer.outcome {
                case .refusedRestored:
                    XCTAssertFalse(transfer.consumingProbeAuthorized)
                    XCTAssertFalse(prerollOwner.issuedPreroll)
                    XCTAssertEqual(prerollOwner.callback?.snapshot.count, 0)
                    XCTAssertEqual(capabilityQueryCount, 0); XCTAssertEqual(capabilityCopyCount, 0)
                    guard !transfer.consumingProbeAuthorized, !prerollOwner.issuedPreroll,
                          prerollOwner.callback?.snapshot.count == 0,
                          capabilityQueryCount == 0, capabilityCopyCount == 0 else {
                        XCTFail("An ownership refusal must never authorize preroll or a consuming output probe")
                        throw SelectionVideoTestFailure.timeout
                    }
                    print("PreparedNextPrerollProbe schema=2 token=\(prerollOwner.token) requestedTreatment=\(prerollOwner.enabled) actualIssued=\(prerollOwner.issuedPreroll) outcome=refusedRestored queryCount=\(capabilityQueryCount) copyCount=\(capabilityCopyCount) ownerStable=true consumingProbeAuthorized=false capabilitySuccess=false latencyEvidence=false compositorPixels=unmeasured")
                    return
                case .qualifiedCapability:
                    guard transfer.consumingProbeAuthorized else {
                        XCTFail("Only a qualified accepted setup may authorize the existing consuming probe")
                        throw SelectionVideoTestFailure.timeout
                    }
                }
            }

            capabilityQueryCount += 1
            let queryEntry = DispatchTime.now().uptimeNanoseconds
            let reportedAvailable = output.hasNewPixelBuffer(forItemTime: .zero)
            let queryReturn = DispatchTime.now().uptimeNanoseconds
            guard ownsPreparedB(), experimentOwnersStable?() ?? true else {
                print("PreparedNextFrameCapability schema=1 checkpointNs=\(checkpoint) queryEntryNs=\(queryEntry) queryReturnNs=\(queryReturn) queryCount=1 copyCount=0 setupValid=true ownerStable=false availability=unverified latencyEvidence=false compositorPixels=unmeasured")
                XCTFail("Prepared B ownership changed during the opaque availability query; no copy is authorized")
                return
            }
            var returnedPTS = CMTime.invalid
            capabilityCopyCount += 1
            let copyEntry = DispatchTime.now().uptimeNanoseconds
            var pixel = output.copyPixelBuffer(forItemTime: .zero, itemTimeForDisplay: &returnedPTS)
            let copyReturn = DispatchTime.now().uptimeNanoseconds
            let ownerStable = ownsPreparedB() && (experimentOwnersStable?() ?? true)
            let afterAudio = audio.renderer.snapshot
            let returnedBuffer = pixel != nil
            let numericPTS = returnedPTS.isNumeric
            let zeroPTS = numericPTS && CMTimeCompare(returnedPTS, .zero) == 0
            var width = 0, height = 0, rowBytes = 0
            var pixelFormat: OSType = 0
            var lockStatus: CVReturn = kCVReturnError
            var greenFraction: Double?, redFraction: Double?, magentaFraction: Double?
            var blueX: Double?, blueY: Double?
            if let image = pixel {
                width = CVPixelBufferGetWidth(image); height = CVPixelBufferGetHeight(image)
                rowBytes = CVPixelBufferGetBytesPerRow(image)
                pixelFormat = CVPixelBufferGetPixelFormatType(image)
                // Fixed public fixture only. No copied image, decoded history, or retained frame queue.
                if width == 160, height == 96, rowBytes >= width * 4, rowBytes <= 4096,
                   pixelFormat == kCVPixelFormatType_32BGRA {
                    lockStatus = CVPixelBufferLockBaseAddress(image, .readOnly)
                    if lockStatus == kCVReturnSuccess {
                        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
                        if let base = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) {
                            var green = 0, red = 0, magenta = 0, blue = 0
                            var sumX = 0.0, sumY = 0.0
                            for y in 0..<height {
                                for x in 0..<width {
                                    let offset = y * rowBytes + x * 4
                                    let b = base[offset], g = base[offset + 1], r = base[offset + 2]
                                    if g > 150 && r < 100 && b < 100 { green += 1 }
                                    if r > 150 && g < 100 && b < 100 { red += 1 }
                                    if r > 150 && g < 100 && b > 150 { magenta += 1 }
                                    if b > 150 && r < 100 && g < 100 {
                                        blue += 1; sumX += Double(x); sumY += Double(y)
                                    }
                                }
                            }
                            let count = Double(width * height)
                            greenFraction = Double(green) / count
                            redFraction = Double(red) / count
                            magentaFraction = Double(magenta) / count
                            if blue >= 4 { blueX = sumX / Double(blue); blueY = sumY / Double(blue) }
                        }
                    }
                }
            }
            pixel = nil // Release the sole copied buffer before teardown or any later action.
            let validPixels = (greenFraction ?? 0) > 0.65 && (redFraction ?? 1) < 0.02
                && (magentaFraction ?? 1) < 0.02
                && blueX.map { abs($0 - 7.5) <= 2 } == true
                && blueY.map { abs($0 - 11.5) <= 2 } == true
            let audioOwnerStable = afterAudio.token == currentToken && afterAudio.token == checkpointAudio.token
                && afterAudio.visit == checkpointAudio.visit
                && afterAudio.selectionVersion == checkpointAudio.selectionVersion && !afterAudio.ended
            let preexistingFrameProven = reportedAvailable && returnedBuffer && numericPTS && zeroPTS
                && validPixels && ownerStable && audioOwnerStable
            let classification = preexistingFrameProven ? "available-before-copy"
                : returnedBuffer ? "copy-returned-without-preexisting-proof" : "no-buffer-returned"
            print("PreparedNextFrameCapability schema=1 checkpointNs=\(checkpoint) queryEntryNs=\(queryEntry) queryReturnNs=\(queryReturn) copyEntryNs=\(copyEntry) copyReturnNs=\(copyReturn) queryCount=1 copyCount=1 setupValid=true initialBStatus=\(initialBStatus) ownerStable=\(ownerStable) audioOwnerStable=\(audioOwnerStable) reportedAvailable=\(reportedAvailable) returnedBuffer=\(returnedBuffer) numericPTS=\(numericPTS) zeroPTS=\(zeroPTS) ptsSeconds=\(numericPTS ? String(returnedPTS.seconds) : "invalid") width=\(width) height=\(height) rowBytes=\(rowBytes) pixelFormat=\(pixelFormat) lockStatus=\(lockStatus) greenFraction=\(greenFraction.map { String($0) } ?? "unavailable") redFraction=\(redFraction.map { String($0) } ?? "unavailable") magentaFraction=\(magentaFraction.map { String($0) } ?? "unavailable") blueX=\(blueX.map { String($0) } ?? "unavailable") blueY=\(blueY.map { String($0) } ?? "unavailable") retainedItems=\(buffer.retainedItemCount) availability=\(classification) preexistingFrameProven=\(preexistingFrameProven) decoderAbsenceProven=false latencyEvidence=false compositorPixels=unmeasured")
            if let prerollOwner {
                print("PreparedNextPrerollProbe schema=1 token=\(prerollOwner.token) order=\(prerollOwner.order) ordinal=\(prerollOwner.ordinal) enabled=\(prerollOwner.enabled) queryEntryNs=\(queryEntry) queryReturnNs=\(queryReturn) copyEntryNs=\(copyEntry) copyReturnNs=\(copyReturn) queryCount=1 copyCount=1 reportedAvailable=\(reportedAvailable) returnedBuffer=\(returnedBuffer) preexistingFrameProven=\(preexistingFrameProven) latencyEvidence=false compositorPixels=unmeasured")
            }
            XCTAssertTrue(ownerStable); XCTAssertTrue(audioOwnerStable)
            XCTAssertEqual(afterAudio.token, checkpointAudio.token)
            XCTAssertEqual(afterAudio.visit, checkpointAudio.visit)
            XCTAssertEqual(afterAudio.selectionVersion, checkpointAudio.selectionVersion)
            XCTAssertGreaterThanOrEqual(afterAudio.frame, checkpointAudio.frame)
            XCTAssertEqual(afterAudio.underrunFrames, checkpointAudio.underrunFrames)
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)
            XCTAssertEqual(queuedB.outputs.count, 1)
            XCTAssertFalse(reportedAvailable && !returnedBuffer,
                           "An available-buffer report without an actual copy cannot prove capability")
            if returnedBuffer {
                XCTAssertTrue(numericPTS && zeroPTS, "A copied nonzero/invalid PTS cannot prove the initial frame")
                XCTAssertEqual(width, 160); XCTAssertEqual(height, 96)
                XCTAssertEqual(pixelFormat, kCVPixelFormatType_32BGRA)
                XCTAssertEqual(lockStatus, kCVReturnSuccess)
                XCTAssertTrue(validPixels, "The actual copied pixels must be B's initial green frame and blue marker")
            }
            // Nil with a false query is a retained observation, never a decoder-absence assertion.
            // No Next is issued: the existing untouched latency/pixel suite remains authoritative.
        }
        #else
        XCTFail("Prepared-frame capability diagnostic requires DEBUG")
        #endif
    }

    /// Capability only; the sole consuming probe remains after the matched transfer.
    func testPreparedNextVideoPrerollCapabilityOffThenOn() async throws {
        prerollCaseStartUTC = ISO8601DateFormatter.string(from: Date(), timeZone: TimeZone(secondsFromGMT: 0)!,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        defer { prerollCaseStartUTC = nil }
        try recordRuntimeHost()
        try await runPreparedNextPrerollPair(order: "off-on", treatments: [false, true])
    }

    func testPreparedNextVideoPrerollCapabilityOnThenOff() async throws {
        prerollCaseStartUTC = ISO8601DateFormatter.string(from: Date(), timeZone: TimeZone(secondsFromGMT: 0)!,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        defer { prerollCaseStartUTC = nil }
        try recordRuntimeHost()
        try await runPreparedNextPrerollPair(order: "on-off", treatments: [true, false])
    }

    private func runPreparedNextPrerollPair(order: String, treatments: [Bool]) async throws {
        for (ordinal, enabled) in treatments.enumerated() {
            guard Self.preparedPrerollToken < UInt64.max else { throw SelectionVideoTestFailure.timeout }
            Self.preparedPrerollToken += 1
            let owner = PreparedNextPrerollOwner(token: Self.preparedPrerollToken,
                enabled: enabled, order: order, ordinal: ordinal)
            try await runPreparedNextPrerollArm(owner)
        }
    }

    // Code-generation/lifetime control for the attributed Swift task-deallocation
    // abort. Original owner, suspension points, deadlines and playback guards.
    @MainActor @inline(never)
    private func runPreparedNextPrerollArm(_ owner: PreparedNextPrerollOwner) async throws {
        let nativeAttachProbeCalibrated = OPDebugCalibrateNativeAttachProbe()
        XCTAssertTrue(nativeAttachProbeCalibrated, "The native observer must preserve the original exception as a classified failure without unwinding Swift")
        guard nativeAttachProbeCalibrated else { throw SelectionVideoTestFailure.timeout }
        print("PrerollAsyncArmBoundary schema=4 token=\(owner.token) phase=entry separateTask=false nativeAttach=typed-ownership-outcome APlaybackResourceTimingGuards=unchanged capabilityExpectation=qualified-or-refusal")
        try await runPreparedNextVideoFirstFrameCapabilityBeforeSelection(prerollOwner: owner)
        print("PrerollAsyncArmBoundary schema=4 token=\(owner.token) phase=return separateTask=false nativeAttach=typed-ownership-outcome APlaybackResourceTimingGuards=unchanged capabilityExpectation=qualified-or-refusal")
    }

    private enum PreparedNextPrerollTransferOutcome {
        case refusedRestored
        case qualifiedCapability
    }

    @MainActor private struct PreparedNextPrerollTransfer {
        let outcome: PreparedNextPrerollTransferOutcome
        let ownersStable: @MainActor () -> Bool
        var consumingProbeAuthorized: Bool {
            switch outcome {
            case .refusedRestored: return false
            case .qualifiedCapability: return true
            }
        }
    }

    @MainActor private final class PreparedNextPrerollOwner {
        let token: UInt64, enabled: Bool, order: String, ordinal: Int
        var cleanupAcknowledged = true
        var issuedPreroll = false
        var helper: AVPlayer?
        // Retained on an uncertain close; no later experimental fixture may start.
        var fixture: SelectionVideoFixture?
        var item: AVPlayerItem?
        var resource: ContinuousPictureInPicture.PreparedVideoResource?
        var callback: PreparedNextPrerollCallback?
        var mayRemoveFixture: Bool {
            cleanupAcknowledged && (callback?.snapshot.count ?? 0) == (issuedPreroll ? 1 : 0)
        }
        init(token: UInt64, enabled: Bool, order: String, ordinal: Int) {
            self.token = token; self.enabled = enabled; self.order = order; self.ordinal = ordinal
        }
    }

    /// Returns only after exact helper detachment and callback ownership are known.
    /// Synchronous SDK spans are observed, never made interruptible by these budgets.
    private func transferPreparedNextForPreroll(_ owner: PreparedNextPrerollOwner,
        fixture: SelectionVideoFixture, audio: ContinuousAudioPlayer, service: PlaybackService,
        buffer: PlaybackBuffer, a: AVPlayerItem, b: AVPlayerItem,
        resource: ContinuousPictureInPicture.PreparedVideoResource, output: AVPlayerItemVideoOutput,
        checkpoint: ContinuousPCMRenderer.Snapshot, nextToken: Int,
        originalSources: [ObjectIdentifier]) async throws -> PreparedNextPrerollTransfer {
        let aAsset = a.asset, bAsset = b.asset, composition = b.videoComposition
        let originalPlayer = service.player, aRate = originalPlayer.rate
        var lastFrame = checkpoint.frame
        var valid = true, issued = false, callbackFinalized = false
        var readyNs: UInt64?, observedCallbackNs: UInt64?
        var helper: AVPlayer?
        let setupEntry = DispatchTime.now().uptimeNanoseconds
        #if DEBUG
        let diagnosticToken = owner.token, diagnosticOrder = owner.order
        let diagnosticOrdinal = owner.ordinal, diagnosticEnabled = owner.enabled
        // At most 46 stages per arm: five first attempts times eight stages plus six cleanup stages.
        // Repeated native-preroll attempts keep their existing receipt but add no stage markers.
        var diagnosticOperations: UInt8 = 0
        @MainActor func claimDiagnosticBoundary(_ operation: String) -> Bool {
            let bit: UInt8
            switch operation {
            case "remove-only-B": bit = 1
            case "attach-same-B": bit = 2
            case "native-preroll": bit = 4
            case "can-insert-same-B": bit = 8
            case "reinsert-same-B-after-same-A": bit = 16
            default: return false
            }
            guard (diagnosticOperations & bit) == 0 else { return false }
            diagnosticOperations |= bit
            return true
        }
        @MainActor func diagnosticStage(_ operation: String, _ stage: String,
                                       result: Bool? = nil, cachedNs: UInt64? = nil) {
            print("PreparedNextPrerollStage schema=1 token=\(diagnosticToken) order=\(diagnosticOrder) ordinal=\(diagnosticOrdinal) enabled=\(diagnosticEnabled) operation=\(operation) stage=\(stage) result=\(result.map { String($0) } ?? "unobserved") cachedNs=\(cachedNs.map { String($0) } ?? "unobserved") scope=first-operation-attempt-or-single-cleanup latencyEvidence=false stdoutDelivery=unacknowledged")
        }
        #endif
        @MainActor func owns(_ queued: Bool, _ helperHasB: Bool) -> Bool {
            let items = buffer.player.items(), pcm = audio.renderer.snapshot, bTime = b.currentTime()
            let exactQueue = queued
                ? items.count == 2 && items.first === a && items.dropFirst().first === b
                : items.count == 1 && items.first === a
            let exactHelper = helper.map {
                $0.rate == 0 && $0.isMuted && $0.volume == 0 && $0.status != .failed
                    && (helperHasB ? $0.currentItem === b : $0.currentItem == nil)
            } ?? !helperHasB
            let exactCallback = !callbackFinalized || owner.callback.map {
                $0.token == owner.token && $0.snapshot.count == (issued ? 1 : 0)
            } == true
            let result = !Task.isCancelled && exactQueue && exactHelper && exactCallback
                && service.player === originalPlayer && buffer.player === originalPlayer
                && originalPlayer.currentItem === a && originalPlayer.rate == aRate && aRate > 0
                && service.queue.currentID == fixture.aID && service.current?.id == fixture.aID
                && audio.selectedID == fixture.aID && service.wantsToPlay && service.audioEngineRunning
                && a.asset === aAsset && b.asset === bAsset && b.videoComposition === composition
                && a.status != .failed && b.status != .failed
                && bTime.isNumeric && CMTimeCompare(bTime, .zero) == 0
                && (aAsset as? AVURLAsset)?.url.standardizedFileURL == fixture.savedURLs[fixture.aID]?.standardizedFileURL
                && (bAsset as? AVURLAsset)?.url.standardizedFileURL == fixture.savedURLs[fixture.bID]?.standardizedFileURL
                && fixture.library.catalog.media.count == 2
                && Set(fixture.library.catalog.media.map(\.id)) == Set([fixture.aID, fixture.bID])
                && fixture.library.catalog.media.allSatisfy({ $0.asset == nil })
                && buffer.previousMediaID == nil && !buffer.hasLoopReserve
                && buffer.nextMediaID == fixture.bID && buffer.resource(for: b) === resource
                && resource.item === b && resource.output === output && resource.isAttached
                && !resource.isRetired && !resource.isBorrowed && b.outputs.count == 1
                && b.outputs.contains(where: { $0 === output }) && buffer.retainedItemCount <= 3
                && service.preparedAudioCount == 2 && audio.entry(for: fixture.aID)?.token == checkpoint.token
                && nextToken > 0 && audio.entry(for: fixture.bID)?.token == nextToken && pcm.token == checkpoint.token
                && pcm.visit == checkpoint.visit && pcm.selectionVersion == checkpoint.selectionVersion
                && !pcm.ended && pcm.frame >= lastFrame && pcm.underrunFrames == checkpoint.underrunFrames
                && audio.renderer.retainedPCMMemoryBytes == 6_912_000
                && originalSources == (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }
            if result { lastFrame = pcm.frame }
            return result
        }
        @MainActor func boundary(_ operation: String, beforeQueued: Bool, beforeHelper: Bool,
            afterQueued: Bool, afterHelper: Bool,
            afterSDKAuthorized: @MainActor () -> Bool = { true }, _ action: @MainActor () -> Void) -> Bool {
            #if DEBUG
            let diagnose = claimDiagnosticBoundary(operation)
            if diagnose { diagnosticStage(operation, "pre-owns-entry") }
            #endif
            let before = owns(beforeQueued, beforeHelper)
            #if DEBUG
            if diagnose { diagnosticStage(operation, "pre-owns-result", result: before) }
            #endif
            guard before else { return false }
            #if DEBUG
            if diagnose { diagnosticStage(operation, "action-entry") }
            #endif
            let entry = DispatchTime.now().uptimeNanoseconds
            action()
            let returned = DispatchTime.now().uptimeNanoseconds
            guard afterSDKAuthorized() else {
                #if DEBUG
                if diagnose { diagnosticStage(operation, "classified-failure-no-post-sdk", result: false, cachedNs: returned) }
                #endif
                return false
            }
            #if DEBUG
            if diagnose {
                diagnosticStage(operation, "action-raw-return", cachedNs: returned)
                diagnosticStage(operation, "post-owns-entry")
            }
            #endif
            let after = owns(afterQueued, afterHelper)
            #if DEBUG
            if diagnose {
                diagnosticStage(operation, "post-owns-result", result: after)
                diagnosticStage(operation, "original-receipt-entry")
            }
            #endif
            print("PreparedNextPrerollBoundary schema=1 token=\(owner.token) operation=\(operation) entryNs=\(entry) returnNs=\(returned) ownerBefore=\(before) ownerAfter=\(after) helperPresent=\(helper != nil) helperRate=\(helper.map { String($0.rate) } ?? "released") helperMuted=\(helper.map { String($0.isMuted) } ?? "released") helperHasB=\(helper?.currentItem === b) latencyEvidence=false")
            #if DEBUG
            if diagnose { diagnosticStage(operation, "original-receipt-return") }
            #endif
            return after
        }
        guard owns(true, false) else {
            XCTFail("Initial two-Saved fixture, settled A epoch, and exact B owners are required")
            throw SelectionVideoTestFailure.timeout
        }
        owner.fixture = fixture; owner.item = b; owner.resource = resource
        owner.cleanupAcknowledged = false
        @MainActor func retainUnresolvedCleanup(_ stage: String) {
            owner.cleanupAcknowledged = false
            Self.unresolvedPreparedPrerollOwner = owner
            Self.targetedFixtureOwnershipLost = true
            print("PreparedNextPrerollCleanupFailure schema=1 token=\(owner.token) stage=\(stage) ownerRetained=true fixtureRetained=true sdkQueriesAfterFailure=false consumingProbeAuthorized=false")
        }
        let created = AVPlayer()
        created.isMuted = true; created.volume = 0
        helper = created; owner.helper = created
        valid = owns(true, false)
        if valid {
            valid = boundary("remove-only-B", beforeQueued: true, beforeHelper: false,
                afterQueued: false, afterHelper: false) { buffer.player.remove(b) }
        }
        var attached: UInt64 = 0
        var attachmentAccepted = false, attachmentAttempted = false
        var attachmentOutcome = OPDebugNativeAttachmentOutcome.observationUnavailable
        if valid {
            valid = boundary("attach-same-B", beforeQueued: false, beforeHelper: false,
                afterQueued: false, afterHelper: true, afterSDKAuthorized: { attachmentAccepted }) {
                    attached = DispatchTime.now().uptimeNanoseconds
                    attachmentAttempted = true
                    attachmentOutcome = OPDebugClassifyPlayerAttachment(created, item: b, token: owner.token)
                    attachmentAccepted = attachmentOutcome == .accepted
                }
        }
        let ownershipRejected = attachmentAttempted && attachmentOutcome == .ownershipRejected
        valid = valid && attachmentAccepted
        let deadline = attached + 1_000_000_000
        let callback = PreparedNextPrerollCallback(token: owner.token, deadline: deadline)
        let callbackToken = owner.token
        owner.callback = callback
        let setupReturn = DispatchTime.now().uptimeNanoseconds
        valid = valid && attached > 0 && setupReturn - setupEntry <= 250_000_000
        let refusalSetupValid = ownershipRejected && attached > 0 && setupReturn - setupEntry <= 250_000_000
        // Both arms observe readiness and dwell to the SAME fixed deadline. ON's
        // completion never shortens it; readiness never extends it.
        while valid, DispatchTime.now().uptimeNanoseconds < deadline {
            valid = owns(false, true)
            guard valid else { break }
            let ready = created.status == .readyToPlay && b.status == .readyToPlay
            let now = DispatchTime.now().uptimeNanoseconds
            if readyNs == nil, ready, now < deadline { readyNs = now }
            if owner.enabled, readyNs != nil, !issued, now < deadline {
                valid = boundary("native-preroll", beforeQueued: false, beforeHelper: true,
                    afterQueued: false, afterHelper: true) {
                    guard DispatchTime.now().uptimeNanoseconds < deadline,
                          created.status == .readyToPlay, b.status == .readyToPlay else { return }
                    issued = true; owner.issuedPreroll = true
                    created.preroll(atRate: 1) { finished in
                        callback.complete(token: callbackToken, finished: finished)
                    }
                }
            }
            let observation = DispatchTime.now().uptimeNanoseconds
            if callback.snapshot.count > 0, observedCallbackNs == nil { observedCallbackNs = observation }
            let remaining = deadline > observation ? deadline - observation : 0
            if remaining > 0 {
                do { try await Task.sleep(nanoseconds: min(10_000_000, remaining)) }
                catch { valid = false }
                valid = owns(false, true) && valid // Revalidate after every await, including cancellation.
            }
        }
        let dwellReturned = DispatchTime.now().uptimeNanoseconds
        let dwellDelay = dwellReturned > deadline ? dwellReturned - deadline : 0
        // A common 50 ms scheduling/SDK-return quality cap is not extra dwell.
        // Both arms request cleanup at exactly the fixed deadline; no late result qualifies.
        if attachmentAccepted {
            valid = owns(false, true) && valid && dwellReturned >= deadline
                && dwellDelay <= 50_000_000 && readyNs != nil
        } else { valid = false }
        // Always clean the exact helper, even after a failed ownership observation.
        #if DEBUG
        diagnosticStage("cleanup-cancel", "entry")
        #endif
        let cancelEntry = DispatchTime.now().uptimeNanoseconds
        let cancelSucceeded = OPDebugCancelPlayerPrerolls(created, token: owner.token)
        let cancelReturn = DispatchTime.now().uptimeNanoseconds
        #if DEBUG
        diagnosticStage("cleanup-cancel", "raw-return", cachedNs: cancelReturn)
        #endif
        guard cancelSucceeded else {
            retainUnresolvedCleanup("cancel-rejected")
            XCTFail("Native cleanup cancellation failed; retain the exact owners without querying the helper")
            throw SelectionVideoTestFailure.timeout
        }
        #if DEBUG
        diagnosticStage("cleanup-owner", "entry")
        #endif
        if attachmentAccepted { valid = owns(false, true) && valid }
        #if DEBUG
        diagnosticStage("cleanup-owner", "combined-valid-result", result: valid)
        #endif
        #if DEBUG
        diagnosticStage("cleanup-detach", "entry")
        #endif
        let detachEntry = DispatchTime.now().uptimeNanoseconds
        let detachSucceeded = cancelSucceeded && OPDebugObservePlayerAttachment(created, item: nil, token: owner.token)
        let detachReturn = DispatchTime.now().uptimeNanoseconds
        #if DEBUG
        diagnosticStage("cleanup-detach", "raw-return", cachedNs: detachReturn)
        #endif
        guard detachSucceeded else {
            retainUnresolvedCleanup("detach-rejected")
            XCTFail("Native cleanup detachment failed; retain the exact owners without querying the helper")
            throw SelectionVideoTestFailure.timeout
        }
        let detachDelay = detachReturn > deadline ? detachReturn - deadline : 0
        let detached = detachSucceeded && created.currentItem == nil
        valid = owns(false, false) && valid && detachDelay <= 50_000_000
        let cleanupDeadline = cancelEntry + 250_000_000
        while issued, callback.snapshot.count == 0, DispatchTime.now().uptimeNanoseconds < cleanupDeadline {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < cleanupDeadline else { break }
            do { try await Task.sleep(nanoseconds: min(10_000_000, cleanupDeadline - now)) }
            catch { break }
            valid = owns(false, false) && valid
            if callback.snapshot.count > 0, observedCallbackNs == nil {
                observedCallbackNs = DispatchTime.now().uptimeNanoseconds
            }
        }
        let native = callback.snapshot
        let cleanupReturned = DispatchTime.now().uptimeNanoseconds
        if native.count > 0, observedCallbackNs == nil { observedCallbackNs = cleanupReturned }
        owner.cleanupAcknowledged = cancelSucceeded && detached && (issued ? native.count == 1 : native.count == 0)
            && cancelReturn <= cleanupDeadline && detachReturn <= cleanupDeadline
            && cleanupReturned <= cleanupDeadline
        let timelySuccess = issued && native.count == 1 && native.finished == true
            && native.time.map { $0 <= deadline } == true
        valid = valid && owner.cleanupAcknowledged && (owner.enabled ? timelySuccess : native.count == 0)
        callbackFinalized = owner.cleanupAcknowledged
        if owner.cleanupAcknowledged { helper = nil; owner.helper = nil }
        // Treatment validity stays false after native rejection. Restoration is
        // independently authorized only by the exact original owners and close.
        var restorationEligible = owner.cleanupAcknowledged && owns(false, false)
        var restored = false
        if restorationEligible {
            var canInsert = false
            restorationEligible = boundary("can-insert-same-B", beforeQueued: false, beforeHelper: false,
                afterQueued: false, afterHelper: false, afterSDKAuthorized: { canInsert }) {
                    canInsert = OPDebugCanRestoreQueueItem(buffer.player, item: b, after: a, token: owner.token)
                } && canInsert
        }
        if restorationEligible {
            var inserted = false
            restored = boundary("reinsert-same-B-after-same-A", beforeQueued: false, beforeHelper: false,
                afterQueued: true, afterHelper: false, afterSDKAuthorized: { inserted }) {
                    inserted = OPDebugRestoreQueueItem(buffer.player, item: b, after: a, token: owner.token)
                } && inserted
        }
        owner.cleanupAcknowledged = owner.cleanupAcknowledged && restored
        valid = valid && restored
        print("PreparedNextPrerollRejectedSetup schema=1 token=\(owner.token) attachmentAccepted=\(attachmentAccepted) restored=\(restored) experimentValid=\(valid) fixedBudgetsUnchanged=true consumingProbeAuthorized=\(valid)")
        guard restored else {
            retainUnresolvedCleanup("queue-restoration-unconfirmed")
            XCTFail("The exact original queue could not be restored; retain owners without further SDK queries")
            throw SelectionVideoTestFailure.timeout
        }
        if ownershipRejected {
            // Refusal changes the platform-capability expectation, never A's
            // observation window. Restore first; observe only the original A/B
            // owners until the SAME attachment-based deadline, without reset.
            var refusalObservationValid = refusalSetupValid && owner.cleanupAcknowledged && restored
                && !issued && !owner.issuedPreroll && callback.snapshot.count == 0 && owns(true, false)
            while refusalObservationValid, DispatchTime.now().uptimeNanoseconds < deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { break }
                do { try await Task.sleep(nanoseconds: min(10_000_000, deadline - now)) }
                catch { refusalObservationValid = false }
                refusalObservationValid = owns(true, false) && refusalObservationValid
                    && !issued && !owner.issuedPreroll && callback.snapshot.count == 0
            }
            let refusalObservationReturned = DispatchTime.now().uptimeNanoseconds
            let refusalObservationDelay = refusalObservationReturned > deadline
                ? refusalObservationReturned - deadline : 0
            refusalObservationValid = owns(true, false) && refusalObservationValid
                && refusalObservationReturned >= deadline && refusalObservationDelay <= 50_000_000
                && !issued && !owner.issuedPreroll && callback.snapshot.count == 0
            print("PreparedNextPrerollRefusalObservation schema=1 token=\(owner.token) requestedTreatment=\(owner.enabled) actualIssued=\(issued) fixedDeadlineNs=\(deadline) returnNs=\(refusalObservationReturned) delayNs=\(refusalObservationDelay) maximumObserverDelayNs=50000000 observedThroughOriginalDeadline=\(refusalObservationReturned >= deadline) qualified=\(refusalObservationValid) nativeOutcome=ownershipRejected capabilitySuccess=false consumingProbeAuthorized=false latencyEvidence=false")
            XCTAssertTrue(refusalObservationValid, "An exact native ownership refusal must preserve restored A/B owners and zero preroll through the original fixed observation deadline")
            guard refusalObservationValid else {
                retainUnresolvedCleanup("refusal-observation-unqualified")
                throw SelectionVideoTestFailure.timeout
            }
        }
        print("PreparedNextPrerollArm schema=1 token=\(owner.token) order=\(owner.order) ordinal=\(owner.ordinal) enabled=\(owner.enabled) setupEntryNs=\(setupEntry) setupReturnNs=\(setupReturn) attachedNs=\(attached) fixedDeadlineNs=\(deadline) dwellReturnNs=\(dwellReturned) dwellDelayNs=\(dwellDelay) detachDelayNs=\(detachDelay) maximumObserverDelayNs=50000000 readyNs=\(readyNs.map { String($0) } ?? "missing") issued=\(issued) callbackCountCappedAtTwo=\(native.count) callbackResult=\(native.finished.map { String($0) } ?? "missing") callbackNativeNs=\(native.time.map { String($0) } ?? "missing") callbackObservedNs=\(observedCallbackNs.map { String($0) } ?? "missing") cancelEntryNs=\(cancelEntry) cancelReturnNs=\(cancelReturn) detachEntryNs=\(detachEntry) detachReturnNs=\(detachReturn) cleanupReturnNs=\(cleanupReturned) helperDetached=\(detached) cleanupAcknowledged=\(owner.cleanupAcknowledged) restored=\(restored) helperRate=\(created.rate) helperMuted=\(created.isMuted) latencyEvidence=false compositorPixels=unmeasured")
        if owner.cleanupAcknowledged {
            owner.helper = nil; owner.item = nil; owner.resource = nil; owner.fixture = nil
        } else {
            Self.unresolvedPreparedPrerollOwner = owner
            Self.targetedFixtureOwnershipLost = true
        }
        if ownershipRejected {
            print("PreparedNextPrerollOutcome schema=1 token=\(owner.token) requestedTreatment=\(owner.enabled) actualIssued=\(issued) outcome=refusedRestored cleanupAcknowledged=\(owner.cleanupAcknowledged) restored=\(restored) capabilitySuccess=false consumingProbeAuthorized=false latencyEvidence=false")
            return PreparedNextPrerollTransfer(outcome: .refusedRestored, ownersStable: { @MainActor in
                owns(true, false) && !owner.issuedPreroll && callback.snapshot.count == 0
            })
        }
        XCTAssertTrue(valid, "Matched helper setup, readiness, timely native result, ownership, cleanup and reinsertion must all be valid before the sole output probe")
        guard valid else { throw SelectionVideoTestFailure.timeout }
        print("PreparedNextPrerollOutcome schema=1 token=\(owner.token) requestedTreatment=\(owner.enabled) actualIssued=\(issued) outcome=qualifiedCapability cleanupAcknowledged=\(owner.cleanupAcknowledged) restored=\(restored) consumingProbeAuthorized=true compositorPixels=unmeasured latencyEvidence=false")
        return PreparedNextPrerollTransfer(outcome: .qualifiedCapability, ownersStable: { @MainActor in owns(true, false) })
    }

    private func assertPreparedNextPrerollContinuity(_ result: ProductionRendererProbe.Result,
        tap: ProductionSelectionOutputTap, first: Int, audio: ContinuousAudioPlayer,
        service: PlaybackService, fixture: SelectionVideoFixture,
        baseline: ContinuousPCMRenderer.Snapshot) {
        let last = tap.stop(), final = audio.renderer.snapshot
        let recorded = tap.samples(from: first, to: last), samples = result.samples
        let validity = tap.validity()
        let tone = ProductionSelectionOutputTap.toneBlocks(recorded.values, rate: recorded.rate, frequency: 440)
        let tolerance = 2 * Double(max(1, service.audioRenderQuantumFrames)) / 48_000 + 0.005
        XCTAssertGreaterThanOrEqual(samples.count, 5); XCTAssertLessThanOrEqual(samples.count, 128)
        XCTAssertLessThanOrEqual(samples.first.map { Double($0.end - result.origin) / 1_000_000_000 } ?? .infinity, 0.25)
        XCTAssertGreaterThanOrEqual(samples.last.map { Double($0.end - result.origin) / 1_000_000_000 } ?? -1, 0.75)
        XCTAssertFalse(result.acquisitionOutstanding); XCTAssertEqual(result.dropped, 0)
        XCTAssertEqual(validity.invalidTimestamps, 0); XCTAssertEqual(validity.droppedFrames, 0)
        XCTAssertEqual(ProductionSelectionOutputTap.quietRun(recorded.values, rate: recorded.rate), 0)
        XCTAssertLessThanOrEqual(ProductionSelectionOutputTap.maximumTimelineHole(recorded.hosts,
            rate: recorded.rate), 0.5 / max(1, recorded.rate))
        XCTAssertGreaterThan(tone.total, 0); XCTAssertEqual(tone.correct, tone.total)
        XCTAssertTrue(samples.allSatisfy {
            $0.audio.token == baseline.token && $0.audio.visit == baseline.visit
                && $0.audio.selectionVersion == baseline.selectionVersion && !$0.audio.ended
                && $0.audio.underrunFrames == baseline.underrunFrames && $0.end >= $0.begin
                && $0.end - $0.begin <= 5_000_000
        })
        for (before, after) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(after.audio.frame, before.audio.frame)
            let wall = Double(after.end - before.end) / 1_000_000_000
            XCTAssertLessThanOrEqual(wall, 0.25)
            XCTAssertEqual(Double(after.audio.frame - before.audio.frame) / 48_000, wall, accuracy: tolerance)
        }
        XCTAssertEqual(final.token, baseline.token); XCTAssertEqual(final.visit, baseline.visit)
        XCTAssertEqual(final.selectionVersion, baseline.selectionVersion); XCTAssertFalse(final.ended)
        XCTAssertGreaterThan(final.frame, baseline.frame)
        XCTAssertEqual(final.underrunFrames, baseline.underrunFrames)
        let state = productionSelectionState(service, fixture: fixture, audio: audio, id: fixture.aID)
        XCTAssertTrue(state.selected); XCTAssertTrue(state.videoReady); XCTAssertFalse(state.loading)
        if let frame = state.frame, let copied = state.copied {
            XCTAssertTrue(frame.isFinite && copied.isFinite && state.requested.isFinite)
            XCTAssertGreaterThanOrEqual(frame, 0); XCTAssertGreaterThanOrEqual(copied, 0)
            XCTAssertLessThanOrEqual(abs(frame - state.requested), 0.080)
            XCTAssertLessThanOrEqual(abs(copied - frame), 0.080)
        } else { XCTFail("Playing A must retain coherent custom progress through helper work") }
    }

    func testProductionDefaultReadinessRequiresTheSelectedCPPOutput() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            // Intentionally use the production default. Do not select the DEBUG
            // alternative, native-read tracing, a different layer or another player.
            let expectedID = fixture.aID
            var gate: SelectionInitialReadyOrderingProbe?
            var starts = 0, ownerCaptures = 0, sameOwnerRestarts = 0
            var rejectedStarts = 0, staleReadyDeliveries = 0, readyDeliveries = 0
            var ownerConflict = false, overflow = false
            var startOutputs = -1, preparedIdentity = false
            var observedItem: ObjectIdentifier?, observedResource: ObjectIdentifier?
            var observedOutput: ObjectIdentifier?
            service.debugAfterFirstFrameMonitorStart = { [weak service] item in
                guard let service else { return }
                guard starts < 8 else { overflow = true; return }
                starts += 1
                let outputs = item.outputs
                let state = service.debugInitialVideoReadyState
                guard service.queue.currentID == expectedID, audio.selectedID == expectedID,
                      let resource = buffer.resource(for: item), resource.item === item,
                      let output = resource.output, resource.isAttached, resource.isBorrowed,
                      !resource.isRetired, outputs.contains(where: { $0 === output }) else {
                    rejectedStarts += 1; return
                }
                if let gate {
                    if state.generation == gate.generation,
                       observedItem == ObjectIdentifier(item), observedResource == ObjectIdentifier(resource),
                       observedOutput == ObjectIdentifier(output) { sameOwnerRestarts += 1 }
                    else { ownerConflict = true }
                    return // A new owner must not silently replace this control.
                }
                // This hook is synchronous immediately after the real monitor
                // starts, before status KVO registration or a later detach can
                // hide a second output. All identity witnesses are scalar IDs.
                startOutputs = outputs.count; preparedIdentity = true
                observedItem = ObjectIdentifier(item); observedResource = ObjectIdentifier(resource)
                observedOutput = ObjectIdentifier(output)
                gate = SelectionInitialReadyOrderingProbe(generation: state.generation)
                ownerCaptures += 1
            }
            service.onDebugInitialVideoReady = { [weak service] request in
                guard readyDeliveries < 8 else { overflow = true; return }
                readyDeliveries += 1
                guard let service, let gate, request == gate.generation,
                      service.debugInitialVideoReadyState.generation == gate.generation,
                      service.queue.currentID == expectedID, audio.selectedID == expectedID else {
                    staleReadyDeliveries += 1; return
                }
                await gate.hold(request: request)
            }
            defer {
                gate?.release()
                service.debugAfterFirstFrameMonitorStart = nil
                service.onDebugInitialVideoReady = nil
            }
            let initialUnderruns = service.audioSnapshot.underrunFrames
            service.start(playlistIDs: [fixture.playlist], at: expectedID)
            let held = await waitUntil(timeout: 3) {
                guard let gate else { return false }
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return gate.isHolding && ownerCaptures == 1 && rejectedStarts == 0 && !ownerConflict
                    && readyDeliveries > 0 && staleReadyDeliveries == 0
                    && starts == ownerCaptures + sameOwnerRestarts && state.generation == gate.generation
                    && state.readyGeneration != gate.generation && state.syncingVideoGeneration == nil
                    && service.queue.currentID == expectedID && audio.selectedID == expectedID
                    && sample.token > 0 && state.audioVisit == sample.visit && !sample.ended
            }
            XCTAssertTrue(held, "The real selected owner and real initial-ready callback must be held")
            guard held, let gate else { throw SelectionVideoTestFailure.timeout }
            let item = try XCTUnwrap(service.player.currentItem)
            let resource = try XCTUnwrap(buffer.resource(for: item))
            let output = try XCTUnwrap(resource.output)
            let displayLayer = try XCTUnwrap(screen.customVideoLayer)
            let token = try XCTUnwrap(audio.entry(for: expectedID)).token
            XCTAssertTrue(displayLayer.superlayer === service.surface.layer)
            XCTAssertEqual(observedItem, ObjectIdentifier(item))
            XCTAssertEqual(observedResource, ObjectIdentifier(resource))
            XCTAssertEqual(observedOutput, ObjectIdentifier(output))
            XCTAssertTrue(preparedIdentity)
            XCTAssertTrue(resource.isAttached); XCTAssertTrue(resource.isBorrowed)
            XCTAssertFalse(resource.isRetired)
            XCTAssertTrue(item.outputs.contains { $0 === output })
            assertSelection(service, fixture: fixture, id: expectedID)

            // RED contract: the default monitor must observe the actual selected
            // CPP output, rather than attach a second native output. This assertion
            // is independent of AVFoundation scheduling or a screenshot timeout.
            XCTAssertEqual(startOutputs, 1,
                "Production first-frame readiness must reuse the selected CPP output without attaching another output")
            XCTAssertEqual(item.outputs.count, 1)
            XCTAssertFalse(service.isVideoReady,
                "A native-player image cannot uncover the poster while the actual CPP presentation is inactive")
            XCTAssertEqual(service.submittedVideoFrameCount, 0)
            XCTAssertNil(service.copiedVideoFramePositionSeconds)
            XCTAssertNil(service.videoFramePositionSeconds)
            XCTAssertFalse(displayLayer.isReadyForDisplay)

            let baseline = service.audioSnapshot
            let progressed = await waitUntil(timeout: 0.75) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return gate.isHolding && state.generation == gate.generation
                    && state.readyGeneration != gate.generation && state.syncingVideoGeneration == nil
                    && state.audioVisit == sample.visit && sample.token == token
                    && sample.visit == baseline.visit && sample.frame >= baseline.frame + 9_600 && !sample.ended
            }
            let heldClock = captureInitialReadyNativeClock(service)
            let heldSample = service.audioSnapshot
            let heldSubmitted = service.submittedVideoFrameCount
            let heldCopied = service.copiedVideoFramePositionSeconds
            let heldFrame = service.videoFramePositionSeconds
            let heldServiceReady = service.isVideoReady
            let heldCustomReady = displayLayer.isReadyForDisplay
            print("ProductionDefaultReadinessHeld schema=1 defaultMode=true debugModeOverrideWritten=false startOutputs=\(startOutputs) expectedStartOutputs=1 preparedIdentity=\(preparedIdentity) request=\(gate.generation) ownerCaptures=\(ownerCaptures) sameOwnerRestarts=\(sameOwnerRestarts) rejectedStarts=\(rejectedStarts) ownerConflict=\(ownerConflict) readyDeliveries=\(readyDeliveries) staleReadyDeliveries=\(staleReadyDeliveries) progressed=\(progressed) token=\(heldSample.token) visit=\(heldSample.visit) pcmDelta=\(heldSample.frame - baseline.frame) underrunDelta=\(heldSample.underrunFrames - initialUnderruns) submitted=\(heldSubmitted) copiedPresent=\(heldCopied != nil) submittedPTSPresent=\(heldFrame != nil) serviceReady=\(heldServiceReady) customLayerReady=\(heldCustomReady) nativeAcquisitionMs=\(heldClock.acquisitionSeconds * 1000) gateTimedOut=\(gate.timedOut) gateCancelled=\(gate.cancelled) overflow=\(overflow) latencyAcceptance=false physicalOutput=unverified")
            XCTAssertTrue(progressed, "Actual PCM must keep advancing in the same visit while CPP activation is withheld")
            XCTAssertEqual(heldSample.token, token); XCTAssertEqual(heldSample.visit, baseline.visit)
            XCTAssertEqual(heldSample.underrunFrames, initialUnderruns)
            XCTAssertTrue(heldClock.sameIdentity); XCTAssertLessThanOrEqual(heldClock.acquisitionSeconds, 0.005)
            XCTAssertEqual(heldSubmitted, 0); XCTAssertNil(heldCopied); XCTAssertNil(heldFrame)
            XCTAssertFalse(heldServiceReady); XCTAssertFalse(heldCustomReady)
            XCTAssertTrue(gate.isHolding); XCTAssertFalse(gate.timedOut); XCTAssertFalse(gate.cancelled)
            XCTAssertFalse(gate.overflow); XCTAssertEqual(gate.dropped, 0)
            XCTAssertFalse(overflow); XCTAssertFalse(ownerConflict); XCTAssertEqual(rejectedStarts, 0)
            XCTAssertEqual(staleReadyDeliveries, 0)
            guard progressed, heldClock.sameIdentity, heldClock.acquisitionSeconds <= 0.005,
                  gate.isHolding, !gate.timedOut, !gate.cancelled, !overflow, !ownerConflict,
                  staleReadyDeliveries == 0,
                  heldSample.token == token, heldSample.visit == baseline.visit,
                  heldSample.underrunFrames == initialUnderruns else { throw SelectionVideoTestFailure.timeout }

            // Do not abort on the intended one-output/readiness RED assertions:
            // still exercise real activation, fresh submission, 80 ms alignment,
            // same PCM visit/no underrun and actual moving composite pixels.
            try await finishExplicitInitialReadyControl(service, screen: screen, fixture: fixture,
                probe: gate, token: token, baselineUnderruns: initialUnderruns,
                label: "production-default-current-CPP-A")
            XCTAssertTrue(service.player.currentItem === item)
            XCTAssertTrue(buffer.resource(for: item) === resource)
            XCTAssertTrue(resource.output === output)
            XCTAssertTrue(screen.customVideoLayer === displayLayer)
            XCTAssertTrue(displayLayer.superlayer === service.surface.layer)
            XCTAssertTrue(resource.isAttached); XCTAssertTrue(resource.isBorrowed)
            XCTAssertFalse(resource.isRetired); XCTAssertEqual(item.outputs.count, 1)
        }
        #else
        XCTFail("Production-default readiness contract requires existing DEBUG test hooks")
        #endif
    }

    func testSeekAfterVisibleReadinessRequiresFreshCPPImageBeforeReadyReturns() async throws {
        #if DEBUG
        let scheduler = SelectionVideoSeekScheduler()
        defer { scheduler.release() }
        try await withOwnedNaturalFixture(seekVideo: scheduler.seek) { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await requireNativeClockContractOwner(service, fixture: fixture, audio: audio,
                screen: screen, id: fixture.aID)
            service.pause()
            try await require({ !service.wantsToPlay && !service.audioEngineRunning && service.player.rate == 0
                && service.debugInitialVideoReadyState.syncingVideoGeneration == nil && service.isVideoReady },
                "A real current image and the ready latch must settle before the independent seek")
            let item = try XCTUnwrap(service.player.currentItem)
            let displayLayer = try XCTUnwrap(screen.customVideoLayer)
            let request = service.debugInitialVideoReadyState.generation
            let submitted = service.submittedVideoFrameCount
            let blocked = service.videoFrameAcquisitionBlockedCount
            XCTAssertTrue(displayLayer.isReadyForDisplay)
            XCTAssertGreaterThan(submitted, 0)
            XCTAssertEqual(item.outputs.count, 1)

            service.seek(0.4)
            XCTAssertFalse(service.isVideoReady,
                "A ready latch must clear synchronously when the visible image is flushed")
            XCTAssertNil(service.videoFramePositionSeconds)
            XCTAssertNil(service.copiedVideoFramePositionSeconds)
            try await require({ scheduler.isHoldingCompletion && scheduler.nativeFinished == true
                && service.videoFrameAcquisitionBlockedCount >= blocked + 2 },
                "The actual native seek must finish while two real pulls encounter the held completion")
            XCTAssertEqual(service.submittedVideoFrameCount, submitted)
            XCTAssertNil(service.videoFramePositionSeconds)
            XCTAssertNil(service.copiedVideoFramePositionSeconds)
            XCTAssertFalse(service.isVideoReady)
            XCTAssertFalse(displayLayer.isReadyForDisplay)
            XCTAssertEqual(service.debugInitialVideoReadyState.generation, request)
            XCTAssertTrue(service.player.currentItem === item)
            XCTAssertFalse(service.wantsToPlay); XCTAssertFalse(service.audioEngineRunning)
            print("ServiceReadinessAfterSeek schema=1 request=\(request) nativeFinished=\(scheduler.nativeFinished == true) completionHeld=\(scheduler.isHoldingCompletion) blockedDelta=\(service.videoFrameAcquisitionBlockedCount - blocked) submittedBefore=\(submitted) submittedNow=\(service.submittedVideoFrameCount) serviceReady=\(service.isVideoReady) customReady=\(displayLayer.isReadyForDisplay) target=0.4 timingAcceptance=false")

            scheduler.release()
            await assertPausedCustomFrame(service, screen: screen, requested: 0.4, after: submitted,
                label: "ready-latch-recovered-A-0.4")
            try await require({ service.isVideoReady && displayLayer.isReadyForDisplay },
                "Only the fresh actual CPP target may requalify service readiness")
            _ = await assertVisibleFrame(service, screen: screen, identity: .a,
                label: "ready-latch-recovered-A-0.4")
            assertPausedCustomFrameState(service, screen: screen, requested: 0.4, after: submitted,
                label: "ready-latch-recovered-A-0.4-captured")
            XCTAssertTrue(service.player.currentItem === item)
            XCTAssertEqual(service.debugInitialVideoReadyState.generation, request)
            XCTAssertEqual(item.outputs.count, 1)
            XCTAssertFalse(service.wantsToPlay); XCTAssertFalse(service.audioEngineRunning)
        }
        #else
        XCTFail("Service readiness seek ordering requires the existing DEBUG ownership state")
        #endif
    }

    func testFrameReadinessMonitorUsesOnePreparedOutputWhileReadyIsWithheld() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for alternative in [false, true] {
            let buffer = PlaybackBuffer()
            try await withOwnedNaturalFixture(buffer: buffer, recordHost: false) { fixture, audio, service, screen in
                service.isInteractingWithFeed = true
                service.debugUsesCurrentCustomFrameForReadiness = alternative
                service.debugInitialLoadPhaseEnabled = true
                var starts = 0, overflow = false
                defer {
                    service.debugAfterFirstFrameMonitorStart = nil; service.onDebugInitialVideoReady = nil
                    service.debugInitialLoadPhaseEnabled = false
                }
                for phase in 0..<3 {
                    if phase > 0 {
                        try await require({ service.preparedAudioCount == 2
                            && (phase == 1 ? buffer.hasPrepared(fixture.bID)
                                : buffer.previousMediaID == fixture.aID && buffer.debugPreviousNeedsRewind == false) },
                            "Both actual audio and the selected prepared video must exist before the control action")
                    }
                    let expectedID = phase == 1 ? fixture.bID : fixture.aID
                    let previousGeneration = service.debugInitialVideoReadyState.generation
                    let requestedGeneration = previousGeneration + 1 // Diagnostic expectation, not the owner.
                    let beforeStarts = starts
                    var gate: SelectionInitialReadyOrderingProbe?
                    var ownerConflict = false
                    var ownerCaptures = 0, sameOwnerRestarts = 0
                    var rejectedStarts = 0, readyDeliveries = 0, staleReadyDeliveries = 0
                    var observedCount = -1, observedPreparedIdentity = false
                    var observedItem: ObjectIdentifier?, observedResource: ObjectIdentifier?, observedOutput: ObjectIdentifier?
                    service.debugAfterFirstFrameMonitorStart = { [weak service] item in
                        guard let service else { return }
                        guard starts < 8 else { overflow = true; return }
                        starts += 1
                        let outputs = item.outputs
                        let resource = buffer.resource(for: item)
                        let state = service.debugInitialVideoReadyState
                        guard state.generation > previousGeneration,
                              service.queue.currentID == expectedID, audio.selectedID == expectedID,
                              let resource, resource.item === item, let output = resource.output,
                              resource.isAttached, resource.isBorrowed, !resource.isRetired,
                              outputs.contains(where: { $0 === output }) else {
                            rejectedStarts += 1; return
                        }
                        // The hook runs after this exact monitor starts and before
                        // its KVO is registered. Cold retries may have a later generation.
                        if let gate {
                            if state.generation == gate.generation,
                               observedItem == ObjectIdentifier(item),
                               observedResource == ObjectIdentifier(resource),
                               observedOutput == ObjectIdentifier(output) { sameOwnerRestarts += 1 }
                            else { ownerConflict = true }
                            return // Never rearm or rehold a captured owner.
                        }
                        observedCount = outputs.count; observedPreparedIdentity = true
                        observedItem = ObjectIdentifier(item); observedResource = ObjectIdentifier(resource)
                        observedOutput = ObjectIdentifier(output)
                        gate = SelectionInitialReadyOrderingProbe(generation: state.generation)
                        ownerCaptures += 1
                    }
                    service.onDebugInitialVideoReady = { [weak service] request in
                        guard readyDeliveries < 8 else { overflow = true; return }
                        readyDeliveries += 1
                        guard let service, let gate, request == gate.generation,
                              service.debugInitialVideoReadyState.generation == gate.generation,
                              service.queue.currentID == expectedID, audio.selectedID == expectedID else {
                            staleReadyDeliveries += 1; return
                        }
                        await gate.hold(request: request)
                    }
                    defer { gate?.release() }
                    switch phase {
                    case 0: service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
                    case 1: service.next()
                    default: service.previous()
                    }
                    let held = await waitUntil(timeout: 3) {
                        guard let gate else { return false }
                        return gate.isHolding && ownerCaptures == 1 && rejectedStarts == 0 && !ownerConflict
                            && starts == beforeStarts + 1 + sameOwnerRestarts
                            && service.debugInitialVideoReadyState.generation == gate.generation
                            && service.queue.currentID == expectedID && audio.selectedID == expectedID
                    }
                    if !held {
                        let state = service.debugInitialVideoReadyState, load = service.debugInitialLoadPhaseState
                        print("FrameMonitorHeldGateFailure schema=1 alternative=\(alternative) phase=\(phase) requestedGeneration=\(requestedGeneration) ownerGeneration=\(gate.map { String($0.generation) } ?? "unknown") currentGeneration=\(state.generation) readyGeneration=\(state.readyGeneration.map { String($0) } ?? "unknown") beforeStarts=\(beforeStarts) starts=\(starts) ownerCaptures=\(ownerCaptures) sameOwnerRestarts=\(sameOwnerRestarts) rejectedStarts=\(rejectedStarts) ownerConflict=\(ownerConflict) readyDeliveries=\(readyDeliveries) staleReadyDeliveries=\(staleReadyDeliveries) gateEntered=\(gate?.entered ?? 0) gateActive=\(gate?.active ?? 0) gateTimedOut=\(gate?.timedOut ?? false) gateCancelled=\(gate?.cancelled ?? false) gateOverflow=\(gate?.overflow ?? false) gateDropped=\(gate?.dropped ?? 0) overflow=\(overflow) loadEnabled=\(load.enabled) loadRequest=\(load.request) loadGeneration=\(load.generation) loadPhase=\(load.phase.rawValue)")
                    }
                    XCTAssertTrue(held)
                    guard held, let gate else { throw SelectionVideoTestFailure.timeout }
                    let request = gate.generation
                    let current = try XCTUnwrap(service.player.currentItem)
                    let resource = try XCTUnwrap(buffer.resource(for: current))
                    let preparedOutput = try XCTUnwrap(resource.output)
                    let outputs = current.outputs
                    // The default monitor may legitimately finish and detach
                    // before this async held observation. Its exact two-output
                    // attachment is proved synchronously at start, before KVO.
                    XCTAssertEqual(observedCount, alternative ? 1 : 2)
                    if alternative { XCTAssertEqual(outputs.count, 1) }
                    else { XCTAssertTrue(outputs.count == 1 || outputs.count == 2) }
                    XCTAssertTrue(observedPreparedIdentity)
                    XCTAssertEqual(observedItem, ObjectIdentifier(current))
                    XCTAssertEqual(observedResource, ObjectIdentifier(resource))
                    XCTAssertEqual(observedOutput, ObjectIdentifier(preparedOutput))
                    XCTAssertTrue(outputs.contains { $0 === preparedOutput })
                    XCTAssertTrue(resource.isAttached); XCTAssertTrue(resource.isBorrowed)
                    XCTAssertFalse(resource.isRetired)
                    XCTAssertNil(service.copiedVideoFramePositionSeconds)
                    XCTAssertNil(service.videoFramePositionSeconds)
                    XCTAssertNotEqual(service.debugInitialVideoReadyState.readyGeneration, request)
                    XCTAssertFalse(gate.timedOut); XCTAssertFalse(gate.cancelled); XCTAssertFalse(gate.overflow)
                    XCTAssertEqual(gate.dropped, 0); XCTAssertFalse(overflow)
                    XCTAssertFalse(ownerConflict); XCTAssertEqual(rejectedStarts, 0); XCTAssertEqual(ownerCaptures, 1)
                    print("FrameMonitorHeldReady schema=1 alternative=\(alternative) phase=\(phase) startOutputs=\(observedCount) heldOutputs=\(outputs.count) expectedStartOutputs=\(alternative ? 1 : 2) preparedIdentity=\(observedPreparedIdentity) currentEpochImage=false request=\(request) held=true startBeforeStatusObservation=true")
                    gate.release()
                    try await require({ self.explicitInitialReadySourceSettled(service, screen: screen) },
                                      "Actual selected custom/native readiness must settle after releasing the real callback")
                    XCTAssertFalse(gate.isHolding, "This source's gate must be released before the next source action")
                    XCTAssertFalse(ownerConflict); XCTAssertEqual(ownerCaptures, 1)
                    XCTAssertEqual(service.debugInitialVideoReadyState.generation, request)
                    assertSelection(service, fixture: fixture, id: phase == 1 ? fixture.bID : fixture.aID)
                    XCTAssertEqual(service.audioSnapshot.underrunFrames, 0)
                }
                let visible = await assertVisibleFrame(service, screen: screen, identity: .a,
                    label: alternative ? "monitor-single-output-returned-A" : "monitor-default-output-returned-A")
                XCTAssertNotNil(visible)
            }
        }
        #else
        XCTFail("Frame-monitor diagnostic requires DEBUG controls")
        #endif
    }

    func testReturnedChannelAuditDistinguishesStereoSilenceFromAntiphaseCancellation() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        func buffer(left: Float, right: Float) throws -> AVAudioPCMBuffer {
            let result = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            result.frameLength = 480
            let channels = try XCTUnwrap(result.floatChannelData)
            for frame in 0..<480 { channels[0][frame] = left; channels[1][frame] = right }
            return result
        }
        func time(_ frame: Int) -> AVAudioTime {
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100 + Double(frame) / 48_000))
        }
        for stereoSilent in [true, false] {
            let tap = ProductionSelectionOutputTap()
            let pcm = try buffer(left: stereoSilent ? 0 : 0.25, right: stereoSilent ? 0 : -0.25)
            XCTAssertEqual(tap.begin(auditChannels: true), 0)
            tap.append(pcm, time: time(0))
            let end = tap.stop()
            XCTAssertEqual(tap.stop(), end)
            let audit = tap.channelAudit()
            let mono = tap.samples(from: 0, to: end)
            XCTAssertEqual(mono.values.count, 480)
            XCTAssertTrue(mono.values.allSatisfy { $0 == 0 })
            // Both arms still fail the benchmark's original zero-quiet acceptance.
            XCTAssertEqual(ProductionSelectionOutputTap.quietRun(mono.values, rate: mono.rate), 0.01)
            XCTAssertFalse(ProductionSelectionOutputTap.isTone(mono.values, rate: mono.rate, frequency: 440))
            XCTAssertEqual(audit.observedFrames, 480); XCTAssertEqual(audit.minimumRunFrames, 480)
            XCTAssertEqual(audit.monoZeroFrames, 480)
            XCTAssertEqual(audit.stereoZeroFrames, stereoSilent ? 480 : 0)
            XCTAssertEqual(audit.leftSquareSum, stereoSilent ? 0 : 30)
            XCTAssertEqual(audit.rightSquareSum, stereoSilent ? 0 : 30)
            XCTAssertEqual(audit.nonfiniteFrames, 0)
            XCTAssertTrue(audit.stereoZeroEvidenceQualified)
            XCTAssertEqual(audit.layout.buffers, 1); XCTAssertEqual(audit.layout.frames, 480)
            XCTAssertEqual(audit.layout.firstChannelCount, 2); XCTAssertEqual(audit.layout.lastChannelCount, 2)
            XCTAssertFalse(audit.layout.firstInterleaved); XCTAssertFalse(audit.layout.lastInterleaved)
            XCTAssertEqual(audit.layout.firstRate, 48_000); XCTAssertEqual(audit.layout.lastRate, 48_000)
            XCTAssertFalse(audit.layout.changed)
            XCTAssertEqual(audit.layout.monoDuplicatedFrames, 0)
            XCTAssertEqual(audit.layout.stereoInputFrames, 480); XCTAssertEqual(audit.layout.otherInputFrames, 0)
            XCTAssertEqual(audit.qualifiedRuns, 1); XCTAssertEqual(audit.retainedRuns, 1)
            XCTAssertEqual(audit.droppedRuns, 0); XCTAssertFalse(audit.overflow)
            let run = try XCTUnwrap(audit.run(at: 0))
            XCTAssertEqual(run.frames, 480); XCTAssertEqual(run.firstFrame, 0); XCTAssertEqual(run.endFrame, 480)
            XCTAssertEqual(run.stereoZeroFrames, stereoSilent ? 480 : 0)
            XCTAssertEqual(run.leftSquareSum, stereoSilent ? 0 : 30)
            XCTAssertEqual(run.rightSquareSum, stereoSilent ? 0 : 30)
            XCTAssertNil(audit.run(at: 1)); XCTAssertNil(audit.run(at: 4))
        }
        // Actual mono zero is duplicated by the unchanged mono oracle. The old
        // stereoZeroFrames value remains visible, but cannot establish two channels.
        let monoFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let monoPCM = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 480))
        monoPCM.frameLength = 480
        try XCTUnwrap(monoPCM.floatChannelData)[0].update(repeating: 0, count: 480)
        let monoTap = ProductionSelectionOutputTap()
        monoTap.begin(auditChannels: true); monoTap.append(monoPCM, time: time(0)); monoTap.stop()
        let monoAudit = monoTap.channelAudit()
        XCTAssertEqual(monoAudit.stereoZeroFrames, 480, "Existing duplicated-mono observation is unchanged")
        XCTAssertFalse(monoAudit.stereoZeroEvidenceQualified)
        XCTAssertEqual(monoAudit.layout.firstChannelCount, 1); XCTAssertEqual(monoAudit.layout.lastChannelCount, 1)
        XCTAssertEqual(monoAudit.layout.monoDuplicatedFrames, 480)
        XCTAssertEqual(monoAudit.layout.stereoInputFrames, 0); XCTAssertEqual(monoAudit.layout.otherInputFrames, 0)
        XCTAssertFalse(monoAudit.layout.firstInterleaved); XCTAssertFalse(monoAudit.layout.changed)
        let monoRecording = monoTap.samples(from: 0, to: monoTap.count)
        XCTAssertTrue(monoRecording.values.allSatisfy { $0 == 0 })
        XCTAssertEqual(ProductionSelectionOutputTap.quietRun(monoRecording.values, rate: monoRecording.rate), 0.01)

        let emptyTap = ProductionSelectionOutputTap()
        monoPCM.frameLength = 0
        emptyTap.begin(auditChannels: true); emptyTap.append(monoPCM, time: time(0)); emptyTap.stop()
        let emptyAudit = emptyTap.channelAudit()
        XCTAssertEqual(emptyAudit.observedFrames, 0)
        XCTAssertEqual(emptyAudit.layout.buffers, 0); XCTAssertEqual(emptyAudit.layout.frames, 0)
        XCTAssertFalse(emptyAudit.layout.allInputActualStereo); XCTAssertFalse(emptyAudit.stereoZeroEvidenceQualified)
        monoPCM.frameLength = 480

        let packedFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 2, interleaved: true))
        let packedPCM = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: packedFormat, frameCapacity: 480))
        packedPCM.frameLength = 480
        let packed = try XCTUnwrap(packedPCM.floatChannelData)[0]
        for frame in 0..<480 { packed[frame * 2] = 0.25; packed[frame * 2 + 1] = -0.25 }
        let packedTap = ProductionSelectionOutputTap()
        packedTap.begin(auditChannels: true); packedTap.append(packedPCM, time: time(0)); packedTap.stop()
        let packedAudit = packedTap.channelAudit()
        XCTAssertTrue(packedAudit.stereoZeroEvidenceQualified)
        XCTAssertTrue(packedAudit.layout.firstInterleaved); XCTAssertTrue(packedAudit.layout.lastInterleaved)
        XCTAssertEqual(packedAudit.layout.stereoInputFrames, 480)
        XCTAssertEqual(packedAudit.stereoZeroFrames, 0); XCTAssertEqual(packedAudit.monoZeroFrames, 480)

        let mixedTap = ProductionSelectionOutputTap()
        mixedTap.begin(auditChannels: true)
        mixedTap.append(monoPCM, time: time(0)); mixedTap.append(packedPCM, time: time(480)); mixedTap.stop()
        let mixedAudit = mixedTap.channelAudit()
        XCTAssertTrue(mixedAudit.layout.changed); XCTAssertFalse(mixedAudit.stereoZeroEvidenceQualified)
        XCTAssertEqual(mixedAudit.layout.buffers, 2); XCTAssertEqual(mixedAudit.layout.frames, 960)
        XCTAssertEqual(mixedAudit.layout.firstChannelCount, 1); XCTAssertEqual(mixedAudit.layout.lastChannelCount, 2)
        XCTAssertFalse(mixedAudit.layout.firstInterleaved); XCTAssertTrue(mixedAudit.layout.lastInterleaved)
        XCTAssertEqual(mixedAudit.layout.monoDuplicatedFrames, 480)
        XCTAssertEqual(mixedAudit.layout.stereoInputFrames, 480)
        XCTAssertEqual(mixedAudit.observedFrames, 960); XCTAssertEqual(mixedAudit.monoZeroFrames, 960)
        XCTAssertEqual(mixedAudit.stereoZeroFrames, 480)
        let overflowTap = ProductionSelectionOutputTap()
        let zero = try buffer(left: 0, right: 0), tone = try buffer(left: 0.25, right: 0.25)
        overflowTap.begin(auditChannels: true)
        for ordinal in 0..<5 {
            overflowTap.append(zero, time: time(ordinal * 960))
            overflowTap.append(tone, time: time(ordinal * 960 + 480))
        }
        overflowTap.stop()
        let overflow = overflowTap.channelAudit()
        XCTAssertEqual(overflow.observedFrames, 4_800); XCTAssertEqual(overflow.monoZeroFrames, 2_400)
        XCTAssertEqual(overflow.qualifiedRuns, 5); XCTAssertEqual(overflow.retainedRuns, 4)
        XCTAssertEqual(overflow.droppedRuns, 1); XCTAssertTrue(overflow.overflow)
        for ordinal in 0..<4 {
            let run = try XCTUnwrap(overflow.run(at: ordinal))
            XCTAssertEqual(run.firstFrame, ordinal * 960); XCTAssertEqual(run.frames, 480)
        }
        XCTAssertNil(overflow.run(at: 4))
        #if DEBUG
        // Same classifier/window alignment as the live loop. These pure controls
        // prove captured-tail interpretation, not a real SDK scheduling failure.
        func recording(_ frequency: (Int) -> Double?) -> ProductionSelectionOutputTap.Recording {
            let values = (0..<5_760).map { frame -> Float in
                guard let hz = frequency(frame) else { return 0 }
                return Float(0.2 * sin(2 * Double.pi * hz * Double(frame) / 48_000))
            }
            return .init(values: values, hosts: (0..<5_760).map { 100 + Double($0) / 48_000 }, rate: 48_000)
        }
        let changed = recording { $0 < 3_840 ? 440 : 880 }
        let replay = ProductionSelectionOutputTap.replayTone(changed, origin: 100.019, frequency: 880,
            firstIndex: 0, onlineNextCursor: 480, expectedFrames: changed.values.count)
        XCTAssertTrue(replay.available); XCTAssertGreaterThan(replay.targetWindows, 0)
        XCTAssertGreaterThan(replay.alternateWindows, 0)
        XCTAssertGreaterThanOrEqual(replay.firstTargetIndex, 480)
        XCTAssertTrue(replay.targetWasUnsearched)
        let visited = ProductionSelectionOutputTap.replayTone(changed, origin: 100.019, frequency: 880,
            firstIndex: 0, onlineNextCursor: replay.firstTargetIndex + 480, expectedFrames: changed.values.count)
        XCTAssertFalse(visited.targetWasUnsearched)
        XCTAssertEqual(visited.firstTargetIndex, replay.firstTargetIndex)
        XCTAssertEqual(visited.firstTarget?.start, replay.firstTarget?.start)
        let alternate = recording { _ in 440 }
        let other = ProductionSelectionOutputTap.replayTone(alternate, origin: 100.019, frequency: 880,
            firstIndex: 0, onlineNextCursor: 480, expectedFrames: alternate.values.count)
        XCTAssertTrue(other.available); XCTAssertEqual(other.targetWindows, 0)
        XCTAssertGreaterThan(other.alternateWindows, 0); XCTAssertNil(other.firstTarget)
        let quietRecording = recording { _ in nil }
        let missing = ProductionSelectionOutputTap.replayTone(quietRecording, origin: 100.019, frequency: 880,
            firstIndex: 0, onlineNextCursor: 480, expectedFrames: quietRecording.values.count)
        XCTAssertTrue(missing.available); XCTAssertNil(missing.firstTarget); XCTAssertNil(missing.firstAlternate)
        XCTAssertEqual(missing.targetWindows, 0); XCTAssertEqual(missing.alternateWindows, 0)
        let truncated = ProductionSelectionOutputTap.replayTone(changed, origin: 100.019, frequency: 880,
            firstIndex: 0, onlineNextCursor: 480, expectedFrames: changed.values.count + 1)
        XCTAssertFalse(truncated.available)
        // Pure bookkeeping controls, using supplied monotonic values rather
        // than a claimed SDK latency or a fabricated readiness observation.
        let poll = ProductionSelectionPollSummary()
        poll.setDeadline(phase: 0, uptime: 1)
        poll.bodyEntered(phase: 0, at: 10)
        poll.stageEntered(phase: 0, stage: .toneScan, at: 12)
        poll.stageReturned(phase: 0, stage: .toneScan, at: 20)
        poll.stageEntered(phase: 0, stage: .stateCapture, at: 22)
        poll.stageReturned(phase: 0, stage: .stateCapture, at: 60)
        poll.stageEntered(phase: 0, stage: .readinessEvaluation, at: 62)
        poll.stageReturned(phase: 0, stage: .readinessEvaluation, at: 70, layerReadyPredicateEvaluated: true)
        poll.bodyReturned(phase: 0, at: 80)
        poll.bodyEntered(phase: 0, at: 180)
        poll.stageEntered(phase: 0, stage: .toneScan, at: 182)
        poll.stageReturned(phase: 0, stage: .toneScan, at: 190)
        poll.stageEntered(phase: 0, stage: .stateCapture, at: 192)
        poll.stageReturned(phase: 0, stage: .stateCapture, at: 200)
        poll.stageEntered(phase: 0, stage: .readinessEvaluation, at: 202)
        poll.stageReturned(phase: 0, stage: .readinessEvaluation, at: 210)
        poll.bodyReturned(phase: 0, at: 220)
        poll.loopExited(phase: 0, at: 230, nextCursor: 960)
        let completed = try XCTUnwrap(poll.snapshot(phase: 0))
        XCTAssertEqual(completed.entered, 2); XCTAssertEqual(completed.returned, 2)
        XCTAssertEqual(completed.state.first?.begin, 22); XCTAssertEqual(completed.state.worst?.duration, 38)
        XCTAssertEqual(completed.largestGap?.begin, 80); XCTAssertEqual(completed.largestGap?.end, 180)
        XCTAssertFalse(completed.bodyOpen); XCTAssertFalse(completed.stageOpen)
        XCTAssertEqual(completed.readiness.first?.layerReadyPredicateEvaluated, true)
        poll.bodyEntered(phase: 1, at: 300)
        poll.stageEntered(phase: 1, stage: .stateCapture, at: 310)
        let open = try XCTUnwrap(poll.snapshot(phase: 1))
        XCTAssertTrue(open.bodyOpen); XCTAssertTrue(open.stageOpen)
        XCTAssertEqual(open.lastEntry, 300); XCTAssertEqual(open.stageEntry, 310)
        XCTAssertEqual(open.stageReturn, 0); XCTAssertEqual(open.returned, 0)
        #endif
    }

    private func runProductionSelectionBenchmark(traceVideoSeeks: Bool, frameMonitorAlternative: Bool? = nil,
                                                recordHost: Bool = true, traceNativeRefill: Bool = false,
                                                renderAccounting: Bool? = nil, traceDefaultFrameMonitor: Bool? = nil,
                                                auditSavedAAfterCleanup: Bool = false,
                                                traceClockHandoff: Bool? = nil,
                                                freshPreviousBundle: Bool? = nil,
                                                suppressNativePlayerRendering: Bool? = nil,
                                                nativeVideoGeometry: Bool? = nil,
                                                traceFirstSourceFailure: Bool? = nil,
                                                queuedPreviousLead: Bool? = nil) async throws {
        if recordHost { try recordRuntimeHost() }
        #if DEBUG
        if let enabled = traceFirstSourceFailure {
            guard !traceVideoSeeks, frameMonitorAlternative == nil, traceNativeRefill == enabled,
                  renderAccounting == nil, traceDefaultFrameMonitor == nil, !auditSavedAAfterCleanup,
                  traceClockHandoff == nil, freshPreviousBundle == nil, queuedPreviousLead == nil,
                  suppressNativePlayerRendering == nil, nativeVideoGeometry == nil,
                  acceptedPCMOriginBenchmarkMode == nil else {
                XCTFail("First-failure control requires its matched native bundle and otherwise unset default benchmark")
                throw SelectionVideoTestFailure.timeout
            }
        }
        if suppressNativePlayerRendering != nil || nativeVideoGeometry != nil {
            guard !traceVideoSeeks, frameMonitorAlternative == nil, !traceNativeRefill,
                  renderAccounting == nil, traceDefaultFrameMonitor == nil,
                  !auditSavedAAfterCleanup, traceClockHandoff == nil,
                  freshPreviousBundle == nil, queuedPreviousLead == nil, acceptedPCMOriginBenchmarkMode == nil,
                  !(suppressNativePlayerRendering != nil && nativeVideoGeometry != nil) else {
                XCTFail("Suppression control requires the otherwise unset production benchmark")
                throw SelectionVideoTestFailure.timeout
            }
        }
        #else
        if traceFirstSourceFailure != nil {
            XCTFail("First-failure control is unavailable outside DEBUG")
            throw SelectionVideoTestFailure.timeout
        }
        if suppressNativePlayerRendering != nil || nativeVideoGeometry != nil {
            XCTFail("Suppression control is unavailable outside DEBUG")
            throw SelectionVideoTestFailure.timeout
        }
        #endif
        guard !Self.targetedFixtureOwnershipLost else {
            XCTFail("A previous targeted fixture did not acknowledge cleanup; no new owners may be created")
            return
        }
        let fixture = try await SelectionVideoFixture()
        #if DEBUG
        // Freeze the exact Saved A URL before measured playback; no extra decode here.
        let fullSourceAReferenceURL = auditSavedAAfterCleanup ? fixture.savedURLs[fixture.aID] : nil
        #endif
        var mayRemoveFixture = true
        defer { if mayRemoveFixture { fixture.remove() } }
        var references: [(samples: [Float], frequency: Double)] = []
        for (id, frequency) in [(fixture.aID, 440.0), (fixture.bID, 880.0)] {
            references.append((try await fixture.decodedTone(id: id), frequency))
        }
        #if DEBUG
        let suppressionControl: PreparedRenderingSuppressionControl?
        if let nativeVideoGeometry {
            suppressionControl = PreparedRenderingSuppressionControl(enabled: false, fixture: fixture,
                nativeGeometry: nativeVideoGeometry)
        } else {
            suppressionControl = suppressNativePlayerRendering.map {
                PreparedRenderingSuppressionControl(enabled: $0, fixture: fixture)
            }
        }
        let previousBundleControl: SelectionPreviousBundleControl?
        if let enabled = queuedPreviousLead {
            guard !traceVideoSeeks, frameMonitorAlternative == nil, !traceNativeRefill,
                  renderAccounting == nil, traceDefaultFrameMonitor == nil, !auditSavedAAfterCleanup,
                  traceClockHandoff == nil, freshPreviousBundle == nil,
                  suppressNativePlayerRendering == nil, nativeVideoGeometry == nil,
                  traceFirstSourceFailure == nil, acceptedPCMOriginBenchmarkMode == nil else {
                XCTFail("Previous queue lead requires the otherwise unset default benchmark")
                throw SelectionVideoTestFailure.timeout
            }
            previousBundleControl = try await SelectionPreviousBundleControl(fresh: false, queuedLead: enabled,
                aID: fixture.aID, bID: fixture.bID,
                aURL: XCTUnwrap(fixture.savedURLs[fixture.aID]),
                bURL: XCTUnwrap(fixture.savedURLs[fixture.bID]))
        } else if let fresh = freshPreviousBundle {
            guard !traceVideoSeeks, frameMonitorAlternative == nil, !traceNativeRefill,
                  renderAccounting == nil, traceDefaultFrameMonitor == nil, !auditSavedAAfterCleanup,
                  traceClockHandoff == nil, acceptedPCMOriginBenchmarkMode == nil else {
                XCTFail("Previous-bundle control must use the unchanged getter-free default benchmark")
                throw SelectionVideoTestFailure.timeout
            }
            // Joined before the audio/service owners exist. Both arms do exactly
            // this metadata work and hold one item with no installed output.
            previousBundleControl = try await SelectionPreviousBundleControl(fresh: fresh,
                aID: fixture.aID, bID: fixture.bID,
                aURL: XCTUnwrap(fixture.savedURLs[fixture.aID]),
                bURL: XCTUnwrap(fixture.savedURLs[fixture.bID]))
        } else { previousBundleControl = nil }
        #else
        if freshPreviousBundle != nil || queuedPreviousLead != nil {
            XCTFail("Previous-bundle control is unavailable outside DEBUG")
            throw SelectionVideoTestFailure.timeout
        }
        #endif
        #if DEBUG
        let nativeActivity = traceNativeRefill ? ContinuousPCMDecoder.DebugNativeLaneActivityRecorder() : nil
        let firstFailure = traceFirstSourceFailure == true ? ContinuousPCMRenderer.DebugFirstFailureRecorder() : nil
        let acceptedPCMOrigin = acceptedPCMOriginBenchmarkMode
        let originRecorder = acceptedPCMOrigin == true ? DebugAcceptedPCMOriginRecorder() : nil
        let originReply = acceptedPCMOrigin == true ? ProductionPCMOriginReply() : nil
        let accounting = renderAccounting == true || acceptedPCMOrigin == true
            ? ContinuousPCMRenderer.DebugRenderAccountingRecorder(capturePCMOrigin: acceptedPCMOrigin == true) : nil
        let audio = ContinuousAudioPlayer(debugNativeLaneActivityRecorder: nativeActivity,
                                          debugRenderAccounting: accounting, debugAcceptedPCMOrigin: originRecorder,
                                          debugFirstFailure: firstFailure)
        if let enabled = acceptedPCMOrigin {
            print("AcceptedPCMOriginScope schema=1 enabled=\(enabled) prefixCapacity=3 ringEpochCapacity=12 minimumZeroRunFrames=480 normalizedRate=48000 channels=2 noRetainedPCM=true noWorkerClock=true receipt=existing-kernel-completion rendererSnapshotUnchanged=true nativeTrace=false defaultMonitor=true independentDomains=true originalGuards=unchanged")
            XCTAssertFalse(traceVideoSeeks); XCTAssertFalse(traceNativeRefill)
            XCTAssertNil(frameMonitorAlternative); XCTAssertNil(renderAccounting)
            XCTAssertNil(traceDefaultFrameMonitor); XCTAssertFalse(auditSavedAAfterCleanup)
        }
        if let enabled = renderAccounting {
            print("ProductionRenderAccountingScope schema=1 enabled=\(enabled) immutableAtConstruction=true nativeRefillTrace=\(traceNativeRefill) videoSeekTrace=\(traceVideoSeeks) defaultVideoMonitor=\(frameMonitorAlternative == nil) samplesPerWindow=128 windows=3 intervalMs=100 snapshotAttempts=3 clocksOnRender=false pcmScan=false jointCoherence=false playbackAcceptance=unchanged")
            XCTAssertFalse(traceNativeRefill); XCTAssertFalse(traceVideoSeeks)
            XCTAssertNil(frameMonitorAlternative)
        }
        let nativeTrace = nativeActivity.map { ProductionNativeRefillTrace(recorder: $0, audio: audio) }
        #else
        let audio = ContinuousAudioPlayer()
        #endif
        let tap = ProductionSelectionOutputTap()
        let seeks = ProductionSelectionSeekRecorder()
        let startup = ProductionVideoStartupTrace(serviceTracing: traceVideoSeeks)
        #if DEBUG
        if acceptedPCMOrigin != nil {
            startup.pollSummary = ProductionSelectionPollSummary()
            print("ProductionSelectionPollScope schema=1 enabled=true originMode=\(acceptedPCMOrigin == true) phases=3 stages=3 firstWorstSpanCapacity=18 largestGapCapacity=3 clock=DispatchTime measurementBudget=unchanged sdkQueries=existing-only capture=unchanged publication=after-cleanup")
        }
        #endif
        #if DEBUG
        // Read-timing ON/OFF remains an explicit comparison of the legacy native
        // monitor. Installing an observer must never choose a rendering path.
        let observedFrameMode = frameMonitorAlternative ?? traceDefaultFrameMonitor.map { _ in false }
        let monitorBuffer = suppressionControl?.buffer ?? previousBundleControl?.buffer
            ?? observedFrameMode.map { _ in PlaybackBuffer() }
        #else
        let monitorBuffer = frameMonitorAlternative.map { _ in PlaybackBuffer() }
        #endif
        let service: PlaybackService
        if traceVideoSeeks {
            service = fixture.service(buffer: monitorBuffer, continuousAudio: audio, seekVideo: seeks.seek)
        } else {
            service = fixture.service(buffer: monitorBuffer, continuousAudio: audio)
        }
        #if DEBUG
        if suppressionControl != nil || traceFirstSourceFailure != nil || queuedPreviousLead != nil {
            XCTAssertTrue(service.debugUsesCurrentCustomFrameForReadiness)
        }
        let remainingWitness = traceClockHandoff == true
            ? RemainingLatencyWitness(baseRequest: service.debugInitialVideoReadyState.generation) : nil
        startup.remainingLatencyWitness = remainingWitness
        let handoffTrace = traceClockHandoff.map {
            NativeClockHandoffTrace(enabled: $0, baseRequest: service.debugInitialVideoReadyState.generation)
        }
        if let enabled = traceClockHandoff {
            print("NativeClockHandoffInstrumentationBundle schema=3 enabled=\(enabled) actualRateAndOrdinaryRead=true snapshotReadReceipt=\(enabled) firstAlignedEnqueue=\(enabled) compoundPollPair=\(enabled) firstPositiveExistingRead=\(enabled) addedReadValueCapacity=6 noNewReadCalls=true noNewClockSites=true observersBundled=true individualObserverAttribution=false acceptance=unchanged")
            XCTAssertEqual(traceVideoSeeks, enabled); XCTAssertFalse(traceNativeRefill)
            XCTAssertNil(acceptedPCMOriginBenchmarkMode); XCTAssertNil(traceDefaultFrameMonitor)
            XCTAssertNil(frameMonitorAlternative); XCTAssertNil(renderAccounting)
            if enabled {
                XCTAssertNil(startup.pollSummary)
                startup.pollSummary = ProductionSelectionPollSummary()
                print("ProductionSelectionPollScope schema=1 enabled=true clockHandoff=true phases=3 stages=3 firstWorstSpanCapacity=18 largestGapCapacity=3 clock=DispatchTime measurementBudget=unchanged sdkQueries=existing-only existingTimingSitesEnabled=true capture=unchanged publication=after-cleanup")
                startup.availabilityClockTrace = handoffTrace
                startup.enableEarlyNativePulls(baseRequest: service.debugInitialVideoReadyState.generation)
                service.onDebugCPPNativePullStamp = { [weak startup] value in startup?.recordEarlyNativePull(value) }
                service.onDebugAlignedVideoEnqueue = { [weak remainingWitness] value in remainingWitness?.record(value) }
                service.onDebugVideoRateHandoff = { [weak handoffTrace] value in handoffTrace?.record(value) }
                service.onDebugVideoPositionRead = { [weak handoffTrace] value in handoffTrace?.record(value) }
            }
        }
        let nativePositionReadTrace = acceptedPCMOriginBenchmarkMode.map {
            NativePositionReadDurationTrace(originEnabled: $0, baseRequest: service.debugInitialVideoReadyState.generation)
        }
        if let nativePositionReadTrace {
            XCTAssertFalse(traceVideoSeeks); XCTAssertFalse(traceNativeRefill)
            XCTAssertNil(traceDefaultFrameMonitor); XCTAssertNil(frameMonitorAlternative); XCTAssertNil(renderAccounting)
            print("NativePositionReadScope schema=1 originEnabled=\(acceptedPCMOriginBenchmarkMode == true) readTimingEnabled=true phases=3 capacityRecords=6 kind0=currentTime kind1=freshItemTimebaseAndGetTime legacySeekTracing=false playbackAcceptance=unchanged")
            service.onDebugVideoPositionRead = { [weak nativePositionReadTrace] value in nativePositionReadTrace?.record(value) }
        }
        let monitorReadTrace = traceDefaultFrameMonitor.map { DefaultFrameMonitorReadTrace(enabled: $0) }
        let cppNativePullTrace = traceDefaultFrameMonitor.map { CPPNativePullDurationTrace(enabled: $0) }
        if let enabled = traceDefaultFrameMonitor {
            XCTAssertFalse(traceVideoSeeks); XCTAssertFalse(traceNativeRefill)
            XCTAssertNil(frameMonitorAlternative); XCTAssertNil(renderAccounting)
            service.debugUsesCurrentCustomFrameForReadiness = false
            XCTAssertFalse(service.debugUsesCurrentCustomFrameForReadiness)
            print("DefaultFrameMonitorReadScope schema=2 enabled=\(enabled) defaultMonitor=false legacyMonitorExplicit=true videoSeekTrace=false nativeRefillTrace=false renderAccounting=false maximumRequests=3 stages=4 maximumRetainedRecords=24 wholeTickCoverage=false releaseBehaviorChange=false playbackAcceptance=unchanged")
            print("CPPNativePullScope schema=2 enabled=\(enabled) stages=3 maximumRequests=3 maximumRetainedRecords=18 legacySeekTrace=false defaultMonitor=false legacyMonitorExplicit=true phaseBinding=monitor-start-request-item nilObserverClocks=false releaseBehaviorChange=false playbackAcceptance=unchanged")
            if enabled {
                service.onDebugFrameMonitorReadBatch = { [weak monitorReadTrace, weak cppNativePullTrace] value in
                    monitorReadTrace?.record(value); cppNativePullTrace?.recordMonitor(value)
                }
                service.onDebugCPPNativePullStamp = { [weak cppNativePullTrace] value in cppNativePullTrace?.record(value) }
            }
        }
        var monitorRows: [(phase: Int, selectedID: String?, expectedID: String?, outputs: Int, preparedIdentity: Bool)] = []
        var monitorOverflow = false
        var monitorPhase = -1
        var monitorExpectedID: String?
        if let alternative = observedFrameMode {
            service.debugUsesCurrentCustomFrameForReadiness = alternative
            service.debugAfterFirstFrameMonitorStart = { [weak service] item in
                guard monitorRows.count < 8 else { monitorOverflow = true; return }
                let outputs = item.outputs
                let matched = monitorBuffer?.resource(for: item)?.output.map { expected in
                    outputs.contains { $0 === expected }
                } ?? false
                monitorRows.append((monitorPhase, service?.queue.currentID, monitorExpectedID, outputs.count, matched))
            }
        }
        if traceVideoSeeks {
            service.onDebugVideoSeekStamp = { [weak seeks, weak startup] stamp in
                seeks?.record(stamp); startup?.recordSeek(stamp)
            }
            service.onDebugVideoStartupStamp = { [weak startup] stamp in startup?.record(stamp) }
            service.onDebugVideoRenderStamp = { [weak startup] stamp in startup?.recordRender(stamp) }
        }
        defer {
            if handoffTrace != nil {
                service.onDebugVideoRateHandoff = nil; service.onDebugVideoPositionRead = nil
                service.onDebugAlignedVideoEnqueue = nil
                service.onDebugCPPNativePullStamp = nil
            }
            if nativePositionReadTrace != nil { service.onDebugVideoPositionRead = nil }
            if traceDefaultFrameMonitor != nil {
                service.onDebugFrameMonitorReadBatch = nil; service.onDebugCPPNativePullStamp = nil
            }
            if observedFrameMode != nil { service.debugAfterFirstFrameMonitorStart = nil }
            if traceVideoSeeks {
                service.onDebugVideoSeekStamp = nil; service.onDebugVideoStartupStamp = nil
                service.onDebugVideoRenderStamp = nil
            }
        }
        #endif
        let screen = try SelectionVideoScreen(service: service)
        // From here, deletion requires the decoder's queued cleanup acknowledgement.
        mayRemoveFixture = false
        let originalSources = (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }
        let originalBytes = audio.renderer.retainedPCMMemoryBytes
        audio.graph.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil) { buffer, time in
            tap.append(buffer, time: time)
        }
        var measurements: [ProductionSelectionMeasurement] = []
        var streams: [ProductionSelectionStream] = []
        measurements.reserveCapacity(3); streams.reserveCapacity(3)
        var returnedStart: Int?
        var returnedEnd: Int?
        var returnedOrigin: Double?
        var previousBundleBodyError: Error?
        do {
        for phase in 0..<3 {
            let id = phase == 1 ? fixture.bID : fixture.aID
            let frequency = phase == 1 ? 880.0 : 440.0
            let prepared = phase != 0
            let preparedBefore: Bool
            if prepared {
                preparedBefore = await waitUntil(timeout: 5) {
                    service.preparedAudioCount == 2 && audio.entry(for: id) != nil
                }
            } else { preparedBefore = true }
            let qualification: (() throws -> Void)?
            #if DEBUG
            if let control = suppressionControl {
                qualification = {
                    try control.qualify(phase: phase, stage: 0, service: service, audio: audio)
                }
            } else if let control = previousBundleControl {
                if phase == 2 {
                    // Same real B/old-A eligibility and fixed settling interval in
                    // both arms. No preparation task or second player is started.
                    guard await waitUntil(timeout: 3, {
                        control.canReplacePrevious(service: service, audio: audio, screen: screen)
                    }) else { throw SelectionPreviousBundleControl.Failure.qualification(20) }
                    control.beginQueuedLead(audio: audio, tap: tap, quantum: service.audioRenderQuantumFrames)
                    try control.choosePrevious(service: service, audio: audio, screen: screen)
                    if queuedPreviousLead != nil { try await control.waitQueuedLead() }
                    else { try await Task.sleep(for: .milliseconds(250)) }
                }
                qualification = {
                    try control.qualifyBeforeCommand(phase: phase, service: service, audio: audio, screen: screen)
                }
            } else { qualification = nil }
            #else
            qualification = nil
            #endif
            let measurement = try await measureProductionSelection(service, screen: screen, fixture: fixture,
                audio: audio, tap: tap, seeks: seeks, startup: startup, phase: phase, id: id,
                frequency: frequency, prepared: prepared, preparedBefore: preparedBefore,
                preCommandQualification: qualification) {
                #if DEBUG
                if let monitorReadTrace {
                    let commandNs = monitorReadTrace.beginPhase(phase)
                    cppNativePullTrace?.beginPhase(phase, commandNs: commandNs)
                }
                if observedFrameMode != nil {
                    monitorPhase = phase
                    monitorExpectedID = id
                }
                #endif
                switch phase {
                case 0: service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
                case 1: service.next()
                default:
                    #if DEBUG
                    try previousBundleControl?.stageAtPreviousCommand(service: service, audio: audio, screen: screen)
                    #endif
                    service.previous()
                    #if DEBUG
                    try previousBundleControl?.qualifyQueuedCommandReturn(service: service, audio: audio)
                    #endif
                }
            }
            measurements.append(measurement)
            #if DEBUG
            if phase == 2 { previousBundleControl?.completeQueuedLeadReadback(last: measurement.last) }
            try suppressionControl?.qualify(phase: phase, stage: 1, service: service, audio: audio)
            #endif
            if phase == 2 {
                returnedOrigin = ProductionSelectionOutputTap.hostSeconds()
                returnedStart = tap.begin(auditChannels: true)
            }
            let baseline = audio.renderer.snapshot
            let before = productionSelectionState(service, fixture: fixture, audio: audio, id: id)
            #if DEBUG
            let probe = ProductionRendererProbe(renderer: audio.renderer, nativeTrace: nativeTrace,
                nativePhase: phase, nativeExpectedToken: measurement.state.expectedToken,
                nativeCommandUnderruns: measurement.before.underrunFrames, renderAccounting: accounting,
                captureSnapshotReadReceipt: traceClockHandoff == true)
            #else
            let probe = ProductionRendererProbe(renderer: audio.renderer)
            #endif
            try? await Task.sleep(for: .seconds(8))
            let result = probe.stop()
            let final = audio.renderer.snapshot
            let after = productionSelectionState(service, fixture: fixture, audio: audio, id: id)
            streams.append(ProductionSelectionStream(phase: phase, baseline: baseline, final: final,
                before: before, after: after, quantum: service.audioRenderQuantumFrames, result: result,
                memoryBytes: audio.renderer.retainedPCMMemoryBytes,
                sameStorage: originalSources == (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }))
            if phase == 2 { returnedEnd = tap.stop() }
            #if DEBUG
            if let control = suppressionControl {
                // The original measurement and eight-second sampler/tap endpoint
                // have stopped. These matched captures change later framework
                // history; they never stand in for the original timed evidence.
                try control.qualify(phase: phase, stage: 2, service: service, audio: audio)
                await assertMovingVisibleVideo(service, screen: screen, identity: phase == 1 ? .b : .a,
                    label: control.captureLabel(phase: phase))
                try control.qualify(phase: phase, stage: 3, service: service, audio: audio)
            }
            try previousBundleControl?.completedPhase(phase, service: service, audio: audio)
            #endif
        }
        } catch { previousBundleBodyError = error }
        #if DEBUG
        // A failed choose/stage/sleep must also stop its optional short probe.
        previousBundleControl?.finishQueuedLead(audio: audio)
        if let control = previousBundleControl, previousBundleBodyError == nil {
            do {
                // The original returned eight-second tap and sampler have stopped.
                // Actual pixels are additional post-window evidence, never a proxy
                // for the original timed first-frame or PCM acceptance checks.
                try control.qualifyReturnedA(service: service, audio: audio, stage: 8)
                await assertMovingVisibleVideo(service, screen: screen, identity: .a,
                    label: control.returnedCaptureLabel)
                try control.qualifyReturnedA(service: service, audio: audio, stage: 9)
            } catch { previousBundleBodyError = error }
        }
        #endif

        // No dumps, spectral analysis or assertions interrupt any streaming window.
        tap.stop(); service.pause()
        audio.graph.engine.mainMixerNode.removeTap(onBus: 0)
        audio.graph.engine.stop(); screen.close()
        let shutdown = ProductionSelectionShutdown()
        let preparation = ProductionSelectionShutdown()
        #if DEBUG
        service.debugStopPreparation { preparation.complete(true) }
        audio.debugShutdown { shutdown.complete($0) }
        if let originReply {
            audio.debugAcceptedPCMOriginSnapshot { snapshot in originReply.complete(snapshot) }
        }
        #endif
        let cleanupReturned = await waitUntil(timeout: 3) {
            let acknowledged = shutdown.result != nil && preparation.result != nil
            #if DEBUG
            // Same off-window deadline; only origin-ON also waits for its one
            // already-queued numerical reply. Nil/OFF retains the original test.
            if let originReply { return acknowledged && originReply.read().received }
            #endif
            return acknowledged
        }
        let preparationAck = preparation.result, decoderAck = shutdown.result
        mayRemoveFixture = cleanupReturned && decoderAck == true && preparationAck == true
        print("ProductionSelectionCleanupAcknowledgements schema=1 cleanupReturned=\(cleanupReturned) preparationAckPresent=\(preparationAck != nil) preparationAckValue=\(preparationAck.map { $0 ? "true" : "false" } ?? "unknown") decoderAckPresent=\(decoderAck != nil) decoderAckValue=\(decoderAck.map { $0 ? "true" : "false" } ?? "unknown") nativeRefillTrace=\(traceNativeRefill) fixtureRemoveAllowed=\(mayRemoveFixture) availabilityScope=after-cleanup-wait")
        #if DEBUG
        if handoffTrace != nil {
            service.onDebugVideoRateHandoff = nil; service.onDebugVideoPositionRead = nil
            service.onDebugAlignedVideoEnqueue = nil
            service.onDebugCPPNativePullStamp = nil
        }
        handoffTrace?.dumpAndAssert()
        remainingWitness?.dumpAndAssert()
        if traceDefaultFrameMonitor != nil {
            service.onDebugFrameMonitorReadBatch = nil; service.onDebugCPPNativePullStamp = nil
        }
        if nativePositionReadTrace != nil { service.onDebugVideoPositionRead = nil }
        nativePositionReadTrace?.dumpAndAssert()
        monitorReadTrace?.dumpAndAssert()
        cppNativePullTrace?.dumpAndAssert()
        nativeTrace?.dumpAfterCleanup()
        dumpFirstSourceCopyFailure(firstFailure, enabled: traceFirstSourceFailure, cleanupAcknowledged: mayRemoveFixture)
        #endif
        print("ProductionSelectionCleanup completed=\(mayRemoveFixture) ownedTasksJoined=\(preparation.result == true) producerTracing=absent sdkInternalQuiescence=unverified syntheticFixtureRetained=\(!mayRemoveFixture)")
        XCTAssertTrue(mayRemoveFixture, "Queued decoder cleanup must return before removing only this synthetic fixture")
        if !mayRemoveFixture { Self.targetedFixtureOwnershipLost = true; fixture.restorePreferences() }
        #if DEBUG
        previousBundleControl?.dump(setupCompleted: previousBundleBodyError == nil)
        suppressionControl?.dumpAndAssert(setupCompleted: previousBundleBodyError == nil)
        #endif
        if let previousBundleBodyError {
            // Rejected setup is still a failure. After acknowledged cleanup, the
            // original nonthrowing validators below must also report whatever
            // bounded evidence was collected before that failure. Missing phases
            // retain their original failing count/window assertions.
            #if DEBUG
            if suppressionControl != nil {
                XCTFail("Prepared rendering setup/owner qualification failed: \(previousBundleBodyError)")
            } else {
                XCTFail("Previous-bundle setup/owner qualification failed: \(previousBundleBodyError)")
            }
            #else
            XCTFail("Previous-bundle setup/owner qualification failed: \(previousBundleBodyError)")
            #endif
            print("ProductionSelectionCachedFailureEvidence schema=1 cleanupAcknowledged=\(mayRemoveFixture) measurementsCollected=\(measurements.count) streamsCollected=\(streams.count) measurementCapacity=3 streamCapacity=3 returnedStartPresent=\(returnedStart != nil) returnedEndPresent=\(returnedEnd != nil) partialCollectedData=true fullApplicationAcceptance=false originalBodyErrorRetained=true publication=\(mayRemoveFixture ? "existing-cached-validators" : "blocked-uncertain-cleanup")")
            if !mayRemoveFixture { throw previousBundleBodyError }
        }
        #if DEBUG
        if let alternative = observedFrameMode {
            print("FrameMonitorBenchmarkOutputs schema=1 alternative=\(alternative) rows=\(monitorRows.count) capacity=8 overflow=\(monitorOverflow) originalGuardsRetained=true physicalPixels=unmeasured")
            XCTAssertGreaterThanOrEqual(monitorRows.count, 3)
            XCTAssertLessThanOrEqual(monitorRows.count, 8)
            XCTAssertFalse(monitorOverflow)
            XCTAssertEqual(Set(monitorRows.map { $0.phase }), Set(0..<3))
            for (ordinal, row) in monitorRows.enumerated() {
                let expected = row.phase == 1 ? fixture.bID : fixture.aID
                let selectedMatches = row.selectedID == expected && row.expectedID == expected
                print("FrameMonitorBenchmarkOutput schema=1 alternative=\(alternative) ordinal=\(ordinal) phase=\(row.phase) outputs=\(row.outputs) expectedOutputs=\(alternative ? 1 : 2) preparedIdentity=\(row.preparedIdentity) selectedIDMatchesPhase=\(selectedMatches)")
                XCTAssertEqual(row.outputs, alternative ? 1 : 2)
                XCTAssertTrue(row.preparedIdentity)
                XCTAssertTrue((0..<3).contains(row.phase))
                XCTAssertTrue(selectedMatches)
            }
        }
        #endif
        for reference in references {
            XCTAssertGreaterThanOrEqual(reference.samples.count, 10_000)
            XCTAssertTrue(ProductionSelectionOutputTap.isTone(reference.samples, rate: 48_000, frequency: reference.frequency))
            XCTAssertEqual(ProductionSelectionOutputTap.quietRun(reference.samples, rate: 48_000), 0,
                           "Independently decoded encoded fixtures must contain no 10 ms RMS-silence windows")
        }
        XCTAssertEqual(originalBytes, 6_912_000)
        XCTAssertEqual(Set(originalSources).count, 3)
        XCTAssertEqual(audio.renderer.sampleRate, 48_000); XCTAssertEqual(audio.renderer.channels, 2)
        for slot in 0..<3 {
            XCTAssertEqual(audio.renderer.source(at: slot).prefixCapacityFrames, 96_000)
            XCTAssertEqual(audio.renderer.source(at: slot).ringCapacityFrames, 192_000)
        }
        XCTAssertEqual(measurements.count, 3); XCTAssertEqual(streams.count, 3)
        XCTAssertLessThanOrEqual(streams.reduce(0) { $0 + $1.result.samples.count }, 384)
        for measurement in measurements { assertProductionSelection(measurement, tap: tap) }
        for stream in streams { assertProductionStream(stream) }
        #if DEBUG
        if let enabled = renderAccounting {
            for stream in streams { assertProductionRenderAccounting(stream, enabled: enabled) }
        }
        if let enabled = acceptedPCMOrigin {
            for stream in streams { assertProductionRenderAccounting(stream, enabled: enabled) }
            assertAcceptedPCMOrigin(enabled: enabled, reply: originReply, streams: streams,
                                    cleanupAcknowledged: mayRemoveFixture)
        }
        #endif
        if measurements.count == 3 {
            XCTAssertGreaterThan(measurements[0].state.expectedToken, 0)
            XCTAssertNotEqual(measurements[0].state.expectedToken, measurements[1].state.expectedToken)
            XCTAssertEqual(measurements[0].state.expectedToken, measurements[2].state.expectedToken,
                           "Previous must reuse the retained A preparation")
            XCTAssertGreaterThan(measurements[1].state.audio.visit, measurements[0].state.audio.visit)
            XCTAssertGreaterThan(measurements[2].state.audio.visit, measurements[1].state.audio.visit)
        }
        let returned = tap.samples(from: returnedStart ?? tap.count, to: returnedEnd ?? tap.count)
        let returnedSeconds = returned.rate > 0 ? Double(returned.values.count) / returned.rate : 0
        let returnedWall = returned.hosts.first.flatMap { first in returned.hosts.last.map { $0 - first + 1 / max(1, returned.rate) } } ?? 0
        let returnedQuiet = ProductionSelectionOutputTap.quietRun(returned.values, rate: returned.rate)
        let returnedHole = ProductionSelectionOutputTap.maximumTimelineHole(returned.hosts, rate: returned.rate)
        let toneBlocks = ProductionSelectionOutputTap.toneBlocks(returned.values, rate: returned.rate, frequency: 440)
        let validity = tap.validity()
        print("ProductionSelectionReturnedOutput seconds=\(returnedSeconds) wallSeconds=\(returnedWall) firstHostOffsetMs=\(((returned.hosts.first ?? .infinity) - (returnedOrigin ?? 0)) * 1_000) lastHostOffsetMs=\(((returned.hosts.last ?? -.infinity) - (returnedOrigin ?? .infinity)) * 1_000) frames=\(returned.values.count) rate=\(returned.rate) toneBlocks=\(toneBlocks.total) correctToneBlocks=\(toneBlocks.correct) quietMs=\(returnedQuiet * 1_000) maximumHoleMs=\(returnedHole * 1_000) invalidTimestamps=\(validity.invalidTimestamps) droppedFrames=\(validity.droppedFrames) retainedFrames=\(tap.count) capacityFrames=576000")
        let channelAudit = tap.channelAudit()
        print("ProductionSelectionReturnedChannelAudit schema=1 minimumRunFrames=\(channelAudit.minimumRunFrames) observedFrames=\(channelAudit.observedFrames) monoZeroFrames=\(channelAudit.monoZeroFrames) stereoZeroFrames=\(channelAudit.stereoZeroFrames) leftSquareSum=\(channelAudit.leftSquareSum) rightSquareSum=\(channelAudit.rightSquareSum) nonfiniteFrames=\(channelAudit.nonfiniteFrames) qualifiedRuns=\(channelAudit.qualifiedRuns) retainedRuns=\(channelAudit.retainedRuns) capacity=4 droppedRuns=\(channelAudit.droppedRuns) overflow=\(channelAudit.overflow) layoutObserved=\(channelAudit.layout.buffers > 0) layoutBuffers=\(channelAudit.layout.buffers) layoutFrames=\(channelAudit.layout.frames) firstChannelCount=\(channelAudit.layout.firstChannelCount) lastChannelCount=\(channelAudit.layout.lastChannelCount) firstInterleaved=\(channelAudit.layout.firstInterleaved) lastInterleaved=\(channelAudit.layout.lastInterleaved) firstSampleRate=\(channelAudit.layout.firstRate) lastSampleRate=\(channelAudit.layout.lastRate) layoutChanged=\(channelAudit.layout.changed) monoDuplicatedFrames=\(channelAudit.layout.monoDuplicatedFrames) stereoInputFrames=\(channelAudit.layout.stereoInputFrames) otherInputFrames=\(channelAudit.layout.otherInputFrames) stereoZeroEvidenceQualified=\(channelAudit.stereoZeroEvidenceQualified) layoutScope=retained-audited-buffers interleavedScope=first-existing-left-index-read exactMonoZero=true playbackAcceptance=unchanged")
        XCTAssertEqual(channelAudit.observedFrames, returned.values.count)
        XCTAssertEqual(channelAudit.nonfiniteFrames, 0)
        XCTAssertLessThanOrEqual(channelAudit.retainedRuns, 4)
        XCTAssertEqual(channelAudit.droppedRuns, 0)
        XCTAssertFalse(channelAudit.overflow)
        for ordinal in 0..<4 {
            guard let run = channelAudit.run(at: ordinal) else { continue }
            let firstOffset = returnedOrigin.map { (run.firstHost - $0) * 1_000 }
            let endOffset = returnedOrigin.map { (run.endHost - $0) * 1_000 }
            print("ProductionSelectionReturnedChannelRun schema=1 ordinal=\(ordinal) firstFrame=\(run.firstFrame - channelAudit.firstFrame) endFrame=\(run.endFrame - channelAudit.firstFrame) frames=\(run.frames) startOffsetMs=\(firstOffset.map { String($0) } ?? "unknown") endOffsetMs=\(endOffset.map { String($0) } ?? "unknown") leftSquareSum=\(run.leftSquareSum) rightSquareSum=\(run.rightSquareSum) stereoZeroFrames=\(run.stereoZeroFrames)")
        }
        #if DEBUG
        let cachedJournal = service.debugCachedPlaybackDiagnostics
        print("ProductionSelectionCachedJournal schema=1 capacity=\(cachedJournal.capacity) retained=\(cachedJournal.entries.count) dropped=\(cachedJournal.droppedEvents) originPresent=\(cachedJournal.originUptime == nil ? 0 : 1) originUptime=\(cachedJournal.originUptime ?? 0) traceVideoSeeks=\(traceVideoSeeks ? 1 : 0) cachedOnly=1 newRecordCalls=0")
        XCTAssertEqual(cachedJournal.capacity, 128)
        XCTAssertLessThanOrEqual(cachedJournal.entries.count, 128)
        for (ordinal, entry) in cachedJournal.entries.prefix(128).enumerated() {
            let s = entry.snapshot
            print("ProductionSelectionCachedJournalEntry schema=1 ordinal=\(ordinal) sequence=\(entry.sequence) elapsedSeconds=\(entry.elapsedSeconds) phase=\(entry.phase.rawValue) generation=\(s.generation) audioRequested=\(s.audioRequested ? 1 : 0) audioPermitted=\(s.audioPermitted ? 1 : 0) audioInterrupted=\(s.audioInterrupted ? 1 : 0) interruptionReasonPresent=\(s.interruptionReason == nil ? 0 : 1) interruptionReason=\(s.interruptionReason ?? 0) interruptionOptionsPresent=\(s.interruptionOptions == nil ? 0 : 1) interruptionOptions=\(s.interruptionOptions ?? 0) wasSuspendedPresent=\(s.wasSuspended == nil ? 0 : 1) wasSuspended=\(s.wasSuspended == true ? 1 : 0) routeReasonPresent=\(s.routeChangeReason == nil ? 0 : 1) routeReason=\(s.routeChangeReason ?? 0) engineRunning=\(s.engineRunning ? 1 : 0) audioOnly=\(s.audioOnlySelected ? 1 : 0) presentation=\(s.presentation.rawValue) pipeline=\(s.pipeline.rawValue) positionPresent=\(s.positionSeconds == nil ? 0 : 1) positionSeconds=\(s.positionSeconds ?? 0) durationPresent=\(s.durationSeconds == nil ? 0 : 1) durationSeconds=\(s.durationSeconds ?? 0) ratePresent=\(s.playbackRate == nil ? 0 : 1) playbackRate=\(s.playbackRate ?? 0) retainedItems=\(s.retainedItems) preparedPCMBytes=\(s.preparedPCMBytes) underrunFrames=\(s.underrunFrames) outputRoute=\(s.outputRoute.rawValue) sampleRatePresent=\(s.sampleRate == nil ? 0 : 1) sampleRate=\(s.sampleRate ?? 0) ioBufferPresent=\(s.ioBufferSeconds == nil ? 0 : 1) ioBufferSeconds=\(s.ioBufferSeconds ?? 0) outputLatencyPresent=\(s.outputLatencySeconds == nil ? 0 : 1) outputLatencySeconds=\(s.outputLatencySeconds ?? 0) pipActive=\(s.pipActive ? 1 : 0) pipPossible=\(s.pipPossible ? 1 : 0) pipSuspended=\(s.pipSuspended ? 1 : 0) sourceFramesPresent=\(s.sourceFrames == nil ? 0 : 1) sourceFrames=\(s.sourceFrames ?? 0) leadingFramesPresent=\(s.sourceLeadingBelowMinus60DBFrames == nil ? 0 : 1) leadingFrames=\(s.sourceLeadingBelowMinus60DBFrames ?? 0) trailingFramesPresent=\(s.sourceTrailingBelowMinus60DBFrames == nil ? 0 : 1) trailingFrames=\(s.sourceTrailingBelowMinus60DBFrames ?? 0) errorPresent=\(entry.error == nil ? 0 : 1) errorFamily=\(entry.error?.family.rawValue ?? 0) errorCode=\(entry.error?.code ?? 0)")
        }
        #endif
        let anomalies = ProductionSelectionOutputTap.anomalyLocations(returned, origin: returnedOrigin, frequency: 440)
        print("ProductionSelectionReturnedAnomalySummary schema=1 available=\(anomalies.available) originHostSeconds=\(returnedOrigin.map { String($0) } ?? "unknown") monitorStopHostSeconds=unknown quietCount=\(anomalies.quietCount) badToneCount=\(anomalies.badToneCount) retainedRecords=\(anomalies.records.count) perKindCapacity=4 droppedAnomalyCount=\(anomalies.droppedAnomalyCount) indices=recording-relative endFrame=exclusive")
        for record in anomalies.records {
            print("ProductionSelectionReturnedAnomaly schema=1 kind=\(record.kind) windowOrdinal=\(record.windowOrdinal) firstFrame=\(record.firstFrame) endFrame=\(record.endFrame) startOffsetMs=\(record.startOffsetMs.map { String($0) } ?? "unknown") endOffsetMs=\(record.endOffsetMs.map { String($0) } ?? "unknown") rms=\(record.rms)")
        }
        XCTAssertGreaterThanOrEqual(returnedSeconds, 7.5); XCTAssertGreaterThanOrEqual(returnedWall, 7.5)
        XCTAssertTrue(returned.values.allSatisfy { $0.isFinite })
        XCTAssertGreaterThanOrEqual(toneBlocks.total, 375); XCTAssertEqual(toneBlocks.correct, toneBlocks.total)
        XCTAssertEqual(returnedQuiet, 0)
        XCTAssertLessThanOrEqual(returnedHole, 0.5 / max(1, returned.rate))
        XCTAssertEqual(validity.invalidTimestamps, 0); XCTAssertEqual(validity.droppedFrames, 0)
        XCTAssertLessThanOrEqual(tap.count, 12 * 48_000)
        XCTAssertLessThanOrEqual((returned.hosts.first ?? .infinity) - (returnedOrigin ?? 0), 0.25)
        XCTAssertGreaterThanOrEqual((returned.hosts.last ?? -.infinity) - (returnedOrigin ?? .infinity), 7.5)
        XCTAssertEqual(audio.renderer.snapshot.underrunFrames, 0,
                       "Startup starvation cannot disappear behind a clean streaming baseline")
        if traceVideoSeeks {
            seeks.dumpAndAssert()
        } else {
            #if DEBUG
            XCTAssertNil(service.onDebugVideoSeekStamp, "The default production benchmark must leave the seek observer unset")
            XCTAssertNil(service.onDebugVideoStartupStamp)
            XCTAssertNil(service.onDebugVideoRenderStamp)
            #endif
            seeks.assertUnused()
        }
        startup.dumpAndAssert()
        #if DEBUG
        startup.pollSummary?.dumpAndAssert()
        #endif
        if let previousBundleBodyError {
            // Everything since the retained error report is an existing cached
            // assertion/dump or original post-cleanup resource/counter check and
            // cannot throw another error. Preserve the exact original Error, and
            // never start the optional reference decoder on this failure path.
            print("ProductionSelectionCachedFailureEvidenceEnd schema=1 validatorsReturned=true originalBodyErrorRetained=true rethrow=original fullApplicationAcceptance=false")
            throw previousBundleBodyError
        }
        #if DEBUG
        if auditSavedAAfterCleanup {
            // All original acceptance checks above execute before this optional audit.
            guard renderAccounting == true, !traceVideoSeeks, !traceNativeRefill,
                  frameMonitorAlternative == nil, traceDefaultFrameMonitor == nil else {
                XCTFail("The post-cleanup reference belongs only to its isolated accounting diagnostic")
                return
            }
            let originalCleanupAcknowledged = mayRemoveFixture
            guard originalCleanupAcknowledged, !audio.graph.engine.isRunning else {
                mayRemoveFixture = false
                Self.targetedFixtureOwnershipLost = true
                fixture.restorePreferences()
                print("FullSourceAReference schema=2 status=skipped cleanupAcknowledged=\(originalCleanupAcknowledged) interpretation=unavailable fixtureRetained=true")
                XCTFail("Original cleanup and engine stop must be established before the reference reader")
                return // Never create another reader after an uncertain original close.
            }
            // A cancellation, metadata/layout/coverage failure or incomplete reader keeps
            // this exact fixture. The existing defer may delete it only after success.
            mayRemoveFixture = false
            do {
                let saved = try XCTUnwrap(fullSourceAReferenceURL)
                guard fixture.savedURLs[fixture.aID] == saved else {
                    throw FullSourceReferenceFailure.quality("Saved A URL changed")
                }
                let audit = try await auditFullSavedAReference(saved)
                audit.dump()
                mayRemoveFixture = true
            } catch {
                Self.targetedFixtureOwnershipLost = true
                fixture.restorePreferences()
                print("FullSourceAReference schema=2 status=failed interpretation=unavailable fixtureRetained=true reason=\(String(describing: error))")
                XCTFail("Full Saved A reference quality failed; retain this fixture: \(error)")
            }
        }
        #endif
    }

    #if DEBUG
    private func dumpFirstSourceCopyFailure(_ recorder: ContinuousPCMRenderer.DebugFirstFailureRecorder?,
                                           enabled: Bool?, cleanupAcknowledged: Bool) {
        guard let recorder else {
            print("PCMSourceCopyFailureSnapshot schema=1 mode=\(enabled.map { $0 ? "on" : "off" } ?? "nil") recorderPresent=false publication=unavailable capture=notCaptured configuredTargetVisit=3 actualTargetVisit=unavailable earlier=unavailable later=unavailable eventPresent=false cleanupAcknowledged=\(cleanupAcknowledged) independentDomains=true noCrossClock=true physicalProof=false causalProof=false")
            return
        }
        let snapshot = recorder.snapshot() // One value read; never query the live sources for omitted operands.
        print("PCMSourceCopyFailureSnapshot schema=1 mode=on recorderPresent=true publication=\(snapshot.publication.rawValue) configuredTargetVisit=3 actualTargetVisit=\(snapshot.targetVisit) earlier=\(snapshot.earlierVisitFailureObserved) later=\(snapshot.laterVisitFailureObserved) eventPresent=\(snapshot.event != nil) cleanupAcknowledged=\(cleanupAcknowledged) independentDomains=true noCrossClock=true physicalProof=false causalProof=false")
        XCTAssertEqual(snapshot.targetVisit, 3)
        XCTAssertEqual(snapshot.event != nil, snapshot.publication == .captured)
        guard let event = snapshot.event else {
            print("PCMSourceCopyFailureEvent schema=1 available=false capture=\(snapshot.publication == .publishing ? "publishing" : "notCaptured") operands=unavailable noFailure=inconclusive")
            return
        }
        XCTAssertEqual(event.visit, snapshot.targetVisit)
        print("PCMSourceCopyFailureEvent schema=1 available=true reason=\(event.reason.rawValue) token=\(event.token) visit=\(event.visit) cursor=\(event.cursor) observedFirstToken=\(event.observedFirstToken.map { String($0) } ?? "unread") observedSecondToken=\(event.observedSecondToken.map { String($0) } ?? "unread") observedThirdToken=\(event.observedThirdToken.map { String($0) } ?? "unread") observedAccess=\(event.observedAccess.map { String($0) } ?? "unread") observedReadyToken=\(event.observedReadyToken.map { String($0) } ?? "unread") prefixFrames=\(event.prefixFrames.map { String($0) } ?? "unread") expectedEpoch=\(event.expectedEpoch.map { String($0) } ?? "unread") observedEpoch=\(event.observedEpoch.map { String($0) } ?? "unread") observedReadPosition=\(event.observedReadPosition.map { String($0) } ?? "unread") observedWritePosition=\(event.observedWritePosition.map { String($0) } ?? "unread") operandScope=original-guard-actual-loads-only independentDomains=true noCrossClock=true physicalProof=false causalProof=false")
    }

    private enum FullSourceReferenceFailure: Error {
        case quality(String)
    }

    private struct FullSourceReferenceRun {
        let firstFrame: Int64, endFrame: Int64
        var frames: Int64 { endFrame - firstFrame }
    }

    /// Two retained ranges per kind, regardless of how many actual runs occur.
    private struct FullSourceReferenceRuns {
        var count: UInt64 = 0
        var first: FullSourceReferenceRun?, longest: FullSourceReferenceRun?
        var overflow = false
        mutating func append(_ run: FullSourceReferenceRun) {
            let next = count.addingReportingOverflow(1)
            count = next.overflow ? .max : next.partialValue
            overflow = overflow || next.overflow
            if first == nil { first = run }
            if longest == nil || run.frames > longest!.frames { longest = run }
        }
        func dump(_ kind: String) {
            for (role, range) in [("first", first), ("longest", longest)] {
                guard let range else { continue }
                print("FullSourceAReferenceRange schema=2 kind=\(kind) role=\(role) firstFrame=\(range.firstFrame) endFrame=\(range.endFrame) frames=\(range.frames) editedStartSeconds=\(Double(range.firstFrame) / 48_000) editedEndSeconds=\(Double(range.endFrame) / 48_000) endFrameExclusive=true")
            }
        }
    }

    private struct FullSourceReferenceTrim {
        let buffer: Int
        let rawStart: Int64, rawFrames: Int64
        let startTrim: Int64, endTrim: Int64
        let outputStart: Int64, outputFrames: Int64
        var trimmedFrames: Int64 { startTrim + endTrim }
    }

    private struct FullSourceReferenceAudit {
        var frames: Int64 = 0
        var rawFrames: Int64 = 0
        var buffers = 0, fullyTrimmedBuffers = 0
        var startTrimAttachments = 0, endTrimAttachments = 0, speedAttachments = 0
        var startTrimFrames: Int64 = 0, endTrimFrames: Int64 = 0
        var trimEvents = 0
        var firstTrim: FullSourceReferenceTrim?, maximumTrim: FullSourceReferenceTrim?
        var stereoZeroFrames: Int64 = 0
        var quietWindows: Int64 = 0
        var stereoRuns = FullSourceReferenceRuns()
        var quietRuns = FullSourceReferenceRuns()
        private var stereoStart: Int64?
        private var quietStart: Int64?, quietEnd: Int64?
        // A sliding 480-frame window on edited presentation PCM only.
        private var squares = [Double](repeating: 0, count: 480)
        private var squareIndex = 0, windowFrames = 0
        private var squareSum = 0.0

        mutating func recordBuffer(_ trim: FullSourceReferenceTrim,
            startPresent: Bool, endPresent: Bool, speedPresent: Bool) {
            // The reader loop bounds every scalar count and frame sum.
            buffers += 1; rawFrames += trim.rawFrames
            if startPresent { startTrimAttachments += 1 }
            if endPresent { endTrimAttachments += 1 }
            if speedPresent { speedAttachments += 1 }
            startTrimFrames += trim.startTrim; endTrimFrames += trim.endTrim
            if trim.outputFrames == 0 { fullyTrimmedBuffers += 1 }
            if trim.trimmedFrames > 0 {
                trimEvents += 1
                if firstTrim == nil { firstTrim = trim }
                if maximumTrim == nil || trim.trimmedFrames > maximumTrim!.trimmedFrames {
                    maximumTrim = trim
                }
            }
        }

        mutating func consume(left: Float, right: Float) throws {
            let mono = (left + right) * 0.5
            guard left.isFinite, right.isFinite, mono.isFinite else {
                throw FullSourceReferenceFailure.quality("Nonfinite presented reference PCM")
            }
            let frame = frames
            if left == 0 && right == 0 {
                stereoZeroFrames += 1
                if stereoStart == nil { stereoStart = frame }
            } else if let start = stereoStart {
                stereoRuns.append(FullSourceReferenceRun(firstFrame: start, endFrame: frame))
                stereoStart = nil
            }
            let square = Double(mono) * Double(mono)
            squareSum += square - squares[squareIndex]
            squares[squareIndex] = square
            squareIndex = (squareIndex + 1) % 480
            windowFrames = min(480, windowFrames + 1)
            if windowFrames == 480 {
                // Same 0.01 RMS amplitude threshold; no silence-absence assertion.
                if max(0, squareSum) < 480 * 0.01 * 0.01 {
                    quietWindows += 1
                    if quietStart == nil { quietStart = frame - 479 }
                    quietEnd = frame + 1
                } else if let start = quietStart, let end = quietEnd {
                    quietRuns.append(FullSourceReferenceRun(firstFrame: start, endFrame: end))
                    quietStart = nil; quietEnd = nil
                }
            }
            frames += 1
        }

        mutating func finish() {
            if let start = stereoStart {
                stereoRuns.append(FullSourceReferenceRun(firstFrame: start, endFrame: frames))
                stereoStart = nil
            }
            if let start = quietStart, let end = quietEnd {
                quietRuns.append(FullSourceReferenceRun(firstFrame: start, endFrame: end))
                quietStart = nil; quietEnd = nil
            }
        }

        func dump() {
            print("FullSourceAReference schema=2 status=completed source=exact-runtime-Saved-A placement=after-original-acceptance-and-cleanup coverage=edited-presentation sampleRate=48000 channels=2 floatBits=32 payloadCapacityBytes=2097152 rawFrameBudget=1964288 sampleBufferBudget=8192 rawFrames=\(rawFrames) presentedFrames=\(frames) expectedPresentedFrames=1440000 startTrimAttachmentCount=\(startTrimAttachments) endTrimAttachmentCount=\(endTrimAttachments) speedAttachmentCount=\(speedAttachments) speedMultiplier=1 startTrimmedFrames=\(startTrimFrames) endTrimmedFrames=\(endTrimFrames) trimEvents=\(trimEvents) fullyTrimmedBuffers=\(fullyTrimmedBuffers) editedStartFrame=0 editedEndFrame=\(frames) buffers=\(buffers) outputPTSGaps=0 outputPTSOverlaps=0 editRangeCovered=true readerCompleted=true finiteRawPCM=true finitePresentedMono=true stereoZeroFrames=\(stereoZeroFrames) stereoZeroRuns=\(stereoRuns.count) quietWindowFrames=480 quietRMSAmplitude=0.01 quietWindowStrideFrames=1 quietWindows=\(quietWindows) quietWindowUnionRuns=\(quietRuns.count) retainedRangeCapacity=4 retainedTrimCapacity=2 overflow=\(stereoRuns.overflow || quietRuns.overflow) trimSource=explicit-attachments runtimeFrameJoin=false bitstreamSilenceProven=false playbackAcceptance=unchanged")
            for (role, trim) in [("first", firstTrim), ("maximum-excluded-frames", maximumTrim)] {
                guard let trim else { continue }
                print("FullSourceAReferenceTrim schema=2 role=\(role) buffer=\(trim.buffer) rawStartFrame=\(trim.rawStart) rawFrames=\(trim.rawFrames) startTrimFrames=\(trim.startTrim) endTrimFrames=\(trim.endTrim) outputStartFrame=\(trim.outputStart) outputFrames=\(trim.outputFrames) metadataExplained=true")
            }
            stereoRuns.dump("exact-stereo-zero")
            quietRuns.dump("quiet-window-union")
        }
    }

    /// An edited-presentation reference decode, separate from runtime decoder
    /// state. Explicit metadata only; no inferred trim or mixer-frame join.
    private func auditFullSavedAReference(_ savedURL: URL) async throws -> FullSourceReferenceAudit {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: savedURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1, let track = tracks.first else {
            throw FullSourceReferenceFailure.quality("Expected one fixture audio track")
        }
        let editedRange = try await track.load(.timeRange)
        let assetDuration = try await asset.load(.duration)
        func exactFrame(_ time: CMTime) throws -> Int64 {
            guard time.isNumeric, time.epoch == 0 else {
                throw FullSourceReferenceFailure.quality("Invalid reference timeline")
            }
            let scaled = CMTimeConvertScale(time, timescale: 48_000, method: .default)
            guard scaled.isNumeric, scaled.epoch == 0, CMTimeCompare(time, scaled) == 0 else {
                throw FullSourceReferenceFailure.quality("Reference timeline is off the 48 kHz frame grid")
            }
            return scaled.value
        }
        func declaredTrim(_ sample: CMSampleBuffer, key: CFString) throws -> (frames: Int64, present: Bool) {
            guard let value = CMGetAttachment(sample, key: key, attachmentModeOut: nil) else {
                return (0, false) // Only absence uses the documented no-trim default.
            }
            guard CFGetTypeID(value) == CFDictionaryGetTypeID() else {
                throw FullSourceReferenceFailure.quality("Present trim attachment is not a CMTime dictionary")
            }
            let time = CMTimeMakeFromDictionary(value as! CFDictionary)
            let frames = try exactFrame(time)
            guard frames >= 0 else {
                throw FullSourceReferenceFailure.quality("Negative declared trim duration")
            }
            return (frames, true)
        }
        func validateSpeed(_ sample: CMSampleBuffer) throws -> Bool {
            guard let value = CMGetAttachment(sample,
                key: kCMSampleBufferAttachmentKey_SpeedMultiplier, attachmentModeOut: nil) else {
                return false // Only absence uses the documented 1.0 default.
            }
            guard CFGetTypeID(value) == CFNumberGetTypeID() else {
                throw FullSourceReferenceFailure.quality("Present speed attachment is not a CFNumber")
            }
            var speed = 0.0
            guard CFNumberGetValue(value as! CFNumber, .doubleType, &speed),
                  speed.isFinite, speed == 1 else {
                throw FullSourceReferenceFailure.quality("Malformed or unsupported non-unit speed")
            }
            return true
        }
        let editedStart = try exactFrame(editedRange.start)
        let editedEnd = try exactFrame(CMTimeRangeGetEnd(editedRange))
        let assetEnd = try exactFrame(assetDuration)
        guard editedStart == 0, editedEnd == assetEnd, assetEnd == 30 * 48_000 else {
            throw FullSourceReferenceFailure.quality("Full 30-second edited audio range is not established")
        }
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw FullSourceReferenceFailure.quality("Reference output cannot be added")
        }
        reader.add(output) // Full source: intentionally do not set reader.timeRange.
        defer { reader.cancelReading() }
        guard reader.startReading() else {
            throw reader.error ?? FullSourceReferenceFailure.quality("Reference reader did not start")
        }
        let payloadBytes = 2 * 1_024 * 1_024
        let maximumRawFrames: Int64 = assetEnd + Int64(2 * (payloadBytes / 8))
        let maximumBuffers = 8_192
        let payload = UnsafeMutablePointer<Float>.allocate(capacity: payloadBytes / MemoryLayout<Float>.size)
        payload.initialize(repeating: 0, count: payloadBytes / MemoryLayout<Float>.size)
        defer {
            payload.deinitialize(count: payloadBytes / MemoryLayout<Float>.size)
            payload.deallocate()
        }
        var audit = FullSourceReferenceAudit()
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard audit.buffers < maximumBuffers,
                  let description = CMSampleBufferGetFormatDescription(sample),
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == 48_000,
                  format.mChannelsPerFrame == 2, format.mBitsPerChannel == 32,
                  format.mBytesPerFrame == 8, format.mBytesPerPacket == 8, format.mFramesPerPacket == 1,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
                  format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
                throw FullSourceReferenceFailure.quality("Reference buffer budget or PCM layout failed")
            }
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0, count <= payloadBytes / 8,
                  audit.rawFrames <= maximumRawFrames - Int64(count),
                  let block = CMSampleBufferGetDataBuffer(sample),
                  CMBlockBufferGetDataLength(block) == count * 8 else {
                throw FullSourceReferenceFailure.quality("Reference raw-frame/payload budget or frame count failed")
            }
            let startTrim = try declaredTrim(sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
            let endTrim = try declaredTrim(sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
            let speedPresent = try validateSpeed(sample)
            let rawCount = Int64(count)
            // Check each operand before subtraction: malformed large metadata
            // cannot overflow arithmetic or silently discard the payload.
            guard startTrim.frames <= rawCount, endTrim.frames <= rawCount - startTrim.frames else {
                throw FullSourceReferenceFailure.quality("Declared trims exceed raw PCM frame count")
            }
            let presentedCount = rawCount - startTrim.frames - endTrim.frames
            let rawStart = try exactFrame(CMSampleBufferGetPresentationTimeStamp(sample))
            let rawDuration = try exactFrame(CMSampleBufferGetDuration(sample))
            let outputStart = try exactFrame(CMSampleBufferGetOutputPresentationTimeStamp(sample))
            let outputDuration = try exactFrame(CMSampleBufferGetOutputDuration(sample))
            let explainedStart = rawStart.addingReportingOverflow(startTrim.frames)
            // Support only the explicit trim mapping at unit speed. This also
            // requires any negative raw priming PTS to be fully explained.
            guard !explainedStart.overflow, explainedStart.partialValue == outputStart,
                  rawDuration == rawCount, outputDuration == presentedCount,
                  outputStart == audit.frames, outputStart >= 0,
                  outputStart <= editedEnd - presentedCount else {
                throw FullSourceReferenceFailure.quality("Unexplained timing edit, output PTS gap/overlap or incomplete trim mapping")
            }
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 8,
                destination: UnsafeMutableRawPointer(payload)) == kCMBlockBufferNoErr else {
                throw FullSourceReferenceFailure.quality("Reference payload copy failed")
            }
            let firstPresented = Int(startTrim.frames)
            let endPresented = count - Int(endTrim.frames)
            for frame in 0..<count {
                let left = payload[frame * 2], right = payload[frame * 2 + 1]
                guard left.isFinite, right.isFinite else {
                    throw FullSourceReferenceFailure.quality("Nonfinite raw reference PCM")
                }
                if frame >= firstPresented, frame < endPresented {
                    try audit.consume(left: left, right: right)
                }
            }
            audit.recordBuffer(FullSourceReferenceTrim(buffer: audit.buffers, rawStart: rawStart,
                rawFrames: rawCount, startTrim: startTrim.frames, endTrim: endTrim.frames,
                outputStart: outputStart, outputFrames: presentedCount),
                startPresent: startTrim.present, endPresent: endTrim.present, speedPresent: speedPresent)
        }
        try Task.checkCancellation()
        guard reader.status == .completed, reader.error == nil, audit.frames == editedEnd,
              audit.rawFrames - audit.startTrimFrames - audit.endTrimFrames == audit.frames else {
            throw reader.error ?? FullSourceReferenceFailure.quality("Reference reader or full edited-presentation coverage incomplete")
        }
        audit.finish()
        guard !audit.stereoRuns.overflow, !audit.quietRuns.overflow else {
            throw FullSourceReferenceFailure.quality("Reference range counter overflow")
        }
        return audit
    }
    #endif

    private func productionSelectionState(_ service: PlaybackService, fixture: SelectionVideoFixture,
        audio: ContinuousAudioPlayer, id: String) -> ProductionSelectionState {
        let asset = service.player.currentItem?.asset as? AVURLAsset
        let expected = audio.entry(for: id)
        return ProductionSelectionState(audio: audio.renderer.snapshot, expectedToken: expected?.token ?? 0,
            metadataMatches: service.queue.currentID == id && service.current?.id == id,
            assetMatches: asset?.url.standardizedFileURL == fixture.savedURLs[id]?.standardizedFileURL,
            sourceIDMatches: expected?.id == id && audio.selectedID == id,
            engineRunning: service.audioEngineRunning, wantsPlaying: service.wantsToPlay,
            preparedCount: service.preparedAudioCount, submitted: service.submittedVideoFrameCount,
            copied: service.copiedVideoFramePositionSeconds, frame: service.videoFramePositionSeconds,
            requested: service.videoRequestedPositionSeconds, videoReady: service.isVideoReady,
            loading: service.isLoading)
    }

    private func measureProductionSelection(_ service: PlaybackService, screen: SelectionVideoScreen,
        fixture: SelectionVideoFixture, audio: ContinuousAudioPlayer, tap: ProductionSelectionOutputTap,
        seeks: ProductionSelectionSeekRecorder, startup: ProductionVideoStartupTrace, phase: Int, id: String, frequency: Double,
        prepared: Bool, preparedBefore: Bool, preCommandQualification: (() throws -> Void)? = nil,
        command: () throws -> Void) async throws -> ProductionSelectionMeasurement {
        let first = tap.begin()
        if prepared { try? await Task.sleep(for: .milliseconds(120)) }
        // Nil preserves the original path. Qualification may query SDK ownership,
        // so it must finish before the original baseline and command origin.
        try preCommandQualification?()
        let before = audio.renderer.snapshot
        let expectedTokenBefore = audio.entry(for: id)?.token ?? 0
        let submitted = service.submittedVideoFrameCount
        seeks.phase = phase
        startup.phase = phase
        let origin = ProductionSelectionOutputTap.hostSeconds()
        #if DEBUG
        startup.remainingLatencyWitness?.beginPhase(phase, commandNs: DispatchTime.now().uptimeNanoseconds)
        #endif
        try command()
        let commandReturned = ProductionSelectionOutputTap.hostSeconds()
        #if DEBUG
        let replayToneAfterCleanup = acceptedPCMOriginBenchmarkMode != nil
        #else
        let replayToneAfterCleanup = false
        #endif
        var cursor = first
        var outgoing: ProductionSelectionOutputTap.Tone?
        var tone: ProductionSelectionOutputTap.Tone?
        var displayReady: Double?
        var ready: Double?
        let deadline = ProcessInfo.processInfo.systemUptime + (prepared ? 1 : 5)
        #if DEBUG
        let pollSummary = startup.pollSummary
        pollSummary?.setDeadline(phase: phase, uptime: deadline)
        #endif
        var pollUptime = ProcessInfo.processInfo.systemUptime
        while pollUptime < deadline {
            #if DEBUG
            let witnessPollEntryNs = startup.remainingLatencyWitness == nil ? nil : DispatchTime.now().uptimeNanoseconds
            pollSummary?.bodyEntered(phase: phase, at: DispatchTime.now().uptimeNanoseconds)
            pollSummary?.stageEntered(phase: phase, stage: .toneScan, at: DispatchTime.now().uptimeNanoseconds)
            #endif
            while tone == nil, let window = tap.window(at: cursor) {
                cursor += max(1, Int(window.rate * 0.01))
                if prepared, outgoing == nil, window.end <= origin,
                   ProductionSelectionOutputTap.isTone(window.samples, rate: window.rate, frequency: frequency == 440 ? 880 : 440) {
                    outgoing = .init(start: window.start, end: window.end)
                }
                if window.end >= origin,
                   ProductionSelectionOutputTap.isTone(window.samples, rate: window.rate, frequency: frequency) {
                    tone = .init(start: window.start, end: window.end)
                }
            }
            #if DEBUG
            pollSummary?.stageReturned(phase: phase, stage: .toneScan, at: DispatchTime.now().uptimeNanoseconds)
            pollSummary?.stageEntered(phase: phase, stage: .stateCapture, at: DispatchTime.now().uptimeNanoseconds)
            #endif
            let state = productionSelectionState(service, fixture: fixture, audio: audio, id: id)
            #if DEBUG
            pollSummary?.stageReturned(phase: phase, stage: .stateCapture, at: DispatchTime.now().uptimeNanoseconds)
            #endif
            startup.beginPoll()
            #if DEBUG
            pollSummary?.stageEntered(phase: phase, stage: .readinessEvaluation, at: DispatchTime.now().uptimeNanoseconds)
            #endif
            if ready == nil, state.selected, state.audio.visit > before.visit,
               state.submitted > submitted, startup.observeLayerReady(screen.customVideoLayer?.isReadyForDisplay == true),
               let frame = state.frame, let copied = state.copied,
               frame.isFinite, copied.isFinite, state.requested.isFinite, frame >= 0, copied >= 0,
               abs(frame - state.requested) <= 0.080, abs(copied - frame) <= 0.080 {
                if displayReady == nil { displayReady = ProductionSelectionOutputTap.hostSeconds() }
                if state.videoReady && !state.loading {
                    ready = ProductionSelectionOutputTap.hostSeconds()
                }
            }
            #if DEBUG
            pollSummary?.stageReturned(phase: phase, stage: .readinessEvaluation,
                at: DispatchTime.now().uptimeNanoseconds, layerReadyPredicateEvaluated: startup.didEvaluateLayerReady)
            #endif
            startup.recordPoll(uptime: pollUptime, readyLatched: ready != nil,
                state: state, beforeVisit: before.visit, beforeSubmitted: submitted)
            #if DEBUG
            startup.recordRemainingLatencyPoll(entryNs: witnessPollEntryNs, state: state, service: service)
            pollSummary?.bodyReturned(phase: phase, at: DispatchTime.now().uptimeNanoseconds)
            #endif
            if tone != nil && ready != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
            pollUptime = ProcessInfo.processInfo.systemUptime
        }
        #if DEBUG
        pollSummary?.loopExited(phase: phase, at: DispatchTime.now().uptimeNanoseconds, nextCursor: cursor)
        #endif
        let last = tap.stop()
        let finalState = productionSelectionState(service, fixture: fixture, audio: audio, id: id)
        startup.finishPhase(state: finalState, beforeVisit: before.visit, beforeSubmitted: submitted)
        return ProductionSelectionMeasurement(phase: phase, prepared: prepared, preparedBefore: preparedBefore,
            frequency: frequency, first: first, last: last, origin: origin,
            onlineNextCursor: cursor,
            replayToneAfterCleanup: replayToneAfterCleanup,
            commandReturnHostSeconds: commandReturned, outgoing: outgoing, tone: tone,
            displayReady: displayReady, ready: ready, before: before,
            expectedTokenBefore: expectedTokenBefore, beforeSubmitted: submitted,
            state: finalState)
    }

    private func assertProductionSelection(_ value: ProductionSelectionMeasurement, tap: ProductionSelectionOutputTap) {
        let recorded = tap.samples(from: value.first, to: value.last)
        let quiet = ProductionSelectionOutputTap.quietRun(recorded.values, rate: recorded.rate)
        let hole = ProductionSelectionOutputTap.maximumTimelineHole(recorded.hosts, rate: recorded.rate)
        #if DEBUG
        if value.replayToneAfterCleanup {
        let replay = ProductionSelectionOutputTap.replayTone(recorded, origin: value.origin,
            frequency: value.frequency, firstIndex: value.first, onlineNextCursor: value.onlineNextCursor,
            expectedFrames: value.last - value.first)
        print("ProductionSelectionOfflineTone schema=1 phase=\(value.phase) prepared=\(value.prepared) inputValid=\(replay.inputValid) available=\(replay.available) recordedFrames=\(recorded.values.count) rate=\(recorded.rate) firstIndex=\(value.first) lastIndex=\(value.last) onlineNextCursor=\(value.onlineNextCursor) onlineTargetFound=\(value.tone != nil) windows=\(replay.windows) eligibleWindows=\(replay.eligibleWindows) unsearchedEligibleWindows=\(replay.unsearchedEligibleWindows) targetWindows=\(replay.targetWindows) alternateWindows=\(replay.alternateWindows) firstTargetIndex=\(replay.firstTargetIndex) firstTargetStartMs=\(replay.firstTarget.map { String(($0.start - value.origin) * 1000) } ?? "missing") firstTargetEndMs=\(replay.firstTarget.map { String(($0.end - value.origin) * 1000) } ?? "missing") firstAlternateStartMs=\(replay.firstAlternate.map { String(($0.start - value.origin) * 1000) } ?? "missing") firstAlternateEndMs=\(replay.firstAlternate.map { String(($0.end - value.origin) * 1000) } ?? "missing") targetWasUnsearched=\(replay.targetWasUnsearched) replayedVisitedMatchDespiteOnlineMissing=\(value.tone == nil && replay.firstTarget != nil && !replay.targetWasUnsearched) firstRecordedHostSeconds=\(recorded.hosts.first.map { String($0) } ?? "missing") lastRecordedEndHostSeconds=\(recorded.hosts.last.map { String($0 + 1 / max(1, recorded.rate)) } ?? "missing") maximumHoleMs=\(hole * 1000) scratchCapacityFrames=960 scope=retained-measurement-only classifiedAfterCleanup=true availableToPollAt100ms=unmeasured playbackAcceptance=unchanged")
        }
        #endif
        let toneMs = value.tone.map { ($0.end - value.origin) * 1_000 }
        let readyMs = value.ready.map { ($0 - value.origin) * 1_000 }
        let state = value.state
        print("ProductionSelectionLatency phase=\(value.phase) prepared=\(value.prepared) preparedBefore=\(value.preparedBefore) frequency=\(value.frequency) commandHostSeconds=\(value.origin) toneStartMs=\(value.tone.map { String(($0.start - value.origin) * 1_000) } ?? "missing") toneEndMs=\(toneMs.map { String($0) } ?? "missing") customDisplayReadyMs=\(value.displayReady.map { String(($0 - value.origin) * 1_000) } ?? "missing") videoReadyMs=\(readyMs.map { String($0) } ?? "missing") metadataMatches=\(state.metadataMatches) assetMatches=\(state.assetMatches) sourceIDMatches=\(state.sourceIDMatches) expectedToken=\(state.expectedToken) token=\(state.audio.token) visit=\(state.audio.visit) beforeVisit=\(value.before.visit) frame=\(state.audio.frame) ended=\(state.audio.ended) copiedPTS=\(state.copied.map { String($0) } ?? "missing") submittedPTS=\(state.frame.map { String($0) } ?? "missing") requested=\(state.requested) submitted=\(state.submitted) beforeSubmitted=\(value.beforeSubmitted) engineRunning=\(state.engineRunning) wantsPlaying=\(state.wantsPlaying) quietMs=\(quiet * 1_000) maximumHoleMs=\(hole * 1_000) underrunDelta=\(state.audio.underrunFrames - value.before.underrunFrames) producerTracing=absent physicalOutput=unverified compositorPixels=unverified")
        print("ProductionSelectionCommandReturn schema=1 phase=\(value.phase) commandHostSeconds=\(value.origin) returnHostSeconds=\(value.commandReturnHostSeconds) synchronousCommandSpanMs=\((value.commandReturnHostSeconds - value.origin) * 1_000)")
        XCTAssertTrue(value.origin.isFinite); XCTAssertTrue(value.commandReturnHostSeconds.isFinite)
        XCTAssertGreaterThanOrEqual(value.commandReturnHostSeconds, value.origin)
        XCTAssertTrue(value.preparedBefore)
        XCTAssertNotNil(value.tone, "The independently classified target must reach the actual mixer tap")
        XCTAssertNotNil(value.ready, "A fresh, selected and aligned actual custom submission must become ready")
        XCTAssertTrue(state.selected); XCTAssertTrue(state.videoReady); XCTAssertFalse(state.loading)
        XCTAssertGreaterThan(state.audio.visit, value.before.visit)
        XCTAssertGreaterThan(state.submitted, value.beforeSubmitted)
        if value.prepared {
            XCTAssertGreaterThan(value.expectedTokenBefore, 0)
            XCTAssertEqual(state.expectedToken, value.expectedTokenBefore)
            XCTAssertEqual(state.preparedCount, 2)
            XCTAssertNotNil(value.outgoing)
            if let outgoing = value.outgoing, let tone = value.tone { XCTAssertLessThanOrEqual(outgoing.end, tone.start) }
            XCTAssertLessThanOrEqual(toneMs ?? .infinity, 100)
            XCTAssertLessThanOrEqual(readyMs ?? .infinity, 250)
            XCTAssertEqual(state.audio.underrunFrames, value.before.underrunFrames)
            XCTAssertEqual(quiet, 0)
            XCTAssertTrue(recorded.values.allSatisfy { $0.isFinite })
            XCTAssertLessThanOrEqual(hole, 0.5 / max(1, recorded.rate))
        }
    }

    private func assertProductionStream(_ value: ProductionSelectionStream) {
        let result = value.result
        let samples = result.samples.filter { $0.end >= result.origin && $0.end - result.origin <= 8_000_000_000 }
        let elapsed = samples.map { Double($0.end - result.origin) / 1_000_000_000 }
        let gaps = zip(samples, samples.dropFirst()).map { before, after in Double(after.end - before.end) / 1_000_000_000 }
        let acquisition = samples.map { Double($0.end - $0.begin) / 1_000_000_000 }.max() ?? .infinity
        let wall = samples.first.flatMap { first in samples.last.map { Double($0.end - first.end) / 1_000_000_000 } } ?? -1
        let pcm = samples.first.flatMap { first in samples.last.map { Double($0.audio.frame - first.audio.frame) / 48_000 } } ?? -1
        let skew = zip(samples, samples.dropFirst()).map { before, after in
            abs(Double(after.audio.frame - before.audio.frame) / 48_000 - Double(after.end - before.end) / 1_000_000_000)
        }.max() ?? .infinity
        let tolerance = 2 * Double(max(1, value.quantum)) / 48_000 + 0.005
        print("ProductionSelectionStream phase=\(value.phase) seconds=8 samples=\(samples.count) rendererCoherentSamples=\(samples.count) firstMs=\((elapsed.first ?? .infinity) * 1_000) lastMs=\((elapsed.last ?? -1) * 1_000) maximumGapMs=\((gaps.max() ?? .infinity) * 1_000) maximumAcquisitionMs=\(acquisition * 1_000) wallSeconds=\(wall) pcmSeconds=\(pcm) maximumSkewMs=\(skew * 1_000) toleranceMs=\(tolerance * 1_000) quantum=\(value.quantum) dropped=\(result.dropped) acquisitionOutstanding=\(result.acquisitionOutstanding) baselineToken=\(value.baseline.token) finalToken=\(value.final.token) baselineVisit=\(value.baseline.visit) finalVisit=\(value.final.visit) baselineFrame=\(value.baseline.frame) finalFrame=\(value.final.frame) baselineUnderruns=\(value.baseline.underrunFrames) finalUnderruns=\(value.final.underrunFrames) retainedPCMBytes=\(value.memoryBytes) sameStorage=\(value.sameStorage) producerTracing=absent")
        #if DEBUG
        if result.snapshotReadWitnessEnabled {
            var qualityFailures = 0, oddRetrySamples = 0, changedRetrySamples = 0
            for sample in samples {
                guard let read = sample.snapshotRead else { qualityFailures += 1; continue }
                let receipt = read.receipt
                let retries = receipt.oddVersionRetries.addingReportingOverflow(receipt.changedVersionRetries)
                let attempts = retries.partialValue.addingReportingOverflow(1)
                let valid = !receipt.overflow && !retries.overflow && !attempts.overflow
                    && receipt.attempts == attempts.partialValue && receipt.firstVersion != nil
                    && receipt.acceptedVersion & 1 == 0
                    && sample.begin <= read.lockAcquiredNs && read.lockAcquiredNs <= read.snapshotEntryNs
                    && read.snapshotEntryNs <= read.snapshotReturnNs && read.snapshotReturnNs <= sample.end
                if !valid { qualityFailures += 1 }
                if receipt.oddVersionRetries > 0 { oddRetrySamples += 1 }
                if receipt.changedVersionRetries > 0 { changedRetrySamples += 1 }
            }
            print("SnapshotReadWitnessSummary schema=2 phase=\(value.phase) enabled=true samples=\(samples.count) capacity=128 oddRetrySamples=\(oddRetrySamples) changedRetrySamples=\(changedRetrySamples) qualityFailures=\(qualityFailures) writerChanges=false retryLimit=none schedulingAttribution=false")
            XCTAssertEqual(qualityFailures, 0)
            if let maximum = samples.max(by: { $0.end - $0.begin < $1.end - $1.begin }),
               let read = maximum.snapshotRead {
                let receipt = read.receipt
                print("SnapshotReadMaxOuter schema=2 phase=\(value.phase) originNs=\(result.origin) beginNs=\(maximum.begin) lockAcquiredNs=\(read.lockAcquiredNs) snapshotEntryNs=\(read.snapshotEntryNs) snapshotReturnNs=\(read.snapshotReturnNs) endNs=\(maximum.end) outerSpanNs=\(maximum.end - maximum.begin) lockBracketSpanNs=\(read.lockAcquiredNs - maximum.begin) snapshotSpanNs=\(read.snapshotReturnNs - read.snapshotEntryNs) token=\(maximum.audio.token) visit=\(maximum.audio.visit) frame=\(maximum.audio.frame) selectionVersion=\(maximum.audio.selectionVersion) attempts=\(receipt.attempts) oddVersionRetries=\(receipt.oddVersionRetries) changedVersionRetries=\(receipt.changedVersionRetries) firstVersion=\(receipt.firstVersion.map { String($0) } ?? "unknown") acceptedVersion=\(receipt.acceptedVersion) overflow=\(receipt.overflow) pairedWith=maximum-outer-acquisition clock=DispatchTime nativeSDKQueries=0")
            }
        }
        #endif
        for sample in samples {
            print("ProductionSelectionRenderSample phase=\(value.phase) originNs=\(result.origin) beginNs=\(sample.begin) endNs=\(sample.end) elapsedMs=\(Double(sample.end - result.origin) / 1_000_000) acquisitionMs=\(Double(sample.end - sample.begin) / 1_000_000) rendererCoherent=true token=\(sample.audio.token) visit=\(sample.audio.visit) frame=\(sample.audio.frame) ended=\(sample.audio.ended) underrunFrames=\(sample.audio.underrunFrames)")
            #if DEBUG
            if sample.nativeTraceEnabled {
                print("ProductionSelectionNativeLanes schema=1 phase=\(value.phase) beginNs=\(sample.begin) endNs=\(sample.end) token=\(sample.audio.token) visit=\(sample.audio.visit) frame=\(sample.audio.frame) underrunFrames=\(sample.audio.underrunFrames) lane0Available=\(sample.lane0 != nil) lane0Packed=\(sample.lane0?.packedState ?? 0) lane0Sequence=\(sample.lane0?.copySequence ?? 0) lane0Stage=\(sample.lane0?.stageCode ?? 0) lane0Overflow=\(sample.lane0?.sequenceOverflowed ?? false) lane1Available=\(sample.lane1 != nil) lane1Packed=\(sample.lane1?.packedState ?? 0) lane1Sequence=\(sample.lane1?.copySequence ?? 0) lane1Stage=\(sample.lane1?.stageCode ?? 0) lane1Overflow=\(sample.lane1?.sequenceOverflowed ?? false) lane2Available=\(sample.lane2 != nil) lane2Packed=\(sample.lane2?.packedState ?? 0) lane2Sequence=\(sample.lane2?.copySequence ?? 0) lane2Stage=\(sample.lane2?.stageCode ?? 0) lane2Overflow=\(sample.lane2?.sequenceOverflowed ?? false) coherence=individual-packed-words-only")
            }
            #endif
        }
        XCTAssertGreaterThanOrEqual(samples.count, 40); XCTAssertLessThanOrEqual(samples.count, 128)
        XCTAssertGreaterThanOrEqual(samples.count, 20, "Every returned renderer snapshot is coherent; no producer-coherence claim is made")
        XCTAssertLessThanOrEqual(elapsed.first ?? .infinity, 0.25)
        XCTAssertGreaterThanOrEqual(elapsed.last ?? -1, 7.5)
        XCTAssertLessThanOrEqual(gaps.max() ?? .infinity, 0.25)
        XCTAssertLessThanOrEqual(acquisition, 0.005)
        XCTAssertEqual(result.dropped, 0); XCTAssertFalse(result.acquisitionOutstanding)
        XCTAssertTrue(value.before.selected && value.after.selected)
        XCTAssertEqual(value.before.expectedToken, value.after.expectedToken)
        XCTAssertEqual(value.baseline.token, value.before.expectedToken)
        XCTAssertEqual(value.final.token, value.baseline.token); XCTAssertEqual(value.final.visit, value.baseline.visit)
        XCTAssertFalse(value.baseline.ended); XCTAssertFalse(value.final.ended)
        XCTAssertEqual(value.final.underrunFrames, value.baseline.underrunFrames)
        XCTAssertTrue(samples.allSatisfy { $0.audio.token == value.baseline.token && $0.audio.visit == value.baseline.visit
            && !$0.audio.ended && $0.audio.underrunFrames == value.baseline.underrunFrames })
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { before, after in after.audio.frame >= before.audio.frame })
        XCTAssertGreaterThan(pcm, 0); XCTAssertEqual(pcm, wall, accuracy: tolerance)
        XCTAssertLessThanOrEqual(skew, tolerance)
        XCTAssertEqual(value.memoryBytes, 6_912_000); XCTAssertTrue(value.sameStorage)
    }


    #if DEBUG
    private func assertAcceptedPCMOrigin(enabled: Bool, reply: ProductionPCMOriginReply?,
                                         streams: [ProductionSelectionStream], cleanupAcknowledged: Bool) {
        let response = reply?.read()
        let snapshot = response?.snapshot
        print("AcceptedPCMOriginWorker schema=1 enabled=\(enabled) replyReceived=\(response?.received ?? false) available=\(snapshot != nil) cleanupAcknowledged=\(cleanupAcknowledged) records=\(snapshot?.records.count ?? 0) capacityExceeded=\(snapshot?.capacityExceeded ?? false) invalidInput=\(snapshot?.invalidInput ?? false) overflowed=\(snapshot?.overflowed ?? false) workerCoherent=\(snapshot != nil) rendererJointCoherence=false tapJointCoherence=false runtimeFrameJoin=false")
        guard enabled else { XCTAssertNil(reply); return }
        XCTAssertTrue(cleanupAcknowledged)
        XCTAssertEqual(response?.received, true)
        guard let snapshot else { XCTFail("Accepted-origin worker response is unavailable"); return }
        XCTAssertFalse(snapshot.failed)
        XCTAssertLessThanOrEqual(snapshot.records.filter { $0.kind == 1 }.count, 3)
        XCTAssertLessThanOrEqual(snapshot.records.filter { $0.kind == 2 }.count, 12)
        for row in snapshot.records {
            print("AcceptedPCMOriginRange schema=1 kind=\(row.kind) token=\(row.token) slot=\(row.slot) epoch=\(row.epoch) firstFrame=\(row.firstFrame) endFrame=\(row.endFrame) acceptedFrames=\(row.acceptedFrames) batches=\(row.batches) zeroFrames=\(row.zeroFrames) leadingZeroFrames=\(row.leadingZeroFrames) trailingZeroFrames=\(row.trailingZeroFrames) longestZeroFrames=\(row.longestZeroFrames) firstRunStart=\(row.firstRunStart) firstRunEnd=\(row.firstRunEnd) longestRunStart=\(row.longestRunStart) longestRunEnd=\(row.longestRunEnd) trailingRunTouchesCoverageEnd=\(row.trailingRunTouchesCoverageEnd) nonFiniteFrames=\(row.nonFiniteFrames) coverageFailed=\(row.coverageFailed) closed=\(row.closed) frameEndExclusive=true domain=accepted-post-src")
        }
        guard let returned = streams.first(where: { $0.phase == 2 }) else {
            XCTFail("Returned-A source window is unavailable"); return
        }
        let samples = returned.result.samples.filter {
            $0.end >= returned.result.origin && $0.end - returned.result.origin <= 8_000_000_000
        }
        var priorCompletion: UInt64 = 0, firstCompletion: UInt64 = 0, epoch = 0
        var maximumFrame = max(returned.baseline.frame, returned.final.frame)
        var allJoined = !samples.isEmpty
        for sample in samples {
            let receipt = sample.renderAccounting?.pcmOrigin
            let joined = receipt.map {
                snapshot.coverage(token: $0.token, epoch: $0.epoch, through: $0.endFrame)
            }
            print("AcceptedPCMOriginReceipt schema=1 phase=2 beginNs=\(sample.begin) endNs=\(sample.end) available=\(receipt != nil) valid=\(receipt?.valid ?? false) completion=\(receipt?.completion ?? 0) token=\(receipt?.token ?? 0) visit=\(receipt?.visit ?? 0) epoch=\(receipt?.epoch ?? 0) firstFrame=\(receipt?.firstFrame ?? -1) endFrame=\(receipt?.endFrame ?? -1) workerCoverage=\(joined?.complete ?? false) qualifyingZeroInAcceptedRange=\(joined?.hasQualifyingZero ?? false) longestAcceptedZeroFrames=\(joined?.longestZeroFrames ?? 0) rendererSampleToken=\(sample.audio.token) rendererSampleVisit=\(sample.audio.visit) rendererSampleFrame=\(sample.audio.frame) receiptScope=last-completed-kernel independentDomains=true runtimeFrameJoin=false")
            guard let receipt else { allJoined = false; continue }
            if firstCompletion == 0 { firstCompletion = receipt.completion; epoch = receipt.epoch }
            let valid = receipt.valid && receipt.completion > 0 && receipt.completion >= priorCompletion
                && receipt.token == returned.baseline.token && receipt.visit == returned.baseline.visit
                && receipt.epoch == epoch && receipt.epoch > 0 && receipt.epoch % 2 == 0
                && receipt.firstFrame >= 0 && receipt.endFrame > receipt.firstFrame
                && joined?.complete == true
            allJoined = allJoined && valid
            priorCompletion = receipt.completion
            maximumFrame = max(maximumFrame, max(sample.audio.frame, receipt.endFrame))
        }
        let envelope = snapshot.coverage(token: returned.baseline.token, epoch: epoch, through: maximumFrame)
        allJoined = allJoined && envelope.complete
        XCTAssertTrue(allJoined, "Each retained completed span must identify the returned token/visit/epoch and have accepted prefix+ring coverage")
        XCTAssertGreaterThan(priorCompletion, firstCompletion)
        print("AcceptedPCMOriginJoin schema=1 phase=2 token=\(returned.baseline.token) visit=\(returned.baseline.visit) epoch=\(epoch) sourceEnvelopeStart=0 sourceEnvelopeEnd=\(maximumFrame) samples=\(samples.count) allEpochCoverage=\(allJoined) qualifyingZeroInAcceptedRange=\(envelope.hasQualifyingZero) longestAcceptedZeroFrames=\(envelope.longestZeroFrames) boundaryRunStart=\(envelope.boundaryRunStart) boundaryRunEnd=\(envelope.boundaryRunEnd) completionAdvanced=\(priorCompletion > firstCompletion) envelope=all-retained-source-position-observations exactTapFrameJoin=false zeroInterpretation=accepted-range-not-encoded-or-tap")
    }

    /// Cumulative record differences are diagnostic evidence, not a new timing allowance.
    /// Samples retain unavailable/overflow states and stay inside the original acquisition bracket.
    private func assertProductionRenderAccounting(_ value: ProductionSelectionStream, enabled: Bool) {
        typealias Accounting = ContinuousPCMRenderer.DebugRenderAccountingSnapshot
        let samples = value.result.samples.filter {
            $0.end >= value.result.origin && $0.end - value.result.origin <= 8_000_000_000
        }
        let available = samples.compactMap { $0.renderAccounting }
        let unavailable = enabled ? samples.count - available.count : 0
        print("ProductionRenderAccountingWindow schema=1 phase=\(value.phase) enabled=\(enabled) samples=\(samples.count) available=\(available.count) unavailable=\(unavailable) snapshotAttempts=3 coherence=accounting-record-only rendererJointCoherence=false observerReadInsideAcquisition=true baselineToken=\(value.baseline.token) finalToken=\(value.final.token) baselineVisit=\(value.baseline.visit) finalVisit=\(value.final.visit)")
        if !enabled {
            XCTAssertTrue(available.isEmpty, "Nil observer must not synthesize zero counters")
            return
        }
        XCTAssertEqual(unavailable, 0, "Unavailable accounting is retained and fails diagnostic quality")
        for sample in samples {
            let stored = sample.renderAccounting
            func number(_ key: KeyPath<Accounting, UInt64>) -> String {
                stored.map { String($0[keyPath: key]) } ?? "unknown"
            }
            let sourceInFlight = stored.map { String($0.sourceCallbacksEntered > $0.sourceCallbacksCompleted) } ?? "unknown"
            let kernelInFlight = stored.map { String($0.kernelCallsEntered > $0.kernelCallsCompleted) } ?? "unknown"
            print("ProductionRenderAccountingSample schema=1 phase=\(value.phase) beginNs=\(sample.begin) endNs=\(sample.end) available=\(stored != nil) sequence=\(number(\.sequence)) sourceEntered=\(number(\.sourceCallbacksEntered)) sourceCompleted=\(number(\.sourceCallbacksCompleted)) sourceRequestedFrames=\(number(\.sourceFramesRequested)) sourceCompletedFrames=\(number(\.sourceFramesCompleted)) kernelEntered=\(number(\.kernelCallsEntered)) kernelCompleted=\(number(\.kernelCallsCompleted)) kernelRequestedFrames=\(number(\.kernelFramesRequested)) kernelClassifiedFrames=\(number(\.kernelFramesClassified)) copiedPCMFrames=\(number(\.copiedPCMFrames)) pausedPositiveTokenFrames=\(number(\.pausedPositiveTokenFrames)) inactiveFrames=\(number(\.inactiveFrames)) eofRemainderFrames=\(number(\.eofRemainderFrames)) underrunFrames=\(number(\.underrunFrames)) sourceInFlight=\(sourceInFlight) kernelInFlight=\(kernelInFlight) overflowed=\(stored.map { String($0.overflowed) } ?? "unknown") coherence=accounting-record-only rendererJointCoherence=false")
            guard let record = stored else { continue }
            XCTAssertFalse(record.overflowed)
            XCTAssertLessThanOrEqual(record.sourceCallbacksCompleted, record.sourceCallbacksEntered)
            XCTAssertLessThanOrEqual(record.kernelCallsCompleted, record.kernelCallsEntered)
            if record.sourceCallbacksEntered >= record.sourceCallbacksCompleted {
                XCTAssertLessThanOrEqual(record.sourceCallbacksEntered - record.sourceCallbacksCompleted, 1)
            }
            if record.kernelCallsEntered >= record.kernelCallsCompleted {
                XCTAssertLessThanOrEqual(record.kernelCallsEntered - record.kernelCallsCompleted, 1)
            }
            XCTAssertLessThanOrEqual(record.sourceFramesCompleted, record.sourceFramesRequested)
            XCTAssertLessThanOrEqual(record.kernelFramesClassified, record.kernelFramesRequested)
            var classified: UInt64 = 0, sumOverflow = false
            for frames in [record.copiedPCMFrames, record.pausedPositiveTokenFrames,
                           record.inactiveFrames, record.eofRemainderFrames, record.underrunFrames] {
                let next = classified.addingReportingOverflow(frames)
                classified = next.partialValue; sumOverflow = sumOverflow || next.overflow
            }
            XCTAssertFalse(sumOverflow)
            XCTAssertEqual(classified, record.kernelFramesClassified)
            if record.kernelCallsEntered == record.kernelCallsCompleted {
                XCTAssertEqual(record.kernelFramesRequested, record.kernelFramesClassified)
            }
            if record.sourceCallbacksEntered == record.sourceCallbacksCompleted,
               record.kernelCallsEntered == record.kernelCallsCompleted {
                let total = record.kernelFramesRequested.addingReportingOverflow(record.invalidLayoutFrames)
                XCTAssertFalse(total.overflow)
                XCTAssertEqual(record.sourceFramesCompleted, total.partialValue)
            }
            XCTAssertEqual(record.invalidLayoutCallbacks, 0); XCTAssertEqual(record.invalidLayoutFrames, 0)
        }
        guard let firstSample = samples.first, let lastSample = samples.last,
              let first = firstSample.renderAccounting, let last = lastSample.renderAccounting else { return }
        func delta(_ key: KeyPath<Accounting, UInt64>) -> String {
            let before = first[keyPath: key], after = last[keyPath: key]
            XCTAssertGreaterThanOrEqual(after, before)
            return after >= before ? String(after - before) : "invalid"
        }
        for (endpoint, sample, record) in [("first", firstSample, first), ("last", lastSample, last)] {
            print("ProductionRenderAccountingEndpoint schema=1 phase=\(value.phase) endpoint=\(endpoint) beginNs=\(sample.begin) endNs=\(sample.end) sequence=\(record.sequence) sourceCallbacksEntered=\(record.sourceCallbacksEntered) sourceCallbacksCompleted=\(record.sourceCallbacksCompleted) sourceFramesRequested=\(record.sourceFramesRequested) sourceFramesCompleted=\(record.sourceFramesCompleted) invalidLayoutCallbacks=\(record.invalidLayoutCallbacks) invalidLayoutFrames=\(record.invalidLayoutFrames) kernelCallsEntered=\(record.kernelCallsEntered) kernelCallsCompleted=\(record.kernelCallsCompleted) kernelFramesRequested=\(record.kernelFramesRequested) kernelFramesClassified=\(record.kernelFramesClassified) copiedPCMFrames=\(record.copiedPCMFrames) pausedPositiveTokenFrames=\(record.pausedPositiveTokenFrames) inactiveFrames=\(record.inactiveFrames) eofRemainderFrames=\(record.eofRemainderFrames) underrunFrames=\(record.underrunFrames) lastKernelToken=\(record.lastKernelToken) lastKernelVisit=\(record.lastKernelVisit) lastSourceFrameCount=\(record.lastSourceFrameCount) lastSourceHostTimeValid=\(record.lastSourceHostTimeValid) lastSourceHostTime=\(record.lastSourceHostTime) sourceInFlight=\(record.sourceCallbacksEntered > record.sourceCallbacksCompleted) kernelInFlight=\(record.kernelCallsEntered > record.kernelCallsCompleted) uncompletedSourceFrames=\(record.sourceFramesRequested >= record.sourceFramesCompleted ? record.sourceFramesRequested - record.sourceFramesCompleted : 0) unclassifiedKernelFrames=\(record.kernelFramesRequested >= record.kernelFramesClassified ? record.kernelFramesRequested - record.kernelFramesClassified : 0) overflowed=\(record.overflowed) recordCoherent=true rendererJointCoherence=false")
        }
        print("ProductionRenderAccountingDelta schema=1 phase=\(value.phase) firstBeginNs=\(firstSample.begin) firstEndNs=\(firstSample.end) lastBeginNs=\(lastSample.begin) lastEndNs=\(lastSample.end) sourceCallbacksEntered=\(delta(\.sourceCallbacksEntered)) sourceCallbacksCompleted=\(delta(\.sourceCallbacksCompleted)) sourceFramesRequested=\(delta(\.sourceFramesRequested)) sourceFramesCompleted=\(delta(\.sourceFramesCompleted)) invalidLayoutCallbacks=\(delta(\.invalidLayoutCallbacks)) invalidLayoutFrames=\(delta(\.invalidLayoutFrames)) kernelCallsEntered=\(delta(\.kernelCallsEntered)) kernelCallsCompleted=\(delta(\.kernelCallsCompleted)) kernelFramesRequested=\(delta(\.kernelFramesRequested)) kernelFramesClassified=\(delta(\.kernelFramesClassified)) copiedPCMFrames=\(delta(\.copiedPCMFrames)) pausedPositiveTokenFrames=\(delta(\.pausedPositiveTokenFrames)) inactiveFrames=\(delta(\.inactiveFrames)) eofRemainderFrames=\(delta(\.eofRemainderFrames)) underrunFrames=\(delta(\.underrunFrames)) firstSourceInFlight=\(first.sourceCallbacksEntered > first.sourceCallbacksCompleted) firstKernelInFlight=\(first.kernelCallsEntered > first.kernelCallsCompleted) lastSourceInFlight=\(last.sourceCallbacksEntered > last.sourceCallbacksCompleted) lastKernelInFlight=\(last.kernelCallsEntered > last.kernelCallsCompleted) endpointScope=independent-record-reads priorInflightCompletionMayBeIncluded=true playbackAcceptance=unchanged")
    }
    #endif

    func testGeneratedSavedFixturesDecodeToExpectedDistinctTones() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        for (id, expected, other) in [(fixture.aID, 440.0, 880.0), (fixture.bID, 880.0, 440.0)] {
            let samples = try await fixture.decodedTone(id: id)
            XCTAssertGreaterThanOrEqual(samples.count, 10_000)
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
            XCTAssertGreaterThan(rms, 0.05, "The saved AAC fixture must decode to non-silent PCM")
            func power(_ frequency: Double) -> Double {
                var real = 0.0, imaginary = 0.0
                for (frame, sample) in samples.enumerated() {
                    let phase = 2 * Double.pi * frequency * Double(frame) / 48_000
                    real += Double(sample) * cos(phase)
                    imaginary += Double(sample) * sin(phase)
                }
                return (real * real + imaginary * imaginary) / pow(Double(max(1, samples.count)), 2)
            }
            let expectedPower = power(expected), otherPower = power(other)
            print("SelectionTone source=\(id == fixture.aID ? "A" : "B") frames=\(samples.count) rms=\(rms) expectedHz=\(expected) expectedPower=\(expectedPower) otherPower=\(otherPower)")
            XCTAssertGreaterThan(expectedPower, 0.0025, "The expected tone needs substantial decoded energy")
            XCTAssertGreaterThan(expectedPower, 100 * max(otherPower, 1e-12),
                                 "Independently decoded Saved A/B must contain their distinct expected tones")
        }
    }

    func testRestoredOffsetRevealsTheSelectedPausedFrame() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        try JSONEncoder().encode(PlaybackBookmark(
            queue: PlaybackQueue(ids: fixture.ids, startAt: fixture.bID), position: 0.4))
            .write(to: fixture.bookmark)
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }

        service.restore()
        try await require({ !service.isLoading && abs(service.player.currentTime().seconds - 0.4) < 0.04 },
                          "The real Saved B item must finish restoring to 0.4 seconds")
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertPausedCustomFrame(service, screen: screen, requested: 0.4, after: 0, label: "restore-0.4-settled")
        if let restored = await assertVisibleFrame(service, screen: screen, identity: .b, label: "restored-B-at-0.4") {
            let center = try XCTUnwrap(restored.blueBarCenter, "The paused restored frame must contain B's blue marker")
            let normalized = center / Double(restored.width)
            print("SelectionRestored position=0.4 blueNormalized=\(normalized) expected=\(38.0 / 160.0)")
            XCTAssertEqual(normalized, 38.0 / 160.0, accuracy: 0.04,
                           "The visible paused B frame must correspond to the restored 0.4-second offset")
        }
        assertPausedCustomFrameState(service, screen: screen, requested: 0.4, after: 0, label: "restore-0.4-captured")
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.player.rate, 0)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertEqual(service.audioSnapshot.selectionVersion, 0,
                       "A paused restore must not start audio to acknowledge its requested position")

        // A short backwards seek must reset the custom display's frame epoch,
        // even though its distance is below the ordinary 80 ms drift threshold.
        let beforeBackward = service.submittedVideoFrameCount
        logCustomFrame(service, screen: screen, label: "backward-0.35-before")
        service.seek(0.35)
        try await require({ abs(service.player.currentTime().seconds - 0.35) < 0.04 },
                          "The selected paused item must complete the backwards seek")
        await assertPausedCustomFrame(service, screen: screen, requested: 0.35, after: beforeBackward,
                                      label: "backward-0.35-settled")
        if let earlier = await assertVisibleFrame(service, screen: screen, identity: .b, label: "paused-B-backwards-to-0.35") {
            let center = try XCTUnwrap(earlier.blueBarCenter)
            let normalized = center / Double(earlier.width)
            print("SelectionPausedBackward position=0.35 blueNormalized=\(normalized) expected=\(28.0 / 160.0)")
            XCTAssertEqual(normalized, 28.0 / 160.0, accuracy: 0.04,
                           "The actual paused composite must replace the later frame after a short backwards seek")
        }
        assertPausedCustomFrameState(service, screen: screen, requested: 0.35, after: beforeBackward,
                                     label: "backward-0.35-captured")
        assertSelection(service, fixture: fixture, id: fixture.bID)
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertEqual(service.audioSnapshot.selectionVersion, 0)
        XCTAssertEqual(service.player.rate, 0)

        // Both requests share one actor turn, so the first native completion must
        // converge on the latest target even though they differ by only 50 ms.
        let beforeCoalesced = service.submittedVideoFrameCount
        logCustomFrame(service, screen: screen, label: "coalesced-0.65-to-0.60-before")
        service.seek(0.65)
        service.seek(0.60)
        try await require({ abs(service.player.currentTime().seconds - 0.60) < 0.04 },
                          "The latest paused seek must supersede the in-flight target")
        await assertPausedCustomFrame(service, screen: screen, requested: 0.60, after: beforeCoalesced,
                                      label: "coalesced-0.60-settled")
        if let newest = await assertVisibleFrame(service, screen: screen, identity: .b, label: "paused-B-latest-0.60") {
            let center = try XCTUnwrap(newest.blueBarCenter)
            let normalized = center / Double(newest.width)
            print("SelectionPausedLatest position=0.60 blueNormalized=\(normalized) expected=\(48.0 / 160.0)")
            XCTAssertEqual(normalized, 48.0 / 160.0, accuracy: 0.04,
                           "The actual paused composite must show the latest coalesced seek target")
        }
        assertPausedCustomFrameState(service, screen: screen, requested: 0.60, after: beforeCoalesced,
                                     label: "coalesced-0.60-captured")
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertEqual(service.audioSnapshot.selectionVersion, 0)
        XCTAssertEqual(service.player.rate, 0)

        service.play()
        try await require({ service.audioSnapshot.token != 0 && service.audioSnapshot.frame > 2_400 },
                          "Restored B must enter the actual audio renderer after explicit Play")
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "restored-B-playing")
    }

    func testStaleHeldReadyCallbackCannotDisplaceNewInitialZeroOwner() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            let oldRequest = service.debugInitialVideoReadyState.generation + 1
            let currentRequest = oldRequest + 1
            let old = SelectionInitialReadyOrderingProbe(generation: oldRequest)
            let current = SelectionInitialReadyOrderingProbe(generation: currentRequest)
            service.onDebugInitialVideoReady = { request in
                if request == oldRequest { await old.hold(request: request) }
                else if request == currentRequest { await current.hold(request: request) }
            }
            service.onDebugVideoSeekStamp = { stamp in current.record(stamp) }
            defer {
                // Both holds are finite and released before the existing owned
                // task/decoder cleanup, including every setup or assertion exit.
                old.release(); current.release()
                service.onDebugInitialVideoReady = nil
                service.onDebugVideoSeekStamp = nil
            }
            let baselineUnderruns = service.audioSnapshot.underrunFrames
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return old.isHolding && state.generation == oldRequest && state.readyGeneration == nil
                    && sample.token > 0 && state.audioVisit == sample.visit && !sample.ended
                    && service.preparedAudioCount == 2 && buffer.hasPrepared(fixture.bID)
            }, "Real A readiness must be held and fresh B must be staged before supersession")
            let a = service.audioSnapshot
            let bToken = try XCTUnwrap(audio.entry(for: fixture.bID)).token
            XCTAssertNotEqual(a.token, bToken)
            assertSelection(service, fixture: fixture, id: fixture.aID)

            service.next()
            let currentHeld = await waitUntil(timeout: 1) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return old.isHolding && current.isHolding && state.generation == currentRequest
                    && state.readyGeneration == nil && sample.token == bToken && sample.visit > a.visit
                    && state.audioVisit == sample.visit && !sample.ended
            }
            XCTAssertTrue(currentHeld, "Both real callbacks must overlap before releasing only the stale one")
            guard currentHeld else { throw SelectionVideoTestFailure.timeout }
            let beforeOldRelease = service.audioSnapshot
            let submitted = service.submittedVideoFrameCount
            let oldActiveBeforeRelease = old.active
            let oldStillHeldAfterSupersession = old.isHolding && oldActiveBeforeRelease > 0
            XCTAssertTrue(oldStillHeldAfterSupersession,
                          "A cancelled or timed-out old callback cannot stand in for stale delivery")
            guard oldStillHeldAfterSupersession else { throw SelectionVideoTestFailure.timeout }
            old.release()
            let oldExited = await waitUntil(timeout: 0.25) { old.active == 0 }
            XCTAssertTrue(oldExited, "The stale real callback's bounded hold must actually return")
            guard oldExited else { throw SelectionVideoTestFailure.timeout }
            let survivedOldDelivery = await waitUntil(timeout: 0.75) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return current.isHolding && state.generation == currentRequest && state.readyGeneration == nil
                    && sample.token == bToken && sample.visit == beforeOldRelease.visit && !sample.ended
                    && state.audioVisit == sample.visit && sample.frame >= beforeOldRelease.frame + 9_600
            }
            let held = service.audioSnapshot, heldState = service.debugInitialVideoReadyState
            let native = service.player.currentTime().seconds
            let drift = abs(native - Double(held.frame) / 48_000)
            current.stopRecording()
            print("InitialZeroStaleReadyControl schema=1 oldRequest=\(oldRequest) currentRequest=\(currentRequest) oldEntered=\(old.entered) oldActiveBeforeRelease=\(oldActiveBeforeRelease) oldStillHeldAfterSupersession=\(oldStillHeldAfterSupersession) oldActive=\(old.active) currentEntered=\(current.entered) currentActive=\(current.active) oldCancelled=\(old.cancelled) currentCancelled=\(current.cancelled) oldTimedOut=\(old.timedOut) currentTimedOut=\(current.timedOut) oldExited=\(oldExited) survivedOldDelivery=\(survivedOldDelivery) readyGeneration=\(heldState.readyGeneration.map { String($0) } ?? "missing") nativePosition=\(native) absoluteDrift=\(drift) reasons=\(current.reasons.map { String($0) }.joined(separator: ",")) underrunDelta=\(held.underrunFrames - baselineUnderruns) ownerProof=observable-pending-ready-behavior")
            XCTAssertTrue(survivedOldDelivery)
            XCTAssertEqual(old.active, 0); XCTAssertTrue(current.isHolding)
            XCTAssertFalse(old.timedOut); XCTAssertFalse(current.timedOut)
            XCTAssertFalse(old.cancelled); XCTAssertFalse(current.cancelled)
            XCTAssertFalse(old.overflow); XCTAssertFalse(current.overflow)
            XCTAssertEqual(old.dropped, 0); XCTAssertEqual(current.dropped, 0)
            XCTAssertNil(heldState.readyGeneration, "Old delivery must not mark any generation ready")
            XCTAssertEqual(heldState.generation, currentRequest)
            XCTAssertNil(heldState.syncingVideoGeneration)
            XCTAssertEqual(service.submittedVideoFrameCount, submitted,
                           "Stale readiness must not authorize the new item's frame feed")
            XCTAssertTrue(drift.isFinite); XCTAssertGreaterThan(drift, 0.080)
            XCTAssertFalse(current.reasons.contains(PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue))
            XCTAssertFalse(current.reasons.contains(PlaybackService.DebugVideoSeekReason.drift.rawValue),
                           "Old delivery must not remove the current owner's ordinary-drift deferral")
            XCTAssertEqual(held.underrunFrames, baselineUnderruns)
            assertSelection(service, fixture: fixture, id: fixture.bID)
            guard survivedOldDelivery else { throw SelectionVideoTestFailure.timeout }

            current.release()
            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                guard let frame = service.videoFramePositionSeconds,
                      let copied = service.copiedVideoFramePositionSeconds else { return false }
                return current.active == 0 && state.generation == currentRequest && state.readyGeneration == currentRequest
                    && state.syncingVideoGeneration == nil && sample.token == bToken && sample.visit == held.visit
                    && sample.frame >= held.frame + 2_400 && !sample.ended
                    && service.submittedVideoFrameCount > submitted && service.isVideoReady && !service.isLoading
                    && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                    && abs(frame - service.videoRequestedPositionSeconds) <= 0.080 && abs(copied - frame) <= 0.080
                    && abs(service.player.currentTime().seconds - Double(sample.frame) / 48_000) <= 0.080
                    && screen.customVideoLayer?.isReadyForDisplay == true
            }, "Only current readiness release may reveal aligned selected B with continued PCM")
            assertSelection(service, fixture: fixture, id: fixture.bID)
            XCTAssertTrue(service.wantsToPlay); XCTAssertTrue(service.audioEngineRunning)
            await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "stale-ready-released-current-B")
            let displayed = service.audioSnapshot
            XCTAssertEqual(displayed.token, bToken); XCTAssertEqual(displayed.visit, held.visit)
            XCTAssertFalse(displayed.ended); XCTAssertGreaterThan(displayed.frame, held.frame)
            XCTAssertEqual(displayed.underrunFrames, baselineUnderruns)

            service.pause()
            try await require({ !service.audioEngineRunning }, "Explicit final Pause must settle the actual audio engine")
            let paused = service.audioSnapshot
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertFalse(service.wantsToPlay); XCTAssertFalse(service.audioEngineRunning)
            XCTAssertEqual(service.player.rate, 0)
            XCTAssertEqual(service.audioSnapshot.token, paused.token)
            XCTAssertEqual(service.audioSnapshot.visit, paused.visit)
            XCTAssertEqual(service.audioSnapshot.frame, paused.frame)
            XCTAssertEqual(service.audioSnapshot.underrunFrames, baselineUnderruns)
        }
        #else
        XCTFail("Stale initial-ready controls require DEBUG hooks")
        #endif
    }

    func testInitialReadyBindsNativeVideoToAdvancedAudioWithoutReseeking() async throws {
        #if DEBUG
        try await withOwnedNaturalFixture { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            let request = service.debugInitialVideoReadyState.generation + 1
            let probe = SelectionInitialReadyOrderingProbe(generation: request)
            service.onDebugInitialVideoReady = { generation in await probe.hold(request: generation) }
            service.onDebugVideoSeekStamp = { stamp in probe.record(stamp) }
            defer {
                probe.release()
                service.onDebugInitialVideoReady = nil
                service.onDebugVideoSeekStamp = nil
            }
            let baselineUnderruns = service.audioSnapshot.underrunFrames
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return probe.isHolding && state.generation == request && state.readyGeneration == nil
                    && state.syncingVideoGeneration == nil && sample.token > 0 && !sample.ended
                    && state.audioVisit == sample.visit && sample.frame >= 9_600
            }, "Real initial readiness must remain held while acknowledged PCM advances at least 200 ms")
            let held = captureInitialReadyNativeClock(service)
            let token = try XCTUnwrap(audio.entry(for: fixture.aID)).token
            XCTAssertEqual(held.after.token, token)
            XCTAssertTrue(held.sameIdentity); XCTAssertLessThanOrEqual(held.acquisitionSeconds, 0.005)
            XCTAssertTrue(held.nativePosition.isFinite); XCTAssertGreaterThan(held.alignmentErrorSeconds, 0.080)
            XCTAssertTrue(probe.reasons.isEmpty, "The existing initial owner must prevent pre-release corrections")
            XCTAssertFalse(probe.timedOut); XCTAssertFalse(probe.cancelled); XCTAssertFalse(probe.overflow)
            XCTAssertEqual(probe.dropped, 0); XCTAssertEqual(held.after.underrunFrames, baselineUnderruns)
            guard held.sameIdentity, held.acquisitionSeconds <= 0.005,
                  held.nativePosition.isFinite, held.alignmentErrorSeconds > 0.080,
                  probe.isHolding, probe.reasons.isEmpty else { throw SelectionVideoTestFailure.timeout }

            // The ready-generation read below cannot run midway through the
            // synchronous actor callback. Do not wait for a drift seek to finish:
            // the window must include the first native clock after ready binding.
            probe.release()
            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return probe.active == 0 && state.generation == request && state.readyGeneration == request
                    && sample.token == token && sample.visit == held.after.visit && !sample.ended
            }, "The real ready callback must return before the post-ready native-clock window")
            var observations: [InitialReadyNativeClockObservation] = []
            observations.reserveCapacity(32)
            for _ in 0..<32 {
                let value = captureInitialReadyNativeClock(service)
                observations.append(value)
                if let first = observations.first,
                   value.end - first.begin >= 200_000_000,
                   value.after.frame >= first.before.frame + 9_600 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            probe.stopRecording()
            let postReady = service.audioSnapshot
            let submitted = service.submittedVideoFrameCount
            let revealed = await waitUntil(timeout: 5) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                guard let frame = service.videoFramePositionSeconds,
                      let copied = service.copiedVideoFramePositionSeconds else { return false }
                return state.generation == request && state.readyGeneration == request
                    && state.syncingVideoGeneration == nil && sample.token == token && sample.visit == held.after.visit
                    && sample.frame >= postReady.frame + 2_400 && !sample.ended
                    && service.submittedVideoFrameCount > submitted && service.isVideoReady && !service.isLoading
                    && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                    && abs(frame - service.videoRequestedPositionSeconds) <= 0.080 && abs(copied - frame) <= 0.080
                    && abs(service.player.currentTime().seconds - Double(sample.frame) / 48_000) <= 0.080
                    && screen.customVideoLayer?.isReadyForDisplay == true
            }
            assertSelection(service, fixture: fixture, id: fixture.aID)
            await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "initial-ready-native-clock-A")
            let final = service.audioSnapshot
            XCTAssertEqual(final.token, token); XCTAssertEqual(final.visit, held.after.visit)
            XCTAssertFalse(final.ended); XCTAssertGreaterThan(final.frame, postReady.frame)
            XCTAssertEqual(final.underrunFrames, baselineUnderruns)
            // Keep numeric dumps and analysis outside the observed clock/window
            // and moving-pixel acquisition; the owned helper still joins cleanup.
            service.pause(); audio.graph.engine.stop()
            let gaps = zip(observations, observations.dropFirst()).map { Double($1.begin - $0.end) / 1_000_000_000 }
            let wall = observations.first.flatMap { first in observations.last.map { Double($0.end - first.begin) / 1_000_000_000 } } ?? -1
            let pcm = observations.first.flatMap { first in observations.last.map { Double($0.after.frame - first.before.frame) / 48_000 } } ?? -1
            print("InitialReadyNativeClockControl schema=1 request=\(request) heldBeforeFrame=\(held.before.frame) heldAfterFrame=\(held.after.frame) heldNativePosition=\(held.nativePosition) heldAcquisitionMs=\(held.acquisitionSeconds * 1_000) heldSameIdentity=\(held.sameIdentity) heldOffsetErrorMs=\(held.alignmentErrorSeconds * 1_000) observations=\(observations.count) capacity=32 requestedIntervalMs=10 wallSeconds=\(wall) pcmSeconds=\(pcm) maximumGapMs=\((gaps.max() ?? .infinity) * 1_000) revealed=\(revealed) reasons=\(probe.reasons.map { String($0) }.joined(separator: ",")) nativeReadsPerObservation=1 rendererReadsPerObservation=2 latencyAcceptance=false physicalOutput=unverified")
            held.dumpBoundaries(request: request, label: "held")
            XCTAssertTrue(revealed, "Ready binding must reveal a fresh selected custom frame with continuing aligned PCM")
            for value in observations {
                value.dumpBoundaries(request: request, label: "released")
                print("InitialReadyNativeClockObservation schema=1 request=\(request) beginNs=\(value.begin) endNs=\(value.end) acquisitionMs=\(value.acquisitionSeconds * 1_000) token=\(value.after.token) visit=\(value.after.visit) beforeFrame=\(value.before.frame) afterFrame=\(value.after.frame) nativePosition=\(value.nativePosition) alignmentErrorMs=\(value.alignmentErrorSeconds * 1_000) sameIdentity=\(value.sameIdentity) underrunFrames=\(value.after.underrunFrames)")
                XCTAssertTrue(value.sameIdentity)
                XCTAssertEqual(value.after.token, token); XCTAssertEqual(value.after.visit, held.after.visit)
                XCTAssertLessThanOrEqual(value.acquisitionSeconds, 0.005)
                XCTAssertTrue(value.nativePosition.isFinite)
                XCTAssertLessThanOrEqual(value.alignmentErrorSeconds, 0.080,
                                         "Initial native clock must bind advanced audio without a corrective seek")
                XCTAssertEqual(value.before.underrunFrames, baselineUnderruns)
                XCTAssertEqual(value.after.underrunFrames, baselineUnderruns)
            }
            XCTAssertGreaterThanOrEqual(observations.count, 5); XCTAssertLessThanOrEqual(observations.count, 32)
            XCTAssertGreaterThanOrEqual(wall, 0.2); XCTAssertGreaterThanOrEqual(pcm, 0.2)
            XCTAssertLessThanOrEqual(gaps.max() ?? .infinity, 0.050)
            XCTAssertFalse(probe.reasons.contains(PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue))
            XCTAssertFalse(probe.reasons.contains(PlaybackService.DebugVideoSeekReason.drift.rawValue),
                           "The real release window must not repair its initial binding through an exact drift seek")
            XCTAssertFalse(probe.timedOut); XCTAssertFalse(probe.cancelled); XCTAssertFalse(probe.overflow)
            XCTAssertEqual(probe.dropped, 0)
        }
        #else
        XCTFail("Initial-ready native-clock controls require DEBUG hooks")
        #endif
    }

    #if DEBUG
    private struct InitialReadyNativeClockObservation {
        let begin: UInt64, beforeSnapshotReturnNs: UInt64, nativeReturnNs: UInt64, end: UInt64
        func dumpBoundaries(request: Int, label: String) {
            print("InitialReadyNativeClockBoundaries schema=2 label=\(label) request=\(request) beginNs=\(begin) beforeSnapshotReturnNs=\(beforeSnapshotReturnNs) nativeReturnNs=\(nativeReturnNs) endNs=\(end) beforeSnapshotSpanNs=\(beforeSnapshotReturnNs - begin) nativeBracketSpanNs=\(nativeReturnNs - beforeSnapshotReturnNs) afterSnapshotSpanNs=\(end - nativeReturnNs) nativeReads=1 snapshotReads=2 nativeSource=fresh-item-timebase nativeOwnerQueries=2 itemTimebaseLookups=1 clock=DispatchTime spansIncludeMarkers=true")
        }
        let before: ContinuousPCMRenderer.Snapshot, after: ContinuousPCMRenderer.Snapshot
        let nativePosition: Double
        let nativeOwnerUnchanged: Bool
        var acquisitionSeconds: Double { Double(end - begin) / 1_000_000_000 }
        var sameIdentity: Bool {
            nativeOwnerUnchanged && before.token > 0 && before.token == after.token && before.visit == after.visit
                && before.selectionVersion == after.selectionVersion && !before.ended && !after.ended
                && after.frame >= before.frame
        }
        var alignmentErrorSeconds: Double {
            guard sameIdentity, nativePosition.isFinite else { return .infinity }
            // Distance to the actual renderer-frame bracket, without adding a
            // second timing tolerance to the existing 80 ms alignment limit.
            return max(0, max(Double(before.frame) / 48_000 - nativePosition,
                              nativePosition - Double(after.frame) / 48_000))
        }
    }

    private func captureInitialReadyNativeClock(_ service: PlaybackService) -> InitialReadyNativeClockObservation {
        let begin = DispatchTime.now().uptimeNanoseconds
        let before = service.audioSnapshot
        let beforeSnapshotReturnNs = DispatchTime.now().uptimeNanoseconds
        let item = service.player.currentItem
        let timebase = item?.timebase
        let native = timebase.map { CMTimebaseGetTime($0).seconds } ?? .nan
        let nativeOwnerUnchanged = item != nil && service.player.currentItem === item
        let nativeReturnNs = DispatchTime.now().uptimeNanoseconds
        let after = service.audioSnapshot
        let end = DispatchTime.now().uptimeNanoseconds
        return InitialReadyNativeClockObservation(begin: begin, beforeSnapshotReturnNs: beforeSnapshotReturnNs,
            nativeReturnNs: nativeReturnNs, end: end, before: before, after: after,
                                                  nativePosition: native, nativeOwnerUnchanged: nativeOwnerUnchanged)
    }
    #endif

    func testExplicitSeekEntryBeforeInitialOwnerInstallationPreservesNativeCorrection() async throws {
        #if DEBUG
        try await withOwnedNaturalFixture { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            service.debugInitialLoadPhaseEnabled = true
            let request = service.debugInitialVideoReadyState.generation + 1
            let probe = SelectionInitialReadyOrderingProbe(generation: request)
            service.onDebugInitialVideoReady = { generation in await probe.hold(request: generation) }
            service.onDebugVideoSeekStamp = { stamp in probe.record(stamp) }
            defer {
                probe.release()
                service.onDebugInitialVideoReady = nil
                service.onDebugVideoSeekStamp = nil
            }
            let before = service.audioSnapshot
            // No await: the cold load Task cannot install its item/owner before
            // this real seek entry. Its guard may reject the target; history is
            // intentionally conservative even for that no-op request.
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            let beforeInstallation = service.player.currentItem == nil
                && service.debugInitialVideoReadyState.generation == request
                && service.debugInitialVideoReadyState.readyGeneration == nil
            XCTAssertTrue(beforeInstallation)
            guard beforeInstallation else { return }
            service.seek(0.04)
            // Cold setup has the original natural case's three-second budget.
            // Its completion is separate from the unchanged correction deadline.
            let initialHeld = await waitUntil(timeout: 3) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                let expected = audio.entry(for: fixture.aID)?.token ?? 0
                return probe.isHolding && state.generation == request && state.readyGeneration != request
                    && expected > 0 && sample.token == expected && state.audioVisit == sample.visit
            }
            guard initialHeld else {
                XCTFail("The real cold initial-ready callback and acknowledged audio visit must be held before checking correction")
                let phase = service.debugInitialLoadPhaseState
                print("InitialZeroExplicitSeekSetup schema=1 held=false request=\(request) loadRequest=\(phase.request) generation=\(phase.generation) loadPhase=\(phase.phase.rawValue) phaseEnabled=\(phase.enabled)")
                await recordNaturalRunwayFailure(audio: audio,
                    expectedToken: audio.entry(for: fixture.aID)?.token ?? 0, stage: "explicit-preinstall-setup")
                return
            }
            let correctedWhileHeld = await waitUntil(timeout: 1.5) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                let expected = audio.entry(for: fixture.aID)?.token ?? 0
                return probe.isHolding && state.generation == request && state.readyGeneration != request
                    && expected > 0 && sample.token == expected && state.audioVisit == sample.visit
                    && probe.reasons.contains { $0 == PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue
                        || $0 == PlaybackService.DebugVideoSeekReason.drift.rawValue }
            }
            let held = service.audioSnapshot
            probe.stopRecording()
            print("InitialZeroExplicitSeekControl schema=1 mode=preinstall request=\(request) beforeInstallation=\(beforeInstallation) requestedSeconds=0.04 targetAcceptance=unverified correctedWhileHeld=\(correctedWhileHeld) held=\(probe.isHolding) reasons=\(probe.reasons.map { String($0) }.joined(separator: ",")) underrunDelta=\(held.underrunFrames - before.underrunFrames)")
            XCTAssertTrue(correctedWhileHeld, "Explicit seek entry before owner installation must leave native correction eligible")
            XCTAssertTrue(probe.isHolding); XCTAssertFalse(probe.timedOut); XCTAssertFalse(probe.cancelled)
            XCTAssertFalse(probe.overflow); XCTAssertEqual(probe.dropped, 0)
            XCTAssertEqual(held.underrunFrames, before.underrunFrames)
            guard correctedWhileHeld else { return }
            try await finishExplicitInitialReadyControl(service, screen: screen, fixture: fixture,
                probe: probe, token: held.token, baselineUnderruns: before.underrunFrames,
                label: "initial-zero-explicit-preinstall-A")
        }
        #else
        XCTFail("Initial-zero explicit seek controls require DEBUG hooks")
        #endif
    }

    func testPauseSeekResumeBeforeFirstReturnedVisitPreservesExplicitForce() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await require({ self.explicitInitialReadySourceSettled(service, screen: screen)
                && service.preparedAudioCount == 2 }, "Initial A must settle before the explicit resumed-seek control")
            let aToken = service.audioSnapshot.token
            service.next()
            try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token != aToken
                && self.explicitInitialReadySourceSettled(service, screen: screen)
                && service.preparedAudioCount == 2 }, "Prepared B must settle before the explicit resumed-seek control")
            try await require({ buffer.previousMediaID == fixture.aID && buffer.debugPreviousNeedsRewind == false },
                              "Retained A must finish its real offscreen rewind")
            let before = service.audioSnapshot
            let request = service.debugInitialVideoReadyState.generation + 1
            let probe = SelectionInitialReadyOrderingProbe(generation: request)
            service.onDebugInitialVideoReady = { generation in await probe.hold(request: generation) }
            service.onDebugVideoSeekStamp = { stamp in probe.record(stamp) }
            defer {
                probe.release()
                service.onDebugInitialVideoReady = nil
                service.onDebugVideoSeekStamp = nil
            }
            // One actor turn: neither readiness delivery nor the actor's audio
            // poll can run between these real actions. The paused seek clears
            // pendingAudioSeek before play restores intent.
            service.previous()
            service.pause()
            service.seek(0.4)
            service.play()
            let correctedWhileHeld = await waitUntil(timeout: 1.5) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return probe.isHolding && state.generation == request && state.readyGeneration != request
                    && sample.token == aToken && sample.visit > before.visit && state.audioVisit == sample.visit
                    && sample.frame >= 19_200
                    && probe.reasons.contains(PlaybackService.DebugVideoSeekReason.userPausedSeek.rawValue)
            }
            let held = service.audioSnapshot
            probe.stopRecording()
            print("InitialZeroExplicitSeekControl schema=1 mode=paused-resumed request=\(request) requestedSeconds=0.4 correctedWhileHeld=\(correctedWhileHeld) held=\(probe.isHolding) playingIntent=\(service.wantsToPlay) reasons=\(probe.reasons.map { String($0) }.joined(separator: ",")) underrunDelta=\(held.underrunFrames - before.underrunFrames) historyOnlyBarrier=unproven")
            XCTAssertTrue(correctedWhileHeld, "Explicit paused force must remain eligible while initial readiness is withheld")
            XCTAssertTrue(service.wantsToPlay); XCTAssertTrue(service.audioEngineRunning)
            XCTAssertTrue(probe.isHolding); XCTAssertFalse(probe.timedOut); XCTAssertFalse(probe.cancelled)
            XCTAssertFalse(probe.overflow); XCTAssertEqual(probe.dropped, 0)
            XCTAssertEqual(held.underrunFrames, before.underrunFrames)
            guard correctedWhileHeld else { throw SelectionVideoTestFailure.timeout }
            try await finishExplicitInitialReadyControl(service, screen: screen, fixture: fixture,
                probe: probe, token: aToken, baselineUnderruns: before.underrunFrames,
                label: "initial-zero-explicit-paused-resumed-A")
        }
        #else
        XCTFail("Initial-zero explicit seek controls require DEBUG hooks")
        #endif
    }

    #if DEBUG
    private func explicitInitialReadySourceSettled(_ service: PlaybackService, screen: SelectionVideoScreen) -> Bool {
        let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
        return sample.token > 0 && sample.frame > 2_400 && !sample.ended
            && state.readyGeneration == state.generation && state.audioVisit == sample.visit
            && state.syncingVideoGeneration == nil && service.isVideoReady && !service.isLoading
            && screen.customVideoLayer?.isReadyForDisplay == true
    }

    private func finishExplicitInitialReadyControl(_ service: PlaybackService, screen: SelectionVideoScreen,
        fixture: SelectionVideoFixture, probe: SelectionInitialReadyOrderingProbe, token: Int,
        baselineUnderruns: Int64, label: String) async throws {
        let submitted = service.submittedVideoFrameCount
        let before = service.audioSnapshot
        XCTAssertEqual(before.token, token); XCTAssertFalse(before.ended)
        probe.release()
        try await require({
            let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
            guard let frame = service.videoFramePositionSeconds,
                  let copied = service.copiedVideoFramePositionSeconds else { return false }
            return state.generation == probe.generation && state.readyGeneration == probe.generation
                && state.syncingVideoGeneration == nil && sample.token == token && sample.visit == before.visit
                && sample.frame >= before.frame + 2_400 && !sample.ended
                && service.submittedVideoFrameCount > submitted && service.isVideoReady && !service.isLoading
                && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                && abs(frame - service.videoRequestedPositionSeconds) <= 0.080 && abs(copied - frame) <= 0.080
                && abs(service.player.currentTime().seconds - Double(sample.frame) / 48_000) <= 0.080
                && screen.customVideoLayer?.isReadyForDisplay == true
        }, "Released real readiness must reveal a fresh selected and aligned custom frame")
        assertSelection(service, fixture: fixture, id: fixture.aID)
        XCTAssertTrue(service.wantsToPlay); XCTAssertTrue(service.audioEngineRunning)
        XCTAssertEqual(service.audioSnapshot.underrunFrames, baselineUnderruns)
        await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: label)
        XCTAssertEqual(service.audioSnapshot.token, token)
        XCTAssertEqual(service.audioSnapshot.visit, before.visit); XCTAssertFalse(service.audioSnapshot.ended)
        XCTAssertGreaterThan(service.audioSnapshot.frame, before.frame)
        XCTAssertEqual(service.audioSnapshot.underrunFrames, baselineUnderruns)
    }
    #endif

    func testReturnedVideoWaitsForInitialReadyCallbackBeforeVisitOrDriftSeek() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await require({
                let state = service.debugInitialVideoReadyState
                let sample = service.audioSnapshot
                return sample.token != 0 && sample.frame > 2_400 && service.preparedAudioCount == 2
                    && state.readyGeneration == state.generation && state.audioVisit == sample.visit
                    && state.syncingVideoGeneration == nil && service.isVideoReady
                    && screen.customVideoLayer?.isReadyForDisplay == true
            }, "Initial A must finish its real readiness path before the ordering control")
            let aToken = service.audioSnapshot.token
            assertSelection(service, fixture: fixture, id: fixture.aID)

            service.next()
            try await require({
                let state = service.debugInitialVideoReadyState
                let sample = service.audioSnapshot
                return service.queue.currentID == fixture.bID && sample.token != 0 && sample.token != aToken
                    && sample.frame > 2_400 && service.preparedAudioCount == 2
                    && state.readyGeneration == state.generation && state.audioVisit == sample.visit
                    && state.syncingVideoGeneration == nil && service.isVideoReady
                    && screen.customVideoLayer?.isReadyForDisplay == true
            }, "Prepared B must settle before holding returned A's real ready callback")
            assertSelection(service, fixture: fixture, id: fixture.bID)
            try await require({ buffer.previousMediaID == fixture.aID && buffer.debugPreviousNeedsRewind == false },
                              "Retained A must finish its real offscreen rewind for the initial zero-start control")
            let beforeReturn = service.audioSnapshot
            let returnedGeneration = service.debugInitialVideoReadyState.generation + 1
            let probe = SelectionInitialReadyOrderingProbe(generation: returnedGeneration)
            service.onDebugInitialVideoReady = { request in await probe.hold(request: request) }
            // Record before Previous: the bad seek can precede entry into the held callback.
            service.onDebugVideoSeekStamp = { stamp in probe.record(stamp) }
            defer {
                // This body exits before withOwnedNaturalFixture performs its existing
                // preparation/decoder acknowledgements and owned-file cleanup.
                probe.release()
                service.onDebugInitialVideoReady = nil
                service.onDebugVideoSeekStamp = nil
            }

            service.previous()
            let visitProcessed = await waitUntil(timeout: 1.5) {
                let state = service.debugInitialVideoReadyState
                let sample = service.audioSnapshot
                return probe.isHolding && state.generation == returnedGeneration
                    && state.readyGeneration != returnedGeneration && sample.token == aToken
                    && sample.visit > beforeReturn.visit && state.audioVisit == sample.visit
            }
            XCTAssertTrue(visitProcessed,
                          "The real returned-A callback must be held after the service processes its acknowledged visit")
            guard visitProcessed else { throw SelectionVideoTestFailure.timeout }
            let heldBaseline = service.audioSnapshot
            let progressedWhileHeld = await waitUntil(timeout: 0.75) {
                let state = service.debugInitialVideoReadyState
                let sample = service.audioSnapshot
                return probe.isHolding && state.generation == returnedGeneration
                    && state.readyGeneration != returnedGeneration && state.audioVisit == sample.visit
                    && sample.token == aToken && sample.visit == heldBaseline.visit
                    && sample.frame >= heldBaseline.frame + 9_600
            }
            let held = service.audioSnapshot
            let heldState = service.debugInitialVideoReadyState
            let nativePosition = service.player.currentTime().seconds
            let drift = abs(nativePosition - Double(held.frame) / 48_000)
            probe.stopRecording()
            print("InitialReadyOrdering phase=held generation=\(returnedGeneration) heldCallbacks=\(probe.entered) activeCallbacks=\(probe.active) timedOut=\(probe.timedOut) cancelled=\(probe.cancelled) overflow=\(probe.overflow) visitProcessed=\(visitProcessed) progressed=\(progressedWhileHeld) cachedVisit=\(heldState.audioVisit) renderVisit=\(held.visit) renderFrame=\(held.frame) nativePosition=\(nativePosition) absoluteDrift=\(drift) readyGeneration=\(heldState.readyGeneration.map { String($0) } ?? "missing") syncingGeneration=\(heldState.syncingVideoGeneration.map { String($0) } ?? "missing") seekReasons=\(probe.reasons.map { String($0) }.joined(separator: ",")) dropped=\(probe.dropped) underrunDelta=\(held.underrunFrames - beforeReturn.underrunFrames)")
            XCTAssertTrue(progressedWhileHeld, "Real PCM must advance 200 ms while initial readiness remains withheld")
            XCTAssertTrue(probe.isHolding)
            XCTAssertFalse(probe.timedOut); XCTAssertFalse(probe.cancelled); XCTAssertFalse(probe.overflow)
            XCTAssertEqual(probe.dropped, 0)
            XCTAssertEqual(heldState.generation, returnedGeneration)
            XCTAssertNotEqual(heldState.readyGeneration, returnedGeneration)
            XCTAssertEqual(heldState.audioVisit, held.visit)
            XCTAssertEqual(held.token, aToken); XCTAssertEqual(held.visit, heldBaseline.visit)
            XCTAssertEqual(held.underrunFrames, beforeReturn.underrunFrames)
            XCTAssertEqual(service.player.currentItem?.status, .readyToPlay)
            XCTAssertTrue(drift.isFinite)
            // A premature seek can already have aligned native time. It still fails
            // the forbidden-reason assertions below. A passing no-seek control must
            // prove that ordinary drift would otherwise be eligible.
            if !probe.reasons.contains(PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue)
                && !probe.reasons.contains(PlaybackService.DebugVideoSeekReason.drift.rawValue) {
                XCTAssertGreaterThan(drift, 0.080, "A passing control must make ordinary drift eligible before callback delivery")
            }
            XCTAssertNil(heldState.syncingVideoGeneration, "Initial callback ownership must not be displaced by a seek")
            XCTAssertFalse(probe.reasons.contains(PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue),
                           "A newly acknowledged visit must not seek before its initial ready callback owns the timeline")
            XCTAssertFalse(probe.reasons.contains(PlaybackService.DebugVideoSeekReason.drift.rawValue),
                           "Ordinary drift must not seek before the initial ready callback owns the timeline")
            assertSelection(service, fixture: fixture, id: fixture.aID)

            let submittedBeforeRelease = service.submittedVideoFrameCount
            probe.release()
            try await require({
                let state = service.debugInitialVideoReadyState
                let sample = service.audioSnapshot
                guard let frame = service.videoFramePositionSeconds,
                      let copied = service.copiedVideoFramePositionSeconds else { return false }
                return state.generation == returnedGeneration && state.readyGeneration == returnedGeneration
                    && state.syncingVideoGeneration == nil && sample.token == aToken && sample.visit == held.visit
                    && sample.frame >= held.frame + 2_400 && !sample.ended
                    && service.submittedVideoFrameCount > submittedBeforeRelease
                    && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                    && abs(frame - service.videoRequestedPositionSeconds) <= 0.080
                    && abs(copied - frame) <= 0.080
                    && abs(service.player.currentTime().seconds - Double(sample.frame) / 48_000) <= 0.080
                    && service.isVideoReady && !service.isLoading
                    && screen.customVideoLayer?.isReadyForDisplay == true
            }, "Releasing the real callback must produce a fresh selected and aligned custom frame with continued PCM")
            XCTAssertTrue(service.audioEngineRunning); XCTAssertTrue(service.wantsToPlay)
            XCTAssertEqual(service.audioSnapshot.underrunFrames, beforeReturn.underrunFrames)
            assertSelection(service, fixture: fixture, id: fixture.aID)
            await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "initial-ready-released-returned-A")
            let final = service.audioSnapshot
            XCTAssertEqual(final.token, aToken); XCTAssertEqual(final.visit, held.visit)
            XCTAssertGreaterThan(final.frame, held.frame)
            XCTAssertEqual(final.underrunFrames, beforeReturn.underrunFrames)
        }
        #else
        XCTFail("Initial-ready ordering controls require DEBUG hooks")
        #endif
    }

    func testReturnedVideoReadyBeforeFirstVisitDoesNotForceSourceVisitSeek() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            service.debugInitialLoadPhaseEnabled = true
            defer { service.debugInitialLoadPhaseEnabled = false }
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            var initialState: PlaybackService.DebugInitialVideoReadyState?
            var initialAudio: ContinuousPCMRenderer.Snapshot?
            var initialVideoReady = false, initialLoading = true
            var initialCustomReady: Bool?, initialBPrepared: Bool?
            var initialPreparedCount: Int?
            do {
                try await require({
                    let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                    initialState = state; initialAudio = sample
                    initialVideoReady = service.isVideoReady; initialLoading = service.isLoading
                    initialCustomReady = nil; initialPreparedCount = nil; initialBPrepared = nil
                    // Preserve the original short circuit: the native layer and
                    // buffer predicates are read only when their earlier guards pass.
                    guard sample.token > 0 && sample.frame > 2_400 && !sample.ended
                        && state.readyGeneration == state.generation && state.audioVisit == sample.visit
                        && state.syncingVideoGeneration == nil && initialVideoReady && !initialLoading else { return false }
                    let customReady = screen.customVideoLayer?.isReadyForDisplay == true
                    initialCustomReady = customReady
                    guard customReady else { return false }
                    let preparedCount = service.preparedAudioCount
                    initialPreparedCount = preparedCount
                    guard preparedCount == 2 else { return false }
                    let prepared = buffer.hasPrepared(fixture.bID)
                    initialBPrepared = prepared
                    return prepared
                }, "Initial A and prepared B must settle before the ready-before-visit control")
            } catch {
                let load = service.debugInitialLoadPhaseState
                print("InitialReadySetupFailure schema=1 currentGeneration=\(initialState.map { String($0.generation) } ?? "unknown") readyGeneration=\(initialState?.readyGeneration.map { String($0) } ?? "unknown") cachedVisit=\(initialState.map { String($0.audioVisit) } ?? "unknown") syncingGeneration=\(initialState?.syncingVideoGeneration.map { String($0) } ?? "unknown") token=\(initialAudio.map { String($0.token) } ?? "unknown") frame=\(initialAudio.map { String($0.frame) } ?? "unknown") visit=\(initialAudio.map { String($0.visit) } ?? "unknown") ended=\(initialAudio.map { String($0.ended) } ?? "unknown") videoReady=\(initialVideoReady) loading=\(initialLoading) customReady=\(initialCustomReady.map { String($0) } ?? "unread") preparedCount=\(initialPreparedCount.map { String($0) } ?? "unread") preparedB=\(initialBPrepared.map { String($0) } ?? "unread") loadEnabled=\(load.enabled) loadRequest=\(load.request) loadGeneration=\(load.generation) loadPhase=\(load.phase.rawValue)")
                throw error
            }
            let aToken = service.audioSnapshot.token
            assertSelection(service, fixture: fixture, id: fixture.aID)
            service.next()
            try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token != aToken
                && self.explicitInitialReadySourceSettled(service, screen: screen)
                && service.preparedAudioCount == 2 }, "Prepared B must settle before returning to A")
            assertSelection(service, fixture: fixture, id: fixture.bID)
            try await require({ buffer.previousMediaID == fixture.aID && buffer.debugPreviousNeedsRewind == false },
                              "Retained A must finish its real offscreen rewind before Previous")
            let before = service.audioSnapshot
            let oldVisit = service.debugInitialVideoReadyState.audioVisit
            XCTAssertEqual(oldVisit, before.visit)
            XCTAssertEqual(audio.selectedID, fixture.bID)
            XCTAssertEqual(audio.entry(for: fixture.aID)?.token, aToken)
            let request = service.debugInitialVideoReadyState.generation + 1
            let probe = SelectionInitialReadyOrderingProbe(generation: request)
            var holdAdoption = true, gateTimedOut = false, gateOverflow = false
            var blockedAttempts = 0
            let gateDeadline = ProcessInfo.processInfo.systemUptime + 3
            service.shouldDebugDeferAudioVisit = { generation in
                guard generation == request, holdAdoption else { return false }
                guard ProcessInfo.processInfo.systemUptime < gateDeadline else {
                    gateTimedOut = true; return false
                }
                if blockedAttempts < 128 { blockedAttempts += 1 }
                else { gateOverflow = true }
                return true
            }
            service.onDebugVideoSeekStamp = { stamp in probe.record(stamp) }
            defer {
                // Release before the existing owned preparation/decoder cleanup on every exit.
                holdAdoption = false
                service.shouldDebugDeferAudioVisit = nil
                service.onDebugVideoSeekStamp = nil
            }

            // Keep the real initial-ready callback unmodified and unheld. Only the
            // main-actor visit adoption is deferred; native PCM continues rendering A.
            service.previous()
            let readyBeforeVisit = await waitUntil(timeout: 1.5) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return blockedAttempts > 0 && !gateTimedOut && !gateOverflow
                    && state.generation == request && state.readyGeneration == request
                    && state.audioVisit == oldVisit && sample.token == aToken && sample.visit > oldVisit
                    && state.syncingVideoGeneration == nil && !sample.ended
                    && audio.selectedID == fixture.aID && service.wantsToPlay && service.audioEngineRunning
            }
            XCTAssertTrue(readyBeforeVisit,
                          "Real returned-A readiness must finish while only its first visit adoption is held")
            guard readyBeforeVisit else { throw SelectionVideoTestFailure.timeout }
            let readySample = service.audioSnapshot
            let progressedWhileHeld = await waitUntil(timeout: 0.75) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return !gateTimedOut && !gateOverflow && state.readyGeneration == request
                    && state.audioVisit == oldVisit && sample.token == aToken && sample.visit == readySample.visit
                    && sample.frame >= readySample.frame + 9_600 && !sample.ended
            }
            let held = service.audioSnapshot
            XCTAssertTrue(progressedWhileHeld, "Actual A PCM must continue for 200 ms before service visit adoption")
            XCTAssertEqual(held.underrunFrames, before.underrunFrames)
            XCTAssertFalse(gateTimedOut); XCTAssertFalse(gateOverflow)
            XCTAssertTrue(probe.reasons.isEmpty, "The qualified zero-start readiness must not require a seek")
            assertSelection(service, fixture: fixture, id: fixture.aID)
            guard progressedWhileHeld, !gateTimedOut, !gateOverflow else { throw SelectionVideoTestFailure.timeout }

            let submitted = service.submittedVideoFrameCount
            holdAdoption = false
            let adopted = await waitUntil(timeout: 1.5) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return state.generation == request && state.readyGeneration == request
                    && state.audioVisit == held.visit && sample.token == aToken && sample.visit == held.visit
                    && sample.frame > held.frame && !sample.ended
            }
            XCTAssertTrue(adopted, "The next real poll must acknowledge the exact held A visit after release")
            XCTAssertFalse(probe.reasons.contains(PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue),
                           "A ready zero-start must not be replaced by a forced seek on its first acknowledged visit")
            guard adopted else { throw SelectionVideoTestFailure.timeout }
            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                guard let frame = service.videoFramePositionSeconds,
                      let copied = service.copiedVideoFramePositionSeconds else { return false }
                return state.generation == request && state.readyGeneration == request
                    && state.audioVisit == held.visit && state.syncingVideoGeneration == nil
                    && sample.token == aToken && sample.visit == held.visit && !sample.ended
                    && sample.frame >= held.frame + 2_400 && service.submittedVideoFrameCount > submitted
                    && service.isVideoReady && !service.isLoading && screen.customVideoLayer?.isReadyForDisplay == true
                    && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                    && abs(frame - service.videoRequestedPositionSeconds) <= 0.080 && abs(copied - frame) <= 0.080
                    && abs(service.player.currentTime().seconds - Double(sample.frame) / 48_000) <= 0.080
            }, "The acknowledged visit must reveal fresh selected and aligned A frames with continued PCM")
            assertSelection(service, fixture: fixture, id: fixture.aID)
            await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "ready-before-first-visit-returned-A")
            let final = service.audioSnapshot
            probe.stopRecording()
            print("ReadyBeforeFirstVisitControl schema=1 request=\(request) readyBeforeVisit=\(readyBeforeVisit) oldVisit=\(oldVisit) heldVisit=\(held.visit) blockedAttempts=\(blockedAttempts) gateTimedOut=\(gateTimedOut) gateOverflow=\(gateOverflow) progressedWhileHeld=\(progressedWhileHeld) adopted=\(adopted) seekReasons=\(probe.reasons.map { String($0) }.joined(separator: ",")) dropped=\(probe.dropped) underrunDelta=\(final.underrunFrames - before.underrunFrames) latencyAcceptance=false heldAdoption=diagnostic-only")
            XCTAssertFalse(probe.reasons.contains(PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue))
            XCTAssertEqual(probe.dropped, 0)
            XCTAssertEqual(final.token, aToken); XCTAssertEqual(final.visit, held.visit)
            XCTAssertFalse(final.ended); XCTAssertGreaterThan(final.frame, held.frame)
            XCTAssertEqual(final.underrunFrames, before.underrunFrames)
            XCTAssertEqual(audio.selectedID, fixture.aID)
            XCTAssertTrue(service.wantsToPlay); XCTAssertTrue(service.audioEngineRunning)
        }
        #else
        XCTFail("Ready-before-first-visit ordering controls require DEBUG hooks")
        #endif
    }

    func testPausedRestoreBlocksFrameAcquisitionUntilTheRealSeekCompletionIsReleased() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        try JSONEncoder().encode(PlaybackBookmark(
            queue: PlaybackQueue(ids: fixture.ids, startAt: fixture.bID), position: 0.4))
            .write(to: fixture.bookmark)
        let scheduler = SelectionVideoSeekScheduler()
        let service = fixture.service(seekVideo: scheduler.seek)
        let screen = try SelectionVideoScreen(service: service)
        defer { scheduler.release(); service.pause(); screen.close() }
        var submittedAtStart: UInt64?
        var blockedAtStart: UInt64?
        scheduler.onSeekStarted = { [weak service] in
            submittedAtStart = service?.submittedVideoFrameCount
            blockedAtStart = service?.videoFrameAcquisitionBlockedCount
        }

        service.restore()
        try await require({ scheduler.isHoldingCompletion && scheduler.nativeFinished == true
            && abs(service.player.currentTime().seconds - 0.4) < 0.04 },
                          "The real AVPlayer seek must finish while its service callback remains held")
        let submitted = try XCTUnwrap(submittedAtStart)
        let blocked = try XCTUnwrap(blockedAtStart)
        try await require({ service.videoFrameAcquisitionBlockedCount >= blocked + 2 },
                          "At least two real frame-poll attempts must encounter the held seek gate")
        logCustomFrame(service, screen: screen, label: "held-real-seek-0.4")
        print("SelectionHeldSeek blockedDelta=\(service.videoFrameAcquisitionBlockedCount - blocked) submittedAtStart=\(submitted) submittedNow=\(service.submittedVideoFrameCount)")
        XCTAssertEqual(service.submittedVideoFrameCount, submitted,
                       "No custom frame may be acquired while the real seek callback is withheld")
        XCTAssertNil(service.videoFramePositionSeconds, "The seek's emptied epoch must contain no submitted frame")
        XCTAssertNil(service.copiedVideoFramePositionSeconds, "The held seek must prevent even copying a frame from the old epoch")
        assertSelection(service, fixture: fixture, id: fixture.bID)
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertEqual(service.player.rate, 0)

        scheduler.release()
        await assertPausedCustomFrame(service, screen: screen, requested: 0.4, after: submitted,
                                      label: "released-real-seek-0.4-settled")
        if let pixels = await assertVisibleFrame(service, screen: screen, identity: .b,
                                                 label: "released-real-seek-0.4") {
            let center = try XCTUnwrap(pixels.blueBarCenter)
            let normalized = center / Double(pixels.width)
            print("SelectionHeldSeekReleased position=0.4 blueNormalized=\(normalized) expected=\(38.0 / 160.0)")
            XCTAssertEqual(normalized, 38.0 / 160.0, accuracy: 0.04)
        }
        assertPausedCustomFrameState(service, screen: screen, requested: 0.4, after: submitted,
                                     label: "released-real-seek-0.4-captured")
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertEqual(service.audioSnapshot.selectionVersion, 0)
        XCTAssertEqual(service.player.rate, 0)
    }

    func testPreparedRewoundBUncoversItsOwnMovingVideo() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let buffer = PlaybackBuffer()
        let service = fixture.service(buffer: buffer)
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.bID)
        try await require({ service.audioSnapshot.frame > 2_400 && service.preparedAudioCount == 2 },
                          "Both generated Saved sources must be prepared")
        let bToken = service.audioSnapshot.token
        let preparedB = try XCTUnwrap(service.player.currentItem)

        service.previous()
        try await require({ service.queue.currentID == fixture.aID && service.audioSnapshot.token != bToken
            && service.audioSnapshot.frame > 2_400 }, "A must be the real rendered source before selecting B again")
        let seeked = await withCheckedContinuation { continuation in
            preparedB.seek(to: CMTime(seconds: 0.75, preferredTimescale: 48_000),
                           toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(seeked)
        // Force the real prepared-item branch with an unfinished rewind, rather than depending
        // on whether background previous-item seeking happened to win a simulator race.
        buffer.discardNext()
        buffer.discardPrevious()
        buffer.stagePrevious(.init(mediaID: fixture.bID, item: preparedB, isLocal: true, needsRewind: true))
        service.next()
        try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token == bToken
            && service.audioSnapshot.frame > 2_400 }, "Prepared B must replace A in the audio renderer")
        XCTAssertTrue(service.player.currentItem === preparedB, "The test must exercise the rewound prepared object")
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "rewound-prepared-B")
    }

    func testPreparedABAChangesActualAssetAudioTokenAndCompositePixels() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await require({ service.audioSnapshot.frame > 2_400 && service.preparedAudioCount == 2 },
                          "A and B must both be prepared before the reversal")
        let aToken = service.audioSnapshot.token
        XCTAssertNotEqual(aToken, 0)
        assertSelection(service, fixture: fixture, id: fixture.aID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "initial-A")

        service.next()
        try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token != aToken
            && service.audioSnapshot.token != 0 && service.audioSnapshot.frame > 2_400 },
                          "Selecting B must change the actual render token")
        let bToken = service.audioSnapshot.token
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "selected-B")

        service.previous()
        try await require({ service.queue.currentID == fixture.aID && service.audioSnapshot.token == aToken
            && service.audioSnapshot.frame > 2_400 }, "Previous must return to the prepared A source")
        XCTAssertNotEqual(service.audioSnapshot.token, bToken)
        assertSelection(service, fixture: fixture, id: fixture.aID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "returned-A")
    }

    func testReturnedForwardVideoReusesItsPreparedNativeItemAndOutput() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        let tap = ProductionSelectionOutputTap()
        let seeks = ProductionSelectionSeekRecorder()
        let startup = ProductionVideoStartupTrace(serviceTracing: false)
        var forwardMeasurement: ProductionSelectionMeasurement?
        var reuseReceipt: String?, recoveryReceipt: String?
        defer {
            if let reuseReceipt { print(reuseReceipt) }
            if let recoveryReceipt { print(recoveryReceipt) }
            print("ReturnedForwardVideoLatencyScope schema=1 commandOrdinal=4 phase=1 measured=\(forwardMeasurement != nil) measurementHelper=original toneEndLimitMs=100 readinessLimitMs=250 alignmentLimitMs=80 captureDuringMeasurement=false serviceObservers=false fullThreePhaseBenchmark=false")
            if let forwardMeasurement { assertProductionSelection(forwardMeasurement, tap: tap) }
            seeks.assertUnused()
            let validity = tap.validity()
            XCTAssertEqual(validity.invalidTimestamps, 0); XCTAssertEqual(validity.droppedFrames, 0)
            XCTAssertLessThanOrEqual(tap.count, 12 * 48_000)
        }
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            let originalSources = (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }
            let originalBytes = audio.renderer.retainedPCMMemoryBytes
            // Configure the graph before first playback, with recording disabled until command four.
            audio.graph.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil) { value, time in
                tap.append(value, time: time)
            }
            defer {
                tap.stop(); service.pause()
                audio.graph.engine.mainMixerNode.removeTap(onBus: 0)
                audio.graph.engine.stop()
            }
            service.isInteractingWithFeed = true
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await self.require({ service.queue.currentID == fixture.aID
                && self.explicitInitialReadySourceSettled(service, screen: screen)
                && service.preparedAudioCount == 2 && buffer.hasPrepared(fixture.bID) },
                "Real ready A and prepared B must precede the forward-cache reuse control")
            let aToken = try XCTUnwrap(audio.entry(for: fixture.aID)).token
            let bToken = try XCTUnwrap(audio.entry(for: fixture.bID)).token
            XCTAssertGreaterThan(aToken, 0); XCTAssertGreaterThan(bToken, 0)
            XCTAssertNotEqual(aToken, bToken); XCTAssertEqual(service.queue.repeatMode, .off)
            XCTAssertEqual(service.audioSnapshot.token, aToken)

            service.next()
            try await self.require({ service.queue.currentID == fixture.bID
                && service.audioSnapshot.token == bToken
                && self.explicitInitialReadySourceSettled(service, screen: screen) },
                "The original prepared B must become the real selected source")
            try await self.requireNativeClockContractOwner(service, fixture: fixture, audio: audio, screen: screen, id: fixture.bID)
            self.assertSelection(service, fixture: fixture, id: fixture.bID)
            await self.assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "forward-cache-original-B")

            // Weak witnesses must not prolong the resource whose cache ownership is under test.
            weak var originalBItem: AVPlayerItem?
            weak var originalBResource: ContinuousPictureInPicture.PreparedVideoResource?
            weak var originalBOutput: AVPlayerItemVideoOutput?
            do {
                let item = try XCTUnwrap(service.player.currentItem)
                let resource = try XCTUnwrap(buffer.resource(for: item))
                let output = try XCTUnwrap(resource.output)
                XCTAssertTrue(resource.item === item && resource.isAttached && !resource.isRetired && resource.isBorrowed)
                XCTAssertTrue(item.outputs.contains { $0 === output })
                originalBItem = item; originalBResource = resource; originalBOutput = output
            }
            let baseline = service.audioSnapshot
            XCTAssertEqual(baseline.token, bToken); XCTAssertFalse(baseline.ended)
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)

            service.previous()
            try await self.require({ service.queue.currentID == fixture.aID
                && service.audioSnapshot.token == aToken
                && self.explicitInitialReadySourceSettled(service, screen: screen) },
                "Previous must return to actual A before checking its intended forward cache")
            try await self.requireNativeClockContractOwner(service, fixture: fixture, audio: audio, screen: screen, id: fixture.aID)
            self.assertSelection(service, fixture: fixture, id: fixture.aID)
            await self.assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "forward-cache-returned-A")
            XCTAssertNil(service.previousID); XCTAssertEqual(service.nextID, fixture.bID)
            XCTAssertEqual(service.queue.repeatMode, .off)
            try await self.require({ buffer.hasPrepared(fixture.bID) },
                "Logical Next B must be prepared within the unchanged setup deadline")
            let nextB = try XCTUnwrap(service.player.items().dropFirst().first)
            let nextResource = try XCTUnwrap(buffer.resource(for: nextB))
            let nextOutput = try XCTUnwrap(nextResource.output)
            XCTAssertTrue(nextResource.isAttached && !nextResource.isRetired && !nextResource.isBorrowed)
            XCTAssertTrue(nextB.outputs.contains { $0 === nextOutput })
            XCTAssertEqual(audio.entry(for: fixture.bID)?.token, bToken)
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)
            let sameItem = nextB === originalBItem
            let sameResource = nextResource === originalBResource
            let sameOutput = nextOutput === originalBOutput
            reuseReceipt = "ReturnedForwardVideoReuse schema=1 originalItemAlive=\(originalBItem != nil) originalResourceAlive=\(originalBResource != nil) originalOutputAlive=\(originalBOutput != nil) sameItem=\(sameItem) sameResource=\(sameResource) sameOutput=\(sameOutput) originalToken=\(bToken) preparedToken=\(audio.entry(for: fixture.bID)?.token ?? 0) retainedItems=\(buffer.retainedItemCount) latencyAcceptance=false"
            // These are the intended RED assertions. Continue through real B recovery on failure.
            XCTAssertTrue(sameItem, "Returning to first A must retain its intended Next B AVPlayerItem")
            XCTAssertTrue(sameResource, "The retained forward B must reuse its prepared video resource")
            XCTAssertTrue(sameOutput, "The retained forward B must reuse its actual attached video output")

            XCTAssertEqual(tap.count, 0, "The preinstalled tap must retain no earlier selection or capture samples")
            let preparedBefore = buffer.hasPrepared(fixture.bID) && service.preparedAudioCount == 2
                && audio.entry(for: fixture.bID)?.token == bToken
            forwardMeasurement = try await self.measureProductionSelection(service, screen: screen, fixture: fixture,
                audio: audio, tap: tap, seeks: seeks, startup: startup, phase: 1, id: fixture.bID,
                frequency: 880, prepared: true, preparedBefore: preparedBefore) {
                service.next()
            }
            try await self.require({ service.queue.currentID == fixture.bID
                && service.audioSnapshot.token == bToken
                && self.explicitInitialReadySourceSettled(service, screen: screen) },
                "Next must recover actual B with the original retained PCM token")
            try await self.requireNativeClockContractOwner(service, fixture: fixture, audio: audio, screen: screen, id: fixture.bID)
            XCTAssertTrue(service.player.currentItem === nextB)
            XCTAssertTrue(buffer.resource(for: nextB) === nextResource)
            XCTAssertTrue(nextResource.output === nextOutput && nextResource.isBorrowed)
            self.assertSelection(service, fixture: fixture, id: fixture.bID)
            await self.assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "forward-cache-recovered-B")
            let final = service.audioSnapshot
            XCTAssertEqual(final.token, bToken); XCTAssertFalse(final.ended)
            XCTAssertEqual(final.underrunFrames, baseline.underrunFrames)
            XCTAssertEqual(service.preparedAudioCount, 2)
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)
            XCTAssertEqual(originalBytes, 6_912_000)
            XCTAssertEqual(audio.renderer.retainedPCMMemoryBytes, originalBytes)
            XCTAssertEqual((0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }, originalSources)
            recoveryReceipt = "ReturnedForwardVideoRecovery schema=1 token=\(final.token) visit=\(final.visit) underrunDelta=\(final.underrunFrames - baseline.underrunFrames) queuedItemAdopted=\(service.player.currentItem === nextB) resourceBorrowed=\(nextResource.isBorrowed) retainedItems=\(buffer.retainedItemCount) movingPixels=asserted-after-return latencyAcceptance=false physicalOutput=unverified"
        }
        #else
        XCTFail("Forward-cache ownership qualification requires DEBUG state")
        #endif
    }

    #if DEBUG
    private enum HeldCompletionFailureSentinel: Error { case afterHeldNativeCompletion }
    #endif

    func testRealHeldCompletionFailureCleanupRequiresItsMatchingServiceTaskReturn() async throws {
        #if DEBUG
        let farTarget = SelectionVideoFixture.duration - 2
        let completion = NaturalCompletionSeekHold(minimumTarget: farTarget, maximumTarget: SelectionVideoFixture.duration)
        let buffer = PlaybackBuffer()
        var caughtExpectedSentinel = false
        defer {
            completion.release()
            print("NaturalSeekCompletionFailureCleanup schema=1 caughtExpectedSentinel=\(caughtExpectedSentinel) nativeCallbacks=\(completion.nativeCallbacks) nativeFinished=\(completion.nativeFinished.map { String($0) } ?? "missing") forwarded=\(completion.forwarded) cleanupAcknowledged=\(completion.cleanupAcknowledged) ownerLatchSet=\(Self.targetedFixtureOwnershipLost) latencyAcceptance=false xctestOutcome=external")
            completion.dumpCommandTrace()
        }
        do {
            try await withOwnedNaturalFixture(buffer: buffer,
                seekVideo: { player, time, callback in completion.seek(player, time, callback) },
                additionalCleanupAcknowledged: { completion.cleanupAcknowledged }) { fixture, audio, service, screen in
                defer {
                    service.onDebugVideoSeekStamp = nil; service.onDebugVideoSeekCompletionTerminal = nil
                    completion.release()
                }
                service.isInteractingWithFeed = false
                service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
                try await self.require({ self.explicitInitialReadySourceSettled(service, screen: screen)
                    && service.preparedAudioCount == 2 && buffer.hasPrepared(fixture.bID) },
                    "Real ready A and both complete Saved sources must precede the error-cleanup control")
                self.assertSelection(service, fixture: fixture, id: fixture.aID)
                let itemA = try XCTUnwrap(service.player.currentItem)
                let aToken = try XCTUnwrap(audio.entry(for: fixture.aID)).token
                let bToken = try XCTUnwrap(audio.entry(for: fixture.bID)).token
                let before = service.audioSnapshot, request = service.debugInitialVideoReadyState.generation
                XCTAssertGreaterThan(aToken, 0); XCTAssertGreaterThan(bToken, 0); XCTAssertNotEqual(aToken, bToken)
                guard before.visit < Int64.max else { XCTFail("The real next visit must remain representable"); throw SelectionVideoTestFailure.timeout }
                var issuedCount = 0, issueOverflow = false
                service.onDebugVideoSeekStamp = { stamp in
                    completion.recordIssued(stamp)
                    guard completion.matchesIssued(stamp) else { return }
                    if issuedCount < 8 { issuedCount += 1 } else { issueOverflow = true }
                }
                service.onDebugVideoSeekCompletionTerminal = { [weak completion] terminal in completion?.recordTerminal(terminal) }
                completion.arm(player: service.player, request: request, generation: request,
                    aToken: aToken, visit: before.visit + 1)
                let setupDeadline = ProcessInfo.processInfo.systemUptime + 10
                service.seek(farTarget)
                let heldOnA = await self.waitUntil(timeout: max(0, setupDeadline - ProcessInfo.processInfo.systemUptime)) {
                    let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                    return completion.isHolding && issuedCount == 1 && !issueOverflow && !completion.overflow
                        && completion.rejectedCommands == 0 && state.generation == request
                        && state.readyGeneration == request && state.syncingVideoGeneration == request
                        && state.audioVisit == sample.visit && sample.token == aToken
                        && sample.visit == before.visit + 1 && sample.selectionVersion > before.selectionVersion
                        && sample.frame >= Int64((farTarget + 0.05) * 48_000) && !sample.ended
                        && !audio.isSelectionPending(in: sample) && service.queue.currentID == fixture.aID
                        && audio.selectedID == fixture.aID && service.player.currentItem === itemA
                        && service.wantsToPlay && service.audioEngineRunning && !service.isLoading && !service.audioOnly
                }
                XCTAssertTrue(heldOnA, "The actual successful native completion must be held after fresh real A PCM acknowledges the far seek")
                guard heldOnA else { throw SelectionVideoTestFailure.timeout }
                XCTAssertEqual(completion.nativeCallbacks, 1); XCTAssertEqual(completion.forwarded, 0)
                XCTAssertFalse(completion.cleanupAcknowledged, "The held, unforwarded callback cannot acknowledge cleanup")
                throw HeldCompletionFailureSentinel.afterHeldNativeCompletion
            }
            XCTFail("The exact held-completion sentinel must survive owned cleanup")
        } catch HeldCompletionFailureSentinel.afterHeldNativeCompletion {
            caughtExpectedSentinel = true
            XCTAssertTrue(completion.cleanupAcknowledged, "The matching real service task must return during owned cleanup")
            XCTAssertFalse(Self.targetedFixtureOwnershipLost, "A fully acknowledged error cleanup must not poison the owner latch")
        }
        #else
        XCTFail("Real held-completion error cleanup requires DEBUG ownership hooks")
        #endif
    }

    func testIssuedVideoSeekCompletionCannotActivateStaleABeforeNaturalBVisitAdoption() async throws {
        #if DEBUG
        let farTarget = SelectionVideoFixture.duration - 2
        let completion = NaturalCompletionSeekHold(minimumTarget: farTarget,
            maximumTarget: SelectionVideoFixture.duration)
        var stage = 0
        var decisionReceipt: String?, recoveryReceipt: String?, startupReceipt: String?
        defer {
            completion.release()
            print("NaturalSeekCompletionSummary schema=1 stage=\(stage) intercepted=\(completion.intercepted) nativeCallbacks=\(completion.nativeCallbacks) nativeFinished=\(completion.nativeFinished.map { String($0) } ?? "missing") forwarded=\(completion.forwarded) rejectedCommands=\(completion.rejectedCommands) overflow=\(completion.overflow) cleanupAcknowledged=\(completion.cleanupAcknowledged) latencyAcceptance=false physicalOutput=unverified")
            if let decisionReceipt { print(decisionReceipt) }
            if let recoveryReceipt { print(recoveryReceipt) }
            if let startupReceipt { print(startupReceipt) }
            completion.dumpCommandTrace()
        }
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer,
            seekVideo: { player, time, callback in completion.seek(player, time, callback) },
            additionalCleanupAcknowledged: { completion.cleanupAcknowledged }) { fixture, audio, service, screen in
            service.isInteractingWithFeed = false
            service.debugInitialLoadPhaseEnabled = true
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            var startupPolls = 0, startupPollCountSaturated = false
            var lastAReady: Bool?, lastPreparedAudioCount: Int?, lastBPrepared: Bool?
            let prepared = await waitUntil(timeout: 3) {
                if startupPolls < Int.max { startupPolls += 1 } else { startupPollCountSaturated = true }
                lastAReady = nil; lastPreparedAudioCount = nil; lastBPrepared = nil
                let aReady = self.explicitInitialReadySourceSettled(service, screen: screen)
                lastAReady = aReady
                guard aReady else { return false }
                let preparedAudioCount = service.preparedAudioCount
                lastPreparedAudioCount = preparedAudioCount
                guard preparedAudioCount == 2 else { return false }
                let bPrepared = buffer.hasPrepared(fixture.bID)
                lastBPrepared = bPrepared
                return bPrepared
            }
            if !prepared {
                let ready = service.debugInitialVideoReadyState, load = service.debugInitialLoadPhaseState
                startupReceipt = "NaturalSeekCompletionStartup schema=1 stage=0 prepared=false polls=\(startupPolls) pollCountSaturated=\(startupPollCountSaturated) aReady=\(lastAReady.map { String($0) } ?? "unknown") preparedAudioCount=\(lastPreparedAudioCount.map { String($0) } ?? "unknown") bPrepared=\(lastBPrepared.map { String($0) } ?? "unknown") predicateScope=last-short-circuit-poll loadEnabled=\(load.enabled) loadRequest=\(load.request) loadGeneration=\(load.generation) loadPhase=\(load.phase.rawValue) readyGeneration=\(ready.readyGeneration.map { String($0) } ?? "unknown") generation=\(ready.generation) cachedAudioVisit=\(ready.audioVisit) syncingGeneration=\(ready.syncingVideoGeneration.map { String($0) } ?? "unknown") phaseScope=after-window-not-joint setupBudgetMs=3000 latencyAcceptance=false playbackAcceptance=false"
            }
            XCTAssertTrue(prepared, "Real ready A and both complete Saved sources must precede the completion control")
            guard prepared else { throw SelectionVideoTestFailure.timeout }
            stage = 1
            assertSelection(service, fixture: fixture, id: fixture.aID)
            let itemA = try XCTUnwrap(service.player.currentItem)
            let resourceA = try XCTUnwrap(buffer.resource(for: itemA))
            let outputA = try XCTUnwrap(resourceA.output)
            let aToken = try XCTUnwrap(audio.entry(for: fixture.aID)).token
            let bToken = try XCTUnwrap(audio.entry(for: fixture.bID)).token
            let request = service.debugInitialVideoReadyState.generation
            let beforeSeek = service.audioSnapshot
            let originalSources = (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }
            let originalBytes = audio.renderer.retainedPCMMemoryBytes
            XCTAssertEqual(service.queue.repeatMode, .off)
            XCTAssertGreaterThan(aToken, 0); XCTAssertGreaterThan(bToken, 0); XCTAssertNotEqual(aToken, bToken)
            XCTAssertEqual(beforeSeek.token, aToken); XCTAssertFalse(beforeSeek.ended)
            XCTAssertFalse(audio.isSelectionPending(in: beforeSeek))
            guard beforeSeek.visit <= Int64.max - 2 else {
                XCTFail("One acknowledged far seek and one actual natural visit must remain representable")
                throw SelectionVideoTestFailure.timeout
            }
            var expectedNaturalVisit: Int64?, acknowledgedVersion: Int?
            var holdAdoption = true, gateTimedOut = false, gateOverflow = false
            var gateDeadline: Double?, blockedAttempts = 0
            var issued: PlaybackService.DebugVideoSeekStamp?, issuedCount = 0, issueOverflow = false
            service.onDebugVideoSeekStamp = { stamp in
                completion.recordIssued(stamp)
                guard completion.matchesIssued(stamp) else { return }
                if issuedCount < 8 { issuedCount += 1; if issued == nil { issued = stamp } }
                else { issueOverflow = true }
            }
            service.onDebugVideoSeekCompletionTerminal = { [weak completion] terminal in
                completion?.recordTerminal(terminal)
            }
            service.shouldDebugDeferAudioVisit = { generation in
                guard holdAdoption, generation == request,
                      let expectedNaturalVisit, let acknowledgedVersion else { return false }
                let sample = service.audioSnapshot
                // A's explicit far-seek acknowledgement is never deferred.
                // Only the subsequent real B renderer visit can enter this gate.
                guard sample.token == bToken, sample.visit == expectedNaturalVisit,
                      sample.selectionVersion == acknowledgedVersion,
                      !audio.isSelectionPending(in: sample) else { return false }
                let now = ProcessInfo.processInfo.systemUptime
                if gateDeadline == nil { gateDeadline = now + 3 }
                guard now < (gateDeadline ?? now) else { gateTimedOut = true; return false }
                guard blockedAttempts < 128 else { gateOverflow = true; return false }
                blockedAttempts += 1
                return true
            }
            defer {
                holdAdoption = false
                service.shouldDebugDeferAudioVisit = nil
                service.onDebugVideoSeekStamp = nil
                service.onDebugVideoSeekCompletionTerminal = nil
                service.onDebugVideoRateHandoff = nil
                service.onDebugVideoRenderStamp = nil
                // The issued callback captured its terminal observer before this clear.
                // Forward even if teardown wins before the actual SDK callback.
                completion.release()
            }
            completion.arm(player: service.player, request: request, generation: request,
                aToken: aToken, visit: beforeSeek.visit + 1)
            let setupDeadline = ProcessInfo.processInfo.systemUptime + 10
            service.seek(farTarget)
            let heldOnA = await waitUntil(timeout: max(0, setupDeadline - ProcessInfo.processInfo.systemUptime)) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return completion.isHolding && issuedCount == 1 && !issueOverflow && !completion.overflow
                    && completion.rejectedCommands == 0 && state.generation == request
                    && state.readyGeneration == request && state.syncingVideoGeneration == request
                    && state.audioVisit == sample.visit && sample.token == aToken
                    && sample.visit == beforeSeek.visit + 1 && sample.selectionVersion > beforeSeek.selectionVersion
                    && sample.frame >= Int64((farTarget + 0.05) * 48_000) && !sample.ended
                    && !audio.isSelectionPending(in: sample) && service.queue.currentID == fixture.aID
                    && audio.selectedID == fixture.aID && service.player.currentItem === itemA
                    && service.wantsToPlay && service.audioEngineRunning && !service.isLoading && !service.audioOnly
            }
            XCTAssertTrue(heldOnA, "A must acknowledge the real far seek while its actual successful native completion alone is held")
            guard heldOnA, let issued else { throw SelectionVideoTestFailure.timeout }
            let acknowledgedA = service.audioSnapshot
            guard acknowledgedA.token == aToken, acknowledgedA.visit == beforeSeek.visit + 1,
                  acknowledgedA.selectionVersion > beforeSeek.selectionVersion,
                  acknowledgedA.frame >= Int64((farTarget + 0.05) * 48_000), !acknowledgedA.ended,
                  !audio.isSelectionPending(in: acknowledgedA) else {
                XCTFail("A's fresh real far-seek acknowledgement must still precede the natural B handoff")
                throw SelectionVideoTestFailure.timeout
            }
            stage = 2
            let heldSeek = service.debugAlignedVideoPollState
            XCTAssertTrue(issued.force); XCTAssertEqual(issued.reason, .sourceVisit)
            XCTAssertEqual(issued.generation, request); XCTAssertTrue(issued.observedItemMatches)
            XCTAssertTrue(issued.selectedMatchesQueue); XCTAssertTrue(issued.presentationRequestMatches)
            XCTAssertEqual(heldSeek.frame.activeSeekTicket, issued.nativeSeekTicket)
            XCTAssertEqual(heldSeek.frame.ticket?.debugItemIdentity, ObjectIdentifier(itemA))
            expectedNaturalVisit = acknowledgedA.visit + 1
            acknowledgedVersion = acknowledgedA.selectionVersion
            let naturalB = await waitUntil(timeout: max(0, setupDeadline - ProcessInfo.processInfo.systemUptime)) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return completion.isHolding && blockedAttempts > 0 && !gateTimedOut && !gateOverflow
                    && state.generation == request && state.readyGeneration == request
                    && state.syncingVideoGeneration == request && state.audioVisit == acknowledgedA.visit
                    && sample.token == bToken && sample.visit == expectedNaturalVisit
                    && sample.selectionVersion == acknowledgedVersion && sample.frame > 2_400 && !sample.ended
                    && !audio.isSelectionPending(in: sample) && service.queue.currentID == fixture.aID
                    && audio.selectedID == fixture.aID && service.player.currentItem === itemA
                    && service.wantsToPlay && service.audioEngineRunning && !service.isLoading && !service.audioOnly
            }
            XCTAssertTrue(naturalB, "Only an actual natural B render handoff may qualify this completion release")
            guard naturalB else { throw SelectionVideoTestFailure.timeout }
            stage = 3
            let firstB = service.audioSnapshot
            let progressed = await waitUntil(timeout: 0.75) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return completion.isHolding && !gateTimedOut && !gateOverflow
                    && state.generation == request && state.syncingVideoGeneration == request
                    && state.audioVisit == acknowledgedA.visit && sample.token == bToken
                    && sample.visit == firstB.visit && sample.selectionVersion == firstB.selectionVersion
                    && sample.frame >= firstB.frame + 9_600 && !sample.ended
                    && sample.underrunFrames == acknowledgedA.underrunFrames
            }
            let beforeRelease = service.audioSnapshot
            let oldPresentation = service.debugAlignedVideoPollState
            let nativeAStillCurrent = service.player.currentItem === itemA && itemA.status == .readyToPlay
            let qualified = progressed && completion.isHolding && completion.nativeFinished == true
                && !completion.overflow && completion.rejectedCommands == 0 && issuedCount == 1 && !issueOverflow
                && !gateTimedOut && !gateOverflow && (gateDeadline.map { ProcessInfo.processInfo.systemUptime < $0 } ?? false)
                && nativeAStillCurrent && service.queue.currentID == fixture.aID && audio.selectedID == fixture.aID
                && oldPresentation.generation == request && oldPresentation.request == request
                && oldPresentation.presentationMatches && oldPresentation.observedItemMatches
                && oldPresentation.frame.ticket == heldSeek.frame.ticket
                && oldPresentation.frame.activeSeekTicket == issued.nativeSeekTicket && !oldPresentation.frame.coherent
                && resourceA.item === itemA && resourceA.output === outputA && resourceA.isAttached
                && resourceA.isBorrowed && !resourceA.isRetired
                && beforeRelease.token == bToken && beforeRelease.visit == firstB.visit
                && beforeRelease.selectionVersion == firstB.selectionVersion && !beforeRelease.ended
                && beforeRelease.underrunFrames == acknowledgedA.underrunFrames
            XCTAssertTrue(qualified, "The successful already-issued A completion and exact unadopted B owner must qualify before release")
            guard qualified else { throw SelectionVideoTestFailure.timeout }
            stage = 4
            var staleRateCount = 0, staleAttemptCount = 0, observerOverflow = false
            var observedBAtRate = false, rateOwnerUnchanged = true
            service.onDebugVideoRateHandoff = { stamp in
                guard stamp.cause == .correctionCompletion, stamp.request == request,
                      stamp.item == ObjectIdentifier(itemA) else { return }
                if staleRateCount < 8 { staleRateCount += 1 } else { observerOverflow = true }
                let sample = service.audioSnapshot
                observedBAtRate = sample.token == bToken && sample.visit == beforeRelease.visit
                    && sample.selectionVersion == beforeRelease.selectionVersion && !sample.ended
                rateOwnerUnchanged = rateOwnerUnchanged && observedBAtRate
                    && stamp.entryGeneration == request && stamp.returnGeneration == request
                    && stamp.entryObservedItemMatches && stamp.returnObservedItemMatches && stamp.presentationUnchanged
                    && stamp.presentationTicket == oldPresentation.frame.ticket
                    && stamp.returnPresentationTicket == oldPresentation.frame.ticket
            }
            service.onDebugVideoRenderStamp = { stamp in
                guard stamp.generation == request, stamp.render.stage == .attempt,
                      stamp.render.ticket == oldPresentation.frame.ticket else { return }
                if staleAttemptCount < 8 { staleAttemptCount += 1 } else { observerOverflow = true }
            }
            completion.release()
            let completionProcessed = await waitUntil(timeout: 0.75) {
                service.debugInitialVideoReadyState.syncingVideoGeneration == nil
            }
            let after = service.audioSnapshot, afterPresentation = service.debugAlignedVideoPollState
            let decisionState = service.debugInitialVideoReadyState
            let nativeAAfterCompletion = service.player.currentItem === itemA
            let insideHold = gateDeadline.map { ProcessInfo.processInfo.systemUptime < $0 } ?? false
            let completionQualified = completionProcessed && completion.forwarded == 1 && !observerOverflow
                && rateOwnerUnchanged && nativeAAfterCompletion && service.queue.currentID == fixture.aID
                && audio.selectedID == fixture.aID && insideHold && !gateTimedOut && !gateOverflow
                && blockedAttempts > 0 && blockedAttempts <= 128
                && decisionState.generation == request && decisionState.readyGeneration == request
                && decisionState.audioVisit == acknowledgedA.visit && decisionState.syncingVideoGeneration == nil
                && after.token == bToken && after.visit == beforeRelease.visit
                && after.selectionVersion == beforeRelease.selectionVersion && !after.ended
                && after.frame >= beforeRelease.frame && after.underrunFrames == acknowledgedA.underrunFrames
                && afterPresentation.frame.ticket == oldPresentation.frame.ticket
                && afterPresentation.frame.activeSeekTicket == nil
            let submittedAfterCompletion = service.submittedVideoFrameCount
            decisionReceipt = "NaturalSeekCompletionDecision schema=1 qualified=\(qualified) completionQualified=\(completionQualified) request=\(request) issuedReason=\(issued.reason.rawValue) nativeSeekTicket=\(issued.nativeSeekTicket) nativeFinished=\(completion.nativeFinished == true) nativeTarget=\(completion.targetSeconds.map { String($0) } ?? "missing") selectedToken=\(aToken) acknowledgedAToken=\(acknowledgedA.token) acknowledgedAVisit=\(acknowledgedA.visit) acknowledgedAFrame=\(acknowledgedA.frame) renderedToken=\(after.token) renderedVisit=\(after.visit) cachedVisit=\(decisionState.audioVisit) selectionVersion=\(after.selectionVersion) acknowledgedAUnderruns=\(acknowledgedA.underrunFrames) coldSeekUnderrunDelta=\(acknowledgedA.underrunFrames - beforeSeek.underrunFrames) qualifiedUnderrunDelta=\(after.underrunFrames - acknowledgedA.underrunFrames) blockedAttempts=\(blockedAttempts) gateTimedOut=\(gateTimedOut) gateOverflow=\(gateOverflow) insideHold=\(insideHold) nativeAAfterCompletion=\(nativeAAfterCompletion) staleRateCount=\(staleRateCount) observedBAtRate=\(observedBAtRate) rateOwnerUnchanged=\(rateOwnerUnchanged) staleAttemptCount=\(staleAttemptCount) stalePresentationCoherent=\(afterPresentation.frame.coherent) observerOverflow=\(observerOverflow) latencyAcceptance=false physicalOutput=unverified"
            // Release adoption before XCTest reports the deliberately failing assertions.
            holdAdoption = false; service.shouldDebugDeferAudioVisit = nil
            service.onDebugVideoRateHandoff = nil; service.onDebugVideoRenderStamp = nil
            service.onDebugVideoSeekStamp = nil
            XCTAssertTrue(completionQualified, "The actual A completion must finish while only the healthy B adoption gate remains held")
            guard completionQualified else { throw SelectionVideoTestFailure.timeout }
            XCTAssertTrue(completion.cleanupAcknowledged,
                "The exact real completion task must return before cleanup is acknowledged")
            stage = 5
            // Intended RED: do not allow A's completed seek to install/activate its
            // stale ticket using the position of the already audible natural B.
            XCTAssertEqual(staleRateCount, 0, "An already-issued A correction must not schedule native A after real audio has naturally entered B")
            XCTAssertEqual(staleAttemptCount, 0, "An already-issued A completion must not reopen stale CPP acquisition")
            XCTAssertFalse(afterPresentation.frame.coherent, "The stale A presentation must remain inactive after its completion")

            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                guard let frame = service.videoFramePositionSeconds,
                      let copied = service.copiedVideoFramePositionSeconds else { return false }
                guard service.queue.currentID == fixture.bID && audio.selectedID == fixture.bID
                    && state.generation > request && state.readyGeneration == state.generation
                    && state.syncingVideoGeneration == nil && state.audioVisit == beforeRelease.visit
                    && sample.token == bToken && sample.visit == beforeRelease.visit
                    && sample.selectionVersion == beforeRelease.selectionVersion
                    && sample.frame >= after.frame + 2_400 && !sample.ended && !audio.isSelectionPending(in: sample)
                    && sample.underrunFrames == acknowledgedA.underrunFrames
                    && service.submittedVideoFrameCount > submittedAfterCompletion && service.isVideoReady && !service.isLoading
                    && screen.customVideoLayer?.isReadyForDisplay == true
                    && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                    && abs(frame - service.videoRequestedPositionSeconds) <= 0.080 && abs(copied - frame) <= 0.080
                    else { return false }
                let nativePosition = service.player.currentTime().seconds
                let fresh = service.audioSnapshot
                return fresh.token == bToken && fresh.visit == sample.visit
                    && fresh.selectionVersion == sample.selectionVersion && fresh.frame >= sample.frame
                    && fresh.underrunFrames == sample.underrunFrames && !fresh.ended
                    && nativePosition.isFinite && abs(nativePosition - Double(fresh.frame) / 48_000) <= 0.080
            }, "Releasing adoption must reveal the actual naturally rendered B with fresh aligned PCM and frames")
            stage = 6
            assertSelection(service, fixture: fixture, id: fixture.bID)
            await assertMovingVisibleVideo(service, screen: screen, identity: .b,
                label: "issued-A-completion-natural-B-recovery")
            let final = service.audioSnapshot
            XCTAssertEqual(final.token, bToken); XCTAssertEqual(final.visit, beforeRelease.visit)
            XCTAssertEqual(final.selectionVersion, beforeRelease.selectionVersion)
            XCTAssertGreaterThan(final.frame, after.frame); XCTAssertFalse(final.ended)
            XCTAssertEqual(final.underrunFrames, acknowledgedA.underrunFrames)
            XCTAssertTrue(service.wantsToPlay); XCTAssertTrue(service.audioEngineRunning)
            XCTAssertFalse(gateTimedOut); XCTAssertFalse(gateOverflow); XCTAssertFalse(observerOverflow)
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3); XCTAssertLessThanOrEqual(service.preparedAudioCount, 3)
            XCTAssertEqual(originalBytes, 6_912_000)
            XCTAssertEqual(audio.renderer.retainedPCMMemoryBytes, originalBytes)
            XCTAssertEqual((0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }, originalSources)
            recoveryReceipt = "NaturalSeekCompletionRecovery schema=1 request=\(request) incomingToken=\(final.token) incomingVisit=\(final.visit) selectionVersion=\(final.selectionVersion) pcmDelta=\(final.frame - after.frame) qualifiedUnderrunDelta=\(final.underrunFrames - acknowledgedA.underrunFrames) completionAcknowledged=\(completion.cleanupAcknowledged) latencyAcceptance=false compositorScope=asserted-moving-B physicalOutput=unverified"
            stage = 7
        }
        #else
        XCTFail("Already-issued natural-handoff completion controls require DEBUG ownership hooks")
        #endif
    }

    #if DEBUG
    @MainActor private final class NaturalCompletionSeekHold {
        private struct CommandTrace {
            let issued: PlaybackService.DebugVideoSeekStamp?
            let target: Double?
            let playerMatches: Bool, numeric: Bool, lowerBoundMatches: Bool, upperBoundMatches: Bool
            let armed: Bool, intercepted: Bool, eligible: Bool
        }
        private struct OwnerBinding {
            let request: Int, generation: Int, aToken: Int
            let visit: Int64
        }
        private let minimumTarget: Double, maximumTarget: Double
        private var expectedPlayer: ObjectIdentifier?
        private var ownerBinding: OwnerBinding?
        private var interceptedStamp: PlaybackService.DebugVideoSeekStamp?
        private var terminalEvents = 0
        private var armed = false, released = false, deliveryObserved = false
        private var callback: (@Sendable (Bool) -> Void)?
        private var issueForNextCommand: PlaybackService.DebugVideoSeekStamp?
        private var commandTrace: [CommandTrace] = []
        private var traceDropped = 0, traceSaturated = false
        private(set) var intercepted = false, overflow = false
        private(set) var nativeCallbacks = 0, forwarded = 0, rejectedCommands = 0
        private(set) var nativeFinished: Bool?
        private(set) var targetSeconds: Double?
        var isHolding: Bool { intercepted && nativeFinished == true && callback != nil && !released }
        var cleanupAcknowledged: Bool {
            !intercepted || (nativeCallbacks == 1 && forwarded == 1 && callback == nil
                && !overflow && terminalEvents == 1 && deliveryObserved)
        }
        init(minimumTarget: Double, maximumTarget: Double) {
            self.minimumTarget = minimumTarget; self.maximumTarget = maximumTarget
            commandTrace.reserveCapacity(8)
        }
        func arm(player: AVPlayer, request: Int, generation: Int, aToken: Int, visit: Int64) {
            expectedPlayer = ObjectIdentifier(player)
            ownerBinding = OwnerBinding(request: request, generation: generation, aToken: aToken, visit: visit)
            armed = true
        }
        func recordIssued(_ stamp: PlaybackService.DebugVideoSeekStamp) { issueForNextCommand = stamp }
        // Shared by issuedCount and interception, before the real native seek.
        // The existing 80 ms position allowance binds the actual source-visit target.
        func matchesIssued(_ stamp: PlaybackService.DebugVideoSeekStamp) -> Bool {
            guard armed, let ownerBinding, stamp.force, stamp.reason == .sourceVisit,
                  stamp.request == ownerBinding.request, stamp.generation == ownerBinding.generation,
                  stamp.cachedAudioToken == ownerBinding.aToken, stamp.cachedAudioVisit == ownerBinding.visit,
                  stamp.requestedPosition.isFinite,
                  abs(stamp.requestedPosition - minimumTarget) <= 0.080,
                  stamp.requestedPosition < maximumTarget else { return false }
            let quantized = CMTime(seconds: stamp.requestedPosition, preferredTimescale: 48_000)
            return quantized.isNumeric && quantized.timescale == 48_000
                && abs(quantized.seconds - minimumTarget) <= 0.080 && quantized.seconds < maximumTarget
        }
        func seek(_ player: AVPlayer, _ time: CMTime, _ completion: @escaping @Sendable (Bool) -> Void) {
            let issued = issueForNextCommand
            let quantized = issued.map { CMTime(seconds: $0.requestedPosition, preferredTimescale: 48_000) }
            let eligible = armed && !intercepted && expectedPlayer == ObjectIdentifier(player)
                && issued.map { matchesIssued($0) } == true && time.isNumeric
                && time.timescale == 48_000 && quantized?.isNumeric == true
                && time.value == quantized?.value && time.epoch == quantized?.epoch
            let target = time.isNumeric ? time.seconds : nil
            if commandTrace.count < 8 {
                commandTrace.append(CommandTrace(issued: issueForNextCommand, target: target,
                    playerMatches: expectedPlayer == ObjectIdentifier(player), numeric: time.isNumeric,
                    lowerBoundMatches: target.map { $0 >= minimumTarget } ?? false,
                    upperBoundMatches: target.map { $0 < maximumTarget } ?? false,
                    armed: armed, intercepted: intercepted, eligible: eligible))
            } else if traceDropped < Int.max { traceDropped += 1 }
            else { traceSaturated = true }
            issueForNextCommand = nil
            if armed, !intercepted, !eligible {
                if rejectedCommands < 8 { rejectedCommands += 1 } else { overflow = true }
            }
            if eligible { intercepted = true; interceptedStamp = issued; targetSeconds = time.seconds }
            // Identical real SDK seek/tolerances to the default injection. There
            // is no synthetic completion, reader gate, second item or player.
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard eligible else { completion(finished); return }
                Task { @MainActor [weak self] in
                    guard let self else { completion(finished); return }
                    guard self.nativeCallbacks == 0 else { self.overflow = true; completion(finished); return }
                    self.nativeCallbacks = 1; self.nativeFinished = finished
                    if self.released { self.forwarded = 1; completion(finished) }
                    else { self.callback = completion }
                }
            }
        }
        func release() {
            released = true
            guard let callback, let nativeFinished else { return }
            self.callback = nil
            if forwarded == 0 { forwarded = 1 } else { overflow = true }
            callback(nativeFinished)
        }
        func recordTerminal(_ terminal: PlaybackService.DebugVideoSeekCompletionTerminal) {
            guard let interceptedStamp, terminal.request == interceptedStamp.request,
                  terminal.nativeSeekTicket == interceptedStamp.nativeSeekTicket else { return }
            if terminalEvents < 2 { terminalEvents += 1 } else { overflow = true }
            if terminalEvents != 1 { overflow = true }
            deliveryObserved = terminalEvents == 1 && nativeCallbacks == 1
                && forwarded == 1 && callback == nil && !overflow
        }
        // Dump only after owned cleanup, including when the original setup throws.
        // This is command metadata, not an additional SDK position/ownership read.
        func dumpCommandTrace() {
            print("NaturalSeekCompletionInjectionCoverage schema=1 retained=\(commandTrace.count) capacity=8 dropped=\(traceDropped) saturated=\(traceSaturated) minimumTarget=\(minimumTarget) maximumTarget=\(maximumTarget) targetAllowanceSeconds=0.080 interceptedRequest=\(interceptedStamp.map { String($0.request) } ?? "missing") interceptedNativeSeekTicket=\(interceptedStamp.map { String($0.nativeSeekTicket) } ?? "missing") terminalEvents=\(terminalEvents) deliveryObserved=\(deliveryObserved) callbackPending=\(callback != nil) deliveryScope=real-service-task-return interventionOwner=forced-source-visit playbackGuards=unchanged playbackAcceptance=false")
            for (index, command) in commandTrace.enumerated() {
                let issue = command.issued
                print("NaturalSeekCompletionInjection schema=1 index=\(index) issuePresent=\(issue != nil) issueReason=\(issue?.reason.rawValue ?? -1) issueRequest=\(issue?.request ?? -1) issueGeneration=\(issue?.generation ?? -1) issueSeekTicket=\(issue.map { String($0.nativeSeekTicket) } ?? "missing") issueTarget=\(issue.map { String($0.requestedPosition) } ?? "missing") issueForce=\(issue.map { String($0.force) } ?? "missing") issueCachedToken=\(issue.map { String($0.cachedAudioToken) } ?? "missing") issueCachedVisit=\(issue.map { String($0.cachedAudioVisit) } ?? "missing") nativeTarget=\(command.target.map { String($0) } ?? "missing") playerMatches=\(command.playerMatches) numeric=\(command.numeric) lowerBoundMatches=\(command.lowerBoundMatches) upperBoundMatches=\(command.upperBoundMatches) armed=\(command.armed) alreadyIntercepted=\(command.intercepted) eligible=\(command.eligible) playbackAcceptance=false")
            }
        }
    }
    #endif

    func testForegroundDoesNotSeekStaleVideoOwnerBeforeNaturalVisitAdoption() async throws {
        try recordRuntimeHost()
        #if DEBUG
        try await runForegroundVisitOwnershipControl(repeatOne: false)
        #else
        XCTFail("Forced foreground ownership controls require DEBUG hooks")
        #endif
    }

    func testForegroundCorrectsSameTokenLoopBeforeVisitAdoption() async throws {
        try recordRuntimeHost()
        #if DEBUG
        try await runForegroundVisitOwnershipControl(repeatOne: true)
        #else
        XCTFail("Forced foreground ownership controls require DEBUG hooks")
        #endif
    }

    #if DEBUG
    private func runForegroundVisitOwnershipControl(repeatOne: Bool) async throws {
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer, recordHost: false) { fixture, audio, service, screen in
            // Natural PCM succession must remain enabled; feed interaction would disable it.
            service.isInteractingWithFeed = false
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await require({ self.explicitInitialReadySourceSettled(service, screen: screen)
                && service.preparedAudioCount == 2 && buffer.hasPrepared(fixture.bID) },
                "Real A readiness and both complete Saved PCM sources must precede the foreground control")
            assertSelection(service, fixture: fixture, id: fixture.aID)
            let itemA = try XCTUnwrap(service.player.currentItem)
            let aToken = try XCTUnwrap(audio.entry(for: fixture.aID)?.token)
            XCTAssertGreaterThan(aToken, 0)
            if repeatOne {
                service.cycleRepeat(); service.cycleRepeat()
                XCTAssertEqual(service.queue.repeatMode, .one)
                try await require({ buffer.hasPrepared(fixture.aID) && service.preparedAudioCount == 2
                    && self.explicitInitialReadySourceSettled(service, screen: screen) },
                    "Repeat-one must prepare its real same-source successor before crossing the boundary")
            } else {
                XCTAssertEqual(service.queue.repeatMode, .off)
            }
            let incomingID = repeatOne ? fixture.aID : fixture.bID
            let incomingToken = try XCTUnwrap(audio.entry(for: incomingID)?.token)
            XCTAssertGreaterThan(incomingToken, 0)
            if repeatOne { XCTAssertEqual(incomingToken, aToken) }
            else { XCTAssertNotEqual(incomingToken, aToken) }
            let request = service.debugInitialVideoReadyState.generation
            let beforeSeek = service.audioSnapshot
            XCTAssertEqual(beforeSeek.token, aToken)
            XCTAssertFalse(audio.isSelectionPending(in: beforeSeek))
            guard beforeSeek.visit <= Int64.max - 2 else {
                XCTFail("The real renderer visit must leave room for one explicit seek and one natural boundary")
                throw SelectionVideoTestFailure.timeout
            }
            let minimumNaturalVisit = beforeSeek.visit + 2
            let originalSources = (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }
            let originalBytes = audio.renderer.retainedPCMMemoryBytes
            var holdAdoption = true, gateTimedOut = false, gateOverflow = false
            var blockedAttempts = 0
            var gateDeadline: Double?
            var foregroundSeeks: [PlaybackService.DebugVideoSeekStamp] = []
            foregroundSeeks.reserveCapacity(8)
            var droppedForegroundSeeks = 0
            service.shouldDebugDeferAudioVisit = { generation in
                guard holdAdoption, generation == request else { return false }
                let sample = service.audioSnapshot
                // Let the explicit far-seek acknowledgement proceed. Only the subsequent
                // real natural boundary is held, including repeat-one's unchanged token.
                guard sample.token == incomingToken, sample.visit >= minimumNaturalVisit,
                      sample.selectionVersion > beforeSeek.selectionVersion,
                      !audio.isSelectionPending(in: sample) else { return false }
                let now = ProcessInfo.processInfo.systemUptime
                if gateDeadline == nil { gateDeadline = now + 3 }
                guard now < (gateDeadline ?? now) else { gateTimedOut = true; return false }
                guard blockedAttempts < 128 else { gateOverflow = true; return false }
                blockedAttempts += 1
                return true
            }
            defer {
                // Release before the unchanged owned preparation/decoder acknowledgement helper.
                holdAdoption = false
                service.shouldDebugDeferAudioVisit = nil
                service.onDebugVideoSeekStamp = nil
            }

            // This is the existing natural control's cold far-seek setup budget,
            // separate from every existing 250 ms prepared-selection acceptance limit.
            service.seek(SelectionVideoFixture.duration - 2)
            let heldBoundary = await waitUntil(timeout: 10) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return blockedAttempts > 0 && !gateTimedOut && !gateOverflow
                    && state.generation == request && state.readyGeneration == request
                    && state.syncingVideoGeneration == nil && state.audioVisit < sample.visit
                    && service.queue.currentID == fixture.aID && audio.selectedID == fixture.aID
                    && service.player.currentItem === itemA && itemA.status == .readyToPlay
                    && sample.token == incomingToken && sample.visit >= minimumNaturalVisit
                    && sample.selectionVersion > beforeSeek.selectionVersion && sample.frame > 2_400
                    && !sample.ended && !audio.isSelectionPending(in: sample) && !service.isLoading && !service.audioOnly
                    && service.wantsToPlay && service.audioEngineRunning
            }
            XCTAssertTrue(heldBoundary,
                "The real natural renderer visit must advance while ready A and its selected metadata remain unadopted")
            guard heldBoundary else { throw SelectionVideoTestFailure.timeout }
            let firstHeld = service.audioSnapshot
            let progressedWhileHeld = await waitUntil(timeout: 0.75) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return !gateTimedOut && !gateOverflow && state.generation == request
                    && state.readyGeneration == request && state.syncingVideoGeneration == nil
                    && state.audioVisit < sample.visit && sample.token == incomingToken
                    && sample.visit == firstHeld.visit && sample.selectionVersion == firstHeld.selectionVersion
                    && sample.frame >= firstHeld.frame + 9_600 && !sample.ended
                    && !audio.isSelectionPending(in: sample)
            }
            XCTAssertTrue(progressedWhileHeld, "Real PCM must continue for 200 ms while visit adoption alone is held")
            let held = service.audioSnapshot
            let heldState = service.debugInitialVideoReadyState
            let qualified = progressedWhileHeld && !gateTimedOut && !gateOverflow
                && heldState.generation == request && heldState.readyGeneration == request
                && heldState.syncingVideoGeneration == nil && heldState.audioVisit < held.visit
                && service.queue.currentID == fixture.aID && audio.selectedID == fixture.aID
                && service.player.currentItem === itemA && itemA.status == .readyToPlay
                && held.token == incomingToken && held.visit == firstHeld.visit
                && held.selectionVersion == firstHeld.selectionVersion && !held.ended
                && !audio.isSelectionPending(in: held) && !service.isLoading && !service.audioOnly
                && service.wantsToPlay && service.audioEngineRunning
            XCTAssertTrue(qualified, "The exact real owner mismatch or same-token loop must still qualify immediately before foreground")
            XCTAssertEqual(held.underrunFrames, firstHeld.underrunFrames)
            guard qualified else { throw SelectionVideoTestFailure.timeout }
            assertSelection(service, fixture: fixture, id: fixture.aID)
            service.onDebugVideoSeekStamp = { stamp in
                guard stamp.reason == .foreground else { return }
                if foregroundSeeks.count < 8 { foregroundSeeks.append(stamp) }
                else { droppedForegroundSeeks += 1 }
            }
            let foregroundEntry = ProcessInfo.processInfo.systemUptime
            service.enteredForeground()
            let foregroundReturn = ProcessInfo.processInfo.systemUptime
            service.onDebugVideoSeekStamp = nil
            let afterForeground = service.audioSnapshot
            let submitted = service.submittedVideoFrameCount
            holdAdoption = false
            service.shouldDebugDeferAudioVisit = nil
            let returnedWithinHold = gateDeadline.map { foregroundReturn < $0 } ?? false
            print("ForegroundVisitOwnershipDecision schema=1 repeatOne=\(repeatOne) request=\(request) qualified=\(qualified) selectedToken=\(aToken) renderedToken=\(held.token) renderedVisit=\(held.visit) renderedFrame=\(held.frame) selectionVersion=\(held.selectionVersion) cachedVisit=\(heldState.audioVisit) readyGeneration=\(heldState.readyGeneration.map { String($0) } ?? "missing") syncingGeneration=\(heldState.syncingVideoGeneration.map { String($0) } ?? "missing") blockedAttempts=\(blockedAttempts) foregroundSeeks=\(foregroundSeeks.count) targets=\(foregroundSeeks.map { String($0.requestedPosition) }.joined(separator: ",")) foregroundCallSeconds=\(foregroundReturn - foregroundEntry) returnedWithinHold=\(returnedWithinHold) latencyAcceptance=false heldAdoption=diagnostic-only")
            XCTAssertTrue(returnedWithinHold, "The foreground observation must finish inside the bounded adoption hold")
            XCTAssertEqual(afterForeground.token, held.token); XCTAssertEqual(afterForeground.visit, held.visit)
            XCTAssertEqual(afterForeground.selectionVersion, held.selectionVersion)
            XCTAssertGreaterThanOrEqual(afterForeground.frame, held.frame); XCTAssertFalse(afterForeground.ended)
            XCTAssertEqual(afterForeground.underrunFrames, held.underrunFrames)
            XCTAssertEqual(foregroundSeeks.count, repeatOne ? 1 : 0,
                repeatOne ? "A selected same-token natural loop must retain its legitimate forced correction"
                          : "Foreground must not seek stale A using the already-rendered B position")
            XCTAssertEqual(droppedForegroundSeeks, 0)
            for stamp in foregroundSeeks {
                XCTAssertEqual(stamp.request, request); XCTAssertEqual(stamp.generation, request)
                XCTAssertTrue(stamp.force); XCTAssertTrue(stamp.observedItemMatches)
                XCTAssertTrue(stamp.selectedMatchesQueue); XCTAssertTrue(stamp.presentationRequestMatches)
                XCTAssertNil(stamp.ordinaryDriftVideoPositionSeconds)
                XCTAssertNil(stamp.ordinaryDriftReadEntryNs); XCTAssertNil(stamp.ordinaryDriftReadReturnNs)
                XCTAssertTrue(stamp.requestedPosition.isFinite)
                XCTAssertGreaterThanOrEqual(stamp.requestedPosition, 0)
                XCTAssertLessThan(stamp.requestedPosition, SelectionVideoFixture.duration)
            }
            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                guard let frame = service.videoFramePositionSeconds,
                      let copied = service.copiedVideoFramePositionSeconds else { return false }
                guard service.queue.currentID == incomingID && audio.selectedID == incomingID
                    && state.readyGeneration == state.generation && state.syncingVideoGeneration == nil
                    && state.audioVisit == held.visit && sample.token == incomingToken && sample.visit == held.visit
                    && sample.frame >= held.frame + 2_400 && !sample.ended && !audio.isSelectionPending(in: sample)
                    && service.submittedVideoFrameCount > submitted && service.isVideoReady && !service.isLoading
                    && screen.customVideoLayer?.isReadyForDisplay == true
                    && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                    && abs(frame - service.videoRequestedPositionSeconds) <= 0.080 && abs(copied - frame) <= 0.080
                    else { return false }
                // Keep the native 80 ms guard, with a fresh renderer goal after
                // the one opaque native read. No SDK getter follows that goal.
                let nativePosition = service.player.currentTime().seconds
                let fresh = service.audioSnapshot
                return fresh.token == incomingToken && fresh.visit == held.visit
                    && fresh.selectionVersion == sample.selectionVersion && fresh.frame >= sample.frame
                    && fresh.underrunFrames == sample.underrunFrames && !fresh.ended
                    && nativePosition.isFinite
                    && abs(nativePosition - Double(fresh.frame) / 48_000) <= 0.080
            }, "Release must adopt the actual incoming source and reveal fresh aligned frames with continuing PCM")
            assertSelection(service, fixture: fixture, id: incomingID)
            await assertMovingVisibleVideo(service, screen: screen, identity: repeatOne ? .a : .b,
                label: repeatOne ? "foreground-same-token-loop-A" : "foreground-stale-A-adopted-B")
            let final = service.audioSnapshot
            XCTAssertEqual(final.token, incomingToken); XCTAssertEqual(final.visit, held.visit)
            XCTAssertGreaterThan(final.frame, held.frame); XCTAssertFalse(final.ended)
            XCTAssertEqual(final.underrunFrames, firstHeld.underrunFrames)
            XCTAssertTrue(service.wantsToPlay); XCTAssertTrue(service.audioEngineRunning)
            XCTAssertFalse(gateTimedOut); XCTAssertFalse(gateOverflow)
            XCTAssertGreaterThan(blockedAttempts, 0); XCTAssertLessThanOrEqual(blockedAttempts, 128)
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)
            XCTAssertLessThanOrEqual(service.preparedAudioCount, 3)
            XCTAssertEqual(originalBytes, 6_912_000)
            XCTAssertEqual(audio.renderer.retainedPCMMemoryBytes, originalBytes)
            XCTAssertEqual((0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }, originalSources)
            print("ForegroundVisitOwnershipControl schema=1 repeatOne=\(repeatOne) request=\(request) cachedVisit=\(heldState.audioVisit) renderedToken=\(held.token) renderedVisit=\(held.visit) selectionVersion=\(held.selectionVersion) blockedAttempts=\(blockedAttempts) gateTimedOut=\(gateTimedOut) gateOverflow=\(gateOverflow) foregroundSeeks=\(foregroundSeeks.count) droppedForegroundSeeks=\(droppedForegroundSeeks) foregroundCallSeconds=\(foregroundReturn - foregroundEntry) returnedWithinHold=\(returnedWithinHold) underrunDelta=\(final.underrunFrames - firstHeld.underrunFrames) latencyAcceptance=false heldAdoption=diagnostic-only")
        }
    }
    #endif


    func testNaturalBoundaryAtPositiveIncomingOffsetRevealsB() async throws {
        try await runNaturalBoundary(traceNativeLaneActivity: false)
    }

    func testNaturalBoundaryWithNativeLaneActivityRevealsB() async throws {
        try await runNaturalBoundary(traceNativeLaneActivity: true)
    }

    private func runNaturalBoundary(traceNativeLaneActivity: Bool) async throws {
        #if DEBUG
        var observations: [(probe: NaturalNativeRunwayProbe, reached: Bool)] = []
        if traceNativeLaneActivity { observations.reserveCapacity(2) }
        // Dump only after the existing owned cleanup has run. Stored endpoints,
        // not this later dump time, determine each phase's coverage.
        defer { for observation in observations { observation.probe.dumpAndAssert(reached: observation.reached) } }
        #endif
        try await withOwnedNaturalFixture(traceNativeLaneActivity: traceNativeLaneActivity) { fixture, audio, service, screen in
        #if DEBUG
        service.debugInitialLoadPhaseEnabled = traceNativeLaneActivity
        let preparationProbe = traceNativeLaneActivity
            ? NaturalNativeRunwayProbe(phase: "initial-preparation", minimumFailureSeconds: nil) : nil
        preparationProbe?.sample(audio: audio, service: service, renderer: service.audioSnapshot, force: true)
        #endif
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        // Same predicate and three-second deadline as the original require call.
        // This known failed guard must not throw through teardown before its state
        // can be captured. Unrelated thrown errors retain the existing rethrow path.
        let prepared = await waitUntil(timeout: 3) {
            let sample = service.audioSnapshot
            #if DEBUG
            preparationProbe?.sample(audio: audio, service: service, renderer: sample)
            #endif
            return sample.frame > 2_400 && service.preparedAudioCount == 2
        }
        #if DEBUG
        preparationProbe?.sample(audio: audio, service: service, renderer: service.audioSnapshot, force: true)
        if let preparationProbe { observations.append((preparationProbe, prepared)) }
        #endif
        guard prepared else {
            XCTFail("Both complete Saved sources must be ready")
            #if DEBUG
            await recordNaturalRunwayFailure(audio: audio,
                expectedToken: audio.entry(for: fixture.aID)?.token ?? 0, stage: "initial-preparation")
            #endif
            return
        }
        let aToken = service.audioSnapshot.token
        let seekPosition = SelectionVideoFixture.duration - 2
        #if DEBUG
        let nativeProbe = traceNativeLaneActivity
            ? NaturalNativeRunwayProbe(phase: "seek-runway", minimumFailureSeconds: 9.5) : nil
        nativeProbe?.sample(audio: audio, service: service, renderer: service.audioSnapshot, force: true)
        #endif
        service.seek(seekPosition)
        // A far seek rebuilds the decoder's original history. Observe real progress with
        // two seconds of runway instead of requiring the main actor to catch A's final
        // 250 ms. A completed natural transition is also valid if scheduling skipped A.
        // This is cold far-seek setup, not a prepared-transition latency limit.
        let reachedRunway = await waitUntil(timeout: 10) {
            let sample = service.audioSnapshot
            #if DEBUG
            nativeProbe?.sample(audio: audio, service: service, renderer: sample)
            #endif
            return sample.token == aToken && sample.frame >= Int64((seekPosition + 0.05) * 48_000)
                || sample.token != 0 && sample.token != aToken && sample.frame > 0
        }
        let sample = service.audioSnapshot
        print("SelectionBoundary phase=runway reached=\(reachedRunway) sourceA=\(sample.token == aToken) frame=\(sample.frame) visit=\(sample.visit) underrunFrames=\(sample.underrunFrames) engineRunning=\(service.audioEngineRunning) wantsToPlay=\(service.wantsToPlay) position=\(service.clock.position) duration=\(service.clock.duration)")
        #if DEBUG
        nativeProbe?.sample(audio: audio, service: service, renderer: sample, force: true)
        if let nativeProbe { observations.append((nativeProbe, reachedRunway)) }
        #endif
        guard reachedRunway else {
            // Keep this an assertion failure, with the original numeric evidence,
            // instead of throwing a setup error through deferred fixture cleanup.
            XCTFail("The real renderer must reach the seek runway or naturally enter B")
            #if DEBUG
            await recordNaturalRunwayFailure(audio: audio, expectedToken: aToken)
            #endif
            return
        }
        // The audio thread continues through the boundary while the main actor is briefly busy.
        // This deterministically exercises an arriving frame offset greater than zero.
        if sample.token == aToken {
            let remaining = max(0, SelectionVideoFixture.duration - Double(sample.frame) / 48_000)
            stallMainActorForBoundary(seconds: min(2.2, remaining + 0.2))
        }
        try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token != 0
            && service.audioSnapshot.token != aToken
            && service.clock.position > 0 }, "The service must adopt naturally rendered B at a positive offset")
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "natural-B-positive-offset")
        }
    }

    /// Cleanup runs on normal return and on a retained original error. File removal
    /// requires both existing acknowledgements; failure retains only this fixture.
    private func withOwnedNaturalFixture(traceNativeLaneActivity: Bool = false, buffer: PlaybackBuffer? = nil, recordHost: Bool = true,
        seekVideo: PlaybackService.SeekVideo? = nil,
        additionalCleanupAcknowledged: @MainActor () -> Bool = { @MainActor in true }, _ body: @MainActor (SelectionVideoFixture, ContinuousAudioPlayer,
        PlaybackService, SelectionVideoScreen) async throws -> Void) async throws {
        if recordHost { try recordRuntimeHost() }
        guard !Self.targetedFixtureOwnershipLost else {
            XCTFail("A previous targeted fixture did not acknowledge cleanup; no new owners may be created")
            throw SelectionVideoTestFailure.timeout
        }
        let fixture = try await SelectionVideoFixture()
        #if DEBUG
        let activity = traceNativeLaneActivity ? ContinuousPCMDecoder.DebugNativeLaneActivityRecorder() : nil
        let audio = ContinuousAudioPlayer(debugNativeLaneActivityRecorder: activity)
        #else
        let audio = ContinuousAudioPlayer()
        #endif
        let service = fixture.service(buffer: buffer, continuousAudio: audio, seekVideo: seekVideo)
        var screen: SelectionVideoScreen?
        var originalError: Error?
        #if DEBUG
        func recordBodyError(_ error: Error, boundary: String) {
            func boundedLabel(_ text: String) -> String {
                let bytes = text.utf8.prefix(192).map { byte in
                    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                        || byte == 46 || byte == 95 ? byte : 95
                }
                return String(bytes: bytes, encoding: .ascii) ?? "unavailable"
            }
            let isTimeout: Bool
            if let local = error as? SelectionVideoTestFailure, case .timeout = local { isTimeout = true }
            else { isTimeout = false }
            let native = error as NSError
            print("NaturalFixtureBodyError schema=1 boundary=\(boundary) intendedTimeout=\(isTimeout) concreteType=\(boundedLabel(String(reflecting: type(of: error)))) nsDomain=\(boundedLabel(native.domain)) nsCode=\(native.code) originalBinding=retained message=omitted userInfo=omitted playbackAcceptance=false")
        }
        #endif
        do {
            let created = try SelectionVideoScreen(service: service)
            screen = created
            try await body(fixture, audio, service, created)
        } catch {
            originalError = error
            #if DEBUG
            recordBodyError(error, boundary: "body-catch")
            #endif
        }
        service.pause(); audio.graph.engine.stop(); screen?.close()
        #if DEBUG
        let preparation = ProductionSelectionShutdown()
        let decoder = ProductionSelectionShutdown()
        service.debugStopPreparation { preparation.complete(true) }
        audio.debugShutdown { decoder.complete($0) }
        let returned = await waitUntil(timeout: 3) {
            preparation.result != nil && decoder.result != nil && additionalCleanupAcknowledged()
        }
        let canRemove = returned && preparation.result == true && decoder.result == true
            && additionalCleanupAcknowledged()
        print("NaturalFixtureCleanup schema=1 ownedTasksJoined=\(preparation.result == true) decoderClosed=\(decoder.result == true) removeAllowed=\(canRemove) originalErrorRetained=\(originalError != nil) syntheticFilesRetained=\(!canRemove) sdkInternalQuiescence=unverified olderCancelledTasks=unverified")
        XCTAssertTrue(canRemove, "Owned task and decoder close acknowledgements must precede synthetic file removal")
        if canRemove { fixture.remove() }
        else { Self.targetedFixtureOwnershipLost = true; fixture.restorePreferences() }
        #else
        fixture.remove()
        #endif
        if let originalError {
            #if DEBUG
            recordBodyError(originalError, boundary: "before-rethrow")
            #endif
            throw originalError
        }
    }

    #if DEBUG
    /// Independent main-actor observation, at most 128 records of three lane words.
    /// No sampler task, worker request, SDK query or decode-path clock is added.
    @MainActor private final class NaturalNativeRunwayProbe {
        struct Sample {
            let begin: UInt64
            let end: UInt64
            let renderer: ContinuousPCMRenderer.Snapshot
            let lanes: [ContinuousPCMDecoder.DebugNativeLaneActivitySnapshot?]
            let load: PlaybackService.DebugInitialLoadPhaseState
        }
        private let origin = DispatchTime.now().uptimeNanoseconds
        private let phase: String
        private let minimumFailureSeconds: Double?
        private var samples: [Sample] = []
        private var dropped = 0
        init(phase: String, minimumFailureSeconds: Double?) {
            self.phase = phase; self.minimumFailureSeconds = minimumFailureSeconds
            samples.reserveCapacity(128)
        }
        func sample(audio: ContinuousAudioPlayer, service: PlaybackService, renderer: ContinuousPCMRenderer.Snapshot, force: Bool = false) {
            let begin = DispatchTime.now().uptimeNanoseconds
            if !force, let last = samples.last, begin - last.begin < 100_000_000 { return }
            guard samples.count < 128 else { dropped += 1; return }
            let lanes = (0..<3).map { audio.debugNativeLaneActivitySnapshot(at: $0) }
            let load = service.debugInitialLoadPhaseState
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Sample(begin: begin, end: end, renderer: renderer, lanes: lanes, load: load))
        }
        func dumpAndAssert(reached: Bool) {
            let gaps = zip(samples, samples.dropFirst()).map { Double($1.begin - $0.begin) / 1_000_000_000 }
            let acquisition = samples.map { Double($0.end - $0.begin) / 1_000_000_000 }.max() ?? .infinity
            let first = samples.first.map { Double($0.begin - origin) / 1_000_000_000 } ?? .infinity
            let elapsed = samples.last.map { Double($0.end - origin) / 1_000_000_000 } ?? -1
            print("NaturalNativeActivityCoverage schema=1 phase=\(phase) reached=\(reached) samples=\(samples.count) capacity=128 lanes=3 dropped=\(dropped) firstMs=\(first * 1000) observedSeconds=\(elapsed) maximumGapMs=\((gaps.max() ?? 0) * 1000) maximumAcquisitionMs=\(acquisition * 1000) cadenceMs=100 rendererAndLanesCoherent=false hotClocks=false internalSDKCause=unestablished")
            XCTAssertGreaterThan(samples.count, 0); XCTAssertLessThanOrEqual(samples.count, 128)
            XCTAssertEqual(dropped, 0); XCTAssertLessThanOrEqual(first, 0.25)
            XCTAssertLessThanOrEqual(gaps.max() ?? 0, 0.25); XCTAssertLessThanOrEqual(acquisition, 0.005)
            if !reached, let minimumFailureSeconds { XCTAssertGreaterThanOrEqual(elapsed, minimumFailureSeconds) }
            for (ordinal, sample) in samples.enumerated() {
                XCTAssertEqual(sample.lanes.count, 3)
                print("NaturalNativeActivityRenderer schema=1 phase=\(phase) ordinal=\(ordinal) beginNs=\(sample.begin) endNs=\(sample.end) token=\(sample.renderer.token) visit=\(sample.renderer.visit) frame=\(sample.renderer.frame) underrunFrames=\(sample.renderer.underrunFrames) selectionVersion=\(sample.renderer.selectionVersion) coherence=renderer-only-before-lane-reads")
                print("NaturalInitialLoadPhase schema=1 phase=\(phase) ordinal=\(ordinal) enabled=\(sample.load.enabled) request=\(sample.load.request) generation=\(sample.load.generation) code=\(sample.load.phase.rawValue) current=\(sample.load.enabled && sample.load.request == sample.load.generation) coherence=main-actor-cached-after-independent-lane-reads sdkInternalCause=unestablished")
                for (index, lane) in sample.lanes.enumerated() {
                    XCTAssertNotNil(lane)
                    if let lane {
                        XCTAssertEqual(lane.laneIndex, index); XCTAssertFalse(lane.sequenceOverflowed)
                        print("NaturalNativeActivity schema=1 phase=\(phase) ordinal=\(ordinal) lane=\(lane.laneIndex) packedState=\(lane.packedState) copySequence=\(lane.copySequence) stage=\(lane.stageCode) overflowed=\(lane.sequenceOverflowed) coherence=one-packed-word")
                    }
                }
            }
        }
    }

    private func naturalFailureEndpoints(audio: ContinuousAudioPlayer, phase: String, expectedToken: Int) -> [String] {
        let sample = audio.snapshot
        let selection = audio.debugSelectionState
        var rows = ["NaturalFailureRenderer schema=1 phase=\(phase) expectedToken=\(expectedToken) token=\(sample.token) frame=\(sample.frame) visit=\(sample.visit) ended=\(sample.ended) underrunFrames=\(sample.underrunFrames) selectionVersion=\(sample.selectionVersion) selectedToken=\(selection.selectedToken) pendingVersion=\(selection.pendingVersion.map { String($0) } ?? "none") selectionPending=\(audio.isSelectionPending(in: sample))"]
        rows.reserveCapacity(4)
        for index in 0..<3 {
            let source = audio.renderer.source(at: index)
            let token = source.token
            let request = source.streamRequest
            let ready = source.availableStreamFrames(for: request.epoch)
            let writable = source.writableStreamFrames
            let after = source.streamRequest
            let tokenAfter = source.token
            rows.append("NaturalFailureSource schema=1 phase=\(phase) slot=\(index) token=\(token) tokenAfter=\(tokenAfter) epoch=\(request.epoch) startFrame=\(request.startFrame) epochAfter=\(after.epoch) startAfter=\(after.startFrame) requestStable=\(request == after && token == tokenAfter) readyFrames=\(ready) writableFrames=\(writable) totalFrames=\(source.totalFrames) prefixFrames=\(source.prefixFrameCount) coherence=individual-accessors")
        }
        return rows
    }

    private func recordNaturalRunwayFailure(audio: ContinuousAudioPlayer, expectedToken: Int, stage: String = "seek-runway") async {
        // Called only after the unchanged preparation or runway guard has failed.
        let before = naturalFailureEndpoints(audio: audio, phase: stage + "-before-worker", expectedToken: expectedToken)
        let mailbox = NaturalFailureStateMailbox()
        audio.debugDecoderFailureState { mailbox.complete($0) }
        let returned = await waitUntil(timeout: 1) { mailbox.result != nil }
        let state = mailbox.result
        let after = naturalFailureEndpoints(audio: audio, phase: stage + "-after-worker", expectedToken: expectedToken)
        for row in before { print(row) }
        print("NaturalFailureWorker schema=1 stage=\(stage) returnedWithinOneSecond=\(returned) snapshotAvailable=\(state != nil) nativePhaseAvailable=false sdkWaitEstablished=false")
        if let state {
            let stats = state.stats
            print("NaturalFailureWorkerStats schema=1 leased=\(stats.leasedReaders) peakLeased=\(stats.peakLeasedReaders) retired=\(stats.retiredLeasesAwaitingClose) starting=\(stats.startingLeases) preparations=\(stats.pendingPreparations) pendingReads=\(stats.readJobsAwaitingAcceptanceOrClose) packets=\(stats.mailboxPackets) occupiedPackets=\(stats.pendingOrMailboxPacketSlots) overflowed=\(stats.counterOverflowed) shutdown=\(stats.shutdownRequested) closed=\(stats.readerLeasesClosed) preparationTokens=\(state.preparationTokens.map { String($0) }.joined(separator: ",")) coherence=worker-owned-fields")
            for slot in state.slots {
                print("NaturalFailureSlot schema=1 slot=\(slot.index) token=\(slot.token) workerEpoch=\(slot.epoch) finished=\(slot.finished) cancelled=\(slot.cancelled) lease=\(slot.leaseIndex) hasStream=\(slot.stream != nil) coherence=worker-owned-fields")
                if let stream = slot.stream {
                    print("NaturalFailureStream schema=1 slot=\(slot.index) cursor=\(stream.cursor) generatedFrames=\(stream.generatedFrames) outputStart=\(stream.outputStart) outputCount=\(stream.outputCount) converterFinished=\(stream.converterFinished) eof=\(stream.reachedEnd) coherence=worker-owned-fields")
                }
            }
            for lease in state.leases {
                print("NaturalFailureLease schema=1 lane=\(lease.index) present=\(lease.present) starting=\(lease.starting) readPending=\(lease.readPending) retired=\(lease.retired) demandFrames=\(lease.requestedFrames) packetFrames=\(lease.packetFrames) packetOffset=\(lease.packetOffset) eof=\(lease.reachedEnd) hasFailure=\(lease.hasFailure) coherence=worker-owned-fields")
            }
        }
        for row in after { print(row) }
    }
    #endif

    func testRapidABASupersedesPendingVideoSeekAndPreservesExplicitPause() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await require({ service.audioSnapshot.frame > 2_400 && service.preparedAudioCount == 2 },
                          "Both Saved sources must be prepared before rapid supersession")
        await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "rapid-baseline-A")
        let aToken = service.audioSnapshot.token
        let priorSelectionVersion = service.audioSnapshot.selectionVersion
        // One main-actor turn: the paused seek has an outstanding native completion when
        // Next and Previous replace its generation. There is no wait for B readiness.
        service.pause()
        service.seek(0.8)
        service.next()
        service.previous()
        service.play()
        try await require({ service.queue.currentID == fixture.aID && service.audioSnapshot.token == aToken
            && service.audioSnapshot.selectionVersion >= priorSelectionVersion + 6
            && service.audioSnapshot.frame > 2_400 }, "The renderer must acknowledge the final A selection")
        print("SelectionRapid beforeVersion=\(priorSelectionVersion) finalVersion=\(service.audioSnapshot.selectionVersion) frame=\(service.audioSnapshot.frame)")
        assertSelection(service, fixture: fixture, id: fixture.aID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "rapid-final-A")
        service.seek(0.35)
        service.pause()
        try await require({ !service.audioEngineRunning }, "Explicit Pause must stop the newest selection")
        let paused = service.audioSnapshot
        try await Task.sleep(for: .milliseconds(250))
        assertSelection(service, fixture: fixture, id: fixture.aID)
        XCTAssertFalse(service.wantsToPlay, "Late video completions must not undo explicit Pause")
        XCTAssertEqual(service.audioSnapshot.token, paused.token)
        XCTAssertEqual(service.audioSnapshot.frame, paused.frame)
        XCTAssertEqual(service.player.rate, 0)
    }

    func testAudioOnlyAndForegroundRestoreSelectedBWithoutOverridingPause() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.bID)
        try await require({ service.audioSnapshot.frame > 2_400 }, "B must be rendered before hiding video")
        let bToken = service.audioSnapshot.token
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "B-before-audio-only")
        service.audioOnly = true
        XCTAssertTrue(service.surface.isHidden)
        let before = service.audioSnapshot.frame
        try await require({ service.audioSnapshot.frame > before + 2_400 }, "Audio only must leave B audio advancing")
        service.pause()
        try await require({ !service.audioEngineRunning }, "Explicit Pause must stop the actual audio engine")
        let pausedFrame = service.audioSnapshot.frame
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        service.enteredForeground()
        service.audioOnly = false
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertVisibleFrame(service, screen: screen, identity: .b, label: "paused-B-restored-inline")
        XCTAssertFalse(service.surface.isHidden)
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.audioSnapshot.token, bToken)
        XCTAssertEqual(service.audioSnapshot.frame, pausedFrame)
        XCTAssertEqual(service.player.rate, 0)
    }

    private func stallMainActorForBoundary(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    private func logCustomFrame(_ service: PlaybackService, screen: SelectionVideoScreen, label: String) {
        print("SelectionCustomFrame label=\(label) submitted=\(service.submittedVideoFrameCount) pts=\(service.videoFramePositionSeconds.map { String($0) } ?? "missing") copiedPTS=\(service.copiedVideoFramePositionSeconds.map { String($0) } ?? "missing") futureRejected=\(service.pausedFutureVideoFrameRejectionCount) requested=\(service.videoRequestedPositionSeconds) timebase=\(service.videoTimebasePositionSeconds.map { String($0) } ?? "missing") customReady=\(screen.customVideoLayer?.isReadyForDisplay == true) playerPosition=\(service.player.currentTime().seconds) clockPosition=\(service.clock.position)")
    }

    private func assertPausedCustomFrame(_ service: PlaybackService, screen: SelectionVideoScreen,
                                         requested: Double, after count: UInt64, label: String,
                                         file: StaticString = #filePath, line: UInt = #line) async {
        let epsilon = 0.000_001
        let settled = await waitUntil {
            guard let pts = service.videoFramePositionSeconds, pts.isFinite else { return false }
            return service.submittedVideoFrameCount > count && screen.customVideoLayer?.isReadyForDisplay == true
                && abs(service.videoRequestedPositionSeconds - requested) <= epsilon
                && pts <= requested + epsilon && requested - pts <= 1.0 / 24.0 + epsilon
        }
        XCTAssertTrue(settled, "The custom display must submit a fresh frame for the settled paused seek", file: file, line: line)
        assertPausedCustomFrameState(service, screen: screen, requested: requested, after: count,
                                     label: label, file: file, line: line)
    }

    private func assertPausedCustomFrameState(_ service: PlaybackService, screen: SelectionVideoScreen,
                                              requested: Double, after count: UInt64, label: String,
                                              file: StaticString = #filePath, line: UInt = #line) {
        logCustomFrame(service, screen: screen, label: label)
        XCTAssertGreaterThan(service.submittedVideoFrameCount, count,
                             "Underlying AVPlayerLayer pixels cannot replace custom-frame submission", file: file, line: line)
        XCTAssertTrue(screen.customVideoLayer?.isReadyForDisplay == true,
                      "The fresh custom frame must remain visible after compositor capture", file: file, line: line)
        let epsilon = 0.000_001
        XCTAssertEqual(service.videoRequestedPositionSeconds, requested, accuracy: epsilon, file: file, line: line)
        guard let pts = service.videoFramePositionSeconds, pts.isFinite else {
            XCTFail("The custom display must expose a finite submitted frame PTS", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(pts, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(pts, requested + epsilon,
                                 "A paused display must not show a future video frame", file: file, line: line)
        XCTAssertLessThanOrEqual(requested - pts, 1.0 / 24.0 + epsilon,
                                 "The 24 fps fixture must settle within one frame before the requested position", file: file, line: line)
    }

    private func assertSelection(_ service: PlaybackService, fixture: SelectionVideoFixture, id: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(service.queue.currentID, id, file: file, line: line)
        XCTAssertEqual(service.current?.id, id, file: file, line: line)
        let asset = service.player.currentItem?.asset as? AVURLAsset
        XCTAssertEqual(asset?.url.standardizedFileURL, fixture.savedURLs[id]?.standardizedFileURL,
                       "The selected metadata must identify the actual AVPlayerItem asset", file: file, line: line)
        XCTAssertTrue(service.surface.playerLayer.player === service.player, file: file, line: line)
    }

    @discardableResult
    private func assertVisibleFrame(_ service: PlaybackService, screen: SelectionVideoScreen,
                                    identity: SelectionVideoIdentity, label: String,
                                    file: StaticString = #filePath, line: UInt = #line) async -> SelectionVideoPixels? {
        let ready = await waitUntil {
            service.isVideoReady && (service.surface.playerLayer.isReadyForDisplay
                || screen.customVideoLayer?.isReadyForDisplay == true)
        }
        XCTAssertTrue(ready, "The selected real video must become ready; an audio clock is insufficient", file: file, line: line)
        do {
            let pixels = try await screen.capture(label: label, test: self)
            pixels.log(label: label, identity: identity)
            XCTAssertGreaterThan(pixels.fraction(identity), 0.65,
                                 "The whole composite must show \(identity), not the opaque poster or another source", file: file, line: line)
            XCTAssertLessThan(pixels.magentaFraction, 0.02,
                              "The real readiness path must uncover video instead of leaving the poster opaque", file: file, line: line)
            return pixels
        } catch {
            XCTFail("Composite capture failed: \(error)", file: file, line: line)
            return nil
        }
    }

    private func assertMovingVisibleVideo(_ service: PlaybackService, screen: SelectionVideoScreen,
                                          identity: SelectionVideoIdentity, label: String,
                                          file: StaticString = #filePath, line: UInt = #line) async {
        guard let first = await assertVisibleFrame(service, screen: screen, identity: identity,
                                                  label: label + "-motion-start", file: file, line: line) else { return }
        do {
            let firstBar = try XCTUnwrap(first.blueBarCenter, "The first composite must contain its decoded blue marker", file: file, line: line)
            let firstBarY = try XCTUnwrap(first.blueBarCenterY, "The first composite must locate the blue marker vertically", file: file, line: line)
            let firstSubmitted = service.submittedVideoFrameCount
            XCTAssertGreaterThan(firstSubmitted, 0, "The first image must have a submitted custom frame", file: file, line: line)
            let firstReady = service.isVideoReady && screen.customVideoLayer?.isReadyForDisplay == true
            XCTAssertTrue(firstReady, "The first composite must have a ready custom video frame", file: file, line: line)
            guard first.fraction(identity) > 0.65, first.magentaFraction < 0.02,
                  firstSubmitted > 0, firstReady else { return }
            var visibleDelta = 0.0
            var states = [first.captureBefore, first.captureAfter]
            guard assertMotionCaptureWindow(states, label: label, file: file, line: line) else { return }
            // The two-dimensional marker is unique throughout the 30-second fixture.
            // Every observation must fit a shorter real-time and media-time window.
            for observation in 2...3 {
                let previousTime = service.player.currentTime().seconds
                let previousAudio = service.audioSnapshot
                _ = await waitUntil(timeout: 1) {
                    let audio = service.audioSnapshot
                    return service.player.currentTime().seconds > previousTime + 0.18
                        && audio.token == previousAudio.token && audio.visit == previousAudio.visit
                        && audio.frame >= previousAudio.frame + 8_640
                }
                let currentAudio = service.audioSnapshot
                let sameWindowSource = previousAudio.token == first.captureBefore.audioToken
                    && previousAudio.visit == first.captureBefore.audioVisit
                let audioAdvanced = sameWindowSource && currentAudio.token == previousAudio.token && currentAudio.visit == previousAudio.visit
                    && currentAudio.frame >= previousAudio.frame + 8_640
                let noUnderrun = currentAudio.underrunFrames == previousAudio.underrunFrames
                    && previousAudio.underrunFrames == first.captureBefore.audioUnderrunFrames
                print("SelectionMotionInterval label=\(label) observation=\(observation) audioDelta=\(currentAudio.frame - previousAudio.frame) underrunDelta=\(currentAudio.underrunFrames - previousAudio.underrunFrames) sameToken=\(currentAudio.token == previousAudio.token) sameVisit=\(currentAudio.visit == previousAudio.visit)")
                guard audioAdvanced, noUnderrun else {
                    XCTFail("audioClockHold/underruns: PCM must advance at least 8640 frames in the same visit without new underruns", file: file, line: line)
                    return
                }
                let videoAdvanced = service.player.currentTime().seconds > previousTime + 0.18
                XCTAssertTrue(videoAdvanced, "The selected AVPlayerItem clock must actually advance for each observation", file: file, line: line)
                guard videoAdvanced else { return }
                let captureLabel = label + "-motion-observation-\(observation)"
                let next = try await screen.capture(label: captureLabel, test: self)
                next.log(label: captureLabel, identity: identity)
                states += [next.captureBefore, next.captureAfter]
                guard assertMotionCaptureWindow(states, label: label, file: file, line: line) else { return }
                XCTAssertGreaterThan(next.fraction(identity), 0.65, file: file, line: line)
                XCTAssertLessThan(next.magentaFraction, 0.02, file: file, line: line)
                let ready = service.isVideoReady && screen.customVideoLayer?.isReadyForDisplay == true
                XCTAssertTrue(ready, "The actual custom video must remain ready during motion proof", file: file, line: line)
                let nextBar = try XCTUnwrap(next.blueBarCenter, "Every composite must contain its decoded blue marker", file: file, line: line)
                let nextBarY = try XCTUnwrap(next.blueBarCenterY, "Every composite must locate the blue marker vertically", file: file, line: line)
                guard next.fraction(identity) > 0.65, next.magentaFraction < 0.02, ready else { return }
                visibleDelta = hypot(nextBar - firstBar, nextBarY - firstBarY)
                print("SelectionMotion label=\(label) observation=\(observation) deltaPixels=\(visibleDelta)")
                if visibleDelta > 3 { break }
            }
            XCTAssertGreaterThan(visibleDelta, 3,
                                 "Advancing clocks must produce different visible video frames", file: file, line: line)
            let customAdvanced = await waitUntil(timeout: 1) {
                service.submittedVideoFrameCount > firstSubmitted && screen.customVideoLayer?.isReadyForDisplay == true
            }
            XCTAssertTrue(customAdvanced, "Motion proof requires new custom-frame submission beyond the first capture", file: file, line: line)
        } catch { XCTFail("Moving-frame proof failed: \(error)", file: file, line: line) }
    }

    private func assertMotionCaptureWindow(_ states: [SelectionVideoCaptureState], label: String,
                                            file: StaticString, line: UInt) -> Bool {
        guard let first = states.first, let last = states.last else { return false }
        let wall = last.uptime - first.uptime
        let positions = states.map(\.playerPosition)
        let media = (positions.max() ?? .infinity) - (positions.min() ?? -.infinity)
        let pcm = Double(last.audioFrame - first.audioFrame) / 48_000
        let validPositions = positions.allSatisfy { $0.isFinite && $0 >= 0 }
        let stableSource = first.audioToken != 0 && states.allSatisfy {
            $0.audioToken == first.audioToken && $0.audioVisit == first.audioVisit
        }
        let monotonicPCM = zip(states, states.dropFirst()).allSatisfy { pair in pair.0.audioFrame <= pair.1.audioFrame }
        let noUnderruns = states.allSatisfy { $0.audioUnderrunFrames == first.audioUnderrunFrames }
        print("SelectionMotionWindow label=\(label) captures=\(states.count / 2) wallSeconds=\(wall) mediaSeconds=\(media) pcmSeconds=\(pcm) stableSource=\(stableSource) monotonicPCM=\(monotonicPCM) noUnderruns=\(noUnderruns)")
        XCTAssertGreaterThanOrEqual(wall, 0, file: file, line: line)
        XCTAssertLessThan(wall, 29, "The capture window must fit inside the fixture's nonrepeating 30-second presentation", file: file, line: line)
        XCTAssertTrue(validPositions, "Capture media-time brackets must be finite and nonnegative", file: file, line: line)
        XCTAssertLessThan(media, 29, "The bracketed media window must exclude a full presentation or loop", file: file, line: line)
        XCTAssertGreaterThanOrEqual(pcm, 0, file: file, line: line)
        XCTAssertLessThan(pcm, 29, file: file, line: line)
        XCTAssertTrue(stableSource && monotonicPCM, "No PCM token, visit or loop change may cross the capture window", file: file, line: line)
        XCTAssertTrue(noUnderruns, "audioClockHold/underruns: capture acquisition must not conceal a new PCM underrun", file: file, line: line)
        return wall >= 0 && wall < 29 && validPositions && media < 29 && pcm >= 0 && pcm < 29
            && stableSource && monotonicPCM && noUnderruns
    }

    private func require(_ condition: () -> Bool, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        guard await waitUntil(condition) else {
            XCTFail(message, file: file, line: line)
            throw SelectionVideoTestFailure.timeout
        }
    }

    func testWaitUntilLatchesSuccessAndPreservesDeadlineAndCancellation() async {
        var successCalls = 0
        let succeeded = await waitUntil(timeout: 0.25) {
            successCalls += 1
            return successCalls == 2 // Script: false, true, false.
        }
        XCTAssertTrue(succeeded, "A valid sample must latch without another predicate/SDK evaluation")
        XCTAssertEqual(successCalls, 2)

        for wouldBecomeTrue in [false, true] {
            var deadlineCalls = 0
            let expired = await waitUntil(timeout: 0) {
                deadlineCalls += 1
                return wouldBecomeTrue && deadlineCalls > 1
            }
            XCTAssertFalse(expired, "A false sample at the deadline is final, even if a second call would pass")
            XCTAssertEqual(deadlineCalls, 1)
        }

        let cancelled = await Task { @MainActor in
            var calls = 0
            let result = await self.waitUntil(timeout: 1) {
                calls += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            }
            return (result, calls)
        }.value
        XCTAssertFalse(cancelled.0, "Cancellation of the poll sleep must return false")
        XCTAssertEqual(cancelled.1, 1, "Cancellation must not cause a second predicate/SDK evaluation")
    }

    private func waitUntil(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if condition() { return true }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
    }
}

/// Both benchmarks retain three predicate summaries; only the existing traced
/// benchmark receives up to 32 default-off DEBUG service stamps. Main actor only.
@MainActor
private final class ProductionVideoStartupTrace {
    struct Poll { let uptime: Double; let readyLatched: Bool; let mask: UInt16; let evaluated: UInt16 }
    let serviceTracing: Bool
    var phase = 0
    private var layerReady: Bool?
    private var lastPolls = [Poll?](repeating: nil, count: 3)
    private var finalMasks = [UInt16?](repeating: nil, count: 3)
    private var badPhase = false
    #if DEBUG
    var remainingLatencyWitness: RemainingLatencyWitness?
    weak var availabilityClockTrace: NativeClockHandoffTrace?
    func recordRemainingLatencyPoll(entryNs: UInt64?, state: ProductionSelectionState, service: PlaybackService) {
        guard let remainingLatencyWitness, let entryNs, lastPolls.indices.contains(phase),
              let poll = lastPolls[phase] else { return }
        let owner = service.debugAlignedVideoPollState // Cached fields only; no SDK getter.
        remainingLatencyWitness.recordPoll(phase: phase, entryNs: entryNs,
            observedNs: DispatchTime.now().uptimeNanoseconds, mask: poll.mask, evaluated: poll.evaluated,
            state: state, owner: owner)
    }
    var pollSummary: ProductionSelectionPollSummary?
    var didEvaluateLayerReady: Bool { layerReady != nil } // Cached optional-chain predicate result; no second SDK getter.
    private enum Event {
        case startup(Int, PlaybackService.DebugVideoStartupStamp)
        case seek(Int, UInt64, PlaybackService.DebugVideoSeekStamp)
    }
    private var events: [Event] = []
    private var dropped = 0, overflow = false
    // Three phases x three seek regions x nine first-only scalar stages. No item/image ownership.
    private var renderSlots: [PlaybackService.DebugVideoRenderStamp?] = []
    private var renderConflicts = 0, renderOwnershipFailures = 0
    private final class EarlyPullPhase {
        var anchorNs: UInt64?
        var rows: [PlaybackService.DebugCPPNativePullStamp] = []
        var outsideWindow: UInt64 = 0, capacityDropped: UInt64 = 0, qualityFailures: UInt64 = 0
        init() { rows.reserveCapacity(256) }
    }
    private var earlyPullBaseRequest: Int?
    private var earlyPullPhases: [EarlyPullPhase] = []
    private var earlyPullOrphans: UInt64 = 0, earlyPullCounterOverflow = false
    private let earlyPullWindowNs: UInt64 = 750_000_000
    private func incrementEarly(_ value: inout UInt64) {
        if value == .max { earlyPullCounterOverflow = true } else { value += 1 }
    }
    func enableEarlyNativePulls(baseRequest: Int) {
        XCTAssertTrue(serviceTracing); XCTAssertNil(earlyPullBaseRequest)
        guard serviceTracing, earlyPullBaseRequest == nil else { return }
        earlyPullBaseRequest = baseRequest
        earlyPullPhases = (0..<3).map { _ in EarlyPullPhase() }
        print("NativeClockEarlyPullScope schema=1 enabled=true phases=3 capacityPerPhase=256 windowNs=750000000 anchor=first-native-pull-entry windowUsesCallEntry=true renderPoints=existing-first-only returnedCallsOnly=true operationResultRecorded=false imageEpoch=unavailable newlyEnabledTiming=existing-native-pull-spans newClockSites=0 extraSDKQueries=0 publication=after-cleanup playbackAcceptance=unchanged")
    }
    func recordEarlyNativePull(_ owner: PlaybackService.DebugCPPNativePullStamp) {
        guard let base = earlyPullBaseRequest else { return }
        guard owner.request > base, owner.request - base <= 3 else {
            incrementEarly(&earlyPullOrphans); return
        }
        let slot = earlyPullPhases[owner.request - base - 1], pull = owner.pull
        guard pull.entryNs > 0, pull.returnNs >= pull.entryNs else {
            incrementEarly(&slot.qualityFailures); return
        }
        if slot.anchorNs == nil { slot.anchorNs = pull.entryNs }
        guard let anchor = slot.anchorNs, pull.entryNs >= anchor else {
            incrementEarly(&slot.qualityFailures); return
        }
        guard pull.entryNs - anchor <= earlyPullWindowNs else {
            incrementEarly(&slot.outsideWindow); return
        }
        guard slot.rows.count < 256 else { incrementEarly(&slot.capacityDropped); return }
        if let previous = slot.rows.last, pull.entryNs < previous.pull.entryNs {
            incrementEarly(&slot.qualityFailures)
        }
        // Scalar metadata only. A call entering within the window is retained even if its return crosses it.
        slot.rows.append(owner)
    }
    private func earlySourceQualified(_ owner: PlaybackService.DebugCPPNativePullStamp) -> Bool {
        let p = owner.pull
        return owner.request == owner.generation && owner.sourceItemMatches && owner.observedItemMatches
            && p.ticket?.debugItemIdentity == owner.sourceItem && p.entryOwnerCoherent && p.ownerUnchanged
            && p.entryRevision == p.returnRevision && p.sourceNativeSeekTicket == p.nativeSeekTicket
            && p.activeSeekTicket == nil
    }
    private func dumpEarlyNativePulls() {
        guard let base = earlyPullBaseRequest else { return }
        func ns(_ value: UInt64?) -> String { value.map(String.init) ?? "unknown" }
        func identity(_ value: ObjectIdentifier?) -> String { value.map { String(describing: $0) } ?? "unknown" }
        for (phase, slot) in earlyPullPhases.enumerated() {
            // Existing first-only points are unchanged; choose the earliest actual true return point across seek regions.
            let first = (0..<3).compactMap { renderSlots[phase * 27 + $0 * 9 + 2] }
                .min { $0.render.entryNs < $1.render.entryNs }
            let preceding = first.flatMap { point in slot.rows.indices.last {
                slot.rows[$0].pull.stage == .availability && slot.rows[$0].pull.returnNs <= point.render.entryNs
            } }
            let covered: Bool
            if let anchor = slot.anchorNs, let first, let preceding {
                let owner = slot.rows[preceding], p = owner.pull, r = first.render
                covered = slot.capacityDropped == 0 && slot.qualityFailures == 0
                    && r.entryNs >= anchor && r.entryNs - anchor <= earlyPullWindowNs
                    && p.ticket == r.ticket && p.returnRevision == r.presentationRevision
                    && first.presentationRequest == base + phase + 1 && first.generation == first.presentationRequest
                    && r.ownershipUnchanged && first.presentationMatches && earlySourceQualified(owner)
            } else { covered = false }
            let unqualified = slot.rows.filter { !earlySourceQualified($0) }.count
            let crossingReturns = slot.rows.filter { row in
                slot.anchorNs.map { row.pull.returnNs >= $0 && row.pull.returnNs - $0 > earlyPullWindowNs } ?? false
            }.count
            print("NativeClockEarlyPullSummary schema=1 phase=\(phase) request=\(base + phase + 1) firstPullEntryNs=\(ns(slot.anchorNs)) firstAvailablePointNs=\(ns(first?.render.entryNs)) firstAvailableRecord=\(preceding.map(String.init) ?? "unknown") firstAvailableCovered=\(covered) records=\(slot.rows.count) capacity=256 outsideWindow=\(slot.outsideWindow) capacityDropped=\(slot.capacityDropped) qualityFailures=\(slot.qualityFailures) sourceUnqualified=\(unqualified) orphans=\(earlyPullOrphans) returnsCrossingWindow=\(crossingReturns) overflow=\(earlyPullCounterOverflow || slot.capacityDropped > 0) returnedCallsOnly=true unreturnedCalls=unverified gapCause=unattributed imageEpoch=unavailable clock=DispatchTime")
            for (ordinal, o) in slot.rows.enumerated() {
                let p = o.pull
                print("NativeClockEarlyPullSpan schema=1 phase=\(phase) ordinal=\(ordinal) stage=\(p.stage.rawValue) request=\(o.request) generation=\(o.generation) rawSourceItem=\(o.sourceItem) item=\(identity(p.item)) ticketRevision=\(p.ticket.map { String($0.debugGeneration) } ?? "unknown") output=\(p.output) entryRevision=\(p.entryRevision) returnRevision=\(p.returnRevision) sourceSeekSerial=\(ns(p.sourceNativeSeekTicket)) seekSerial=\(p.nativeSeekTicket) activeSeek=\(ns(p.activeSeekTicket)) entryNs=\(p.entryNs) returnNs=\(p.returnNs) spanNs=\(p.returnNs - p.entryNs) entryOwnerCoherent=\(p.entryOwnerCoherent) ownerUnchanged=\(p.ownerUnchanged) sourceItemMatches=\(o.sourceItemMatches) observedItemMatches=\(o.observedItemMatches) presentationRequest=\(o.presentationRequest.map(String.init) ?? "unknown") presentationMatches=\(o.presentationMatches) sourceQualified=\(earlySourceQualified(o)) cachedAudioToken=\(o.cachedAudioToken) cachedAudioVisit=\(o.cachedAudioVisit) imageEpoch=unavailable operationResultRecorded=false clock=DispatchTime")
            }
            XCTAssertNotNil(slot.anchorNs); XCTAssertEqual(slot.capacityDropped, 0)
            XCTAssertEqual(slot.qualityFailures, 0)
            XCTAssertTrue(covered, "The first available point must retain its actual returned availability call within the bounded early window")
        }
        XCTAssertEqual(earlyPullOrphans, 0); XCTAssertFalse(earlyPullCounterOverflow)
    }
    #endif
    init(serviceTracing: Bool) {
        self.serviceTracing = serviceTracing
        #if DEBUG
        if serviceTracing {
            events.reserveCapacity(32)
            renderSlots = Array(repeating: nil, count: 81)
        }
        #endif
    }
    func beginPoll() { layerReady = nil }
    func observeLayerReady(_ value: Bool) -> Bool { layerReady = value; return value }
    private func predicates(_ state: ProductionSelectionState, beforeVisit: Int64, beforeSubmitted: UInt64) -> UInt16 {
        var result: UInt16 = 0
        if state.selected { result |= 1 << 0 }
        if state.audio.visit > beforeVisit { result |= 1 << 1 }
        if state.submitted > beforeSubmitted { result |= 1 << 2 }
        if layerReady == true { result |= 1 << 3 }
        if let frame = state.frame, let copied = state.copied,
           frame.isFinite, copied.isFinite, state.requested.isFinite, frame >= 0, copied >= 0 {
            result |= 1 << 4
            if abs(frame - state.requested) <= 0.080 { result |= 1 << 5 }
            if abs(copied - frame) <= 0.080 { result |= 1 << 6 }
        }
        if state.videoReady { result |= 1 << 7 }
        if !state.loading { result |= 1 << 8 }
        return result
    }
    func recordPoll(uptime: Double, readyLatched: Bool, state: ProductionSelectionState,
                    beforeVisit: Int64, beforeSubmitted: UInt64) {
        guard (0..<3).contains(phase) else { badPhase = true; return }
        lastPolls[phase] = Poll(uptime: uptime, readyLatched: readyLatched,
            mask: predicates(state, beforeVisit: beforeVisit, beforeSubmitted: beforeSubmitted),
            evaluated: layerReady == nil ? 503 : 511)
    }
    func finishPhase(state: ProductionSelectionState, beforeVisit: Int64, beforeSubmitted: UInt64) {
        guard (0..<3).contains(phase) else { badPhase = true; return }
        layerReady = nil // No second custom-layer query at the terminal snapshot.
        finalMasks[phase] = predicates(state, beforeVisit: beforeVisit, beforeSubmitted: beforeSubmitted)
    }
    #if DEBUG
    private func append(_ event: Event) {
        guard serviceTracing, events.count < 32 else {
            if dropped < Int.max { dropped += 1 } else { overflow = true }
            return
        }
        events.append(event)
    }
    func record(_ stamp: PlaybackService.DebugVideoStartupStamp) { append(.startup(phase, stamp)) }
    func recordSeek(_ stamp: PlaybackService.DebugVideoSeekStamp) {
        guard serviceTracing else { return }
        append(.seek(phase, DispatchTime.now().uptimeNanoseconds, stamp))
    }
    func recordRender(_ stamp: PlaybackService.DebugVideoRenderStamp) {
        guard serviceTracing, (0..<3).contains(phase), (0..<3).contains(stamp.render.region),
              (0..<9).contains(stamp.render.stage.rawValue) else { badPhase = true; return }
        let index = phase * 27 + stamp.render.region * 9 + stamp.render.stage.rawValue
        guard renderSlots[index] == nil else {
            if renderConflicts < Int.max { renderConflicts += 1 } else { overflow = true }
            return
        }
        renderSlots[index] = stamp
        if stamp.render.ticket == nil || !stamp.render.ownershipUnchanged || !stamp.presentationMatches {
            if renderOwnershipFailures < Int.max { renderOwnershipFailures += 1 } else { overflow = true }
        }
        if stamp.render.stage == .hasNewTrue, let trace = availabilityClockTrace {
            let slot = earlyPullPhases.indices.contains(phase) ? earlyPullPhases[phase] : nil
            let source = slot?.rows.last {
                $0.pull.stage == .availability && $0.pull.returnNs <= stamp.render.entryNs
            }
            let covered = slot.map { slot in
                slot.capacityDropped == 0 && slot.qualityFailures == 0
                    && slot.anchorNs.map { stamp.render.entryNs >= $0
                        && stamp.render.entryNs - $0 <= earlyPullWindowNs } == true
            } == true && source.map { earlySourceQualified($0) } == true
            trace.recordFirstAvailability(phase: phase, point: stamp, source: source, covered: covered)
        }
    }
    private func dumpRenderRows() {
        print("ProductionSelectionRenderSummary schema=1 enabled=\(serviceTracing) phases=3 regions=3 stages=9 capacity=81 conflicts=\(renderConflicts) ownershipFailures=\(renderOwnershipFailures) storage=scalar-first-only")
        guard serviceTracing else { return }
        for phase in 0..<3 {
            var observedCopy = false, observedEnqueue = false
            for region in 0..<3 {
                // A missing stage is unavailable, never a false SDK result or proof of idle.
                let offset = phase * 27 + region * 9
                var observedMask: UInt16 = 0
                for stage in 0..<9 where renderSlots[offset + stage] != nil { observedMask |= UInt16(1) << stage }
                print("ProductionSelectionRenderRegion schema=1 phase=\(phase) region=\(region) observedMask=\(observedMask) firstSeekOnly=true")
                for stage in 0..<9 {
                    guard let s = renderSlots[offset + stage] else { continue }
                    if stage == 3 { observedCopy = true }
                    if stage == 4 { observedEnqueue = true }
                    let r = s.render
                    print("ProductionSelectionRenderStage schema=1 phase=\(phase) region=\(region) stage=\(stage) entryNs=\(r.entryNs) returnNs=\(r.returnNs) presentationRevision=\(r.presentationRevision) ownershipUnchanged=\(r.ownershipUnchanged) nativeSeekTicket=\(r.nativeSeekTicket.map { String($0) } ?? "unknown") request=\(s.presentationRequest.map { String($0) } ?? "unknown") generation=\(s.generation) presentationMatches=\(s.presentationMatches) token=\(s.audioToken) visit=\(s.audioVisit) requested=\(r.requestedSeconds.map { String($0) } ?? "unknown") samplePTS=\(r.sampleSeconds.map { String($0) } ?? "unknown") cachedCopiedPTS=\(r.copiedPTS.map { String($0) } ?? "unknown") cachedSubmittedPTS=\(r.submittedPTS.map { String($0) } ?? "unknown") submittedCount=\(r.submittedCount) resourceOwnership=\(r.resourceOwnership)")
                }
            }
            XCTAssertTrue(observedCopy, "The traced selection must retain its actual copy observation")
            XCTAssertTrue(observedEnqueue, "The traced selection must retain its actual enqueue observation")
        }
    }
    #endif
    func dumpAndAssert() {
        for phase in 0..<3 {
            if let poll = lastPolls[phase] {
                print("ProductionSelectionReadyPredicates schema=1 phase=\(phase) lastPollEntryUptime=\(poll.uptime) readyLatched=\(poll.readyLatched) lastPollMask=\(poll.mask) lastPollEvaluatedMask=\(poll.evaluated) terminalMask=\(finalMasks[phase].map { String($0) } ?? "unknown") terminalEvaluatedMask=503 allTrueMask=511 serviceTracing=\(serviceTracing)")
            }
        }
        XCTAssertFalse(badPhase)
        #if DEBUG
        print("ProductionSelectionStartupSummary schema=1 enabled=\(serviceTracing) events=\(events.count) capacity=32 dropped=\(dropped) overflow=\(overflow)")
        for (ordinal, event) in events.enumerated() {
            switch event {
            case .startup(let phase, let s):
                print("ProductionSelectionStartup schema=1 ordinal=\(ordinal) phase=\(phase) kind=\(s.kind.rawValue) request=\(s.request) entryGeneration=\(s.entryGeneration) returnGeneration=\(s.returnGeneration) entryNs=\(s.entryNs) returnNs=\(s.returnNs) presentationRequest=\(s.presentationRequest.map { String($0) } ?? "unknown") presentationUnchanged=\(s.presentationUnchanged) token=\(s.audioToken) visit=\(s.audioVisit) readyGeneration=\(s.readyGeneration.map { String($0) } ?? "unknown") entryVideoReady=\(s.entryVideoReady) returnVideoReady=\(s.returnVideoReady) entryLoading=\(s.entryLoading) returnLoading=\(s.returnLoading) timelineInstalled=\(s.timelineInstalled) anchorHostSeconds=\(s.anchorHostSeconds.map { String($0) } ?? "unknown") anchorPosition=\(s.anchorPosition.map { String($0) } ?? "unknown")")
            case .seek(let phase, let seenNs, let s):
                print("ProductionSelectionStartupSeekOrder schema=1 ordinal=\(ordinal) phase=\(phase) observedNs=\(seenNs) reason=\(s.reason.rawValue) request=\(s.request) generation=\(s.generation) nativeSeekTicket=\(s.nativeSeekTicket) force=\(s.force) ordinaryDriftReadEntryNs=\(s.ordinaryDriftReadEntryNs.map { String($0) } ?? "unknown") ordinaryDriftReadReturnNs=\(s.ordinaryDriftReadReturnNs.map { String($0) } ?? "unknown") ordinaryDriftReadSpanNs=\(s.ordinaryDriftReadEntryNs.flatMap { begin in s.ordinaryDriftReadReturnNs.flatMap { end in end >= begin ? String(end - begin) : nil } } ?? "unknown")")
            }
        }
        XCTAssertEqual(dropped, 0); XCTAssertFalse(overflow)
        dumpRenderRows()
        XCTAssertEqual(renderConflicts, 0); XCTAssertEqual(renderOwnershipFailures, 0)
        dumpEarlyNativePulls()
        #endif
    }
}

#if DEBUG
/// Returned durations only; fixed three raw-source requests, no SDK queries or per-call logging.
@MainActor
private final class CPPNativePullDurationTrace {
    private struct Record {
        let owner: PlaybackService.DebugCPPNativePullStamp
        var span: UInt64 { owner.pull.returnNs - owner.pull.entryNs }
    }
    private struct Stage {
        var calls: UInt64 = 0
        var first: Record?, maximum: Record?
    }
    private struct Request {
        let request: Int, sourceItem: ObjectIdentifier
        var phase: Int?, monitorEpoch: UInt64?, monitorOutput: ObjectIdentifier?
        var monitorStartEntryNs: UInt64?, monitorStarts: UInt64 = 0
        var cppTicket: ContinuousPictureInPicture.PresentationTicket?, cppOutput: ObjectIdentifier?
        var cppRevision: Int?, pendingPhaseCalls: UInt64 = 0
        var stages = [Stage](repeating: Stage(), count: 3)
    }
    private let enabled: Bool
    private var anchors = [UInt64?](repeating: nil, count: 3)
    private var requests: [Request] = []
    private var observed = [UInt64](repeating: 0, count: 3)
    private var orphans = [UInt64](repeating: 0, count: 3)
    private var unmatchedMonitorStarts: UInt64 = 0, qualityFailures: UInt64 = 0
    private var overflow = false
    init(enabled: Bool) { self.enabled = enabled; requests.reserveCapacity(3) }
    private func increment(_ value: inout UInt64) {
        if value == .max { overflow = true } else { value += 1 }
    }
    func beginPhase(_ phase: Int, commandNs: UInt64?) {
        guard anchors.indices.contains(phase), anchors[phase] == nil, let commandNs else {
            increment(&qualityFailures); return
        }
        anchors[phase] = commandNs // Reuse the existing lifecycle anchor, no extra clock.
    }
    private func slot(request: Int, item: ObjectIdentifier) -> Int? {
        if let index = requests.firstIndex(where: { $0.request == request }) {
            guard requests[index].sourceItem == item else { increment(&qualityFailures); return nil }
            return index
        }
        guard requests.count < 3 else { overflow = true; return nil }
        requests.append(Request(request: request, sourceItem: item))
        return requests.count - 1
    }
    func record(_ owner: PlaybackService.DebugCPPNativePullStamp) {
        let pull = owner.pull, stageIndex = pull.stage.rawValue
        increment(&observed[stageIndex])
        guard enabled, owner.request == owner.generation, owner.sourceItemMatches,
              owner.observedItemMatches, pull.ticket != nil, pull.entryOwnerCoherent,
              pull.ownerUnchanged, pull.returnNs >= pull.entryNs,
              let index = slot(request: owner.request, item: owner.sourceItem) else {
            increment(&orphans[stageIndex]); increment(&qualityFailures); return
        }
        if (requests[index].cppTicket != nil && requests[index].cppTicket != pull.ticket)
            || (requests[index].cppOutput != nil && requests[index].cppOutput != pull.output) {
            increment(&orphans[stageIndex]); increment(&qualityFailures); return
        }
        requests[index].cppTicket = pull.ticket; requests[index].cppOutput = pull.output
        requests[index].cppRevision = pull.entryRevision
        if requests[index].phase == nil { increment(&requests[index].pendingPhaseCalls) }
        var stage = requests[index].stages[stageIndex]
        increment(&stage.calls)
        let record = Record(owner: owner)
        if stage.first == nil { stage.first = record }
        if stage.maximum == nil || record.span > stage.maximum!.span { stage.maximum = record }
        requests[index].stages[stageIndex] = stage
    }
    func recordMonitor(_ owner: PlaybackService.DebugFrameMonitorReadBatch) {
        let batch = owner.reads
        guard batch.isStartBodyExit else { return }
        guard enabled, !batch.epochOverflowed, owner.request == owner.generation,
              owner.sourceItemMatches, owner.observedItemMatches, owner.presentationMatches,
              let phase = anchors.indices.last(where: {
                  anchors[$0].map { $0 <= batch.lifecycle.startEntryNs } ?? false
              }), let index = slot(request: owner.request, item: batch.item) else {
            increment(&unmatchedMonitorStarts); increment(&qualityFailures); return
        }
        var request = requests[index]
        guard request.phase == nil, !requests.contains(where: { $0.phase == phase }) else {
            increment(&unmatchedMonitorStarts); increment(&qualityFailures); return
        }
        request.phase = phase; request.monitorEpoch = batch.epoch; request.monitorOutput = batch.output
        request.monitorStartEntryNs = batch.lifecycle.startEntryNs
        increment(&request.monitorStarts)
        requests[index] = request
    }
    func dumpAndAssert() {
        func optional<T>(_ value: T?) -> String { value.map { String(describing: $0) } ?? "unavailable" }
        let retained = requests.reduce(0) { total, request in
            total + request.stages.reduce(0) { $0 + ($1.first == nil ? 0 : 1) + ($1.maximum == nil ? 0 : 1) }
        }
        let unjoined = requests.filter { $0.phase == nil }.count
        print("CPPNativePullSummary schema=1 enabled=\(enabled) requests=\(requests.count) maximumRequests=3 retainedRecords=\(retained) capacityRecords=18 orphanAvailability=\(orphans[0]) orphanCopy=\(orphans[1]) orphanEnqueue=\(orphans[2]) observedAvailability=\(observed[0]) observedCopy=\(observed[1]) observedEnqueue=\(observed[2]) unjoinedRequests=\(unjoined) unmatchedMonitorStarts=\(unmatchedMonitorStarts) qualityFailures=\(qualityFailures) overflow=\(overflow) returnedCallsOnly=true unreturnedCalls=unverified wholeRenderFrameCovered=false clock=DispatchTime")
        XCTAssertFalse(overflow); XCTAssertEqual(qualityFailures, 0); XCTAssertLessThanOrEqual(retained, 18)
        XCTAssertEqual(unjoined, 0); XCTAssertEqual(unmatchedMonitorStarts, 0)
        for stage in ContinuousPictureInPicture.DebugNativePullStage.allCases {
            let index = stage.rawValue
            XCTAssertEqual(orphans[index], 0)
            var accounted = orphans[index]
            for request in requests {
                let sum = accounted.addingReportingOverflow(request.stages[index].calls)
                XCTAssertFalse(sum.overflow); accounted = sum.partialValue
            }
            XCTAssertEqual(observed[index], accounted)
        }
        for anchor in anchors { XCTAssertNotNil(anchor) }
        if !enabled { XCTAssertTrue(requests.isEmpty); return }
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.compactMap(\.phase)), Set(0..<3))
        for request in requests {
            let phase = request.phase
            let anchor = phase.flatMap { anchors[$0] }
            print("CPPNativePullRequest schema=1 phase=\(optional(phase)) request=\(request.request) rawSourceItem=\(request.sourceItem) cppOutput=\(optional(request.cppOutput)) cppRevision=\(optional(request.cppRevision)) monitorEpoch=\(optional(request.monitorEpoch)) monitorOutput=\(optional(request.monitorOutput)) monitorStartEntryNs=\(optional(request.monitorStartEntryNs)) commandEntryNs=\(optional(anchor)) monitorStarts=\(request.monitorStarts) callsBeforePhaseJoin=\(request.pendingPhaseCalls) phaseJoin=exact-request-and-raw-item cppAndMonitorOutputsDistinct=true")
            XCTAssertEqual(request.monitorStarts, 1)
            XCTAssertNotNil(request.cppTicket); XCTAssertNotNil(request.cppOutput)
            XCTAssertGreaterThan(request.stages[0].calls, 0)
            XCTAssertLessThanOrEqual(request.stages[1].calls, request.stages[0].calls)
            XCTAssertLessThanOrEqual(request.stages[2].calls, request.stages[1].calls)
            for kind in ContinuousPictureInPicture.DebugNativePullStage.allCases {
                let stage = request.stages[kind.rawValue]
                XCTAssertEqual(stage.first == nil, stage.calls == 0)
                XCTAssertEqual(stage.maximum == nil, stage.calls == 0)
                print("CPPNativePullCount schema=1 phase=\(optional(phase)) request=\(request.request) stage=\(kind.rawValue) calls=\(stage.calls)")
                for (role, record) in [("first", stage.first), ("maximum", stage.maximum)] {
                    guard let record else { continue }
                    let owner = record.owner, pull = owner.pull
                    if let anchor { XCTAssertGreaterThanOrEqual(pull.entryNs, anchor) }
                    print("CPPNativePullDuration schema=1 phase=\(optional(phase)) request=\(request.request) stage=\(kind.rawValue) role=\(role) calls=\(stage.calls) rawSourceItem=\(owner.sourceItem) cppItem=\(optional(pull.item)) cppOutput=\(pull.output) entryRevision=\(pull.entryRevision) returnRevision=\(pull.returnRevision) sourceNativeSeekTicket=\(optional(pull.sourceNativeSeekTicket)) nativeSeekTicket=\(pull.nativeSeekTicket) activeSeekTicket=\(optional(pull.activeSeekTicket)) entryNs=\(pull.entryNs) returnNs=\(pull.returnNs) spanNs=\(record.span) entryOwnerCoherent=\(pull.entryOwnerCoherent) ownerUnchanged=\(pull.ownerUnchanged) serviceGeneration=\(owner.generation) sourceItemMatches=\(owner.sourceItemMatches) observedItemMatches=\(owner.observedItemMatches) presentationRequest=\(optional(owner.presentationRequest)) presentationMatches=\(owner.presentationMatches) cachedAudioToken=\(owner.cachedAudioToken) cachedAudioVisit=\(owner.cachedAudioVisit) cachedAudioOnly=true operationResultRecorded=false enqueueReturnProvesDisplay=false clock=DispatchTime")
                }
            }
        }
    }
}

/// No native queries or per-call logging. Fixed first+maximum per stage/request.
@MainActor
private final class DefaultFrameMonitorReadTrace {
    private struct Record {
        let owner: PlaybackService.DebugFrameMonitorReadBatch
        let read: PlaybackFrameMonitor.DebugReadStamp
        var span: UInt64 { read.returnNs >= read.entryNs ? read.returnNs - read.entryNs : 0 }
    }
    private struct Stage {
        var calls: UInt64 = 0
        var first: Record?, maximum: Record?
    }
    private struct Request {
        let phase: Int, request: Int, commandNs: UInt64
        let epoch: UInt64
        let item: ObjectIdentifier, output: ObjectIdentifier
        let startAudioToken: Int, startAudioVisit: Int64
        var latestAudioToken: Int, latestAudioVisit: Int64
        var lifecycle: PlaybackFrameMonitor.DebugLifecycle
        var starts: UInt64 = 0, observedTicks: UInt64 = 0
        var batches: UInt64 = 0, invalidMappings: UInt64 = 0, accepted: UInt64 = 0
        var stages = [Stage](repeating: Stage(), count: 4)
    }
    let enabled: Bool
    private var commandAnchors = [UInt64?](repeating: nil, count: 3)
    private var requests: [Request] = []
    private var overflow = false
    private var qualityFailures: UInt64 = 0
    init(enabled: Bool) { self.enabled = enabled; requests.reserveCapacity(3) }
    @discardableResult func beginPhase(_ value: Int) -> UInt64? {
        guard commandAnchors.indices.contains(value), commandAnchors[value] == nil else {
            increment(&qualityFailures); return nil
        }
        // Common test-only anchor in BOTH matched arms; no production nil-path clock.
        commandAnchors[value] = DispatchTime.now().uptimeNanoseconds
        return commandAnchors[value]
    }
    private func increment(_ value: inout UInt64) {
        if value == UInt64.max { overflow = true } else { value += 1 }
    }
    func record(_ owner: PlaybackService.DebugFrameMonitorReadBatch) {
        guard enabled else { increment(&qualityFailures); return }
        let batch = owner.reads, life = batch.lifecycle
        guard !batch.epochOverflowed else { overflow = true; return }
        let index: Int
        if let found = requests.firstIndex(where: { $0.request == owner.request }) { index = found }
        else {
            // Start-body exit binds the owner before any ordinary display-link tick.
            // Locate phase by start time, never by the phase at callback delivery.
            guard batch.isStartBodyExit,
                  let phase = commandAnchors.indices.last(where: {
                      commandAnchors[$0].map { $0 <= life.startEntryNs } ?? false
                  }), let anchor = commandAnchors[phase] else {
                increment(&qualityFailures); return
            }
            guard requests.count < 3, !requests.contains(where: { $0.phase == phase }) else {
                overflow = true; return
            }
            requests.append(Request(phase: phase, request: owner.request, commandNs: anchor,
                epoch: batch.epoch, item: batch.item, output: batch.output,
                startAudioToken: owner.cachedAudioToken, startAudioVisit: owner.cachedAudioVisit,
                latestAudioToken: owner.cachedAudioToken, latestAudioVisit: owner.cachedAudioVisit,
                lifecycle: life))
            index = requests.count - 1
        }
        let initial = requests[index]
        guard initial.epoch == batch.epoch, initial.item == batch.item, initial.output == batch.output,
              initial.lifecycle.startEntryNs == life.startEntryNs,
              initial.lifecycle.startBodyExitNs == life.startBodyExitNs else {
            increment(&qualityFailures); return // Never merge restarted or changed owners.
        }
        if owner.request != owner.generation || !owner.sourceItemMatches || !owner.observedItemMatches
            || !owner.presentationMatches || !owner.selectedMatchesQueue || !life.startOwnerCoherent
            || life.ownerChanges != 0 || life.overflow || life.identity.overflow || life.status.overflow
            || life.tickBody.overflow || life.ticks < initial.lifecycle.ticks
            || life.identity.count < initial.lifecycle.identity.count
            || life.status.count < initial.lifecycle.status.count
            || life.tickBody.count < initial.lifecycle.tickBody.count {
            increment(&qualityFailures)
        }
        let ordered = [Optional(life.startEntryNs), life.startBodyExitNs, life.firstTickEntryNs,
                       life.acceptedNs, life.cancelEntryNs, life.cancelReturnNs,
                       life.completionEntryNs, life.completionReturnNs, life.lastTickBodyExitNs].compactMap { $0 }
        if zip(ordered, ordered.dropFirst()).contains(where: { before, after in after < before }) { increment(&qualityFailures) }
        var request = requests[index]
        if batch.isStartBodyExit {
            increment(&request.starts)
            if batch.native != nil || life.ticks != 0 { increment(&qualityFailures) }
        } else { increment(&request.observedTicks) }
        request.lifecycle = life
        request.latestAudioToken = owner.cachedAudioToken; request.latestAudioVisit = owner.cachedAudioVisit
        if life.ticks != request.observedTicks { increment(&qualityFailures) }
        if let reads = batch.native {
            if reads.ownerAfterReadiness == reads.readinessAccepted
                || (reads.fallback != nil) != !reads.mappedTime.isValid { increment(&qualityFailures) }
            increment(&request.batches)
            if !reads.mappedTime.isValid { increment(&request.invalidMappings) }
            if reads.readinessAccepted { increment(&request.accepted) }
            let values = [Optional(reads.mapping), reads.fallback, Optional(reads.availability), Optional(reads.layer)]
            for value in values.compactMap({ $0 }) {
                if !value.ownerCoherent || value.returnNs < value.entryNs { increment(&qualityFailures) }
                let index = value.stage.rawValue
                var stage = request.stages[index]
                increment(&stage.calls)
                let record = Record(owner: owner, read: value)
                if stage.first == nil { stage.first = record }
                if stage.maximum == nil || record.span > stage.maximum!.span { stage.maximum = record }
                request.stages[index] = stage
            }
        }
        requests[index] = request
    }
    private func dumpLifecycle(_ request: Request) {
        let l = request.lifecycle
        func ns(_ value: UInt64?) -> String { value.map(String.init) ?? "unavailable" }
        print("DefaultFrameMonitorLifecycleSummary schema=1 phase=\(request.phase) request=\(request.request) epoch=\(request.epoch) item=\(request.item) output=\(request.output) commandEntryNs=\(request.commandNs) startEntryNs=\(l.startEntryNs) startBodyExitNs=\(ns(l.startBodyExitNs)) firstTickEntryNs=\(ns(l.firstTickEntryNs)) lastTickBodyExitNs=\(ns(l.lastTickBodyExitNs)) starts=\(request.starts) ticks=\(l.ticks) observedReturnedTicks=\(request.observedTicks) nativeBatches=\(request.batches) missingOwners=\(l.missingOwners) identityRejected=\(l.identityRejected) statusNotReady=\(l.statusNotReady) identityCalls=\(l.identity.count) statusCalls=\(l.status.count) tickBodies=\(l.tickBody.count) firstDecodedNs=\(ns(l.firstDecodedNs)) firstLayerReadyNs=\(ns(l.firstLayerReadyNs)) acceptedNs=\(ns(l.acceptedNs)) cancelReason=\(l.cancelReason.map(String.init) ?? "unavailable") cancelEntryNs=\(ns(l.cancelEntryNs)) cancelReturnNs=\(ns(l.cancelReturnNs)) completionEntryNs=\(ns(l.completionEntryNs)) completionReturnNs=\(ns(l.completionReturnNs)) completionPresent=\(l.completionPresent.map(String.init) ?? "unavailable") startAudioToken=\(request.startAudioToken) startAudioVisit=\(request.startAudioVisit) latestAudioToken=\(request.latestAudioToken) latestAudioVisit=\(request.latestAudioVisit) cachedAudioOnly=true ownerChanges=\(l.ownerChanges) clock=DispatchTime bodyExcludesObserver=true externalCancellationCovered=false unreturnedCalls=unverified")
        XCTAssertEqual(request.starts, 1)
        XCTAssertNotNil(l.startBodyExitNs); XCTAssertNotNil(l.firstTickEntryNs)
        XCTAssertEqual(l.ticks, request.observedTicks); XCTAssertEqual(l.tickBody.count, l.ticks)
        for (actual, total, excluded) in [(l.identity.count, l.ticks, l.missingOwners),
                                         (l.status.count, l.identity.count, l.identityRejected),
                                         (request.batches, l.status.count, l.statusNotReady)] {
            let expected = total.subtractingReportingOverflow(excluded)
            XCTAssertFalse(expected.overflow); XCTAssertEqual(actual, expected.partialValue)
        }
        XCTAssertEqual(l.cancelReason, 2); XCTAssertEqual(l.completionPresent, true)
        XCTAssertNotNil(l.acceptedNs); XCTAssertNotNil(l.cancelEntryNs); XCTAssertNotNil(l.cancelReturnNs)
        XCTAssertNotNil(l.completionEntryNs); XCTAssertNotNil(l.completionReturnNs)
        for (name, span) in [("identity", l.identity), ("status", l.status), ("tickBody", l.tickBody)] {
            XCTAssertFalse(span.overflow)
            XCTAssertEqual(span.first == nil, span.count == 0)
            XCTAssertEqual(span.maximum == nil, span.count == 0)
            for (role, value) in [("first", span.first), ("maximum", span.maximum)] {
                guard let value else { continue }
                XCTAssertGreaterThanOrEqual(value.returnNs, value.entryNs)
                print("DefaultFrameMonitorLifecycleSpan schema=1 phase=\(request.phase) request=\(request.request) epoch=\(request.epoch) stage=\(name) role=\(role) calls=\(span.count) entryNs=\(value.entryNs) returnNs=\(value.returnNs) spanNs=\(value.span) bodyExcludesObserver=true")
            }
        }
    }
    func dumpAndAssert() {
        let retained = requests.reduce(0) { sum, request in
            sum + request.stages.reduce(0) { $0 + ($1.first == nil ? 0 : 1) + ($1.maximum == nil ? 0 : 1) }
        }
        print("DefaultFrameMonitorReadSummary schema=1 enabled=\(enabled) requests=\(requests.count) maximumRequests=3 stages=4 retainedRecords=\(retained) capacityRecords=24 overflow=\(overflow) qualityFailures=\(qualityFailures) wholeTickCoverage=false nativeEntryGuardsCovered=\(enabled) lifecycleSnapshotsMaximum=3 lifecycleSpanKinds=3")
        XCTAssertFalse(overflow); XCTAssertEqual(qualityFailures, 0); XCTAssertLessThanOrEqual(retained, 24)
        for (phase, anchor) in commandAnchors.enumerated() {
            print("DefaultFrameMonitorLifecycleCommand schema=1 enabled=\(enabled) phase=\(phase) commandEntryNs=\(anchor.map(String.init) ?? "unavailable") clock=DispatchTime")
            XCTAssertNotNil(anchor)
        }
        if !enabled {
            XCTAssertTrue(requests.isEmpty, "Nil observer must not synthesize zero-valued native read evidence")
            return
        }
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.map(\.phase)), Set(0..<3))
        for request in requests {
            dumpLifecycle(request)
            XCTAssertGreaterThan(request.batches, 0)
            XCTAssertGreaterThan(request.accepted, 0, "Each selected request needs an actual accepted monitor tick")
            for kind in PlaybackFrameMonitor.DebugReadStage.allCases {
                let stage = request.stages[kind.rawValue]
                let expected = kind == .fallback ? request.invalidMappings : request.batches
                XCTAssertEqual(stage.calls, expected, "Missing or duplicate read observations fail quality")
                print("DefaultFrameMonitorReadCount schema=1 phase=\(request.phase) request=\(request.request) stage=\(kind.rawValue) calls=\(stage.calls) batches=\(request.batches) invalidMappings=\(request.invalidMappings) accepted=\(request.accepted) absentFallbackIsZero=\(kind == .fallback && stage.calls == 0)")
                for (role, value) in [("first", stage.first), ("maximum", stage.maximum)] {
                    guard let value else { continue }
                    let owner = value.owner, batch = owner.reads
                    guard let reads = batch.native else { XCTFail("A retained native record must contain actual reads"); continue }
                    let mapped = reads.mappedTime.isNumeric ? String(reads.mappedTime.seconds) : "nonnumeric"
                    let chosen = reads.chosenTime.isNumeric ? String(reads.chosenTime.seconds) : "nonnumeric"
                    print("DefaultFrameMonitorRead schema=1 phase=\(request.phase) request=\(request.request) role=\(role) stage=\(kind.rawValue) epoch=\(batch.epoch) entryNs=\(value.read.entryNs) returnNs=\(value.read.returnNs) spanNs=\(value.span) operationOwnerCoherent=\(value.read.ownerCoherent) sourceItemMatches=\(owner.sourceItemMatches) observedItemMatches=\(owner.observedItemMatches) presentationMatches=\(owner.presentationMatches) selectedMatchesQueue=\(owner.selectedMatchesQueue) generation=\(owner.generation) cachedAudioToken=\(owner.cachedAudioToken) cachedAudioVisit=\(owner.cachedAudioVisit) mappedValid=\(reads.mappedTime.isValid) mappedNumeric=\(reads.mappedTime.isNumeric) mappedSeconds=\(mapped) chosenValid=\(reads.chosenTime.isValid) chosenNumeric=\(reads.chosenTime.isNumeric) chosenSeconds=\(chosen) fallbackTaken=\(reads.fallback != nil) decoded=\(reads.decoded) layerReady=\(reads.layerReady) readinessAccepted=\(reads.readinessAccepted) expectedTerminalCancellation=\(reads.readinessAccepted) ownerAfterReadiness=\(reads.ownerAfterReadiness) displayTimestamp=\(reads.displayTimestamp) targetTimestamp=\(reads.targetTimestamp) wholeTickCoverage=false")
                }
            }
        }
    }
}
#endif

#if DEBUG
/// Main-actor-only fixed scalar observation. Nil configuration reads no clock.
/// First/worst completed spans include entry-marker work and any synchronous
/// reentrancy; they exclude the return-marker update and are not exclusive SDK cost.
@MainActor
private final class ProductionSelectionPollSummary {
    enum Stage: Int { case toneScan = 1, stateCapture = 2, readinessEvaluation = 3 }
    struct Span {
        let poll: UInt64, begin: UInt64, end: UInt64
        var layerReadyPredicateEvaluated = false
        var duration: UInt64 { end - begin }
    }
    struct Pair {
        var first: Span?, worst: Span?
        mutating func accept(_ span: Span) {
            if first == nil { first = span }
            if worst == nil || span.duration > worst!.duration { worst = span }
        }
    }
    struct Phase {
        var entered: UInt64 = 0, returned: UInt64 = 0
        var lastEntry: UInt64 = 0, lastReturn: UInt64 = 0
        var stageEntry: UInt64 = 0, stageReturn: UInt64 = 0
        var stageCode = 0, bodyOpen = false, stageOpen = false
        var deadlineUptime = 0.0
        var loopExit: UInt64 = 0, nextCursor = 0
        var tone = Pair(), state = Pair(), readiness = Pair()
        var largestGap: Span?
    }
    private var phases = [Phase](repeating: Phase(), count: 3)
    private var invalid = false, overflowed = false

    func snapshot(phase: Int) -> Phase? { phases.indices.contains(phase) ? phases[phase] : nil }
    func setDeadline(phase: Int, uptime: Double) {
        guard phases.indices.contains(phase), uptime.isFinite else { invalid = true; return }
        phases[phase].deadlineUptime = uptime
    }
    func bodyEntered(phase: Int, at now: UInt64) {
        guard phases.indices.contains(phase) else { invalid = true; return }
        var value = phases[phase]
        if value.bodyOpen || value.stageOpen { invalid = true }
        value.entered = increment(value.entered)
        if value.returned > 0 {
            if now < value.lastReturn { invalid = true }
            else {
                let gap = Span(poll: value.entered, begin: value.lastReturn, end: now)
                if value.largestGap == nil || gap.duration > value.largestGap!.duration { value.largestGap = gap }
            }
        }
        value.lastEntry = now; value.bodyOpen = true
        phases[phase] = value
    }
    func stageEntered(phase: Int, stage: Stage, at now: UInt64) {
        guard phases.indices.contains(phase) else { invalid = true; return }
        var value = phases[phase]
        if !value.bodyOpen || value.stageOpen || now < value.lastEntry { invalid = true }
        value.stageCode = stage.rawValue; value.stageEntry = now; value.stageReturn = 0; value.stageOpen = true
        phases[phase] = value
    }
    func stageReturned(phase: Int, stage: Stage, at now: UInt64, layerReadyPredicateEvaluated: Bool = false) {
        guard phases.indices.contains(phase) else { invalid = true; return }
        var value = phases[phase]
        guard value.bodyOpen, value.stageOpen, value.stageCode == stage.rawValue,
              now >= value.stageEntry else { invalid = true; return }
        let span = Span(poll: value.entered, begin: value.stageEntry, end: now,
                        layerReadyPredicateEvaluated: layerReadyPredicateEvaluated)
        switch stage {
        case .toneScan: value.tone.accept(span)
        case .stateCapture: value.state.accept(span)
        case .readinessEvaluation: value.readiness.accept(span)
        }
        value.stageReturn = now; value.stageOpen = false
        phases[phase] = value
    }
    func bodyReturned(phase: Int, at now: UInt64) {
        guard phases.indices.contains(phase) else { invalid = true; return }
        var value = phases[phase]
        guard value.bodyOpen, !value.stageOpen, now >= value.lastEntry else { invalid = true; return }
        value.returned = increment(value.returned); value.lastReturn = now; value.bodyOpen = false
        phases[phase] = value
    }
    func loopExited(phase: Int, at now: UInt64, nextCursor: Int) {
        guard phases.indices.contains(phase), now >= phases[phase].lastEntry,
              nextCursor >= 0 else { invalid = true; return }
        phases[phase].loopExit = now; phases[phase].nextCursor = nextCursor
    }
    private func increment(_ count: UInt64) -> UInt64 {
        let result = count.addingReportingOverflow(1)
        if result.overflow { overflowed = true; return .max }
        return result.partialValue
    }
    func dumpAndAssert() {
        XCTAssertFalse(invalid); XCTAssertFalse(overflowed)
        for phase in phases.indices {
            let value = phases[phase]
            let trailingAvailable = value.loopExit > 0 && value.returned > 0
                && !value.bodyOpen && value.loopExit >= value.lastReturn
            let trailing = trailingAvailable ? value.loopExit - value.lastReturn : 0
            print("ProductionSelectionPollSummary schema=1 phase=\(phase) entered=\(value.entered) returned=\(value.returned) lastEntryAvailable=\(value.entered > 0) lastEntryNs=\(value.lastEntry) lastBodyReturnNs=\(value.lastReturn) lastStage=\(value.stageCode) lastStageEntryNs=\(value.stageEntry) lastStageReturnNs=\(value.stageReturn) unreturnedBody=\(value.bodyOpen) unreturnedStage=\(value.stageOpen) loopExitNs=\(value.loopExit) trailingGapAvailable=\(trailingAvailable) trailingBodyReturnToLoopExitNs=\(trailing) deadlineSystemUptime=\(value.deadlineUptime) onlineNextCursor=\(value.nextCursor) invalid=\(invalid) overflowed=\(overflowed) firstWorstSpanCapacity=18 largestGapCapacity=3 publication=after-cleanup sdkExclusiveCost=false terminalStateMeasured=false")
            XCTAssertEqual(value.entered, value.returned)
            XCTAssertFalse(value.bodyOpen); XCTAssertFalse(value.stageOpen)
            for (stage, pair) in [(1, value.tone), (2, value.state), (3, value.readiness)] {
                for (variant, span) in [(0, pair.first), (1, pair.worst)] {
                    print("ProductionSelectionPollSpan schema=1 phase=\(phase) stage=\(stage) variant=\(variant) available=\(span != nil) poll=\(span?.poll ?? 0) beginNs=\(span?.begin ?? 0) endNs=\(span?.end ?? 0) durationNs=\(span?.duration ?? 0) layerReadyPredicateEvaluated=\(span?.layerReadyPredicateEvaluated ?? false) clock=DispatchTime scope=existing-operation-plus-entry-marker includesSynchronousReentrancy=true playbackAcceptance=unchanged")
                }
            }
            let gap = value.largestGap
            print("ProductionSelectionPollGap schema=1 phase=\(phase) available=\(gap != nil) nextPoll=\(gap?.poll ?? 0) bodyReturnNs=\(gap?.begin ?? 0) nextEntryNs=\(gap?.end ?? 0) durationNs=\(gap?.duration ?? 0) includes=return-marker-sleep-and-scheduling finalGapWithoutNextEntryNs=\(trailing)")
        }
    }
}
#endif

#if DEBUG
/// Boundary qualifications only. Owns the one injected buffer, no player/output
/// beyond its normal window, no tasks and no strong history of selected resources.
@MainActor
private final class PreparedRenderingSuppressionControl {
    enum Failure: Error { case qualification(Int, Int) }
    let enabled: Bool
    let nativeGeometry: Bool?
    let buffer: PlaybackBuffer
    private let aID: String, bID: String
    private let urls: [String: URL]
    private weak var aItem: AVPlayerItem?, bItem: AVPlayerItem?
    private weak var aOutput: AVPlayerItemVideoOutput?, bOutput: AVPlayerItemVideoOutput?
    private weak var aResource: ContinuousPictureInPicture.PreparedVideoResource?
    private weak var bResource: ContinuousPictureInPicture.PreparedVideoResource?
    private var visits: [Int64?] = [nil, nil, nil]
    private struct Check {
        var source = false, oneOutput = false, prepared = false, borrowed = false
        var identity = false, cppOwner = false
        var actualMode = -1, resourceMode = -1
        var geometryQualified = true, geometryValidated = false, usesNativeGeometry = false
        var compositionPresent = -1
        var geometryWidth = -1, geometryHeight = -1
        func qualifies(mode: Bool, borrowed expectedBorrow: Bool) -> Bool {
            source && oneOutput && prepared && borrowed == expectedBorrow && identity
                && actualMode == (mode ? 1 : 0) && resourceMode == (mode ? 1 : 0)
                && (!expectedBorrow || cppOwner) && geometryQualified
        }
    }
    private struct Row {
        let phase: Int, stage: Int, retained: Int
        let begin: UInt64, end: UInt64
        let selectedRequired: Bool, targetRequired: Bool
        let selected: Check, target: Check
        let allRetainedPolicies: Bool, ownerStable: Bool, audioOwner: Bool, selectedReady: Bool, mode: Bool, qualified: Bool
    }
    private var rows: [Row] = []
    private var overflow = false
    init(enabled: Bool, fixture: SelectionVideoFixture, nativeGeometry: Bool? = nil) {
        self.enabled = enabled
        self.nativeGeometry = nativeGeometry
        if let nativeGeometry { buffer = PlaybackBuffer(debugNativeGeometry: nativeGeometry) }
        else { buffer = PlaybackBuffer(debugSuppressesPlayerRendering: enabled) }
        aID = fixture.aID; bID = fixture.bID
        urls = fixture.savedURLs.mapValues { $0.standardizedFileURL }
        rows.reserveCapacity(12)
    }
    func captureLabel(phase: Int) -> String {
        if let nativeGeometry { return "native-geometry-\(nativeGeometry ? "on" : "off")-phase-\(phase)" }
        return "suppression-\(enabled ? "on" : "off")-phase-\(phase)"
    }
    private func geometryMatches(_ item: AVPlayerItem, resource: ContinuousPictureInPicture.PreparedVideoResource,
                                 actualComposition: AVVideoComposition?) -> Bool {
        guard let nativeGeometry else { return true }
        return resource.debugNativeGeometryValidated && resource.debugUsesNativeGeometry == nativeGeometry
            && (nativeGeometry ? actualComposition == nil
                : actualComposition != nil && actualComposition === resource.debugInstalledComposition)
    }
    private func rememberOrMatch(_ item: AVPlayerItem,
        resource: ContinuousPictureInPicture.PreparedVideoResource, output: AVPlayerItemVideoOutput,
        id: String, remember: Bool) -> Bool {
        if id == aID {
            if remember, aItem == nil, aResource == nil, aOutput == nil {
                aItem = item; aResource = resource; aOutput = output
            }
            return aItem === item && aResource === resource && aOutput === output
        }
        if id == bID {
            if remember, bItem == nil, bResource == nil, bOutput == nil {
                bItem = item; bResource = resource; bOutput = output
            }
            return bItem === item && bResource === resource && bOutput === output
        }
        return false
    }
    private func inspect(_ item: AVPlayerItem?, id: String, remember: Bool,
                         service: PlaybackService) -> Check {
        var result = Check()
        guard let item else { return result }
        let actualURL = (item.asset as? AVURLAsset)?.url.standardizedFileURL
        result.source = urls[id].map { actualURL == $0 } ?? false
        let outputs = item.outputs
        guard let resource = buffer.resource(for: item), let output = resource.output else { return result }
        result.oneOutput = outputs.count == 1 && outputs.first === output
        result.prepared = resource.item === item && resource.isAttached && !resource.isRetired
        result.borrowed = resource.isBorrowed
        result.actualMode = output.suppressesPlayerRendering ? 1 : 0
        result.resourceMode = resource.debugSuppressesPlayerRendering ? 1 : 0
        if nativeGeometry != nil {
            let composition = item.videoComposition
            result.compositionPresent = composition == nil ? 0 : 1
            result.geometryValidated = resource.debugNativeGeometryValidated
            result.usesNativeGeometry = resource.debugUsesNativeGeometry
            if let geometry = resource.debugNativeGeometry {
                result.geometryWidth = Int(geometry.width); result.geometryHeight = Int(geometry.height)
            }
            result.geometryQualified = geometryMatches(item, resource: resource, actualComposition: composition)
        }
        result.identity = rememberOrMatch(item, resource: resource, output: output, id: id, remember: remember)
        let owner = service.debugAlignedVideoPollState
        result.cppOwner = owner.presentationMatches && owner.observedItemMatches && owner.frame.coherent
            && owner.frame.ticket?.debugItemIdentity == ObjectIdentifier(item)
            && owner.frame.output == ObjectIdentifier(output)
        return result
    }
    func qualify(phase: Int, stage: Int, service: PlaybackService, audio: ContinuousAudioPlayer) throws {
        guard (0..<3).contains(phase), (0..<4).contains(stage), rows.count < 12 else {
            overflow = true; throw Failure.qualification(phase, stage)
        }
        let begin = DispatchTime.now().uptimeNanoseconds
        let initialAudio = audio.renderer.snapshot
        let selectedItem = service.player.currentItem
        let retained = buffer.retainedItems // Published app window, not an SDK/RSS inventory.
        let selectedRequired = phase != 0 || stage != 0
        let selectedID = stage == 0 ? (phase == 2 ? bID : aID) : (phase == 1 ? bID : aID)
        let targetRequired = stage == 0 && phase > 0
        let targetID = phase == 1 ? bID : aID
        let selected = inspect(selectedItem, id: selectedID, remember: phase == 0 && stage == 1, service: service)
        let candidates = targetRequired ? retained.filter {
            ($0.asset as? AVURLAsset)?.url.standardizedFileURL == urls[targetID]
        } : []
        let target = inspect(candidates.count == 1 ? candidates.first : nil, id: targetID,
                             remember: phase == 1 && stage == 0, service: service)
        let allRetainedPolicies = retained.allSatisfy { item in
            guard let resource = buffer.resource(for: item), let output = resource.output,
                  resource.isAttached, !resource.isRetired else { return false }
            let outputs = item.outputs
            return outputs.count == 1 && outputs.first === output
                && resource.debugSuppressesPlayerRendering == enabled
                && output.suppressesPlayerRendering == enabled
                && (nativeGeometry == nil || geometryMatches(item, resource: resource, actualComposition: item.videoComposition))
        }
        let finalAudio = audio.renderer.snapshot
        let ownerStable = service.player.currentItem === selectedItem
            && finalAudio.token == initialAudio.token && finalAudio.visit == initialAudio.visit
        let expectedToken = audio.entry(for: selectedID)?.token
        let expectedVisit = stage == 0 && phase > 0 ? visits[phase - 1] : visits[phase]
        let audioOwner = selectedRequired
            ? service.queue.currentID == selectedID && service.current?.id == selectedID
                && audio.selectedID == selectedID && expectedToken != nil && finalAudio.token == expectedToken
                && !finalAudio.ended && (stage == 1 || finalAudio.visit == expectedVisit)
            : selectedItem == nil && service.queue.currentID == nil && audio.selectedID == nil && retained.isEmpty
        let mode = service.debugUsesCurrentCustomFrameForReadiness
            && buffer.debugSuppressesPlayerRendering == enabled && service.player === buffer.player
            && buffer.debugNativeGeometry == nativeGeometry
        let selectedReady = !selectedRequired || (service.isVideoReady && !service.isLoading)
        let qualified = ownerStable && audioOwner && selectedReady && mode && retained.count <= 3 && allRetainedPolicies
            && (!selectedRequired || selected.qualifies(mode: enabled, borrowed: true))
            && (!targetRequired || (candidates.count == 1 && target.qualifies(mode: enabled, borrowed: false)))
        if qualified, stage == 1 { visits[phase] = finalAudio.visit }
        rows.append(Row(phase: phase, stage: stage, retained: retained.count,
            begin: begin, end: DispatchTime.now().uptimeNanoseconds,
            selectedRequired: selectedRequired, targetRequired: targetRequired,
            selected: selected, target: target, allRetainedPolicies: allRetainedPolicies,
            ownerStable: ownerStable, audioOwner: audioOwner, selectedReady: selectedReady, mode: mode, qualified: qualified))
        guard qualified else { throw Failure.qualification(phase, stage) }
    }
    func dumpAndAssert(setupCompleted: Bool) {
        if let nativeGeometry {
            print("PreparedNativeGeometryScope schema=1 nativeGeometry=\(nativeGeometry) suppressesPlayerRendering=\(enabled) rows=\(rows.count) capacity=12 overflow=\(overflow) setupCompleted=\(setupCompleted) currentCPPMonitor=true sdkReads=outside-original-windows fallback=unqualified eligibility=file-single-enabled-full-zero-based-track-known-geometry-only originalCaptureFreeWorkload=false captures=post-each-stream causalBenefit=unproven")
            for (ordinal, row) in rows.enumerated() {
                print("PreparedNativeGeometryQualification schema=1 ordinal=\(ordinal) phase=\(row.phase) stage=\(row.stage) beginNs=\(row.begin) endNs=\(row.end) retained=\(row.retained) selectedRequired=\(row.selectedRequired) selectedSource=\(row.selected.source) selectedOneOutput=\(row.selected.oneOutput) selectedPrepared=\(row.selected.prepared) selectedBorrowed=\(row.selected.borrowed) selectedIdentity=\(row.selected.identity) selectedCPPOwner=\(row.selected.cppOwner) selectedCompositionPresent=\(row.selected.compositionPresent) selectedActualSuppression=\(row.selected.actualMode) selectedResourceSuppression=\(row.selected.resourceMode) selectedGeometryValidated=\(row.selected.geometryValidated) selectedGeometryWidth=\(row.selected.geometryWidth) selectedGeometryHeight=\(row.selected.geometryHeight) selectedUsesNativeGeometry=\(row.selected.usesNativeGeometry) selectedGeometryQualified=\(row.selected.geometryQualified) targetRequired=\(row.targetRequired) targetSource=\(row.target.source) targetOneOutput=\(row.target.oneOutput) targetPrepared=\(row.target.prepared) targetBorrowed=\(row.target.borrowed) targetIdentity=\(row.target.identity) targetCompositionPresent=\(row.target.compositionPresent) targetActualSuppression=\(row.target.actualMode) targetResourceSuppression=\(row.target.resourceMode) targetGeometryValidated=\(row.target.geometryValidated) targetGeometryWidth=\(row.target.geometryWidth) targetGeometryHeight=\(row.target.geometryHeight) targetUsesNativeGeometry=\(row.target.usesNativeGeometry) targetGeometryQualified=\(row.target.geometryQualified) allRetainedPolicies=\(row.allRetainedPolicies) ownerStable=\(row.ownerStable) audioOwner=\(row.audioOwner) selectedReady=\(row.selectedReady) mode=\(row.mode) qualified=\(row.qualified)")
            }
        }
        if nativeGeometry == nil {
        print("PreparedRenderingSuppressionScope schema=1 suppressesPlayerRendering=\(enabled) rows=\(rows.count) capacity=12 overflow=\(overflow) setupCompleted=\(setupCompleted) currentCPPMonitor=true sdkReads=outside-original-windows fallback=unqualified retainedClaim=published-boundaries-only captures=post-each-stream originalCaptureFreeWorkload=false causalBenefit=unproven")
        }
        XCTAssertFalse(overflow); XCTAssertTrue(setupCompleted); XCTAssertEqual(rows.count, 12)
        for (ordinal, row) in rows.enumerated() {
            if nativeGeometry == nil {
            print("PreparedRenderingSuppressionQualification schema=1 ordinal=\(ordinal) phase=\(row.phase) stage=\(row.stage) beginNs=\(row.begin) endNs=\(row.end) retained=\(row.retained) selectedRequired=\(row.selectedRequired) selectedSource=\(row.selected.source) selectedOneOutput=\(row.selected.oneOutput) selectedPrepared=\(row.selected.prepared) selectedBorrowed=\(row.selected.borrowed) selectedIdentity=\(row.selected.identity) selectedCPPOwner=\(row.selected.cppOwner) selectedActualMode=\(row.selected.actualMode) selectedResourceMode=\(row.selected.resourceMode) targetRequired=\(row.targetRequired) targetSource=\(row.target.source) targetOneOutput=\(row.target.oneOutput) targetPrepared=\(row.target.prepared) targetBorrowed=\(row.target.borrowed) targetIdentity=\(row.target.identity) targetActualMode=\(row.target.actualMode) targetResourceMode=\(row.target.resourceMode) allRetainedPolicies=\(row.allRetainedPolicies) ownerStable=\(row.ownerStable) audioOwner=\(row.audioOwner) selectedReady=\(row.selectedReady) mode=\(row.mode) qualified=\(row.qualified)")
            }
            XCTAssertTrue(row.qualified)
            XCTAssertLessThanOrEqual(row.retained, 3)
            XCTAssertGreaterThanOrEqual(row.end, row.begin)
            XCTAssertEqual(row.phase, ordinal / 4); XCTAssertEqual(row.stage, ordinal % 4)
        }
    }
}

/// Test-only treatment of the retained video's entire item/output/composition history.
/// Owns no service/audio/task and creates no player other than the injected buffer.
@MainActor
private final class SelectionPreviousBundleControl {
    enum Failure: Error { case qualification(Int) }
    let fresh: Bool
    let queuedLead: Bool?
    private let queueCaptureID: String?
    let buffer = PlaybackBuffer()
    private let aID: String, bID: String, aURL: URL, bURL: URL
    private let candidate: AVPlayerItem
    private let preparation: ContinuousPictureInPicture.VideoResourcePreparation
    private weak var originalA: AVPlayerItem?
    private weak var originalResource: ContinuousPictureInPicture.PreparedVideoResource?
    private weak var originalVideoOutput: AVPlayerItemVideoOutput?
    private weak var preparedB: AVPlayerItem?
    private weak var preparedBResource: ContinuousPictureInPicture.PreparedVideoResource?
    private weak var chosenResource: ContinuousPictureInPicture.PreparedVideoResource?
    private var originalOutput: ObjectIdentifier?
    private var preparedBOutput: ObjectIdentifier?
    private var chosenOutput: ObjectIdentifier?
    private var aToken = 0, bToken = 0
    private var bVisit: Int64?, bGeneration: Int?
    private var returnedVisit: Int64?
    private var oldDetachedBeforeInstall = false
    private var chosePrevious = false
    private var queuedStaged = false
    private var queueStageAttempted = false
    private var queuedBSelection: ContinuousPCMRenderer.Snapshot?
    private var queuedStorage: [ObjectIdentifier] = []
    private var queuedMemoryBytes: Int?
    private struct Availability {
        let ordinal: Int, begin: Double, end: Double, available: Bool
    }
    private struct QueueStage {
        let begin: Double, returned: Double, qualified: Double
        let accepted: Bool, exactQueue: Bool
    }
    private struct QueueCommandReturn {
        let begin: Double, end: Double, selectedExactItemResourceOutput: Bool, queuedAConsumed: Bool
        let nextRole: Int, previousRole: Int
    }
    private var availability: [Availability] = []
    private var queueStage: QueueStage?
    private var queueCommandReturn: QueueCommandReturn?
    private var queueCommandArmed = false
    private var advanceBranchCount = 0
    private var advanceBranchOverflow = false
    private var advanceBranchKind: Int?
    private var advanceBranchItemMatches = false
    private var advanceBranchUnarmed = false
    private struct LeadEndpoint {
        let entry: UInt64, returned: UInt64, audio: ContinuousPCMRenderer.Snapshot
    }
    private weak var leadTap: ProductionSelectionOutputTap?
    private var leadTapFirst: Int?, leadTapEndpointIndex: Int?, leadTapReadbackEnd: Int?
    private var leadReadbackRepeated = false
    private var leadStartHost: Double?, leadEndHost: Double?
    private var leadStart: LeadEndpoint?, leadEnd: LeadEndpoint?
    private var leadProbe: ProductionRendererProbe?, leadResult: ProductionRendererProbe.Result?
    private var leadBeginUptime: Double?, leadDeadlineUptime: Double?, leadWakeUptime: Double?
    private var leadBeforeSleepUptime: Double?
    private var leadQuantum = 0
    private struct Row {
        let stage: Int, publishedUnionItems: Int
        let candidateDetached: Bool, originalResourceAlive: Bool
        let originalRetired: Bool, originalAttached: Bool, originalBorrowed: Bool
        let oldDetachedBeforeInstall: Bool
    }
    private var rows: [Row] = []
    private var overflow = false
    private let metadataBegin: Double, metadataEnd: Double

    init(fresh: Bool, queuedLead: Bool? = nil, aID: String, bID: String, aURL: URL, bURL: URL) async throws {
        self.fresh = fresh; self.queuedLead = queuedLead; self.aID = aID; self.bID = bID
        queueCaptureID = queuedLead.map { _ in UUID().uuidString.lowercased() }
        self.aURL = aURL.standardizedFileURL; self.bURL = bURL.standardizedFileURL
        let item = AVPlayerItem(url: aURL)
        item.preferredForwardBufferDuration = 8
        let begin = ProcessInfo.processInfo.systemUptime
        let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
        candidate = item; preparation = plan
        metadataBegin = begin; metadataEnd = ProcessInfo.processInfo.systemUptime
        rows.reserveCapacity(12)
        if queuedLead != nil { availability.reserveCapacity(2); queuedStorage.reserveCapacity(3) }
        try check(queuedLead == nil || !fresh, 60)
        try check(candidate.outputs.isEmpty && candidate.videoComposition == nil, 1)
        try check((candidate.asset as? AVURLAsset)?.url.standardizedFileURL == self.aURL, 2)
        try append(stage: 0)
        if queuedLead != nil {
            buffer.onDebugAdvanceBranch = { [weak self] route, id, item in
                self?.recordAdvanceBranch(route, mediaID: id, item: item)
            }
        }
    }

    private func check(_ valid: Bool, _ code: Int) throws {
        guard valid else { throw Failure.qualification(code) }
    }
    func beginQueuedLead(audio: ContinuousAudioPlayer, tap: ProductionSelectionOutputTap, quantum: Int) {
        guard queuedLead != nil else { return }
        let begin = ProcessInfo.processInfo.systemUptime
        leadBeginUptime = begin; leadDeadlineUptime = begin + 0.250
        leadTap = tap; leadTapFirst = tap.begin(); leadQuantum = quantum
        leadStartHost = ProductionSelectionOutputTap.hostSeconds()
        let entry = DispatchTime.now().uptimeNanoseconds
        let sample = audio.renderer.snapshot
        let returned = DispatchTime.now().uptimeNanoseconds
        leadStart = LeadEndpoint(entry: entry, returned: returned, audio: sample)
        leadProbe = ProductionRendererProbe(renderer: audio.renderer)
    }

    func waitQueuedLead() async throws {
        guard queuedLead != nil, let deadline = leadDeadlineUptime else { throw Failure.qualification(70) }
        let before = ProcessInfo.processInfo.systemUptime
        leadBeforeSleepUptime = before
        // Staging must fit inside the same common budget. Never add 250 ms after
        // ON staging, extend this deadline, or wait for additional probe samples.
        try check(before < deadline, 71)
        try await Task.sleep(for: .seconds(deadline - before))
        leadWakeUptime = ProcessInfo.processInfo.systemUptime
    }

    func finishQueuedLead(audio: ContinuousAudioPlayer) {
        guard queuedLead != nil, let probe = leadProbe else { return }
        leadProbe = nil
        leadResult = probe.stop()
        let entry = DispatchTime.now().uptimeNanoseconds
        let sample = audio.renderer.snapshot
        let returned = DispatchTime.now().uptimeNanoseconds
        leadEnd = LeadEndpoint(entry: entry, returned: returned, audio: sample)
        leadEndHost = ProductionSelectionOutputTap.hostSeconds()
        // Preserve the original tap's enabled state across its timed command.
        // count is only the endpoint into the same fixed 12-second PCM storage.
        leadTapEndpointIndex = leadTap?.count
    }

    func completeQueuedLeadReadback(last: Int) {
        guard queuedLead != nil else { return }
        // The ordinary measured phase has already returned; retain its existing
        // callback endpoint only. No extra capture, wait, query or PCM is added.
        guard leadTapReadbackEnd == nil else { leadReadbackRepeated = true; return }
        leadTapReadbackEnd = last
    }
    var returnedCaptureLabel: String {
        if let queuedLead, let queueCaptureID {
            return "previous-queue-lead-\(queuedLead ? "on" : "off")-\(queueCaptureID)-returned-A"
        }
        return "previous-bundle-\(fresh ? "fresh" : "retained")-returned-A"
    }
    private func append(stage: Int) throws {
        // This is explicitly a published-boundary union, not a count of SDK-held
        // or unpublished service-local/in-flight items and not a process RSS bound.
        let count = Set((buffer.retainedItems + [candidate]).map(ObjectIdentifier.init)).count
        guard rows.count < 12 else { overflow = true; throw Failure.qualification(3) }
        let old = originalResource
        rows.append(Row(stage: stage, publishedUnionItems: count,
            candidateDetached: candidate.outputs.isEmpty,
            originalResourceAlive: old != nil, originalRetired: old?.isRetired == true,
            originalAttached: old?.isAttached == true, originalBorrowed: old?.isBorrowed == true,
            oldDetachedBeforeInstall: oldDetachedBeforeInstall))
        try check(count > 0 && count <= 3, 4)
    }
    private func itemURLMatches(_ item: AVPlayerItem?, _ url: URL) -> Bool {
        (item?.asset as? AVURLAsset)?.url.standardizedFileURL == url
    }
    private func candidateIsMetadataOnly() -> Bool {
        candidate.outputs.isEmpty && candidate.videoComposition == nil
    }
    private func selectedOwner(_ service: PlaybackService, audio: ContinuousAudioPlayer,
                               item: AVPlayerItem, id: String, url: URL, token: Int) -> Bool {
        let sample = audio.renderer.snapshot
        return service.player === buffer.player && service.player.currentItem === item
            && service.queue.repeatMode == .off && service.queue.currentID == id && service.current?.id == id
            && itemURLMatches(item, url) && audio.selectedID == id && audio.entry(for: id)?.token == token
            && sample.token == token && token > 0 && !sample.ended && !audio.isSelectionPending(in: sample)
            && service.preparedAudioCount == 2 && service.wantsToPlay && service.audioEngineRunning
            && service.isVideoReady && !service.isLoading && sample.underrunFrames == 0
    }
    private func oldPreviousMatches() -> Bool {
        guard let old = originalA, let resource = originalResource, let output = resource.output else { return false }
        if queuedLead != nil {
            let position = old.currentTime().seconds
            guard old.status == .readyToPlay && position.isFinite && abs(position) < 0.005 else { return false }
        }
        return old !== candidate && itemURLMatches(old, aURL)
            && buffer.previousMediaID == aID && buffer.debugPreviousNeedsRewind == false
            && buffer.resource(for: old) === resource && resource.item === old
            && resource.isAttached && !resource.isBorrowed && !resource.isRetired
            && ObjectIdentifier(output) == originalOutput && old.outputs.contains { $0 === output }
    }
    private func bOwnerMatches(_ service: PlaybackService, audio: ContinuousAudioPlayer,
                               screen: SelectionVideoScreen, requireSnapshot: Bool) -> Bool {
        guard let item = preparedB, let resource = preparedBResource,
              let output = resource.output else { return false }
        let state = service.debugInitialVideoReadyState, sample = audio.renderer.snapshot
        let queue = buffer.player.items()
        return selectedOwner(service, audio: audio, item: item, id: bID, url: bURL, token: bToken)
            && buffer.resource(for: item) === resource && resource.item === item
            && resource.isAttached && resource.isBorrowed && !resource.isRetired
            && ObjectIdentifier(output) == preparedBOutput && item.outputs.contains { $0 === output }
            && audio.entry(for: aID)?.token == aToken && aToken > 0 && aToken != bToken
            && (queuedLead == nil
                ? (queue.count == 1 && queue.first === item && buffer.nextMediaID == nil && !buffer.hasPrepared(aID))
                : queuedBLayoutMatches(queue, current: item))
            && !buffer.hasLoopReserve
            && state.readyGeneration == state.generation && state.audioVisit == sample.visit
            && state.syncingVideoGeneration == nil && screen.customVideoLayer?.isReadyForDisplay == true
            && (!requireSnapshot || (state.generation == bGeneration && sample.visit == bVisit))
            && (queuedLead == nil || (item.outputs.count == 1 && item.outputs.first === output
                && queuedStorageMatches(audio, sample: sample, requireSnapshot: requireSnapshot)))
    }

    private func queuedBLayoutMatches(_ items: [AVPlayerItem], current: AVPlayerItem) -> Bool {
        if queuedStaged {
            return items.count == 2 && items.first === current && items.last === originalA
                && buffer.nextMediaID == aID && buffer.hasPrepared(aID)
        }
        return items.count == 1 && items.first === current && buffer.nextMediaID == nil && !buffer.hasPrepared(aID)
    }

    private func recordAdvanceBranch(_ route: PlaybackBuffer.DebugAdvanceRoute,
                                     mediaID: String, item: ObjectIdentifier) {
        guard mediaID == aID else { return }
        guard advanceBranchCount == 0 else { advanceBranchOverflow = true; return }
        advanceBranchCount = 1
        advanceBranchKind = route.rawValue
        advanceBranchItemMatches = originalA.map { ObjectIdentifier($0) == item } == true
        advanceBranchUnarmed = !queueCommandArmed
    }

    private func queuedStorageMatches(_ audio: ContinuousAudioPlayer, sample: ContinuousPCMRenderer.Snapshot,
                                      requireSnapshot: Bool) -> Bool {
        guard queuedStorage.count == 3, queuedMemoryBytes == 6_912_000,
              audio.renderer.retainedPCMMemoryBytes == queuedMemoryBytes,
              queuedStorage == (0..<3).map({ ObjectIdentifier(audio.renderer.source(at: $0)) }) else { return false }
        guard requireSnapshot else { return true }
        guard let baseline = queuedBSelection else { return false }
        return sample.token == baseline.token && sample.visit == baseline.visit
            && sample.selectionVersion == baseline.selectionVersion && sample.frame >= baseline.frame
            && sample.underrunFrames == baseline.underrunFrames
    }

    private func observeAvailability(_ ordinal: Int) throws {
        guard queuedLead != nil, availability.count == ordinal, ordinal < 2,
              let old = originalA, let resource = originalResource, let output = resource.output,
              resource.item === old, resource === chosenResource, resource.isAttached,
              !resource.isRetired, !resource.isBorrowed, ObjectIdentifier(output) == originalOutput,
              old.outputs.count == 1, old.outputs.first === output else { throw Failure.qualification(61) }
        let begin = ProcessInfo.processInfo.systemUptime
        let available = output.hasNewPixelBuffer(forItemTime: .zero)
        let end = ProcessInfo.processInfo.systemUptime
        availability.append(Availability(ordinal: ordinal, begin: begin, end: end, available: available))
    }

    private func stageRetainedPrevious(service: PlaybackService, audio: ContinuousAudioPlayer,
                                       screen: SelectionVideoScreen) throws {
        // This entire OFF call is inside the original command origin. No print or
        // XCTest assertion occurs here; refusal throws before issuing Previous.
        guard queuedLead != nil, !queueStageAttempted, chosePrevious,
              let old = originalA, let resource = originalResource,
              preparedB != nil, bOwnerMatches(service, audio: audio, screen: screen, requireSnapshot: true),
              oldPreviousMatches(), candidateIsMetadataOnly() else { throw Failure.qualification(62) }
        queueStageAttempted = true
        let begin = ProcessInfo.processInfo.systemUptime
        let accepted = buffer.stage(.init(mediaID: aID, item: old, isLocal: true, videoResource: resource),
            after: bID, ifEligible: { [self] in
                bOwnerMatches(service, audio: audio, screen: screen, requireSnapshot: true)
                    && oldPreviousMatches() && !queuedStaged
            })
        let returned = ProcessInfo.processInfo.systemUptime
        queuedStaged = accepted
        let exactQueue = accepted && bOwnerMatches(service, audio: audio, screen: screen, requireSnapshot: true)
            && oldPreviousMatches() && old.outputs.count == 1
            && resource === chosenResource && resource.output.map(ObjectIdentifier.init) == chosenOutput
        let qualified = ProcessInfo.processInfo.systemUptime
        queueStage = QueueStage(begin: begin, returned: returned, qualified: qualified,
                                accepted: accepted, exactQueue: exactQueue)
        try check(exactQueue, 63)
    }

    func stageAtPreviousCommand(service: PlaybackService, audio: ContinuousAudioPlayer,
                                screen: SelectionVideoScreen) throws {
        guard let queuedLead else { return }
        guard availability.count == 2 else { throw Failure.qualification(64) }
        if !queuedLead { try stageRetainedPrevious(service: service, audio: audio, screen: screen) }
        else {
            // Recheck after the original baseline/origin reads. Staging or a warmer
            // must never silently change the queued route before this command.
            try check(queuedStaged && queueStage?.exactQueue == true
                && bOwnerMatches(service, audio: audio, screen: screen, requireSnapshot: true)
                && oldPreviousMatches(), 65)
        }
        try check(advanceBranchCount == 0 && !advanceBranchOverflow, 69)
        queueCommandArmed = true
    }

    func qualifyQueuedCommandReturn(service: PlaybackService, audio: ContinuousAudioPlayer) throws {
        guard queuedLead != nil else { return }
        defer { queueCommandArmed = false }
        let begin = ProcessInfo.processInfo.systemUptime
        guard queueCommandReturn == nil, let old = originalA, let resource = originalResource,
              let output = originalVideoOutput else { throw Failure.qualification(67) }
        // Synchronous item/adoption outcome only: real PCM acknowledgement, CPP
        // readiness, borrowed state and pixels remain the original later oracles.
        let exact = service.player === buffer.player && service.player.currentItem === old
            && service.queue.currentID == aID && service.current?.id == aID && audio.selectedID == aID
            && buffer.resource(for: old) === resource && resource === chosenResource
            && resource.item === old && resource.isAttached && !resource.isRetired
            && resource.output === output && old.outputs.count == 1 && old.outputs.first === output
        let postNext = buffer.nextMediaID, postPrevious = buffer.previousMediaID
        let consumed = postNext != aID && !buffer.hasPrepared(aID)
        func role(_ id: String?) -> Int { id == nil ? 0 : (id == aID ? 1 : (id == bID ? 2 : 3)) }
        let end = ProcessInfo.processInfo.systemUptime
        queueCommandReturn = QueueCommandReturn(begin: begin, end: end,
            selectedExactItemResourceOutput: exact, queuedAConsumed: consumed,
            nextRole: role(postNext), previousRole: role(postPrevious))
        try check(exact && consumed && advanceBranchCount == 1 && !advanceBranchOverflow
            && advanceBranchKind == PlaybackBuffer.DebugAdvanceRoute.queuedAdvance.rawValue
            && advanceBranchItemMatches && !advanceBranchUnarmed, 68)
    }

    func canReplacePrevious(service: PlaybackService, audio: ContinuousAudioPlayer,
                            screen: SelectionVideoScreen) -> Bool {
        !chosePrevious && candidateIsMetadataOnly() && oldPreviousMatches()
            && bOwnerMatches(service, audio: audio, screen: screen, requireSnapshot: false)
    }

    func choosePrevious(service: PlaybackService, audio: ContinuousAudioPlayer,
                        screen: SelectionVideoScreen) throws {
        try check(canReplacePrevious(service: service, audio: audio, screen: screen), 21)
        bVisit = audio.renderer.snapshot.visit
        bGeneration = service.debugInitialVideoReadyState.generation
        if queuedLead != nil { queuedBSelection = audio.renderer.snapshot }
        try append(stage: 4)
        if fresh {
            // The only strong old references are scoped to this verification block;
            // they end BEFORE the fresh resource is installed. SDK retention is
            // neither observed nor claimed to have quiesced.
            oldDetachedBeforeInstall = try {
                let old = try XCTUnwrap(originalA), resource = try XCTUnwrap(originalResource)
                let oldOutput = try XCTUnwrap(originalOutput)
                buffer.discardPrevious()
                try check(resource.isRetired && !resource.isAttached && !resource.isBorrowed
                    && resource.output == nil && !old.outputs.contains { ObjectIdentifier($0) == oldOutput }
                    && buffer.previousMediaID == nil, 22)
                return true
            }()
            try check(oldDetachedBeforeInstall && candidateIsMetadataOnly(), 23)
            let staged = buffer.stagePrevious(.init(mediaID: aID, item: candidate, isLocal: true),
                videoPreparation: preparation, ifEligible: { [self] in
                    bOwnerMatches(service, audio: audio, screen: screen, requireSnapshot: true)
                        && buffer.previousMediaID == nil
                })
            try check(staged, 24)
            let resource = try XCTUnwrap(buffer.resource(for: candidate))
            let output = try XCTUnwrap(resource.output)
            // A retired output's address may be reused after deallocation; compare
            // live weak witnesses rather than treating an old address as unique.
            try check(resource.item === candidate && resource.isAttached && !resource.isRetired
                && !resource.isBorrowed && resource !== originalResource && output !== originalVideoOutput
                && candidate.outputs.contains { $0 === output }, 25)
            chosenResource = resource; chosenOutput = ObjectIdentifier(output)
        } else {
            try check(oldPreviousMatches() && candidateIsMetadataOnly(), 26)
            chosenResource = originalResource; chosenOutput = originalOutput
        }
        chosePrevious = true
        try append(stage: 5)
        if let queuedLead {
            try observeAvailability(0)
            if queuedLead { try stageRetainedPrevious(service: service, audio: audio, screen: screen) }
        }
    }

    func qualifyBeforeCommand(phase: Int, service: PlaybackService, audio: ContinuousAudioPlayer,
                              screen: SelectionVideoScreen) throws {
        switch phase {
        case 0:
            try check(service.player === buffer.player && buffer.retainedItems.isEmpty
                && candidateIsMetadataOnly() && !chosePrevious, 30)
            try append(stage: 1)
        case 1:
            guard let old = originalA, let resource = originalResource, let queued = preparedB else {
                throw Failure.qualification(31)
            }
            let items = buffer.player.items()
            try check(selectedOwner(service, audio: audio, item: old, id: aID, url: aURL, token: aToken)
                && buffer.resource(for: old) === resource && resource.isBorrowed
                && resource.output.map(ObjectIdentifier.init) == originalOutput
                && items.count == 2 && items.first === old && items.last === queued
                && buffer.hasPrepared(bID) && buffer.nextMediaID == bID && !buffer.hasLoopReserve
                && candidateIsMetadataOnly() && audio.entry(for: bID)?.token == bToken, 32)
            try append(stage: 3)
        case 2:
            guard chosePrevious, let item = fresh ? candidate : originalA,
                  let resource = chosenResource, let output = resource.output else {
                throw Failure.qualification(33)
            }
            try check(bOwnerMatches(service, audio: audio, screen: screen, requireSnapshot: true)
                && buffer.previousMediaID == aID && buffer.debugPreviousNeedsRewind == false
                && buffer.resource(for: item) === resource && resource.item === item
                && resource.isAttached && !resource.isBorrowed && !resource.isRetired
                && ObjectIdentifier(output) == chosenOutput && item.outputs.contains { $0 === output }
                && (fresh ? oldDetachedBeforeInstall : (oldPreviousMatches() && candidateIsMetadataOnly())), 34)
            if queuedLead != nil { try observeAvailability(1) }
            try append(stage: 6)
            finishQueuedLead(audio: audio)
        default: throw Failure.qualification(35)
        }
    }

    func completedPhase(_ phase: Int, service: PlaybackService, audio: ContinuousAudioPlayer) throws {
        if phase == 0 {
            let items = buffer.player.items()
            try check(items.count == 2 && buffer.hasPrepared(bID) && !buffer.hasLoopReserve, 40)
            let old = try XCTUnwrap(items.first), queued = try XCTUnwrap(items.last)
            let resource = try XCTUnwrap(buffer.resource(for: old))
            let output = try XCTUnwrap(resource.output)
            let queuedResource = try XCTUnwrap(buffer.resource(for: queued))
            let queuedOutput = try XCTUnwrap(queuedResource.output)
            aToken = try XCTUnwrap(audio.entry(for: aID)).token
            bToken = try XCTUnwrap(audio.entry(for: bID)).token
            try check(old !== candidate && old !== queued && itemURLMatches(old, aURL)
                && itemURLMatches(queued, bURL) && resource.item === old && resource.isBorrowed
                && resource.isAttached && !resource.isRetired && candidateIsMetadataOnly()
                && queuedResource.item === queued && queuedResource.isAttached
                && !queuedResource.isBorrowed && !queuedResource.isRetired
                && selectedOwner(service, audio: audio, item: old, id: aID, url: aURL, token: aToken), 41)
            originalA = old; originalResource = resource; originalOutput = ObjectIdentifier(output)
            originalVideoOutput = output
            preparedB = queued; preparedBResource = queuedResource
            preparedBOutput = ObjectIdentifier(queuedOutput)
            if queuedLead != nil {
                queuedStorage = (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }
                queuedMemoryBytes = audio.renderer.retainedPCMMemoryBytes
            }
            try append(stage: 2)
        } else if phase == 2 {
            try qualifyReturnedA(service: service, audio: audio, stage: 7)
        }
    }

    func qualifyReturnedA(service: PlaybackService, audio: ContinuousAudioPlayer, stage: Int) throws {
        guard chosePrevious, let item = fresh ? candidate : originalA,
              let resource = chosenResource, let output = resource.output, let bVisit else {
            throw Failure.qualification(50)
        }
        let sample = audio.renderer.snapshot
        try check(selectedOwner(service, audio: audio, item: item, id: aID, url: aURL, token: aToken)
            && sample.visit > bVisit && audio.entry(for: bID)?.token == bToken
            && buffer.resource(for: item) === resource && resource.item === item
            && resource.isBorrowed && resource.isAttached && !resource.isRetired
            && ObjectIdentifier(output) == chosenOutput && item.outputs.contains { $0 === output }
            && (fresh ? oldDetachedBeforeInstall : candidateIsMetadataOnly()), 51)
        if let returnedVisit { try check(sample.visit == returnedVisit, 52) }
        else { returnedVisit = sample.visit }
        if queuedLead != nil {
            try check(queuedStaged && queueStage?.exactQueue == true && item === originalA
                && resource === originalResource && output === originalVideoOutput
                && queueCommandReturn?.selectedExactItemResourceOutput == true
                && queueCommandReturn?.queuedAConsumed == true
                && queuedStorageMatches(audio, sample: sample, requireSnapshot: false), 66)
        }
        try append(stage: stage)
    }

    private func dumpQueuedLead() {
        guard let queuedLead else { return }
        guard let begin = leadBeginUptime, let deadline = leadDeadlineUptime,
              let beforeSleep = leadBeforeSleepUptime, let wake = leadWakeUptime,
              let start = leadStart, let end = leadEnd, let result = leadResult,
              let startHost = leadStartHost, let endHost = leadEndHost,
              let tap = leadTap, let first = leadTapFirst, let endpointIndex = leadTapEndpointIndex,
              let readbackEnd = leadTapReadbackEnd else {
            print("PreviousQueueLeadWindow schema=2 queuedPreviousLead=\(queuedLead) available=false beginUptime=\(leadBeginUptime.map { String($0) } ?? "unavailable") deadlineUptime=\(leadDeadlineUptime.map { String($0) } ?? "unavailable") beforeSleepUptime=\(leadBeforeSleepUptime.map { String($0) } ?? "unavailable") wakeUptime=\(leadWakeUptime.map { String($0) } ?? "unavailable") startEndpointPresent=\(leadStart != nil) endEndpointPresent=\(leadEnd != nil) probeResultPresent=\(leadResult != nil) leadStartHost=\(leadStartHost.map { String($0) } ?? "unavailable") leadEndHost=\(leadEndHost.map { String($0) } ?? "unavailable") tapFirstIndex=\(leadTapFirst.map { String($0) } ?? "unavailable") tapEndpointIndex=\(leadTapEndpointIndex.map { String($0) } ?? "unavailable") tapReadbackEnd=\(leadTapReadbackEnd.map { String($0) } ?? "unavailable") scope=whole-precommand-B-lead publication=after-cleanup")
            XCTFail("The queued-Previous B lead must have complete bounded evidence")
            return
        }
        guard start.entry <= start.returned, start.returned <= end.entry, end.entry <= end.returned,
              result.samples.allSatisfy({ $0.begin >= start.returned && $0.end >= $0.begin && $0.end <= end.entry }) else {
            XCTFail("Lead endpoint/probe clock ordering is invalid"); return
        }
        let recorded = tap.samples(from: first, to: readbackEnd)
        let validity = tap.validity()
        guard recorded.rate.isFinite, recorded.rate > 0, recorded.values.count == recorded.hosts.count,
              startHost.isFinite, endHost.isFinite, startHost < endHost,
              first >= 0, first <= endpointIndex, endpointIndex <= readbackEnd, readbackEnd <= tap.count,
              recorded.values.count == readbackEnd - first, !recorded.values.isEmpty,
              recorded.values.allSatisfy({ $0.isFinite }), recorded.hosts.allSatisfy({ $0.isFinite }),
              !leadReadbackRepeated, validity.invalidTimestamps == 0, validity.droppedFrames == 0 else {
            print("PreviousQueueLeadTapReadback schema=2 queuedPreviousLead=\(queuedLead) available=false reasonCode=1 tapFirstIndex=\(first) tapEndpointIndex=\(endpointIndex) tapReadbackEnd=\(readbackEnd) rawFrames=\(recorded.values.count) rawHosts=\(recorded.hosts.count) invalidTimestamps=\(validity.invalidTimestamps) droppedFrames=\(validity.droppedFrames) repeatedReadback=\(leadReadbackRepeated) publication=after-cleanup")
            XCTFail("The whole B lead tap recording is unavailable"); return
        }
        let samples = result.samples
        let wall = Double(end.returned - start.returned) / 1_000_000_000
        let pcm = Double(end.audio.frame - start.audio.frame) / 48_000
        let tolerance = 2 * Double(max(1, leadQuantum)) / 48_000 + 0.005
        let endpointAcquisitions: [Double] = [start, end].map { endpoint in
            let span: UInt64 = endpoint.returned - endpoint.entry
            return Double(span) / 1_000_000_000.0
        }
        let probeAcquisitions: [Double] = samples.map { sample in
            let span: UInt64 = sample.end - sample.begin
            return Double(span) / 1_000_000_000.0
        }
        let acquisition: Double = (endpointAcquisitions + probeAcquisitions).max() ?? Double.infinity
        let innerGaps = zip(samples, samples.dropFirst()).map { before, after in Double(after.end - before.end) / 1_000_000_000 }
        let edgeGaps = [samples.first.map { Double($0.end - start.returned) / 1_000_000_000 } ?? .infinity,
                       samples.last.map { Double(end.returned - $0.end) / 1_000_000_000 } ?? .infinity]
        let maximumGap = (innerGaps + edgeGaps).max() ?? .infinity
        let represented = samples.first.flatMap { first in samples.last.map { Double($0.end - first.end) / 1_000_000_000 } } ?? -1
        let skew = zip(samples, samples.dropFirst()).map { before, after in
            abs(Double(after.audio.frame - before.audio.frame) / 48_000 - Double(after.end - before.end) / 1_000_000_000)
        }.max() ?? .infinity
        print("PreviousQueueLeadWindow schema=2 queuedPreviousLead=\(queuedLead) available=true beginUptime=\(begin) deadlineUptime=\(deadline) beforeSleepUptime=\(beforeSleep) wakeUptime=\(wake) stageDwellBudgetMs=250 wakeOvershootMs=\((wake - deadline) * 1000) endpointStartEntryNs=\(start.entry) endpointStartReturnNs=\(start.returned) endpointEndEntryNs=\(end.entry) endpointEndReturnNs=\(end.returned) fullLeadWallSeconds=\(wall) pcmSeconds=\(pcm) toleranceMs=\(tolerance * 1000) samples=\(samples.count) representedSeconds=\(represented) maximumGapMs=\(maximumGap * 1000) maximumAcquisitionMs=\(acquisition * 1000) maximumSkewMs=\(skew * 1000) dropped=\(result.dropped) acquisitionOutstanding=\(result.acquisitionOutstanding) firstToken=\(start.audio.token) finalToken=\(end.audio.token) firstVisit=\(start.audio.visit) finalVisit=\(end.audio.visit) firstSelectionVersion=\(start.audio.selectionVersion) finalSelectionVersion=\(end.audio.selectionVersion) firstFrame=\(start.audio.frame) finalFrame=\(end.audio.frame) firstUnderruns=\(start.audio.underrunFrames) finalUnderruns=\(end.audio.underrunFrames) scope=common-250ms-deadline-plus-original-120ms-lead-and-returned-query-spans noExtensionForSamples=true tapProof=separate-host-domain-row physicalOutputProof=false publication=after-cleanup")
        for sample in samples.prefix(8) {
            print("PreviousQueueLeadRenderSample schema=1 queuedPreviousLead=\(queuedLead) beginNs=\(sample.begin) endNs=\(sample.end) token=\(sample.audio.token) visit=\(sample.audio.visit) selectionVersion=\(sample.audio.selectionVersion) frame=\(sample.audio.frame) ended=\(sample.audio.ended) underrunFrames=\(sample.audio.underrunFrames)")
        }
        XCTAssertLessThan(beforeSleep, deadline); XCTAssertGreaterThanOrEqual(wake, deadline)
        XCTAssertGreaterThanOrEqual(wall, 0.25); XCTAssertGreaterThan(leadQuantum, 0)
        XCTAssertGreaterThanOrEqual(samples.count, 2); XCTAssertLessThanOrEqual(samples.count, 8)
        XCTAssertGreaterThan(represented, 0.15); XCTAssertLessThanOrEqual(maximumGap, 0.25)
        XCTAssertLessThanOrEqual(acquisition, 0.005); XCTAssertEqual(result.dropped, 0)
        XCTAssertFalse(result.acquisitionOutstanding)
        XCTAssertEqual(start.audio.token, bToken); XCTAssertEqual(start.audio.visit, bVisit)
        XCTAssertEqual(end.audio.token, start.audio.token); XCTAssertEqual(end.audio.visit, start.audio.visit)
        XCTAssertEqual(end.audio.selectionVersion, start.audio.selectionVersion)
        XCTAssertFalse(start.audio.ended); XCTAssertFalse(end.audio.ended)
        XCTAssertEqual(start.audio.underrunFrames, 0); XCTAssertEqual(end.audio.underrunFrames, 0)
        XCTAssertTrue(samples.allSatisfy { $0.audio.token == bToken && $0.audio.visit == start.audio.visit
            && $0.audio.selectionVersion == start.audio.selectionVersion && !$0.audio.ended
            && $0.audio.underrunFrames == 0 && $0.audio.frame >= start.audio.frame && $0.audio.frame <= end.audio.frame })
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { before, after in after.audio.frame >= before.audio.frame })
        XCTAssertGreaterThan(pcm, 0.15); XCTAssertEqual(pcm, wall, accuracy: tolerance)
        XCTAssertLessThanOrEqual(skew, tolerance)
        // Host-time selection is a readback of synthetic measurement frames, not
        // media trimming. Whole callback buffers are allowed at both raw edges.
        let sampleSeconds = 1 / recorded.rate
        let rawFirstHost = recorded.hosts[0], rawLastHost = recorded.hosts[recorded.hosts.count - 1]
        let ordered = zip(recorded.hosts, recorded.hosts.dropFirst()).allSatisfy { before, after in after > before }
        let gridErrorFrames = recorded.hosts.enumerated().reduce(0.0) { maximum, value in
            max(maximum, abs((value.element - rawFirstHost) * recorded.rate - Double(value.offset)))
        }
        let rawHole = ProductionSelectionOutputTap.maximumTimelineHole(recorded.hosts, rate: recorded.rate)
        let covered = rawFirstHost <= startHost && rawLastHost + sampleSeconds >= endHost
        print("PreviousQueueLeadTapReadback schema=2 queuedPreviousLead=\(queuedLead) available=true rawCoverage=\(covered) ordered=\(ordered) rawFrameGridError=\(gridErrorFrames) rawMaximumHoleSeconds=\(rawHole) tapFirstIndex=\(first) tapEndpointIndex=\(endpointIndex) tapReadbackEnd=\(readbackEnd) rawFrames=\(recorded.values.count) rate=\(recorded.rate) rawFirstHost=\(rawFirstHost) rawLastHost=\(rawLastHost) rawEndHostExclusive=\(rawLastHost + sampleSeconds) leadStartHost=\(startHost) leadEndHost=\(endHost) hostIntervalSeconds=\(endHost - startHost) invalidTimestamps=\(validity.invalidTimestamps) droppedFrames=\(validity.droppedFrames) readbackSource=existing-phase2-measurement-last extraWaits=0 extraCaptures=0 hostToDispatchArithmetic=false runtimeSourceFrameJoin=false publication=after-cleanup")
        guard ordered, covered, gridErrorFrames <= 0.5, rawHole <= 0.5 / recorded.rate,
              let lower = recorded.hosts.firstIndex(where: { $0 >= startHost }) else {
            XCTFail("Existing phase-2 tap callbacks do not qualify full host-domain B lead coverage"); return
        }
        let upper = recorded.hosts.firstIndex(where: { $0 >= endHost }) ?? recorded.hosts.count
        guard lower < upper else { XCTFail("No complete host-domain B lead interval is available"); return }
        let selectedValues = Array(recorded.values[lower..<upper])
        let selectedHosts = Array(recorded.hosts[lower..<upper])
        let selectedFirst = selectedHosts[0], selectedLast = selectedHosts[selectedHosts.count - 1]
        let firstOffsetFrames = (selectedFirst - startHost) * recorded.rate
        let endOvershootFrames = (selectedLast + sampleSeconds - endHost) * recorded.rate
        let expectedFrames = (endHost - startHost) * recorded.rate
        let countErrorFrames = abs(Double(selectedValues.count) - expectedFrames)
        let tone = ProductionSelectionOutputTap.toneBlocks(selectedValues, rate: recorded.rate, frequency: 880)
        let quiet = ProductionSelectionOutputTap.quietRun(selectedValues, rate: recorded.rate)
        let hole = ProductionSelectionOutputTap.maximumTimelineHole(selectedHosts, rate: recorded.rate)
        print("PreviousQueueLeadTapSelection schema=2 queuedPreviousLead=\(queuedLead) available=true firstIndex=\(first + lower) endIndex=\(first + upper) frames=\(selectedValues.count) expectedHostFrames=\(expectedFrames) countErrorFrames=\(countErrorFrames) firstHost=\(selectedFirst) lastHost=\(selectedLast) endHostExclusive=\(selectedLast + sampleSeconds) firstOffsetFrames=\(firstOffsetFrames) endOvershootFrames=\(endOvershootFrames) correctToneBlocks=\(tone.correct) totalToneBlocks=\(tone.total) quietSeconds=\(quiet) maximumTimelineHoleSeconds=\(hole) selection=actual-tap-hosts-in-fixed-lead-interval sourceMediaTrim=false physicalOutputProof=false runtimeSourceFrameJoin=false publication=after-cleanup")
        XCTAssertTrue(selectedHosts.allSatisfy { $0 >= startHost && $0 < endHost })
        XCTAssertGreaterThanOrEqual(firstOffsetFrames, 0); XCTAssertLessThanOrEqual(firstOffsetFrames, 1)
        XCTAssertGreaterThanOrEqual(endOvershootFrames, 0); XCTAssertLessThanOrEqual(endOvershootFrames, 1)
        XCTAssertLessThanOrEqual(countErrorFrames, 1)
        XCTAssertGreaterThan(Double(selectedValues.count) / recorded.rate, 0.15)
        XCTAssertEqual(quiet, 0); XCTAssertGreaterThan(tone.total, 0); XCTAssertEqual(tone.correct, tone.total)
        XCTAssertLessThanOrEqual(hole, 0.5 / recorded.rate)
    }

    func dump(setupCompleted: Bool) {
        if let queuedLead {
            buffer.onDebugAdvanceBranch = nil
            dumpQueuedLead()
            print("PreviousQueueLeadScope schema=1 queuedPreviousLead=\(queuedLead) captureID=\(queueCaptureID ?? "unavailable") captureLabel=\(returnedCaptureLabel) setupCompleted=\(setupCompleted) fixedSetupLeadMs=250 existingPreparedLeadMs=120 staging=\(queuedLead ? "before-fixed-lead" : "inside-original-command") adoptionRoute=actual-queued-branch-required sameRetainedItemResourceOutput=true extraPlayers=0 copiesBeforePrevious=0 availabilityReads=\(availability.count) availabilityCapacity=2 stageAttempts=\(queueStageAttempted ? 1 : 0) stageAccepted=\(queueStage?.accepted == true) exactQueuedBA=\(queueStage?.exactQueue == true) readScope=no-copy-hasNew-at-zero sdkReadSideEffects=unverified publication=after-owned-cleanup nilMode=unchanged relativeBenefit=not-decoder-proof acceptance=unchanged")
            print("PreviousQueueLeadBranch schema=1 queuedPreviousLead=\(queuedLead) count=\(advanceBranchCount) capacity=1 overflow=\(advanceBranchOverflow) routeCode=\(advanceBranchKind.map { String($0) } ?? "unavailable") itemMatches=\(advanceBranchItemMatches) unarmed=\(advanceBranchUnarmed) observedBoundary=after-existing-branch-guard-before-mutation sdkReturnOutcome=separate callbackGetters=0 callbackClocks=0 callbackPrinting=0")
            for value in availability {
                print("PreviousQueueLeadAvailability schema=1 queuedPreviousLead=\(queuedLead) ordinal=\(value.ordinal) beginUptime=\(value.begin) returnUptime=\(value.end) durationMs=\((value.end - value.begin) * 1000) available=\(value.available) negativeMeaning=inconclusive consumed=false itemResourceOutput=retained-rewound")
            }
            if let value = queueStage {
                print("PreviousQueueLeadStage schema=1 queuedPreviousLead=\(queuedLead) beginUptime=\(value.begin) returnUptime=\(value.returned) qualifiedUptime=\(value.qualified) stageMs=\((value.returned - value.begin) * 1000) postQualificationMs=\((value.qualified - value.returned) * 1000) accepted=\(value.accepted) exactQueuedBA=\(value.exactQueue) withinMeasuredCommand=\(!queuedLead) stageQualificationCost=included-no-observer printsDuringCommand=0")
            }
            if let value = queueCommandReturn {
                print("PreviousQueueLeadCommandReturn schema=1 queuedPreviousLead=\(queuedLead) beginUptime=\(value.begin) returnUptime=\(value.end) durationMs=\((value.end - value.begin) * 1000) selectedExactItemResourceOutput=\(value.selectedExactItemResourceOutput) queuedAConsumed=\(value.queuedAConsumed) nextRole=\(value.nextRole) previousRole=\(value.previousRole) roleCodes=absent0-A1-B2-other3 withinMeasuredCommand=true previousSlotReconciledByService=true actualPCMAndCPPProof=original-later-oracles")
            }
            XCTAssertLessThanOrEqual(availability.count, 2)
            if setupCompleted {
                XCTAssertEqual(availability.map(\.ordinal), [0, 1]); XCTAssertTrue(queueStageAttempted)
                XCTAssertTrue(queuedStaged); XCTAssertEqual(queueStage?.accepted, true)
                XCTAssertEqual(queueStage?.exactQueue, true)
                XCTAssertEqual(queueCommandReturn?.selectedExactItemResourceOutput, true)
                XCTAssertEqual(queueCommandReturn?.queuedAConsumed, true)
                XCTAssertEqual(advanceBranchCount, 1); XCTAssertFalse(advanceBranchOverflow)
                XCTAssertEqual(advanceBranchKind, PlaybackBuffer.DebugAdvanceRoute.queuedAdvance.rawValue)
                XCTAssertTrue(advanceBranchItemMatches); XCTAssertFalse(advanceBranchUnarmed)
            }
        }
        print("PreviousBundleScope schema=1 fresh=\(fresh) setupCompleted=\(setupCompleted) metadataJoined=true metadataMs=\((metadataEnd - metadataBegin) * 1000) extraPlayers=0 customTasks=0 traceVideoSeeks=false fixedSetupLeadMs=250 existingPreparedLeadMs=120 aToken=\(aToken) bToken=\(bToken) bVisit=\(bVisit.map { String($0) } ?? "unavailable") bGeneration=\(bGeneration.map { String($0) } ?? "unavailable") returnedVisit=\(returnedVisit.map { String($0) } ?? "unavailable") rows=\(rows.count) capacity=12 overflow=\(overflow) ownershipScope=published-buffer-union-held-candidate sdkInternalQuiescence=unverified unobservedInflightItems=unknown maximumObservedItems=\(rows.map(\.publishedUnionItems).max() ?? 0) compositorScope=returned-A-after-original-PCM-tail treatment=bundle-history-not-individual-component originalAcceptance=unchanged")
        for row in rows {
            print("PreviousBundleBoundary schema=1 fresh=\(fresh) stage=\(row.stage) publishedUnionItems=\(row.publishedUnionItems) candidateDetached=\(row.candidateDetached) originalResourceAlive=\(row.originalResourceAlive) originalRetired=\(row.originalRetired) originalAttached=\(row.originalAttached) originalBorrowed=\(row.originalBorrowed) oldDetachedBeforeInstall=\(row.oldDetachedBeforeInstall)")
        }
        XCTAssertFalse(overflow); XCTAssertLessThanOrEqual(rows.count, 12)
        XCTAssertTrue(rows.allSatisfy { $0.publishedUnionItems > 0 && $0.publishedUnionItems <= 3 })
        if setupCompleted { XCTAssertEqual(rows.map(\.stage), Array(0..<10)) }
    }
}
#endif

private struct ProductionSelectionState {
    let audio: ContinuousPCMRenderer.Snapshot
    let expectedToken: Int
    let metadataMatches: Bool
    let assetMatches: Bool
    let sourceIDMatches: Bool
    let engineRunning: Bool
    let wantsPlaying: Bool
    let preparedCount: Int
    let submitted: UInt64
    let copied: Double?
    let frame: Double?
    let requested: Double
    let videoReady: Bool
    let loading: Bool
    var selected: Bool {
        expectedToken > 0 && audio.token == expectedToken && !audio.ended && metadataMatches
            && assetMatches && sourceIDMatches && engineRunning && wantsPlaying
    }
}

private struct ProductionSelectionMeasurement {
    let phase: Int
    let prepared: Bool
    let preparedBefore: Bool
    let frequency: Double
    let first: Int
    let last: Int
    let origin: Double
    let onlineNextCursor: Int
    let replayToneAfterCleanup: Bool
    let commandReturnHostSeconds: Double
    let outgoing: ProductionSelectionOutputTap.Tone?
    let tone: ProductionSelectionOutputTap.Tone?
    let displayReady: Double?
    let ready: Double?
    let before: ContinuousPCMRenderer.Snapshot
    let expectedTokenBefore: Int
    let beforeSubmitted: UInt64
    let state: ProductionSelectionState
}

private struct ProductionSelectionStream {
    let phase: Int
    let baseline: ContinuousPCMRenderer.Snapshot
    let final: ContinuousPCMRenderer.Snapshot
    let before: ProductionSelectionState
    let after: ProductionSelectionState
    let quantum: Int
    let result: ProductionRendererProbe.Result
    let memoryBytes: Int
    let sameStorage: Bool
}

/// Independent serial observer of the unchanged renderer API. A read occurs outside the
/// result lock: stop never waits for a seqlock acquisition, and an outstanding read fails coverage.
private final class ProductionRendererProbe: @unchecked Sendable {
    #if DEBUG
    struct SnapshotReadWitness: Sendable {
        let lockAcquiredNs: UInt64, snapshotEntryNs: UInt64, snapshotReturnNs: UInt64
        let receipt: ContinuousPCMRenderer.DebugSnapshotReadReceipt
    }
    #endif
    struct Sample: Sendable {
        let begin: UInt64
        let end: UInt64
        let audio: ContinuousPCMRenderer.Snapshot
        #if DEBUG
        let snapshotRead: SnapshotReadWitness?
        let nativeTraceEnabled: Bool
        let lane0: ContinuousPCMDecoder.DebugNativeLaneActivitySnapshot?
        let lane1: ContinuousPCMDecoder.DebugNativeLaneActivitySnapshot?
        let lane2: ContinuousPCMDecoder.DebugNativeLaneActivitySnapshot?
        let renderAccounting: ContinuousPCMRenderer.DebugRenderAccountingSnapshot?
        #endif
    }
    struct Result: Sendable {
        let origin: UInt64
        let samples: [Sample]
        let dropped: Int
        let acquisitionOutstanding: Bool
        #if DEBUG
        let snapshotReadWitnessEnabled: Bool
        #endif
    }
    private let renderer: ContinuousPCMRenderer
    private let origin = DispatchTime.now().uptimeNanoseconds
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var samples: [Sample] = []
    private var stopped = false
    private var acquiring = false
    private var dropped = 0

    #if DEBUG
    private let captureSnapshotReadReceipt: Bool
    private let nativeTrace: ProductionNativeRefillTrace?
    private let nativePhase: Int
    private let nativeExpectedToken: Int
    private let nativeCommandUnderruns: Int64
    private let renderAccounting: ContinuousPCMRenderer.DebugRenderAccountingRecorder?
    init(renderer: ContinuousPCMRenderer, nativeTrace: ProductionNativeRefillTrace? = nil,
         nativePhase: Int = -1, nativeExpectedToken: Int = 0, nativeCommandUnderruns: Int64 = 0,
         renderAccounting: ContinuousPCMRenderer.DebugRenderAccountingRecorder? = nil,
         captureSnapshotReadReceipt: Bool = false) {
        self.renderer = renderer
        self.captureSnapshotReadReceipt = captureSnapshotReadReceipt
        self.nativeTrace = nativeTrace
        self.nativePhase = nativePhase; self.nativeExpectedToken = nativeExpectedToken
        self.nativeCommandUnderruns = nativeCommandUnderruns
        self.renderAccounting = renderAccounting
        samples.reserveCapacity(128)
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test.production-render-sampler", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }
    #else
    init(renderer: ContinuousPCMRenderer) {
        self.renderer = renderer
        samples.reserveCapacity(128)
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test.production-render-sampler", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }
    #endif

    private func sample() {
        let begin = DispatchTime.now().uptimeNanoseconds
        guard begin >= origin, begin - origin < 8_000_000_000 else { return }
        lock.lock()
        #if DEBUG
        let lockAcquiredNs = captureSnapshotReadReceipt ? DispatchTime.now().uptimeNanoseconds : 0
        #endif
        guard !stopped else { lock.unlock(); return }
        acquiring = true
        #if DEBUG
        let firstWindowSample = samples.isEmpty
        #endif
        lock.unlock()
        #if DEBUG
        let snapshotEntryNs = captureSnapshotReadReceipt ? DispatchTime.now().uptimeNanoseconds : 0
        let audio: ContinuousPCMRenderer.Snapshot
        let readReceipt: ContinuousPCMRenderer.DebugSnapshotReadReceipt?
        if captureSnapshotReadReceipt {
            let value = renderer.debugSnapshotWithReadReceipt()
            audio = value.snapshot; readReceipt = value.receipt
        } else {
            audio = renderer.snapshot; readReceipt = nil
        }
        let snapshotReturnNs = captureSnapshotReadReceipt ? DispatchTime.now().uptimeNanoseconds : 0
        #else
        let audio = renderer.snapshot
        #endif
        #if DEBUG
        let lane0 = nativeTrace?.recorder.snapshot(at: 0)
        let lane1 = nativeTrace?.recorder.snapshot(at: 1)
        let lane2 = nativeTrace?.recorder.snapshot(at: 2)
        let accounting = renderAccounting?.snapshot()
        #endif
        let end = DispatchTime.now().uptimeNanoseconds
        #if DEBUG
        var requestFromStoredWindowSample = false
        #endif
        lock.lock()
        acquiring = false
        if !stopped {
            if samples.count < 128 {
                #if DEBUG
                samples.append(Sample(begin: begin, end: end, audio: audio,
                    snapshotRead: readReceipt.map { SnapshotReadWitness(lockAcquiredNs: lockAcquiredNs,
                        snapshotEntryNs: snapshotEntryNs, snapshotReturnNs: snapshotReturnNs, receipt: $0) },
                    nativeTraceEnabled: nativeTrace != nil, lane0: lane0, lane1: lane1, lane2: lane2,
                    renderAccounting: accounting))
                requestFromStoredWindowSample = end >= origin && end - origin < 8_000_000_000
                #else
                samples.append(Sample(begin: begin, end: end, audio: audio))
                #endif
            }
            else { dropped += 1 }
        }
        lock.unlock()
        #if DEBUG
        // Stop/drop/late acquisitions cannot trigger a request. A retained
        // pre-stop observation may still deliver its async response after stop;
        // request/reply times and nonjoint coherence qualify that later state.
        if requestFromStoredWindowSample {
            nativeTrace?.observeFirstUnderrun(audio, renderer: renderer, phase: nativePhase, expectedToken: nativeExpectedToken,
                commandUnderruns: nativeCommandUnderruns, firstWindowSample: firstWindowSample,
                observationBegin: begin, observationEnd: end)
        }
        #endif
    }

    func stop() -> Result {
        timer.cancel()
        lock.lock(); defer { lock.unlock() }
        stopped = true
        #if DEBUG
        return Result(origin: origin, samples: samples, dropped: dropped, acquisitionOutstanding: acquiring,
                      snapshotReadWitnessEnabled: captureSnapshotReadReceipt)
        #else
        return Result(origin: origin, samples: samples, dropped: dropped, acquisitionOutstanding: acquiring)
        #endif
    }
}

#if DEBUG
/// One arm-owned failure request/response, shared by its three existing probes.
/// No producer sampling task, native getter, media reference or per-call history.
private final class ProductionNativeRefillTrace: @unchecked Sendable {
    private struct SourceEndpoint: Sendable {
        let slot: Int, token: Int, tokenAfter: Int
        let prefixFrames: Int, availableRaw: Int, writableRaw: Int
        let totalFrames: Int64
    }
    let recorder: ContinuousPCMDecoder.DebugNativeLaneActivityRecorder
    @MainActor private weak var audio: ContinuousAudioPlayer?
    private let lock = NSLock()
    private var requested = false, issued = false
    private var observationBegin: UInt64 = 0, observationEnd: UInt64 = 0
    private var enqueueNs: UInt64 = 0, issueNs: UInt64 = 0, replyNs: UInt64 = 0
    private var phase = -1
    private var token = 0
    private var visit: Int64 = 0, frame: Int64 = 0, underruns: Int64 = 0, commandUnderruns: Int64 = 0
    private var firstWindowSample = false
    private var sourceBeginNs: UInt64 = 0, sourceEndNs: UInt64 = 0
    private var sources: [SourceEndpoint] = [] // One fixed three-source endpoint, not a history.
    private var response: ContinuousPCMDecoder.DebugFailureState?

    @MainActor init(recorder: ContinuousPCMDecoder.DebugNativeLaneActivityRecorder, audio: ContinuousAudioPlayer) {
        self.recorder = recorder
        self.audio = audio
    }

    func observeFirstUnderrun(_ value: ContinuousPCMRenderer.Snapshot, renderer: ContinuousPCMRenderer,
                             phase: Int, expectedToken: Int,
                             commandUnderruns: Int64, firstWindowSample: Bool,
                             observationBegin: UInt64, observationEnd: UInt64) {
        guard phase == 1 || phase == 2, expectedToken > 0, value.token == expectedToken,
              !value.ended, value.underrunFrames > commandUnderruns else { return }
        lock.lock()
        guard !requested else { lock.unlock(); return }
        requested = true
        self.observationBegin = observationBegin; self.observationEnd = observationEnd
        self.phase = phase; self.firstWindowSample = firstWindowSample
        token = value.token; visit = value.visit; frame = value.frame; underruns = value.underrunFrames
        self.commandUnderruns = commandUnderruns
        sourceBeginNs = DispatchTime.now().uptimeNanoseconds
        sources.reserveCapacity(3)
        for index in 0..<3 {
            let source = renderer.source(at: index)
            let before = source.token
            let total = source.totalFrames, prefix = source.prefixFrameCount
            let available = source.availableStreamFrames, writable = source.writableStreamFrames
            let after = source.token
            sources.append(SourceEndpoint(slot: index, token: before, tokenAfter: after,
                prefixFrames: prefix, availableRaw: available, writableRaw: writable, totalFrames: total))
        }
        sourceEndNs = DispatchTime.now().uptimeNanoseconds
        enqueueNs = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        // One task per arm, only after a real positive underrun. No wait in the
        // observation window; failure of main/worker delivery stays explicit.
        Task { @MainActor [weak self] in
            guard let self, let audio = self.audio else { return }
            self.markIssued()
            audio.debugDecoderFailureState { [weak self] state in
                guard let self else { return }
                self.storeResponse(state)
            }
        }
    }

    private func markIssued() {
        lock.lock(); issued = true; issueNs = DispatchTime.now().uptimeNanoseconds; lock.unlock()
    }

    private func storeResponse(_ state: ContinuousPCMDecoder.DebugFailureState) {
        lock.lock(); response = state; replyNs = DispatchTime.now().uptimeNanoseconds; lock.unlock()
    }

    func dumpAfterCleanup() {
        lock.lock()
        let requestObserved = requested, requestIssued = issued, state = response
        let begin = observationBegin, end = observationEnd
        let requestEnqueueNs = enqueueNs, requestIssueNs = issueNs, workerReplyNs = replyNs
        let triggerPhase = phase, triggerToken = token, triggerVisit = visit, triggerFrame = frame
        let triggerUnderruns = underruns, commandBaseline = commandUnderruns, positiveAtFirstSample = firstWindowSample
        let sourceRecords = sources, sourcesBegin = sourceBeginNs, sourcesEnd = sourceEndNs
        lock.unlock()
        print("ProductionNativeRefillScope schema=1 enabled=true lanes=3 windows=3 maximumSamplesPerWindow=128 intervalMs=100 windowSeconds=8 failureRequestsPerArm=1 failurePriority=B-then-A-fallback coldSubstitution=false snapshotWaitInsideWindow=false realtimeQueries=false")
        print("ProductionNativeRefillFailure schema=1 enabled=true requested=\(requestObserved) requestIssued=\(requestIssued) workerResponseAvailable=\(state != nil) phase=\(triggerPhase) target=\(triggerPhase == 1 ? "B-priority" : triggerPhase == 2 ? "A-fallback" : "none") token=\(triggerToken) visit=\(triggerVisit) frame=\(triggerFrame) underrunFrames=\(triggerUnderruns) commandBaselineUnderruns=\(commandBaseline) positiveAtFirstWindowSample=\(positiveAtFirstSample) onsetBeforeFirstObservation=\(positiveAtFirstSample) observationBeginNs=\(begin) observationEndNs=\(end) requestEnqueueNs=\(requestEnqueueNs) requestIssueNs=\(requestIssueNs) workerReplyNs=\(workerReplyNs) requestCapacity=1 requestDeliveryOutsideAcquisition=true snapshotScope=worker-cached-state jointLaneRendererCoherence=false onsetExact=false coldSubstitution=false")
        print("ProductionNativeRefillSourceScope schema=1 available=\(sourceRecords.count == 3) count=\(sourceRecords.count) capacity=3 beginNs=\(sourcesBegin) endNs=\(sourcesEnd) epochQualified=false streamRequestReads=0 scope=first-observed-failure-after-renderer-acquisition")
        for source in sourceRecords.prefix(3) {
            print("ProductionNativeRefillSource schema=1 slot=\(source.slot) token=\(source.token) tokenAfter=\(source.tokenAfter) tokenStable=\(source.token == source.tokenAfter) prefixFrames=\(source.prefixFrames) totalFrames=\(source.totalFrames) rawAvailableFrames=\(source.availableRaw) rawWritableFrames=\(source.writableRaw) epochQualified=false coherence=individual-atomic-accessors")
        }
        for index in 0..<3 {
            let lane = recorder.snapshot(at: index)
            print("ProductionNativeRefillCleanupLane schema=1 lane=\(index) available=\(lane != nil) packedState=\(lane?.packedState ?? 0) copySequence=\(lane?.copySequence ?? 0) stage=\(lane?.stageCode ?? 0) overflowed=\(lane?.sequenceOverflowed ?? false) scope=after-cleanup-wait")
        }
        guard let state else { return }
        let s = state.stats
        print("ProductionNativeRefillWorker schema=1 leasedReaders=\(s.leasedReaders) peakLeasedReaders=\(s.peakLeasedReaders) retiredLeasesAwaitingClose=\(s.retiredLeasesAwaitingClose) startingLeases=\(s.startingLeases) pendingPreparations=\(s.pendingPreparations) pendingReads=\(s.readJobsAwaitingAcceptanceOrClose) mailboxPackets=\(s.mailboxPackets) pendingOrMailboxPacketSlots=\(s.pendingOrMailboxPacketSlots) shutdownRequested=\(s.shutdownRequested) readerLeasesClosed=\(s.readerLeasesClosed) overflowed=\(s.counterOverflowed)")
        for slot in state.slots.prefix(3) {
            print("ProductionNativeRefillSlot schema=1 slot=\(slot.index) token=\(slot.token) epoch=\(slot.epoch) finished=\(slot.finished) cancelled=\(slot.cancelled) lease=\(slot.leaseIndex) streamAvailable=\(slot.stream != nil) cursor=\(slot.stream?.cursor ?? 0) generatedFrames=\(slot.stream?.generatedFrames ?? 0) outputStart=\(slot.stream?.outputStart ?? 0) outputCount=\(slot.stream?.outputCount ?? 0) converterFinished=\(slot.stream?.converterFinished ?? false) reachedEnd=\(slot.stream?.reachedEnd ?? false)")
        }
        for lease in state.leases.prefix(3) {
            print("ProductionNativeRefillLease schema=1 lane=\(lease.index) present=\(lease.present) starting=\(lease.starting) readPending=\(lease.readPending) retired=\(lease.retired) requestedFrames=\(lease.requestedFrames) packetFrames=\(lease.packetFrames) packetOffset=\(lease.packetOffset) reachedEnd=\(lease.reachedEnd) hasFailure=\(lease.hasFailure)")
        }
    }
}
#endif

/// Fixed 12-second storage for actual mixer PCM and its AVAudioTime host timeline.
/// The tap is disabled during the first two 8-second renderer-only windows.
private final class ProductionSelectionOutputTap: @unchecked Sendable {
    struct Tone { let start: Double; let end: Double }
    #if DEBUG
    struct ToneReplay {
        var inputValid = false
        var windows = 0, eligibleWindows = 0, unsearchedEligibleWindows = 0
        var targetWindows = 0, alternateWindows = 0
        var firstTarget: Tone?, firstAlternate: Tone?
        var firstTargetIndex = -1
        var targetWasUnsearched = false
        var available: Bool { inputValid && eligibleWindows > 0 }
    }
    #endif
    struct Window { let samples: [Float]; let rate: Double; let start: Double; let end: Double }
    struct Recording { let values: [Float]; let hosts: [Double]; let rate: Double }
    struct Anomaly {
        let kind: Int // 0 = existing 10 ms RMS quiet test; 1 = existing 20 ms tone test.
        let windowOrdinal: Int, firstFrame: Int, endFrame: Int
        let startOffsetMs: Double?, endOffsetMs: Double?
        let rms: Double
    }
    struct ChannelRun {
        let firstFrame: Int, firstHost: Double
        var endFrame: Int, endHost: Double
        var leftSquareSum: Double, rightSquareSum: Double
        var stereoZeroFrames: Int
        var frames: Int { endFrame - firstFrame }
    }

    /// Observed only for admitted frames, under the existing tap lock.
    /// Counts cannot exceed the fixed PCM capacity; no format history is retained.
    struct TapLayout {
        var buffers = 0, frames = 0
        var firstChannelCount = 0, lastChannelCount = 0
        var firstInterleaved = false, lastInterleaved = false
        var firstRate = 0.0, lastRate = 0.0
        var changed = false
        var monoDuplicatedFrames = 0, stereoInputFrames = 0, otherInputFrames = 0
        var allInputActualStereo: Bool {
            buffers > 0 && frames > 0 && stereoInputFrames == frames
                && monoDuplicatedFrames == 0 && otherInputFrames == 0
        }
        mutating func observe(channelCount: Int, interleaved: Bool, rate: Double, retainedFrames: Int) {
            guard retainedFrames > 0 else { return }
            if buffers == 0 {
                firstChannelCount = channelCount; firstInterleaved = interleaved; firstRate = rate
            } else if channelCount != firstChannelCount || interleaved != firstInterleaved || rate != firstRate {
                changed = true
            }
            lastChannelCount = channelCount; lastInterleaved = interleaved; lastRate = rate
            buffers += 1; frames += retainedFrames
            if channelCount == 1 { monoDuplicatedFrames += retainedFrames }
            else if channelCount == 2 { stereoInputFrames += retainedFrames }
            else { otherInputFrames += retainedFrames }
        }
    }
    struct ChannelAudit {
        let firstFrame: Int, minimumRunFrames: Int, observedFrames: Int
        let monoZeroFrames: Int, stereoZeroFrames: Int, nonfiniteFrames: Int
        let leftSquareSum: Double, rightSquareSum: Double
        let qualifiedRuns: Int, retainedRuns: Int, droppedRuns: Int, overflow: Bool
        let first: ChannelRun?, second: ChannelRun?, third: ChannelRun?, fourth: ChannelRun?
        let layout: TapLayout
        // Qualifies the existing count's input layout; it does not assert that zeros occurred.
        var stereoZeroEvidenceQualified: Bool {
            layout.allInputActualStereo && layout.frames == observedFrames
        }
        func run(at ordinal: Int) -> ChannelRun? {
            switch ordinal {
            case 0: return first
            case 1: return second
            case 2: return third
            case 3: return fourth
            default: return nil
            }
        }
    }
    private let lock = NSLock()
    private let capacity = 12 * 48_000
    private var values: [Float] = []
    private var hosts: [Double] = []
    private var rate = 0.0
    private var enabled = false
    private var invalidTimestamps = 0
    private var droppedFrames = 0
    // Protected by the existing tap lock; no extra PCM storage or hot allocation.
    private var auditEnabled = false
    private var auditFirstFrame = 0, auditMinimumRunFrames = 0, auditObservedFrames = 0
    private var auditMonoZeroFrames = 0, auditStereoZeroFrames = 0, auditNonfiniteFrames = 0
    private var auditLeftSquareSum = 0.0, auditRightSquareSum = 0.0
    private var auditQualifiedRuns = 0, auditDroppedRuns = 0
    private var auditOverflow = false
    private var auditLayout = TapLayout()
    private var auditPending: ChannelRun?
    private var auditFirst: ChannelRun?, auditSecond: ChannelRun?, auditThird: ChannelRun?, auditFourth: ChannelRun?

    init() { values.reserveCapacity(capacity); hosts.reserveCapacity(capacity) }
    static func hostSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    @discardableResult
    func begin(auditChannels: Bool = false) -> Int {
        lock.lock(); defer { lock.unlock() }
        if auditEnabled { finishChannelRun() }
        enabled = true; auditEnabled = auditChannels
        if auditChannels {
            auditFirstFrame = values.count; auditMinimumRunFrames = 0; auditObservedFrames = 0
            auditMonoZeroFrames = 0; auditStereoZeroFrames = 0; auditNonfiniteFrames = 0
            auditLeftSquareSum = 0; auditRightSquareSum = 0
            auditQualifiedRuns = 0; auditDroppedRuns = 0; auditOverflow = false
            auditLayout = TapLayout()
            auditPending = nil; auditFirst = nil; auditSecond = nil; auditThird = nil; auditFourth = nil
        }
        return values.count
    }
    @discardableResult
    func stop() -> Int {
        lock.lock(); defer { lock.unlock() }
        enabled = false
        if auditEnabled { finishChannelRun(); auditEnabled = false }
        return values.count
    }

    func channelAudit() -> ChannelAudit {
        lock.lock(); defer { lock.unlock() }
        return ChannelAudit(firstFrame: auditFirstFrame, minimumRunFrames: auditMinimumRunFrames,
            observedFrames: auditObservedFrames, monoZeroFrames: auditMonoZeroFrames,
            stereoZeroFrames: auditStereoZeroFrames, nonfiniteFrames: auditNonfiniteFrames,
            leftSquareSum: auditLeftSquareSum, rightSquareSum: auditRightSquareSum,
            qualifiedRuns: auditQualifiedRuns, retainedRuns: min(4, auditQualifiedRuns),
            droppedRuns: auditDroppedRuns, overflow: auditOverflow,
            first: auditFirst, second: auditSecond, third: auditThird, fourth: auditFourth,
            layout: auditLayout)
    }

    /// Called only under the existing append/stop lock.
    private func finishChannelRun() {
        guard let run = auditPending else { return }
        auditPending = nil
        guard auditMinimumRunFrames > 0, run.frames >= auditMinimumRunFrames else { return }
        switch auditQualifiedRuns {
        case 0: auditFirst = run
        case 1: auditSecond = run
        case 2: auditThird = run
        case 3: auditFourth = run
        default: auditDroppedRuns += 1; auditOverflow = true
        }
        auditQualifiedRuns += 1
    }

    private func auditChannels(left: Float, right: Float, mono: Float, frame: Int,
                               host: Double, rate: Double) {
        auditObservedFrames += 1
        if auditMinimumRunFrames == 0 { auditMinimumRunFrames = Int(rate * 0.01) }
        guard left.isFinite, right.isFinite, mono.isFinite else {
            auditNonfiniteFrames += 1; finishChannelRun(); return
        }
        guard mono == 0 else { finishChannelRun(); return }
        let leftSquare = Double(left) * Double(left), rightSquare = Double(right) * Double(right)
        let stereoZero = left == 0 && right == 0 ? 1 : 0
        auditMonoZeroFrames += 1; auditStereoZeroFrames += stereoZero
        auditLeftSquareSum += leftSquare; auditRightSquareSum += rightSquare
        if auditPending == nil {
            auditPending = ChannelRun(firstFrame: frame, firstHost: host, endFrame: frame,
                endHost: host, leftSquareSum: 0, rightSquareSum: 0, stereoZeroFrames: 0)
        }
        auditPending?.endFrame = frame + 1
        auditPending?.endHost = host + 1 / rate
        auditPending?.leftSquareSum += leftSquare
        auditPending?.rightSquareSum += rightSquare
        auditPending?.stereoZeroFrames += stereoZero
    }

    func append(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        guard time.isHostTimeValid, buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
              buffer.format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData else {
            invalidTimestamps += 1; return
        }
        let actualRate = buffer.format.sampleRate
        if rate == 0 { rate = actualRate }
        guard abs(actualRate - rate) < 0.1 else { invalidTimestamps += 1; return }
        let start = AVAudioTime.seconds(forHostTime: time.hostTime)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0, start.isFinite else { invalidTimestamps += 1; return }
        let frames = min(Int(buffer.frameLength), capacity - values.count)
        droppedFrames += Int(buffer.frameLength) - frames
        for frame in 0..<frames {
            // Bind the first existing format read; retain the original right-side read below.
            let interleaved = buffer.format.isInterleaved
            let left = channels[0][interleaved ? frame * channelCount : frame]
            let right = channelCount > 1
                ? (buffer.format.isInterleaved ? channels[0][frame * channelCount + 1] : channels[1][frame]) : left
            let mono = (left + right) * 0.5
            let host = start + Double(frame) / actualRate
            if auditEnabled {
                if frame == 0 {
                    auditLayout.observe(channelCount: channelCount, interleaved: interleaved,
                                        rate: actualRate, retainedFrames: frames)
                }
                auditChannels(left: left, right: right, mono: mono, frame: values.count, host: host, rate: actualRate)
            }
            values.append(mono)
            hosts.append(host)
        }
    }

    func window(at index: Int) -> Window? {
        lock.lock(); defer { lock.unlock() }
        let frames = Int(rate * 0.02)
        guard frames > 0, index >= 0, index + frames <= values.count else { return nil }
        return Window(samples: Array(values[index..<(index + frames)]), rate: rate,
                      start: hosts[index], end: hosts[index + frames - 1] + 1 / rate)
    }

    func samples(from first: Int, to last: Int) -> Recording {
        lock.lock(); defer { lock.unlock() }
        let lower = min(max(0, first), values.count), upper = min(max(first, last), values.count)
        return Recording(values: Array(values[lower..<upper]), hosts: Array(hosts[lower..<upper]), rate: rate)
    }

    func validity() -> (invalidTimestamps: Int, droppedFrames: Int) {
        lock.lock(); defer { lock.unlock() }; return (invalidTimestamps, droppedFrames)
    }

    static func isTone(_ samples: [Float], rate: Double, frequency: Double) -> Bool {
        guard !samples.isEmpty, rate.isFinite, rate > 0, samples.allSatisfy({ $0.isFinite }) else { return false }
        func power(_ hz: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for (index, value) in samples.enumerated() {
                let phase = 2 * Double.pi * hz * Double(index) / rate
                real += Double(value) * cos(phase); imaginary += Double(value) * sin(phase)
            }
            return (real * real + imaginary * imaginary) / pow(Double(samples.count), 2)
        }
        let expected = power(frequency)
        return expected > 0.001 && expected > 10 * max(power(frequency == 440 ? 880 : 440), 1e-12)
    }

    static func toneBlocks(_ samples: [Float], rate: Double, frequency: Double) -> (correct: Int, total: Int) {
        let frames = Int(rate * 0.02)
        guard frames > 0, samples.count >= frames else { return (0, 0) }
        var correct = 0, total = 0
        for start in stride(from: 0, through: samples.count - frames, by: frames) {
            total += 1
            if isTone(Array(samples[start..<(start + frames)]), rate: rate, frequency: frequency) { correct += 1 }
        }
        return (correct, total)
    }

    #if DEBUG
    /// Replay the original live 20 ms windows/10 ms cursor, without extending
    /// capture, reading another source, changing classifications or latching ready.
    /// One fixed scratch buffer; no PCM or per-window history escapes this call.
    static func replayTone(_ recording: Recording, origin: Double, frequency: Double,
                           firstIndex: Int, onlineNextCursor: Int, expectedFrames: Int) -> ToneReplay {
        var result = ToneReplay()
        let count = recording.values.count
        let end = firstIndex.addingReportingOverflow(count)
        guard recording.rate == 48_000, origin.isFinite, frequency == 440 || frequency == 880,
              firstIndex >= 0, !end.overflow, end.partialValue <= 576_000,
              count == expectedFrames, count == recording.hosts.count, count >= 960,
              onlineNextCursor >= firstIndex, onlineNextCursor <= end.partialValue,
              recording.values.allSatisfy({ $0.isFinite }), recording.hosts.allSatisfy({ $0.isFinite }),
              zip(recording.hosts, recording.hosts.dropFirst()).allSatisfy({ pair in pair.0 < pair.1 }) else { return result }
        result.inputValid = true
        var scratch = [Float](repeating: 0, count: 960)
        recording.values.withUnsafeBufferPointer { values in
            for start in stride(from: 0, through: count - 960, by: 480) {
                result.windows += 1
                let last = start + 960
                let hostEnd = recording.hosts[last - 1] + 1 / recording.rate
                guard hostEnd >= origin else { continue }
                result.eligibleWindows += 1
                let globalIndex = firstIndex + start
                if globalIndex >= onlineNextCursor { result.unsearchedEligibleWindows += 1 }
                scratch.withUnsafeMutableBufferPointer {
                    $0.baseAddress!.update(from: values.baseAddress!.advanced(by: start), count: 960)
                }
                if isTone(scratch, rate: recording.rate, frequency: frequency) {
                    result.targetWindows += 1
                    if result.firstTarget == nil {
                        result.firstTarget = Tone(start: recording.hosts[start], end: hostEnd)
                        result.firstTargetIndex = globalIndex
                        result.targetWasUnsearched = globalIndex >= onlineNextCursor
                    }
                }
                if isTone(scratch, rate: recording.rate, frequency: frequency == 440 ? 880 : 440) {
                    result.alternateWindows += 1
                    if result.firstAlternate == nil {
                        result.firstAlternate = Tone(start: recording.hosts[start], end: hostEnd)
                    }
                }
            }
        }
        return result
    }
    #endif

    static func quietRun(_ samples: [Float], rate: Double) -> Double {
        let frames = Int(rate * 0.01)
        guard frames > 0, samples.count >= frames else { return 0 }
        var longest = 0, run = 0
        for start in stride(from: 0, through: samples.count - frames, by: frames) {
            var square = 0.0
            for value in samples[start..<(start + frames)] { square += Double(value) * Double(value) }
            if sqrt(square / Double(frames)) < 0.01 { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        return Double(longest * frames) / rate
    }

    /// Replay unchanged classifications after cleanup; never clip either recording edge.
    static func anomalyLocations(_ recording: Recording, origin: Double?, frequency: Double)
        -> (available: Bool, records: [Anomaly], quietCount: Int, badToneCount: Int, droppedAnomalyCount: Int) {
        guard recording.rate.isFinite, recording.rate > 0,
              recording.values.count == recording.hosts.count else { return (false, [], 0, 0, 0) }
        var records: [Anomaly] = []
        records.reserveCapacity(8)
        var quietCount = 0, badToneCount = 0
        for kind in 0..<2 {
            let frames = Int(recording.rate * (kind == 0 ? 0.01 : 0.02))
            guard frames > 0, recording.values.count >= frames else { continue }
            for first in stride(from: 0, through: recording.values.count - frames, by: frames) {
                let end = first + frames
                var square = 0.0
                for value in recording.values[first..<end] { square += Double(value) * Double(value) }
                let rms = sqrt(square / Double(frames))
                let anomalous = kind == 0 ? rms < 0.01
                    : !isTone(Array(recording.values[first..<end]), rate: recording.rate, frequency: frequency)
                guard anomalous else { continue }
                let ordinal = kind == 0 ? quietCount : badToneCount
                if kind == 0 { quietCount += 1 } else { badToneCount += 1 }
                guard ordinal < 4 else { continue }
                let validOrigin = origin.flatMap { $0.isFinite ? $0 : nil }
                records.append(Anomaly(kind: kind, windowOrdinal: first / frames,
                    firstFrame: first, endFrame: end,
                    startOffsetMs: validOrigin.map { (recording.hosts[first] - $0) * 1_000 },
                    endOffsetMs: validOrigin.map { (recording.hosts[end - 1] + 1 / recording.rate - $0) * 1_000 },
                    rms: rms))
            }
        }
        return (true, records, quietCount, badToneCount, max(0, quietCount - 4) + max(0, badToneCount - 4))
    }

    static func maximumTimelineHole(_ hosts: [Double], rate: Double) -> Double {
        guard rate > 0, hosts.count > 1 else { return 0 }
        var maximum = 0.0
        for index in 1..<hosts.count {
            let interval = hosts[index] - hosts[index - 1]
            guard interval.isFinite, interval > 0 else { return .infinity }
            maximum = max(maximum, interval - 1 / rate)
        }
        return maximum
    }
}

/// Seek forwarding timestamps/targets plus optional cached DEBUG decision stamps.
/// Neither path queries native player state; all output remains post-cleanup.
private final class ProductionSelectionSeekRecorder: @unchecked Sendable {
    struct Event {
        let phase: Int
        let target: Double
        let forwardedTimeValue: CMTimeValue
        let forwardedTimeTimescale: CMTimeScale
        let entered: Double
        var returnHostSeconds: Double?
        var completed: Double?
        var finished: Bool?
        #if DEBUG
        var stamp: PlaybackService.DebugVideoSeekStamp?
        #endif
    }
    private let lock = NSLock()
    private var currentPhase = -1
    private var events: [Event] = []
    private var dropped = 0
    #if DEBUG
    private var pendingStamp: PlaybackService.DebugVideoSeekStamp?
    private var stampConflicts = 0

    func record(_ stamp: PlaybackService.DebugVideoSeekStamp) {
        lock.lock(); defer { lock.unlock() }
        if pendingStamp != nil { stampConflicts += 1 }
        pendingStamp = stamp
    }
    #endif
    init() { events.reserveCapacity(32) }
    var phase: Int {
        get { lock.lock(); defer { lock.unlock() }; return currentPhase }
        set { lock.lock(); currentPhase = newValue; lock.unlock() }
    }

    @MainActor
    func seek(_ player: AVPlayer, _ time: CMTime, _ completion: @escaping @Sendable (Bool) -> Void) {
        let entered = ProductionSelectionOutputTap.hostSeconds()
        lock.lock()
        let index: Int?
        #if DEBUG
        let stamp = pendingStamp
        pendingStamp = nil
        #endif
        if events.count < 32 {
            index = events.count
            var event = Event(phase: currentPhase, target: time.seconds,
                              forwardedTimeValue: time.value, forwardedTimeTimescale: time.timescale, entered: entered)
            #if DEBUG
            event.stamp = stamp
            #endif
            events.append(event)
        } else { dropped += 1; index = nil }
        lock.unlock()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [self] finished in
            let completed = ProductionSelectionOutputTap.hostSeconds()
            completion(finished)
            // Forward the real completion before recorder mutation or logging.
            lock.lock(); defer { lock.unlock() }
            if let index {
                if events[index].completed == nil {
                    events[index].completed = completed; events[index].finished = finished
                } else { dropped += 1 }
            }
        }
        // Timestamp immediately after the real forwarding call returns. The
        // native completion may legitimately occur before or after this point.
        let returned = ProductionSelectionOutputTap.hostSeconds()
        lock.lock()
        if let index { events[index].returnHostSeconds = returned }
        lock.unlock()
    }

    func assertUnused(file: StaticString = #filePath, line: UInt = #line) {
        lock.lock()
        let count = events.count, lost = dropped
        #if DEBUG
        let conflicts = stampConflicts, pending = pendingStamp != nil
        #endif
        lock.unlock()
        print("ProductionSelectionDefaultSeekPath recordedSeeks=\(count) dropped=\(lost) nativeSeekForwarder=default producerTracing=absent nativeLaneTracing=absent observer=unset")
        XCTAssertEqual(count, 0, "The default path must not pass native seeks through the benchmark recorder", file: file, line: line)
        XCTAssertEqual(lost, 0, file: file, line: line)
        #if DEBUG
        XCTAssertEqual(conflicts, 0, file: file, line: line)
        XCTAssertFalse(pending, file: file, line: line)
        #endif
    }

    func dumpAndAssert() {
        lock.lock()
        let result = events, lost = dropped
        #if DEBUG
        let conflicts = stampConflicts, pending = pendingStamp != nil
        #endif
        lock.unlock()
        print("ProductionSelectionSeekSummary events=\(result.count) capacity=32 dropped=\(lost) nativePositionGetters=0 producerTracing=absent")
        XCTAssertLessThanOrEqual(result.count, 32); XCTAssertEqual(lost, 0)
        #if DEBUG
        print("ProductionSelectionSeekStampSummary schema=1 conflicts=\(conflicts) pending=\(pending) storage=existing32events-plus-one-pending")
        XCTAssertEqual(conflicts, 0); XCTAssertFalse(pending)
        #endif
        for (index, event) in result.enumerated() {
            print("ProductionSelectionSeek ordinal=\(index) phase=\(event.phase) target=\(event.target) enteredHostSeconds=\(event.entered) completedHostSeconds=\(event.completed.map { String($0) } ?? "missing") finished=\(event.finished.map { String($0) } ?? "missing")")
            XCTAssertTrue((0...2).contains(event.phase)); XCTAssertTrue(event.target.isFinite)
            XCTAssertTrue(event.entered.isFinite)
            if let completed = event.completed { XCTAssertGreaterThanOrEqual(completed, event.entered) }
            print("ProductionSelectionSeekReturn schema=1 ordinal=\(index) phase=\(event.phase) enteredHostSeconds=\(event.entered) returnHostSeconds=\(event.returnHostSeconds.map { String($0) } ?? "missing") forwardingSynchronousSpanMs=\(event.returnHostSeconds.map { String(($0 - event.entered) * 1_000) } ?? "missing")")
            XCTAssertNotNil(event.returnHostSeconds, "Every forwarded seek must retain its synchronous return timestamp")
            if let returned = event.returnHostSeconds {
                XCTAssertTrue(returned.isFinite)
                XCTAssertGreaterThanOrEqual(returned, event.entered)
            }
            #if DEBUG
            XCTAssertNotNil(event.stamp, "Every forwarded benchmark seek must retain its decision stamp")
            if let stamp = event.stamp {
                print("ProductionSelectionSeekReason schema=1 ordinal=\(index) phase=\(event.phase) reason=\(stamp.reason.rawValue) request=\(stamp.request) generation=\(stamp.generation) nativeSeekTicket=\(stamp.nativeSeekTicket) requestedPosition=\(stamp.requestedPosition) force=\(stamp.force) cachedSelected=\(stamp.cachedSelected) selectedMatchesQueue=\(stamp.selectedMatchesQueue) cachedAudioToken=\(stamp.cachedAudioToken) cachedAudioVisit=\(stamp.cachedAudioVisit) observedItemMatches=\(stamp.observedItemMatches) presentationRequestMatches=\(stamp.presentationRequestMatches) readyGeneration=\(stamp.readyGeneration.map { String($0) } ?? "missing") pendingAudioSeek=\(stamp.pendingAudioSeek) audioLoading=\(stamp.audioLoading) canPlay=\(stamp.canPlay) videoAllowed=\(stamp.videoAllowed)")
                XCTAssertNotEqual(stamp.reason, .unattributed)
                XCTAssertGreaterThan(stamp.nativeSeekTicket, 0)
                XCTAssertTrue(stamp.requestedPosition.isFinite)
                // Reconstruct the original application request exactly as forwarded.
                // The actual integer fields were retained from CMTime, never from target.seconds.
                let expectedTime = CMTime(seconds: stamp.requestedPosition, preferredTimescale: 48_000)
                print("ProductionSelectionSeekExactTime schema=1 ordinal=\(index) phase=\(event.phase) expectedValue=\(expectedTime.value) expectedTimescale=\(expectedTime.timescale) forwardedValue=\(event.forwardedTimeValue) forwardedTimescale=\(event.forwardedTimeTimescale) force=\(stamp.force) ordinaryDriftVideoPositionSeconds=\(stamp.ordinaryDriftVideoPositionSeconds.map { String($0) } ?? "not-read") ordinarySignedDriftSeconds=\(stamp.ordinaryDriftVideoPositionSeconds.map { String($0 - stamp.requestedPosition) } ?? "not-read")")
                XCTAssertEqual(expectedTime.value, event.forwardedTimeValue)
                XCTAssertEqual(expectedTime.timescale, event.forwardedTimeTimescale)
                if stamp.force { XCTAssertNil(stamp.ordinaryDriftVideoPositionSeconds) }
                else { XCTAssertNotNil(stamp.ordinaryDriftVideoPositionSeconds) }
            }
            #endif
        }
    }
}

private final class ProductionSelectionShutdown: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    var result: Bool? { lock.lock(); defer { lock.unlock() }; return value }
    func complete(_ result: Bool) { lock.lock(); value = result; lock.unlock() }
}

#if DEBUG
private final class ProductionPCMOriginReply: @unchecked Sendable {
    private let lock = NSLock()
    private var received = false
    private var snapshot: DebugAcceptedPCMOriginSnapshot?
    func complete(_ snapshot: DebugAcceptedPCMOriginSnapshot?) {
        lock.lock(); self.snapshot = snapshot; received = true; lock.unlock()
    }
    func read() -> (received: Bool, snapshot: DebugAcceptedPCMOriginSnapshot?) {
        lock.lock(); defer { lock.unlock() }; return (received, snapshot)
    }
}

private final class NaturalFailureStateMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuousPCMDecoder.DebugFailureState?
    var result: ContinuousPCMDecoder.DebugFailureState? { lock.lock(); defer { lock.unlock() }; return value }
    func complete(_ result: ContinuousPCMDecoder.DebugFailureState) { lock.lock(); value = result; lock.unlock() }
}
#endif

enum SelectionVideoIdentity: String { case a, b }
private enum SelectionVideoTestFailure: Error {
    case timeout, sample, capture, unsafeCapturePath
    case simulatorCaptureUnavailable
    case simulatorCaptureRejected(Int)
}

@MainActor
final class SelectionVideoFixture {
    static let duration = 30.0
    let temporary: URL
    let cloud: OneDriveClient
    let downloads: OfflineDownloads
    let library: LibraryRepository
    let ids: [String]
    let playlist = "local:selected-video-regression-" + UUID().uuidString
    var aID: String { ids[0] }
    var bID: String { ids[1] }
    var bookmark: URL { temporary.appendingPathComponent("playback.json") }
    private(set) var savedURLs: [String: URL] = [:]
    private let previousSpeakerSound = UserDefaults.standard.object(forKey: "speakerSound")
    private let previousAutomaticPiP = UserDefaults.standard.object(forKey: "automaticPiP")

    init() async throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        cloud = OneDriveClient(account: MicrosoftAccount())
        downloads = OfflineDownloads(cloud: cloud, network: NetworkStatus())
        library = LibraryRepository(cloud: cloud, catalogURL: temporary.appendingPathComponent("catalog.json"))
        ids = ["local:selected-A-" + UUID().uuidString, "local:selected-B-" + UUID().uuidString]
        do {
            for (index, identity) in [SelectionVideoIdentity.a, .b].enumerated() {
                let source = try XCTUnwrap(Bundle(for: PlaybackSelectionVideoRegressionTests.self)
                    .url(forResource: "test-selection-" + identity.rawValue, withExtension: "mp4"))
                _ = try await downloads.importLocal(source, mediaID: ids[index])
            }
            let records = ids.map { MediaRecord(id: $0, title: "Generated selection fixture", creator: "Test", duration: Self.duration) }
            try library.install(LibraryCatalog(libraryID: "local:selection-regression", media: records,
                                               playlists: [PlaylistRecord(id: playlist, name: "Generated", itemIDs: ids)]))
            for record in records {
                let saved = await downloads.localURL(for: record)
                savedURLs[record.id] = try XCTUnwrap(saved)
            }
        } catch { remove(); throw error }
    }

    func service(buffer: PlaybackBuffer? = nil, continuousAudio: ContinuousAudioPlayer? = nil,
                 seekVideo: PlaybackService.SeekVideo? = nil) -> PlaybackService {
        let result: PlaybackService
        if let seekVideo {
            result = PlaybackService(library: library, downloads: downloads, cloud: cloud,
                                     bookmarkURL: bookmark, activateSession: {}, buffer: buffer,
                                     continuousAudio: continuousAudio, seekVideo: seekVideo)
        } else {
            result = PlaybackService(library: library, downloads: downloads, cloud: cloud,
                                     bookmarkURL: bookmark, activateSession: {}, buffer: buffer, continuousAudio: continuousAudio)
        }
        result.speakerSound = false
        result.automaticPiP = false
        return result
    }

    /// This verifies encoded fixture identity independently of PlaybackService and its token.
    /// It does not claim to measure which tone reached a physical speaker.
    func decodedTone(id: String) async throws -> [Float] {
        let asset = AVURLAsset(url: try XCTUnwrap(savedURLs[id]))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw SelectionVideoTestFailure.sample }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(value: 24_000, timescale: 48_000),
                                      duration: CMTime(value: 12_000, timescale: 48_000))
        guard reader.startReading() else { throw reader.error ?? SelectionVideoTestFailure.sample }
        defer { reader.cancelReading() }
        var left: [Float] = []
        while let sample = output.copyNextSampleBuffer(), left.count < 12_000 {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw SelectionVideoTestFailure.sample }
            let byteCount = CMBlockBufferGetDataLength(block)
            guard byteCount > 0, byteCount % 8 == 0, byteCount <= 1_048_576 else { throw SelectionVideoTestFailure.sample }
            var values = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw SelectionVideoTestFailure.sample }
            for index in stride(from: 0, to: values.count, by: 2) where left.count < 12_000 {
                left.append(values[index])
            }
        }
        guard reader.status != .failed else { throw reader.error ?? SelectionVideoTestFailure.sample }
        return left
    }

    func remove() {
        for id in ids { downloads.remove(id) }
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let owned = temporary.standardizedFileURL
        // Only this fixture's UUID directory is recursively removed. Cleanup is
        // idempotent when initialization failed or a prior cleanup already ran.
        if UUID(uuidString: owned.lastPathComponent) != nil,
           owned.deletingLastPathComponent().resolvingSymlinksInPath() == parent,
           owned.resolvingSymlinksInPath().deletingLastPathComponent() == parent,
           manager.fileExists(atPath: owned.path) {
            do { try manager.removeItem(at: owned) }
            catch { print("SelectionFixture cleanupErrorCode=\((error as NSError).code)") }
        }
        restorePreferences()
    }

    func restorePreferences() {
        if let previousSpeakerSound { UserDefaults.standard.set(previousSpeakerSound, forKey: "speakerSound") }
        else { UserDefaults.standard.removeObject(forKey: "speakerSound") }
        if let previousAutomaticPiP { UserDefaults.standard.set(previousAutomaticPiP, forKey: "automaticPiP") }
        else { UserDefaults.standard.removeObject(forKey: "automaticPiP") }
    }

}

#if DEBUG
@MainActor
private final class SelectionInitialReadyOrderingProbe {
    let generation: Int
    private(set) var entered = 0, active = 0, dropped = 0
    private(set) var timedOut = false, cancelled = false, overflow = false
    private(set) var reasons: [Int] = []
    private var released = false, recording = true
    private var deadline: Double?
    var isHolding: Bool { active > 0 && !released && !timedOut && !cancelled }

    init(generation: Int) { self.generation = generation; reasons.reserveCapacity(32) }

    func hold(request: Int) async {
        guard request == generation, !released else { return }
        guard entered < 8 else { overflow = true; return }
        entered += 1; active += 1
        defer { active -= 1 }
        if deadline == nil { deadline = ProcessInfo.processInfo.systemUptime + 3 }
        while !released, ProcessInfo.processInfo.systemUptime < (deadline ?? 0) {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { cancelled = true; return }
        }
        if !released { timedOut = true }
    }

    func record(_ stamp: PlaybackService.DebugVideoSeekStamp) {
        guard recording, stamp.generation == generation else { return }
        if reasons.count < 32 { reasons.append(stamp.reason.rawValue) }
        else { dropped += 1 }
    }

    func stopRecording() { recording = false }
    func release() { released = true }
}
#endif

@MainActor
private final class SelectionVideoSeekScheduler {
    var onSeekStarted: (@MainActor () -> Void)?
    private(set) var nativeFinished: Bool?
    private var intercepted = false
    private var released = false
    private var heldCompletion: (@Sendable (Bool) -> Void)?
    var isHoldingCompletion: Bool { heldCompletion != nil }

    func seek(_ player: AVPlayer, _ time: CMTime, _ completion: @escaping @Sendable (Bool) -> Void) {
        let hold = !intercepted && abs(time.seconds - 0.4) < 0.000_001
        if hold { intercepted = true; onSeekStarted?() }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { completion(finished); return }
                if hold, !self.released { self.nativeFinished = finished; self.heldCompletion = completion }
                else { completion(finished) }
            }
        }
    }

    func release() {
        // Teardown can precede the native callback. In that case the callback
        // passes through when it arrives instead of becoming a leaked hold.
        released = true
        guard let completion = heldCompletion, let finished = nativeFinished else { return }
        heldCompletion = nil
        completion(finished)
    }
}

private struct SelectionVideoCaptureState {
    let uptime: Double
    let playerPosition: Double
    let audioFrame: Int64
    let audioVisit: Int64
    let audioToken: Int
    let audioUnderrunFrames: Int64
}

@MainActor
private final class SelectionVideoScreen {
    let window: UIWindow
    let service: PlaybackService
    private weak var previousKeyWindow: UIWindow?
    var customVideoLayer: AVSampleBufferDisplayLayer? {
        service.surface.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.last
    }

    init(service: PlaybackService) throws {
        self.service = service
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: SelectionVideoHarness(service: service))
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    func capture(label: String, test: XCTestCase) async throws -> SelectionVideoPixels {
        let before = captureState()
        let started = before.uptime
        var completed = false
        logCapture(label: label, phase: "before", started: started, failed: false)
        defer { logCapture(label: label, phase: "after", started: started, failed: !completed) }
        window.rootViewController?.view.layoutIfNeeded()
        CATransaction.flush()
        let image: UIImage
        let scaleX: CGFloat
        let scaleY: CGFloat
        #if targetEnvironment(simulator)
        // drawHierarchy can omit hardware-backed video. Require the host compositor on
        // Simulator; never replace missing onscreen pixels with decoded asset images.
        image = try await compositorImage()
        guard let cg = image.cgImage, window.bounds.width > 0, window.bounds.height > 0 else {
            throw SelectionVideoTestFailure.capture
        }
        scaleX = CGFloat(cg.width) / window.bounds.width
        scaleY = CGFloat(cg.height) / window.bounds.height
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var drewHierarchy = false
        image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard drewHierarchy else { throw SelectionVideoTestFailure.capture }
        scaleX = 1; scaleY = 1
        #endif
        let attachment = XCTAttachment(image: image)
        attachment.name = "Selected-video-composite-" + label
        attachment.lifetime = .keepAlways
        test.add(attachment)
        // This is the complete onscreen hierarchy cropped to the real surface, never an
        // AVAssetImageGenerator image substituted underneath the opaque poster.
        let points = service.surface.convert(service.surface.bounds, to: window)
        let rect = CGRect(x: points.minX * scaleX, y: points.minY * scaleY,
                          width: points.width * scaleX, height: points.height * scaleY).integral
        guard let cg = image.cgImage, rect.width > 0, rect.height > 0,
              CGRect(x: 0, y: 0, width: cg.width, height: cg.height).contains(rect),
              let cropped = cg.cropping(to: rect) else { throw SelectionVideoTestFailure.capture }
        var pixels = try SelectionVideoPixels(cropped, scaleX: Double(scaleX), scaleY: Double(scaleY), captureBefore: before)
        pixels.captureAfter = captureState()
        completed = true
        return pixels
    }

    private func captureState() -> SelectionVideoCaptureState {
        let audio = service.audioSnapshot
        return SelectionVideoCaptureState(uptime: ProcessInfo.processInfo.systemUptime,
            playerPosition: service.player.currentTime().seconds, audioFrame: audio.frame,
            audioVisit: audio.visit, audioToken: audio.token, audioUnderrunFrames: audio.underrunFrames)
    }

    private func logCapture(label: String, phase: String, started: Double, failed: Bool) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let audio = service.audioSnapshot
        print("SelectionCapture label=\(label) phase=\(phase) uptime=\(uptime) elapsed=\(uptime - started) failed=\(failed) playerPosition=\(service.player.currentTime().seconds) playerRate=\(service.player.rate) audioFrame=\(audio.frame) audioVisit=\(audio.visit) audioToken=\(audio.token) audioUnderrunFrames=\(audio.underrunFrames) engineRunning=\(service.audioEngineRunning) wantsToPlay=\(service.wantsToPlay) requested=\(service.videoRequestedPositionSeconds) timebase=\(service.videoTimebasePositionSeconds.map { String($0) } ?? "missing") copiedPTS=\(service.copiedVideoFramePositionSeconds.map { String($0) } ?? "missing") submittedPTS=\(service.videoFramePositionSeconds.map { String($0) } ?? "missing") submitted=\(service.submittedVideoFrameCount) futureRejected=\(service.pausedFutureVideoFrameRejectionCount) customReady=\(customVideoLayer?.isReadyForDisplay == true)")
    }

    #if targetEnvironment(simulator)
    private struct CaptureRequest: Encodable { let schemaVersion: Int; let requestID: String }
    private struct CaptureResponse: Decodable {
        let schemaVersion: Int
        let requestID: String
        let errorCode: Int
        let imageName: String
    }

    private func compositorImage() async throws -> UIImage {
        let manager = FileManager.default
        guard UIApplication.shared.applicationState == .active, window.isKeyWindow else {
            throw SelectionVideoTestFailure.capture
        }
        let temporary = manager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let identifier = UUID().uuidString.lowercased()
        let prefix = "OfflinePlayer-TestFrameCapture-" + identifier
        let request = temporary.appendingPathComponent(prefix + ".request.json")
        let response = temporary.appendingPathComponent(prefix + ".response.json")
        let image = temporary.appendingPathComponent(prefix + ".png")
        let paths = [request, response, image]
        for path in paths {
            guard path.deletingLastPathComponent() == temporary,
                  path.resolvingSymlinksInPath().deletingLastPathComponent() == temporary,
                  !manager.fileExists(atPath: path.path) else { throw SelectionVideoTestFailure.unsafeCapturePath }
        }
        defer { for path in paths { try? manager.removeItem(at: path) } }
        try JSONEncoder().encode(CaptureRequest(schemaVersion: 1, requestID: identifier)).write(to: request, options: .atomic)
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while !manager.fileExists(atPath: response.path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                // scripts/capture-simulator-test-frames.py must run beside the native test.
                throw SelectionVideoTestFailure.simulatorCaptureUnavailable
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        func validate(_ path: URL, maximum: Int) throws {
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard path.deletingLastPathComponent() == temporary,
                  path.resolvingSymlinksInPath().deletingLastPathComponent() == temporary,
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= maximum else {
                throw SelectionVideoTestFailure.unsafeCapturePath
            }
        }
        try validate(response, maximum: 4_096)
        let data = try Data(contentsOf: response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "requestID", "errorCode", "imageName"]) else {
            throw SelectionVideoTestFailure.unsafeCapturePath
        }
        let result = try JSONDecoder().decode(CaptureResponse.self, from: data)
        guard result.schemaVersion == 1, result.requestID == identifier,
              UUID(uuidString: result.requestID)?.uuidString.lowercased() == identifier,
              result.imageName == image.lastPathComponent else { throw SelectionVideoTestFailure.unsafeCapturePath }
        guard result.errorCode == 0 else { throw SelectionVideoTestFailure.simulatorCaptureRejected(result.errorCode) }
        try validate(image, maximum: 32 * 1_024 * 1_024)
        guard let captured = UIImage(contentsOfFile: image.path), let cg = captured.cgImage,
              UIApplication.shared.applicationState == .active, window.isKeyWindow,
              cg.width > 0, cg.height > 0, cg.width <= 10_000, cg.height <= 10_000,
              cg.width * cg.height <= 25_000_000 else { throw SelectionVideoTestFailure.capture }
        return captured
    }
    #endif
}

private struct SelectionVideoHarness: View {
    let service: PlaybackService
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FeedVideoSurface(surface: service.surface, isActive: true, isReady: service.isVideoReady) {
                Color(red: 1, green: 0, blue: 1)
            }.frame(width: 320, height: 192)
        }
    }
}

private struct SelectionVideoPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    let scaleX: Double
    let scaleY: Double
    let blueBarCenter: Double?
    let blueBarCenterY: Double?
    let captureBefore: SelectionVideoCaptureState
    var captureAfter: SelectionVideoCaptureState
    init(_ image: CGImage, scaleX: Double, scaleY: Double, captureBefore: SelectionVideoCaptureState) throws {
        width = image.width; height = image.height
        self.scaleX = scaleX; self.scaleY = scaleY
        self.captureBefore = captureBefore; self.captureAfter = captureBefore
        var storage = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = storage.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw SelectionVideoTestFailure.capture }
        bytes = storage
        var sumX = 0.0, sumY = 0.0, blueCount = 0
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            if storage[offset + 2] > 150 && storage[offset] < 100 && storage[offset + 1] < 100 {
                sumX += Double(pixel % width)
                sumY += Double(pixel / width)
                blueCount += 1
            }
        }
        blueBarCenter = blueCount >= 4 ? sumX / Double(blueCount) : nil
        blueBarCenterY = blueCount >= 4 ? sumY / Double(blueCount) : nil
    }

    func log(label: String, identity: SelectionVideoIdentity) {
        print("SelectionPixels label=\(label) expected=\(identity.rawValue) fraction=\(fraction(identity)) magenta=\(magentaFraction) blueCenterX=\(blueBarCenter.map { String($0) } ?? "missing") blueCenterY=\(blueBarCenterY.map { String($0) } ?? "missing") scaleX=\(scaleX) scaleY=\(scaleY)")
    }

    func fraction(_ identity: SelectionVideoIdentity) -> Double {
        fraction { r, g, b in identity == .a ? r > 150 && g < 100 && b < 100 : g > 150 && r < 100 && b < 100 }
    }
    var magentaFraction: Double { fraction { $0 > 150 && $1 < 100 && $2 > 150 } }
    private func fraction(_ predicate: (UInt8, UInt8, UInt8) -> Bool) -> Double {
        var count = 0
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            if predicate(bytes[offset], bytes[offset + 1], bytes[offset + 2]) { count += 1 }
        }
        return Double(count) / Double(max(1, width * height))
    }
}

/// Native ingress only. No actor-owned SDK object or fixture is captured by the callback.
private final class PreparedNextPrerollCallback: @unchecked Sendable {
    struct Snapshot { let count: Int; let finished: Bool?; let time: UInt64? }
    let token: UInt64, deadline: UInt64
    private let lock = NSLock()
    private var count = 0
    private var finished: Bool?
    private var time: UInt64?
    init(token: UInt64, deadline: UInt64) { self.token = token; self.deadline = deadline }
    func complete(token: UInt64, finished: Bool) {
        let entered = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        guard token == self.token else { count = 2; return }
        count = min(2, count + 1) // Two denotes two or more actual callbacks.
        if count == 1 { self.finished = finished; time = entered }
        // A late callback remains an ownership acknowledgement, never timely evidence.
    }
    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(count: count, finished: finished, time: time)
    }
}

#if DEBUG
/// Instrumentation bundle v2: three first owned aligned enqueues and one
/// last-false/first-true custom-compound poll pair per phase. Scalar identities only.
@MainActor
private final class RemainingLatencyWitness {
    private struct Poll {
        let entryNs: UInt64, observedNs: UInt64
        let mask: UInt16, evaluated: UInt16
        let audio: ContinuousPCMRenderer.Snapshot
        let requested: Double, copied: Double?, submittedPTS: Double?, submittedCount: UInt64
        let owner: PlaybackService.DebugAlignedVideoPollState
    }
    private struct Phase {
        var commandNs: UInt64 = 0
        var enqueue: PlaybackService.DebugAlignedVideoEnqueue?
        var lastFalse: Poll?, firstTrue: Poll?
        var lastNotFull: Poll?, firstFull: Poll?
        var pollsThroughFirstFull: UInt64 = 0
    }
    private let baseRequest: Int
    private var phases = Array(repeating: Phase(), count: 3)
    private var uncredited: UInt64 = 0, orphans: UInt64 = 0
    private var overflow = false
    init(baseRequest: Int) { self.baseRequest = baseRequest }
    private func increment(_ value: inout UInt64) {
        if value == .max { overflow = true } else { value += 1 }
    }
    func beginPhase(_ phase: Int, commandNs: UInt64) {
        guard phases.indices.contains(phase), phases[phase].commandNs == 0 else {
            increment(&orphans); return
        }
        phases[phase].commandNs = commandNs
    }
    func record(_ value: PlaybackService.DebugAlignedVideoEnqueue) {
        guard let request = value.request else { increment(&orphans); return }
        let phase = request - baseRequest - 1
        guard phases.indices.contains(phase) else { increment(&orphans); return }
        let frame = value.frame
        guard phases[phase].commandNs > 0, frame.renderEntryNs >= phases[phase].commandNs,
              frame.enqueuedNs >= frame.renderEntryNs else { increment(&orphans); return }
        guard value.generation == request, value.presentationMatches, value.observedItemMatches,
              frame.coherent, frame.ticket != nil else { increment(&uncredited); return }
        if phases[phase].enqueue == nil { phases[phase].enqueue = value }
    }
    func recordPoll(phase: Int, entryNs: UInt64, observedNs: UInt64, mask: UInt16, evaluated: UInt16,
                    state: ProductionSelectionState, owner: PlaybackService.DebugAlignedVideoPollState) {
        guard phases.indices.contains(phase), phases[phase].commandNs > 0,
              entryNs >= phases[phase].commandNs, observedNs >= entryNs else {
            increment(&orphans); return
        }
        guard phases[phase].firstTrue == nil || phases[phase].firstFull == nil else { return }
        let poll = Poll(entryNs: entryNs, observedNs: observedNs, mask: mask, evaluated: evaluated,
            audio: state.audio, requested: state.requested, copied: state.copied,
            submittedPTS: state.frame, submittedCount: state.submitted, owner: owner)
        // Mask127 is exactly the existing custom compound; videoReady/loading
        // remain visible in mask511 and retain their original acceptance guards.
        if phases[phase].firstTrue == nil {
            if mask & 127 == 127, evaluated == 511 { phases[phase].firstTrue = poll }
            else { phases[phase].lastFalse = poll }
        }
        // Independent pair: continue collecting the original full compound after custom127 latches.
        if phases[phase].firstFull == nil {
            increment(&phases[phase].pollsThroughFirstFull)
            if mask == 511, evaluated == 511 { phases[phase].firstFull = poll }
            else { phases[phase].lastNotFull = poll }
        }
    }
    private func dumpFullPolls(phase: Int, value: Phase) {
        let full = value.firstFull, previous = value.lastNotFull
        let covered = full != nil && value.pollsThroughFirstFull > 0
            && ((previous != nil) == (value.pollsThroughFirstFull > 1))
        let ordered = full.map { first in
            previous.map { $0.observedNs <= first.entryNs } ?? (value.pollsThroughFirstFull == 1)
        } ?? false
        let afterCustom = full.map { first in
            value.firstTrue.map { $0.observedNs <= first.observedNs && $0.entryNs <= first.entryNs } ?? false
        } ?? false
        print("FullCompoundPollCoverage schema=1 phase=\(phase) commandNs=\(value.commandNs) pairCapacity=2 pollsThroughFirstFull=\(value.pollsThroughFirstFull) lastNotFullAvailable=\(previous != nil) firstFullAvailable=\(full != nil) covered=\(covered) pairOrdered=\(ordered) fullAtOrAfterCustom=\(afterCustom) extraClocks=0 extraSDKQueries=0 clock=DispatchTime publication=after-cleanup")
        XCTAssertTrue(covered); XCTAssertTrue(ordered); XCTAssertTrue(afterCustom)
        if let previous { XCTAssertFalse(previous.mask == 511 && previous.evaluated == 511) }
        if let full { XCTAssertEqual(full.mask, 511); XCTAssertEqual(full.evaluated, 511) }
        for (variant, poll) in [(0, previous), (1, full)] {
            guard let poll else {
                print("FullCompoundPoll schema=1 phase=\(phase) variant=\(variant) available=false qualifyingMask=511 fullAcceptanceMask=511")
                continue
            }
            XCTAssertGreaterThanOrEqual(poll.entryNs, value.commandNs)
            XCTAssertGreaterThanOrEqual(poll.observedNs, poll.entryNs)
            let owner = poll.owner, frame = owner.frame
            let pollOrdinal = variant == 0 && value.pollsThroughFirstFull > 0
                ? value.pollsThroughFirstFull - 1 : value.pollsThroughFirstFull
            let joined = value.enqueue.map { enqueue in
                enqueue.request == owner.request && owner.generation == owner.request
                    && owner.presentationMatches && owner.observedItemMatches && frame.coherent
                    && frame.ticket == enqueue.frame.ticket && frame.output == enqueue.frame.output
                    && frame.seekSerial == enqueue.frame.seekSerial && frame.activeSeekTicket == nil
                    && frame.imageEpoch == enqueue.frame.imageEpoch && poll.entryNs >= enqueue.frame.enqueuedNs
            } ?? false
            print("FullCompoundPoll schema=1 phase=\(phase) variant=\(variant) available=true poll=\(pollOrdinal) commandNs=\(value.commandNs) entryNs=\(poll.entryNs) observedNs=\(poll.observedNs) mask=\(poll.mask) evaluatedMask=\(poll.evaluated) qualifyingMask=511 fullAcceptanceMask=511 request=\(owner.request.map { String($0) } ?? "unknown") generation=\(owner.generation) item=\(frame.ticket.map { String(describing: $0.debugItemIdentity) } ?? "unknown") ticketRevision=\(frame.ticket.map { String($0.debugGeneration) } ?? "unknown") output=\(frame.output.map { String(describing: $0) } ?? "unknown") seekSerial=\(frame.seekSerial) activeSeek=\(frame.activeSeekTicket.map { String($0) } ?? "none") imageEpoch=\(frame.imageEpoch) sameEnqueueEpoch=\(joined) token=\(poll.audio.token) visit=\(poll.audio.visit) audioFrame=\(poll.audio.frame) copiedPTS=\(poll.copied.map { String($0) } ?? "unknown") submittedPTS=\(poll.submittedPTS.map { String($0) } ?? "unknown") requested=\(poll.requested) submittedCount=\(poll.submittedCount) clock=DispatchTime stateOwnerJointCoherence=false")
        }
    }
    func dumpAndAssert() {
        print("RemainingLatencyWitnessSummary schema=2 phases=3 alignedEnqueues=\(phases.compactMap(\.enqueue).count) pollPairsCapacity=3 uncredited=\(uncredited) orphans=\(orphans) overflow=\(overflow) extraSDKQueries=0 durableFrameProof=false output=after-cleanup")
        XCTAssertFalse(overflow); XCTAssertEqual(orphans, 0); XCTAssertEqual(uncredited, 0)
        for phase in phases.indices {
            let value = phases[phase]
            XCTAssertGreaterThan(value.commandNs, 0)
            XCTAssertNotNil(value.enqueue); XCTAssertNotNil(value.firstTrue)
            if let owner = value.enqueue {
                let frame = owner.frame
                print("FirstOwnedAlignedEnqueue schema=2 phase=\(phase) commandNs=\(value.commandNs) request=\(owner.request.map { String($0) } ?? "unknown") generation=\(owner.generation) item=\(frame.ticket.map { String(describing: $0.debugItemIdentity) } ?? "unknown") ticketRevision=\(frame.ticket.map { String($0.debugGeneration) } ?? "unknown") output=\(frame.output) seekSerial=\(frame.seekSerial) imageEpoch=\(frame.imageEpoch) renderEntryNs=\(frame.renderEntryNs) enqueuedNs=\(frame.enqueuedNs) requested=\(frame.requestedSeconds) samplePTS=\(frame.sampleSeconds) submittedCount=\(frame.submittedCount) cachedAudioToken=\(owner.audioToken) cachedAudioVisit=\(owner.audioVisit) entryCoherent=\(frame.entryCoherent) afterCopyCoherent=\(frame.afterCopyCoherent) beforeEnqueueCoherent=\(frame.beforeEnqueueCoherent) afterEnqueueCoherent=\(frame.afterEnqueueCoherent) presentationMatches=\(owner.presentationMatches) observedItemMatches=\(owner.observedItemMatches) clock=DispatchTime sdkOperationDuration=false")
            }
            for (variant, poll) in [(0, value.lastFalse), (1, value.firstTrue)] {
                guard let poll else {
                    print("AlignedCompoundPoll schema=2 phase=\(phase) variant=\(variant) available=false qualifyingMask=127 fullAcceptanceMask=511")
                    continue
                }
                let owner = poll.owner, frame = owner.frame
                let joined = value.enqueue.map { enqueue in
                    enqueue.request == owner.request && owner.generation == owner.request
                        && owner.presentationMatches && owner.observedItemMatches && frame.coherent
                        && frame.ticket == enqueue.frame.ticket && frame.output == enqueue.frame.output
                        && frame.seekSerial == enqueue.frame.seekSerial && frame.activeSeekTicket == nil
                        && frame.imageEpoch == enqueue.frame.imageEpoch
                        && poll.entryNs >= enqueue.frame.enqueuedNs
                } ?? false
                print("AlignedCompoundPoll schema=2 phase=\(phase) variant=\(variant) available=true commandNs=\(value.commandNs) entryNs=\(poll.entryNs) observedNs=\(poll.observedNs) mask=\(poll.mask) evaluatedMask=\(poll.evaluated) qualifyingMask=127 fullAcceptanceMask=511 request=\(owner.request.map { String($0) } ?? "unknown") generation=\(owner.generation) item=\(frame.ticket.map { String(describing: $0.debugItemIdentity) } ?? "unknown") ticketRevision=\(frame.ticket.map { String($0.debugGeneration) } ?? "unknown") output=\(frame.output.map { String(describing: $0) } ?? "unknown") seekSerial=\(frame.seekSerial) activeSeek=\(frame.activeSeekTicket.map { String($0) } ?? "none") imageEpoch=\(frame.imageEpoch) sameEnqueueEpoch=\(joined) token=\(poll.audio.token) visit=\(poll.audio.visit) audioFrame=\(poll.audio.frame) copiedPTS=\(poll.copied.map { String($0) } ?? "unknown") submittedPTS=\(poll.submittedPTS.map { String($0) } ?? "unknown") requested=\(poll.requested) submittedCount=\(poll.submittedCount) clock=DispatchTime stateOwnerJointCoherence=false")
            }
            dumpFullPolls(phase: phase, value: value)
        }
    }
}

/// Six scalar handoffs and their first returned ordinary reads. SDK state is
/// sampled only by the original rate command/position operation, never here.
@MainActor
private final class NativeClockHandoffTrace {
    private struct Slot {
        var commands: UInt64 = 0
        var handoff: PlaybackService.DebugVideoRateHandoff?
        var read: PlaybackService.DebugVideoPositionRead?
    }
    private struct AvailabilitySlot {
        var before: PlaybackService.DebugVideoPositionRead?, after: PlaybackService.DebugVideoPositionRead?
        var beforeCount: UInt64 = 0, afterCount: UInt64 = 0
        var beforeOrdinal: UInt64 = 0, afterOrdinal: UInt64 = 0, boundaryCount: UInt64 = 0
        var point: PlaybackService.DebugVideoRenderStamp?
        var source: PlaybackService.DebugCPPNativePullStamp?
        var sourceCovered = false
        // Two value slots per phase: last stopped candidate, then frozen first-positive pair.
        var startStopped: PlaybackService.DebugVideoPositionRead?, startPositive: PlaybackService.DebugVideoPositionRead?
        var startStoppedOrdinal: UInt64 = 0, startPositiveOrdinal: UInt64 = 0
        var startReads: UInt64 = 0, startBeforeHandoff: UInt64 = 0, startRejected: UInt64 = 0
        var startUnavailable: UInt64 = 0, startOtherFinite: UInt64 = 0, startStoppedCount: UInt64 = 0
        var startOrderFailures: UInt64 = 0, startLastReturnNs: UInt64 = 0
    }
    private let enabled: Bool, baseRequest: Int
    private var slots = Array(repeating: Slot(), count: 6)
    private var orphans: UInt64 = 0, reads: UInt64 = 0
    private var overflow = false
    private var availabilitySlots: [AvailabilitySlot] = []
    private var availabilityOrphans: UInt64 = 0, availabilityOverflow = false
    init(enabled: Bool, baseRequest: Int) {
        self.enabled = enabled; self.baseRequest = baseRequest
        if enabled {
            availabilitySlots = Array(repeating: AvailabilitySlot(), count: 3)
            print("NativeClockStartScope schema=1 enabled=true phases=3 additionalReadValueCapacity=6 selection=first-qualified-returned-positive-after-sole-initial-setRate positive=rate-and-raw-and-decision-position-greater-than-zero predecessor=immediately-previous-returned-callback-stopped-rate-zero seekSerialRequired=0 counters=saturating extraGetters=0 newClockSites=0 timebaseIdentity=unavailable jointSnapshot=false unreturnedCalls=unverified publication=after-cleanup playbackAcceptance=unchanged")
            print("NativeClockAvailabilityScope schema=1 enabled=true phases=3 retainedReadsCapacity=6 nativeBoundaryCapacity=3 firstRenderPointCapacity=3 selection=last-existing-read-before-point-and-first-existing-read-after-point noAdditionalGetters=true newClockSites=0 outputIdentity=CPP-boundary-only timebaseIdentity=unavailable imageEpoch=unavailable jointSnapshot=false nativeTimeAndRateAtomic=false missingOrChangedOwnerIsUnqualified=true publication=after-cleanup playbackAcceptance=unchanged")
        }
    }
    private func incrementAvailability(_ value: inout UInt64) {
        if value == .max { availabilityOverflow = true } else { value += 1 }
    }
    func recordFirstAvailability(phase: Int, point: PlaybackService.DebugVideoRenderStamp,
        source: PlaybackService.DebugCPPNativePullStamp?, covered: Bool) {
        guard enabled, availabilitySlots.indices.contains(phase) else {
            incrementAvailability(&availabilityOrphans); return
        }
        incrementAvailability(&availabilitySlots[phase].boundaryCount)
        // Preserve the first true point, even if its ownership/coverage is invalid. Never repair it later.
        guard availabilitySlots[phase].point == nil else { return }
        availabilitySlots[phase].point = point
        availabilitySlots[phase].source = source
        availabilitySlots[phase].sourceCovered = covered
    }
    private func availabilityOwnerJoined(_ read: PlaybackService.DebugVideoPositionRead,
        source: PlaybackService.DebugCPPNativePullStamp) -> Bool {
        let p = source.pull
        return read.kind == .itemTimebase && read.request == source.request && read.returnGeneration == source.request
            && read.item == source.sourceItem && read.observedItemMatches && read.presentationUnchanged
            && read.presentationRequest == source.request && read.returnPresentationRequest == source.request
            && read.presentationTicket == p.ticket && read.returnPresentationTicket == p.ticket
            && read.entrySeekState == read.returnSeekState && read.entrySeekState.serial == p.nativeSeekTicket
            && read.entrySeekState.activeTicket == nil && read.entryNs > 0 && read.returnNs >= read.entryNs
    }
    private func dumpAvailabilityClocks() {
        for (phase, slot) in availabilitySlots.enumerated() {
            let boundaryQualified: Bool
            if let s = slot.source, let point = slot.point {
                let p = s.pull, r = point.render
                boundaryQualified = slot.sourceCovered && s.request == baseRequest + phase + 1
                    && s.generation == s.request && point.presentationRequest == s.request && point.generation == s.request
                    && p.stage == .availability && r.stage == .hasNewTrue && p.returnNs <= r.entryNs
                    && p.ticket != nil && p.ticket == r.ticket && p.returnRevision == r.presentationRevision
                    && r.ownershipUnchanged && point.presentationMatches
            } else { boundaryQualified = false }
            let beforeJoined = slot.before.flatMap { read in slot.source.map { availabilityOwnerJoined(read, source: $0) } } ?? false
            let afterJoined = slot.after.flatMap { read in slot.source.map { availabilityOwnerJoined(read, source: $0) } } ?? false
            let beforeNonoverlap = slot.before.flatMap { read in slot.source.map { read.returnNs <= $0.pull.entryNs } } ?? false
            let afterNonoverlap = slot.after.flatMap { read in slot.source.map { read.entryNs >= $0.pull.returnNs } } ?? false
            let valuesAvailable = [slot.before, slot.after].allSatisfy { read in
                read?.rawItemTimebasePosition?.isFinite == true && read?.itemTimebaseEffectiveRate?.isFinite == true
            }
            let qualified = boundaryQualified && beforeJoined && afterJoined && beforeNonoverlap && afterNonoverlap && valuesAvailable
            let selectionIntegrity = (slot.before == nil ? slot.beforeCount == 0 : slot.beforeCount > 0 && slot.beforeOrdinal == slot.beforeCount)
                && (slot.after == nil ? slot.afterCount == 0 : slot.afterCount > 0 && slot.afterOrdinal == 1)
                && ((slot.point != nil) == (slot.boundaryCount > 0))
            print("NativeClockAvailabilitySummary schema=1 phase=\(phase) request=\(baseRequest + phase + 1) readsBeforePoint=\(slot.beforeCount) readsAfterPoint=\(slot.afterCount) truePointsObserved=\(slot.boundaryCount) beforeAvailable=\(slot.before != nil) afterAvailable=\(slot.after != nil) boundaryQualified=\(boundaryQualified) beforeOwnerJoined=\(beforeJoined) afterOwnerJoined=\(afterJoined) beforeNonoverlap=\(beforeNonoverlap) afterNonoverlap=\(afterNonoverlap) nativeValuesAvailable=\(valuesAvailable) sequentialBracketQualified=\(qualified) selectionIntegrity=\(selectionIntegrity) orphans=\(availabilityOrphans) overflow=\(availabilityOverflow) jointSnapshot=false timebaseIdentity=unavailable clockOutputObserved=false imageEpoch=unavailable clock=DispatchTime")
            if let s = slot.source, let point = slot.point {
                let p = s.pull
                print("NativeClockAvailabilityBoundary schema=1 phase=\(phase) request=\(s.request) generation=\(s.generation) item=\(s.sourceItem) ticketRevision=\(p.ticket.map { String($0.debugGeneration) } ?? "unknown") output=\(p.output) seekSerial=\(p.nativeSeekTicket) sourceSeekSerial=\(p.sourceNativeSeekTicket.map { String($0) } ?? "unknown") activeSeek=\(p.activeSeekTicket.map { String($0) } ?? "none") nativeEntryNs=\(p.entryNs) nativeReturnNs=\(p.returnNs) firstTruePointNs=\(point.render.entryNs) sourceCovered=\(slot.sourceCovered) ownerUnchanged=\(p.ownerUnchanged) entryOwnerCoherent=\(p.entryOwnerCoherent) boundaryQualified=\(boundaryQualified) imageEpoch=unavailable clock=DispatchTime")
            }
            for (role, read, ordinal, joined, nonoverlap) in [(0, slot.before, slot.beforeOrdinal, beforeJoined, beforeNonoverlap), (1, slot.after, slot.afterOrdinal, afterJoined, afterNonoverlap)] {
                guard let read else {
                    print("NativeClockAvailabilityRead schema=1 phase=\(phase) role=\(role) available=false jointSnapshot=false")
                    continue
                }
                print("NativeClockAvailabilityRead schema=1 phase=\(phase) role=\(role) available=true readOrdinal=\(ordinal) kind=\(read.kind.rawValue) request=\(read.request) returnGeneration=\(read.returnGeneration) item=\(read.item) entryNs=\(read.entryNs) returnNs=\(read.returnNs) position=\(read.position) rawPosition=\(read.rawItemTimebasePosition.map { String($0) } ?? "unavailable") effectiveRate=\(read.itemTimebaseEffectiveRate.map { String($0) } ?? "unavailable") presentationRequest=\(read.presentationRequest.map { String($0) } ?? "unknown") returnPresentationRequest=\(read.returnPresentationRequest.map { String($0) } ?? "unknown") ticketRevision=\(read.presentationTicket.map { String($0.debugGeneration) } ?? "unknown") returnTicketRevision=\(read.returnPresentationTicket.map { String($0.debugGeneration) } ?? "unknown") entrySeekSerial=\(read.entrySeekState.serial) returnSeekSerial=\(read.returnSeekState.serial) entryActiveSeek=\(read.entrySeekState.activeTicket.map { String($0) } ?? "none") returnActiveSeek=\(read.returnSeekState.activeTicket.map { String($0) } ?? "none") observedItemMatches=\(read.observedItemMatches) presentationUnchanged=\(read.presentationUnchanged) ownerJoined=\(joined) nonoverlap=\(nonoverlap) outputFromBoundary=\(slot.source.map { String(describing: $0.pull.output) } ?? "unavailable") clockOutputObserved=false timebaseIdentity=unavailable imageEpoch=unavailable jointSnapshot=false nativeTimeAndRateAtomic=false clock=DispatchTime")
            }
            // Assert recorder integrity only. Missing, overlapping or changed-owner observations remain unqualified data.
            XCTAssertTrue(selectionIntegrity)
        }
        XCTAssertEqual(availabilityOrphans, 0); XCTAssertFalse(availabilityOverflow)
    }
    private func initialClockHandoffQualified(_ h: PlaybackService.DebugVideoRateHandoff, phase: Int) -> Bool {
        guard h.cause == .initialReady, slots[phase * 2].commands == 1,
              h.request == baseRequest + phase + 1, h.entryGeneration == h.request, h.returnGeneration == h.request,
              h.presentationRequest == h.request, h.returnPresentationRequest == h.request,
              let ticket = h.presentationTicket, ticket == h.returnPresentationTicket,
              ticket.debugItemIdentity == h.item, h.presentationUnchanged,
              h.entryObservedItemMatches, h.returnObservedItemMatches,
              h.entrySeekState == h.returnSeekState, h.entrySeekState.serial == 0,
              h.entrySeekState.activeTicket == nil, h.requestedRate == 1,
              h.entryNs > 0, h.returnNs >= h.entryNs else { return false }
        return true
    }
    private func startReadJoined(_ r: PlaybackService.DebugVideoPositionRead,
        handoff h: PlaybackService.DebugVideoRateHandoff, phase: Int) -> Bool {
        initialClockHandoffQualified(h, phase: phase) && r.kind == .itemTimebase
            && r.request == h.request && r.returnGeneration == h.request && r.item == h.item
            && r.presentationRequest == h.request && r.returnPresentationRequest == h.request
            && r.presentationTicket == h.returnPresentationTicket && r.returnPresentationTicket == h.returnPresentationTicket
            && r.observedItemMatches && r.presentationUnchanged
            && r.entrySeekState == h.returnSeekState && r.returnSeekState == h.returnSeekState
            && r.entryNs >= h.returnNs && r.returnNs >= r.entryNs
    }
    private func recordClockStart(_ value: PlaybackService.DebugVideoPositionRead, phase: Int) {
        guard enabled else { return }
        incrementAvailability(&availabilitySlots[phase].startReads)
        if value.entryNs < availabilitySlots[phase].startLastReturnNs || value.returnNs < value.entryNs {
            incrementAvailability(&availabilitySlots[phase].startOrderFailures)
        }
        availabilitySlots[phase].startLastReturnNs = max(availabilitySlots[phase].startLastReturnNs, value.returnNs)
        // Continue detecting overlap after selection; a late returned outer read must not silently validate it.
        guard availabilitySlots[phase].startPositive == nil else { return }
        guard let handoff = slots[phase * 2].handoff else {
            incrementAvailability(&availabilitySlots[phase].startBeforeHandoff)
            availabilitySlots[phase].startStopped = nil; availabilitySlots[phase].startStoppedOrdinal = 0
            return
        }
        guard startReadJoined(value, handoff: handoff, phase: phase) else {
            incrementAvailability(&availabilitySlots[phase].startRejected)
            availabilitySlots[phase].startStopped = nil; availabilitySlots[phase].startStoppedOrdinal = 0
            return
        }
        guard let raw = value.rawItemTimebasePosition, raw.isFinite, raw >= 0,
              let rate = value.itemTimebaseEffectiveRate, rate.isFinite,
              (value.position.isFinite && value.position >= 0) || (rate == 0 && value.position.isNaN) else {
            incrementAvailability(&availabilitySlots[phase].startUnavailable)
            availabilitySlots[phase].startStopped = nil; availabilitySlots[phase].startStoppedOrdinal = 0
            return
        }
        if rate > 0, raw > 0, value.position.isFinite, value.position > 0 {
            let next = availabilitySlots[phase].startStoppedOrdinal.addingReportingOverflow(1)
            let adjacent = availabilitySlots[phase].startStopped.map {
                !next.overflow && next.partialValue == reads && $0.returnNs <= value.entryNs
            } ?? false
            if !adjacent {
                availabilitySlots[phase].startStopped = nil; availabilitySlots[phase].startStoppedOrdinal = 0
            }
            availabilitySlots[phase].startPositive = value
            availabilitySlots[phase].startPositiveOrdinal = reads
        } else if rate == 0, value.position.isNaN || (value.position.isFinite && value.position >= 0) {
            incrementAvailability(&availabilitySlots[phase].startStoppedCount)
            availabilitySlots[phase].startStopped = value
            availabilitySlots[phase].startStoppedOrdinal = reads
        } else {
            incrementAvailability(&availabilitySlots[phase].startOtherFinite)
            availabilitySlots[phase].startStopped = nil; availabilitySlots[phase].startStoppedOrdinal = 0
        }
    }
    private func dumpClockStartRead(_ read: PlaybackService.DebugVideoPositionRead?, phase: Int, role: Int, ordinal: UInt64) {
        guard let r = read else {
            print("NativeClockStartRead schema=1 phase=\(phase) role=\(role) available=false")
            return
        }
        print("NativeClockStartRead schema=1 phase=\(phase) role=\(role) available=true callbackOrdinal=\(ordinal) kind=\(r.kind.rawValue) request=\(r.request) returnGeneration=\(r.returnGeneration) item=\(r.item) entryNs=\(r.entryNs) returnNs=\(r.returnNs) position=\(r.position) rawPosition=\(r.rawItemTimebasePosition.map { String($0) } ?? "unavailable") effectiveRate=\(r.itemTimebaseEffectiveRate.map { String($0) } ?? "unavailable") presentationRequest=\(r.presentationRequest.map(String.init) ?? "unknown") returnPresentationRequest=\(r.returnPresentationRequest.map(String.init) ?? "unknown") ticketRevision=\(r.presentationTicket.map { String($0.debugGeneration) } ?? "unknown") returnTicketRevision=\(r.returnPresentationTicket.map { String($0.debugGeneration) } ?? "unknown") entrySeekSerial=\(r.entrySeekState.serial) returnSeekSerial=\(r.returnSeekState.serial) observedItemMatches=\(r.observedItemMatches) presentationUnchanged=\(r.presentationUnchanged) timebaseIdentity=unavailable imageEpoch=unavailable outputIdentity=unavailable jointSnapshot=false nativeTimeAndRateAtomic=false unreturnedCalls=unverified clock=DispatchTime")
    }
    private func dumpClockStarts() {
        for phase in 0..<3 {
            let s = availabilitySlots[phase], h = slots[phase * 2].handoff
            let handoffQualified = h.map { initialClockHandoffQualified($0, phase: phase) } ?? false
            let positiveJoined = s.startPositive.flatMap { r in h.map { startReadJoined(r, handoff: $0, phase: phase) } } ?? false
            let stoppedJoined = s.startStopped.flatMap { r in h.map { startReadJoined(r, handoff: $0, phase: phase) } } ?? false
            let positiveQualified = positiveJoined && s.startOrderFailures == 0 && !overflow && !availabilityOverflow
            let pairQualified = positiveQualified && stoppedJoined && s.startStopped != nil
            print("NativeClockStartSummary schema=1 phase=\(phase) request=\(baseRequest + phase + 1) initialHandoffPresent=\(h != nil) initialHandoffQualified=\(handoffQualified) observedReads=\(s.startReads) beforeHandoff=\(s.startBeforeHandoff) ownerOrTimeRejected=\(s.startRejected) unavailableValues=\(s.startUnavailable) stoppedReadsBeforePositive=\(s.startStoppedCount) otherFiniteBeforePositive=\(s.startOtherFinite) readOrderFailures=\(s.startOrderFailures) positiveAvailable=\(s.startPositive != nil) immediatelyPrecedingStoppedAvailable=\(s.startPositive != nil && s.startStopped != nil) firstPositiveQualified=\(positiveQualified) sequentialStoppedPositiveBracketQualified=\(pairQualified) overflow=\(overflow || availabilityOverflow) classificationStopsAtFirstPositive=true adjacency=global-returned-callback-ordinal unreturnedCalls=unverified jointSnapshot=false timebaseIdentity=unavailable outputIdentity=unavailable clock=DispatchTime")
            dumpClockStartRead(s.startPositive == nil ? nil : s.startStopped, phase: phase, role: 0, ordinal: s.startStoppedOrdinal)
            dumpClockStartRead(s.startPositive, phase: phase, role: 1, ordinal: s.startPositiveOrdinal)
        }
    }
    private func increment(_ value: inout UInt64) {
        if value == .max { overflow = true } else { value += 1 }
    }
    func record(_ value: PlaybackService.DebugVideoRateHandoff) {
        let phase = value.request - baseRequest - 1
        guard (0..<3).contains(phase), (0..<2).contains(value.cause.rawValue) else {
            increment(&orphans); return
        }
        let index = phase * 2 + value.cause.rawValue
        increment(&slots[index].commands)
        if slots[index].handoff == nil { slots[index].handoff = value }
    }
    func record(_ value: PlaybackService.DebugVideoPositionRead) {
        increment(&reads)
        let phase = value.request - baseRequest - 1
        guard (0..<3).contains(phase) else { increment(&orphans); return }
        if enabled {
            recordClockStart(value, phase: phase)
            if availabilitySlots[phase].point == nil {
                incrementAvailability(&availabilitySlots[phase].beforeCount)
                availabilitySlots[phase].before = value
                availabilitySlots[phase].beforeOrdinal = availabilitySlots[phase].beforeCount
            } else {
                incrementAvailability(&availabilitySlots[phase].afterCount)
                if availabilitySlots[phase].after == nil {
                    availabilitySlots[phase].after = value
                    availabilitySlots[phase].afterOrdinal = availabilitySlots[phase].afterCount
                }
            }
        }
        for index in (phase * 2)..<(phase * 2 + 2) {
            guard slots[index].read == nil, let handoff = slots[index].handoff,
                  value.entryNs >= handoff.returnNs else { continue }
            // Preserve the first following read, even if its ownership fails.
            // A later matching observation must not conceal that first result.
            slots[index].read = value
        }
    }
    func dumpAndAssert() {
        let handoffs = slots.compactMap(\.handoff).count
        let following = slots.compactMap(\.read).count
        print("NativeClockHandoffSummary schema=1 enabled=\(enabled) phases=3 handoffs=\(handoffs) followingReads=\(following) capacityEach=6 observedReads=\(reads) orphans=\(orphans) overflow=\(overflow) extraNativePositionQueries=0 output=after-cleanup performanceAcceptance=unchanged")
        XCTAssertFalse(overflow); XCTAssertEqual(orphans, 0)
        XCTAssertLessThanOrEqual(handoffs, 6); XCTAssertLessThanOrEqual(following, 6)
        if !enabled {
            XCTAssertEqual(handoffs, 0); XCTAssertEqual(following, 0); XCTAssertEqual(reads, 0)
            return
        }
        for phase in 0..<3 {
            XCTAssertTrue((phase * 2..<(phase * 2 + 2)).contains { slots[$0].handoff != nil },
                          "Every actual source handoff must produce at least one scalar rate receipt")
        }
        for (index, slot) in slots.enumerated() {
            guard let handoff = slot.handoff else { continue }
            let phase = index / 2
            let ownerValid = handoff.request == handoff.entryGeneration
                && handoff.request == handoff.returnGeneration
                && handoff.presentationRequest == handoff.request
                && handoff.returnPresentationRequest == handoff.request
                && handoff.presentationUnchanged
                && handoff.entryObservedItemMatches && handoff.returnObservedItemMatches
                && handoff.entrySeekState == handoff.returnSeekState
                && handoff.entrySeekState.activeTicket == nil
            print("NativeClockHandoff schema=1 phase=\(phase) cause=\(handoff.cause.rawValue) commands=\(slot.commands) request=\(handoff.request) item=\(handoff.item) entryNs=\(handoff.entryNs) returnNs=\(handoff.returnNs) requestedRate=\(handoff.requestedRate) anchorTime=\(handoff.anchorTime.seconds) anchorHostTime=\(handoff.anchorHostTime.seconds) seekSerial=\(handoff.entrySeekState.serial) activeSeek=\(handoff.entrySeekState.activeTicket.map { String($0) } ?? "none") ownerValid=\(ownerValid) clock=DispatchTime")
            XCTAssertTrue(ownerValid)
            XCTAssertGreaterThanOrEqual(handoff.returnNs, handoff.entryNs)
            guard let read = slot.read else {
                XCTFail("A retained handoff lacks its first subsequent ordinary read"); continue
            }
            let joined = ownerValid && read.item == handoff.item
                && read.request == handoff.request && read.returnGeneration == handoff.request
                && read.presentationRequest == handoff.returnPresentationRequest
                && read.returnPresentationRequest == handoff.returnPresentationRequest
                && read.presentationTicket == handoff.returnPresentationTicket
                && read.returnPresentationTicket == handoff.returnPresentationTicket
                && read.entrySeekState == handoff.returnSeekState
                && read.returnSeekState == handoff.returnSeekState
                && read.observedItemMatches && read.presentationUnchanged
            print("NativeClockFollowingRead schema=2 phase=\(phase) cause=\(handoff.cause.rawValue) request=\(read.request) item=\(read.item) entryNs=\(read.entryNs) returnNs=\(read.returnNs) position=\(read.position) rawPosition=\(read.rawItemTimebasePosition.map { String($0) } ?? "unavailable") effectiveRate=\(read.itemTimebaseEffectiveRate.map { String($0) } ?? "unavailable") seekSerial=\(read.entrySeekState.serial) activeSeek=\(read.entrySeekState.activeTicket.map { String($0) } ?? "none") joined=\(joined) clock=DispatchTime")
            XCTAssertTrue(joined, "The first following read must retain the exact handoff owner")
        }
        dumpAvailabilityClocks()
        dumpClockStarts()
    }
}

/// Returned ordinary-position reads only; three known fresh-service requests, six value records.
@MainActor
private final class NativePositionReadDurationTrace {
    private struct Phase {
        let request: Int
        var item: ObjectIdentifier?
        var calls: UInt64 = 0, nonfinite: UInt64 = 0
        var first: PlaybackService.DebugVideoPositionRead?, maximum: PlaybackService.DebugVideoPositionRead?
    }
    private let originEnabled: Bool
    private var phases: [Phase] = []
    private var observed: UInt64 = 0, orphans: UInt64 = 0, qualityFailures: UInt64 = 0
    private var overflow = false
    init(originEnabled: Bool, baseRequest: Int) {
        self.originEnabled = originEnabled
        phases.reserveCapacity(3)
        for phase in 0..<3 {
            let request = baseRequest.addingReportingOverflow(phase + 1)
            if request.overflow { overflow = true }
            phases.append(Phase(request: request.partialValue))
        }
    }
    private func increment(_ value: inout UInt64) {
        if value == .max { overflow = true } else { value += 1 }
    }
    func record(_ value: PlaybackService.DebugVideoPositionRead) {
        increment(&observed)
        guard value.request == value.returnGeneration, value.observedItemMatches, value.presentationUnchanged,
              value.returnNs >= value.entryNs,
              let index = phases.firstIndex(where: { $0.request == value.request }) else {
            increment(&orphans); increment(&qualityFailures); return
        }
        if (phases[index].item != nil && phases[index].item != value.item)
            || (phases[index].first != nil && phases[index].first?.kind != value.kind) {
            increment(&orphans); increment(&qualityFailures); return
        }
        phases[index].item = value.item
        increment(&phases[index].calls)
        if !value.position.isFinite { increment(&phases[index].nonfinite) }
        if phases[index].first == nil { phases[index].first = value }
        let span = value.returnNs - value.entryNs
        if phases[index].maximum == nil
            || span > phases[index].maximum!.returnNs - phases[index].maximum!.entryNs {
            phases[index].maximum = value
        }
    }
    func dumpAndAssert() {
        let retained = phases.reduce(0) { $0 + ($1.first == nil ? 0 : 1) + ($1.maximum == nil ? 0 : 1) }
        print("NativePositionReadSummary schema=1 originEnabled=\(originEnabled) readTimingEnabled=true observedReturned=\(observed) orphans=\(orphans) qualityFailures=\(qualityFailures) overflow=\(overflow) phases=3 retainedRecords=\(retained) capacityRecords=6 phaseBinding=fresh-service-request-offset returnedCallsOnly=true unreturnedCalls=unverified orphanIntervals=unavailable clock=DispatchTime")
        XCTAssertFalse(overflow); XCTAssertEqual(qualityFailures, 0); XCTAssertEqual(orphans, 0)
        XCTAssertLessThanOrEqual(retained, 6)
        var accounted = orphans
        for (phase, value) in phases.enumerated() {
            let sum = accounted.addingReportingOverflow(value.calls)
            XCTAssertFalse(sum.overflow); accounted = sum.partialValue
            XCTAssertEqual(value.first == nil, value.calls == 0)
            XCTAssertEqual(value.maximum == nil, value.calls == 0)
            print("NativePositionReadCount schema=1 originEnabled=\(originEnabled) phase=\(phase) request=\(value.request) calls=\(value.calls) nonfinitePositions=\(value.nonfinite) item=\(value.item.map { String(describing: $0) } ?? "unavailable") absentRecords=unavailable")
            for (role, read) in [("first", value.first), ("maximum", value.maximum)] {
                guard let read else { continue }
                print("NativePositionReadDuration schema=1 originEnabled=\(originEnabled) phase=\(phase) request=\(read.request) role=\(role) kind=\(read.kind.rawValue) item=\(read.item) entryNs=\(read.entryNs) returnNs=\(read.returnNs) spanNs=\(read.returnNs - read.entryNs) position=\(read.position) finite=\(read.position.isFinite) returnGeneration=\(read.returnGeneration) observedItemMatches=\(read.observedItemMatches) presentationUnchanged=\(read.presentationUnchanged) decisionOutcome=unjoined clock=DispatchTime")
            }
        }
        XCTAssertEqual(observed, accounted)
    }
}
#endif
