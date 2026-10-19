import Foundation

/// A history visit, rather than a reusable current/next slot. Repeat cycles may visit a video twice.
public struct PlaybackPage: Identifiable, Hashable, Sendable {
    public let mediaID: String
    let visitIndex: Int
    public var id: String { "\(visitIndex):\(mediaID)" }
}

public struct PlaybackPageWindow: Equatable, Sendable {
    public let previous: PlaybackPage?
    public let current: PlaybackPage?
    public let next: PlaybackPage?
    public var pages: [PlaybackPage] { [previous, current, next].compactMap { $0 } }
    public init(previous: PlaybackPage? = nil, current: PlaybackPage? = nil, next: PlaybackPage? = nil) {
        self.previous = previous; self.current = current; self.next = next
    }
    public func settledDirection(at landedID: String?, currentWindow: PlaybackPageWindow) -> Int {
        guard let landedID, current == currentWindow.current else { return 0 }
        if landedID == next?.id, next == currentWindow.next { return 1 }
        if landedID == previous?.id, previous == currentWindow.previous { return -1 }
        return 0
    }
}
