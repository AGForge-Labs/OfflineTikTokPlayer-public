import XCTest
@testable import PlayerCore

#if DEBUG
final class ContinuousPCMSourceOutputTests: XCTestCase {
    private func write(_ recorder: ContinuousPCMRenderer.DebugRenderAccountingRecorder,
                       frames: Int, host: UInt64, value: (Int) -> (Float, Float)) {
        recorder.sourceCallbackEntered(frames: frames, hostTimeValid: true, hostTime: host)
        for frame in 0..<frames {
            let pair = value(frame)
            recorder.sourceOutputPair(left: pair.0, right: pair.1)
        }
        recorder.sourceCallbackCompleted(frames: frames, invalidLayout: false)
    }

    func testSourceOutputCompletedSpanCountsExactZerosAcrossCallbacks() throws {
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder(captureSourceOutput: true)
        write(recorder, frames: 2, host: 1) { _ in (0.25, 0.25) }
        let before = try XCTUnwrap(recorder.snapshot())
        for packet in 0..<2 {
            recorder.sourceCallbackEntered(frames: 480, hostTimeValid: true, hostTime: UInt64(packet + 2))
            for frame in 0..<480 {
                let v: Float = (200..<844).contains(packet * 480 + frame) ? 0 : 0.25
                recorder.sourceOutputPair(left: v, right: v)
            }
            // Pair observations do not publish a partly copied callback.
            let pending = try XCTUnwrap(recorder.snapshot())
            XCTAssertEqual(pending.sourceOutput.callbacks, UInt64(packet + 1))
            XCTAssertEqual(pending.sourceOutput.frames, UInt64(2 + packet * 480))
            recorder.sourceCallbackCompleted(frames: 480, invalidLayout: false)
        }
        let after = try XCTUnwrap(recorder.snapshot())
        let span = try XCTUnwrap(after.sourceOutputSpan(since: before))
        XCTAssertEqual(span.callbacks, 2); XCTAssertEqual(span.frames, 960)
        XCTAssertEqual(span.stereoZeroFrames, 644); XCTAssertEqual(span.nonfiniteFrames, 0)
        XCTAssertEqual(after.sourceOutput.longestZeroRun, 644)
        XCTAssertEqual(after.sourceOutput.trailingZeroRun, 0)
        XCTAssertEqual(after.sourceOutput.lastHostTime, 3)
        XCTAssertEqual(after.sourceOutput.lastFrameCount, 480)

        // A previous cumulative maximum cannot conceal the next span's content.
        let secondBefore = after
        write(recorder, frames: 4, host: 4) { frame in
            frame == 0 ? (0, 0) : (0.25, -0.25)
        }
        let secondAfter = try XCTUnwrap(recorder.snapshot())
        let second = try XCTUnwrap(secondAfter.sourceOutputSpan(since: secondBefore))
        XCTAssertEqual(second.stereoZeroFrames, 1)
        XCTAssertEqual(secondAfter.sourceOutput.longestZeroRun, 644)
    }

    func testSourceOutputSpanRefusesMissingCoverageAndPreservesNonfiniteEvidence() throws {
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder(captureSourceOutput: true)
        write(recorder, frames: 2, host: 1) { _ in (0.25, 0.25) }
        let before = try XCTUnwrap(recorder.snapshot())
        write(recorder, frames: 2, host: 2) { frame in
            frame == 0 ? (Float.nan, 0.25) : (0.25, 0.25)
        }
        let nonfinite = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(try XCTUnwrap(nonfinite.sourceOutputSpan(since: before)).nonfiniteFrames, 1)

        recorder.sourceCallbackEntered(frames: 2, hostTimeValid: true, hostTime: 3)
        recorder.sourceOutputPair(left: 0.25, right: 0.25)
        XCTAssertNil(try XCTUnwrap(recorder.snapshot()).sourceOutputSpan(since: before))
        recorder.sourceCallbackCompleted(frames: 2, invalidLayout: false)
        XCTAssertNil(try XCTUnwrap(recorder.snapshot()).sourceOutputSpan(since: nonfinite),
                     "An unobserved output pair cannot become zero-free coverage")

        let missingHost = ContinuousPCMRenderer.DebugRenderAccountingRecorder(captureSourceOutput: true)
        write(missingHost, frames: 1, host: 1) { _ in (0.25, 0.25) }
        let hostBefore = try XCTUnwrap(missingHost.snapshot())
        missingHost.sourceCallbackEntered(frames: 1, hostTimeValid: false, hostTime: 2)
        missingHost.sourceOutputPair(left: 0.25, right: 0.25)
        missingHost.sourceCallbackCompleted(frames: 1, invalidLayout: false)
        XCTAssertNil(try XCTUnwrap(missingHost.snapshot()).sourceOutputSpan(since: hostBefore))

        let off = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        write(off, frames: 1, host: 1) { _ in (0, 0) }
        let offBefore = try XCTUnwrap(off.snapshot())
        write(off, frames: 1, host: 2) { _ in (0, 0) }
        let offAfter = try XCTUnwrap(off.snapshot())
        XCTAssertFalse(offAfter.sourceOutput.enabled); XCTAssertEqual(offAfter.sourceOutput.frames, 0)
        XCTAssertNil(offAfter.sourceOutputSpan(since: offBefore))

        let exhausted = ContinuousPCMRenderer.DebugRenderAccountingRecorder(captureSourceOutput: true,
            testHooks: .init(initialSequence: UInt64.max - 1))
        exhausted.sourceCallbackEntered(frames: 1, hostTimeValid: true, hostTime: 1)
        XCTAssertNil(exhausted.snapshot())
    }
}
#endif
