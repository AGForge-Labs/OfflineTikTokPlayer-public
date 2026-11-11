import Foundation

/// A held picture can trigger one repair. Only a stretch of timely, moving
/// pictures rearms recovery within the same playback visit.
public struct VideoImageProgress {
    private var since: Double?
    private var playbackAtProgress = 0.0
    private var previousPlayback = 0.0
    private var previousHost = 0.0
    private var latestImage = 0.0
    private var attempted = false
    private var resumedSince: Double?
    private let grace: Double
    public init(graceSeconds: Double = 1.5) {
        grace = graceSeconds.isFinite ? min(30, max(1.5, graceSeconds)) : 3
    }
    public mutating func shouldRecover(now: Double, playbackPosition: Double,
                                       displayedPosition: Double?) -> Bool {
        guard now.isFinite, playbackPosition.isFinite, playbackPosition >= 0,
              displayedPosition.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            let used = attempted
            self = Self(graceSeconds: grace); attempted = used
            return false
        }
        if since == nil || now < previousHost || playbackPosition < previousPlayback - 0.080 {
            since = now; playbackAtProgress = playbackPosition
            latestImage = displayedPosition ?? 0
            resumedSince = nil
        }
        previousHost = now; previousPlayback = playbackPosition
        if let displayedPosition, displayedPosition > latestImage + 1.0 / 48_000 {
            if attempted {
                let timely = abs(playbackPosition - displayedPosition) <= 0.35
                if timely {
                    if resumedSince == nil || now - (since ?? now) > 0.75 { resumedSince = now }
                    if let resumedSince, now - resumedSince >= 1.5 {
                        attempted = false
                        self.resumedSince = nil
                    }
                } else { resumedSince = nil }
            }
            latestImage = displayedPosition
            since = now; playbackAtProgress = playbackPosition
        }
        guard let since, !attempted, now - since >= grace,
              playbackPosition - playbackAtProgress >= 0.5,
              playbackPosition - latestImage >= 0.5 else { return false }
        // A long source frame can resemble a freeze. A repeated or isolated
        // image after repair is insufficient to trigger another one.
        attempted = true
        return true
    }
}
