import XCTest
@testable import PlayerCore

final class AcceptedPCMOriginReceiptTests: XCTestCase {
    func testReceiptUsesActualCopiedEpochAndPreservesLastCompletionAcrossSourceEntry() throws {
        #if DEBUG
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder(capturePCMOrigin: true)
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 2, ringFrames: 4,
                                             debugRenderAccounting: recorder)
        let source = renderer.source(at: 0)
        XCTAssertTrue([Float(0), 0].withUnsafeBufferPointer {
            source.prepare(token: 7, totalFrames: 6, prefix: $0)
        })
        let request = source.streamRequest
        XCTAssertTrue(source.beginStream(epoch: request.epoch))
        XCTAssertEqual([Float(3), 4, 5, 6].withUnsafeBufferPointer {
            source.append(interleaved: $0, epoch: request.epoch)
        }, 4)
        renderer.select(token: 7); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, 4), [0, 0, 3, 4])
        let first = try XCTUnwrap(try XCTUnwrap(recorder.snapshot()).pcmOrigin)
        XCTAssertTrue(first.valid); XCTAssertEqual(first.token, 7)
        XCTAssertEqual(first.visit, renderer.snapshot.visit)
        XCTAssertEqual(first.epoch, request.epoch)
        XCTAssertEqual(first.firstFrame, 0); XCTAssertEqual(first.endFrame, 4)
        XCTAssertEqual(first.completion, 1)
        recorder.sourceCallbackEntered(frames: 2, hostTimeValid: true, hostTime: 123)
        let entered = try XCTUnwrap(try XCTUnwrap(recorder.snapshot()).pcmOrigin)
        XCTAssertEqual(entered, first, "A source-entry publication retains the last completed receipt, not a new kernel completion")
        renderer.select(token: 7, frame: 1)
        XCTAssertEqual(render(renderer, 1), [0])
        let sought = try XCTUnwrap(try XCTUnwrap(recorder.snapshot()).pcmOrigin)
        XCTAssertTrue(sought.valid); XCTAssertGreaterThan(sought.epoch, first.epoch)
        XCTAssertGreaterThan(sought.visit, first.visit)
        XCTAssertEqual(sought.firstFrame, 1); XCTAssertEqual(sought.endFrame, 2)
        #else
        XCTFail("PCM origin receipt contracts require DEBUG")
        #endif
    }

    func testReceiptRejectsInactivePausedUnderrunEOFAndMixedSourceCallbacks() throws {
        #if DEBUG
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder(capturePCMOrigin: true)
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 2, ringFrames: 2,
                                             debugRenderAccounting: recorder)
        _ = render(renderer, 1)
        XCTAssertFalse(try XCTUnwrap(try XCTUnwrap(recorder.snapshot()).pcmOrigin).valid)
        XCTAssertTrue([Float(1), 2].withUnsafeBufferPointer {
            renderer.source(at: 0).prepare(token: 1, totalFrames: 4, prefix: $0)
        })
        renderer.select(token: 1)
        _ = render(renderer, 1)
        XCTAssertFalse(try XCTUnwrap(try XCTUnwrap(recorder.snapshot()).pcmOrigin).valid)
        renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, 4), [1, 2, 0, 0])
        XCTAssertFalse(try XCTUnwrap(try XCTUnwrap(recorder.snapshot()).pcmOrigin).valid)

        let boundaryRecorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder(capturePCMOrigin: true)
        let boundary = ContinuousPCMRenderer(channels: 1, prefixFrames: 2, ringFrames: 2,
                                            debugRenderAccounting: boundaryRecorder)
        for (slot, token) in [(0, 3), (1, 4)] {
            XCTAssertTrue([Float(token), Float(token)].withUnsafeBufferPointer {
                boundary.source(at: slot).prepare(token: token, totalFrames: 2, prefix: $0)
            })
        }
        XCTAssertTrue(boundary.setSuccessor(token: 4, for: 3))
        boundary.select(token: 3); boundary.setPlaying(true)
        XCTAssertEqual(render(boundary, 3), [3, 3, 4])
        XCTAssertFalse(try XCTUnwrap(try XCTUnwrap(boundaryRecorder.snapshot()).pcmOrigin).valid)
        XCTAssertEqual(render(boundary, 3), [4, 0, 0])
        XCTAssertFalse(try XCTUnwrap(try XCTUnwrap(boundaryRecorder.snapshot()).pcmOrigin).valid)
        let plain = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        XCTAssertNil(try XCTUnwrap(plain.snapshot()).pcmOrigin)
        #else
        XCTFail("PCM origin receipt contracts require DEBUG")
        #endif
    }

    private func render(_ renderer: ContinuousPCMRenderer, _ count: Int) -> [Float] {
        var output = [Float](repeating: -1, count: count)
        output.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: count) }
        return output
    }
}
