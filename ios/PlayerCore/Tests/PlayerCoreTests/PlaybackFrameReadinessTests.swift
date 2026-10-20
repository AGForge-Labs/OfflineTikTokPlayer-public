import XCTest
@testable import PlayerCore

final class PlaybackFrameReadinessTests: XCTestCase {
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
