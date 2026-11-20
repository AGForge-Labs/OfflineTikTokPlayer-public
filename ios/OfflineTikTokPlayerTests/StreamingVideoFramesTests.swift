import AVFoundation
import QuartzCore
import XCTest
@testable import OfflineTikTokPlayer

@MainActor
final class StreamingVideoFramesTests: XCTestCase {
    func testLoopbackFramesFollowTheCurrentQueueItemWithoutAnItemVideoOutput() async throws {
        let bundle = Bundle(for: Self.self)
        let first = try XCTUnwrap(bundle.url(forResource: "test-selection-a", withExtension: "mp4"))
        let second = try XCTUnwrap(bundle.url(forResource: "test-motion-60", withExtension: "mp4"))
        let server = try HTTPPlaybackFixtureServer(files: ["/a.mp4": Data(contentsOf: first), "/b.mp4": Data(contentsOf: second)])
        let base = try await server.start()
        defer { server.stop() }
        let a = AVPlayerItem(url: base.appendingPathComponent("a.mp4"))
        let b = AVPlayerItem(url: base.appendingPathComponent("b.mp4"))
        let player = AVQueuePlayer()
        let frames = StreamingVideoFrames(player: player)
        defer { player.pause(); frames.cancel(); player.removeAllItems() }
        player.insert(a, after: nil)
        player.insert(b, after: a)
        player.automaticallyWaitsToMinimizeStalling = false
        player.playImmediately(atRate: 1)

        func checkFrames(_ selected: AVPlayerItem, excluding other: AVPlayerItem, width: Int, height: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            var firstPTS: CMTime?
            while ContinuousClock.now < deadline {
                let host = CACurrentMediaTime()
                XCTAssertNil(frames.frame(for: other, atHostTime: host))
                if let frame = frames.frame(for: selected, atHostTime: host) {
                    XCTAssertEqual(CVPixelBufferGetWidth(frame.pixel), width)
                    XCTAssertEqual(CVPixelBufferGetHeight(frame.pixel), height)
                    if let firstPTS, CMTimeSubtract(frame.position, firstPTS).seconds >= 0.08 {
                        XCTAssertTrue(player.currentItem === selected)
                        XCTAssertTrue(selected.outputs.isEmpty)
                        return
                    }
                    if firstPTS == nil { firstPTS = frame.position }
                }
                try await Task.sleep(for: .milliseconds(12))
            }
            XCTFail("Expected two current, advancing video frames from the actual HTTP queue")
        }

        try await checkFrames(a, excluding: b, width: 160, height: 96)
        player.advanceToNextItem()
        try await checkFrames(b, excluding: a, width: 128, height: 192)
        XCTAssertGreaterThan(server.snapshot().ranges, 0)
        frames.cancel()
        XCTAssertNil(player.videoOutput)
        XCTAssertNil(frames.frame(for: b, atHostTime: CACurrentMediaTime()))
    }

    func testACancelledOrReplacedOutputCannotDetachAnotherOwner() throws {
        let player = AVPlayer()
        let first = StreamingVideoFrames(player: player)
        let original = try XCTUnwrap(player.videoOutput)
        let other = StreamingVideoFrames(player: player)
        XCTAssertTrue(player.videoOutput === original)
        other.cancel()
        XCTAssertTrue(player.videoOutput === original)
        first.cancel()
        let replacement = StreamingVideoFrames(player: player)
        let installed = try XCTUnwrap(player.videoOutput)
        first.cancel()
        XCTAssertTrue(player.videoOutput === installed)
        replacement.cancel()
        XCTAssertNil(player.videoOutput)
    }
}
