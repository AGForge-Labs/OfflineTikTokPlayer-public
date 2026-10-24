import XCTest
@testable import PlayerCore

final class PlaybackFrameReadinessTests: XCTestCase {
    func testAlignedCurrentPresentationSurvivesAStaleNativeClock() {
        // Run 39533839020 phase 1: the frame was already submitted before
        // native time 0 triggered a seek and withdrew the presentation.
        XCTAssertFalse(PlaybackVideoSynchronization.requiresExactSeek(force: false, canPlay: true,
            nativeRate: 1, nativePosition: 0, audioPosition: 0.150_562_5,
            framePosition: 0.083_333_333, timebasePosition: 0.150_562_5))
        // Phase 0 had already passed the display commit before its drift seek.
        XCTAssertFalse(PlaybackVideoSynchronization.requiresExactSeek(force: false, canPlay: true,
            nativeRate: 1, nativePosition: 0, audioPosition: 0.112_854_167,
            framePosition: 0.041_666_667, timebasePosition: 0.112_854_167))
    }

    func testPresentationCannotBypassForcedPausedStoppedOrUnprovenRecovery() {
        func requires(force: Bool = false, canPlay: Bool = true, rate: Float = 1,
                      frame: Double? = 0.1, timebase: Double? = 0.15) -> Bool {
            PlaybackVideoSynchronization.requiresExactSeek(force: force, canPlay: canPlay,
                nativeRate: rate, nativePosition: 0, audioPosition: 0.15,
                framePosition: frame, timebasePosition: timebase)
        }
        XCTAssertFalse(requires())
        XCTAssertTrue(requires(force: true))
        XCTAssertTrue(requires(canPlay: false))
        for rate: Float in [0, -1, .nan, .infinity] { XCTAssertTrue(requires(rate: rate)) }
        XCTAssertTrue(requires(frame: nil), "An epoch reset must invalidate a lifetime frame count")
        XCTAssertTrue(requires(timebase: nil))
        for bad in [Double.nan, .infinity, -.infinity, 0.069, 0.231] {
            XCTAssertTrue(requires(frame: bad))
            XCTAssertTrue(requires(timebase: bad))
        }
    }

    func testNativeAlignmentAndForcedSeekRetainTheirOriginalSemantics() {
        XCTAssertFalse(PlaybackVideoSynchronization.requiresExactSeek(force: false, canPlay: false,
            nativeRate: 0, nativePosition: 0.149, audioPosition: 0.15,
            framePosition: nil, timebasePosition: nil))
        XCTAssertTrue(PlaybackVideoSynchronization.requiresExactSeek(force: true, canPlay: true,
            nativeRate: 1, nativePosition: 0.15, audioPosition: 0.15,
            framePosition: 0.15, timebasePosition: 0.15))
    }

    func testAWithdrawnCurrentFrameCannotSurviveTheDisplayCommitGate() {
        var state = PlaybackFrameReadiness()
        XCTAssertFalse(state.sampleCurrentFrame(epoch: 1, layerReady: true, displayTime: 1))
        XCTAssertFalse(state.sampleCurrentFrame(epoch: nil, layerReady: true, displayTime: 2),
                       "A seek withdrew the current epoch before its display commit")
        XCTAssertFalse(state.sampleCurrentFrame(epoch: 2, layerReady: true, displayTime: 3),
                       "The replacement frame needs its own display opportunity")
        XCTAssertTrue(state.sampleCurrentFrame(epoch: 2, layerReady: true, displayTime: 4))
        XCTAssertFalse(state.sampleCurrentFrame(epoch: nil, layerReady: true, displayTime: 5))
    }

    func testARefilledNewEpochCannotBorrowThePreviousEpochDisplayTick() {
        var state = PlaybackFrameReadiness()
        XCTAssertFalse(state.sampleCurrentFrame(epoch: 1, layerReady: true, displayTime: 1))
        XCTAssertFalse(state.sampleCurrentFrame(epoch: 2, layerReady: true, displayTime: 2),
                       "A flush and refill between observations still requires this epoch's own display opportunity")
        XCTAssertTrue(state.sampleCurrentFrame(epoch: 2, layerReady: true, displayTime: 3))
    }

    func testOldLayerReadinessCannotUncoverANewItem() {
        var state = PlaybackFrameReadiness()
        XCTAssertFalse(state.sample(decodedFrame: false, layerReady: true, displayTime: 1))
        XCTAssertFalse(state.sample(decodedFrame: false, layerReady: true, displayTime: 2))
    }

    func testNewFrameGetsOneDisplayOpportunityBeforeUncovering() {
        var state = PlaybackFrameReadiness()
        XCTAssertFalse(state.sample(decodedFrame: true, layerReady: false, displayTime: 1))
        XCTAssertFalse(state.sample(decodedFrame: false, layerReady: true, displayTime: 2))
        XCTAssertFalse(state.sample(decodedFrame: false, layerReady: true, displayTime: 2))
        XCTAssertTrue(state.sample(decodedFrame: false, layerReady: true, displayTime: 3))
        XCTAssertTrue(state.sample(decodedFrame: false, layerReady: false, displayTime: 4))
    }

    func testResetRequiresTheNextItemsOwnFrame() {
        var state = PlaybackFrameReadiness()
        _ = state.sample(decodedFrame: true, layerReady: true, displayTime: 1)
        XCTAssertTrue(state.sample(decodedFrame: true, layerReady: true, displayTime: 2))
        state = PlaybackFrameReadiness()
        XCTAssertFalse(state.sample(decodedFrame: false, layerReady: true, displayTime: 3))
        XCTAssertFalse(state.sample(decodedFrame: true, layerReady: true, displayTime: .nan))
    }
}
