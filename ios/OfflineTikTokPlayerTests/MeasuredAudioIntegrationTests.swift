import XCTest
import AVFoundation
import AudioToolbox
import MediaToolbox
@testable import OfflineTikTokPlayer

@MainActor
final class MeasuredAudioIntegrationTests: XCTestCase {
    func testNativeAudioMixPassesEachItemsMeasuredGainToItsActualTap() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let quiet = AVPlayerItem(url: url), loud = AVPlayerItem(url: url)
        let controller = SpeakerAudioController()
        controller.update(items: [], enabled: true)
        controller.configureNormalization(12.041199826559248, for: quiet)
        controller.configureNormalization(0, for: loud)
        await controller.prepare(quiet)
        await controller.prepare(loud)
        let quietRMS = try tappedRMS(try XCTUnwrap(quiet.audioMix), amplitude: 0.02)
        let loudRMS = try tappedRMS(try XCTUnwrap(loud.audioMix), amplitude: 0.08)
        XCTAssertLessThan(abs(20 * log10(quietRMS / loudRMS)), 0.15)
        let retained = loud.audioMix
        controller.update(items: [quiet, loud], enabled: true)
        XCTAssertTrue(loud.audioMix === retained, "Handoff must keep the prepared native audio path")
        controller.update(items: [quiet, loud], enabled: false)
        XCTAssertNil(quiet.audioMix)
        XCTAssertNil(loud.audioMix)
    }

    func testASecondVersionOfOnePostCannotChangeTheRetainedPCMFilesGain() async throws {
        let first = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-a", withExtension: "mp4"))
        let other = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-b", withExtension: "mp4"))
        let audio = ContinuousAudioPlayer()
        addTeardownBlock { @MainActor in
            audio.suspend()
            audio.graph.engine.stop()
            let closed = await withCheckedContinuation { continuation in
                audio.debugShutdown { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(closed, "The actual decoder must acknowledge teardown")
        }
        audio.setWindow(["post"])
        audio.configureLoudness(id: "post", url: first, gainDB: 0)
        let entry = try await audio.prepare(id: "post", url: first)
        XCTAssertEqual(entry.sourceURL, first)
        audio.renderer.setSpeakerEnabled(true)
        audio.renderer.setPlaying(true)
        let baseline = renderedRMS(audio, token: entry.token)
        audio.configureLoudness(id: "post", url: other, gainDB: 24)
        let after = renderedRMS(audio, token: entry.token)
        XCTAssertGreaterThan(baseline, 0)
        XCTAssertLessThan(abs(20 * log10(after / baseline)), 0.15,
                          "Gain is bound to the prepared file, not only the TikTok ID")
        XCTAssertEqual(audio.snapshot.underrunFrames, 0)
    }

    private func renderedRMS(_ audio: ContinuousAudioPlayer, token: Int) -> Double {
        audio.renderer.select(token: token)
        var samples = Array(repeating: Float(0), count: 48000 * 2)
        samples.withUnsafeMutableBufferPointer { audio.renderer.render(interleaved: $0, frameCount: 48000) }
        let power = samples.dropFirst(48000).reduce(0.0) { $0 + Double($1 * $1) }
        return sqrt(power / 48000)
    }

    private func tappedRMS(_ mix: AVAudioMix, amplitude: Double) throws -> Double {
        let tap = try XCTUnwrap(mix.inputParameters.first?.audioTapProcessor)
        let state = Unmanaged<SpeakerTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        buffer.frameLength = 96000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<96000 { channel[index] = Float(amplitude * sin(2 * .pi * 1000 * Double(index) / 48000)) }
        state.prepare(format.streamDescription.pointee)
        state.process(buffer.mutableAudioBufferList, frames: 96000)
        var power = 0.0
        for index in 48000..<96000 { power += Double(channel[index] * channel[index]) }
        return sqrt(power / 48000)
    }
}
