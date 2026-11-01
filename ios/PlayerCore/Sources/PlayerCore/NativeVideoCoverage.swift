import Foundation

/// Qualification for the unscaled video range; this never edits either track.
public enum NativeVideoCoverage {
    public static func allowsNativePresentation(start: Double, end: Double,
        assetDuration: Double, frameDuration: Double) -> Bool {
        start.isFinite && end.isFinite && assetDuration.isFinite
            && start == 0 && end > 0 && end == assetDuration
    }
}
