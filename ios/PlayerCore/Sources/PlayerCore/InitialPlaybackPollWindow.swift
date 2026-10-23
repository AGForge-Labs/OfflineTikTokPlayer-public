/// Bounds a faster observation cadence to the first half-second of a new request.
/// This grants no playback or frame-readiness permission and owns no task or timer.
public struct InitialPlaybackPollWindow {
    public struct Snapshot: Sendable {
        public let request: Int
        public let start: Double?
        public let deadline: Double?
    }
    private var request = 0
    private var start: Double?
    private var deadline: Double?
    public init() {}
    public var snapshot: Snapshot { .init(request: request, start: start, deadline: deadline) }
    public mutating func withdraw(request: Int) {
        self.request = max(self.request, request)
        start = nil; deadline = nil
    }

    public mutating func milliseconds(request: Int, eligible: Bool, monotonicTime now: Double) -> Int {
        guard request > 0, request >= self.request, now.isFinite, now >= 0 else { return 33 }
        if request > self.request {
            self.request = request
            start = eligible ? now : nil
            deadline = eligible ? now + 0.5 : nil
        }
        guard eligible else { withdraw(request: request); return 33 }
        guard let start, let deadline, now >= start, now < deadline else { return 33 }
        return 16
    }
}
