import Foundation
import Dispatch

@main struct GateChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAILED: " + message); exit(1) }
    }
    static func main() {
        var gate = NativePreparationHeartbeatGate(start: 1_000)
        check(gate.claim(now: 250_001_000) == nil, "No heartbeat cannot claim")
        gate.heartbeat(now: 1_000, phase: 4, request: 1, generation: 1)
        check(gate.claim(now: 250_000_999) == nil, "Do not sample below the250ms threshold")
        let claim = gate.claim(now: 250_001_000)
        check(claim != nil, "A250ms missing heartbeat must claim exactly one sample")
        check(claim?.heartbeat.phase == 4 && claim?.heartbeat.request == 1, "Retain the exact cached phase and request")
        check(gate.claim(now: 500_001_000) == nil, "Never sample twice")

        var refreshed = NativePreparationHeartbeatGate(start: 0)
        refreshed.heartbeat(now: 0, phase: 0, request: 0, generation: 0)
        refreshed.heartbeat(now: 200_000_000, phase: 4, request: 1, generation: 1)
        check(refreshed.claim(now: 250_000_000) == nil, "A heartbeat resets the missing interval")
        check(refreshed.claim(now: 100_000_000) == nil && !refreshed.stopped,
              "A delayed timer timestamp older than the heartbeat cannot close observation")
        check(refreshed.claim(now: 450_000_000)?.heartbeat.ordinal == 2, "Claim identifies the latest heartbeat")
        var closed = NativePreparationHeartbeatGate(start: 0)
        closed.heartbeat(now: 0, phase: 4, request: 1, generation: 1)
        closed.stop()
        check(closed.claim(now: 500_000_000) == nil, "Closed observations cannot claim")
        var expired = NativePreparationHeartbeatGate(start: 0)
        expired.heartbeat(now: 0, phase: 4, request: 1, generation: 1)
        check(expired.claim(now: 4_000_000_000) == nil && expired.stopped, "Expire at the original4second window")
        var reversed = NativePreparationHeartbeatGate(start: 1_000)
        reversed.heartbeat(now: 1_000, phase: 4, request: 1, generation: 1)
        check(reversed.claim(now: 999) == nil && reversed.stopped, "Reject backwards clock observations")
        checkOwnedDrain()
        let expiredSampler = FakeSampler()
        let expiredObserver = NativePreparationStallObservation(start: 0, mainThreadConfirmed: false,
            clock: { 4_000_000_000 }, sample: { expiredSampler.sample() }, closeNative: { expiredSampler.close() })
        check(waitFor { expiredObserver.result.closed }, "The real timer must expire and drain without caller polling")
        check(expiredSampler.counts.0 == 0 && expiredSampler.counts.1 == 1, "Expiration cannot launch a query")
        print("Initial preparation heartbeat gate checks passed")
    }

    final class FakeSampler: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0, closes = 0
        func sample() -> [String: Any] {
            lock.withLock { calls += 1 }
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            return ["available": true, "frames": [["symbol": "fake-only"]]]
        }
        func close() { lock.withLock { closes += 1 } }
        var counts: (Int, Int) { lock.withLock { (calls, closes) } }
    }
    static func waitFor(_ predicate: () -> Bool) -> Bool {
        let end = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < end {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return predicate()
    }
    static func checkOwnedDrain() {
        let fake = FakeSampler()
        let observer = NativePreparationStallObservation(start: 0, automatic: false, mainThreadConfirmed: false,
            clock: { 500_000_000 }, sample: { fake.sample() }, closeNative: { fake.close() })
        observer.heartbeat(now: 100_000_000, phase: 4, request: 1, generation: 1)
        observer.enqueueCalibrationTick(now: 50_000_000)
        observer.enqueueCalibrationTick(now: 350_000_000)
        check(fake.entered.wait(timeout: .now() + 1) == .success, "The query must actually enter")
        observer.heartbeat(now: 360_000_000, phase: 5, request: 1, generation: 1)
        observer.stop(); observer.stop()
        check(!observer.result.closed && fake.counts.1 == 0, "Stop cannot close a native context during an actual query")
        observer.enqueueCalibrationTick(now: 270_000_000)
        fake.release.signal()
        check(waitFor { observer.result.closed }, "The owned query must drain and close")
        let result = observer.result
        check(fake.counts.0 == 1 && fake.counts.1 == 1 && result.queries == 1 && result.rows.count == 1, "One query and one actual close only")
        check(result.rows[0]["heartbeatUnchangedAtReturn"] as? Bool == false, "A heartbeat change or stop cannot remain qualified")
        check(result.rows[0]["phaseExecutionQualified"] as? Bool == false, "A cached phase never proves executing phase")
    }
}
