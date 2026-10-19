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
}
