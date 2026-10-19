import XCTest
@testable import PlayerCore

final class SpeakerAudioProcessorTests: XCTestCase {
    func testTransientPeakDoesNotKeepFollowingQuietMusicTurnedDown() {
        let processor = SpeakerAudioProcessor(sampleRate: 48000, channels: 1, enabled: true)
        var frame: [Float] = [1.8]
        frame.withUnsafeMutableBufferPointer { processor.process($0) }
        var power = 0.0
        for index in 0..<1920 {
            frame[0] = Float(0.1 * sin(2 * .pi * 2000 * Double(index) / 48000))
            frame.withUnsafeMutableBufferPointer { processor.process($0) }
            if index >= 960 { power += Double(frame[0] * frame[0]) }
        }
        XCTAssertGreaterThan(sqrt(power / 960), 0.1 / sqrt(2) * 1.3,
                             "An isolated peak must not depress the next 20-40ms of music")
    }

    func testSpeakerProcessingDoesNotDelaySamples() {
        let processor = SpeakerAudioProcessor(sampleRate: 48000, channels: 1, enabled: true)
        var impulse: [Float] = [0.25]
        impulse.withUnsafeMutableBufferPointer { processor.process($0) }
        XCTAssertGreaterThan(impulse[0], 0, "Peak detection may retain levels, never delay the audio frames")
    }

    func testOriginalPreservesSamplesExactly() {
        let processor = SpeakerAudioProcessor(sampleRate: 48000, channels: 2, enabled: false)
        var frame: [Float] = [0.34, -0.75]
        for _ in 0..<100 { frame.withUnsafeMutableBufferPointer { processor.process($0) } }
        XCTAssertEqual(frame, [0.34, -0.75])
    }

    func testQuietBassAndPresenceAreLiftedAtBothSampleRates() {
        for rate in [44100.0, 48000.0] {
            let bass = response(frequency: 100, amplitude: 0.04, rate: rate)
            let middle = response(frequency: 1000, amplitude: 0.04, rate: rate)
            let presence = response(frequency: 6000, amplitude: 0.04, rate: rate)
            XCTAssertGreaterThan(bass, middle * 1.15)
            XCTAssertGreaterThan(presence, middle * 1.04)
            XCTAssertGreaterThan(middle, 0.04 / sqrt(2) * 1.8)
        }
    }

    func testSustainedBassIsNotMadeHarshByTheLoudnessBoost() {
        let rate = 48000.0, frequency = 100.0
        let processor = SpeakerAudioProcessor(sampleRate: rate, channels: 1, enabled: true)
        var frame: [Float] = [0]
        var power = 0.0, real = 0.0, imaginary = 0.0
        let count = Int(rate / 2)
        for index in 0..<Int(rate) {
            let angle = 2 * .pi * frequency * Double(index) / rate
            frame[0] = Float(0.65 * sin(angle))
            frame.withUnsafeMutableBufferPointer { processor.process($0) }
            if index >= count {
                let sample = Double(frame[0])
                power += sample * sample; real += sample * cos(angle); imaginary += sample * sin(angle)
            }
        }
        let fundamental = 2 * (real * real + imaginary * imaginary) / Double(count * count)
        let distortion = sqrt(max(0, power / Double(count) - fundamental) / fundamental)
        XCTAssertLessThan(distortion, 0.01, "A louder 100Hz bass tone must remain below 1% THD+N")
    }

    func testLoudAndMalformedInputIsFiniteAndPeakLimitedWithStereoLinked() {
        let processor = SpeakerAudioProcessor(sampleRate: 48000, channels: 2, enabled: true)
        var peak: Float = 0
        for index in 0..<48000 {
            let left = Float(sin(Double(index) * 0.05) * 2)
            var frame: [Float] = [left, left * 0.4]
            frame.withUnsafeMutableBufferPointer { processor.process($0) }
            peak = max(peak, abs(frame[0]), abs(frame[1]))
            XCTAssertEqual(frame[1], frame[0] * 0.4, accuracy: 0.00001)
        }
        XCTAssertLessThanOrEqual(peak, 0.98)
        var invalid: [Float] = [.nan, .infinity]
        invalid.withUnsafeMutableBufferPointer { processor.process($0) }
        XCTAssertTrue(invalid.allSatisfy { $0.isFinite && abs($0) <= 0.98 })
    }

    func testSilenceAndNewProcessorDoNotLeakPreviousAudio() {
        let first = SpeakerAudioProcessor(sampleRate: 48000, channels: 1, enabled: true)
        var frame: [Float] = [1]
        frame.withUnsafeMutableBufferPointer { first.process($0) }
        let next = SpeakerAudioProcessor(sampleRate: 48000, channels: 1, enabled: true)
        frame = [0]
        for _ in 0..<1000 { frame.withUnsafeMutableBufferPointer { next.process($0) }; XCTAssertEqual(frame[0], 0) }
    }

    func testSeekResetDiscardsFilterHistoryWithoutAllocatingANewProcessor() {
        let processor = SpeakerAudioProcessor(sampleRate: 48000, channels: 1, enabled: true)
        var frame: [Float] = [0.6]
        frame.withUnsafeMutableBufferPointer { processor.process($0) }
        processor.reset()
        frame = [0]
        frame.withUnsafeMutableBufferPointer { processor.process($0) }
        XCTAssertEqual(frame[0], 0)
    }

    private func response(frequency: Double, amplitude: Double, rate: Double) -> Double {
        let processor = SpeakerAudioProcessor(sampleRate: rate, channels: 1, enabled: true)
        var power = 0.0
        for index in 0..<Int(rate) {
            var frame = [Float(amplitude * sin(2 * .pi * frequency * Double(index) / rate))]
            frame.withUnsafeMutableBufferPointer { processor.process($0) }
            if index >= Int(rate / 2) { power += Double(frame[0] * frame[0]) }
        }
        return sqrt(power / (rate / 2))
    }
}
