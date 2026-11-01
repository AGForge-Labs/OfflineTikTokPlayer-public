import XCTest
@testable import PlayerCore

final class VideoImageIdentityTests: XCTestCase {
    func testWrapperAddressReuseCannotOverrideAConflictingSurfaceIdentity() {
        for source in UInt32(1)...16 {
            for displayed in UInt32(1)...16 where source != displayed {
                XCTAssertFalse(VideoImageIdentity.matches(sourceSurface: source, displayedSurface: displayed,
                    sameRetainedBuffer: true), "A recycled wrapper address cannot credit the departing surface")
            }
        }
        XCTAssertFalse(VideoImageIdentity.matches(sourceSurface: 0, displayedSurface: 0, sameRetainedBuffer: true))
        XCTAssertFalse(VideoImageIdentity.matches(sourceSurface: 7, displayedSurface: nil, sameRetainedBuffer: true))
        XCTAssertTrue(VideoImageIdentity.matches(sourceSurface: 7, displayedSurface: 7, sameRetainedBuffer: false))
        XCTAssertTrue(VideoImageIdentity.matches(sourceSurface: nil, displayedSurface: nil, sameRetainedBuffer: true))
        XCTAssertFalse(VideoImageIdentity.matches(sourceSurface: nil, displayedSurface: nil, sameRetainedBuffer: false))
    }
}
