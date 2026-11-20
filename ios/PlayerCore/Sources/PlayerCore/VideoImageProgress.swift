import Foundation

/// A held picture can trigger one repair. Continued loss of all current
/// images permits one more attempt. Moving pictures rearm recovery.
public struct VideoImageProgress {
    public enum NextSourceFrame: Equatable, Sendable {
        /// Time from the held frame to its actual successor in presentation order.
        case after(Double)
        case end
    }
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
                                       displayedPosition: Double?, followingFrame: NextSourceFrame? = nil) -> Bool {
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
        var wait = grace
        var clockAdvance = 0.5
        if let displayedPosition, let followingFrame {
            guard case .after(let interval) = followingFrame, interval.isFinite, interval > 0,
                  playbackPosition - displayedPosition >= interval + 0.080 else { return false }
            // A source sample is already overdue. Allow a few ordinary render
            // ticks for it to arrive, then leave time to replace a starved tap.
            wait = 0.12
            clockAdvance = 0.080
        }
        guard let since, now - since >= wait,
              playbackPosition - playbackAtProgress >= clockAdvance,
              playbackPosition - latestImage >= clockAdvance else { return false }
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
