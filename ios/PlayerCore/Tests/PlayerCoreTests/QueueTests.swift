import XCTest
@testable import PlayerCore

final class QueueTests: XCTestCase {
    func testOpeningAMiddlePlaylistItemAllowsPreviousContextAndForwardReturn() {
        var queue = PlaybackQueue(ids: ["a", "b", "c", "d"], startAt: "c")
        let window = queue.feedWindow
        XCTAssertEqual(window.previous?.mediaID, "b")
        XCTAssertEqual(window.current?.id, "0:c")
        XCTAssertEqual(queue.previous(), "b")
        XCTAssertEqual(queue.feedWindow.current?.id, window.previous?.id)
        XCTAssertEqual(queue.previous(), "a")
        XCTAssertNil(queue.previous())
        XCTAssertEqual(queue.next(), "b")
        XCTAssertEqual(queue.next(), "c")
        XCTAssertEqual(queue.next(), "d")
        XCTAssertNil(queue.next())
    }

    func testExplicitSelectionRetainsContextWithShuffleAndOnlyConsumesVisitedContext() {
        var queue = PlaybackQueue(ids: ["a", "b", "c", "d", "e"], startAt: "c", shuffle: true, seed: 20)
        XCTAssertEqual(queue.previewPrevious(), "b")
        XCTAssertEqual(queue.previous(), "b")
        XCTAssertEqual(queue.next(), "c")
        var rest: [String] = []
        while let next = queue.next() { rest.append(next) }
        XCTAssertEqual(rest.count, 3)
        XCTAssertEqual(Set(rest), ["a", "d", "e"])
    }

    func testSelectedContextSurvivesBookmarkAndSkipsUnavailablePredecessors() throws {
        var queue = PlaybackQueue(ids: ["a", "b", "c", "d"], startAt: "c")
        queue.markUnavailable("b")
        XCTAssertEqual(queue.previewPrevious(), "a")
        let raw = try JSONEncoder().encode(PlaybackBookmark(queue: queue, position: 3))
        var restored = try PlaybackBookmark.restore(raw, availableIDs: ["a", "c", "d"]).queue
        XCTAssertEqual(restored.currentID, "c")
        XCTAssertEqual(restored.previous(), "a")
        XCTAssertEqual(restored.next(), "c")
        try restored.validate()
    }

    func testLegacyBookmarkWithoutVisitOffsetStillRestores() throws {
        let bookmark = PlaybackBookmark(queue: PlaybackQueue(ids: ["a", "b"]), position: 2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bookmark)) as? [String: Any])
        var queue = try XCTUnwrap(object["queue"] as? [String: Any])
        queue.removeValue(forKey: "historyVisitOffset"); object["queue"] = queue
        let restored = try PlaybackBookmark.restore(JSONSerialization.data(withJSONObject: object), availableIDs: ["a", "b"])
        XCTAssertEqual(restored.queue.currentID, "a")
        XCTAssertEqual(restored.queue.feedWindow.current?.id, "0:a")
    }

    func testStartingShuffleRandomizesTheFirstItemUnlessOneWasSelected() {
        let ids = ["a", "b", "c", "d"]
        let starts = Set((0..<32).compactMap { seed in
            PlaybackQueue(ids: ids, shuffle: true, seed: UInt64(seed)).currentID
        })
        XCTAssertGreaterThan(starts.count, 1, "Shuffle must not always start with the first playlist item.")
        XCTAssertTrue(starts.isSubset(of: Set(ids)))
        for seed in 0..<32 {
            let selected = PlaybackQueue(ids: ids, startAt: "c", shuffle: true, seed: UInt64(seed))
            XCTAssertEqual(selected.currentID, "c", "An explicitly selected video must still start first.")
        }
        XCTAssertEqual(PlaybackQueue(ids: ids).currentID, "a")
        XCTAssertNil(PlaybackQueue(ids: [], shuffle: true).currentID)
    }

    func testShuffleExhaustsUniqueItemsThenStops() {
        let ids = (0..<500).map(String.init)
        var queue = PlaybackQueue(ids: ids + ids, shuffle: true, seed: 42)
        var played = [queue.currentID!]
        while let next = queue.next() { played.append(next) }
        XCTAssertEqual(played.count, 500)
        XCTAssertEqual(Set(played), Set(ids))
    }

    func testEnablingShuffleAfterStartingInMiddleIncludesEarlierUnplayedItems() {
        var queue = PlaybackQueue(ids: ["a", "b", "c", "d", "e"], startAt: "c")
        XCTAssertEqual(queue.currentID, "c")
        XCTAssertEqual(queue.next(), "d")
        queue.setShuffle(true)
        XCTAssertEqual(queue.currentID, "d")
        var remaining = [String]()
        while let next = queue.next() { remaining.append(next) }
        XCTAssertEqual(remaining.count, 3)
        XCTAssertEqual(Set(remaining), Set(["a", "b", "e"]))
    }

    func testPreviousUsesHistoryAndNextReplaysForwardHistory() {
        var queue = PlaybackQueue(ids: ["a", "b", "c", "d"], shuffle: true, seed: 18)
        let first = queue.currentID
        let second = queue.next()
        let third = queue.next()
        XCTAssertEqual(queue.previous(), second)
        XCTAssertEqual(queue.previous(), first)
        XCTAssertNil(queue.previous())
        XCTAssertEqual(queue.next(), second)
        XCTAssertEqual(queue.next(), third)
        XCTAssertNotEqual(queue.next(), third)
    }

    func testShuffleTogglesPreserveCurrentAndDoNotRepeatConsumedItems() {
        var queue = PlaybackQueue(ids: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(queue.next(), "b")
        queue.setShuffle(true)
        XCTAssertEqual(queue.currentID, "b")
        let third = queue.next()!
        queue.setShuffle(false)
        XCTAssertEqual(queue.currentID, third)
        var rest = [String]()
        while let next = queue.next() { rest.append(next) }
        XCTAssertEqual(Set(rest), Set(["a", "b", "c", "d", "e"]).subtracting(["a", "b", third]))
    }

    func testRepeatOneLoopsAutomaticallyButExplicitSkipAndPreviousWork() {
        var queue = PlaybackQueue(ids: ["a", "b", "c"])
        queue.repeatMode = .one
        XCTAssertEqual(queue.next(explicit: false), "a")
        XCTAssertEqual(queue.next(), "b")
        XCTAssertEqual(queue.next(explicit: false), "b")
        XCTAssertEqual(queue.previous(), "a")
        XCTAssertEqual(queue.next(), "b")
    }

    func testRepeatAllStartsANewCycleAndSingleItemTerminatesOrLoopsCorrectly() {
        var queue = PlaybackQueue(ids: ["a", "b", "c"], shuffle: true, seed: 1)
        queue.repeatMode = .all
        var cycle = [queue.currentID!]
        cycle += (0..<2).map { _ in queue.next()! }
        let boundary = queue.next()!
        XCTAssertNotEqual(boundary, cycle.last)
        let nextCycle = [boundary, queue.next()!, queue.next()!]
        XCTAssertEqual(Set(nextCycle), Set(cycle))
        var one = PlaybackQueue(ids: ["only"])
        XCTAssertNil(one.next())
        one.repeatMode = .all
        XCTAssertEqual(one.next(), "only")
        var empty = PlaybackQueue(ids: [])
        empty.repeatMode = .all
        XCTAssertNil(empty.next())
        XCTAssertNil(empty.previous())
    }

    func testUnavailableItemsCannotTrapRepeatOneOrAnOfflineQueue() {
        var queue = PlaybackQueue(ids: ["missing", "local", "expired"])
        queue.repeatMode = .one
        queue.markUnavailable("missing")
        queue.markUnavailable("expired")
        XCTAssertEqual(queue.next(explicit: false), "local")
        queue.markUnavailable("local")
        XCTAssertNil(queue.next())
    }

    func testBookmarkRestoresPositionPausedAndFiltersMissingCopies() throws {
        var queue = PlaybackQueue(ids: ["a", "b", "c"], shuffle: true, seed: 9)
        _ = queue.next()
        let current = queue.currentID!
        let bookmark = PlaybackBookmark(queue: queue, position: 12.5)
        let raw = try JSONEncoder().encode(bookmark)
        let restored = try PlaybackBookmark.restore(raw, availableIDs: [current])
        XCTAssertEqual(restored.queue.currentID, current)
        XCTAssertEqual(restored.position, 12.5)
        XCTAssertFalse(restored.shouldAutoplay)
        var restoredQueue = restored.queue
        XCTAssertNil(restoredQueue.next())
    }

    func testPreviewDoesNotConsumeQueueOrRandomState() {
        var queue = PlaybackQueue(ids: ["a", "b", "c"], shuffle: true, seed: 19)
        let preview = queue.previewNext()
        XCTAssertEqual(queue.previewNext(), preview)
        XCTAssertEqual(queue.next(), preview)
    }
}
