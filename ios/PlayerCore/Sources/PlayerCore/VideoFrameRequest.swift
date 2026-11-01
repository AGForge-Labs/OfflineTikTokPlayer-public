import Foundation

public enum VideoFrameRequest {
    public static func usesNativeDeadline(presentation: Double, mapped: Double) -> Bool {
        guard presentation.isFinite, mapped.isFinite, mapped >= 0 else { return false }
        let lead = mapped - presentation
        return lead >= -0.080 && lead <= 1.0 / 30
    }
}
