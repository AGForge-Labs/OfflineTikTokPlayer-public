import Foundation

/// One bounded picture repair per absence of forward image progress.
/// The caller qualifies the exact audio/video owner and resets on user intent changes.
public struct VideoImageProgress {
    private var since: Double?
    private var nativeAtProgress = 0.0
    private var previousNative = 0.0
    private var previousHost = 0.0
    private var latestImage = 0.0
    private var attempted = false
    public init() {}
    public mutating func shouldRecover(now: Double, nativePosition: Double,
                                       displayedPosition: Double?) -> Bool {
        guard now.isFinite, nativePosition.isFinite, nativePosition >= 0,
              displayedPosition.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            self = Self(); return false
        }
        if since == nil || now < previousHost || nativePosition < previousNative - 0.080 {
            since = now; nativeAtProgress = nativePosition
            latestImage = displayedPosition ?? 0
            attempted = false
        }
        previousHost = now; previousNative = nativePosition
        if let displayedPosition, displayedPosition > latestImage + 1.0 / 48_000 {
            latestImage = displayedPosition
            since = now; nativeAtProgress = nativePosition; attempted = false
        }
        guard let since, !attempted, now - since >= 1.5,
              nativePosition - nativeAtProgress >= 0.5,
              nativePosition - latestImage >= 0.5 else { return false }
        // A real VFR hold can look like starvation. Keep its image and audio,
        // and do not repeat a repair until a genuinely later image is displayed.
        attempted = true
        return true
    }
}
