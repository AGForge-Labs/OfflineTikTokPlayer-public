import Foundation

public enum VideoFrameRequest {
    public static func usesNativeDeadline(presentation: Double, mapped: Double) -> Bool {
        presentation.isFinite && mapped.isFinite && mapped >= 0 && abs(mapped - presentation) <= 0.080
    }
}
