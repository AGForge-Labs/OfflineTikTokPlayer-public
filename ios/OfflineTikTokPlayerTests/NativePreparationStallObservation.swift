import Foundation
import Dispatch

/// Test-only fixed-window trigger. This does not identify a blocking SDK call.
struct NativePreparationHeartbeatGate: Sendable {
    struct Heartbeat: Sendable, Equatable {
        let ordinal: UInt64, time: UInt64
        let phase: Int, request: Int, generation: Int
    }
    struct Claim: Sendable { let heartbeat: Heartbeat, entry: UInt64 }
    let start: UInt64
    private(set) var last: Heartbeat?
    private(set) var claimed = false
    private(set) var stopped = false
    init(start: UInt64) { self.start = start }
    mutating func heartbeat(now: UInt64, phase: Int, request: Int, generation: Int) {
        guard !stopped, now >= start, now >= (last?.time ?? start), (last?.ordinal ?? 0) < .max else {
            stopped = true; return
        }
        last = Heartbeat(ordinal: (last?.ordinal ?? 0) + 1, time: now,
                         phase: phase, request: request, generation: generation)
    }
    mutating func claim(now: UInt64) -> Claim? {
        guard !stopped, now >= start, now - start < 4_000_000_000 else {
            stopped = true; return nil
        }
        // Timer clocks are read before the state lock. A newer heartbeat can
        // legitimately win that lock first; ignore the old tick and keep watching.
        guard now >= (last?.time ?? start) else { return nil }
        guard !claimed, let last, now - last.time >= 250_000_000 else { return nil }
        claimed = true
        return Claim(heartbeat: last, entry: now)
    }
    mutating func stop() { stopped = true }
}

/// One own-thread query on a dedicated non-RT serial queue. The native probe
/// captures best-effort frames; cached heartbeat fields cannot qualify an SDK phase.
final class NativePreparationStallObservation: @unchecked Sendable {
    struct Result {
        let closed: Bool, claimed: Bool, queries: Int, mainThreadConfirmed: Bool
        let rows: [[String: Any]]
    }
    private let lock = NSLock()
    private var gate: NativePreparationHeartbeatGate
    private var closeRequested = false, closed = false
    private var queries = 0
    private var rows: [[String: Any]] = []
    private let queue = DispatchQueue(label: "OfflineTikTokPlayer.Tests.InitialMainThreadSample", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let clock: @Sendable () -> UInt64
    private let sample: @Sendable () -> [String: Any]
    private let closeNative: @Sendable () -> Void
    private let mainThreadConfirmed: Bool

    init(start: UInt64 = DispatchTime.now().uptimeNanoseconds, automatic: Bool = true,
         mainThreadConfirmed: Bool, clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         sample: @escaping @Sendable () -> [String: Any], closeNative: @escaping @Sendable () -> Void) {
        gate = NativePreparationHeartbeatGate(start: start)
        self.clock = clock; self.sample = sample; self.closeNative = closeNative
        self.mainThreadConfirmed = mainThreadConfirmed
        rows.reserveCapacity(1)
        if automatic {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            self.timer = timer
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.tick(now: self.clock())
            }
            timer.resume()
        }
    }

    func heartbeat(now: UInt64, phase: Int, request: Int, generation: Int) {
        lock.withLock { gate.heartbeat(now: now, phase: phase, request: request, generation: generation) }
    }
    var result: Result {
        lock.withLock { Result(closed: closed, claimed: gate.claimed, queries: queries,
                               mainThreadConfirmed: mainThreadConfirmed, rows: rows) }
    }
    func stop() {
        let first = lock.withLock { () -> Bool in
            guard !closeRequested else { return false }
            closeRequested = true; gate.stop(); return true
        }
        guard first else { return }
        timer?.cancel()
        // Never wait on the MainActor or close its retained port during a query.
        // This strong, owned drain finishes even after the test's last reference leaves.
        queue.async { [self] in
            closeNative()
            lock.withLock { closed = true }
        }
    }
    /// Local calibration entry only; it uses the same serial owner as the timer.
    func enqueueCalibrationTick(now: UInt64) { queue.async { [self] in tick(now: now) } }
    private func tick(now: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        let decision = lock.withLock { () -> (NativePreparationHeartbeatGate.Claim?, Bool) in
            let claim = gate.claim(now: now)
            if claim != nil { queries += 1 }
            return (claim, gate.stopped)
        }
        guard let claim = decision.0 else {
            if decision.1 { stop() }
            return
        }
        var row = sample()
        let returned = clock()
        lock.withLock {
            row["schema"] = 1
            row["scope"] = "test-process-recorded-main-thread-only"
            row["mainThreadConfirmed"] = mainThreadConfirmed
            row["heartbeatOrdinal"] = claim.heartbeat.ordinal
            row["heartbeatNs"] = claim.heartbeat.time
            row["queryEntryNs"] = claim.entry; row["queryReturnNs"] = returned
            row["heartbeatUnchangedAtReturn"] = gate.last == claim.heartbeat && !closeRequested
            row["cachedPhase"] = claim.heartbeat.phase
            row["cachedRequest"] = claim.heartbeat.request; row["cachedGeneration"] = claim.heartbeat.generation
            row["phaseExecutionQualified"] = false; row["stackCoherent"] = false
            row["sdkInternalCause"] = "unestablished"; row["physicalOutputProof"] = false
            rows.append(row)
        }
        stop()
    }
}

#if canImport(ObjectiveC) && !OP_STALL_GATE_CALIBRATION
/// Own MainActor registration only. The original probe owns/duplicates/releases
/// its port rights and bounds frame walking to16; no decoder context is borrowed.
private final class InitialMainThreadContext: @unchecked Sendable {
    let mainThreadConfirmed: Bool
    private let native = OPNativeReaderWaitProbe()
    @MainActor init() {
        mainThreadConfirmed = Thread.isMainThread
        if mainThreadConfirmed { native.noteOwnThread(forLane: 0, copySequence: 1) }
    }
    func sample() -> [String: Any] { native.sampleLane(0, copySequence: 1) }
    func close() { native.close() }
}
extension NativePreparationStallObservation {
    @MainActor static func usingOwnMainThread() -> NativePreparationStallObservation {
        let context = InitialMainThreadContext()
        return NativePreparationStallObservation(mainThreadConfirmed: context.mainThreadConfirmed,
            sample: { context.sample() }, closeNative: { context.close() })
    }
}
#endif
