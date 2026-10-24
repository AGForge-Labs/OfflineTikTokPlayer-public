import XCTest
@testable import PlayerCore

final class AudioFilePresentationTests: XCTestCase {
    func testFullAACSegmentAgreesWithCodecPrimingAndValidFrames() {
        let layout = AudioFilePresentation(sourceStart: 1_024, sourceFrames: 1_440_000,
            targetStart: 0, targetFrames: 1_440_000)
        XCTAssertTrue(layout.matches(primingFrames: 1_024, validFrames: 1_440_000, presentationFrames: 1_440_000))
    }

    func testContentEditsOffsetsAndIncompleteMetadataAreRejected() {
        let full = AudioFilePresentation(sourceStart: 1_024, sourceFrames: 1_440_000,
            targetStart: 0, targetFrames: 1_440_000)
        let cases: [(String, AudioFilePresentation, Int64, Int64, Int64)] = [
            ("content crop", .init(sourceStart: 241_024, sourceFrames: 1_440_000, targetStart: 0, targetFrames: 1_440_000), 1_024, 1_440_000, 1_440_000),
            ("leading presentation silence", .init(sourceStart: 1_024, sourceFrames: 1_440_000, targetStart: 4_800, targetFrames: 1_440_000), 1_024, 1_440_000, 1_444_800),
            ("short source", .init(sourceStart: 1_024, sourceFrames: 1_439_999, targetStart: 0, targetFrames: 1_440_000), 1_024, 1_440_000, 1_440_000),
            ("scaled target", .init(sourceStart: 1_024, sourceFrames: 1_440_000, targetStart: 0, targetFrames: 1_439_999), 1_024, 1_440_000, 1_440_000),
            ("unknown priming", full, -1, 1_440_000, 1_440_000),
            ("different priming", full, 0, 1_440_000, 1_440_000),
            ("missing valid frames", full, 1_024, 0, 1_440_000),
            ("different complete endpoint", full, 1_024, 1_440_000, 1_440_001),
            ("empty presentation", full, 1_024, 1_440_000, 0)
        ]
        for (name, layout, priming, valid, presentation) in cases {
            XCTAssertFalse(layout.matches(primingFrames: priming, validFrames: valid, presentationFrames: presentation), name)
        }
    }
}
