import XCTest
@testable import PlayerCore

final class VideoImageIdentityTests: XCTestCase {
    func testEvenAMatchingSurfaceCannotProveAQueuedFuturePresentation() {
        XCTAssertFalse(VideoImageIdentity.isPresented(sourceSurface: 7, displayedSurface: 7,
            sameRetainedBuffer: false, framePosition: 1.5, presentationPosition: 0))
        XCTAssertTrue(VideoImageIdentity.isPresented(sourceSurface: 7, displayedSurface: 7,
            sameRetainedBuffer: false, framePosition: 1.5, presentationPosition: 1.5))
        XCTAssertTrue(VideoImageIdentity.isPresented(sourceSurface: 7, displayedSurface: 7,
            sameRetainedBuffer: false, framePosition: 1.4, presentationPosition: 1.5))
        XCTAssertFalse(VideoImageIdentity.isPresented(sourceSurface: 7, displayedSurface: 19,
            sameRetainedBuffer: true, framePosition: 1.4, presentationPosition: 1.5))
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(VideoImageIdentity.isPresented(sourceSurface: 7, displayedSurface: 7,
                sameRetainedBuffer: false, framePosition: invalid, presentationPosition: 1.5))
            XCTAssertFalse(VideoImageIdentity.isPresented(sourceSurface: 7, displayedSurface: 7,
                sameRetainedBuffer: false, framePosition: 1.5, presentationPosition: invalid))
        }
    }

    func testWrapperAddressReuseCannotOverrideAConflictingSurfaceIdentity() {
        for (source, displayed): (UInt32, UInt32) in [(7, 19), (19, 7), (.max, 1)] {
            XCTAssertFalse(VideoImageIdentity.matches(sourceSurface: source, displayedSurface: displayed,
                sameRetainedBuffer: true), "A recycled wrapper address cannot credit the departing surface")
        }
        XCTAssertFalse(VideoImageIdentity.matches(sourceSurface: 0, displayedSurface: 0, sameRetainedBuffer: true))
        XCTAssertFalse(VideoImageIdentity.matches(sourceSurface: 7, displayedSurface: nil, sameRetainedBuffer: true))
        XCTAssertTrue(VideoImageIdentity.matches(sourceSurface: 7, displayedSurface: 7, sameRetainedBuffer: false))
        XCTAssertTrue(VideoImageIdentity.matches(sourceSurface: nil, displayedSurface: nil, sameRetainedBuffer: true))
        XCTAssertFalse(VideoImageIdentity.matches(sourceSurface: nil, displayedSurface: nil, sameRetainedBuffer: false))
    }
}
