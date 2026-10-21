import XCTest
@testable import PlayerCore

/// Actual kernel branches, not a PCM-energy classifier or mocked render result.
final class ContinuousRenderAccountingTests: XCTestCase {
    func testAccountingIsAbsentByDefaultAndDoesNotChangeExactSamples() throws {
        #if DEBUG
        let plain = ContinuousPCMRenderer(channels: 1, prefixFrames: 8, ringFrames: 8)
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        let observed = ContinuousPCMRenderer(channels: 1, prefixFrames: 8, ringFrames: 8,
                                             debugRenderAccounting: recorder)
        XCTAssertNil(plain.debugRenderAccounting)
        for renderer in [plain, observed] {
            prepare(renderer, slot: 0, token: 1, samples: [0, 2, 0, 4])
            renderer.select(token: 1); renderer.setPlaying(true)
        }
        XCTAssertEqual(render(plain, frames: 6), render(observed, frames: 6))
        XCTAssertEqual(plain.snapshot.frame, observed.snapshot.frame)
        XCTAssertEqual(plain.snapshot.underrunFrames, observed.snapshot.underrunFrames)
        XCTAssertEqual(try XCTUnwrap(recorder.snapshot()).copiedPCMFrames, 4)
        #else
        XCTFail("Render accounting contracts require DEBUG")
        #endif
    }

    func testInactiveAndActualPausedPositiveTokenHaveDistinctDispositions() throws {
        #if DEBUG
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 8, ringFrames: 8,
                                             debugRenderAccounting: recorder)
        XCTAssertEqual(render(renderer, frames: 4), [0, 0, 0, 0])
        prepare(renderer, slot: 0, token: 7, samples: [0, 0, 1, 2])
        renderer.select(token: 7)
        XCTAssertEqual(render(renderer, frames: 3), [0, 0, 0])
        XCTAssertEqual(renderer.snapshot.token, 7); XCTAssertEqual(renderer.snapshot.frame, 0)
        renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 2), [0, 0])
        let value = try XCTUnwrap(recorder.snapshot())
        assertConservation(value, requested: 9, completedCalls: 3)
        XCTAssertEqual(value.inactiveFrames, 4)
        XCTAssertEqual(value.pausedPositiveTokenFrames, 3)
        XCTAssertEqual(value.copiedPCMFrames, 2, "Real zero PCM still advances the source cursor")
        XCTAssertEqual(value.eofRemainderFrames, 0); XCTAssertEqual(value.underrunFrames, 0)
        #else
        XCTFail("Render accounting contracts require DEBUG")
        #endif
    }

    func testCopiedZeroPCMIsNotMisclassifiedAsPauseOrUnderrun() throws {
        #if DEBUG
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 8, ringFrames: 8,
                                             debugRenderAccounting: recorder)
        prepare(renderer, slot: 0, token: 1, samples: [0, 0, 0])
        renderer.select(token: 1); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 3), [0, 0, 0])
        let value = try XCTUnwrap(recorder.snapshot())
        assertConservation(value, requested: 3, completedCalls: 1)
        XCTAssertEqual(value.copiedPCMFrames, 3)
        XCTAssertEqual(value.pausedPositiveTokenFrames, 0); XCTAssertEqual(value.inactiveFrames, 0)
        XCTAssertEqual(value.eofRemainderFrames, 0); XCTAssertEqual(value.underrunFrames, 0)
        XCTAssertEqual(renderer.snapshot.frame, 3)
        #else
        XCTFail("Render accounting contracts require DEBUG")
        #endif
    }

    func testUnavailableRingIsExactlyTheExistingUnderrunRemainder() throws {
        #if DEBUG
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 2, ringFrames: 3,
                                             debugRenderAccounting: recorder)
        XCTAssertTrue([Float(1), 2].withUnsafeBufferPointer {
            renderer.source(at: 0).prepare(token: 1, totalFrames: 5, prefix: $0)
        })
        renderer.select(token: 1); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 5), [1, 2, 0, 0, 0])
        let value = try XCTUnwrap(recorder.snapshot())
        assertConservation(value, requested: 5, completedCalls: 1)
        XCTAssertEqual(value.copiedPCMFrames, 2); XCTAssertEqual(value.underrunFrames, 3)
        XCTAssertEqual(value.eofRemainderFrames, 0); XCTAssertEqual(renderer.snapshot.underrunFrames, 3)
        XCTAssertEqual(renderer.snapshot.frame, 2)
        #else
        XCTFail("Render accounting contracts require DEBUG")
        #endif
    }

    func testEndOfQueueRemainderIsNotAnUnderrun() throws {
        #if DEBUG
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 8, ringFrames: 8,
                                             debugRenderAccounting: recorder)
        prepare(renderer, slot: 0, token: 1, samples: [1, 2, 3])
        renderer.select(token: 1); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 7), [1, 2, 3, 0, 0, 0, 0])
        XCTAssertEqual(render(renderer, frames: 2), [0, 0])
        let value = try XCTUnwrap(recorder.snapshot())
        assertConservation(value, requested: 9, completedCalls: 2)
        XCTAssertEqual(value.copiedPCMFrames, 3); XCTAssertEqual(value.eofRemainderFrames, 6)
        XCTAssertEqual(value.underrunFrames, 0); XCTAssertTrue(renderer.snapshot.ended)
        #else
        XCTFail("Render accounting contracts require DEBUG")
        #endif
    }

    func testPreparedBoundaryConservesEveryCopiedFrameAndFinalIdentity() throws {
        #if DEBUG
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 8, ringFrames: 8,
                                             debugRenderAccounting: recorder)
        prepare(renderer, slot: 0, token: 1, samples: [1, 0])
        prepare(renderer, slot: 1, token: 2, samples: [0, 4, 5])
        XCTAssertTrue(renderer.setSuccessor(token: 2, for: 1))
        renderer.select(token: 1); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 7), [1, 0, 0, 4, 5, 0, 0])
        let value = try XCTUnwrap(recorder.snapshot())
        assertConservation(value, requested: 7, completedCalls: 1)
        XCTAssertEqual(value.copiedPCMFrames, 5); XCTAssertEqual(value.eofRemainderFrames, 2)
        XCTAssertEqual(value.lastKernelToken, 2); XCTAssertEqual(value.lastKernelVisit, 2)
        #else
        XCTFail("Render accounting contracts require DEBUG")
        #endif
    }

    func testSourceEntryRemainsReadableUntilSeparateCompletionPublication() throws {
        #if DEBUG
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        recorder.sourceCallbackEntered(frames: 11, hostTimeValid: true, hostTime: 42)
        let entered = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(entered.sourceCallbacksEntered, 1); XCTAssertEqual(entered.sourceCallbacksCompleted, 0)
        XCTAssertEqual(entered.sourceFramesRequested, 11); XCTAssertEqual(entered.sourceFramesCompleted, 0)
        XCTAssertTrue(entered.lastSourceHostTimeValid); XCTAssertEqual(entered.lastSourceHostTime, 42)
        recorder.sourceCallbackCompleted(frames: 11, invalidLayout: true)
        let completed = try XCTUnwrap(recorder.snapshot())
        XCTAssertGreaterThan(completed.sequence, entered.sequence)
        XCTAssertEqual(completed.sourceCallbacksCompleted, 1); XCTAssertEqual(completed.sourceFramesCompleted, 11)
        XCTAssertEqual(completed.invalidLayoutCallbacks, 1); XCTAssertEqual(completed.invalidLayoutFrames, 11)
        XCTAssertEqual(completed.kernelCallsEntered, 0)
        let saturated = ContinuousPCMRenderer.DebugRenderAccountingRecorder.saturatingAdd(.max - 1, 3)
        XCTAssertEqual(saturated.value, .max); XCTAssertTrue(saturated.overflowed)
        #else
        XCTFail("Render accounting contracts require DEBUG")
        #endif
    }

    #if DEBUG
    private func assertConservation(_ value: ContinuousPCMRenderer.DebugRenderAccountingSnapshot,
                                    requested: UInt64, completedCalls: UInt64) {
        XCTAssertFalse(value.overflowed)
        XCTAssertEqual(value.kernelCallsEntered, completedCalls)
        XCTAssertEqual(value.kernelCallsCompleted, completedCalls)
        XCTAssertEqual(value.kernelFramesRequested, requested)
        XCTAssertEqual(value.kernelFramesClassified, requested)
        XCTAssertEqual(value.copiedPCMFrames + value.pausedPositiveTokenFrames + value.inactiveFrames
            + value.eofRemainderFrames + value.underrunFrames, requested)
    }
    #endif

    private func prepare(_ renderer: ContinuousPCMRenderer, slot: Int, token: Int, samples: [Float]) {
        XCTAssertTrue(samples.withUnsafeBufferPointer {
            renderer.source(at: slot).prepare(token: token, totalFrames: Int64(samples.count), prefix: $0)
        })
    }
    private func render(_ renderer: ContinuousPCMRenderer, frames: Int) -> [Float] {
        var output = [Float](repeating: -99, count: frames)
        output.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: frames) }
        return output
    }
}
