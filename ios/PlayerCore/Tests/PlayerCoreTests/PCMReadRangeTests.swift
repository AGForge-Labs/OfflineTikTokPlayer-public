import XCTest
@testable import PlayerCore

final class PCMReadRangeTests: XCTestCase {
    func testInitialAndRetainedHeadReadsKeepTheirOriginalHistory() {
        for frame: Int64 in [0, 1, 48_000, 96_000] {
            XCTAssertEqual(PCMReadRange.startFrame(requestedFrame: frame, nativeSampleRate: 48_000), 0)
        }
    }

    func testDistant48kSeekKeepsTwoSecondsOfPrerollInsteadOfReadingFromZero() {
        XCTAssertEqual(PCMReadRange.startFrame(requestedFrame: 28 * 48_000, nativeSampleRate: 48_000), 26 * 48_000)
        XCTAssertEqual(PCMReadRange.startFrame(requestedFrame: 96_001, nativeSampleRate: 48_000), 1)
    }

    func testSampleRateConversionRetainsItsFullPhaseHistory() {
        for rate in [8_000.0, 44_100, 96_000, 0, -.infinity, .infinity, .nan] {
            XCTAssertEqual(PCMReadRange.startFrame(requestedFrame: 119 * 48_000, nativeSampleRate: rate), 0)
        }
    }

    func testInvalidAndExtremeRequestsDoNotOverflow() {
        XCTAssertEqual(PCMReadRange.startFrame(requestedFrame: .min, nativeSampleRate: 48_000), 0)
        XCTAssertEqual(PCMReadRange.startFrame(requestedFrame: -1, nativeSampleRate: 48_000), 0)
        XCTAssertEqual(PCMReadRange.startFrame(requestedFrame: .max, nativeSampleRate: 48_000), Int64.max - 96_000)
    }
}
