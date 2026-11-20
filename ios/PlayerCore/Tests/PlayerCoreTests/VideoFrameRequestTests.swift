import XCTest
@testable import PlayerCore

final class VideoFrameRequestTests: XCTestCase {
    func testAValidNativeClockLeadCannotConsumeOnlyUndisplayableFutureFrames() {
        XCTAssertFalse(VideoFrameRequest.usesNativeDeadline(presentation: 1, mapped: 1.055))
        XCTAssertFalse(VideoFrameRequest.usesNativeDeadline(presentation: 1, mapped: 1.040))
        XCTAssertTrue(VideoFrameRequest.usesNativeDeadline(presentation: 1, mapped: 1.015))
        XCTAssertTrue(VideoFrameRequest.usesNativeDeadline(presentation: 1, mapped: 0.975))
    }
    func testUnmappedAndUnrelatedTimelinesUseTheSelectedPresentationClock() {
        XCTAssertFalse(VideoFrameRequest.usesNativeDeadline(presentation: 1, mapped: .nan))
        XCTAssertFalse(VideoFrameRequest.usesNativeDeadline(presentation: .infinity, mapped: 1))
        XCTAssertFalse(VideoFrameRequest.usesNativeDeadline(presentation: 1, mapped: -0.5))
        XCTAssertFalse(VideoFrameRequest.usesNativeDeadline(presentation: 1, mapped: 0.5))
    }
}
