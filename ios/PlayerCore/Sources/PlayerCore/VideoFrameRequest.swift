import Foundation

public enum VideoFrameRequest {
    public static func sourceRate(nominal: Double, minimumFrameDuration: Double) -> Double {
        let validNominal = nominal.isFinite && nominal > 0
        let fastest = 1 / minimumFrameDuration
        if fastest.isFinite, fastest >= 1, fastest <= 120.5,
           !validNominal || fastest > nominal * 1.05 { return min(120, fastest) }
        return validNominal ? min(120, nominal) : 30
    }

    public static func displayRate(source: Double, maximum: Int) -> Double {
        let limit = maximum > 0 ? Double(min(maximum, 120)) : 60
        guard limit > 60, source.isFinite, source > 0 else { return min(60, limit) }
        // A 24 fps frame fits two 48 Hz refreshes. At 60 Hz the same clip
        // alternates between two and three. Allow fractional NTSC rates.
        for hz in [48.0, 60, 80, 120] where hz <= limit {
            let multiple = (hz / source).rounded()
            if multiple >= 1, abs(hz - multiple * source) <= hz * 0.002 { return hz }
        }
        // For e.g. 25 and 50 fps, use the finest available display deadline.
        return limit
    }

    public static func usesNativeDeadline(presentation: Double, mapped: Double) -> Bool {
        guard presentation.isFinite, mapped.isFinite, mapped >= 0 else { return false }
        let lead = mapped - presentation
        return lead >= -0.080 && lead <= 1.0 / 30
    }
}
