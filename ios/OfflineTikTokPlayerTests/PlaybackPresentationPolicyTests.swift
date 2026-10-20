import XCTest
#if canImport(OfflineTikTokPlayer)
@testable import OfflineTikTokPlayer
#else
@testable import PlaybackSupport
#endif

final class PlaybackPresentationPolicyTests: XCTestCase {
    func testBackgroundTransitionKeepsVideoEligibleUntilPiPStartsOrFails() {
        var policy = PlaybackPresentationPolicy()
        _ = policy.applicationDidEnterBackground()
        XCTAssertEqual(policy.presentation, .inlineVideo)
        _ = policy.pictureInPictureChanged(active: true, possible: true, suspended: false)
        XCTAssertEqual(policy.presentation, .pictureInPicture)
        _ = policy.pictureInPictureChanged(active: true, possible: false, suspended: true)
        XCTAssertEqual(policy.presentation, .audioOnly)
    }
    func testSuspendedBackgroundPiPFallsBackAndRestoresInlineOnce() {
        var policy = PlaybackPresentationPolicy()
        _ = policy.pictureInPictureChanged(active: true, possible: true, suspended: false)
        _ = policy.applicationDidEnterBackground()
        XCTAssertEqual(policy.presentation, .pictureInPicture)

        let suspended = policy.pictureInPictureChanged(active: true, possible: false, suspended: true)
        XCTAssertEqual(policy.presentation, .audioOnly)
        XCTAssertFalse(suspended.stopPictureInPicture)
        XCTAssertFalse(suspended.restoreInlineVideo)

        let foreground = policy.applicationDidBecomeActive()
        XCTAssertTrue(foreground.stopPictureInPicture)
        XCTAssertTrue(foreground.restoreInlineVideo)
        let duplicate = policy.applicationDidBecomeActive()
        XCTAssertFalse(duplicate.stopPictureInPicture)
        XCTAssertFalse(duplicate.restoreInlineVideo)
    }

    func testStoppedAndFailedBackgroundPiPRequestInlineRestoration() {
        for failed in [false, true] {
            var policy = PlaybackPresentationPolicy()
            _ = policy.pictureInPictureChanged(active: true, possible: true, suspended: false)
            _ = policy.applicationDidEnterBackground()
            if failed { _ = policy.pictureInPictureFailedToStart() }
            else { _ = policy.pictureInPictureChanged(active: false, possible: false, suspended: false) }
            XCTAssertEqual(policy.presentation, .audioOnly)
            XCTAssertTrue(policy.applicationDidBecomeActive().restoreInlineVideo)
        }
    }

    func testNormalForegroundAndPiPFailureDoNotNavigateTheUser() {
        var policy = PlaybackPresentationPolicy()
        XCTAssertFalse(policy.applicationDidBecomeActive().restoreInlineVideo)
        XCTAssertFalse(policy.pictureInPictureFailedToStart().restoreInlineVideo)
        XCTAssertEqual(policy.presentation, .inlineVideo)
        _ = policy.applicationDidEnterBackground()
        XCTAssertFalse(policy.applicationDidBecomeActive().restoreInlineVideo)
    }

    func testExplicitAudioOnlyPreferenceStopsVideoWithoutCreatingAnAudioAction() {
        var policy = PlaybackPresentationPolicy()
        _ = policy.pictureInPictureChanged(active: true, possible: true, suspended: false)
        let selection = policy.setAudioOnly(true)
        XCTAssertTrue(selection.stopPictureInPicture)
        XCTAssertFalse(selection.restoreInlineVideo)
        XCTAssertFalse(policy.allowsPictureInPicture)
        _ = policy.applicationDidEnterBackground()
        XCTAssertEqual(policy.presentation, .audioOnly)
        XCTAssertFalse(policy.applicationDidBecomeActive().restoreInlineVideo)
        XCTAssertEqual(policy.presentation, .audioOnly)
        XCTAssertTrue(policy.setAudioOnly(false).restoreInlineVideo)
        XCTAssertTrue(policy.allowsPictureInPicture)
    }

    func testLateAutomaticPiPStartIsStoppedWhenAudioOnlyWasSelected() {
        var policy = PlaybackPresentationPolicy(audioOnly: true)
        _ = policy.applicationDidEnterBackground()
        let lateStart = policy.pictureInPictureChanged(active: true, possible: true, suspended: false)
        XCTAssertTrue(lateStart.stopPictureInPicture)
        XCTAssertEqual(policy.presentation, .audioOnly)
    }

    func testEnablingVideoInBackgroundWaitsForInlineReturnWithoutStartingPiP() {
        var policy = PlaybackPresentationPolicy(audioOnly: true)
        _ = policy.applicationDidEnterBackground()
        let selection = policy.setAudioOnly(false)
        XCTAssertFalse(selection.stopPictureInPicture)
        XCTAssertFalse(selection.restoreInlineVideo)
        XCTAssertTrue(policy.applicationDidBecomeActive().restoreInlineVideo)
        XCTAssertEqual(policy.presentation, .inlineVideo)
    }

    func testDuplicateExplicitSelectionsDoNotRepeatRestoration() {
        var policy = PlaybackPresentationPolicy(audioOnly: true)
        XCTAssertFalse(policy.setAudioOnly(true).restoreInlineVideo)
        XCTAssertTrue(policy.setAudioOnly(false).restoreInlineVideo)
        XCTAssertFalse(policy.setAudioOnly(false).restoreInlineVideo)
    }

    func testPiPRecoveryBeforeForegroundCancelsTheFallbackNavigation() {
        var policy = PlaybackPresentationPolicy()
        _ = policy.pictureInPictureChanged(active: true, possible: true, suspended: false)
        _ = policy.applicationDidEnterBackground()
        _ = policy.pictureInPictureChanged(active: true, possible: true, suspended: true)
        _ = policy.pictureInPictureChanged(active: true, possible: true, suspended: false)
        XCTAssertFalse(policy.applicationDidBecomeActive().restoreInlineVideo)
        XCTAssertEqual(policy.presentation, .pictureInPicture)
    }
}
