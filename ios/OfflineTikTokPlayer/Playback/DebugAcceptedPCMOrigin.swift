#if DEBUG
import Foundation

/// Diagnostic values only. A clean result describes accepted post-SRC content,
/// not encoded-source silence, a rendered buffer, tap timing or physical output.
struct DebugAcceptedPCMOriginRecord: Sendable {
    let kind: Int // 1 pinned prefix (all visits), 2 one ring epoch.
    let token: Int
    let slot: Int
    let epoch: Int // Prefix uses zero deliberately; it is shared by every visit.
    let firstFrame: Int64
    var endFrame: Int64
    var zeroFrames: Int64 = 0
    var leadingZeroFrames: Int64 = 0
    var trailingZeroFrames: Int64 = 0
    var longestZeroFrames: Int64 = 0
    var firstRunStart: Int64 = -1
    var firstRunEnd: Int64 = -1
    var longestRunStart: Int64 = -1
    var longestRunEnd: Int64 = -1
    var nonFiniteFrames: Int64 = 0
    var batches: UInt64 = 0
    var coverageFailed = false
    var closed = false
    fileprivate var leadingOpen = true
    var acceptedFrames: Int64 { endFrame - firstFrame }
    // Retirement/prefix completion does not prove the next source sample is nonzero.
    var trailingRunTouchesCoverageEnd: Bool { trailingZeroFrames > 0 }
}

struct DebugAcceptedPCMOriginCoverage: Sendable {
    let complete: Bool
    let longestZeroFrames: Int64
    var boundaryRunStart: Int64 = -1
    var boundaryRunEnd: Int64 = -1
    var hasQualifyingZero: Bool { longestZeroFrames >= 480 }
}

struct DebugAcceptedPCMOriginSnapshot: Sendable {
    let records: [DebugAcceptedPCMOriginRecord] // At most 3 prefix + 12 ring records.
    let capacityExceeded: Bool
    let invalidInput: Bool
    let overflowed: Bool
    var failed: Bool {
        capacityExceeded || invalidInput || overflowed
            || records.contains { $0.coverageFailed || $0.nonFiniteFrames != 0 }
    }

    /// Coverage is conservative: any diagnostic failure invalidates a clean claim.
    /// Prefix/ring boundary runs are joined without scanning the prefix again.
    /// Maxima can include accepted read-ahead beyond `through`; this is explicit
    /// accepted-range evidence, not the location of a particular tap event.
    func coverage(token: Int, epoch: Int, through end: Int64) -> DebugAcceptedPCMOriginCoverage {
        let missing = DebugAcceptedPCMOriginCoverage(complete: false, longestZeroFrames: 0)
        guard !failed, token > 0, epoch > 0, end > 0,
              let prefix = records.first(where: { $0.kind == 1 && $0.token == token }),
              prefix.firstFrame == 0 else { return missing }
        if end <= prefix.endFrame {
            return DebugAcceptedPCMOriginCoverage(complete: true, longestZeroFrames: prefix.longestZeroFrames)
        }
        guard let ring = records.first(where: {
            $0.kind == 2 && $0.token == token && $0.slot == prefix.slot && $0.epoch == epoch
        }), ring.firstFrame == prefix.endFrame, ring.endFrame >= end else { return missing }
        let crossing = prefix.trailingZeroFrames.addingReportingOverflow(ring.leadingZeroFrames)
        guard !crossing.overflow else { return missing }
        return DebugAcceptedPCMOriginCoverage(complete: true,
            longestZeroFrames: max(max(prefix.longestZeroFrames, ring.longestZeroFrames), crossing.partialValue),
            boundaryRunStart: crossing.partialValue >= 480 ? prefix.endFrame - prefix.trailingZeroFrames : -1,
            boundaryRunEnd: crossing.partialValue >= 480 ? prefix.endFrame + ring.leadingZeroFrames : -1)
    }
}

/// Single converter-worker writer. Snapshot access is queued onto that worker;
/// this object owns no decoder, URLs, SDK readers, PCM or task/owner callbacks.
/// State has 15 descriptor slots. One offpath snapshot returns <=15 values;
/// its compact/concatenated temporary value copies are also bounded by those slots.
/// These are app-owned descriptor bounds, not an SDK allocation or RSS bound.
final class DebugAcceptedPCMOriginRecorder: @unchecked Sendable {
    private var prefixes = [DebugAcceptedPCMOriginRecord?](repeating: nil, count: 3)
    private var rings = [DebugAcceptedPCMOriginRecord?](repeating: nil, count: 12)
    private var capacityExceeded = false, invalidInput = false, overflowed = false

    func recordPrefix(token: Int, slot: Int, interleaved: UnsafeBufferPointer<Float>) {
        guard token > 0, (0..<3).contains(slot), !interleaved.isEmpty, interleaved.count % 2 == 0 else {
            invalidInput = true; return
        }
        guard !prefixes.contains(where: { $0?.token == token }),
              let index = prefixes.firstIndex(where: { $0 == nil }) else {
            capacityExceeded = true; return
        }
        var record = DebugAcceptedPCMOriginRecord(kind: 1, token: token, slot: slot, epoch: 0,
                                                  firstFrame: 0, endFrame: 0)
        scan(interleaved, startFrame: 0, into: &record)
        record.closed = true
        prefixes[index] = record
    }

    func recordRing(token: Int, slot: Int, epoch: Int, startFrame: Int64,
                    interleaved: UnsafeBufferPointer<Float>) {
        guard token > 0, (0..<3).contains(slot), epoch > 0, epoch % 2 == 0,
              startFrame >= 0, !interleaved.isEmpty, interleaved.count % 2 == 0 else {
            invalidInput = true; return
        }
        let existing = rings.firstIndex { $0?.token == token && $0?.slot == slot && $0?.epoch == epoch }
        guard let index = existing ?? rings.firstIndex(where: { $0 == nil }) else {
            capacityExceeded = true; return
        }
        if existing == nil {
            for other in rings.indices where rings[other]?.token == token && rings[other]?.slot == slot {
                rings[other]?.closed = true
            }
        }
        var record = rings[index] ?? DebugAcceptedPCMOriginRecord(kind: 2, token: token, slot: slot,
            epoch: epoch, firstFrame: startFrame, endFrame: startFrame)
        guard !record.closed else { record.coverageFailed = true; rings[index] = record; return }
        scan(interleaved, startFrame: startFrame, into: &record)
        rings[index] = record
    }

    func close(token: Int) {
        for index in rings.indices where rings[index]?.token == token { rings[index]?.closed = true }
    }

    func snapshotOnWorker() -> DebugAcceptedPCMOriginSnapshot {
        DebugAcceptedPCMOriginSnapshot(records: prefixes.compactMap { $0 } + rings.compactMap { $0 },
            capacityExceeded: capacityExceeded, invalidInput: invalidInput, overflowed: overflowed)
    }

    private func scan(_ input: UnsafeBufferPointer<Float>, startFrame: Int64,
                      into record: inout DebugAcceptedPCMOriginRecord) {
        guard startFrame == record.endFrame else { record.coverageFailed = true; return }
        let frames = input.count / 2
        let end = startFrame.addingReportingOverflow(Int64(frames))
        let batches = record.batches.addingReportingOverflow(1)
        guard !end.overflow, !batches.overflow else { overflowed = true; return }
        record.batches = batches.partialValue
        for offset in 0..<frames {
            let left = input[offset * 2], right = input[offset * 2 + 1]
            let finite = left.isFinite && right.isFinite
            let zero = finite && left == 0 && right == 0 // Signed zeros both count.
            if !finite { record.nonFiniteFrames += 1 }
            if zero {
                record.zeroFrames += 1
                record.trailingZeroFrames += 1
                if record.leadingOpen { record.leadingZeroFrames += 1 }
                let runEnd = startFrame + Int64(offset) + 1
                let runStart = runEnd - record.trailingZeroFrames
                record.longestZeroFrames = max(record.longestZeroFrames, record.trailingZeroFrames)
                if record.trailingZeroFrames >= 480 {
                    if record.firstRunStart == -1 { record.firstRunStart = runStart }
                    if record.firstRunStart == runStart { record.firstRunEnd = runEnd }
                    if record.trailingZeroFrames > record.longestRunEnd - record.longestRunStart {
                        record.longestRunStart = runStart; record.longestRunEnd = runEnd
                    }
                }
            } else {
                record.leadingOpen = false; record.trailingZeroFrames = 0
            }
        }
        // All per-frame counts above are bounded by this validated contiguous range.
        record.endFrame = end.partialValue
    }
}
#endif
