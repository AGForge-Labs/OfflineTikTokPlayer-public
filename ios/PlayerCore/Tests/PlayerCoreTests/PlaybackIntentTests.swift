import XCTest
@testable import PlayerCore

final class PlaybackIntentTests: XCTestCase {
    func testInterruptionPreservesIntentButBlocksPlaybackUntilReactivation() {
        var intent = PlaybackIntent()
        intent.requestPlay(); intent.activationCompleted(succeeded: true)
        XCTAssertTrue(intent.canPlay)
        intent.interruptionBegan(); intent.interruptionBegan()
        XCTAssertTrue(intent.wantsToPlay)
        XCTAssertFalse(intent.canPlay)
        XCTAssertTrue(intent.interruptionEnded(shouldResume: true))
        XCTAssertFalse(intent.canPlay)
        intent.activationCompleted(succeeded: true)
        XCTAssertTrue(intent.canPlay)
    }

    func testUserPauseDuringInterruptionAlwaysWinsIncludingLateEnd() {
        var intent = PlaybackIntent()
        intent.requestPlay(); intent.activationCompleted(succeeded: true)
        intent.interruptionBegan(); intent.pause()
        XCTAssertFalse(intent.interruptionEnded(shouldResume: true))
        XCTAssertFalse(intent.interruptionEnded(shouldResume: true))
        XCTAssertFalse(intent.canPlay)
        XCTAssertFalse(intent.wantsToPlay)
    }

    func testMissingResumePermissionAndFailedActivationStayStopped() {
        var intent = PlaybackIntent()
        intent.requestPlay(); intent.activationCompleted(succeeded: true)
        intent.interruptionBegan()
        XCTAssertFalse(intent.interruptionEnded(shouldResume: false))
        XCTAssertFalse(intent.wantsToPlay)
        intent.requestPlay(); intent.activationCompleted(succeeded: false)
        XCTAssertFalse(intent.canPlay)
        intent.pause(); intent.activationCompleted(succeeded: true)
        XCTAssertFalse(intent.canPlay)
    }

    func testForegroundDoesNotInventResumePermissionForMissingEnd() {
        var intent = PlaybackIntent()
        intent.requestPlay(); intent.activationCompleted(succeeded: true)
        // A normal background/foreground cycle must leave background audio running.
        intent.enteredForeground(); XCTAssertTrue(intent.canPlay)
        intent.interruptionBegan(); intent.enteredForeground()
        XCTAssertFalse(intent.canPlay)
        XCTAssertTrue(intent.isInterrupted)
        intent.requestPlay(); intent.activationCompleted(succeeded: true)
        XCTAssertTrue(intent.canPlay)
        XCTAssertFalse(intent.interruptionEnded(shouldResume: true))
        XCTAssertTrue(intent.canPlay)
    }

    func testForegroundBeforeRealInterruptionEndRetainsResumePermission() {
        var intent = PlaybackIntent()
        intent.requestPlay(); intent.activationCompleted(succeeded: true)
        intent.interruptionBegan(); intent.enteredForeground()
        XCTAssertTrue(intent.interruptionEnded(shouldResume: true))
        intent.activationCompleted(succeeded: true)
        XCTAssertTrue(intent.canPlay)
    }
}
