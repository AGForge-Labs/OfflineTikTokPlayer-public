import Foundation
import Synchronization
import XCTest
@testable import OfflineTikTokPlayer

#if DEBUG
/// Equal per-copy context publication in OFF/ON. Queries happen on the existing
/// non-RT sampler, only after an actual zero event or >=300ms unchanged copy word.
/// At most two batches of three lanes. No new sampler, retry, AVFoundation query,
/// media retain, native cancellation or synthesized cleanup acknowledgement.
final class NativeReaderWaitObservation: @unchecked Sendable {
    let enabled: Bool
    private let native = OPNativeReaderWaitProbe()
    private let lock = NSLock()
    private var closing = false, sampling = false, zeroIssued = false, waitIssued = false
    private var words = [UInt64](repeating: 0, count: 3)
    private var starts = [UInt64](repeating: 0, count: 3)
    private var rows: [[String: Any]] = []
    init(enabled: Bool) { self.enabled = enabled; rows.reserveCapacity(6) }
    func note(lane: Int, sequence: UInt64) { native.noteOwnThread(forLane: lane, copySequence: sequence) }
    func observe(recorder: ContinuousPCMDecoder.DebugNativeLaneActivityRecorder,
                 zero: Bool, phase: Int) {
        guard phase == 2 else { return }
        let begin = DispatchTime.now().uptimeNanoseconds
        let before = (0..<3).map { recorder.snapshot(at: $0) }
        lock.lock()
        guard !closing, !sampling else { lock.unlock(); return }
        var held = false
        for lane in 0..<3 {
            guard let value = before[lane], !value.sequenceOverflowed,
                  value.stageCode == ContinuousPCMDecoder.DebugNativeLaneActivityStage.copyEntered.rawValue else {
                words[lane] = 0; starts[lane] = 0; continue
            }
            if words[lane] != value.packedState { words[lane] = value.packedState; starts[lane] = begin }
            if starts[lane] > 0 && begin >= starts[lane] && begin - starts[lane] >= 300_000_000 { held = true }
        }
        let reason: String
        if zero && !zeroIssued { zeroIssued = true; reason = "actual-stereo-zero" }
        else if held && !waitIssued { waitIssued = true; reason = "unchanged-copy-300ms" }
        else { lock.unlock(); return }
        sampling = true; lock.unlock()
        var captured: [[String: Any]] = []
        for lane in 0..<3 {
            let value = before[lane]
            let admitted = value?.stageCode == ContinuousPCMDecoder.DebugNativeLaneActivityStage.copyEntered.rawValue
                && value?.sequenceOverflowed == false
            let queryEntry = DispatchTime.now().uptimeNanoseconds
            var row: [String: Any] = enabled && admitted
                ? native.sampleLane(lane, copySequence: value!.copySequence)
                : ["available": false, "reason": admitted ? "query-control-off" : "no-copy-entered-boundary"]
            let queryReturn = DispatchTime.now().uptimeNanoseconds
            let after = recorder.snapshot(at: lane)
            row["schema"] = 1; row["enabled"] = enabled; row["lane"] = lane
            row["trigger"] = reason; row["phase"] = phase
            row["observationBeginNs"] = begin; row["queryEntryNs"] = queryEntry; row["queryReturnNs"] = queryReturn
            row["beforeWord"] = value?.packedState ?? 0; row["afterWord"] = after?.packedState ?? 0
            row["copySequence"] = value?.copySequence ?? 0
            row["boundaryQualified"] = admitted && value?.packedState == after?.packedState
                && after?.sequenceOverflowed == false
            row["stackCoherent"] = false; row["sourceTapFrameJoin"] = false
            captured.append(row)
        }
        lock.lock(); rows.append(contentsOf: captured); sampling = false; lock.unlock()
    }
    func close() { lock.lock(); closing = true; lock.unlock() }
    var requestsClosed: Bool { lock.lock(); defer { lock.unlock() }; return closing && !sampling }
    func dump(cleanupAcknowledged: Bool) {
        lock.lock(); let captured = rows, closed = closing && !sampling; lock.unlock()
        XCTAssertTrue(closed); XCTAssertLessThanOrEqual(captured.count, 6)
        print("NativeReaderWaitSummary schema=1 enabled=\(enabled) rows=\(captured.count) maximumRows=6 framesPerRow=16 sampler=existing-only copyContext=both-arms cleanupAcknowledged=\(cleanupAcknowledged) requestsClosed=\(closed) nativePolicy=unchanged stackCoherent=false noEvent=inconclusive")
        for row in captured {
            do {
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                XCTAssertLessThanOrEqual(data.count, 16_384)
                print("NativeReaderWaitRow " + String(decoding: data, as: UTF8.self))
            } catch { XCTFail("Bounded own-thread result could not be serialized") }
        }
        // Unacknowledged native owners retain the recorder/probe closure. Do not
        // contend with a note writer or release its rights after the 3s deadline.
        if closed && cleanupAcknowledged { native.close() }
    }
    func calibrationSample(lane: Int, sequence: UInt64) -> [String: Any] {
        native.sampleLane(lane, copySequence: sequence)
    }
}
#endif
