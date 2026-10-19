import XCTest
@testable import PlayerCore

final class PlaybackPageTests: XCTestCase {
    func testIncomingPageKeepsItsIdentityAfterItBecomesCurrent() {
        var queue = PlaybackQueue(ids: ["a", "b", "c", "d"])
        let incoming = queue.feedWindow.next
        queue.next()
        XCTAssertEqual(queue.feedWindow.current?.mediaID, "b")
        XCTAssertEqual(queue.feedWindow.current?.id, incoming?.id,
                       "Settling a swipe must not replace the visible page with a different view identity.")
    }

    func testPreviousAndForwardHistoryKeepTheSamePageIdentities() {
        var queue = PlaybackQueue(ids: ["a", "b", "c", "d"], shuffle: true, seed: 30)
        let first = queue.feedWindow.current
        queue.next()
        let second = queue.feedWindow.current
        XCTAssertEqual(queue.feedWindow.previous?.id, first?.id)
        queue.previous()
        XCTAssertEqual(queue.feedWindow.current?.id, first?.id)
        XCTAssertEqual(queue.feedWindow.next?.id, second?.id)
        queue.next()
        XCTAssertEqual(queue.feedWindow.current?.id, second?.id)
    }

    func testRepeatedVideoHasDistinctVisitsWithoutChangingTheArrivingPage() {
        var queue = PlaybackQueue(ids: ["a"])
        queue.repeatMode = .all
        let incoming = queue.feedWindow.next
        queue.next()
        let window = queue.feedWindow
        XCTAssertEqual(window.current?.id, incoming?.id)
        XCTAssertEqual(window.pages.map(\.mediaID), ["a", "a", "a"])
        XCTAssertEqual(Set(window.pages.map(\.id)).count, 3)
    }

    func testShuffleChangeAndLookaheadDoNotReplaceOrConsumeTheCurrentVisit() {
        var queue = PlaybackQueue(ids: ["a", "b", "c", "d"])
        queue.next()
        let current = queue.feedWindow.current
        queue.setShuffle(true)
        XCTAssertEqual(queue.feedWindow.current, current)
        let upcoming = queue.feedWindow.next
        for _ in 0..<100 { XCTAssertEqual(queue.feedWindow.next, upcoming) }
        queue.next()
        XCTAssertEqual(queue.feedWindow.current, upcoming)
    }

    func testFeedWindowStaysBoundedForLargeQueuesAndHasNoFakeBoundaryPage() {
        var queue = PlaybackQueue(ids: (0..<6_212).map(String.init))
        XCTAssertEqual(queue.feedWindow.pages.map(\.mediaID), ["0", "1"])
        for _ in 0..<50 { queue.next() }
        XCTAssertEqual(queue.feedWindow.pages.map(\.mediaID), ["49", "50", "51"])
        XCTAssertEqual(queue.feedWindow.pages.count, 3)
        XCTAssertTrue(PlaybackQueue(ids: []).feedWindow.pages.isEmpty)
        XCTAssertNil(PlaybackQueue(ids: ["only"]).feedWindow.next)
    }

    func testSettlingAGestureCannotSkipAgainAfterAHeadphoneOrFailedLoadChangedTheVideo() {
        var queue = PlaybackQueue(ids: ["a", "b"])
        let dragging = queue.feedWindow
        queue.next()
        XCTAssertEqual(dragging.settledDirection(at: dragging.next?.id, currentWindow: queue.feedWindow), 0)
        XCTAssertEqual(queue.feedWindow.settledDirection(at: queue.feedWindow.previous?.id, currentWindow: queue.feedWindow), -1)
    }

    func testCancelledAndBoundaryGesturesDoNotAdvanceTheQueue() {
        let window = PlaybackQueue(ids: ["only"]).feedWindow
        XCTAssertEqual(window.settledDirection(at: nil, currentWindow: window), 0)
        XCTAssertEqual(window.settledDirection(at: window.current?.id, currentWindow: window), 0)
        let pair = PlaybackQueue(ids: ["a", "b"]).feedWindow
        XCTAssertEqual(pair.settledDirection(at: pair.next?.id, currentWindow: pair), 1)
    }

    func testAnObsoletePreviewCannotBeCommittedAfterTheNextVideoBecomesUnavailable() {
        var queue = PlaybackQueue(ids: ["a", "b", "c"])
        let dragging = queue.feedWindow
        queue.markUnavailable("b")
        XCTAssertEqual(dragging.settledDirection(at: dragging.next?.id, currentWindow: queue.feedWindow), 0)
        XCTAssertEqual(queue.currentID, "a")
    }
}
