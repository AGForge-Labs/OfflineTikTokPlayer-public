import XCTest
import AVFoundation
import Synchronization
import PlayerCore
@testable import OfflineTikTokPlayer

final class AcceptedPCMOriginTests: XCTestCase {
    func testAcceptedPCMOriginCoverageAndExactZeroCalibration() async throws {
        #if DEBUG
        try calibrateRangesAndFailures()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("accepted-origin.caf")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_049))
        buffer.frameLength = 2_049
        let pointer = try XCTUnwrap(buffer.floatChannelData?[0])
        var expected = [Float](repeating: 0.25, count: 2_049 * 2)
        for frame in 400..<1_000 { expected[frame * 2] = 0; expected[frame * 2 + 1] = -0.0 }
        expected.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: $0.count) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: true)
            try file.write(from: buffer)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
        let origin = DebugAcceptedPCMOriginRecorder()
        let accounting = ContinuousPCMRenderer.DebugRenderAccountingRecorder(capturePCMOrigin: true)
        let renderer = ContinuousPCMRenderer(prefixFrames: 512, ringFrames: 1_024,
                                             debugRenderAccounting: accounting)
        let decoder = ContinuousPCMDecoder(renderer: renderer, debugAcceptedPCMOrigin: origin)
        let prepared = Mutex<Result<ContinuousPCMDecoder.Prepared, ContinuousPCMDecoder.Failure>?>(nil)
        let preparationSettled = Mutex(false)
        let task = Task {
            defer { preparationSettled.withLock { $0 = true } }
            do { let value = try await decoder.prepare(url: url, token: 1, slot: 0)
                prepared.withLock { $0 = .success(value) }
            } catch { prepared.withLock { $0 = .failure((error as? ContinuousPCMDecoder.Failure) ?? .cannotDecode) } }
        }
        defer {
            task.cancel(); renderer.setPlaying(false); decoder.shutdown()
            decoder.debugAfterShutdown { closed in
                // Metadata awaits precede lease registration. An empty-worker ACK
                // alone does not authorize deleting a still-loading source file.
                if closed, preparationSettled.withLock({ $0 }) {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        }
        try await wait(timeout: 3) {
            prepared.withLock { $0 != nil } && preparationSettled.withLock { $0 }
        }
        _ = try XCTUnwrap(prepared.withLock { $0 }).get()
        let request = renderer.source(at: 0).streamRequest
        renderer.select(token: 1); renderer.setPlaying(true)
        var actual = [Float](repeating: -1, count: 1_536 * 2)
        actual.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 1_536) }
        XCTAssertEqual(actual, Array(expected.prefix(actual.count)))
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        let receipt = try XCTUnwrap(try XCTUnwrap(accounting.snapshot()).pcmOrigin)
        XCTAssertTrue(receipt.valid); XCTAssertEqual(receipt.epoch, request.epoch)
        XCTAssertEqual(receipt.firstFrame, 0); XCTAssertEqual(receipt.endFrame, 1_536)
        renderer.setPlaying(false); decoder.shutdown()
        let closed = Mutex<Bool?>(nil)
        decoder.debugAfterShutdown { value in closed.withLock { $0 = value } }
        try await wait(timeout: 3) { closed.withLock { $0 != nil } }
        XCTAssertEqual(closed.withLock { $0 }, true)
        XCTAssertTrue(preparationSettled.withLock { $0 })
        let reply = Mutex<DebugAcceptedPCMOriginSnapshot?>(nil)
        decoder.debugAcceptedPCMOriginSnapshot { value in reply.withLock { $0 = value } }
        try await wait(timeout: 1) { reply.withLock { $0 != nil } }
        let snapshot = try XCTUnwrap(reply.withLock { $0 })
        let joined = snapshot.coverage(token: 1, epoch: receipt.epoch, through: receipt.endFrame)
        XCTAssertTrue(joined.complete); XCTAssertTrue(joined.hasQualifyingZero)
        XCTAssertEqual(joined.longestZeroFrames, 600)
        XCTAssertEqual(joined.boundaryRunStart, 400); XCTAssertEqual(joined.boundaryRunEnd, 1_000)
        XCTAssertFalse(snapshot.failed)
        XCTAssertEqual(snapshot.records.filter { $0.kind == 1 }.count, 1)
        print("AcceptedPCMOriginCalibration schema=1 actualPreparedPrefix=true actualAcceptedRing=true exactRenderedFrames=1536 expectedRunStart=400 expectedRunEnd=1000 joinedLongest=\(joined.longestZeroFrames) complete=\(joined.complete) preparationSettled=\(preparationSettled.withLock { $0 }) nativeClose=\(closed.withLock { $0 } == true) independentDomains=true")
        #else
        XCTFail("Accepted PCM origin calibration requires DEBUG")
        #endif
    }

    #if DEBUG
    private func calibrateRangesAndFailures() throws {
        let empty = DebugAcceptedPCMOriginRecorder().snapshotOnWorker()
        XCTAssertTrue(empty.records.isEmpty)
        XCTAssertFalse(empty.coverage(token: 1, epoch: 2, through: 1).complete)
        let recorder = DebugAcceptedPCMOriginRecorder()
        let prefix = [Float](repeating: 0, count: 300 * 2)
        prefix.withUnsafeBufferPointer { recorder.recordPrefix(token: 1, slot: 0, interleaved: $0) }
        for start in [300, 500] {
            [Float](repeating: 0, count: 200 * 2).withUnsafeBufferPointer {
                recorder.recordRing(token: 1, slot: 0, epoch: 2, startFrame: Int64(start), interleaved: $0)
            }
        }
        var joined = recorder.snapshotOnWorker().coverage(token: 1, epoch: 2, through: 700)
        XCTAssertTrue(joined.complete); XCTAssertEqual(joined.longestZeroFrames, 700)
        XCTAssertTrue(joined.hasQualifyingZero)
        XCTAssertEqual(joined.boundaryRunStart, 0); XCTAssertEqual(joined.boundaryRunEnd, 700)
        // A later epoch cannot borrow the previous epoch's accepted coverage.
        [Float](repeating: 1, count: 100 * 2).withUnsafeBufferPointer {
            recorder.recordRing(token: 1, slot: 0, epoch: 4, startFrame: 300, interleaved: $0)
        }
        joined = recorder.snapshotOnWorker().coverage(token: 1, epoch: 4, through: 700)
        XCTAssertFalse(joined.complete)
        let bad = DebugAcceptedPCMOriginRecorder()
        [Float(1), 1].withUnsafeBufferPointer { bad.recordPrefix(token: 2, slot: 1, interleaved: $0) }
        [Float.nan, 0].withUnsafeBufferPointer {
            bad.recordRing(token: 2, slot: 1, epoch: 2, startFrame: 1, interleaved: $0)
        }
        [Float(0), 0].withUnsafeBufferPointer {
            bad.recordRing(token: 2, slot: 1, epoch: 2, startFrame: 3, interleaved: $0)
        }
        XCTAssertTrue(bad.snapshotOnWorker().failed)
        XCTAssertFalse(bad.snapshotOnWorker().coverage(token: 2, epoch: 2, through: 4).complete)
        let exhausted = DebugAcceptedPCMOriginRecorder()
        for epoch in stride(from: 2, through: 26, by: 2) {
            [Float(1), 1].withUnsafeBufferPointer {
                exhausted.recordRing(token: 3, slot: 2, epoch: epoch, startFrame: 1, interleaved: $0)
            }
        }
        XCTAssertTrue(exhausted.snapshotOnWorker().capacityExceeded)
        XCTAssertEqual(exhausted.snapshotOnWorker().records.count, 12)
        let prefixExhausted = DebugAcceptedPCMOriginRecorder()
        for token in 1...4 {
            [Float(1), 1].withUnsafeBufferPointer {
                prefixExhausted.recordPrefix(token: token, slot: token % 3, interleaved: $0)
            }
        }
        XCTAssertTrue(prefixExhausted.snapshotOnWorker().capacityExceeded)
        XCTAssertEqual(prefixExhausted.snapshotOnWorker().records.count, 3)
        let overflow = DebugAcceptedPCMOriginRecorder()
        [Float(0), 0].withUnsafeBufferPointer {
            overflow.recordRing(token: 4, slot: 0, epoch: 2, startFrame: Int64.max, interleaved: $0)
        }
        XCTAssertTrue(overflow.snapshotOnWorker().overflowed)
        let malformed = DebugAcceptedPCMOriginRecorder()
        [Float(0)].withUnsafeBufferPointer { malformed.recordPrefix(token: 5, slot: 0, interleaved: $0) }
        XCTAssertTrue(malformed.snapshotOnWorker().invalidInput)
    }

    private func wait(timeout: Double, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if condition() { return }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("Bounded accepted-origin preparation/snapshot/close must complete")
        throw ContinuousPCMDecoder.Failure.cannotDecode
    }
    #endif
}
