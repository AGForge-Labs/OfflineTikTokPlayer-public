import Foundation

/// Whether the muted native clock requires an exact seek. The submitted
/// presentation is evidence only after its owner validates item/epoch/readiness.
public enum PlaybackVideoSynchronization {
    public static func requiresExactSeek(force: Bool, canPlay: Bool, nativeRate: Float,
                                         nativePosition: Double, audioPosition: Double,
                                         framePosition: Double?, timebasePosition: Double?) -> Bool {
        guard force || abs(nativePosition - audioPosition) > 0.080 else { return false }
        guard !force, canPlay, nativeRate.isFinite, nativeRate > 0,
              audioPosition.isFinite, let framePosition, framePosition.isFinite,
              let timebasePosition, timebasePosition.isFinite,
              abs(framePosition - audioPosition) <= 0.080,
              abs(timebasePosition - audioPosition) <= 0.080 else { return true }
        return false
    }
}

/// A persistent AVPlayerLayer can still be displaying the departing item's frame.
/// Only the arriving item's output can arm this gate; allow a display commit, then latch.
public struct PlaybackFrameReadiness {
    private var decoded = false
    private var armedAt: Double?
    private var ready = false
    private var frameEpoch: UInt64?
    public init() {}

    /// Level evidence from an actively submitted frame. A missing/replaced epoch
    /// must earn its own native-layer display opportunity after every flush.
    public mutating func sampleCurrentFrame(epoch: UInt64?, layerReady: Bool, displayTime: Double) -> Bool {
        guard let epoch else { self = Self(); return false }
        if frameEpoch != epoch { self = Self(); frameEpoch = epoch }
        return sample(decodedFrame: true, layerReady: layerReady, displayTime: displayTime)
    }

    public mutating func sample(decodedFrame: Bool, layerReady: Bool, displayTime: Double) -> Bool {
        if ready { return true }
        guard displayTime.isFinite else { return false }
        decoded = decoded || decodedFrame
        guard decoded, layerReady else { armedAt = nil; return false }
        if let armedAt, displayTime > armedAt { ready = true }
        else if armedAt == nil { armedAt = displayTime }
        return ready
    }
}
