import Foundation

/// Qualification for the unscaled video range; this never edits either track.
public enum NativeVideoCoverage {
    public static func allowsNativePresentation(start: Double, end: Double,
        assetDuration: Double, frameDuration: Double) -> Bool {
        guard start.isFinite, end.isFinite, assetDuration.isFinite,
              start == 0, end > 0, assetDuration >= end else { return false }
        let tail = assetDuration - end
        if tail == 0 { return true }
        guard frameDuration.isFinite, frameDuration > 0 else { return false }
        // AAC/container rounding can leave less than one video frame of audio.
        // Preserve both tracks; never stretch/trim video or admit a long empty tail.
        let rounding = max(1, max(abs(end), abs(assetDuration))) * Double.ulpOfOne * 8
        return tail <= min(frameDuration, 0.080) + rounding
    }
}
