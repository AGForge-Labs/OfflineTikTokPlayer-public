import XCTest
import AVFoundation
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class ContinuousAudioGraphTests: XCTestCase {
    // A wrong interleaved/planar copy, stopped node, or delayed boundary inserts,
    // repeats or drops these independently specified samples.
    func testActualSourceNodeJoinsPreparedFramesInsideRenderBlocks() throws {
        for speaker in [false, true] {
            #if DEBUG
            let accounting = ContinuousPCMRenderer.DebugRenderAccountingRecorder()
            let renderer = ContinuousPCMRenderer(sampleRate: 48_000, channels: 2, prefixFrames: 16, ringFrames: 16,
                                                 debugRenderAccounting: accounting)
            #else
            let renderer = ContinuousPCMRenderer(sampleRate: 48_000, channels: 2, prefixFrames: 16, ringFrames: 16)
            #endif
            let first: [Float] = [0.1, -0.1, 0, 0, 0.2, -0.2]
            let second: [Float] = [0.3, -0.3, 0.4, -0.4]
            XCTAssertTrue(first.withUnsafeBufferPointer { renderer.source(at: 0).prepare(token: 1, totalFrames: 3, prefix: $0) })
            XCTAssertTrue(second.withUnsafeBufferPointer { renderer.source(at: 1).prepare(token: 2, totalFrames: 2, prefix: $0) })
            renderer.setSuccessor(token: 2, for: 1)
            renderer.setSuccessor(token: 1, for: 2)
            renderer.select(token: 1, frame: 0)
            renderer.setSpeakerEnabled(speaker)
            renderer.setPlaying(true)
            let graph = ContinuousAudioGraph(renderer: renderer)
            try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 512)
            try graph.engine.start()
            defer { graph.engine.stop() }
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: 512))
            var samples: [Float] = []
            for frames: AVAudioFrameCount in [1, 7, 2, 11, 4] {
                XCTAssertEqual(try graph.engine.renderOffline(frames, to: output), .success)
                let channels = try XCTUnwrap(output.floatChannelData)
                for frame in 0..<Int(frames) { samples.append(channels[0][frame]); samples.append(channels[1][frame]) }
            }
            var expected = Array(repeating: first + second, count: 5).flatMap { $0 }
            if speaker {
                let reference = SpeakerAudioProcessor(sampleRate: 48_000, channels: 2, enabled: true)
                expected.withUnsafeMutableBufferPointer { buffer in
                    for frame in 0..<25 { reference.process(UnsafeMutableBufferPointer(start: buffer.baseAddress!.advanced(by: frame * 2), count: 2)) }
                }
            }
            XCTAssertEqual(samples.count, expected.count)
            for (actual, wanted) in zip(samples, expected) { XCTAssertEqual(actual, wanted, accuracy: 0.000001) }
            XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
            #if DEBUG
            let value = try XCTUnwrap(accounting.snapshot())
            XCTAssertFalse(value.overflowed)
            XCTAssertGreaterThan(value.sourceCallbacksEntered, 0)
            XCTAssertEqual(value.sourceCallbacksEntered, value.sourceCallbacksCompleted)
            XCTAssertEqual(value.sourceFramesRequested, value.sourceFramesCompleted)
            XCTAssertEqual(value.sourceFramesCompleted, value.kernelFramesRequested)
            XCTAssertEqual(value.kernelCallsEntered, value.kernelCallsCompleted)
            XCTAssertEqual(value.kernelFramesRequested, value.kernelFramesClassified)
            XCTAssertEqual(value.copiedPCMFrames, value.kernelFramesClassified)
            XCTAssertGreaterThanOrEqual(value.copiedPCMFrames, 25)
            XCTAssertEqual(value.invalidLayoutCallbacks, 0); XCTAssertEqual(value.invalidLayoutFrames, 0)
            XCTAssertEqual(value.pausedPositiveTokenFrames, 0); XCTAssertEqual(value.inactiveFrames, 0)
            XCTAssertEqual(value.eofRemainderFrames, 0); XCTAssertEqual(value.underrunFrames, 0)
            #endif
        }
    }
}
