import XCTest
@testable import PlayerCore
#if DEBUG
import Dispatch
import Foundation
import Synchronization
#endif

/// Actual kernel branches, not a PCM-energy classifier or mocked render result.
final class ContinuousRenderAccountingTests: XCTestCase {
    func testCallbackLedgerDistinguishesCopiedZeroPauseAndUnavailablePrefixes() throws {
        #if DEBUG
        let accounting = ContinuousPCMRenderer.DebugRenderAccountingRecorder(captureCallbackLedger: true)
        XCTAssertNil(ContinuousPCMRenderer.DebugRenderAccountingRecorder().callbackLedger)
        let ledger = try XCTUnwrap(accounting.callbackLedger)
        let renderer = ContinuousPCMRenderer(channels: 2, prefixFrames: 8, ringFrames: 8, debugRenderAccounting: accounting)
        let input: [Float] = [0, 0, 0, 0, 1, 1, 2, 2]
        XCTAssertTrue(input.withUnsafeBufferPointer { renderer.source(at: 0).prepare(token: 7, totalFrames: 4, prefix: $0) })
        renderer.select(token: 7); renderer.setPlaying(true)
        func callback(sample: Double) -> [Float] {
            let suppliedHost = UInt64(sample + 100)
            ledger.beginSource(stamp: .init(host: suppliedHost, sample: sample, rate: 48_000, valid: 3),
                frames: 4, counters: accounting.renderWriterCounters())
            accounting.sourceCallbackEntered(frames: 4, hostTimeValid: true, hostTime: suppliedHost)
            ledger.layout(buffers: 2, channels0: 1, channels1: 1, bytes0: 16, bytes1: 16, dataPresent: true)
            var output = [Float](repeating: -1, count: 8)
            output.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 4) }
            ledger.observeChunk(accounting.renderWriterCounters())
            for frame in 0..<4 { accounting.sourceOutputPair(left: output[frame * 2], right: output[frame * 2 + 1]) }
            accounting.sourceCallbackCompleted(frames: 4, invalidLayout: false)
            ledger.endSource(result: 0, counters: accounting.renderWriterCounters())
            return output
        }
        XCTAssertEqual(callback(sample: 10), input)
        renderer.setPlaying(false)
        XCTAssertEqual(callback(sample: 14), [Float](repeating: 0, count: 8))
        let prefix = ledger.prefix()
        XCTAssertEqual(prefix.source.count, 2); XCTAssertFalse(prefix.failed)
        XCTAssertEqual(prefix.source[0].copied, 4); XCTAssertEqual(prefix.source[0].paused, 0)
        XCTAssertEqual(prefix.source[0].first.first, 0); XCTAssertEqual(prefix.source[0].first.end, 2)
        XCTAssertEqual(prefix.source[1].copied, 0); XCTAssertEqual(prefix.source[1].paused, 4)
        XCTAssertEqual(prefix.source[1].zeros, 4); XCTAssertFalse(prefix.coverageClosed)
        ledger.beginSource(stamp: .init(), frames: 4, counters: accounting.renderWriterCounters())
        let open = ledger.prefix()
        XCTAssertEqual(open.enteredBefore, 3); XCTAssertEqual(open.completedBefore, 2)
        ledger.layout(buffers: 1, channels0: 2, channels1: 0, bytes0: 32, bytes1: 0, dataPresent: true)
        ledger.endSource(result: -50, counters: accounting.renderWriterCounters())
        XCTAssertTrue(ledger.prefix().failed)
        let sourceTiny = ContinuousPCMRenderer.DebugSourceCallbackLedger(sourceCapacity: 1, tapCapacity: 1)
        let tinyAccounting = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
        let tinyRenderer = ContinuousPCMRenderer(channels: 2, prefixFrames: 1, ringFrames: 1,
                                                debugRenderAccounting: tinyAccounting)
        XCTAssertTrue([Float(1), 1].withUnsafeBufferPointer {
            tinyRenderer.source(at: 0).prepare(token: 8, totalFrames: 1, prefix: $0)
        })
        tinyRenderer.select(token: 8) // Actual positive-token paused disposition.
        for ordinal in 0..<2 {
            sourceTiny.beginSource(stamp: .init(host: UInt64(ordinal + 100), sample: Double(ordinal), rate: 48_000, valid: 3),
                                   frames: 1, counters: tinyAccounting.renderWriterCounters())
            tinyAccounting.sourceCallbackEntered(frames: 1, hostTimeValid: true, hostTime: UInt64(ordinal + 100))
            sourceTiny.layout(buffers: 2, channels0: 1, channels1: 1, bytes0: 4, bytes1: 4, dataPresent: true)
            var paused = [Float](repeating: -1, count: 2)
            paused.withUnsafeMutableBufferPointer { tinyRenderer.render(interleaved: $0, frameCount: 1) }
            sourceTiny.observeChunk(tinyAccounting.renderWriterCounters())
            sourceTiny.writtenPair(left: paused[0], right: paused[1])
            tinyAccounting.sourceCallbackCompleted(frames: 1, invalidLayout: false)
            sourceTiny.endSource(result: 0, counters: tinyAccounting.renderWriterCounters())
            if ordinal == 0 { XCTAssertFalse(sourceTiny.prefix().failed) }
        }
        XCTAssertEqual(sourceTiny.prefix().source.count, 1)
        XCTAssertEqual(sourceTiny.prefix().enteredBefore, 2); XCTAssertTrue(sourceTiny.prefix().failed)
        let tiny = ContinuousPCMRenderer.DebugSourceCallbackLedger(sourceCapacity: 1, tapCapacity: 1)
        let emptyTap = ContinuousPCMRenderer.DebugSourceCallbackLedger.Tap(stamp: .init(), first: 0, end: 0, inputFrames: 0, channels: 0, flags: 0)
        tiny.appendTap(emptyTap); tiny.appendTap(emptyTap)
        XCTAssertEqual(tiny.prefix().tap.count, 1); XCTAssertTrue(tiny.prefix().failed)
        #else
        XCTFail("Callback ledger requires DEBUG")
        #endif
    }
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

    func testAccountingReadsPreviousCompleteRecordWhilePublicationIsHeld() throws {
        #if DEBUG
        let gate = AccountingPublicationGate()
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder(capturePCMOrigin: true, testHooks: .init(
            publicationPrepared: { gate.holdOnce() }))
        recorder.sourceCallbackEntered(frames: 3, hostTimeValid: true, hostTime: 100)
        recorder.sourceCallbackCompleted(frames: 3, invalidLayout: false)
        let before = try XCTUnwrap(recorder.snapshot())
        XCTAssertNotNil(before.pcmOrigin)
        XCTAssertEqual(before.pcmOrigin?.valid, false)
        XCTAssertEqual(before.pcmOrigin?.completion, 0)
        let finished = DispatchSemaphore(value: 0)
        gate.arm()
        defer { gate.release() }
        DispatchQueue(label: "test.accounting-held-publication").async {
            recorder.sourceCallbackEntered(frames: 7, hostTimeValid: true, hostTime: 200)
            finished.signal()
        }
        XCTAssertTrue(gate.waitForEntry())
        let held = recorder.snapshot()
        XCTAssertNotNil(held, "An unpublished bank must not hide the previous complete publication")
        if let held {
            XCTAssertEqual(held.sequence, before.sequence)
            XCTAssertEqual(held.sourceCallbacksEntered, 1); XCTAssertEqual(held.sourceCallbacksCompleted, 1)
            XCTAssertEqual(held.sourceFramesRequested, 3); XCTAssertEqual(held.sourceFramesCompleted, 3)
            XCTAssertEqual(held.lastSourceHostTime, 100)
            XCTAssertEqual(held.pcmOrigin, before.pcmOrigin)
            XCTAssertFalse(held.overflowed)
        }
        gate.release()
        XCTAssertEqual(finished.wait(timeout: .now() + .seconds(2)), .success)
        XCTAssertFalse(gate.didTimeOut, "The test must release the writer before its safety timeout")
        let after = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(after.sequence, before.sequence + 2)
        XCTAssertEqual(after.sourceCallbacksEntered, 2); XCTAssertEqual(after.sourceCallbacksCompleted, 1)
        XCTAssertEqual(after.sourceFramesRequested, 10); XCTAssertEqual(after.sourceFramesCompleted, 3)
        XCTAssertEqual(after.lastSourceHostTime, 200)
        #else
        XCTFail("Accounting publication controls require DEBUG")
        #endif
    }

    func testAccountingReaderPinSurvivesPublicationsAndRejectsConcurrentObserver() throws {
        #if DEBUG
        let gate = AccountingPublicationGate()
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder(testHooks: .init(
            readerPinned: { gate.holdOnce() }))
        recorder.sourceCallbackEntered(frames: 3, hostTimeValid: true, hostTime: 100)
        recorder.sourceCallbackCompleted(frames: 3, invalidLayout: false)
        let before = try XCTUnwrap(recorder.snapshot())
        let result = AccountingSnapshotBox()
        let finished = DispatchSemaphore(value: 0)
        gate.arm()
        defer { gate.release() }
        DispatchQueue(label: "test.accounting-pinned-observer").async {
            result.store(recorder.snapshot())
            finished.signal()
        }
        XCTAssertTrue(gate.waitForEntry())
        // A pinned reader keeps its old bank. The sole writer must continue
        // publishing through the other two banks without waiting for that reader.
        for ordinal in 0..<256 {
            recorder.sourceCallbackEntered(frames: 1, hostTimeValid: true, hostTime: UInt64(ordinal + 200))
            recorder.sourceCallbackCompleted(frames: 1, invalidLayout: false)
        }
        XCTAssertNil(recorder.snapshot(), "Concurrent observers remain explicitly unavailable")
        let heldStatus = finished.wait(timeout: .now())
        XCTAssertEqual(heldStatus, .timedOut, "The original observer must still hold its pinned bank")
        XCTAssertFalse(gate.didTimeOut, "Writer publications must not wait for the observer timeout")
        gate.release()
        if heldStatus == .timedOut {
            XCTAssertEqual(finished.wait(timeout: .now() + .seconds(2)), .success)
        }
        XCTAssertFalse(gate.didTimeOut)
        let held = try XCTUnwrap(result.load())
        XCTAssertEqual(held.sequence, before.sequence)
        XCTAssertEqual(held.sourceCallbacksEntered, 1); XCTAssertEqual(held.sourceCallbacksCompleted, 1)
        XCTAssertEqual(held.sourceFramesRequested, 3); XCTAssertEqual(held.sourceFramesCompleted, 3)
        XCTAssertEqual(held.lastSourceHostTime, 100)
        let after = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(after.sequence, before.sequence + 1_024)
        XCTAssertEqual(after.sourceCallbacksEntered, 257); XCTAssertEqual(after.sourceCallbacksCompleted, 257)
        XCTAssertEqual(after.sourceFramesRequested, 259); XCTAssertEqual(after.sourceFramesCompleted, 259)
        XCTAssertFalse(after.overflowed)
        #else
        XCTFail("Accounting publication controls require DEBUG")
        #endif
    }

    func testAccountingPublicationExhaustionRemainsUnavailableWithoutVersionReuse() throws {
        #if DEBUG
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder(testHooks: .init(
            initialSequence: UInt64.max - 3))
        XCTAssertEqual(try XCTUnwrap(recorder.snapshot()).sequence, UInt64.max - 3)
        recorder.sourceCallbackEntered(frames: 1, hostTimeValid: true, hostTime: 1)
        XCTAssertEqual(try XCTUnwrap(recorder.snapshot()).sequence, UInt64.max - 1)
        recorder.sourceCallbackCompleted(frames: 1, invalidLayout: false)
        XCTAssertNil(recorder.snapshot())
        recorder.sourceCallbackEntered(frames: 1, hostTimeValid: true, hostTime: 2)
        XCTAssertNil(recorder.snapshot(), "Exhaustion cannot fall back to the last complete bank")
        #else
        XCTFail("Accounting publication controls require DEBUG")
        #endif
    }

    func testAccountingCounterOverflowRemainsVisibleInCompletePublication() throws {
        #if DEBUG
        let recorder = ContinuousPCMRenderer.DebugRenderAccountingRecorder(testHooks: .init(
            initialSourceFramesRequested: UInt64.max))
        recorder.sourceCallbackEntered(frames: 1, hostTimeValid: true, hostTime: 1)
        let value = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(value.sourceFramesRequested, UInt64.max)
        XCTAssertEqual(value.sourceCallbacksEntered, 1)
        XCTAssertTrue(value.overflowed, "A complete publication must retain the quality failure")
        #else
        XCTFail("Accounting publication controls require DEBUG")
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

#if DEBUG
/// These waits exist only in a test-installed immutable hook, never an app initializer.
private final class AccountingPublicationGate: @unchecked Sendable {
    private let armed = Atomic<Bool>(false)
    private let timedOut = Atomic<Bool>(false)
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    func arm() { armed.store(true, ordering: .releasing) }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + .seconds(2)) == .success }
    func release() { released.signal() }
    var didTimeOut: Bool { timedOut.load(ordering: .acquiring) }
    func holdOnce() {
        guard armed.exchange(false, ordering: .acquiringAndReleasing) else { return }
        entered.signal()
        timedOut.store(released.wait(timeout: .now() + .seconds(5)) == .timedOut, ordering: .releasing)
    }
}

private final class AccountingSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuousPCMRenderer.DebugRenderAccountingSnapshot?
    func store(_ value: ContinuousPCMRenderer.DebugRenderAccountingSnapshot?) {
        lock.lock(); self.value = value; lock.unlock()
    }
    func load() -> ContinuousPCMRenderer.DebugRenderAccountingSnapshot? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}
#endif
