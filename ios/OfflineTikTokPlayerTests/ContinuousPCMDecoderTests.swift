import XCTest
import AVFoundation
import AudioToolbox
import Synchronization
import PlayerCore
@testable import OfflineTikTokPlayer

#if DEBUG
enum PCMWorkerBoundaryOwnership {
    struct Retained: @unchecked Sendable {
        let decoder: ContinuousPCMDecoder, renderer: ContinuousPCMRenderer
        let gate: ContinuousPCMDecoder.DebugNativeReadGate, directory: URL
    }
    static let unresolved = Mutex<Retained?>(nil)
    static var blocksFixtures: Bool { unresolved.withLock { $0 != nil } }
}
#endif

final class ContinuousPCMDecoderTests: XCTestCase {
    func testSameRetainedAssetAdmissionWaitsForActualRetiredReaderClose() async throws {
        #if DEBUG && targetEnvironment(simulator)
        for enabled in [false, true] {
            guard !PCMWorkerBoundaryOwnership.blocksFixtures else {
                XCTFail("An unresolved actual reader close blocks new calibration owners")
                throw ContinuousPCMDecoder.Failure.cannotDecode
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let a = directory.appendingPathComponent("same-asset-A.caf")
            let b = directory.appendingPathComponent("independent-B.caf")
            let expected = Self.mailboxPattern(frames: 8_193, identity: 1)
            do {
                try writePCM(expected, to: a)
                try writePCM(Self.mailboxPattern(frames: 8_193, identity: 2), to: b)
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
            let renderer = ContinuousPCMRenderer(prefixFrames: 512, ringFrames: 1_024)
            let admission = ContinuousPCMDecoder.DebugReaderAdmissionRecorder(excludesSameAsset: enabled)
            let threadProbe = NativeReaderWaitObservation(enabled: true)
            let activity = ContinuousPCMDecoder.DebugNativeLaneActivityRecorder(beforeCopyThread: { lane, sequence in
                threadProbe.note(lane: lane, sequence: sequence)
            })
            let decoder = ContinuousPCMDecoder(renderer: renderer, debugNativeLaneActivityRecorder: activity,
                                               debugReaderAdmission: admission)
            let gate = ContinuousPCMDecoder.DebugNativeReadGate()
            decoder.debugSetNativeReadGate(gate)
            var bodyError: Error?
            var independentPreparedWhileHeld = false, exactPCM = false
            do {
                _ = try await Self.mailboxPrepare(decoder, url: a, token: 1, slot: 0)
                let source = renderer.source(at: 0)
                let initialRequest = source.streamRequest
                _ = try await Self.mailboxStateUntil(decoder, timeout: 1) { value in
                    value.stats.leasedReaders == 1 && value.stats.startingLeases == 0
                        && value.stats.retiredLeasesAwaitingClose == 0
                        && value.leases.allSatisfy { !$0.readPending }
                        && source.availableStreamFrames(for: initialRequest.epoch) == 1_024
                }
                XCTAssertTrue(gate.arm(token: 1))
                Self.mailboxAcknowledge(renderer, token: 1, frame: 2_049)
                let firstRequest = source.streamRequest
                try await Self.mailboxWait(timeout: 1, "The actual A native read must enter") { gate.didEnter }
                guard gate.isHolding, !gate.didTimeOut, (0..<3).contains(gate.enteredLane) else {
                    XCTFail("Calibration must identify the held executing native lane")
                    throw ContinuousPCMDecoder.Failure.cannotDecode
                }
                let lane = gate.enteredLane, bit = 1 << lane
                let pinned = try await Self.mailboxStateUntil(decoder, timeout: 1) { value in
                    let lease = value.leases[lane], slot = value.slots[0]
                    return slot.epoch == firstRequest.epoch && slot.leaseIndex == lane
                        && lease.present && !lease.starting && !lease.retired && lease.readPending
                        && lease.admissionLeaseID > 0 && lease.admissionAssetID > 0
                }
                let heldLease = pinned.leases[lane]
                let cutoff = try XCTUnwrap(pinned.admission).events.count
                // Context was captured on THIS executing lane before the gate.
                // copyEntered has deliberately not published yet: this is a known
                // calibration wait before the SDK call, never an SDK-wait claim.
                let boundary = try XCTUnwrap(activity.snapshot(at: lane))
                XCTAssertFalse(boundary.sequenceOverflowed)
                let sample = threadProbe.calibrationSample(lane: lane, sequence: boundary.copySequence + 1)
                XCTAssertEqual(threadProbe.calibrationSample(lane: lane, sequence: boundary.copySequence + 2)["available"] as? Bool, false)
                XCTAssertEqual(threadProbe.calibrationSample(lane: -1, sequence: boundary.copySequence + 1)["available"] as? Bool, false)
                XCTAssertEqual(sample["available"] as? Bool, true)
                XCTAssertEqual(sample["contextUnchanged"] as? Bool, true)
                XCTAssertEqual(sample["basicReturn"] as? Int, 0)
                XCTAssertEqual(sample["basicValid"] as? Bool, true)
                XCTAssertEqual(sample["registerReturn"] as? Int, 0)
                XCTAssertEqual(sample["runState"] as? Int, 3, "Known gate must be observed waiting")
                var calibration = sample
                calibration["calibration"] = true; calibration["gateBeforeSDK"] = true
                calibration["gateHolding"] = gate.isHolding && !gate.didTimeOut
                calibration["admissionLeaseID"] = heldLease.admissionLeaseID
                let data = try JSONSerialization.data(withJSONObject: calibration, options: [.sortedKeys])
                XCTAssertLessThanOrEqual(data.count, 16_384)
                print("NativeReaderWaitCalibration " + String(decoding: data, as: UTF8.self))
                Self.mailboxAcknowledge(renderer, token: 1, frame: 2_203)
                let latestRequest = source.streamRequest
                XCTAssertNotEqual(latestRequest.epoch, firstRequest.epoch)
                XCTAssertEqual(latestRequest.startFrame, 2_203)
                let held = try await Self.mailboxStateUntil(decoder, timeout: 1) { value in
                    guard gate.isHolding, !gate.didTimeOut, let receipt = value.admission,
                          receipt.events.count >= cutoff else { return false }
                    let lease = value.leases[lane], slot = value.slots[0]
                    guard lease.present && lease.retired && lease.readPending,
                          lease.admissionLeaseID == heldLease.admissionLeaseID,
                          lease.admissionAssetID == heldLease.admissionAssetID else { return false }
                    return receipt.events.dropFirst(cutoff).contains { event in
                        guard event.asset == heldLease.admissionAssetID && event.token == 1,
                              event.matchingMask & bit != 0, event.retiredMask & bit != 0 else { return false }
                        if enabled { return event.kind == 2 && event.freeMask != 0 && slot.stream == nil }
                        return event.kind == 1 && event.lease != heldLease.admissionLeaseID
                            && slot.epoch == latestRequest.epoch && slot.leaseIndex == event.lane
                    }
                }
                let receipt = try XCTUnwrap(held.admission)
                Self.assertMailboxBounds(held.stats)
                XCTAssertFalse(receipt.overflowed)
                XCTAssertTrue(gate.isHolding); XCTAssertFalse(gate.didTimeOut)
                XCTAssertGreaterThan(held.stats.retiredLeasesAwaitingClose, 0)
                let later = receipt.events.dropFirst(cutoff)
                XCTAssertFalse(later.contains { $0.kind == 3 && $0.lease == heldLease.admissionLeaseID })
                if enabled {
                    XCTAssertGreaterThan(receipt.exclusions, 0); XCTAssertEqual(receipt.overlaps, 0)
                } else { XCTAssertGreaterThan(receipt.overlaps, 0) }
                // A distinct retained asset can prepare while the A read remains held.
                _ = try await Self.mailboxPrepare(decoder, url: b, token: 2, slot: 1, timeout: 1)
                independentPreparedWhileHeld = gate.isHolding && !gate.didTimeOut
                XCTAssertTrue(gate.isHolding); XCTAssertFalse(gate.didTimeOut)
                gate.release()
                let request = source.streamRequest
                try await Self.mailboxWait(timeout: 2, "The actual latest A epoch must refill after held read release") {
                    source.availableStreamFrames(for: request.epoch) >= 32
                }
                var pcm = [Float](repeating: .nan, count: 64)
                renderer.setPlaying(true)
                pcm.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 32) }
                renderer.setPlaying(false)
                assertSamples(pcm, equal: Array(expected[Int(request.startFrame) * 2..<Int(request.startFrame + 32) * 2]))
                exactPCM = pcm == Array(expected[Int(request.startFrame) * 2..<Int(request.startFrame + 32) * 2])
                XCTAssertFalse(gate.didTimeOut)
            } catch { bodyError = error }
            gate.release(); renderer.setPlaying(false); decoder.shutdown()
            let closed = Mutex<(Bool, ContinuousPCMDecoder.DebugReaderAdmissionState?)?>(nil)
            decoder.debugAfterShutdownWithAdmission { acknowledged, state in closed.withLock { $0 = (acknowledged, state) } }
            do {
                try await Self.mailboxWait(timeout: 2, "Actual close acceptance is required before calibration fixture removal") {
                    closed.withLock { $0 } != nil
                }
                guard closed.withLock({ $0?.0 }) == true else { throw ContinuousPCMDecoder.Failure.cannotDecode }
            } catch {
                PCMWorkerBoundaryOwnership.unresolved.withLock {
                    $0 = .init(decoder: decoder, renderer: renderer, gate: gate, directory: directory)
                }
                XCTFail("Exact unresolved same-asset calibration owners retained; no later fixture allocation")
                throw bodyError ?? error
            }
            threadProbe.close(); XCTAssertTrue(threadProbe.requestsClosed)
            threadProbe.dump(cleanupAcknowledged: true)
            XCTAssertEqual(threadProbe.calibrationSample(lane: 0, sequence: 1)["available"] as? Bool, false)
            let final = try XCTUnwrap(closed.withLock { $0?.1 })
            XCTAssertFalse(final.overflowed)
            var live: [Int: Set<Int>] = [:]
            for e in final.events {
                if e.kind == 1 {
                    if enabled { XCTAssertTrue(live[e.asset, default: []].isEmpty); XCTAssertEqual(e.matchingMask, 0) }
                    live[e.asset, default: []].insert(e.lease)
                } else if e.kind == 3 {
                    XCTAssertNotNil(live[e.asset]?.remove(e.lease), "Only an actually admitted lease can close")
                }
            }
            XCTAssertTrue(live.values.allSatisfy { $0.isEmpty })
            XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
            print("SameAssetAdmissionCalibration schema=1 enabled=\(enabled) exclusions=\(final.exclusions) overlaps=\(final.overlaps) events=\(final.events.count) actualCleanupAcknowledged=true independentAssetPreparedWhileHeld=\(independentPreparedWhileHeld) exactPCM=\(exactPCM) bodyCompleted=\(bodyError == nil) gateMaximumSeconds=5 sourceIdentity=retained-asset-instance sdkInternalWait=false")
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Acknowledged same-asset fixture removal failed"); throw bodyError ?? error }
            if let bodyError { throw bodyError }
        }
        #else
        XCTFail("Same-asset admission/own-thread calibration requires DEBUG Simulator")
        #endif
    }

    func testWorkerBoundaryReceiptSeparatesHeldConversionFromQueuedShutdown() async throws {
        #if DEBUG
        guard !PCMWorkerBoundaryOwnership.blocksFixtures else {
            XCTFail("A prior worker calibration did not acknowledge cleanup; no new calibration owners may be created")
            throw ContinuousPCMDecoder.Failure.cannotDecode
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("worker-boundary.caf")
        do { try writePCM(Self.mailboxPattern(frames: 8_193, identity: 1), to: url) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        let renderer = ContinuousPCMRenderer(prefixFrames: 512, ringFrames: 1_024)
        let recorder = ContinuousPCMDecoder.DebugNativeLaneActivityRecorder()
        let decoder = ContinuousPCMDecoder(renderer: renderer, debugNativeLaneActivityRecorder: recorder)
        let gate = ContinuousPCMDecoder.DebugNativeReadGate()
        decoder.debugSetWorkerConversionGate(gate)
        var bodyError: Error?
        do {
        _ = try await Self.mailboxPrepare(decoder, url: url, token: 1, slot: 0)
        XCTAssertTrue(gate.arm(token: 1))
        Self.mailboxAcknowledge(renderer, token: 1, frame: 2_049)
        try await Self.mailboxWait(timeout: 1, "The actual worker conversion boundary must enter") { gate.didEnter }
        guard gate.isHolding, !gate.didTimeOut else { throw ContinuousPCMDecoder.Failure.cannotDecode }
        let held = recorder.workerSnapshot()
        XCTAssertFalse(held.overflowed); XCTAssertGreaterThan(held.sequence, 0)
        XCTAssertEqual(held.token, 1)
        XCTAssertEqual(held.stageCode, ContinuousPCMDecoder.DebugWorkerActivityStage.converterEntered.rawValue)
        let reply = Mutex<Bool>(false), acknowledgement = Mutex<Bool?>(nil)
        decoder.debugFailureState { _ in reply.withLock { $0 = true } }
        decoder.shutdown(); decoder.debugAfterShutdown { value in acknowledgement.withLock { $0 = value } }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(gate.isHolding); XCTAssertFalse(gate.didTimeOut)
        XCTAssertEqual(recorder.workerSnapshot().packedState, held.packedState)
        XCTAssertFalse(reply.withLock { $0 }); XCTAssertNil(acknowledgement.withLock { $0 })
        gate.release()
        try await Self.mailboxWait(timeout: 2, "Released worker must run queued request and actual reader cleanup") {
            reply.withLock { $0 } && acknowledgement.withLock { $0 } != nil
        }
        XCTAssertEqual(acknowledgement.withLock { $0 }, true)
        let closed = try await Self.mailboxStats(decoder)
        Self.assertMailboxBounds(closed); XCTAssertTrue(closed.readerLeasesClosed)
        XCTAssertEqual(closed.leasedReaders, 0); XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        XCTAssertFalse(gate.didTimeOut)
        let after = recorder.workerSnapshot()
        XCTAssertFalse(after.overflowed); XCTAssertGreaterThan(after.sequence, held.sequence)
        print("PCMWorkerBoundaryCalibration schema=1 heldPacked=\(held.packedState) heldSequence=\(held.sequence) heldStage=\(held.stageCode) heldToken=\(held.token) laterPacked=\(after.packedState) laterSequence=\(after.sequence) laterStage=\(after.stageCode) actualQueuedRequest=true actualShutdownAcknowledged=\(acknowledgement.withLock { $0 } == true) gateMaximumSeconds=5 gateScope=before-real-converter-call sdkInternalWait=false publication=one-packed-word")
        } catch { bodyError = error }
        gate.release(); renderer.setPlaying(false); decoder.shutdown()
        let cleanup = Mutex<Bool?>(nil)
        decoder.debugAfterShutdown { value in cleanup.withLock { $0 = value } }
        do {
            try await Self.mailboxWait(timeout: 2, "Calibration must join actual decoder close before another fixture") {
                cleanup.withLock { $0 } != nil
            }
            guard cleanup.withLock({ $0 }) == true else { throw ContinuousPCMDecoder.Failure.cannotDecode }
        } catch {
            PCMWorkerBoundaryOwnership.unresolved.withLock {
                $0 = .init(decoder: decoder, renderer: renderer, gate: gate, directory: directory)
            }
            XCTFail("Worker calibration cleanup did not acknowledge; exact owners and fixture retained, later fixture creation blocked")
            throw bodyError ?? error
        }
        print("PCMWorkerBoundaryCleanup schema=1 acknowledged=true fixtureRemoveAllowed=true originalBodyError=\(bodyError != nil) retainedUnresolved=false")
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Acknowledged calibration fixture removal failed"); throw bodyError ?? error }
        if let bodyError { throw bodyError }
        #else
        XCTFail("Worker boundary calibration requires DEBUG")
        #endif
    }

    // Bounded native-reader lifecycle and complete-presentation regressions.
    // These tests use worker-coherent DEBUG counters; they do not
    // characterize SDK-internal cancellation, memory, thread count or wait causes.
    func testShutdownAcknowledgementWaitsForHeldNativeReadAndEveryLeaseClose() async throws {
        #if DEBUG
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("held-shutdown.caf")
        do { try writePCM(Self.mailboxPattern(frames: 8_193, identity: 1), to: url) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        let renderer = ContinuousPCMRenderer(prefixFrames: 512, ringFrames: 1_024)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        let gate = ContinuousPCMDecoder.DebugNativeReadGate()
        decoder.debugSetNativeReadGate(gate)
        defer {
            gate.release(); renderer.setPlaying(false); decoder.shutdown()
            decoder.debugAfterShutdown { closed in
                if closed { try? FileManager.default.removeItem(at: directory) }
            }
        }
        _ = try await Self.mailboxPrepare(decoder, url: url, token: 1, slot: 0)
        XCTAssertTrue(gate.arm(token: 1))
        // Paused selection publishes a real nonprefix request without spending
        // samples or making the deliberate blocked call an audio underrun.
        Self.mailboxAcknowledge(renderer, token: 1, frame: 2_049)
        try await Self.mailboxWait(timeout: 1, "The controlled native read must enter") { gate.didEnter }
        guard gate.isHolding, !gate.didTimeOut else { throw ContinuousPCMDecoder.Failure.cannotDecode }

        let acknowledgement = Mutex<Bool?>(nil)
        decoder.shutdown()
        decoder.debugAfterShutdown { value in acknowledgement.withLock { $0 = value } }
        let held = try await Self.mailboxStatsUntil(decoder, timeout: 0.5) {
            $0.shutdownRequested && $0.retiredLeasesAwaitingClose > 0
        }
        Self.assertMailboxBounds(held)
        XCTAssertFalse(held.readerLeasesClosed)
        XCTAssertGreaterThan(held.leasedReaders, 0)
        XCTAssertNil(acknowledgement.withLock { $0 }, "Stopped=true alone cannot acknowledge a still-held lease")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(gate.isHolding); XCTAssertFalse(gate.didTimeOut)
        XCTAssertNil(acknowledgement.withLock { $0 }, "Shutdown acknowledgement must stay pending until native return/close")

        gate.release()
        try await Self.mailboxWait(timeout: 2, "Released native read must finish actual queued shutdown") {
            acknowledgement.withLock { $0 } != nil
        }
        XCTAssertEqual(acknowledgement.withLock { $0 }, true)
        let closed = try await Self.mailboxStats(decoder)
        Self.assertMailboxBounds(closed)
        XCTAssertTrue(closed.shutdownRequested); XCTAssertTrue(closed.readerLeasesClosed)
        XCTAssertEqual(closed.leasedReaders, 0); XCTAssertEqual(closed.retiredLeasesAwaitingClose, 0)
        XCTAssertEqual(closed.startingLeases, 0); XCTAssertEqual(closed.pendingPreparations, 0)
        XCTAssertEqual(closed.readJobsAwaitingAcceptanceOrClose, 0); XCTAssertEqual(closed.mailboxPackets, 0)
        XCTAssertEqual(closed.pendingOrMailboxPacketSlots, 0); XCTAssertEqual(closed.packetAllocationUpperBound, 0)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0); XCTAssertFalse(gate.didTimeOut)
        print("PCM_MAILBOX_SHUTDOWN heldLeases=\(held.leasedReaders) heldRetired=\(held.retiredLeasesAwaitingClose) finalLeases=\(closed.leasedReaders) acknowledged=\(acknowledgement.withLock { $0 } == true) gateMaximumSeconds=5 sdkInternalQuiescence=unverified")
        #endif
    }

    func testRetiredHeldReadersKeepTheirPermitsAcrossEpochsAndPendingPreparations() async throws {
        #if DEBUG
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldURLs = (0..<3).map { directory.appendingPathComponent("retired-old-\($0).caf") }
        let newURLs = (0..<3).map { directory.appendingPathComponent("retired-new-\($0).caf") }
        let newPCM = (0..<3).map { Self.mailboxPattern(frames: 8_193, identity: $0 + 4) }
        do {
            for slot in 0..<3 {
                try writePCM(Self.mailboxPattern(frames: 8_193, identity: slot + 1), to: oldURLs[slot])
                try writePCM(newPCM[slot], to: newURLs[slot])
            }
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
        let renderer = ContinuousPCMRenderer(prefixFrames: 512, ringFrames: 1_024)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        let gates = (0..<3).map { _ in ContinuousPCMDecoder.DebugNativeReadGate() }
        var jobs: [Task<Void, Never>] = []
        defer {
            gates.forEach { $0.release() }; jobs.forEach { $0.cancel() }
            renderer.setPlaying(false); decoder.shutdown()
            decoder.debugAfterShutdown { closed in
                if closed { try? FileManager.default.removeItem(at: directory) }
            }
        }
        for slot in 0..<3 {
            decoder.debugSetNativeReadGate(gates[slot])
            _ = try await Self.mailboxPrepare(decoder, url: oldURLs[slot], token: slot + 1, slot: slot)
        }
        var observedStats: [ContinuousPCMDecoder.DebugWorkerStats] = []
        observedStats.reserveCapacity(12)
        observedStats.append(try await Self.mailboxStats(decoder))
        let memory = renderer.retainedPCMMemoryBytes
        for slot in 0..<3 {
            let token = slot + 1, source = renderer.source(at: slot), gate = gates[slot]
            XCTAssertTrue(gate.arm(token: token))
            Self.mailboxAcknowledge(renderer, token: token, frame: 2_049)
            try await Self.mailboxWait(timeout: 0.75, "Each source must enter its actual controlled native read") { gate.didEnter }
            guard gate.isHolding, !gate.didTimeOut else { throw ContinuousPCMDecoder.Failure.cannotDecode }
            let firstEpoch = source.streamRequest.epoch
            // Every command is consumed while paused. Obsolete requests cannot
            // acquire uncounted leases or publish a later request's ring data.
            for frame in [Int64(2_303), 2_701, 3_201, 2_111] {
                Self.mailboxAcknowledge(renderer, token: token, frame: frame)
            }
            let last = source.streamRequest
            XCTAssertGreaterThan(last.epoch, firstEpoch); XCTAssertEqual(last.startFrame, 2_111)
            XCTAssertEqual(source.availableStreamFrames(for: last.epoch), 0)
            Self.mailboxAcknowledge(renderer, token: 0, frame: 0)
            XCTAssertTrue(renderer.retireSource(at: slot))
            XCTAssertEqual(source.token, 0)
            decoder.retain(tokens: Set(((slot + 1)..<3).map { $0 + 1 }))
            let stats = try await Self.mailboxStatsUntil(decoder, timeout: 0.5) {
                $0.retiredLeasesAwaitingClose >= slot + 1
            }
            observedStats.append(stats)
        }
        let held = try await Self.mailboxStats(decoder)
        observedStats.append(held)
        XCTAssertEqual(held.leasedReaders, 3); XCTAssertEqual(held.retiredLeasesAwaitingClose, 3)
        XCTAssertFalse(held.readerLeasesClosed)
        XCTAssertTrue(gates.allSatisfy { $0.isHolding && !$0.didTimeOut })

        let results = Mutex<[Int: Result<ContinuousPCMDecoder.Prepared, ContinuousPCMDecoder.Failure>]>([:])
        for slot in 0..<3 {
            let url = newURLs[slot], token = slot + 4
            jobs.append(Task {
                do {
                    let prepared = try await decoder.prepare(url: url, token: token, slot: slot)
                    results.withLock { $0[token] = .success(prepared) }
                } catch { results.withLock { $0[token] = .failure((error as? ContinuousPCMDecoder.Failure) ?? .cannotDecode) } }
            })
        }
        // Registration is observed on the real worker, not inferred from a delay.
        let pending = try await Self.mailboxStatsUntil(decoder, timeout: 0.75) { $0.pendingPreparations == 3 }
        observedStats.append(pending)
        XCTAssertTrue(results.withLock { $0.isEmpty })
        XCTAssertEqual(pending.leasedReaders, 3); XCTAssertEqual(pending.retiredLeasesAwaitingClose, 3)
        XCTAssertTrue((0..<3).allSatisfy { renderer.source(at: $0).token == 0 })
        let duplicate = Mutex<ContinuousPCMDecoder.Failure?>(nil)
        jobs.append(Task {
            do {
                _ = try await decoder.prepare(url: newURLs[0], token: 7, slot: 0)
                duplicate.withLock { $0 = .cannotDecode }
            } catch { duplicate.withLock { $0 = (error as? ContinuousPCMDecoder.Failure) ?? .cannotDecode } }
        })
        try await Self.mailboxWait(timeout: 0.5, "A fourth preparation must be rejected without another descriptor") {
            duplicate.withLock { $0 } != nil
        }
        XCTAssertEqual(duplicate.withLock { $0 }, .slotInUse)
        let stillHeld = try await Self.mailboxStats(decoder)
        observedStats.append(stillHeld)
        XCTAssertEqual(stillHeld.pendingPreparations, 3); XCTAssertEqual(stillHeld.leasedReaders, 3)
        XCTAssertTrue(results.withLock { $0.isEmpty })
        XCTAssertTrue(gates.allSatisfy { $0.isHolding && !$0.didTimeOut })
        gates.forEach { $0.release() }
        try await Self.mailboxWait(timeout: 3, "Releasing retired reads must permit all three queued replacements") {
            results.withLock { $0.count == 3 }
        }
        for token in 4...6 {
            let result = try XCTUnwrap(results.withLock { $0[token] })
            switch result {
            case .success(let prepared): XCTAssertEqual(prepared.token, token); XCTAssertEqual(prepared.totalFrames, 8_193)
            case .failure(let failure): XCTFail("Replacement preparation failed: \(failure)"); throw failure
            }
        }
        // All three replacements have different PCM from their retired source.
        // Their full prepared prefix+ring detects stale completion acceptance.
        for slot in 0..<3 {
            Self.mailboxAcknowledge(renderer, token: slot + 4, frame: 0)
            renderer.setPlaying(true)
            var actual = [Float](repeating: .nan, count: 1_536 * 2)
            actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1_536) }
            renderer.setPlaying(false)
            assertSamples(actual, equal: Array(newPCM[slot].prefix(actual.count)))
        }
        Self.mailboxAcknowledge(renderer, token: 4, frame: 3_201)
        let current = renderer.source(at: 0), epoch = current.streamRequest.epoch
        try await Self.mailboxWait(timeout: 2, "The latest current epoch must eventually receive its exact nonprefix span") {
            current.availableStreamFrames(for: epoch) >= 193
        }
        renderer.setPlaying(true)
        var actual = [Float](repeating: .nan, count: 193 * 2)
        actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 193) }
        renderer.setPlaying(false)
        assertSamples(actual, equal: Array(newPCM[0][(3_201 * 2)..<(3_394 * 2)]))
        XCTAssertEqual(renderer.snapshot.token, 4); XCTAssertEqual(renderer.snapshot.frame, 3_394)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0); XCTAssertEqual(renderer.retainedPCMMemoryBytes, memory)
        observedStats.append(try await Self.mailboxStats(decoder))
        for stats in observedStats { Self.assertMailboxBounds(stats) }
        XCTAssertTrue(gates.allSatisfy { !$0.didTimeOut })
        let closed = try await Self.mailboxShutdown(decoder)
        Self.assertMailboxBounds(closed)
        XCTAssertTrue(closed.readerLeasesClosed); XCTAssertEqual(closed.leasedReaders, 0)
        XCTAssertEqual(closed.pendingPreparations, 0); XCTAssertEqual(closed.peakLeasedReaders, 3)
        print("PCM_MAILBOX_RETIREMENT heldRetired=\(held.retiredLeasesAwaitingClose) pendingPreparations=\(pending.pendingPreparations) peakLeases=\(closed.peakLeasedReaders) maximumLeases=3 maximumPacketAllocationCapacity=6 exactCurrentFrames=193 underruns=\(renderer.snapshot.underrunFrames) retainedPCMBytes=\(memory) gateMaximumSeconds=5 sdkRSS=unmeasured")
        #endif
    }

    func testPositiveInputRanDryOutputSurvivesReal44100ConversionThroughItsExactTail() async throws {
        #if DEBUG
        try await assertReal44100ConversionThroughItsExactTail(controlledStatus: false)
        try await assertReal44100ConversionThroughItsExactTail(controlledStatus: true)
        #endif
    }

    #if DEBUG
    private func assertReal44100ConversionThroughItsExactTail(controlledStatus: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("positive-input-ran-dry-44100.caf")
        let native = (0..<9_801).flatMap { frame -> [Float] in
            let value = Float(sin(Double(frame) * 0.071)) * 0.2
            return [value, -value]
        }
        do { try writePCM(native, to: url, sampleRate: 44_100) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        let renderer = ContinuousPCMRenderer(prefixFrames: 512, ringFrames: 1_024)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer {
            renderer.setPlaying(false); decoder.shutdown()
            decoder.debugAfterShutdown { closed in
                if closed { try? FileManager.default.removeItem(at: directory) }
            }
        }
        let expected = try await independentlyDecode(AVURLAsset(url: url), diagnosticName: "mailbox-44100-tail")
        XCTAssertEqual(expected.count, 10_668 * 2)
        XCTAssertGreaterThan(abs(try XCTUnwrap(expected.suffix(2).first)), 0.01,
                             "The final fractional frame must contain calculated source content")
        let failures = Mutex<[ContinuousPCMDecoder.Failure]>([])
        let reports = Mutex<[(Int, ContinuousPCMDecoder.SourceSilence)]>([])
        decoder.setFailureHandler { _, failure in failures.withLock { $0.append(failure) } }
        decoder.setSourceSilenceHandler { token, value in reports.withLock { $0.append((token, value)) } }
        let initial = try await Self.mailboxStats(decoder)
        XCTAssertEqual(initial.positiveInputRanDryBuffersRetained, 0)
        XCTAssertEqual(initial.positiveInputRanDryFramesRetained, 0)
        XCTAssertEqual(initial.nativePositiveInputRanDryBuffersRetained, 0)
        XCTAssertEqual(initial.nativePositiveInputRanDryFramesRetained, 0)
        XCTAssertEqual(initial.injectedPositiveInputRanDryBuffersRetained, 0)
        XCTAssertEqual(initial.injectedPositiveInputRanDryFramesRetained, 0)
        XCTAssertFalse(initial.positiveInputRanDryContractInjectionEnabled, "A fresh decoder must default to the unmodified native status path")
        if controlledStatus {
            decoder.debugSetPositiveInputRanDryContractInjectionEnabled(true)
            let armed = try await Self.mailboxStats(decoder)
            XCTAssertTrue(armed.positiveInputRanDryContractInjectionEnabled)
        }
        let prepared = try await Self.mailboxPrepare(decoder, url: url, token: 1, slot: 0)
        XCTAssertEqual(prepared.totalFrames, 10_668)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        let graph = ContinuousAudioGraph(renderer: renderer)
        try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 257)
        try graph.engine.start()
        defer { graph.engine.stop() }
        var actual: [Float] = []
        actual.reserveCapacity(expected.count)
        while actual.count < expected.count {
            let count = min(127, (expected.count - actual.count) / 2)
            try await Self.waitForPreparedFrames(renderer, count: count, totalFrames: prepared.totalFrames, timeout: 2)
            actual.append(contentsOf: try render(graph, frames: count))
        }
        graph.engine.stop(); renderer.setPlaying(false)
        // A terminal observation is required. Pending native input is not EOF,
        // and no progress/counter may replace the full reference comparison.
        try await Self.mailboxWait(timeout: 2, "The complete native presentation must actually reach EOF") {
            reports.withLock { !$0.isEmpty }
        }
        let final = try await Self.mailboxStats(decoder)
        Self.assertMailboxBounds(final)
        if controlledStatus {
            XCTAssertEqual(final.injectedPositiveInputRanDryBuffersRetained, 1,
                           "Exactly one real positive haveData result must reach the controlled inputRanDry contract")
            XCTAssertGreaterThan(final.injectedPositiveInputRanDryFramesRetained, 0)
            XCTAssertGreaterThan(final.positiveInputRanDryBuffersRetained, 0,
                                 "The controlled status arm must exercise positive-output inputRanDry without inventing PCM")
            XCTAssertGreaterThan(final.positiveInputRanDryFramesRetained, 0)
        } else {
            XCTAssertEqual(final.injectedPositiveInputRanDryBuffersRetained, 0)
            XCTAssertEqual(final.injectedPositiveInputRanDryFramesRetained, 0)
        }
        XCTAssertEqual(final.positiveInputRanDryContractInjectionEnabled, controlledStatus)
        let buffers = final.nativePositiveInputRanDryBuffersRetained.addingReportingOverflow(final.injectedPositiveInputRanDryBuffersRetained)
        let frames = final.nativePositiveInputRanDryFramesRetained.addingReportingOverflow(final.injectedPositiveInputRanDryFramesRetained)
        XCTAssertFalse(buffers.overflow); XCTAssertFalse(frames.overflow)
        XCTAssertEqual(final.positiveInputRanDryBuffersRetained, buffers.partialValue)
        XCTAssertEqual(final.positiveInputRanDryFramesRetained, frames.partialValue)
        XCTAssertGreaterThanOrEqual(final.positiveInputRanDryFramesRetained, final.positiveInputRanDryBuffersRetained)
        assertSamples(actual, equal: expected)
        assertSamples(Array(actual.suffix(64)), equal: Array(expected.suffix(64)))
        XCTAssertEqual(renderer.snapshot.frame, prepared.totalFrames)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        XCTAssertTrue(failures.withLock { $0.isEmpty })
        let analyses = reports.withLock { $0 }
        XCTAssertEqual(analyses.count, 1); XCTAssertEqual(analyses.first?.0, 1)
        XCTAssertEqual(analyses.first?.1.totalFrames, prepared.totalFrames)
        let closed = try await Self.mailboxShutdown(decoder)
        XCTAssertTrue(closed.readerLeasesClosed); XCTAssertEqual(closed.leasedReaders, 0)
        print("PCM_MAILBOX_CONVERTER nativeRate=44100 outputRate=48000 referenceFrames=10668 actualFrames=\(actual.count / 2) positiveInputRanDryBuffersRetained=\(final.positiveInputRanDryBuffersRetained) positiveInputRanDryFramesRetained=\(final.positiveInputRanDryFramesRetained) sourceReports=\(analyses.count) underruns=\(renderer.snapshot.underrunFrames) retainedCounterMeaning=stream-output-before-cursor-discard")
        print("PCM_MAILBOX_CONVERTER_STATUS controlledStatus=\(controlledStatus) nativePositiveBuffers=\(final.nativePositiveInputRanDryBuffersRetained) nativePositiveFrames=\(final.nativePositiveInputRanDryFramesRetained) injectedPositiveBuffers=\(final.injectedPositiveInputRanDryBuffersRetained) injectedPositiveFrames=\(final.injectedPositiveInputRanDryFramesRetained) nativeBranchObserved=\(final.nativePositiveInputRanDryBuffersRetained > 0) controlMeaning=one-real-positive-status-substitution-no-PCM-substitution")
    }
    #endif

    func testExactlyPinnedSourceDrainsTrueEOFAndReportsItsRealLeadingAndTrailingZerosOnce() async throws {
        #if DEBUG
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("exact-prefix-with-zeros.caf")
        let expected = (0..<512).flatMap { frame -> [Float] in
            let value: Float = frame < 3 || frame >= 507 ? 0 : Float(frame % 31 + 1) / 64
            return [value, -value]
        }
        do { try writePCM(expected, to: url) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        let renderer = ContinuousPCMRenderer(prefixFrames: 512, ringFrames: 1_024)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer {
            renderer.setPlaying(false); decoder.shutdown()
            decoder.debugAfterShutdown { closed in
                if closed { try? FileManager.default.removeItem(at: directory) }
            }
        }
        let reports = Mutex<[(Int, ContinuousPCMDecoder.SourceSilence)]>([])
        let failures = Mutex<[ContinuousPCMDecoder.Failure]>([])
        decoder.setSourceSilenceHandler { token, value in reports.withLock { $0.append((token, value)) } }
        decoder.setFailureHandler { _, failure in failures.withLock { $0.append(failure) } }
        let prepared = try await Self.mailboxPrepare(decoder, url: url, token: 1, slot: 0)
        // Preparation's original EOF probe is required even when no sample is
        // left for the ring. Later playback cannot repair a premature return.
        let beforePlayback = reports.withLock { $0 }
        XCTAssertEqual(beforePlayback.count, 1, "Exactly filling the pinned prefix must still drain actual EOF during preparation")
        let analysis = try XCTUnwrap(beforePlayback.first)
        XCTAssertEqual(analysis.0, 1); XCTAssertEqual(analysis.1.totalFrames, 512)
        XCTAssertEqual(analysis.1.leadingFrames, 3); XCTAssertEqual(analysis.1.trailingFrames, 5)
        XCTAssertEqual(analysis.1.peak, 31.0 / 64.0)
        XCTAssertEqual(prepared.totalFrames, 512)
        XCTAssertEqual(renderer.source(at: 0).prefixFrameCount, 512)
        XCTAssertEqual(renderer.source(at: 0).availableStreamFrames, 0)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual = [Float](repeating: .nan, count: expected.count)
        var offset = 0
        while offset < 512 {
            let count = min(127, 512 - offset)
            actual.withUnsafeMutableBufferPointer {
                renderer.render(interleaved: UnsafeMutableBufferPointer(rebasing: $0[(offset * 2)..<((offset + count) * 2)]), frameCount: count)
            }
            offset += count
        }
        assertSamples(actual, equal: expected)
        assertSamples(Array(actual.suffix(24)), equal: Array(expected.suffix(24)))
        XCTAssertEqual(renderer.snapshot.frame, 512); XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        var eof = [Float](repeating: .nan, count: 2)
        eof.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1) }
        XCTAssertEqual(eof, [0, 0]); XCTAssertTrue(renderer.snapshot.ended)
        XCTAssertEqual(renderer.snapshot.frame, 512); XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        let final = try await Self.mailboxStats(decoder)
        Self.assertMailboxBounds(final)
        XCTAssertEqual(reports.withLock { $0.count }, 1)
        XCTAssertTrue(failures.withLock { $0.isEmpty })
        let closed = try await Self.mailboxShutdown(decoder)
        XCTAssertTrue(closed.readerLeasesClosed); XCTAssertEqual(closed.leasedReaders, 0)
        print("PCM_MAILBOX_EXACT_PREFIX totalFrames=512 prefixFrames=512 leadingFrames=3 trailingFrames=5 sourceReports=\(reports.withLock { $0.count }) exactTailSamples=24 ended=\(renderer.snapshot.ended) underruns=\(renderer.snapshot.underrunFrames)")
        #endif
    }

    #if DEBUG
    private static func mailboxPattern(frames: Int, identity: Int) -> [Float] {
        (0..<frames).flatMap { frame -> [Float] in
            let value = Float(identity) / 32 + Float(frame % 97 + 1) / 512
            let sign: Float = identity < 4 ? 1 : -1
            return [sign * value, -sign * value * 0.5]
        }
    }

    private static func mailboxAcknowledge(_ renderer: ContinuousPCMRenderer, token: Int, frame: Int64) {
        renderer.setPlaying(false)
        let version = renderer.select(token: token, frame: frame)
        var ignored = [Float](repeating: .nan, count: 2)
        ignored.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1) }
        XCTAssertEqual(renderer.snapshot.selectionVersion, version)
        XCTAssertEqual(renderer.snapshot.token, token)
    }

    private static func mailboxWait(timeout: Double, _ message: String,
                                    _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard condition() else { XCTFail(message); throw ContinuousPCMDecoder.Failure.cannotDecode }
    }

    private static func mailboxPrepare(_ decoder: ContinuousPCMDecoder, url: URL, token: Int, slot: Int,
                                       timeout: Double = 3) async throws -> ContinuousPCMDecoder.Prepared {
        let value = Mutex<Result<ContinuousPCMDecoder.Prepared, ContinuousPCMDecoder.Failure>?>(nil)
        let job = Task {
            do {
                let prepared = try await decoder.prepare(url: url, token: token, slot: slot)
                value.withLock { $0 = .success(prepared) }
            } catch { value.withLock { $0 = .failure((error as? ContinuousPCMDecoder.Failure) ?? .cannotDecode) } }
        }
        defer { job.cancel() }
        try await mailboxWait(timeout: timeout, "The owned synthetic preparation must finish within its bounded setup window") {
            value.withLock { $0 } != nil
        }
        return try XCTUnwrap(value.withLock { $0 }).get()
    }

    private static func mailboxStateUntil(_ decoder: ContinuousPCMDecoder, timeout: Double,
        _ condition: (ContinuousPCMDecoder.DebugFailureState) -> Bool) async throws -> ContinuousPCMDecoder.DebugFailureState {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            let value = Mutex<ContinuousPCMDecoder.DebugFailureState?>(nil)
            decoder.debugFailureState { state in value.withLock { $0 = state } }
            try await mailboxWait(timeout: min(0.25, max(0.001, deadline - ProcessInfo.processInfo.systemUptime)),
                "The exact worker state request must actually return") { value.withLock { $0 } != nil }
            let state = try XCTUnwrap(value.withLock { $0 })
            if condition(state) { return state }
            try await Task.sleep(for: .milliseconds(2))
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("The exact held lane, lease, new epoch and later event did not qualify")
        throw ContinuousPCMDecoder.Failure.cannotDecode
    }

    private static func mailboxStats(_ decoder: ContinuousPCMDecoder, timeout: Double = 0.25) async throws -> ContinuousPCMDecoder.DebugWorkerStats {
        let value = Mutex<ContinuousPCMDecoder.DebugWorkerStats?>(nil)
        decoder.debugWorkerStats { stats in value.withLock { $0 = stats } }
        try await mailboxWait(timeout: timeout, "The real serial worker must answer a bounded stats query") {
            value.withLock { $0 } != nil
        }
        return try XCTUnwrap(value.withLock { $0 })
    }

    private static func mailboxStatsUntil(_ decoder: ContinuousPCMDecoder, timeout: Double,
        _ condition: (ContinuousPCMDecoder.DebugWorkerStats) -> Bool) async throws -> ContinuousPCMDecoder.DebugWorkerStats {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            let value = try await mailboxStats(decoder, timeout: min(0.25, max(0.001, deadline - ProcessInfo.processInfo.systemUptime)))
            if condition(value) { return value }
            try await Task.sleep(for: .milliseconds(2))
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("The worker did not reach the required bounded mailbox lifecycle state")
        throw ContinuousPCMDecoder.Failure.cannotDecode
    }

    private static func mailboxShutdown(_ decoder: ContinuousPCMDecoder) async throws -> ContinuousPCMDecoder.DebugWorkerStats {
        let value = Mutex<Bool?>(nil)
        decoder.shutdown()
        decoder.debugAfterShutdown { closed in value.withLock { $0 = closed } }
        try await mailboxWait(timeout: 2, "Actual reader-lane close acknowledgement must finish before owned-file cleanup") {
            value.withLock { $0 } != nil
        }
        XCTAssertEqual(value.withLock { $0 }, true)
        let stats = try await mailboxStats(decoder)
        XCTAssertTrue(stats.shutdownRequested); XCTAssertTrue(stats.readerLeasesClosed)
        XCTAssertEqual(stats.leasedReaders, 0); XCTAssertEqual(stats.pendingPreparations, 0)
        return stats
    }

    private static func assertMailboxBounds(_ stats: ContinuousPCMDecoder.DebugWorkerStats,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(stats.maximumLeases, 3, file: file, line: line)
        XCTAssertEqual(stats.maximumNativeFramesPerPacket, 4_096, file: file, line: line)
        XCTAssertEqual(stats.maximumChannels, 8, file: file, line: line)
        XCTAssertEqual(stats.maximumLaneBufferBytes, 131_072, file: file, line: line)
        XCTAssertEqual(stats.maximumOwnedPacketBytes, 131_072, file: file, line: line)
        XCTAssertEqual(stats.maximumOwnedPacketsPerLease, 2, file: file, line: line)
        XCTAssertEqual(stats.maximumOwnedPayloadBytesPerLease, 262_144, file: file, line: line)
        XCTAssertTrue((0...3).contains(stats.leasedReaders), file: file, line: line)
        XCTAssertTrue((0...3).contains(stats.peakLeasedReaders), file: file, line: line)
        XCTAssertGreaterThanOrEqual(stats.peakLeasedReaders, stats.leasedReaders, file: file, line: line)
        XCTAssertTrue((0...3).contains(stats.pendingPreparations), file: file, line: line)
        XCTAssertTrue((0...max(0, stats.leasedReaders)).contains(stats.retiredLeasesAwaitingClose), file: file, line: line)
        XCTAssertTrue((0...max(0, stats.leasedReaders)).contains(stats.startingLeases), file: file, line: line)
        XCTAssertTrue((0...max(0, stats.leasedReaders)).contains(stats.readJobsAwaitingAcceptanceOrClose), file: file, line: line)
        XCTAssertTrue((0...max(0, stats.leasedReaders)).contains(stats.mailboxPackets), file: file, line: line)
        XCTAssertEqual(stats.pendingOrMailboxPacketSlots,
                       stats.mailboxPackets + stats.readJobsAwaitingAcceptanceOrClose, file: file, line: line)
        XCTAssertTrue((0...3).contains(stats.pendingOrMailboxPacketSlots), file: file, line: line)
        XCTAssertEqual(stats.packetAllocationUpperBound, 2 * stats.leasedReaders, file: file, line: line)
        XCTAssertTrue((0...6).contains(stats.packetAllocationUpperBound), file: file, line: line)
        XCTAssertFalse(stats.counterOverflowed, file: file, line: line)
    }
    #endif

    func testHeldNeighbourNativeReadDoesNotPreventPreparedCurrentSourceRefill() async throws {
        #if DEBUG
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let aURL = directory.appendingPathComponent("independence-a.caf")
        let bURL = directory.appendingPathComponent("independence-b.caf")
        let expected = (0..<8_193).flatMap { frame -> [Float] in
            let value = Float(frame % 127 + 1) / 256
            return [value, -value]
        }
        do {
            try writePCM(expected, to: aURL)
            try writePCM(expected.map { -$0 }, to: bURL)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let renderer = ContinuousPCMRenderer(prefixFrames: 512, ringFrames: 1_024)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        let gate = ContinuousPCMDecoder.DebugNativeReadGate()
        decoder.debugSetNativeReadGate(gate)
        defer {
            gate.release()
            decoder.shutdown()
            // Delete only this owned directory, after queued reader retirement.
            // A native cleanup stall retains its files rather than deleting an
            // asset beneath an outstanding reader.
            decoder.debugAfterShutdown { stopped in
                if stopped { try? FileManager.default.removeItem(at: directory) }
            }
        }
        let a = try await decoder.prepare(url: aURL, token: 1, slot: 0)
        _ = try await decoder.prepare(url: bURL, token: 2, slot: 1)
        let source = renderer.source(at: 0), preparedRequest = source.streamRequest
        let memory = renderer.retainedPCMMemoryBytes
        XCTAssertEqual(a.totalFrames, 8_193)
        XCTAssertEqual(source.availableStreamFrames(for: preparedRequest.epoch), 1_024)

        renderer.select(token: 2, frame: 0); renderer.setPlaying(true)
        var acknowledged = [Float](repeating: .nan, count: 2)
        acknowledged.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1) }
        XCTAssertEqual(renderer.snapshot.token, 2)
        XCTAssertTrue(gate.arm(token: 2))
        // A same-token restart requests a fresh B reader. Its pinned first
        // sample is already available, so reaching the gate causes no underrun.
        let oldBRequest = renderer.source(at: 1).streamRequest
        renderer.select(token: 2, frame: 0)
        acknowledged.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1) }
        XCTAssertGreaterThan(renderer.source(at: 1).streamRequest.epoch, oldBRequest.epoch)
        let enteredDeadline = Date().addingTimeInterval(2)
        while !gate.didEnter, Date() < enteredDeadline { try await Task.sleep(for: .milliseconds(2)) }
        guard gate.didEnter, gate.isHolding, !gate.didTimeOut else {
            XCTFail("Setup must hold B immediately before its actual native read")
            throw ContinuousPCMDecoder.Failure.cannotDecode
        }
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)

        // A has never been selected: restart(frame: 0) must preserve its prepared
        // request/ring. These are positive controls, not readiness workarounds.
        renderer.select(token: 1, frame: 0)
        var head = [Float](repeating: .nan, count: 1_536 * 2)
        head.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1_536) }
        let afterHead = renderer.snapshot
        XCTAssertEqual(afterHead.token, 1)
        XCTAssertEqual(afterHead.frame, 1_536)
        XCTAssertEqual(afterHead.underrunFrames, 0)
        XCTAssertEqual(source.streamRequest.epoch, preparedRequest.epoch)
        assertSamples(head, equal: Array(expected.prefix(head.count)))
        guard afterHead.token == 1, afterHead.frame == 1_536, afterHead.underrunFrames == 0,
              source.streamRequest.epoch == preparedRequest.epoch else {
            throw ContinuousPCMDecoder.Failure.cannotDecode
        }

        let refillDeadline = Date().addingTimeInterval(1)
        while source.availableStreamFrames(for: preparedRequest.epoch) < 128,
              gate.isHolding, Date() < refillDeadline { try await Task.sleep(for: .milliseconds(2)) }
        let ready = source.availableStreamFrames(for: preparedRequest.epoch)
        let heldAtRefill = gate.isHolding && !gate.didTimeOut
        var following: [Float] = []
        if ready >= 128, heldAtRefill {
            following = [Float](repeating: .nan, count: 128 * 2)
            following.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 128) }
        }
        let final = renderer.snapshot, heldAfterRender = gate.isHolding && !gate.didTimeOut
        gate.release()
        decoder.shutdown()
        let closed = expectation(description: "Released B and both readers finish queued shutdown")
        decoder.debugAfterShutdown { stopped in if stopped { closed.fulfill() } }
        await fulfillment(of: [closed], timeout: 2)

        XCTAssertTrue(heldAtRefill && heldAfterRender, "The controlled B call must remain held through the observation")
        XCTAssertGreaterThanOrEqual(ready, 128,
            "A must refill after its prepared head while B's native read remains outstanding")
        if ready >= 128, heldAtRefill {
            assertSamples(following, equal: Array(expected[(1_536 * 2)..<(1_664 * 2)]))
            XCTAssertEqual(final.frame, 1_664)
        }
        XCTAssertEqual(final.token, 1)
        XCTAssertEqual(final.underrunFrames, 0)
        XCTAssertEqual(renderer.retainedPCMMemoryBytes, memory)
        XCTAssertFalse(gate.didTimeOut)
        print("PCM_NATIVE_READ_INDEPENDENCE gateToken=2 controlledBoundary=before-copy currentToken=1 readyFrames=\(ready) heldAtRefill=\(heldAtRefill) heldAfterRender=\(heldAfterRender) frame=\(final.frame) underruns=\(final.underrunFrames) retainedBytes=\(memory) gateMaximumSeconds=5 refillMaximumSeconds=1 interpretation=producer-independence-not-SDK-wait-cause")
        #endif
    }

    func testDecoderPreservesLeadingAndTrailingSourceSilenceAndTheLastFrame() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.caf")
        let expected: [Float] = [0, 0, 0, 0, 0.125, -0.125, 0.25, -0.25, 0, 0, 0.5, -0.5, 0, 0]
        try writePCM(expected, to: url)
        let renderer = ContinuousPCMRenderer(prefixFrames: 16, ringFrames: 32)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let sourceSilence = expectation(description: "Complete source silence measurement")
        sourceSilence.assertForOverFulfill = true
        let observed = Mutex<(Int, ContinuousPCMDecoder.SourceSilence)?>(nil)
        let failures = Mutex<[ContinuousPCMDecoder.Failure]>([])
        decoder.setFailureHandler { _, failure in failures.withLock { $0.append(failure) } }
        decoder.setSourceSilenceHandler { token, analysis in
            observed.withLock { $0 = (token, analysis) }
            sourceSilence.fulfill()
        }
        let prepared = try await decoder.prepare(url: url, token: 1, slot: 0)
        await fulfillment(of: [sourceSilence], timeout: 2)
        let analysis = try XCTUnwrap(observed.withLock { $0 })
        XCTAssertEqual(analysis.0, 1)
        XCTAssertEqual(analysis.1.totalFrames, 7)
        XCTAssertEqual(analysis.1.leadingFrames, 2)
        XCTAssertEqual(analysis.1.trailingFrames, 1)
        XCTAssertEqual(analysis.1.peak, 0.5)
        XCTAssertEqual(prepared.totalFrames, 7)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual = [Float](repeating: .nan, count: 14)
        actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 7) }
        XCTAssertEqual(actual, expected, "Genuine zero samples and the complete tail belong to the source")
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        renderer.setSuccessor(token: 1, for: 1)
        renderer.select(token: 1, frame: 0)
        actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 7) }
        XCTAssertEqual(actual, expected)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(failures.withLock { $0.isEmpty }, "A fully pinned loop must not reopen a reader beyond EOF")
    }

    func testAACPreparationLoopsTheDecodedPresentationWithoutAddingCodecPadding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("compressed.m4a")
        let frameCount = 12_345
        let samples = (0..<frameCount).flatMap { frame -> [Float] in
            let value: Float = frame < 240 || frame >= frameCount - 480 ? 0 : Float(sin(Double(frame) * 0.071)) * 0.2
            return [value, -value]
        }
        try writePCM(samples, to: url, compressed: true)
        let asset = AVURLAsset(url: url)
        let expected = try await independentlyDecode(asset, diagnosticName: "generated-aac")
        XCTAssertGreaterThan(expected.map { abs($0) }.max() ?? 0, 0.01, "AAC reference must contain the encoded tone")
        let renderer = ContinuousPCMRenderer(prefixFrames: 24_000, ringFrames: 24_000)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let prepared = try await decoder.prepare(url: url, token: 1, slot: 0)
        XCTAssertEqual(prepared.totalFrames, Int64(frameCount), "Container timing, rather than AAC packet size, defines the presentation")
        XCTAssertEqual(expected.count, frameCount * 2)
        renderer.setSuccessor(token: 1, for: 1)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual = [Float](repeating: .nan, count: expected.count * 3)
        var offset = 0
        while offset < frameCount * 3 {
            let count = min(257, frameCount * 3 - offset)
            actual.withUnsafeMutableBufferPointer {
                renderer.render(interleaved: UnsafeMutableBufferPointer(rebasing: $0[(offset * 2)..<((offset + count) * 2)]), frameCount: count)
            }
            offset += count
        }
        XCTAssertEqual(actual, expected + expected + expected, "Prepared AAC loops must join exact decoded samples, including source silence")
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testRemoteURLIsRejectedBeforeAnyReaderOrNetworkOperation() async throws {
        let renderer = ContinuousPCMRenderer(prefixFrames: 8, ringFrames: 8)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        do {
            _ = try await decoder.prepare(url: URL(string: "https://example.invalid/private.mp4")!, token: 1, slot: 0)
            XCTFail("Only an already-local Saved or verified playback-cache file may enter the PCM decoder")
        } catch let error as ContinuousPCMDecoder.Failure {
            XCTAssertEqual(error, .localFileRequired)
        }
    }

    func testPartialDecodeAndSeekToTheTailDoNotInventSourceSilenceMeasurements() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("partial.caf")
        try writePCM([Float](repeating: 0.25, count: 40_000), to: url)
        let renderer = ContinuousPCMRenderer(prefixFrames: 16, ringFrames: 32)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let reports = Mutex<Int>(0)
        decoder.setSourceSilenceHandler { _, _ in reports.withLock { $0 += 1 } }
        _ = try await decoder.prepare(url: url, token: 1, slot: 0)
        XCTAssertEqual(reports.withLock { $0 }, 0, "A full decode-ahead ring is still only a partial source")
        renderer.select(token: 1, frame: 19_999); renderer.setPlaying(true)
        var lastFrame = [Float](repeating: .nan, count: 2)
        // Publish the seek request to the worker; the unprepared seek may underrun.
        lastFrame.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1) }
        let epoch = renderer.source(at: 0).streamRequest.epoch
        let deadline = Date().addingTimeInterval(2)
        while renderer.source(at: 0).availableStreamFrames(for: epoch) != 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(renderer.source(at: 0).availableStreamFrames(for: epoch), 1)
        lastFrame.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1) }
        XCTAssertEqual(lastFrame, [0.25, 0.25])
        XCTAssertEqual(reports.withLock { $0 }, 0, "A tail-only reader cannot know source leading/trailing quiet frames")
    }

    func testPreparedAACAndALACVideosJoinInTheProductionGraphAndReverseWithoutExtraFrames() async throws {
        // The original MP3-in-MP4 asset has no iOS-readable audio track. The
        // archived iPhone compatibility derivative contains lossless ALAC.
        let urls = try ["test-video", "test-slideshow-mp3.iphone"].map {
            try XCTUnwrap(Bundle(for: Self.self).url(forResource: $0, withExtension: "mp4"))
        }
        let first = try await independentlyDecode(AVURLAsset(url: urls[0]), diagnosticName: "aac-video")
        let second = try await independentlyDecode(AVURLAsset(url: urls[1]), diagnosticName: "alac-compatibility-video")
        XCTAssertGreaterThan(first.map { abs($0) }.max() ?? 0, 0.01, "AAC graph reference must contain audible tone")
        XCTAssertGreaterThan(second.map { abs($0) }.max() ?? 0, 0.01, "ALAC graph reference must contain audible tone")
        let maximum = max(first.count, second.count) / 2
        guard maximum > 0, maximum <= 960_000 else { throw XCTSkip("Synthetic fixture outside the test's bounded PCM allocation") }
        // Retain these short synthetic sources completely so faster-than-realtime
        // offline rendering tests boundaries, rather than starving a real-time worker.
        let renderer = ContinuousPCMRenderer(prefixFrames: maximum + 1, ringFrames: 512)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let a = try await decoder.prepare(url: urls[0], token: 1, slot: 0)
        let b = try await decoder.prepare(url: urls[1], token: 2, slot: 1)
        XCTAssertEqual(a.totalFrames, Int64(first.count / 2))
        XCTAssertEqual(b.totalFrames, Int64(second.count / 2))
        renderer.setSuccessor(token: 2, for: 1)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        let graph = ContinuousAudioGraph(renderer: renderer)
        try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 257)
        try graph.engine.start()
        defer { graph.engine.stop() }
        let actual = try render(graph, frames: (first.count + second.count) / 2)
        assertSamples(actual, equal: first + second)
        // A prepared Previous changes only the source cursor inside the same graph.
        renderer.select(token: 1, frame: 0)
        assertSamples(try render(graph, frames: min(401, first.count / 2)), equal: Array(first.prefix(802)))
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testStandaloneMP3KeepsCompleteDecodedSamplesThroughGraphLoopsNextAndPrevious() async throws {
        let mp3 = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "mp3"))
        let expectedMP3 = try await independentlyDecode(AVURLAsset(url: mp3), diagnosticName: "standalone-mp3")
        XCTAssertGreaterThan(expectedMP3.count, 48_000, "The real MP3 decoder must return the complete synthetic tone")
        XCTAssertLessThan(expectedMP3.count, 192_000)
        XCTAssertGreaterThan(expectedMP3.map { abs($0) }.max() ?? 0, 0.01, "MP3 sample comparisons must exercise audible decoded tone")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let following = directory.appendingPathComponent("following.caf")
        let expectedFollowing: [Float] = [0.25, -0.25, 0.125, -0.125, 0, 0, 0.5, -0.5, 0, 0]
        try writePCM(expectedFollowing, to: following)
        let renderer = ContinuousPCMRenderer(prefixFrames: expectedMP3.count / 2 + 2_048, ringFrames: 512)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let prepared = try await decoder.prepare(url: mp3, token: 1, slot: 0)
        _ = try await decoder.prepare(url: following, token: 2, slot: 1)
        XCTAssertEqual(prepared.totalFrames, Int64(expectedMP3.count / 2), "MP3 loops must use its own decoded presentation, not the source MP4 edit duration")
        renderer.setSuccessor(token: 1, for: 1)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        let graph = ContinuousAudioGraph(renderer: renderer)
        try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 257)
        graph.engine.prepare()
        try graph.engine.start()
        defer { graph.engine.stop() }
        let looped = try render(graph, frames: expectedMP3.count / 2 * 3)
        XCTAssertGreaterThan(looped.map { abs($0) }.max() ?? 0, 0.01, "The production graph must emit audible MP3 samples")
        assertSamples(looped, equal: expectedMP3 + expectedMP3 + expectedMP3)
        renderer.setSuccessor(token: 2, for: 1)
        renderer.select(token: 1, frame: 0)
        assertSamples(try render(graph, frames: (expectedMP3.count + expectedFollowing.count) / 2), equal: expectedMP3 + expectedFollowing)
        // Repeated prepared Previous/Next commands keep the same running graph.
        for _ in 0..<8 {
            renderer.select(token: 1, frame: 0)
            assertSamples(try render(graph, frames: 193), equal: Array(expectedMP3.prefix(386)))
            renderer.select(token: 2, frame: 0)
            assertSamples(try render(graph, frames: expectedFollowing.count / 2), equal: expectedFollowing)
        }
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testRepeatedMP3ReadersAndPreparationsPreserveTheSameFullDeclaredPresentation() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "mp3"))
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        let end = CMTimeCompare(range.end, duration) > 0 ? range.end : duration
        let declaredFrames = CMTimeConvertScale(end, timescale: 48_000, method: .roundHalfAwayFromZero).value
        let expected = try await independentlyDecode(AVURLAsset(url: url), diagnosticName: "repeated-mp3-declared-presentation")
        XCTAssertEqual(expected.count, Int(declaredFrames) * 2, "The standalone fixture's precise declared timeline is authoritative")
        XCTAssertGreaterThan(expected.map { abs($0) }.max() ?? 0, 0.01)
        for _ in 0..<3 {
            let repeated = try await independentlyDecode(AVURLAsset(url: url))
            assertSamples(repeated, equal: expected)
            let renderer = ContinuousPCMRenderer(prefixFrames: 65_000, ringFrames: 512)
            let decoder = ContinuousPCMDecoder(renderer: renderer)
            defer { decoder.shutdown() }
            let prepared = try await decoder.prepare(url: url, token: 1, slot: 0)
            XCTAssertEqual(prepared.totalFrames, declaredFrames)
            XCTAssertEqual(renderer.source(at: 0).totalFrames, declaredFrames)
            renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
            var actual = [Float](repeating: .nan, count: expected.count)
            actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: expected.count / 2) }
            assertSamples(actual, equal: expected)
            XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        }
    }

    func testSampleRateConversionPreservesTheCompleteDeclaredTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("44100.caf")
        let samples = (0..<9_801).flatMap { frame -> [Float] in
            let value = Float(sin(Double(frame) * 0.071)) * 0.2
            return [value, -value]
        }
        try writePCM(samples, to: url, sampleRate: 44_100)
        let asset = AVURLAsset(url: url)
        let expected = try await independentlyDecode(asset, diagnosticName: "sample-rate-44100-to-48000")
        let withoutSupport = try await independentlyDecode(asset, quantizedEndSupport: false)
        XCTAssertEqual(withoutSupport.count, 10_667 * 2, "Characterize the converter's floor-sized termination without native support")
        assertSamples(Array(expected.prefix(withoutSupport.count)), equal: withoutSupport)
        let finalLeft = try XCTUnwrap(expected.suffix(2).first)
        XCTAssertGreaterThan(abs(finalLeft), 0.01,
            "The final fractional frame must be calculated from the source, not padded with an output zero")
        let renderer = ContinuousPCMRenderer(prefixFrames: 20_000, ringFrames: 512)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let prepared = try await decoder.prepare(url: url, token: 1, slot: 0)
        XCTAssertEqual(prepared.totalFrames, 10_668, "9,801 / 44,100 seconds equals 10,668 samples at 48 kHz")
        XCTAssertEqual(expected.count, 10_668 * 2)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual = [Float](repeating: .nan, count: expected.count)
        actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: expected.count / 2) }
        assertSamples(actual, equal: expected)
    }

    func testStreamingRefillAndLoopReopenPreserveEveryFrameAcrossThePinnedPrefix() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stream.caf")
        let expected = (0..<4_097).flatMap { frame -> [Float] in
            let value = Float(frame % 97) / 128
            return [value, -value]
        }
        try writePCM(expected, to: url)
        let renderer = ContinuousPCMRenderer(prefixFrames: 512, ringFrames: 1_024)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        _ = try await decoder.prepare(url: url, token: 1, slot: 0)
        renderer.setSuccessor(token: 1, for: 1)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual: [Float] = []
        while actual.count < expected.count * 2 {
            let count = min(127, (expected.count * 2 - actual.count) / 2)
            try await Self.waitForPreparedFrames(renderer, count: count, totalFrames: 4_097)
            var block = [Float](repeating: .nan, count: count * 2)
            block.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: count) }
            actual.append(contentsOf: block)
        }
        assertSamples(actual, equal: expected + expected)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testResampledStreamingLoopAndSeekRebuildTheOriginalConverterHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stream-44100.caf")
        let native = (0..<9_801).flatMap { frame -> [Float] in
            let value = frame < 42 || frame >= 9_784 ? 0 : Float(sin(Double(frame) * 0.071)) * 0.2
            return [value, -value]
        }
        try writePCM(native, to: url, sampleRate: 44_100)
        let expected = try await independentlyDecode(AVURLAsset(url: url), diagnosticName: "streamed-44100-to-48000")
        XCTAssertEqual(expected.count, 10_668 * 2)
        let renderer = ContinuousPCMRenderer(prefixFrames: 512, ringFrames: 1_024)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        _ = try await decoder.prepare(url: url, token: 1, slot: 0)
        renderer.setSuccessor(token: 1, for: 1)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual: [Float] = []
        while actual.count < expected.count * 3 {
            let count = min(127, (expected.count * 3 - actual.count) / 2)
            try await Self.waitForPreparedFrames(renderer, count: count, totalFrames: 10_668)
            var block = [Float](repeating: .nan, count: count * 2)
            block.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: count) }
            actual.append(contentsOf: block)
        }
        assertSamples(actual, equal: expected + expected + expected)
        // A paused render acknowledges the seek without consuming/starving it.
        renderer.setPlaying(false); renderer.select(token: 1, frame: 7_891)
        var block = [Float](repeating: .nan, count: 386)
        block.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 193) }
        try await Self.waitForPreparedFrames(renderer, count: 193, totalFrames: 10_668)
        renderer.setPlaying(true)
        block.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 193) }
        assertSamples(block, equal: Array(expected[(7_891 * 2)..<((7_891 + 193) * 2)]))
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    @MainActor
    func testRetainedPreviousPrewarmsItsStreamingHeadBeforeReturningAcrossThePrefix() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let renderer = ContinuousPCMRenderer()
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let a = try await decoder.prepare(url: XCTUnwrap(fixture.savedURLs[fixture.aID]), token: 1, slot: 0)
        _ = try await decoder.prepare(url: XCTUnwrap(fixture.savedURLs[fixture.bID]), token: 2, slot: 1)
        let source = renderer.source(at: 0)
        let retainedBytes = renderer.retainedPCMMemoryBytes
        XCTAssertEqual(source.prefixFrameCount, 96_000)
        XCTAssertEqual(source.ringCapacityFrames, 192_000)
        XCTAssertEqual(retainedBytes, 3 * (96_000 + 192_000) * 2 * MemoryLayout<Float>.stride)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)

        // Consume A well beyond its pinned prefix so its current ring no longer
        // represents the stream head needed by Previous. Retain only three
        // seconds of reference PCM, with readiness controlling the first pass.
        let referenceFrames = 3 * 48_000, playedFrames = 204_000
        var reference: [Float] = []
        reference.reserveCapacity(referenceFrames * 2)
        var played = 0
        while played < playedFrames {
            let count = min(257, playedFrames - played)
            try await Self.waitForPreparedFrames(renderer, count: count, totalFrames: a.totalFrames)
            var block = [Float](repeating: .nan, count: count * 2)
            block.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: count) }
            let retainedFrames = min(count, max(0, referenceFrames - played))
            reference.append(contentsOf: block.prefix(retainedFrames * 2))
            played += count
        }
        XCTAssertEqual(renderer.snapshot.frame, Int64(playedFrames))
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        XCTAssertEqual(reference.count, referenceFrames * 2)
        XCTAssertGreaterThan(reference.map { abs($0) }.max() ?? 0, 0.01)
        XCTAssertGreaterThan(reference.dropFirst(source.prefixFrameCount * 2).map { abs($0) }.max() ?? 0, 0.01,
            "The reference must contain decoded tone beyond the pinned prefix")
        let oldEpoch = source.streamRequest.epoch

        renderer.select(token: 2, frame: 0)
        var selectedB = [Float](repeating: .nan, count: 512 * 2)
        selectedB.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 512) }
        XCTAssertEqual(renderer.snapshot.token, 2)
        let warmRequest = source.streamRequest
        XCTAssertGreaterThan(warmRequest.epoch, oldEpoch, "Leaving A must request its next frame-zero visit immediately")
        XCTAssertEqual(warmRequest.startFrame, Int64(source.prefixFrameCount))
        guard warmRequest.epoch > oldEpoch else { throw ContinuousPCMDecoder.Failure.cannotDecode }
        let deadline = Date().addingTimeInterval(5)
        let requiredWarmFrames = 3 * 48_000
        while source.availableStreamFrames(for: warmRequest.epoch) < requiredWarmFrames {
            guard Date() < deadline else {
                XCTFail("The actual serial decoder did not prewarm retained A while B was current")
                throw ContinuousPCMDecoder.Failure.cannotDecode
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(renderer.snapshot.token, 2)
        let readyFrames = source.availableStreamFrames(for: warmRequest.epoch)
        let beforeReturnUnderruns = renderer.snapshot.underrunFrames
        XCTAssertEqual(beforeReturnUnderruns, 0)

        // No producer-readiness wait is allowed after Previous. A's prepared
        // stream head must survive selection and supply every sample after its
        // two-second prefix, even when manual rendering runs faster than audio.
        renderer.select(token: 1, frame: 0)
        var returned = [Float](repeating: .nan, count: referenceFrames * 2)
        var rendered = 0
        while rendered < referenceFrames {
            let count = min(257, referenceFrames - rendered)
            returned.withUnsafeMutableBufferPointer {
                renderer.render(interleaved: UnsafeMutableBufferPointer(rebasing: $0[(rendered * 2)..<((rendered + count) * 2)]), frameCount: count)
            }
            rendered += count
        }
        let returnedEpoch = source.streamRequest.epoch
        let underrunDelta = renderer.snapshot.underrunFrames - beforeReturnUnderruns
        XCTAssertEqual(renderer.snapshot.token, 1)
        XCTAssertEqual(renderer.snapshot.frame, Int64(referenceFrames))
        XCTAssertEqual(returnedEpoch, warmRequest.epoch, "Previous must adopt the already-committed stream request")
        XCTAssertEqual(underrunDelta, 0, "Returning to a prepared source must not exhaust its prefix while rewinding")
        XCTAssertGreaterThan(returned.map { abs($0) }.max() ?? 0, 0.01)
        assertSamples(returned, equal: reference)
        XCTAssertEqual(renderer.retainedPCMMemoryBytes, retainedBytes)
        print("PCM_PREWARM_ABA oldEpoch=\(oldEpoch) warmEpoch=\(warmRequest.epoch) returnedEpoch=\(returnedEpoch) readyFrames=\(readyFrames) renderedFrames=\(rendered) underrunDelta=\(underrunDelta) retainedBytes=\(retainedBytes)")
    }

    /// Capability comparison only. No production decoder selection changes.
    func testAVAudioFileMatchesCompleteNative48kMoviePresentation() async throws {
        #if DEBUG
        guard !PCMWorkerBoundaryOwnership.blocksFixtures else {
            XCTFail("An unresolved reader close blocks new native decoder comparisons")
            throw ContinuousPCMDecoder.Failure.cannotDecode
        }
        #endif
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-a", withExtension: "mp4"))
        let expectedFrames: Int64 = 30 * 48_000
        typealias DecodedFile = (samples: [Float], fileFrames: Int64, openMs: Double,
                                 firstReadMs: Double, prefixMs: Double, totalMs: Double, reads: Int)
        // Close the alternative reader before opening the existing reference.
        // Only the copied sample array and scalar metrics leave this pool.
        let decoded: DecodedFile = try autoreleasepool { () throws -> DecodedFile in
            let start = DispatchTime.now().uptimeNanoseconds
            func milliseconds() -> Double {
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
            let openMs = milliseconds(), format = file.processingFormat
            guard format.sampleRate == 48_000, format.channelCount == 2,
                  format.commonFormat == .pcmFormatFloat32, format.isInterleaved else {
                XCTFail("The capability comparison requires native interleaved stereo Float32")
                throw ContinuousPCMDecoder.Failure.unsupportedPCM
            }
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
            var samples: [Float] = []
            samples.reserveCapacity(Int(expectedFrames) * 2)
            var firstReadMs = -1.0, prefixMs = -1.0, reads = 0
            while true {
                buffer.frameLength = 0
                try file.read(into: buffer, frameCount: 4_096)
                reads += 1
                if firstReadMs < 0 { firstReadMs = milliseconds() }
                let frames = Int(buffer.frameLength)
                if frames == 0 { break }
                guard samples.count / 2 + frames <= Int(expectedFrames) + 4_096 else {
                    XCTFail("Unexpected extra presentation exceeds the bounded capability comparison")
                    throw ContinuousPCMDecoder.Failure.invalidTimeline
                }
                let channels = try XCTUnwrap(buffer.floatChannelData)
                samples.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames * 2))
                if prefixMs < 0, samples.count / 2 >= 96_000 { prefixMs = milliseconds() }
            }
            return (samples, file.length, openMs, firstReadMs, prefixMs, milliseconds(), reads)
        }
        let reference = try await independentlyDecode(AVURLAsset(url: url),
                                                     diagnosticName: "audio-file-full-native48k-reference")
        var firstMismatch: Int?, nonfinite = 0
        var maximumDifference: Float = 0
        for index in 0..<min(decoded.samples.count, reference.count) {
            let actual = decoded.samples[index], expected = reference[index]
            let finite = actual.isFinite && expected.isFinite
            let difference: Float = finite ? abs(actual - expected) : .infinity
            if !finite { nonfinite += 1 }
            if difference > 0.000_001, firstMismatch == nil { firstMismatch = index }
            maximumDifference = max(maximumDifference, difference)
        }
        print("AudioFileCapability schema=1 fixture=complete-native48k-30s-mp4 fileFrames=\(decoded.fileFrames) decodedFrames=\(decoded.samples.count / 2) referenceFrames=\(reference.count / 2) openMs=\(decoded.openMs) firstReadMs=\(decoded.firstReadMs) prefixMs=\(decoded.prefixMs) totalMs=\(decoded.totalMs) reads=\(decoded.reads) firstMismatch=\(firstMismatch.map { String($0) } ?? "none") maximumDifference=\(maximumDifference) nonfinite=\(nonfinite) tolerance=0.000001 productionChanged=false physicalOutput=unverified")
        XCTAssertEqual(reference.count, Int(expectedFrames) * 2)
        XCTAssertEqual(decoded.fileFrames, expectedFrames)
        XCTAssertEqual(decoded.samples.count, reference.count, "Do not trim priming, padding or missing frames to obtain agreement")
        XCTAssertEqual(nonfinite, 0)
        XCTAssertNil(firstMismatch, "The alternative must preserve every original stereo sample")
        XCTAssertGreaterThanOrEqual(decoded.prefixMs, 0)
        XCTAssertLessThanOrEqual(decoded.prefixMs, 3_000, "Keep the existing initial preparation budget")
        XCTAssertLessThanOrEqual(decoded.firstReadMs, 3_000)
    }


    func testDistantNative48kSeeksBoundDecodeWorkAndMatchFullSourceSamples() async throws {
        #if DEBUG
        guard !PCMWorkerBoundaryOwnership.blocksFixtures else {
            XCTFail("An unresolved reader close blocks new decoder owners")
            throw ContinuousPCMDecoder.Failure.cannotDecode
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-a", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format))
        XCTAssertEqual(asbd.pointee.mSampleRate, 48_000)
        // Independent full-source decode; do not compare the new range path to itself.
        let expected = try await independentlyDecode(asset, diagnosticName: "48k-seek-full-source")
        XCTAssertEqual(expected.count, 30 * 48_000 * 2)
        let renderer = ContinuousPCMRenderer(prefixFrames: 96_000, ringFrames: 8_192)
        let activity = ContinuousPCMDecoder.DebugNativeLaneActivityRecorder()
        let decoder = ContinuousPCMDecoder(renderer: renderer, debugNativeLaneActivityRecorder: activity)
        defer { decoder.shutdown() }
        var bodyError: Error?
        do {
            let prepared = try await Self.mailboxPrepare(decoder, url: url, token: 1, slot: 0)
            XCTAssertEqual(prepared.totalFrames, 30 * 48_000)
            let source = renderer.source(at: 0), initial = source.streamRequest
            _ = try await Self.mailboxStateUntil(decoder, timeout: 3) { state in
                source.availableStreamFrames(for: initial.epoch) == 8_192
                    && state.leases.allSatisfy { !$0.readPending && !$0.starting }
            }
            let memory = renderer.retainedPCMMemoryBytes
            for target: Int64 in [28 * 48_000, 7 * 48_000] {
                let beforeCopies = (0..<3).compactMap { activity.snapshot(at: $0)?.copySequence }.reduce(0, +)
                Self.mailboxAcknowledge(renderer, token: 1, frame: target)
                let request = source.streamRequest
                XCTAssertEqual(request.startFrame, target)
                _ = try await Self.mailboxStateUntil(decoder, timeout: 3) { state in
                    source.availableStreamFrames(for: request.epoch) == 8_192
                        && state.leases.allSatisfy { !$0.readPending && !$0.starting }
                }
                let afterCopies = (0..<3).compactMap { activity.snapshot(at: $0)?.copySequence }.reduce(0, +)
                XCTAssertGreaterThan(afterCopies, beforeCopies)
                XCTAssertLessThanOrEqual(afterCopies - beforeCopies, 192,
                    "A distant seek must not demux the entire earlier presentation")
                let beforeUnderruns = renderer.snapshot.underrunFrames
                renderer.setPlaying(true)
                var samples = [Float](repeating: .nan, count: 512 * 2)
                samples.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 512) }
                renderer.setPlaying(false)
                assertSamples(samples, equal: Array(expected[Int(target) * 2..<Int(target + 512) * 2]))
                XCTAssertEqual(renderer.snapshot.frame, target + 512)
                XCTAssertEqual(renderer.snapshot.underrunFrames, beforeUnderruns)
                XCTAssertEqual(source.totalFrames, prepared.totalFrames)
                XCTAssertEqual(renderer.retainedPCMMemoryBytes, memory)
                print("PCM_NATIVE48K_SEEK targetFrame=\(target) nativeCopies=\(afterCopies - beforeCopies) exactSamples=\(samples == Array(expected[Int(target) * 2..<Int(target + 512) * 2])) completeFrames=\(source.totalFrames) memoryBytes=\(memory)")
            }
        } catch { bodyError = error }
        _ = try await Self.mailboxShutdown(decoder)
        if let bodyError { throw bodyError }
        #else
        XCTFail("Seek work qualification requires the existing native copy recorder")
        #endif
    }

    func testLeavingAFarSeekYieldsToCurrentRefillAndPrewarmsTheRetainedHead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let far = directory.appendingPathComponent("far.caf"), current = directory.appendingPathComponent("current.caf")
        // The two-minute low-rate file is written with one fixed-size buffer.
        // No complete long-source PCM array is retained by this test or decoder.
        try writeConstantPCM(frames: 120 * 8_000, sampleRate: 8_000, value: 0.125, to: far)
        try writePCM([Float](repeating: 0.375, count: 4_097 * 2), to: current)
        let renderer = ContinuousPCMRenderer(prefixFrames: 64, ringFrames: 128)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        _ = try await decoder.prepare(url: far, token: 1, slot: 0)
        _ = try await decoder.prepare(url: current, token: 2, slot: 1)
        renderer.select(token: 1, frame: 119 * 48_000)
        var acknowledged = [Float](repeating: .nan, count: 2)
        acknowledged.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1) }
        let farEpoch = renderer.source(at: 0).streamRequest.epoch
        let firstYield = Date().addingTimeInterval(3)
        while decoder.cooperativeYieldCount == 0, Date() < firstYield {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertGreaterThan(decoder.cooperativeYieldCount, 0, "A far seek must return the serial worker between bounded discard steps")
        // Leaving A supersedes its distant seek with a frame-zero prewarm.
        // B consumes all its prepared PCM and must refill on the same worker.
        renderer.select(token: 2, frame: 0); renderer.setPlaying(true)
        var initial = [Float](repeating: .nan, count: 192 * 2)
        initial.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 192) }
        XCTAssertTrue(initial.allSatisfy { $0 == 0.375 })
        let headRequest = renderer.source(at: 0).streamRequest
        XCTAssertGreaterThan(headRequest.epoch, farEpoch)
        XCTAssertEqual(headRequest.startFrame, 64)
        let currentSource = renderer.source(at: 1), currentEpoch = currentSource.streamRequest.epoch
        let refill = Date().addingTimeInterval(3)
        while currentSource.availableStreamFrames(for: currentEpoch) < 128, Date() < refill {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(currentSource.availableStreamFrames(for: currentEpoch), 128)
        XCTAssertEqual(renderer.source(at: 0).availableStreamFrames(for: farEpoch), 0,
            "The obsolete distant seek must not publish readiness after A is rearmed")
        var next = [Float](repeating: .nan, count: 128 * 2)
        next.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 128) }
        XCTAssertTrue(next.allSatisfy { $0 == 0.375 })
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0, "Retiring distant work must not starve current B")
        let retainedReady = Date().addingTimeInterval(3)
        while renderer.source(at: 0).availableStreamFrames(for: headRequest.epoch) < 128, Date() < retainedReady {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(renderer.source(at: 0).availableStreamFrames(for: headRequest.epoch), 128,
            "The retained source must prepare its next visit instead of finishing an obsolete far seek")
        // A fresh selection requests a fresh epoch; verify it also eventually
        // reaches the exact steady-state PCM after rebuilding the same history.
        renderer.setPlaying(false); renderer.select(token: 1, frame: 119 * 48_000)
        acknowledged.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1) }
        try await Self.waitForPreparedFrames(renderer, count: 16, totalFrames: 120 * 48_000, timeout: 12)
        renderer.setPlaying(true)
        var resumed = [Float](repeating: .nan, count: 16 * 2)
        resumed.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 16) }
        for sample in resumed { XCTAssertEqual(sample, 0.125, accuracy: 0.00001) }
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testAnAudioTrackOffsetRemainsPresentationSilenceRatherThanBeingTrimmedAsPriming() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tone.caf")
        let edited = directory.appendingPathComponent("offset.mov")
        let samples = (0..<12_000).flatMap { frame -> [Float] in
            let value = Float(sin(Double(frame) * 0.071)) * 0.2
            return [value, -value]
        }
        try writePCM(samples, to: source)
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let composition = AVMutableComposition()
        let composed = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try composed.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 12_000, timescale: 48_000)),
            of: track, at: CMTime(value: 4_800, timescale: 48_000))
        // Preserve the PCM and its edit offset without AAC export quantization.
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
            "The offset fixture requires lossless PCM passthrough export")
        guard export.supportedFileTypes.contains(.mov) else {
            XCTFail("Lossless PCM passthrough must support a MOV offset fixture")
            throw ContinuousPCMDecoder.Failure.unsupportedPCM
        }
        try await export.export(to: edited, as: .mov)
        let editedAsset = AVURLAsset(url: edited, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let editedTracks = try await editedAsset.loadTracks(withMediaType: .audio)
        let editedTrack = try XCTUnwrap(editedTracks.first, "The MOV offset fixture must retain its PCM track")
        let range = try await editedTrack.load(.timeRange)
        let duration = try await editedAsset.load(.duration)
        let segments = try await editedTrack.load(.segments)
        let content = try XCTUnwrap(segments.first { !$0.isEmpty },
            "The MOV fixture must retain a nonempty PCM edit segment")
        let contentStart = CMTime(value: 4_800, timescale: 48_000)
        let presentationEnd = CMTime(value: 16_800, timescale: 48_000)
        // The track range includes its leading empty edit; the content segment
        // identifies the exact offset without treating presentation silence as priming.
        XCTAssertEqual(CMTimeCompare(content.timeMapping.target.start, contentStart), 0,
            "The MOV PCM content must start at exactly 0.1 seconds")
        XCTAssertEqual(CMTimeCompare(content.timeMapping.target.end, presentationEnd), 0,
            "The MOV PCM content must retain its complete 12,000-frame span")
        if let first = segments.first, first.isEmpty {
            XCTAssertEqual(CMTimeCompare(first.timeMapping.target.start, .zero), 0,
                "The leading empty edit must begin at presentation zero")
            XCTAssertEqual(CMTimeCompare(first.timeMapping.target.end, contentStart), 0,
                "The leading empty edit must preserve all 4,800 quiet frames")
        }
        XCTAssertEqual(CMTimeCompare(range.end, presentationEnd), 0,
            "The MOV track must end at exactly 0.35 seconds")
        XCTAssertEqual(CMTimeCompare(duration, presentationEnd), 0,
            "The MOV asset must present exactly 16,800 frames at 48 kHz")
        let formats = try await editedTrack.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format))
        XCTAssertEqual(asbd.pointee.mFormatID, kAudioFormatLinearPCM, "The offset fixture must remain lossless PCM")
        XCTAssertEqual(asbd.pointee.mSampleRate, 48_000)
        let expected = try await independentlyDecode(editedAsset, diagnosticName: "exported-audio-offset")
        XCTAssertGreaterThan(expected.map { abs($0) }.max() ?? 0, 0.01, "The edited PCM reference must retain its tone")
        XCTAssertEqual(expected.count, 16_800 * 2)
        XCTAssertTrue(expected.prefix(4_800 * 2).allSatisfy { abs($0) < 0.00001 })
        let renderer = ContinuousPCMRenderer(prefixFrames: 20_000, ringFrames: 512)
        let decoder = ContinuousPCMDecoder(renderer: renderer)
        defer { decoder.shutdown() }
        let prepared = try await decoder.prepare(url: edited, token: 1, slot: 0)
        XCTAssertEqual(prepared.totalFrames, 16_800)
        renderer.select(token: 1, frame: 0); renderer.setPlaying(true)
        var actual = [Float](repeating: .nan, count: 16_800 * 2)
        actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 16_800) }
        assertSamples(actual, equal: expected)
    }

    private func writePCM(_ samples: [Float], to url: URL, compressed: Bool = false, sampleRate: Double = 48_000) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / 2))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = samples[frame * 2]
            buffer.floatChannelData![1][frame] = samples[frame * 2 + 1]
        }
        let settings: [String: Any] = compressed
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
            : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private func writeConstantPCM(frames: Int, sampleRate: Double, value: Float, to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192))
        for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: value, count: Int(buffer.frameCapacity)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var remaining = frames
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(remaining, Int(buffer.frameCapacity)))
            try file.write(from: buffer); remaining -= Int(buffer.frameLength)
        }
    }

    private func render(_ graph: ContinuousAudioGraph, frames: Int) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: graph.engine.manualRenderingFormat, frameCapacity: 257)!
        var result: [Float] = []
        var retries = 0
        while result.count < frames * 2 {
            let count = min(257, frames - result.count / 2)
            let status = try graph.engine.renderOffline(AVAudioFrameCount(count), to: buffer)
            if status == .cannotDoInCurrentContext, retries < 10 { retries += 1; continue }
            XCTAssertEqual(status, .success)
            guard status == .success else { throw ContinuousPCMDecoder.Failure.cannotDecode }
            XCTAssertEqual(buffer.frameLength, AVAudioFrameCount(count))
            for frame in 0..<Int(buffer.frameLength) {
                result.append(buffer.floatChannelData![0][frame]); result.append(buffer.floatChannelData![1][frame])
            }
        }
        return result
    }

    private static func waitForPreparedFrames(_ renderer: ContinuousPCMRenderer, count: Int, totalFrames: Int64, timeout: Double = 3) async throws {
        let source = renderer.source(at: 0)
        let frame = renderer.snapshot.frame
        let streamedStart = max(frame, Int64(source.prefixCapacityFrames))
        let streamedEnd = min(frame + Int64(count), totalFrames)
        let needed = max(0, Int(streamedEnd - streamedStart))
        guard needed > 0 else { return }
        let epoch = source.streamRequest.epoch
        let deadline = Date().addingTimeInterval(timeout)
        while source.availableStreamFrames(for: epoch) < needed {
            guard Date() < deadline else {
                XCTFail("Prepared decoder epoch did not supply the exact next sample span")
                throw ContinuousPCMDecoder.Failure.cannotDecode
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func assertSamples(_ actual: [Float], equal expected: [Float], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        let mismatch = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }
        XCTAssertNil(mismatch.map(\.offset), "First changed/inserted/dropped sample: \(String(describing: mismatch))", file: file, line: line)
    }

    /// Array-backed reference: native PCM first, then a separate converter driver
    /// using 113-frame input and 257-frame output blocks (production uses 4096).
    /// This avoids the implicit AudioMixOutput converter that lost its tail.
    private func independentlyDecode(_ inputAsset: AVAsset, diagnosticName: String? = nil, quantizedEndSupport: Bool = true) async throws -> [Float] {
        let asset: AVAsset
        if let urlAsset = inputAsset as? AVURLAsset {
            asset = AVURLAsset(url: urlAsset.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        } else { asset = inputAsset }
        guard try await asset.load(.providesPreciseDurationAndTiming) else {
            XCTFail("Full-presentation comparisons require precise source timing")
            throw ContinuousPCMDecoder.Failure.unsupportedPCM
        }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first, "Synthetic fixture needs an iOS-readable audio track")
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        let sourceASBD = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description))
        let rate = sourceASBD.pointee.mSampleRate
        let channels = Int(sourceASBD.pointee.mChannelsPerFrame)
        let duration = try await asset.load(.duration)
        let range = try await track.load(.timeRange)
        let readEnd = CMTimeCompare(range.end, duration) > 0 ? range.end : duration
        let nativePresentationFrames = Int(CMTimeConvertScale(readEnd, timescale: CMTimeScale(rate), method: .roundHalfAwayFromZero).value)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: readEnd)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        var packets = 0
        var firstPacket: [String: Double]?
        var lastPackets: [[String: Double]] = []
        var outsidePresentationFrames = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            func trimSeconds(_ key: CFString) -> Double {
                guard let dictionary = CMGetAttachment(sample, key: key, attachmentModeOut: nil) as? [String: Any] else { return 0 }
                return CMTimeMakeFromDictionary(dictionary as CFDictionary).seconds
            }
            let trimStart = Int((trimSeconds(kCMSampleBufferAttachmentKey_TrimDurationAtStart) * rate).rounded())
            let trimEnd = Int((trimSeconds(kCMSampleBufferAttachmentKey_TrimDurationAtEnd) * rate).rounded())
            let packetFrames = bytes.count / (channels * 4)
            let packetStart = Int((CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds * rate).rounded())
            let decodedFrames = packetFrames - trimStart - trimEnd
            XCTAssertGreaterThanOrEqual(decodedFrames, 0)
            guard decodedFrames >= 0 else { throw ContinuousPCMDecoder.Failure.invalidTimeline }
            let validFrames = max(0, min(decodedFrames, nativePresentationFrames - packetStart))
            let included = max(0, min(nativePresentationFrames, packetStart + decodedFrames) - max(0, packetStart))
            outsidePresentationFrames += decodedFrames - included
            let oldFrames = samples.count / channels
            if packetStart > oldFrames {
                samples.append(contentsOf: repeatElement(0, count: (min(packetStart, nativePresentationFrames) - oldFrames) * channels))
            }
            let skipped = max(0, samples.count / channels - packetStart)
            if skipped < validFrames {
                bytes.withUnsafeBytes {
                    let values = $0.bindMemory(to: Float.self)
                    samples.append(contentsOf: values[((trimStart + skipped) * channels)..<((trimStart + validFrames) * channels)])
                }
            }
            if diagnosticName != nil {
                let asbd = CMSampleBufferGetFormatDescription(sample).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }
                let packet: [String: Double] = [
                    "packet": Double(packets), "byteFrames": Double(packetFrames),
                    "numSamples": Double(CMSampleBufferGetNumSamples(sample)),
                    "sampleRate": asbd?.pointee.mSampleRate ?? -1,
                    "rawPTS": CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                    "outputPTS": CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds,
                    "rawDuration": CMSampleBufferGetDuration(sample).seconds,
                    "outputDuration": CMSampleBufferGetOutputDuration(sample).seconds,
                    "trimStart": trimSeconds(kCMSampleBufferAttachmentKey_TrimDurationAtStart),
                    "trimEnd": trimSeconds(kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
                ].mapValues { $0.isFinite ? $0 : -1 }
                if firstPacket == nil { firstPacket = packet }
                lastPackets.append(packet)
                if lastPackets.count > 3 { lastPackets.removeFirst() }
                packets += 1
            }
        }
        XCTAssertEqual(reader.status, .completed)
        let nativeFrames = nativePresentationFrames
        XCTAssertLessThanOrEqual(samples.count / channels, nativeFrames)
        samples.append(contentsOf: repeatElement(0, count: nativeFrames * channels - samples.count))
        let inputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: UInt32(channels), interleaved: true))
        let outputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))
        if channels == 1 { converter.channelMap = [0, 0] }
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 113))
        let outputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 257))
        let presentationFrames = Int(CMTimeConvertScale(readEnd, timescale: 48_000, method: .roundHalfAwayFromZero).value)
        let requiredNative = (Int64(presentationFrames) * Int64(rate) + 47_999) / 48_000
        let supportFrames = quantizedEndSupport ? max(0, Int(requiredNative) - nativeFrames) : 0
        XCTAssertLessThanOrEqual(supportFrames, Int(ceil(rate / 96_000 + 0.5)))
        var suppliedSupport = 0
        var inputOffset = 0, converted: [Float] = [], iterations = 0
        while true {
            iterations += 1
            guard iterations < 100_000 else { throw ContinuousPCMDecoder.Failure.cannotDecode }
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, status in
                guard requested > 0 else { status.pointee = .noDataNow; return nil }
                let count = min(Int(requested), 113, nativeFrames - inputOffset)
                guard count > 0 else {
                    let needed = supportFrames - suppliedSupport
                    if needed > 0 {
                        let count = min(needed, Int(requested), 113)
                        guard count > 0 else { status.pointee = .endOfStream; return nil }
                        inputBuffer.floatChannelData![0].update(repeating: 0, count: count * channels)
                        inputBuffer.frameLength = AVAudioFrameCount(count); suppliedSupport += count
                        status.pointee = .haveData; return inputBuffer
                    }
                    status.pointee = .endOfStream; return nil
                }
                samples.withUnsafeBufferPointer {
                    inputBuffer.floatChannelData![0].update(from: $0.baseAddress!.advanced(by: inputOffset * channels), count: count * channels)
                }
                inputBuffer.frameLength = AVAudioFrameCount(count); inputOffset += count
                status.pointee = .haveData; return inputBuffer
            }
            XCTAssertNil(conversionError)
            XCTAssertNotEqual(status, .error)
            guard status != .error else { throw ContinuousPCMDecoder.Failure.cannotDecode }
            converted.append(contentsOf: UnsafeBufferPointer(start: outputBuffer.floatChannelData![0], count: Int(outputBuffer.frameLength) * 2))
            if status == .endOfStream { break }
        }
        if quantizedEndSupport {
            XCTAssertGreaterThanOrEqual(converted.count, presentationFrames * 2,
                "Native support and explicit flushing must calculate every declared presentation frame")
            XCTAssertLessThanOrEqual(converted.count / 2, presentationFrames + Int(ceil(48_000 / rate)),
                "Only the bounded native support may generate samples outside the declared timeline")
        }
        if let diagnosticName {
            let metrics: [String: Any] = ["fixture": diagnosticName, "assetSeconds": duration.seconds,
                "trackStartSeconds": range.start.seconds, "trackEndSeconds": range.end.seconds,
                "nativeDecodedFrames": samples.count / channels, "convertedFrames": converted.count / 2,
                "presentationFrames": presentationFrames, "nativeSupportFrames": suppliedSupport,
                "outsidePresentationNativeFrames": outsidePresentationFrames, "packets": packets,
                "nativePeak": samples.reduce(0.0) { max($0, Double(abs($1))) },
                "convertedPeak": converted.reduce(0.0) { max($0, Double(abs($1))) },
                "first": firstPacket ?? [:], "last": lastPackets]
            let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
            print("PCM_PACKET_DIAGNOSTICS " + String(decoding: data, as: UTF8.self))
        }
        // Support is outside the original presentation. Its filter response is
        // needed to calculate the final included frame, not to extend playback.
        return quantizedEndSupport ? Array(converted.prefix(presentationFrames * 2)) : converted
    }
}
