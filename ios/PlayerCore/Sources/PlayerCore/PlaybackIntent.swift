/// User intent and audio-session permission are independent. Readiness callbacks and
/// stall recovery must consult canPlay, never just the user's last Play command.
public struct PlaybackIntent: Sendable {
    public private(set) var wantsToPlay = false
    public private(set) var isInterrupted = false
    private var sessionIsActive = false
    private var resumeEligible = false
    public var canPlay: Bool { wantsToPlay && sessionIsActive && !isInterrupted }
    public init() {}

    public mutating func requestPlay() {
        wantsToPlay = true
        // Explicit Play is also the recovery path when iOS omits an interruption end.
        isInterrupted = false; resumeEligible = false; sessionIsActive = false
    }
    public mutating func pause() { wantsToPlay = false; resumeEligible = false }
    public mutating func activationCompleted(succeeded: Bool) { sessionIsActive = succeeded }
    public mutating func interruptionBegan() {
        if !isInterrupted { resumeEligible = wantsToPlay }
        isInterrupted = true; sessionIsActive = false
    }
    public mutating func interruptionEnded(shouldResume: Bool) -> Bool {
        guard isInterrupted else { return false }
        let resume = resumeEligible && wantsToPlay && shouldResume
        isInterrupted = false; resumeEligible = false
        if !resume { wantsToPlay = false }
        return resume
    }
    public mutating func enteredForeground() {
        // Keep waiting: an actual ended notification may arrive after foregrounding.
        // Only an explicit Play can recover when that notification never arrives.
    }
}
