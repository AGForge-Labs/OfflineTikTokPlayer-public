import Foundation

/// A held picture can trigger one repair. Continued loss of all current
/// images permits one more attempt. Moving pictures rearm recovery.
public struct VideoImageProgress {
    private var since: Double?
    private var playbackAtProgress = 0.0
    private var previousPlayback = 0.0
    private var previousHost = 0.0
    private var latestImage = 0.0
    public private(set) var repairAttempts = 0
    private var missingSince: Double?
    private var resumedSince: Double?
    private let grace: Double
    public init(graceSeconds: Double = 1.5) {
        grace = graceSeconds.isFinite ? min(30, max(1.5, graceSeconds)) : 3
    }
    public mutating func shouldRecover(now: Double, playbackPosition: Double,
                                       displayedPosition: Double?) -> Bool {
        guard now.isFinite, playbackPosition.isFinite, playbackPosition >= 0,
              displayedPosition.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            let used = repairAttempts
            self = Self(graceSeconds: grace); repairAttempts = used
            return false
        }
        if since == nil || now < previousHost || playbackPosition < previousPlayback - 0.080 {
            since = now; playbackAtProgress = playbackPosition
            latestImage = displayedPosition ?? 0
            resumedSince = nil; missingSince = nil
        }
        previousHost = now; previousPlayback = playbackPosition
        if displayedPosition != nil { missingSince = nil }
        else if missingSince == nil { missingSince = now }
        if let displayedPosition, displayedPosition > latestImage + 1.0 / 48_000 {
            if repairAttempts > 0 {
                let timely = abs(playbackPosition - displayedPosition) <= 0.35
                if timely {
                    if resumedSince == nil || now - (since ?? now) > 0.75 { resumedSince = now }
                    if let resumedSince, now - resumedSince >= 1.5 {
                        repairAttempts = 0
                        self.resumedSince = nil
                    }
                } else { resumedSince = nil }
            }
            latestImage = displayedPosition
            since = now; playbackAtProgress = playbackPosition
        }
        guard let since, now - since >= grace,
              playbackPosition - playbackAtProgress >= 0.5,
              playbackPosition - latestImage >= 0.5 else { return false }
        if repairAttempts > 0 {
            // A legitimately long frame remains present. A failed repair that
            // never gets a current image may retry after another full window.
            guard repairAttempts == 1, let missingSince, now - missingSince >= grace else { return false }
        }
        repairAttempts += 1
        self.since = now
        playbackAtProgress = playbackPosition
        return true
    }
}
