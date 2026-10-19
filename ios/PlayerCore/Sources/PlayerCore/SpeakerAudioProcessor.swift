import Foundation

/// Single audio-render-thread owner. All storage and coefficients are prepared off the render path.
/// No resampling, channel summing, source rewriting or per-frame allocations.
public final class SpeakerAudioProcessor {
    private struct Shelf {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0
        // RBJ shelves, slope S=1: https://www.w3.org/TR/audio-eq-cookbook/
        init(rate: Double, frequency: Double, gainDB: Double, high: Bool) {
            let a = pow(10, gainDB / 40), w = 2 * Double.pi * frequency / rate
            let c = cos(w), beta = sin(w) * sqrt(2 * a)
            let a0: Double
            if high {
                a0 = (a + 1) - (a - 1) * c + beta
                b0 = a * ((a + 1) + (a - 1) * c + beta) / a0
                b1 = -2 * a * ((a - 1) + (a + 1) * c) / a0
                b2 = a * ((a + 1) + (a - 1) * c - beta) / a0
                a1 = 2 * ((a - 1) - (a + 1) * c) / a0
                a2 = ((a + 1) - (a - 1) * c - beta) / a0
            } else {
                a0 = (a + 1) + (a - 1) * c + beta
                b0 = a * ((a + 1) - (a - 1) * c + beta) / a0
                b1 = 2 * a * ((a - 1) - (a + 1) * c) / a0
                b2 = a * ((a + 1) - (a - 1) * c - beta) / a0
                a1 = -2 * ((a - 1) + (a + 1) * c) / a0
                a2 = ((a + 1) + (a - 1) * c - beta) / a0
            }
        }
        mutating func sample(_ input: Double) -> Double {
            let value = b0 * input + z1
            z1 = b1 * input - a1 * value + z2
            z2 = b2 * input - a2 * value
            return value
        }
    }
    private let enabled: Bool
    private let limiterRelease: Double
    private let levelCoefficient: Double
    private let compressionAttack: Double
    private let compressionRecovery: Double
    private let rampStep: Double
    private var bass: [Shelf]
    private var presence: [Shelf]
    private var signal: [Double]
    private var limiter = 1.0
    private var levelPower = 0.0
    private var compression = 1.0
    private var wet = 0.0

    public init(sampleRate: Double, channels: Int, enabled: Bool) {
        let valid = sampleRate.isFinite && sampleRate >= 16000 && sampleRate <= 192000 && (1...8).contains(channels)
        let rate = valid ? sampleRate : 48000
        let count = valid ? channels : 0
        self.enabled = enabled && valid
        limiterRelease = exp(-1 / (rate * 0.003))
        levelCoefficient = exp(-1 / (rate * 0.030))
        compressionAttack = exp(-1 / (rate * 0.005))
        compressionRecovery = exp(-1 / (rate * 0.040))
        rampStep = 1 / (rate * 0.030)
        bass = (0..<count).map { _ in Shelf(rate: rate, frequency: 160, gainDB: 4, high: false) }
        presence = (0..<count).map { _ in Shelf(rate: rate, frequency: 3500, gainDB: 2, high: true) }
        signal = Array(repeating: 0, count: count)
    }

    public func process(_ frame: UnsafeMutableBufferPointer<Float>) {
        guard enabled, frame.count == bass.count else { return }
        wet = min(1, wet + rampStep)
        var peak = 0.0
        for channel in frame.indices {
            let dry = frame[channel].isFinite ? Double(frame[channel]) : 0
            let shaped = presence[channel].sample(bass[channel].sample(dry))
            let value = dry + wet * (shaped - dry)
            signal[channel] = value
            peak = max(peak, abs(value))
        }
        // Shape music by its average level, rather than holding it down after every transient.
        // 2:1 compression above 0.18 RMS, with up to 6dB gain on quieter material.
        levelPower = levelCoefficient * levelPower + (1 - levelCoefficient) * peak * peak
        let level = sqrt(levelPower)
        let targetCompression = level > 0.18 ? sqrt(0.18 / level) : 1
        let coefficient = targetCompression < compression ? compressionAttack : compressionRecovery
        compression = targetCompression + (compression - targetCompression) * coefficient
        let gain = 1 + wet * (2 * compression - 1)
        peak *= gain
        // Peak protection shares gain across channels and recovers quickly. No sample delay.
        let target = peak > 0.98 ? 0.98 / peak : 1
        limiter = min(target, 1 - (1 - limiter) * limiterRelease)
        for channel in frame.indices {
            frame[channel] = Float(max(-0.98, min(0.98, signal[channel] * gain * limiter)))
        }
    }

    public func reset() {
        for channel in bass.indices {
            bass[channel].z1 = 0; bass[channel].z2 = 0
            presence[channel].z1 = 0; presence[channel].z2 = 0
            signal[channel] = 0
        }
        limiter = 1; wet = 0; levelPower = 0; compression = 1
    }
}
