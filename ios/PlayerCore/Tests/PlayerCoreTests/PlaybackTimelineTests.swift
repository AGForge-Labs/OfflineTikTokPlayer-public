import XCTest
@testable import PlayerCore

final class PlaybackTimelineTests: XCTestCase {
    func testOldTicksCannotPullTheThumbBackDuringASeek() throws {
        var clock = PlaybackTimeline()
        clock.reset(position: 12, duration: 120)
        let seek = try XCTUnwrap(clock.beginSeek(to: 80))
        clock.sample(position: 12.5)
        XCTAssertEqual(clock.position, 80)
        XCTAssertTrue(clock.completeSeek(seek, actualPosition: 80.02))
        clock.sample(position: 80.08)
        XCTAssertEqual(clock.position, 80.08)
    }

    func testInterruptedSeekCompletionCannotOverwriteTheLatestTarget() throws {
        var clock = PlaybackTimeline()
        clock.reset(position: 10, duration: 100)
        let first = try XCTUnwrap(clock.beginSeek(to: 60))
        let second = try XCTUnwrap(clock.beginSeek(to: 30))
        XCTAssertFalse(clock.completeSeek(first, actualPosition: 11))
        XCTAssertEqual(clock.position, 30)
        XCTAssertTrue(clock.completeSeek(second, actualPosition: 30.01))
        XCTAssertEqual(clock.position, 30.01)
    }

    func testChangingVideoInvalidatesItsPendingSeek() throws {
        var clock = PlaybackTimeline()
        clock.reset(position: 10, duration: 100)
        let old = try XCTUnwrap(clock.beginSeek(to: 90))
        clock.reset(position: 0, duration: 20)
        XCTAssertFalse(clock.completeSeek(old, actualPosition: 90))
        XCTAssertEqual(clock.position, 0)
        XCTAssertEqual(clock.duration, 20)
    }

    func testActualDurationAndFiniteSamplesBoundTheDisplayedPosition() throws {
        var clock = PlaybackTimeline()
        clock.reset(position: 40, duration: 100)
        clock.updateDuration(30)
        XCTAssertEqual(clock.position, 30)
        XCTAssertNil(clock.beginSeek(to: .nan))
        clock.sample(position: .infinity)
        XCTAssertEqual(clock.position, 30)
        let seek = try XCTUnwrap(clock.beginSeek(to: -5))
        XCTAssertEqual(seek.target, 0)
        XCTAssertTrue(clock.completeSeek(seek, actualPosition: 0))
        XCTAssertEqual(clock.position, 0)
    }

    func testStartingToDragDoesNotOverwriteTheFirstSliderValue() {
        var scrub = PlaybackScrub()
        scrub.update(70, mediaID: "first")
        scrub.begin(mediaID: "first", position: 10)
        XCTAssertEqual(scrub.position, 70)
        XCTAssertEqual(scrub.finish(mediaID: "first"), 70)
        XCTAssertNil(scrub.position)
    }

    func testDragCannotSeekAnotherVideoAfterASwipe() {
        var scrub = PlaybackScrub()
        scrub.begin(mediaID: "first", position: 10)
        scrub.update(70, mediaID: "first")
        XCTAssertNil(scrub.finish(mediaID: "second"))
        XCTAssertNil(scrub.position)
        scrub.begin(mediaID: "second", position: 0)
        XCTAssertEqual(scrub.finish(mediaID: "second"), 0)
    }

    func testVideoCorrectionTargetsAudioAfterTheNativeReadReturns() throws {
        var audio = 0.8939155833357972
        var nativeReads = 0
        let target = PlaybackTimeline.videoCorrectionTarget(force: false, readVideoPosition: {
            nativeReads += 1
            audio = 1.344 // Audio progressed while the opaque native read was in flight.
            return 1.0
        }, readAudioPosition: { audio }, isCurrent: { true })
        XCTAssertEqual(try XCTUnwrap(target), 1.344, accuracy: 0.5 / 48_000)
        XCTAssertEqual(nativeReads, 1)
    }

    func testVideoCorrectionDoesNotSeekFromAnAgedFalsePositive() {
        var audio = 0.9
        var nativeReads = 0
        let target = PlaybackTimeline.videoCorrectionTarget(force: false, readVideoPosition: {
            nativeReads += 1
            audio = 1.0
            return 1.0
        }, readAudioPosition: { audio }, isCurrent: { true })
        XCTAssertNil(target)
        XCTAssertEqual(nativeReads, 1)
    }

    func testForcedPausedVideoCorrectionUsesTheLatestTargetWithoutANativeRead() throws {
        var pendingAudioTarget = 0.75
        var nativeReads = 0
        let target = PlaybackTimeline.videoCorrectionTarget(force: true, readVideoPosition: {
            nativeReads += 1
            XCTFail("A forced paused/restored correction must not query native position")
            return 0
        }, readAudioPosition: {
            pendingAudioTarget = 2.25
            return pendingAudioTarget
        }, isCurrent: { true })
        XCTAssertEqual(try XCTUnwrap(target), 2.25)
        XCTAssertEqual(nativeReads, 0)
    }

    func testVideoCorrectionRejectsOwnersChangedDuringEitherPositionRead() {
        var owner = 1
        var audioReads = 0
        var nativeReads = 0
        let alreadyChanged = PlaybackTimeline.videoCorrectionTarget(force: false,
            readVideoPosition: {
                nativeReads += 1
                return 1.0
            }, readAudioPosition: {
                audioReads += 1
                return 0.9
            }, isCurrent: { false })
        XCTAssertNil(alreadyChanged)
        XCTAssertEqual(nativeReads, 0)
        XCTAssertEqual(audioReads, 0)

        let afterVideo = PlaybackTimeline.videoCorrectionTarget(force: false, readVideoPosition: {
            owner = 2
            return 1.0
        }, readAudioPosition: {
            audioReads += 1
            return 0.9
        }, isCurrent: { owner == 1 })
        XCTAssertNil(afterVideo)
        XCTAssertEqual(audioReads, 0)

        owner = 1
        let afterAudio = PlaybackTimeline.videoCorrectionTarget(force: false,
            readVideoPosition: { 1.0 }, readAudioPosition: {
                owner = 2
                return 1.5
            }, isCurrent: { owner == 1 })
        XCTAssertNil(afterAudio)
    }

    func testVideoCorrectionRetainsTheExistingDriftThresholdAndFallback() throws {
        XCTAssertNil(PlaybackTimeline.videoCorrectionTarget(force: false,
            readVideoPosition: { 1.04 }, readAudioPosition: { 1.0 }, isCurrent: { true }))
        let drift = PlaybackTimeline.videoCorrectionTarget(force: false,
            readVideoPosition: { 1.16 }, readAudioPosition: { 1.0 }, isCurrent: { true })
        XCTAssertEqual(try XCTUnwrap(drift), 1.0)
    }
}
