import XCTest
@testable import PlayerCore

final class VideoImageProgressTests: XCTestCase {
    func testAdvancingClockWithoutIncomingPicturesRequestsOneBoundedRepair() {
        var progress = VideoImageProgress()
        XCTAssertFalse(progress.shouldRecover(now: 0, nativePosition: 0.2, displayedPosition: 0.2))
        XCTAssertFalse(progress.shouldRecover(now: 0.7, nativePosition: 0.9, displayedPosition: 0.2))
        XCTAssertTrue(progress.shouldRecover(now: 1.6, nativePosition: 1.8, displayedPosition: 0.2))
        for tick in 2...30 {
            XCTAssertFalse(progress.shouldRecover(now: Double(tick), nativePosition: Double(tick) + 0.2,
                displayedPosition: tick.isMultiple(of: 2) ? 0.2 : nil), "A held/static/VFR image must not cause a repair loop")
        }
    }
    func testMissingFirstImageCanRecoverButRepeatedSamePTSAfterSeekCannotRearmIt() {
        var progress = VideoImageProgress()
        XCTAssertFalse(progress.shouldRecover(now: 0, nativePosition: 0.1, displayedPosition: nil))
        XCTAssertTrue(progress.shouldRecover(now: 1.6, nativePosition: 1.7, displayedPosition: nil))
        XCTAssertFalse(progress.shouldRecover(now: 1.7, nativePosition: 1.8, displayedPosition: 0))
        XCTAssertFalse(progress.shouldRecover(now: 4, nativePosition: 4.1, displayedPosition: 0))
    }
    func testHealthySlowAndVFRHoldsCannotCauseRepeatedRepairsWithinOneOwner() {
        var progress = VideoImageProgress()
        XCTAssertFalse(progress.shouldRecover(now: 0, nativePosition: 0.2, displayedPosition: 0.2))
        XCTAssertTrue(progress.shouldRecover(now: 1.6, nativePosition: 1.8, displayedPosition: 0.2))
        XCTAssertFalse(progress.shouldRecover(now: 2, nativePosition: 2.2, displayedPosition: 2.1))
        XCTAssertFalse(progress.shouldRecover(now: 2.5, nativePosition: 2.7, displayedPosition: 2.1))
        XCTAssertFalse(progress.shouldRecover(now: 3.6, nativePosition: 3.8, displayedPosition: 2.1))
        for tick in stride(from: 4, through: 20, by: 2) {
            let position = Double(tick)
            XCTAssertFalse(progress.shouldRecover(now: position, nativePosition: position + 0.2, displayedPosition: position))
            XCTAssertFalse(progress.shouldRecover(now: position + 1.6, nativePosition: position + 1.8, displayedPosition: position))
        }
    }
    func testNativeClockAndRepeatedDecodedFramesAreNotImageProgress() {
        var stopped = VideoImageProgress()
        XCTAssertFalse(stopped.shouldRecover(now: 0, nativePosition: 0.2, displayedPosition: nil))
        XCTAssertFalse(stopped.shouldRecover(now: 5, nativePosition: 0.2, displayedPosition: nil))
        var playing = VideoImageProgress()
        for tick in 0...300 {
            let position = Double(tick) / 60
            XCTAssertFalse(playing.shouldRecover(now: position, nativePosition: position,
                displayedPosition: position), "New PTS remains progress even when the picture content is static")
        }
    }
    func testClockDiscontinuityAndNonfiniteSamplesCannotTriggerRepair() {
        var progress = VideoImageProgress()
        XCTAssertFalse(progress.shouldRecover(now: 0, nativePosition: 3, displayedPosition: 3))
        XCTAssertFalse(progress.shouldRecover(now: 4, nativePosition: 0.2, displayedPosition: nil))
        XCTAssertFalse(progress.shouldRecover(now: 4.1, nativePosition: 0.3, displayedPosition: nil))
        XCTAssertFalse(progress.shouldRecover(now: .nan, nativePosition: 3, displayedPosition: nil))
        XCTAssertFalse(progress.shouldRecover(now: 8, nativePosition: .infinity, displayedPosition: nil))
    }
    func testKnownSlowSourceUsesItsCadenceBeforeRequestingAnyRepair() {
        var progress = VideoImageProgress(graceSeconds: 6)
        for tick in 0...12 {
            let now = Double(tick) / 2
            let image = floor(now / 2) * 2
            XCTAssertFalse(progress.shouldRecover(now: now, nativePosition: now, displayedPosition: image))
        }
    }
}
