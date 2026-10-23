import XCTest
@testable import PlayerCore

final class InitialPlaybackPollWindowTests: XCTestCase {
    func testRepeatedObservationsCannotExtendTheRequestWindow() {
        var window = InitialPlaybackPollWindow()
        XCTAssertEqual(window.milliseconds(request: 1, eligible: true, monotonicTime: 10), 16)
        XCTAssertEqual(window.milliseconds(request: 1, eligible: true, monotonicTime: 10.499), 16)
        XCTAssertEqual(window.milliseconds(request: 1, eligible: true, monotonicTime: 10.5), 33)
        XCTAssertEqual(window.milliseconds(request: 1, eligible: true, monotonicTime: 20), 33)
    }
    func testPauseOrDisabledVideoWithdrawsPermissionUntilANewRequest() {
        var window = InitialPlaybackPollWindow()
        XCTAssertEqual(window.milliseconds(request: 1, eligible: true, monotonicTime: 10), 16)
        window.withdraw(request: 1) // A pause and resume may both happen between observations.
        XCTAssertEqual(window.milliseconds(request: 1, eligible: true, monotonicTime: 10.2), 33)
        XCTAssertEqual(window.milliseconds(request: 2, eligible: true, monotonicTime: 10.3), 16)
        XCTAssertEqual(window.milliseconds(request: 2, eligible: false, monotonicTime: 10.4), 33)
        XCTAssertNil(window.snapshot.start); XCTAssertNil(window.snapshot.deadline)
        XCTAssertEqual(window.milliseconds(request: 2, eligible: true, monotonicTime: 10.45), 33)
        window.withdraw(request: 3) // Selection and pause can both precede its first poll.
        XCTAssertEqual(window.milliseconds(request: 3, eligible: true, monotonicTime: 10.46), 33)
        XCTAssertEqual(window.milliseconds(request: 4, eligible: true, monotonicTime: 10.47), 16)
    }
    func testRapidSelectionKeepsOnlyTheLatestRequestAndRejectsStaleObservations() {
        var window = InitialPlaybackPollWindow()
        for request in 1...100 {
            XCTAssertEqual(window.milliseconds(request: request, eligible: true,
                monotonicTime: Double(request) / 100), 16)
        }
        XCTAssertEqual(window.milliseconds(request: 99, eligible: true, monotonicTime: 1.1), 33)
        XCTAssertEqual(window.milliseconds(request: 100, eligible: true, monotonicTime: 1.49), 16)
        XCTAssertEqual(window.milliseconds(request: 100, eligible: true, monotonicTime: 1.5), 33)
    }
    func testInvalidRequestsAndClocksCannotStartOrRenewAWindow() {
        var window = InitialPlaybackPollWindow()
        for now in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(window.milliseconds(request: 1, eligible: true, monotonicTime: now), 33)
        }
        XCTAssertEqual(window.milliseconds(request: 0, eligible: true, monotonicTime: 1), 33)
        XCTAssertEqual(window.milliseconds(request: 1, eligible: true, monotonicTime: 1), 16)
        XCTAssertEqual(window.milliseconds(request: 1, eligible: true, monotonicTime: 0.9), 33)
        XCTAssertEqual(window.milliseconds(request: 1, eligible: true, monotonicTime: 1.5), 33)
    }
}
