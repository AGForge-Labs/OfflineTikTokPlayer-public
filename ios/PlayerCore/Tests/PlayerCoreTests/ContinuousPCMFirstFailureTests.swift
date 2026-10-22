import XCTest
@testable import PlayerCore

#if DEBUG
final class ContinuousPCMFirstFailureTests: XCTestCase {
    func testVisitThreeRecordsUncommittedEpochAndKeepsTheFirstFailure() throws {
        let recorder = ContinuousPCMRenderer.DebugFirstFailureRecorder()
        let renderer = makeRenderer(recorder)
        let source = renderer.source(at: 0)
        prepare(source, samples: [1, 2], total: 8)
        renderer.setPlaying(true)

        renderer.select(token: 71)
        XCTAssertEqual(render(renderer, 3), [1, 2, 0])
        XCTAssertEqual(recorder.snapshot().publication, .notCaptured)
        XCTAssertTrue(recorder.snapshot().earlierVisitFailureObserved)
        XCTAssertNil(recorder.snapshot().event)

        renderer.select(token: 71)
        XCTAssertEqual(render(renderer, 2), [1, 2])
        renderer.select(token: 71)
        XCTAssertEqual(render(renderer, 3), [1, 2, 0])
        let captured = recorder.snapshot()
        XCTAssertEqual(captured.targetVisit, 3)
        XCTAssertEqual(captured.publication, .captured)
        let first = try XCTUnwrap(captured.event)
        XCTAssertEqual(first.reason, .epochMismatch)
        XCTAssertEqual(first.token, 71)
        XCTAssertEqual(first.visit, 3)
        XCTAssertEqual(first.cursor, 2)
        XCTAssertEqual(first.prefixFrames, 2)
        XCTAssertEqual(first.expectedEpoch, source.streamRequest.epoch)
        XCTAssertEqual(first.observedEpoch, 0)
        XCTAssertNil(first.observedReadPosition)
        XCTAssertNil(first.observedWritePosition)
        XCTAssertNil(first.observedReadyToken)
        XCTAssertEqual(renderer.snapshot.frame, 2)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 2)

        let epoch = source.streamRequest.epoch
        XCTAssertTrue(source.beginStream(epoch: epoch))
        XCTAssertEqual([Float(3), 4, 5].withUnsafeBufferPointer { source.append(interleaved: $0, epoch: epoch) }, 3)
        XCTAssertEqual(render(renderer, 4), [3, 4, 5, 0])
        XCTAssertEqual(renderer.snapshot.frame, 5)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 3)
        XCTAssertEqual(recorder.snapshot().event, first, "A later empty-ring failure cannot replace the first epoch failure")
    }

    func testCommittedEmptyVisitThreeRecordsTheActualUnpublishedFrameOperands() throws {
        let recorder = ContinuousPCMRenderer.DebugFirstFailureRecorder()
        let renderer = makeRenderer(recorder)
        let source = renderer.source(at: 0)
        prepare(source, samples: [1, 2], total: 8)
        advanceThroughThreePrefixes(renderer)
        let epoch = source.streamRequest.epoch
        XCTAssertTrue(source.beginStream(epoch: epoch))
        XCTAssertEqual(source.availableStreamFrames(for: epoch), 0)

        XCTAssertEqual(render(renderer, 1), [0])
        let snapshot = recorder.snapshot()
        let event = try XCTUnwrap(snapshot.event)
        XCTAssertEqual(snapshot.publication, .captured)
        XCTAssertFalse(snapshot.earlierVisitFailureObserved)
        XCTAssertEqual(event.reason, .unpublishedFrame)
        XCTAssertEqual(event.token, 71)
        XCTAssertEqual(event.visit, 3)
        XCTAssertEqual(event.cursor, 2)
        XCTAssertEqual(event.expectedEpoch, epoch)
        XCTAssertEqual(event.observedEpoch, epoch)
        XCTAssertEqual(event.observedReadPosition, 2)
        XCTAssertEqual(event.observedWritePosition, 2)
        XCTAssertEqual(renderer.snapshot.frame, 2)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 1)
        XCTAssertFalse(renderer.snapshot.ended)
    }

    func testSameEpochResetRecordsPositionMismatchWithoutReadingLaterOperands() throws {
        let recorder = ContinuousPCMRenderer.DebugFirstFailureRecorder()
        let renderer = makeRenderer(recorder)
        let source = renderer.source(at: 0)
        prepare(source, samples: [1, 2], total: 8)
        advanceThroughThreePrefixes(renderer)
        let epoch = source.streamRequest.epoch
        XCTAssertTrue(source.beginStream(epoch: epoch))
        XCTAssertEqual([Float(3), 4, 5].withUnsafeBufferPointer { source.append(interleaved: $0, epoch: epoch) }, 3)
        XCTAssertEqual(render(renderer, 1), [3])
        XCTAssertEqual(renderer.snapshot.frame, 3)
        // The existing API permits this duplicate reset. Its ordinary failure
        // remains a zero frame plus underrun, rather than a diagnostic repair.
        XCTAssertTrue(source.beginStream(epoch: epoch))
        XCTAssertEqual(render(renderer, 1), [0])
        let event = try XCTUnwrap(recorder.snapshot().event)
        XCTAssertEqual(event.reason, .positionMismatch)
        XCTAssertEqual(event.cursor, 3)
        XCTAssertEqual(event.expectedEpoch, epoch)
        XCTAssertEqual(event.observedEpoch, epoch)
        XCTAssertEqual(event.observedReadPosition, 2)
        XCTAssertNil(event.observedWritePosition, "The original guard short-circuits before the write-position load")
        XCTAssertEqual(renderer.snapshot.frame, 3)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 1)
    }

    func testDefaultOffAndOnPreserveSourceZerosPauseAndEOFSamples() {
        let recorder = ContinuousPCMRenderer.DebugFirstFailureRecorder()
        let off = makeRenderer(nil)
        let on = makeRenderer(recorder)
        XCTAssertNil(off.debugFirstFailure)
        for renderer in [off, on] {
            let source = renderer.source(at: 0)
            prepare(source, samples: [1, 0], total: 5)
            advanceThroughThreePrefixes(renderer, expected: [1, 0])
            let epoch = source.streamRequest.epoch
            XCTAssertTrue(source.beginStream(epoch: epoch))
            XCTAssertEqual([Float(3), 0, 5].withUnsafeBufferPointer { source.append(interleaved: $0, epoch: epoch) }, 3)
            XCTAssertEqual(render(renderer, 4), [3, 0, 5, 0])
            XCTAssertTrue(renderer.snapshot.ended)
            renderer.setPlaying(false)
            XCTAssertEqual(render(renderer, 2), [0, 0])
            XCTAssertEqual(renderer.snapshot.frame, 5)
            XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
            XCTAssertEqual(renderer.retainedPCMMemoryBytes, 3 * (2 + 3) * MemoryLayout<Float>.stride)
        }
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.publication, .notCaptured)
        XCTAssertNil(snapshot.event)
        XCTAssertFalse(snapshot.earlierVisitFailureObserved)
        XCTAssertFalse(snapshot.laterVisitFailureObserved)
        XCTAssertEqual(off.snapshot.frame, on.snapshot.frame)
        XCTAssertEqual(off.snapshot.visit, on.snapshot.visit)
        XCTAssertEqual(off.snapshot.selectionVersion, on.snapshot.selectionVersion)
    }

    private func makeRenderer(_ recorder: ContinuousPCMRenderer.DebugFirstFailureRecorder?) -> ContinuousPCMRenderer {
        ContinuousPCMRenderer(channels: 1, prefixFrames: 2, ringFrames: 3, debugFirstFailure: recorder)
    }
    private func prepare(_ source: ContinuousPCMSource, samples: [Float], total: Int64) {
        XCTAssertTrue(samples.withUnsafeBufferPointer { source.prepare(token: 71, totalFrames: total, prefix: $0) })
    }
    private func advanceThroughThreePrefixes(_ renderer: ContinuousPCMRenderer, expected: [Float] = [1, 2]) {
        renderer.setPlaying(true)
        for visit in 1...3 {
            renderer.select(token: 71)
            XCTAssertEqual(render(renderer, 2), expected)
            XCTAssertEqual(renderer.snapshot.visit, Int64(visit))
        }
    }
    private func render(_ renderer: ContinuousPCMRenderer, _ frames: Int) -> [Float] {
        var output = [Float](repeating: -999, count: frames)
        output.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: frames) }
        return output
    }
}
#endif
