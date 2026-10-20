import XCTest
import AVFoundation
@testable import OfflineTikTokPlayer

@MainActor
final class ContinuousAudioPlayerTests: XCTestCase {
    func testDecodeFailureUsesPendingSelectionOrActualNaturalSuccessor() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        for explicitSelection in [true, false] {
            let audio = ContinuousAudioPlayer()
            defer { audio.suspend(); audio.graph.engine.stop() }
            audio.setWindow(["a", "b"])
            let a = try await audio.prepare(id: "a", url: url, currentPriority: true)
            let b = try await audio.prepare(id: "b", url: url)
            try audio.graph.engine.enableManualRenderingMode(.offline, format: audio.graph.format, maximumFrameCount: 32)
            XCTAssertTrue(audio.select(id: "a"))
            try audio.setPlaying(true)
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.graph.format, frameCapacity: 32))
            XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
            if explicitSelection {
                XCTAssertTrue(audio.select(id: "b"))
                XCTAssertFalse(audio.invalidateForRetry(token: a.token), "A delayed old-current failure cannot cancel requested B")
                XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
                XCTAssertEqual(audio.snapshot.token, b.token)
                XCTAssertGreaterThan(audio.snapshot.frame, 0)
                XCTAssertTrue(audio.graph.engine.isRunning)
            } else {
                audio.follow(from: "a", to: "b")
                XCTAssertTrue(audio.select(id: "a", position: Double(a.frames - 1) / 48_000))
                XCTAssertEqual(try audio.graph.engine.renderOffline(3, to: output), .success)
                XCTAssertEqual(audio.snapshot.token, b.token)
                XCTAssertEqual(audio.selectedID, "a", "The natural boundary precedes the service poll")
                XCTAssertTrue(audio.invalidateForRetry(token: b.token), "The actual natural successor's failure must stop it")
                XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
                audio.settlePausedState()
                XCTAssertFalse(audio.graph.engine.isRunning)
            }
        }
    }

    func testInvalidatingAPendingSelectionLetsTheSilentEngineSettle() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let audio = ContinuousAudioPlayer()
        audio.setWindow(["a"])
        let entry = try await audio.prepare(id: "a", url: url, currentPriority: true)
        try audio.graph.engine.enableManualRenderingMode(.offline, format: audio.graph.format, maximumFrameCount: 32)
        XCTAssertTrue(audio.select(id: "a"))
        try audio.setPlaying(true)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.graph.format, frameCapacity: 32))
        XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
        _ = audio.seek(0.1)
        XCTAssertTrue(audio.isSelectionPending(in: audio.snapshot))
        XCTAssertTrue(audio.invalidateForRetry(token: entry.token))
        XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
        XCTAssertEqual(audio.snapshot.token, 0)
        XCTAssertFalse(audio.isSelectionPending(in: audio.snapshot))
        audio.settlePausedState()
        XCTAssertFalse(audio.graph.engine.isRunning)
    }

    func testNewCurrentEvictsANeighbourRatherThanWaitingForeverForOldCurrent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
            buffer.frameLength = 128
            for frame in 0..<128 { buffer.floatChannelData![0][frame] = 0.1; buffer.floatChannelData![1][frame] = -0.1 }
            try file.write(from: buffer)
        }
        let audio = ContinuousAudioPlayer()
        audio.setWindow(["a", "b", "c"])
        _ = try await audio.prepare(id: "b", url: url, currentPriority: true)
        _ = try await audio.prepare(id: "a", url: url)
        _ = try await audio.prepare(id: "c", url: url)
        XCTAssertTrue(audio.select(id: "b"))
        var sample = [Float](repeating: 0, count: 2)
        sample.withUnsafeMutableBufferPointer { audio.renderer.render(interleaved: $0, frameCount: 1) }
        audio.setWindow(["a", "d", "c"])
        let prepared = try await audio.prepare(id: "d", url: url, currentPriority: true)
        XCTAssertEqual(prepared.id, "d")
        XCTAssertEqual(audio.preparedCount, 3)
        XCTAssertTrue(audio.select(id: "d", position: 0.001))
        // The engine has not started: paused presentation still uses requested time.
        XCTAssertEqual(audio.presentationPosition(at: CMClockGetTime(CMClockGetHostTimeClock())), 0.001, accuracy: 0.000001)
        audio.trimWindow(preserving: "d")
        XCTAssertNotNil(audio.entry(for: "d"))
        try audio.graph.engine.enableManualRenderingMode(.offline, format: audio.graph.format, maximumFrameCount: 32)
        try audio.setPlaying(true)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.graph.format, frameCapacity: 32))
        XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
        audio.suspend()
        let pausedFrame = audio.snapshot.frame
        XCTAssertEqual(try audio.graph.engine.renderOffline(1, to: output), .success)
        audio.settlePausedState()
        XCTAssertFalse(audio.graph.engine.isRunning, "Explicit Pause must not leave a silent background engine running")
        XCTAssertEqual(audio.snapshot.frame, pausedFrame)
    }
}
