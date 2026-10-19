import Foundation

/// State shared by the player clock and scrubber; media operations stay in AVFoundation.
public struct PlaybackTimeline: Sendable {
    public struct Seek: Equatable, Sendable {
        fileprivate let revision: UInt64
        public let target: Double
    }
    public private(set) var position: Double = 0
    public private(set) var duration: Double = 0
    private var revision: UInt64 = 0
    private var pending: Seek?

    public init() {}
    public mutating func reset(position: Double, duration: Double) {
        revision &+= 1
        pending = nil
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.position = bounded(position)
    }
    public mutating func updateDuration(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        duration = seconds
        position = bounded(position)
    }
    public mutating func sample(position: Double) {
        guard pending == nil, position.isFinite else { return }
        self.position = bounded(position)
    }
    public mutating func beginSeek(to seconds: Double) -> Seek? {
        guard seconds.isFinite else { return nil }
        revision &+= 1
        let seek = Seek(revision: revision, target: bounded(seconds))
        position = seek.target
        pending = seek
        return seek
    }
    @discardableResult
    public mutating func completeSeek(_ seek: Seek, actualPosition: Double) -> Bool {
        guard pending == seek else { return false }
        pending = nil
        sample(position: actualPosition)
        return true
    }
    private func bounded(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return max(0, min(seconds, duration > 0 ? duration : seconds))
    }
}

public struct PlaybackScrub: Sendable {
    public private(set) var position: Double?
    private var mediaID: String?
    public init() {}
    public mutating func begin(mediaID: String, position: Double) {
        if self.mediaID != mediaID || self.position == nil { update(position, mediaID: mediaID) }
    }
    public mutating func update(_ position: Double, mediaID: String) {
        guard position.isFinite else { return }
        self.mediaID = mediaID
        self.position = position
    }
    public mutating func finish(mediaID: String) -> Double? {
        defer { self = Self() }
        return self.mediaID == mediaID ? position : nil
    }
}
