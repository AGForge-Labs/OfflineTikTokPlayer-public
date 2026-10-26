import XCTest
@testable import PlayerCore

final class PlaybackWarmupOrderTests: XCTestCase {
    func testNextVideoWarmsBeforeTheAlreadyPlayingVideoAndHistory() {
        XCTAssertEqual(PlaybackWarmupOrder.ids(current: "current", previous: "previous", upcoming: ["next", "later"]),
                       ["next", "current", "previous", "later"])
    }
    func testRepeatedAndMissingNeighboursAreBoundedAndUnique() {
        XCTAssertEqual(PlaybackWarmupOrder.ids(current: "a", previous: "a", upcoming: ["b", "a", "b"]), ["b", "a"])
        XCTAssertEqual(PlaybackWarmupOrder.ids(current: "a", previous: nil, upcoming: []), ["a"])
        XCTAssertEqual(PlaybackWarmupOrder.ids(current: nil, previous: nil, upcoming: []), [])
    }
}
