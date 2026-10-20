import XCTest
@testable import PlayerCore

final class ContinuousPCMTests: XCTestCase {
    // A boundary that waits for a callback, trims the tail or inserts a zero fails this test.
    func testBoundaryCopiesTailAndHeadInTheSameRenderRequest() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 8, ringFrames: 8)
        prepare(renderer, slot: 0, token: 1, samples: [11, 12, 0, 0])
        prepare(renderer, slot: 1, token: 2, samples: [0, 21, 22])
        renderer.setSuccessor(token: 2, for: 1)
        renderer.select(token: 1)
        renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 9), [11, 12, 0, 0, 0, 21, 22, 0, 0])
        XCTAssertEqual(renderer.snapshot.frame, 3)
        XCTAssertTrue(renderer.snapshot.ended)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testThousandsOfLoopsKeepAllSourceFramesIncludingRealSilence() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 8, ringFrames: 8)
        prepare(renderer, slot: 0, token: 1, samples: [0, 1, 2, 3, 0])
        renderer.setSuccessor(token: 1, for: 1)
        renderer.select(token: 1); renderer.setPlaying(true)
        var output = [Float]()
        for block in [1, 7, 256, 4096, 5640] { output += render(renderer, frames: block) }
        XCTAssertEqual(output, Array(repeating: [Float(0), 1, 2, 3, 0], count: 2000).flatMap { $0 })
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testPreparedReversalHasNoInsertedFrameAndPauseDoesNotConsumePosition() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 8, ringFrames: 8)
        prepare(renderer, slot: 0, token: 10, samples: [1, 2, 3])
        prepare(renderer, slot: 1, token: 20, samples: [4, 5, 6])
        renderer.select(token: 10); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 2), [1, 2])
        renderer.setPlaying(false)
        XCTAssertEqual(render(renderer, frames: 4), [0, 0, 0, 0])
        XCTAssertEqual(renderer.snapshot.frame, 2)
        renderer.select(token: 20); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 2), [4, 5])
        renderer.select(token: 10)
        XCTAssertEqual(render(renderer, frames: 3), [1, 2, 3])
        for _ in 0..<1000 {
            renderer.select(token: 20); XCTAssertEqual(render(renderer, frames: 1), [4])
            renderer.select(token: 10); XCTAssertEqual(render(renderer, frames: 1), [1])
        }
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testStreamingRingWrapAndSeekDiscardStaleDecodeEpoch() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 2, ringFrames: 3)
        let source = renderer.source(at: 0)
        XCTAssertTrue([Float(1), 2].withUnsafeBufferPointer { source.prepare(token: 1, totalFrames: 8, prefix: $0) })
        let initial = source.streamRequest
        XCTAssertTrue(source.beginStream(epoch: initial.epoch))
        XCTAssertEqual([Float(3), 4, 5].withUnsafeBufferPointer { source.append(interleaved: $0, epoch: initial.epoch) }, 3)
        renderer.select(token: 1); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 4), [1, 2, 3, 4])
        XCTAssertEqual([Float(6), 7].withUnsafeBufferPointer { source.append(interleaved: $0, epoch: initial.epoch) }, 2)
        XCTAssertEqual(render(renderer, frames: 3), [5, 6, 7])
        renderer.select(token: 1, frame: 1)
        XCTAssertEqual(render(renderer, frames: 1), [2])
        let restarted = source.streamRequest
        XCTAssertNotEqual(restarted.epoch, initial.epoch)
        XCTAssertEqual(restarted.startFrame, 2)
        XCTAssertEqual([Float(99)].withUnsafeBufferPointer { source.append(interleaved: $0, epoch: initial.epoch) }, 0)
        XCTAssertTrue(source.beginStream(epoch: restarted.epoch))
        XCTAssertEqual([Float(3), 4, 5].withUnsafeBufferPointer { source.append(interleaved: $0, epoch: restarted.epoch) }, 3)
        XCTAssertEqual(render(renderer, frames: 3), [3, 4, 5])
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testStreamReadinessRejectsOldAndUncommittedEpochsAfterRestart() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 2, ringFrames: 3)
        let source = renderer.source(at: 0)
        XCTAssertTrue([Float(1), 2].withUnsafeBufferPointer { source.prepare(token: 1, totalFrames: 5, prefix: $0) })
        let initial = source.streamRequest
        XCTAssertEqual(source.availableStreamFrames(for: initial.epoch), 0)
        XCTAssertTrue(source.beginStream(epoch: initial.epoch))
        XCTAssertEqual([Float(3), 4, 5].withUnsafeBufferPointer { source.append(interleaved: $0, epoch: initial.epoch) }, 3)
        XCTAssertEqual(source.availableStreamFrames(for: initial.epoch), 3)
        renderer.select(token: 1); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 1), [1])
        renderer.select(token: 1)
        XCTAssertEqual(render(renderer, frames: 1), [1])
        let restarted = source.streamRequest
        XCTAssertNotEqual(restarted.epoch, initial.epoch)
        XCTAssertEqual(source.availableStreamFrames(for: initial.epoch), 0, "Old queued PCM is not readiness for a new visit")
        XCTAssertEqual(source.availableStreamFrames(for: restarted.epoch), 0, "A requested epoch has no committed stream yet")
        XCTAssertTrue(source.beginStream(epoch: restarted.epoch))
        XCTAssertEqual(source.availableStreamFrames(for: restarted.epoch), 0)
        XCTAssertEqual([Float(3), 4].withUnsafeBufferPointer { source.append(interleaved: $0, epoch: restarted.epoch) }, 2)
        XCTAssertEqual(source.availableStreamFrames(for: restarted.epoch), 2)
        XCTAssertEqual(source.availableStreamFrames(for: initial.epoch), 0)
    }

    func testExplicitReturnUsesOutgoingSourceRearmedBeforeTheSwitchBack() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 2, ringFrames: 3)
        let allocatedBytes = renderer.retainedPCMMemoryBytes
        let sourceA = renderer.source(at: 0)
        XCTAssertTrue([Float(1), 2].withUnsafeBufferPointer { sourceA.prepare(token: 1, totalFrames: 5, prefix: $0) })
        prepare(renderer, slot: 1, token: 2, samples: [21, 22])
        let initialA = sourceA.streamRequest
        XCTAssertTrue(sourceA.beginStream(epoch: initialA.epoch))
        XCTAssertEqual([Float(3), 4, 5].withUnsafeBufferPointer { sourceA.append(interleaved: $0, epoch: initialA.epoch) }, 3)
        renderer.select(token: 1); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 4), [1, 2, 3, 4])

        renderer.select(token: 2)
        XCTAssertEqual(render(renderer, frames: 1), [21])
        XCTAssertEqual(renderer.snapshot.token, 2)
        let warmedA = sourceA.streamRequest
        XCTAssertNotEqual(warmedA.epoch, initialA.epoch, "Leaving A must request its next visit while B is current")
        XCTAssertEqual(warmedA.startFrame, 2)
        XCTAssertTrue(sourceA.beginStream(epoch: warmedA.epoch))
        XCTAssertEqual([Float(3), 4, 5].withUnsafeBufferPointer { sourceA.append(interleaved: $0, epoch: warmedA.epoch) }, 3)
        XCTAssertEqual(sourceA.availableStreamFrames(for: warmedA.epoch), 3)
        XCTAssertEqual(renderer.snapshot.token, 2, "Preparation must happen before returning to A")

        renderer.select(token: 1)
        XCTAssertEqual(render(renderer, frames: 5), [1, 2, 3, 4, 5], "The return must consume the prepared head and stream in one request")
        XCTAssertEqual(sourceA.streamRequest.epoch, warmedA.epoch, "Returning must preserve the prewarmed stream epoch")
        XCTAssertEqual(renderer.snapshot.token, 1)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        XCTAssertEqual(renderer.retainedPCMMemoryBytes, allocatedBytes)
    }

    func testNaturalAdvanceRearmsPreviousBeforeReturningWithoutDiscardingPreparedPCM() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 2, ringFrames: 3)
        let allocatedBytes = renderer.retainedPCMMemoryBytes
        let sourceA = renderer.source(at: 0)
        XCTAssertTrue([Float(31), 0].withUnsafeBufferPointer { sourceA.prepare(token: 1, totalFrames: 5, prefix: $0) })
        prepare(renderer, slot: 1, token: 2, samples: [51, 52])
        let initialA = sourceA.streamRequest
        XCTAssertTrue(sourceA.beginStream(epoch: initialA.epoch))
        XCTAssertEqual([Float(33), 34, 0].withUnsafeBufferPointer { sourceA.append(interleaved: $0, epoch: initialA.epoch) }, 3)
        renderer.setSuccessor(token: 2, for: 1)
        renderer.select(token: 1); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 6), [31, 0, 33, 34, 0, 51])
        XCTAssertEqual(renderer.snapshot.token, 2)
        let warmedA = sourceA.streamRequest
        XCTAssertNotEqual(warmedA.epoch, initialA.epoch, "A natural boundary must rearm its outgoing source for Previous")
        XCTAssertEqual(warmedA.startFrame, 2)
        XCTAssertTrue(sourceA.beginStream(epoch: warmedA.epoch))
        XCTAssertEqual([Float(33), 34, 0].withUnsafeBufferPointer { sourceA.append(interleaved: $0, epoch: warmedA.epoch) }, 3)
        XCTAssertEqual(sourceA.availableStreamFrames(for: warmedA.epoch), 3)
        XCTAssertEqual(renderer.snapshot.token, 2)

        renderer.select(token: 1)
        XCTAssertEqual(render(renderer, frames: 5), [31, 0, 33, 34, 0], "Previous must preserve every prepared frame, including source silence")
        XCTAssertEqual(sourceA.streamRequest.epoch, warmedA.epoch)
        XCTAssertEqual(renderer.snapshot.token, 1)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        XCTAssertEqual(renderer.retainedPCMMemoryBytes, allocatedBytes)
    }

    func testUnderrunIsCountedWithoutSkippingUnrenderedContent() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 2, ringFrames: 3)
        let source = renderer.source(at: 0)
        XCTAssertTrue([Float(1), 2].withUnsafeBufferPointer { source.prepare(token: 1, totalFrames: 4, prefix: $0) })
        renderer.select(token: 1); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 4), [1, 2, 0, 0])
        XCTAssertEqual(renderer.snapshot.frame, 2)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 2)
        let request = source.streamRequest
        XCTAssertTrue(source.beginStream(epoch: request.epoch))
        XCTAssertEqual([Float(3), 4].withUnsafeBufferPointer { source.append(interleaved: $0, epoch: request.epoch) }, 2)
        source.finishStream(totalFrames: 4, epoch: request.epoch)
        XCTAssertEqual(render(renderer, frames: 2), [3, 4])
    }

    func testLongLoopUsesPinnedHeadWhileWorkerReopensStreamingTail() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 2, ringFrames: 3)
        let source = renderer.source(at: 0)
        XCTAssertTrue([Float(1), 2].withUnsafeBufferPointer { source.prepare(token: 1, totalFrames: 5, prefix: $0) })
        var request = source.streamRequest
        XCTAssertTrue(source.beginStream(epoch: request.epoch))
        XCTAssertEqual([Float(3), 4, 5].withUnsafeBufferPointer { source.append(interleaved: $0, epoch: request.epoch) }, 3)
        renderer.setSuccessor(token: 1, for: 1); renderer.select(token: 1); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 7), [1, 2, 3, 4, 5, 1, 2])
        request = source.streamRequest
        XCTAssertEqual(request.startFrame, 2)
        XCTAssertTrue(source.beginStream(epoch: request.epoch))
        XCTAssertEqual([Float(3), 4, 5].withUnsafeBufferPointer { source.append(interleaved: $0, epoch: request.epoch) }, 3)
        XCTAssertEqual(render(renderer, frames: 5), [3, 4, 5, 1, 2])
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testAcknowledgedSelectionReleasesOldSlotAndReusingSlotCannotReadOldPrefix() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 8, ringFrames: 8)
        prepare(renderer, slot: 0, token: 1, samples: [1, 2])
        prepare(renderer, slot: 1, token: 2, samples: [3, 4])
        renderer.select(token: 1); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 1), [1])
        renderer.select(token: 2)
        XCTAssertEqual(render(renderer, frames: 1), [3])
        XCTAssertTrue(renderer.retireSource(at: 0))
        prepare(renderer, slot: 0, token: 3, samples: [8, 9])
        renderer.select(token: 3)
        XCTAssertEqual(render(renderer, frames: 2), [8, 9])
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    func testRetiredSlotCannotKeepItsOldSuccessorPinned() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 8, ringFrames: 8)
        prepare(renderer, slot: 0, token: 1, samples: [1])
        prepare(renderer, slot: 1, token: 2, samples: [2])
        prepare(renderer, slot: 2, token: 3, samples: [3])
        renderer.setSuccessor(token: 2, for: 1)
        renderer.select(token: 3); renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 1), [3])
        XCTAssertTrue(renderer.retireSource(at: 0))
        XCTAssertTrue(renderer.retireSource(at: 1), "Retired source 1 must no longer pin source 2")
    }

    func testSelectionAcknowledgementTracksOnlyRenderedCommandAcrossCoalescingAndPause() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 8, ringFrames: 8)
        prepare(renderer, slot: 0, token: 1, samples: [1, 2, 3, 4])
        prepare(renderer, slot: 1, token: 2, samples: [5, 6, 7, 8])
        let first = renderer.select(token: 1, frame: 1)
        XCTAssertEqual(renderer.snapshot.selectionVersion, 0, "Publishing a command is not render acknowledgement")
        XCTAssertEqual(renderer.snapshot.token, 0)
        XCTAssertEqual(render(renderer, frames: 1), [0], "A paused renderer acknowledges position without playing")
        XCTAssertEqual(renderer.snapshot.selectionVersion, first)
        XCTAssertEqual(renderer.snapshot.token, 1)
        XCTAssertEqual(renderer.snapshot.frame, 1)

        let selectedVisit = renderer.snapshot.visit
        renderer.setSuccessor(token: 1, for: 1)
        renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 9), [2, 3, 4, 1, 2, 3, 4, 1, 2])
        XCTAssertGreaterThan(renderer.snapshot.visit, selectedVisit + 1, "Two natural loops must produce distinct source visits")
        XCTAssertEqual(renderer.snapshot.selectionVersion, first, "Natural visits cannot acknowledge a selection command")
        renderer.setPlaying(false)

        let superseded = renderer.select(token: 2, frame: 3)
        let final = renderer.select(token: 1, frame: 2)
        XCTAssertGreaterThan(final, superseded)
        XCTAssertGreaterThan(superseded, first)
        XCTAssertEqual(renderer.snapshot.selectionVersion, first, "An older rendered command cannot acknowledge a newer request")
        XCTAssertNotEqual(renderer.snapshot.selectionVersion, final)
        renderer.setPlaying(false)
        XCTAssertEqual(render(renderer, frames: 4), [0, 0, 0, 0])
        XCTAssertEqual(renderer.snapshot.selectionVersion, final)
        XCTAssertEqual(renderer.snapshot.token, 1, "The coalesced middle command must not become current")
        XCTAssertEqual(renderer.snapshot.frame, 2)
        renderer.setPlaying(true)
        XCTAssertEqual(render(renderer, frames: 1), [3])
        XCTAssertEqual(renderer.snapshot.selectionVersion, final)
        XCTAssertEqual(renderer.snapshot.frame, 3)
    }

    func testLiveAndReferencedSourcesCannotBeEvictedAndStorageRemainsBounded() {
        let renderer = ContinuousPCMRenderer(channels: 2, prefixFrames: 2, ringFrames: 3)
        prepare(renderer, slot: 0, token: 1, samples: [1, 1, 2, 2])
        prepare(renderer, slot: 1, token: 2, samples: [3, 3, 4, 4])
        renderer.setSuccessor(token: 2, for: 1)
        renderer.select(token: 1); renderer.setPlaying(true)
        XCTAssertFalse(renderer.retireSource(at: 0))
        XCTAssertFalse(renderer.retireSource(at: 1))
        _ = render(renderer, frames: 1)
        XCTAssertFalse(renderer.retireSource(at: 0))
        XCTAssertEqual(renderer.retainedPCMMemoryBytes, 3 * (2 + 3) * 2 * MemoryLayout<Float>.stride)
        for token in 3..<103 {
            XCTAssertTrue(renderer.retireSource(at: 2))
            prepare(renderer, slot: 2, token: token, samples: [5, 5])
        }
        XCTAssertEqual(renderer.retainedPCMMemoryBytes, 120)
    }

    func testSpeakerStateIsContinuousAcrossClipBoundariesAndOriginalBypassesExactly() {
        let renderer = ContinuousPCMRenderer(channels: 2, prefixFrames: 8, ringFrames: 8)
        let first: [Float] = [0.1, -0.2, 0.3, -0.1, 0.2, 0.2]
        let second: [Float] = [0.4, 0.1, 0.2, -0.2]
        prepare(renderer, slot: 0, token: 1, samples: first)
        prepare(renderer, slot: 1, token: 2, samples: second)
        renderer.setSuccessor(token: 2, for: 1)
        renderer.select(token: 1); renderer.setSpeakerEnabled(true); renderer.setPlaying(true)
        var expected = first + second
        let processor = SpeakerAudioProcessor(sampleRate: 48000, channels: 2, enabled: true)
        expected.withUnsafeMutableBufferPointer { samples in
            for frame in 0..<5 { processor.process(UnsafeMutableBufferPointer(start: samples.baseAddress! + frame * 2, count: 2)) }
        }
        XCTAssertEqual(render(renderer, frames: 5), expected)
        renderer.setSpeakerEnabled(false); renderer.select(token: 1)
        XCTAssertEqual(render(renderer, frames: 3), first)
    }

    private func prepare(_ renderer: ContinuousPCMRenderer, slot: Int, token: Int, samples: [Float]) {
        XCTAssertTrue(samples.withUnsafeBufferPointer {
            renderer.source(at: slot).prepare(token: token, totalFrames: Int64(samples.count / renderer.channels), prefix: $0)
        })
    }

    private func render(_ renderer: ContinuousPCMRenderer, frames: Int) -> [Float] {
        var output = [Float](repeating: -999, count: frames * renderer.channels)
        output.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: frames) }
        return output
    }
}
