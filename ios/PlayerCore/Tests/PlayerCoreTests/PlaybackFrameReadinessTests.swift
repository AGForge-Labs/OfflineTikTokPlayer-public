import XCTest
@testable import PlayerCore

final class PlaybackFrameReadinessTests: XCTestCase {
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
