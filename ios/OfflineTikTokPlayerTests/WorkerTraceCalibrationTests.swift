import Foundation
import XCTest
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
    }
}
