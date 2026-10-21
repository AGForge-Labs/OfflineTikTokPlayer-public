import XCTest
import AVFoundation
import Synchronization
@testable import OfflineTikTokPlayer

@MainActor
final class ContinuousAudioPlayerTests: XCTestCase {
    func testCancelledCoalescedPreparationCallersReleaseWhileLegitimateNativeReadIsHeld() async throws {
        #if DEBUG
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
        var heldFinished = -1, heldCancelled = -1, heldLiveWitnesses = -1, heldActiveCalls = -1
        let token = audio.debugPreparationState.nextToken
        do {
            // Retain B throughout; cancellation of eight callers must not be
            // confused with setWindow cancelling the one legitimate producer.
            audio.setWindow(["b"])
            guard gate.arm(token: token) else { throw CAPCancellationSetupError.invalidSetup }
            audio.debugSetNativeReadGate(gate)
            nativePreparationStarted = true
            legitimate = Task {
                do { run.legitimateEntry = try await audio.prepare(id: "b", url: url) }
                catch { run.legitimateFailed = true }
                run.legitimateFinished = true
            }
            let entered = await Self.capCancellationWait(.seconds(2)) { gate.isHolding }
            let initial = audio.debugPreparationState
            guard entered, !gate.didTimeOut, initial.activeCalls == 1,
                  initial.sharedTasks == 1, initial.reservedSlots == 1,
                  !initial.counterOverflowed, audio.preparedCount == 0,
                  !run.legitimateFinished else {
                XCTFail("Setup must hold B's first real native read before any prefix publication")
                throw CAPCancellationSetupError.invalidSetup
            }
            for index in 0..<8 {
                callers.append(Task {
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
                })
            }
            let registered = await Self.capCancellationWait(.seconds(1)) {
                run.entered == 8 && run.liveWitnesses == 8 && audio.debugPreparationState.activeCalls == 9
            }
            let registeredState = audio.debugPreparationState
            guard registered, gate.isHolding, !gate.didTimeOut,
                  registeredState.sharedTasks == 1, registeredState.reservedSlots == 1,
                  !registeredState.counterOverflowed else {
                XCTFail("All eight additional callers must actually enter the same held preparation")
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
                "Cancelled coalesced callers must finish and release task-local owners while legitimate B remains held")

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
        print("CAP_SHARED_PREPARATION_CANCELLATION expectedCallers=8 enteredCallers=\(run.entered) coalescedSetupVerified=\(coalescedSetupVerified) heldFinished=\(heldFinished) heldCancelled=\(heldCancelled) heldLiveWitnesses=\(heldLiveWitnesses) heldActiveCalls=\(heldActiveCalls) finalFinished=\(run.finished) finalReturnedEntry=\(run.returnedEntry) finalOtherErrors=\(run.otherErrors) nativeCloseAcknowledged=\(closed.withLock { $0 } == true) callersSettled=\(callersSettled) gateTimedOut=\(gate.didTimeOut) cancellationMaximumMilliseconds=250 gateMaximumSeconds=5 expectedFrames=257 exactSamplesVerified=\(exactSamplesVerified) resourceScope=caller-lifetimes-not-RSS latencyFix=false")
        if let setupError { throw setupError }
        #else
        XCTFail("This native cancellation control requires DEBUG gate seams")
        #endif
    }

    #if DEBUG
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
