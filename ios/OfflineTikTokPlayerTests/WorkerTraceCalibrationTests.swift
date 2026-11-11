import Foundation
import XCTest
import PlayerCore
@testable import OfflineTikTokPlayer

/// Lexicographic class ordering keeps this tool calibration after playback
/// observations. A known sleeping queue is not a reproduction of starvation.
@MainActor
final class ZZZWorkerTraceCalibrationTests: XCTestCase {
    func testKnownWorkerWaitPublishesBoundedSamplerCalibration() async throws {
        let recorder = ContinuousPCMDecoder.ProgressRecorder()
        let workerID = recorder.workerIdentifier
        let requestID = UUID().uuidString.lowercased()
        let queue = DispatchQueue(label: "OfflineTikTokPlayer.PCMDecode." + workerID, qos: .userInitiated)
        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        queue.async {
            recorder.withKnownWorkerWait {
                entered.signal()
                // No busy loop, native reader, audio graph or user data is involved.
                _ = release.wait(timeout: .now() + .seconds(12))
            }
            finished.signal()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var active = false
        while !active, ProcessInfo.processInfo.systemUptime < deadline {
            active = entered.wait(timeout: .now()) == .success
            if !active { try await Task.sleep(for: .milliseconds(10)) }
        }
        guard active else { XCTFail("The bounded calibration worker did not start"); return }
        var waitingObservations = 0
        var waitingSnapshot: ContinuousPCMDecoder.ProgressSnapshot?
        for _ in 0..<10 {
            let snapshot = recorder.snapshot()
            let state = recorder.workerThreadState(matching: snapshot)
            XCTAssertGreaterThanOrEqual(state.acquisitionEndNs, state.acquisitionBeginNs)
            let acquisitionNs = state.acquisitionEndNs >= state.acquisitionBeginNs
                ? state.acquisitionEndNs - state.acquisitionBeginNs : UInt64.max
            if state.kernelReturnCode != -1 {
                XCTAssertLessThanOrEqual(acquisitionNs, 5_000_000,
                    "A kernel observation exceeding 5 ms is unavailable for calibration")
            }
            let available = state.statusCode == 0 && acquisitionNs <= 5_000_000
            if available {
                XCTAssertEqual(state.kernelReturnCode, 0)
                XCTAssertEqual(state.phaseSequence, snapshot.phaseSequence)
                XCTAssertEqual(snapshot.phase, .calibrationWait)
                XCTAssertGreaterThanOrEqual(state.userMicros, 0)
                XCTAssertGreaterThanOrEqual(state.systemMicros, 0)
                // Darwin TH_STATE_WAITING=3 and TH_STATE_UNINTERRUPTIBLE=4.
                // A sample immediately after entered.signal() can still be running.
                if state.runState == 3 || state.runState == 4 {
                    waitingObservations += 1
                    waitingSnapshot = snapshot
                }
            }
            print("SelectionWorkerThreadCalibration workerID=\(workerID) available=\(available) statusCode=\(state.statusCode) kernelReturnCode=\(state.kernelReturnCode) runState=\(state.runState) userMicros=\(state.userMicros) systemMicros=\(state.systemMicros) phaseSequence=\(state.phaseSequence) acquisitionBeginNs=\(state.acquisitionBeginNs) acquisitionEndNs=\(state.acquisitionEndNs)")
            if waitingObservations >= 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard waitingObservations >= 2, let waitingSnapshot else {
            XCTFail("The known sleeping worker must yield two valid waiting-state observations")
            return
        }
        let written = SelectionNativeWorkerSample.request(purpose: 2,
            workerIdentifier: workerID, identifier: requestID)
        XCTAssertTrue(written, "Calibration must publish its bounded request")
        print("SelectionNativeWorkerCalibration requestID=\(requestID) workerID=\(workerID) written=\(written)")
        // Separate from every playback timing window; host commands cap at
        // 1s PID + 1s bundle + 4s sampling. The host-log gate requires success.
        try await Task.sleep(for: .seconds(7))
        release.signal()
        let completionDeadline = ProcessInfo.processInfo.systemUptime + 1
        var completed = false
        while !completed, ProcessInfo.processInfo.systemUptime < completionDeadline {
            completed = finished.wait(timeout: .now()) == .success
            if !completed { try await Task.sleep(for: .milliseconds(10)) }
        }
        guard completed else { XCTFail("The bounded calibration worker did not complete after release"); return }
        let stale = recorder.workerThreadState(matching: waitingSnapshot)
        XCTAssertEqual(stale.statusCode, 5, "Completing the wait must invalidate its saved phase snapshot")
        XCTAssertEqual(stale.runState, 0)
        XCTAssertEqual(stale.userMicros, 0)
        XCTAssertEqual(stale.systemMicros, 0)
        XCTAssertEqual(recorder.workerThreadState(matching: recorder.snapshot()).statusCode, 3)
        recorder.setTracingEnabled(false)
        XCTAssertEqual(recorder.workerThreadState(matching: recorder.snapshot()).statusCode, 1)
        try await verifyNativeCopyCompletions()
        try await verifyIdleDecoderLifecycle()
        try await verifyHeldDecoderLifecycle()
    }

    private func verifyNativeCopyCompletions() async throws {
        // A fresh synthetic recorder exercises publication only, after the host
        // calibration. No reader, converter, audio graph or SDK wait is involved.
        let recorder = ContinuousPCMDecoder.ProgressRecorder()
        let empty = recorder.nativeCopyCompletionSnapshot()
        XCTAssertTrue(empty.coherent)
        XCTAssertEqual(empty.slot0, .empty)
        XCTAssertEqual(empty.slot1, .empty)
        XCTAssertEqual(empty.slot2, .empty)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let queue = DispatchQueue(label: "OfflinePlayer.TestCopyCompletionCalibration")
        queue.async {
            let mark = recorder.beginNativeCopyCalibration(token: 101, slot: 0, epoch: 0)
            entered.signal()
            _ = release.wait(timeout: .now() + .seconds(12))
            recorder.endNativeCopyCalibration(mark)
            finished.signal()
        }
        guard try await untilLifecycle({ entered.wait(timeout: .now()) == .success }) else {
            XCTFail("The synthetic copy scope must enter"); return
        }
        let held = recorder.nativeCopyCompletionSnapshot()
        XCTAssertTrue(held.coherent)
        XCTAssertEqual(held.phase, .nativeCopy)
        XCTAssertEqual(held.token, 101)
        XCTAssertEqual(held.slot, 0)
        XCTAssertEqual(held.epoch, 0)
        XCTAssertGreaterThan(held.phaseSequence, 0)
        XCTAssertGreaterThan(held.phaseEnteredUptimeNanoseconds, 0)
        assertEmptyCopyKey(held.slot0, token: 101, epoch: 0)
        release.signal()
        guard try await untilLifecycle({ finished.wait(timeout: .now()) == .success }) else {
            XCTFail("The released synthetic copy scope must complete"); return
        }
        let completed = recorder.nativeCopyCompletionSnapshot()
        XCTAssertTrue(completed.coherent)
        XCTAssertEqual(completed.phase, .idle)
        XCTAssertEqual(completed.slot0.completedCount, 1)
        XCTAssertEqual(completed.slot0.maximumEntrySequence, held.phaseSequence)
        XCTAssertEqual(completed.slot0.maximumStartNanoseconds, held.phaseEnteredUptimeNanoseconds)
        XCTAssertGreaterThanOrEqual(completed.slot0.maximumEndNanoseconds, completed.slot0.maximumStartNanoseconds)
        let initialDuration = completed.slot0.maximumEndNanoseconds.subtractingReportingOverflow(
            completed.slot0.maximumStartNanoseconds)
        XCTAssertFalse(initialDuration.overflow)
        XCTAssertEqual(completed.slot0.maximumWallNanoseconds, initialDuration.partialValue)
        XCTAssertEqual(completed.slot0.completedWallNanoseconds, completed.slot0.maximumWallNanoseconds)
        XCTAssertFalse(completed.slot0.wallTimeOverflowed)

        let prior = recorder.beginNativeCopyCalibration(token: 101, slot: 0, epoch: 0)
        let priorEntry = recorder.nativeCopyCompletionSnapshot()
        recorder.endNativeCopyCalibration(prior)
        let second = recorder.nativeCopyCompletionSnapshot()
        XCTAssertEqual(second.slot0.completedCount, 2)
        XCTAssertGreaterThanOrEqual(second.slot0.completedWallNanoseconds, completed.slot0.completedWallNanoseconds)
        XCTAssertGreaterThanOrEqual(second.slot0.maximumWallNanoseconds, completed.slot0.maximumWallNanoseconds)
        if second.slot0.maximumEntrySequence == priorEntry.phaseSequence {
            XCTAssertEqual(second.slot0.maximumStartNanoseconds, priorEntry.phaseEnteredUptimeNanoseconds)
            let nextDuration = second.slot0.maximumEndNanoseconds.subtractingReportingOverflow(
                second.slot0.maximumStartNanoseconds)
            XCTAssertFalse(nextDuration.overflow)
            XCTAssertEqual(second.slot0.maximumWallNanoseconds, nextDuration.partialValue)
        } else {
            XCTAssertEqual(second.slot0.maximumWallNanoseconds, completed.slot0.maximumWallNanoseconds)
            XCTAssertEqual(second.slot0.maximumEntrySequence, completed.slot0.maximumEntrySequence)
            XCTAssertEqual(second.slot0.maximumStartNanoseconds, completed.slot0.maximumStartNanoseconds)
            XCTAssertEqual(second.slot0.maximumEndNanoseconds, completed.slot0.maximumEndNanoseconds)
        }
        let current = recorder.beginNativeCopyCalibration(token: 101, slot: 0, epoch: 0)
        let active = recorder.nativeCopyCompletionSnapshot()
        recorder.endNativeCopyCalibration(prior)
        XCTAssertEqual(recorder.nativeCopyCompletionSnapshot(), active,
            "An old same-key return cannot restore or count over a later entry")
        recorder.endNativeCopyCalibration(current)
        let third = recorder.nativeCopyCompletionSnapshot()
        XCTAssertEqual(third.slot0.completedCount, 3)
        recorder.endNativeCopyCalibration(current)
        XCTAssertEqual(recorder.nativeCopyCompletionSnapshot(), third, "A duplicate return cannot count twice")

        let other = recorder.beginNativeCopyCalibration(token: 202, slot: 1, epoch: 2)
        XCTAssertEqual(recorder.nativeCopyCompletionSnapshot().slot0, third.slot0,
            "A's maximum cannot overwrite B's separate physical-slot summary")
        recorder.endNativeCopyCalibration(other)
        let otherCompleted = recorder.nativeCopyCompletionSnapshot().slot1
        XCTAssertEqual(otherCompleted.completedCount, 1)
        let replacement = recorder.beginNativeCopyCalibration(token: 202, slot: 0, epoch: 0)
        let replaced = recorder.nativeCopyCompletionSnapshot()
        assertEmptyCopyKey(replaced.slot0, token: 202, epoch: 0)
        XCTAssertEqual(replaced.slot1, otherCompleted)
        recorder.endNativeCopyCalibration(current)
        XCTAssertEqual(recorder.nativeCopyCompletionSnapshot(), replaced,
            "An obsolete token's return cannot alter the replacement generation")
        recorder.endNativeCopyCalibration(replacement)
        let newEpoch = recorder.beginNativeCopyCalibration(token: 202, slot: 0, epoch: 2)
        let reset = recorder.nativeCopyCompletionSnapshot()
        assertEmptyCopyKey(reset.slot0, token: 202, epoch: 2)
        XCTAssertEqual(reset.slot1, otherCompleted)
        recorder.endNativeCopyCalibration(newEpoch)
        let epochCompleted = recorder.nativeCopyCompletionSnapshot()
        XCTAssertEqual(epochCompleted.slot0.completedCount, 1)
        XCTAssertEqual(epochCompleted.slot0.maximumEntrySequence, reset.phaseSequence)
        recorder.withKnownWorkerWait {}
        XCTAssertEqual(recorder.nativeCopyCompletionSnapshot().slot0, epochCompleted.slot0,
            "Generic phase changes must preserve a completed token/epoch history")
        let last = recorder.beginNativeCopyCalibration(token: 303, slot: 2, epoch: 2)
        recorder.endNativeCopyCalibration(last)
        let allSlots = recorder.nativeCopyCompletionSnapshot()
        XCTAssertEqual(allSlots.slot0, epochCompleted.slot0)
        XCTAssertEqual(allSlots.slot1, otherCompleted)
        XCTAssertEqual(allSlots.slot2.completedCount, 1)

        recorder.setTracingEnabled(false)
        let disabledPhase = recorder.snapshot()
        XCTAssertEqual(recorder.nativeCopyCompletionSnapshot(), .disabled)
        let disabled = recorder.beginNativeCopyCalibration(token: 404, slot: 0, epoch: 3)
        recorder.endNativeCopyCalibration(disabled)
        XCTAssertEqual(recorder.nativeCopyCompletionSnapshot(), .disabled,
            "Disabled completion snapshots expose constant empty counters")
        XCTAssertEqual(recorder.snapshot().phaseSequence, disabledPhase.phaseSequence)
        XCTAssertEqual(recorder.snapshot().phaseEnteredUptimeNanoseconds, disabledPhase.phaseEnteredUptimeNanoseconds)
    }

    private func assertEmptyCopyKey(_ value: ContinuousPCMDecoder.NativeCopySlotSnapshot, token: Int, epoch: Int,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value, ContinuousPCMDecoder.NativeCopySlotSnapshot(token: token, epoch: epoch,
            completedCount: 0, completedWallNanoseconds: 0, wallTimeOverflowed: false,
            maximumWallNanoseconds: 0, maximumEntrySequence: 0, maximumStartNanoseconds: 0,
            maximumEndNanoseconds: 0), file: file, line: line)
    }

    private func verifyIdleDecoderLifecycle() async throws {
        let before = ContinuousPCMDecoder.lifecycleSnapshot()
        var decoder: ContinuousPCMDecoder? = ContinuousPCMDecoder(renderer: ContinuousPCMRenderer())
        defer { decoder?.shutdown() }
        weak var owner = decoder
        let recorder = try XCTUnwrap(decoder?.progressRecorder)
        // Lifecycle publication is independent of optional native tracing.
        recorder.setTracingEnabled(false)
        decoder?.shutdown()
        decoder?.shutdown()
        XCTAssertTrue(recorder.lifecycleSnapshot().shutdownRequested)
        decoder = nil
        let completed = try await untilLifecycle {
            let state = recorder.lifecycleSnapshot()
            return state.shutdownCompleted && state.deinitEntered && owner == nil
        }
        XCTAssertTrue(completed, "An idle decoder must finish shutdown and enter deinit while its recorder remains retained")
        let state = recorder.lifecycleSnapshot()
        XCTAssertTrue(state.shutdownRequested)
        XCTAssertTrue(state.shutdownCompleted)
        XCTAssertTrue(state.deinitEntered)
        XCTAssertNil(owner)
        let after = ContinuousPCMDecoder.lifecycleSnapshot()
        assertMinimumIncrease(after.createdInstances, from: before.createdInstances, minimum: 1)
        assertMinimumIncrease(after.shutdownRequestCalls, from: before.shutdownRequestCalls, minimum: 2)
        assertMinimumIncrease(after.shutdownRequestedInstances, from: before.shutdownRequestedInstances, minimum: 1)
        assertMinimumIncrease(after.shutdownCompletedInstances, from: before.shutdownCompletedInstances, minimum: 1)
        assertMinimumIncrease(after.deinitEnteredInstances, from: before.deinitEnteredInstances, minimum: 1)
        if after.stableReread { XCTAssertNotNil(after.liveInstances, "Stable lifecycle counts must permit checked live-instance arithmetic") }
        logLifecycle("idle-completed", recorder: recorder)
    }

    private func verifyHeldDecoderLifecycle() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var decoder: ContinuousPCMDecoder? = ContinuousPCMDecoder(renderer: ContinuousPCMRenderer())
        defer { decoder?.shutdown(); release.signal() }
        weak var owner = decoder
        let recorder = try XCTUnwrap(decoder?.progressRecorder)
        decoder?.enqueueLifecycleCalibrationHold(entered: entered, release: release)
        let active = try await untilLifecycle { entered.wait(timeout: .now()) == .success }
        guard active else { XCTFail("The actual decoder worker did not enter its bounded lifecycle hold"); return }
        decoder?.shutdown()
        decoder = nil
        let pending = recorder.lifecycleSnapshot()
        XCTAssertTrue(pending.shutdownRequested)
        XCTAssertFalse(pending.shutdownCompleted)
        XCTAssertFalse(pending.deinitEntered)
        XCTAssertNotNil(owner, "Queued shutdown must retain its decoder until the held worker can run it")
        XCTAssertEqual(recorder.snapshot().phase, .calibrationWait)
        logLifecycle("held-pending", recorder: recorder)
        release.signal()
        let completed = try await untilLifecycle {
            let state = recorder.lifecycleSnapshot()
            return state.shutdownCompleted && state.deinitEntered && owner == nil
        }
        XCTAssertTrue(completed, "Releasing the worker must allow queued shutdown and deinit to finish")
        let state = recorder.lifecycleSnapshot()
        XCTAssertTrue(state.shutdownRequested)
        XCTAssertTrue(state.shutdownCompleted)
        XCTAssertTrue(state.deinitEntered)
        XCTAssertNil(owner)
        logLifecycle("held-completed", recorder: recorder)
    }

    private func untilLifecycle(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func assertMinimumIncrease(_ value: Int64, from previous: Int64, minimum: Int64,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let difference = value.subtractingReportingOverflow(previous)
        XCTAssertFalse(difference.overflow, file: file, line: line)
        if !difference.overflow {
            XCTAssertGreaterThanOrEqual(difference.partialValue, minimum, file: file, line: line)
        }
    }

    private func logLifecycle(_ phase: String, recorder: ContinuousPCMDecoder.ProgressRecorder) {
        let global = ContinuousPCMDecoder.lifecycleSnapshot()
        let state = recorder.lifecycleSnapshot()
        print("SelectionDecoderLifecycleCalibration phase=\(phase) workerID=\(recorder.workerIdentifier) createdInstances=\(global.createdInstances) deinitEnteredInstances=\(global.deinitEnteredInstances) liveInstances=\(global.liveInstances ?? -1) stableReread=\(global.stableReread) shutdownRequestCalls=\(global.shutdownRequestCalls) shutdownRequestedInstances=\(global.shutdownRequestedInstances) shutdownCompletedInstances=\(global.shutdownCompletedInstances) shutdownRequested=\(state.shutdownRequested) shutdownCompleted=\(state.shutdownCompleted) deinitEntered=\(state.deinitEntered)")
    }
}
