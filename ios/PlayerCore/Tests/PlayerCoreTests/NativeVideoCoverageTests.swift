import XCTest
@testable import PlayerCore

final class NativeVideoCoverageTests: XCTestCase {
    func testOrdinarySubframeAudioTailsDoNotForceVideoThroughACompositor() {
        for (end, asset, frame) in [(24.424424, 24.427007, 1.0 / 29.97),
                                    (6965.0 / 60, 1161.0 / 10, 1.0 / 60),
                                    (15.0, 15.020998, 1.0 / 30)] {
            XCTAssertTrue(NativeVideoCoverage.allowsNativePresentation(start: 0, end: end,
                assetDuration: asset, frameDuration: frame), "Preserve the full audio tail and native video range")
        }
    }
    func testExactCoverageStillWorksWithoutCadenceMetadata() {
        XCTAssertTrue(NativeVideoCoverage.allowsNativePresentation(start: 0, end: 6,
            assetDuration: 6, frameDuration: .nan))
    }
    func testLeadingEditsOverrunAndLongAudioTailsKeepTheirConservativePath() {
        for (start, end, asset, frame) in [(0.1, 6.0, 6.0, 1.0 / 60),
                                          (0, 6, 5.9, 1.0 / 60),
                                          (0, 6, 6.1, 1.0 / 30),
                                          (0, 6, 6.081, 0.2),
                                          (0, 0, 1, 1.0 / 30),
                                          (0, 6, 6.01, 0)] {
            XCTAssertFalse(NativeVideoCoverage.allowsNativePresentation(start: start, end: end,
                assetDuration: asset, frameDuration: frame))
        }
    }
    func testNonfiniteTimingNeverQualifiesAFramePath() {
        XCTAssertFalse(NativeVideoCoverage.allowsNativePresentation(start: .nan, end: 6,
            assetDuration: 6, frameDuration: 1.0 / 60))
        XCTAssertFalse(NativeVideoCoverage.allowsNativePresentation(start: 0, end: .infinity,
            assetDuration: 6, frameDuration: 1.0 / 60))
    }
}
