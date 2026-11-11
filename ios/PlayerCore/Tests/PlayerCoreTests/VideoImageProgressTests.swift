import XCTest
@testable import PlayerCore

final class VideoImageProgressTests: XCTestCase {
    func testAdvancingClockWithoutIncomingPicturesRequestsOneBoundedRepair() {
        var progress = VideoImageProgress()
        XCTAssertFalse(progress.shouldRecover(now: 0, playbackPosition: 0.2, displayedPosition: 0.2))
        XCTAssertFalse(progress.shouldRecover(now: 0.7, playbackPosition: 0.9, displayedPosition: 0.2))
        XCTAssertTrue(progress.shouldRecover(now: 1.6, playbackPosition: 1.8, displayedPosition: 0.2))
        for tick in 2...30 {
            XCTAssertFalse(progress.shouldRecover(now: Double(tick), playbackPosition: Double(tick) + 0.2,
                displayedPosition: tick.isMultiple(of: 2) ? 0.2 : nil), "A held/static/VFR image must not cause a repair loop")
        }
    }
    func testMissingFirstImageCanRecoverButRepeatedSamePTSAfterSeekCannotRearmIt() {
        var progress = VideoImageProgress()
        XCTAssertFalse(progress.shouldRecover(now: 0, playbackPosition: 0.1, displayedPosition: nil))
        XCTAssertTrue(progress.shouldRecover(now: 1.6, playbackPosition: 1.7, displayedPosition: nil))
        XCTAssertFalse(progress.shouldRecover(now: 1.7, playbackPosition: 1.8, displayedPosition: 0))
        XCTAssertFalse(progress.shouldRecover(now: 4, playbackPosition: 4.1, displayedPosition: 0))
    }
    func testHealthySlowAndVFRHoldsCannotCauseRepeatedRepairsWithinOneOwner() {
        var progress = VideoImageProgress()
        XCTAssertFalse(progress.shouldRecover(now: 0, playbackPosition: 0.2, displayedPosition: 0.2))
        XCTAssertTrue(progress.shouldRecover(now: 1.6, playbackPosition: 1.8, displayedPosition: 0.2))
        XCTAssertFalse(progress.shouldRecover(now: 2, playbackPosition: 2.2, displayedPosition: 2.1))
        XCTAssertFalse(progress.shouldRecover(now: 2.5, playbackPosition: 2.7, displayedPosition: 2.1))
        XCTAssertFalse(progress.shouldRecover(now: 3.6, playbackPosition: 3.8, displayedPosition: 2.1))
        for tick in stride(from: 4, through: 20, by: 2) {
            let position = Double(tick)
            XCTAssertFalse(progress.shouldRecover(now: position, playbackPosition: position + 0.2, displayedPosition: position))
            XCTAssertFalse(progress.shouldRecover(now: position + 1.6, playbackPosition: position + 1.8, displayedPosition: position))
        }
    }
    func testSustainedMovingPicturesAllowRecoveryFromAnotherFreeze() {
        var progress = VideoImageProgress()
        XCTAssertFalse(progress.shouldRecover(now: 0, playbackPosition: 0.2, displayedPosition: 0.2))
        XCTAssertTrue(progress.shouldRecover(now: 1.75, playbackPosition: 1.95, displayedPosition: 0.2))
        for tick in 8...16 {
            let now = Double(tick) / 4
            XCTAssertFalse(progress.shouldRecover(now: now, playbackPosition: now + 0.2, displayedPosition: now + 0.16))
        }
        XCTAssertFalse(progress.shouldRecover(now: 4.75, playbackPosition: 4.95, displayedPosition: 4.16))
        XCTAssertTrue(progress.shouldRecover(now: 5.75, playbackPosition: 5.95, displayedPosition: 4.16))
        XCTAssertFalse(progress.shouldRecover(now: 8, playbackPosition: 8.2, displayedPosition: 4.16))
    }
    func testNativeClockAndRepeatedDecodedFramesAreNotImageProgress() {
        var stopped = VideoImageProgress()
        XCTAssertFalse(stopped.shouldRecover(now: 0, playbackPosition: 0.2, displayedPosition: nil))
        XCTAssertFalse(stopped.shouldRecover(now: 5, playbackPosition: 0.2, displayedPosition: nil))
        var playing = VideoImageProgress()
        for tick in 0...300 {
            let position = Double(tick) / 60
            XCTAssertFalse(playing.shouldRecover(now: position, playbackPosition: position,
                displayedPosition: position), "New PTS remains progress even when the picture content is static")
        }
    }
    func testClockDiscontinuityAndNonfiniteSamplesCannotTriggerRepair() {
        var progress = VideoImageProgress()
        XCTAssertFalse(progress.shouldRecover(now: 0, playbackPosition: 3, displayedPosition: 3))
        XCTAssertFalse(progress.shouldRecover(now: 4, playbackPosition: 0.2, displayedPosition: nil))
        XCTAssertFalse(progress.shouldRecover(now: 4.1, playbackPosition: 0.3, displayedPosition: nil))
        XCTAssertFalse(progress.shouldRecover(now: .nan, playbackPosition: 3, displayedPosition: nil))
        XCTAssertFalse(progress.shouldRecover(now: 8, playbackPosition: .infinity, displayedPosition: nil))
    }
    func testKnownSlowSourceUsesItsCadenceBeforeRequestingAnyRepair() {
        var progress = VideoImageProgress(graceSeconds: 6)
        for tick in 0...12 {
            let now = Double(tick) / 2
            let image = floor(now / 2) * 2
            XCTAssertFalse(progress.shouldRecover(now: now, playbackPosition: now, displayedPosition: image))
        }
    }
}
