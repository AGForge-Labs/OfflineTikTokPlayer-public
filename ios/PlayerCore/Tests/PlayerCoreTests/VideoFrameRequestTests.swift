import XCTest
@testable import PlayerCore

final class VideoFrameRequestTests: XCTestCase {
    func testVariableRateBurstsHaveEnoughPullsAndTimestampNoiseCannotDemandExtremeRates() {
        XCTAssertEqual(VideoFrameRequest.sourceRate(nominal: 30, minimumFrameDuration: 1.0 / 120), 120)
        XCTAssertEqual(VideoFrameRequest.sourceRate(nominal: 59.94, minimumFrameDuration: 1.0 / 60), 59.94)
        XCTAssertEqual(VideoFrameRequest.sourceRate(nominal: 24, minimumFrameDuration: 1.0 / 90000), 24)
        XCTAssertEqual(VideoFrameRequest.sourceRate(nominal: .nan, minimumFrameDuration: 1.0 / 60), 60)
        XCTAssertEqual(VideoFrameRequest.sourceRate(nominal: .nan, minimumFrameDuration: .nan), 30)
    }

    func testDisplayCadenceAvoidsAlternatingFrameHoldsOnProMotion() {
        // Quantize actual source timestamps to the refreshes at which they can appear.
        func holdSpread(source: Double, maximum: Int) -> Double {
            let rate = VideoFrameRequest.displayRate(source: source, maximum: maximum)
            let ticks = (0...120).map { (Double($0) * rate / source - 1e-9).rounded(.up) / rate }
            let holds = zip(ticks.dropFirst(), ticks).map { $0 - $1 }
            return holds.max()! - holds.min()!
        }
        for fps in [24.0, 30, 40, 48, 60, 120] {
            XCTAssertLessThan(holdSpread(source: fps, maximum: 120), 0.00001, "Uneven holds at \(fps) fps")
        }
        for fps in [25.0, 50] {
            XCTAssertLessThanOrEqual(holdSpread(source: fps, maximum: 120), 0.00834)
        }
        XCTAssertEqual(VideoFrameRequest.displayRate(source: 23.976, maximum: 120), 48)
        XCTAssertEqual(VideoFrameRequest.displayRate(source: 59.94, maximum: 120), 60)
        XCTAssertEqual(VideoFrameRequest.displayRate(source: 120, maximum: 60), 60)
        XCTAssertEqual(VideoFrameRequest.displayRate(source: .nan, maximum: 120), 60)
    }

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
