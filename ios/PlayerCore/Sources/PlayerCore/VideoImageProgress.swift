import Foundation

/// One bounded picture repair per caller-owned selection/presentation context.
/// The caller qualifies the exact audio/video owner and resets on user intent changes.
public struct VideoImageProgress {
    private var since: Double?
    private var nativeAtProgress = 0.0
    private var previousNative = 0.0
    private var previousHost = 0.0
    private var latestImage = 0.0
    private var attempted = false
    private let grace: Double
    public init(graceSeconds: Double = 1.5) {
        grace = graceSeconds.isFinite ? min(30, max(1.5, graceSeconds)) : 3
    }
    public mutating func shouldRecover(now: Double, nativePosition: Double,
                                       displayedPosition: Double?) -> Bool {
        guard now.isFinite, nativePosition.isFinite, nativePosition >= 0,
              displayedPosition.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            let used = attempted
            self = Self(graceSeconds: grace); attempted = used
            return false
        }
        if since == nil || now < previousHost || nativePosition < previousNative - 0.080 {
            since = now; nativeAtProgress = nativePosition
            latestImage = displayedPosition ?? 0
        }
        previousHost = now; previousNative = nativePosition
        if let displayedPosition, displayedPosition > latestImage + 1.0 / 48_000 {
            latestImage = displayedPosition
            since = now; nativeAtProgress = nativePosition
        }
        guard let since, !attempted, now - since >= grace,
              nativePosition - nativeAtProgress >= 0.5,
              nativePosition - latestImage >= 0.5 else { return false }
        // A real VFR hold can look like starvation. Rebuilding the output keeps
        // audio/position intact, and later valid frames must not rearm a loop.
        attempted = true
        return true
    }
}
