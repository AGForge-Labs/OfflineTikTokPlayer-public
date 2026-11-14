import XCTest
@testable import PlayerCore

final class MeasuredSpeakerAudioTests: XCTestCase {
    func testQuietAndLoudCopiesProduceMatchedSpeakerAudioInsteadOfFixedBoost() {
        let quiet = render(amplitude: 0.02, gain: 12.041199826559248)
        let loud = render(amplitude: 0.08, gain: 0)
        let difference = abs(20 * log10(quiet.rms / loud.rms))
        XCTAssertLessThan(difference, 0.15, "Measured gain must remove a real 12dB input difference")
        XCTAssertLessThanOrEqual(quiet.peak, 0.89)
        XCTAssertLessThanOrEqual(loud.peak, 0.89)
    }

    func testMeasuredZeroGainDoesNotReceiveAnotherNineDecibelsOfMakeup() {
        let measured = render(amplitude: 0.04, gain: 0)
        let sourceRMS = 0.04 / sqrt(2)
        XCTAssertGreaterThan(measured.rms / sourceRMS, 0.95)
        XCTAssertLessThan(measured.rms / sourceRMS, 1.2,
                          "Already matched audio retains only its modest EQ response")
    }

    func testOriginalSoundRemainsAnExactBypassWithNormalizationConfigured() {
        let processor = SpeakerAudioProcessor(sampleRate: 48000, channels: 2, enabled: false)
        processor.setNormalizationGainDB(24)
        var frame: [Float] = [0.34, -0.75]
        frame.withUnsafeMutableBufferPointer { processor.process($0) }
        XCTAssertEqual(frame, [0.34, -0.75])
    }

    func testPreparedSourcesKeepTheirOwnMeasuredGainAcrossNextAndLoopBoundaries() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 4096, ringFrames: 1024)
        let quiet = Array(repeating: Float(0.01), count: 4096)
        let loud = Array(repeating: Float(0.04), count: 4096)
        XCTAssertTrue(quiet.withUnsafeBufferPointer { renderer.source(at: 0).prepare(token: 1, totalFrames: 4096, prefix: $0) })
        XCTAssertTrue(loud.withUnsafeBufferPointer { renderer.source(at: 1).prepare(token: 2, totalFrames: 4096, prefix: $0) })
        renderer.setNormalizationGainDB(12.041199826559248, for: 1)
        renderer.setNormalizationGainDB(0, for: 2)
        renderer.setNormalizationGainDB(24, for: 999) // A stale preparation has no authority.
        renderer.setSuccessor(token: 2, for: 1)
        renderer.setSuccessor(token: 2, for: 2)
        renderer.setSpeakerEnabled(true)
        renderer.select(token: 1)
        renderer.setPlaying(true)
        var output = Array(repeating: Float(0), count: 8320)
        output.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 8320) }
        let before = output[3968..<4096].reduce(0.0) { $0 + Double($1 * $1) }
        let after = output[4096..<4224].reduce(0.0) { $0 + Double($1 * $1) }
        XCTAssertLessThan(abs(10 * log10(before / after)), 0.15,
                          "Next must switch normalization with the source, inside the same callback")
        XCTAssertTrue(output.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 0.89 })
        XCTAssertEqual(renderer.snapshot.token, 2)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        XCTAssertFalse(renderer.snapshot.ended)
    }

    func testMasteredSourceBypassesSpeakerProcessingAcrossNextAndLoopWithNoAddedFrames() {
        let renderer = ContinuousPCMRenderer(channels: 1, prefixFrames: 256, ringFrames: 256)
        let original = Array(repeating: Float(0.03), count: 192)
        let mastered = (0..<192).map { Float($0 + 1) * 0.001 }
        XCTAssertTrue(original.withUnsafeBufferPointer { renderer.source(at: 0).prepare(token: 1, totalFrames: 192, prefix: $0) })
        XCTAssertTrue(mastered.withUnsafeBufferPointer { renderer.source(at: 1).prepare(token: 2, totalFrames: 192, prefix: $0) })
        renderer.setNormalizationGainDB(18, for: 1)
        renderer.setNormalizationGainDB(18, for: 2, mastered: true)
        renderer.setSpeakerEnabled(true)
        renderer.setSuccessor(token: 2, for: 1)
        renderer.setSuccessor(token: 2, for: 2)
        renderer.select(token: 1)
        renderer.setPlaying(true)
        var output = Array(repeating: Float(0), count: 416)
        output.withUnsafeMutableBufferPointer { renderer.render(interleaved: $0, frameCount: 416) }
        XCTAssertNotEqual(Array(output.prefix(192)), original)
        XCTAssertEqual(Array(output[192..<384]), mastered)
        XCTAssertEqual(Array(output[384...]), Array(mastered.prefix(32)))
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
    }

    private func render(amplitude: Double, gain: Double) -> (rms: Double, peak: Float) {
        let processor = SpeakerAudioProcessor(sampleRate: 48000, channels: 1, enabled: true)
        processor.setNormalizationGainDB(gain)
        var power = 0.0, peak: Float = 0
        var frame: [Float] = [0]
        for index in 0..<96000 {
            frame[0] = Float(amplitude * sin(2 * .pi * 1000 * Double(index) / 48000))
            frame.withUnsafeMutableBufferPointer { processor.process($0) }
            if index >= 48000 { power += Double(frame[0] * frame[0]); peak = max(peak, abs(frame[0])) }
        }
        return (sqrt(power / 48000), peak)
    }
}
