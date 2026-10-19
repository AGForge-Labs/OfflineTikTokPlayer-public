import Foundation

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
    public var next: RepeatMode { switch self { case .off: return .all; case .all: return .one; case .one: return .off } }
}

private struct ShuffleGenerator: RandomNumberGenerator, Codable, Sendable {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

/// Metadata only. Playback history and the remaining shuffle bag are independent.
public struct PlaybackQueue: Codable, Sendable {
    public private(set) var eligibleIDs: [String]
    public private(set) var isShuffled: Bool
    public var repeatMode: RepeatMode = .off
    private var history: [String]
    private var historyIndex: Int
    // Optional so bookmarks written before playlist context was supported still decode.
    private var historyVisitOffset: Int?
    private var remaining: [String]
    private var played: Set<String>
    private var unavailable = Set<String>()
    private var generator: ShuffleGenerator

    public var currentID: String? { history.indices.contains(historyIndex) ? history[historyIndex] : nil }
    public var count: Int { eligibleIDs.count }

    public init(ids: [String], startAt: String? = nil, shuffle: Bool = false, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        var seen = Set<String>()
        let uniqueIDs = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        eligibleIDs = uniqueIDs
        isShuffled = shuffle
        var random = ShuffleGenerator(state: seed)
        let selectedIndex = startAt.flatMap { uniqueIDs.firstIndex(of: $0) }
        let index = selectedIndex
            ?? (shuffle && !uniqueIDs.isEmpty ? Int.random(in: uniqueIDs.indices, using: &random) : 0)
        generator = random
        let contextCount = selectedIndex ?? 0
        history = eligibleIDs.isEmpty ? [] : (selectedIndex == nil ? [eligibleIDs[index]] : Array(eligibleIDs.prefix(index + 1)))
        historyIndex = contextCount
        historyVisitOffset = -contextCount
        let initialPlayed = Set(eligibleIDs.isEmpty ? [] : [eligibleIDs[index]])
        if shuffle {
            played = initialPlayed
            remaining = uniqueIDs.filter { !initialPlayed.contains($0) }
            remaining.shuffle(using: &generator)
        } else {
            played = initialPlayed
            remaining = Array(eligibleIDs.dropFirst(index + 1))
        }
    }

    public mutating func setShuffle(_ enabled: Bool) {
        guard enabled != isShuffled else { return }
        isShuffled = enabled
        remaining = eligibleIDs.filter { !played.contains($0) && !unavailable.contains($0) }
        if enabled { remaining.shuffle(using: &generator) }
    }

    @discardableResult
    public mutating func next(explicit: Bool = true) -> String? {
        if !explicit, repeatMode == .one, let id = currentID, !unavailable.contains(id) { return id }
        while historyIndex + 1 < history.count {
            historyIndex += 1
            if let id = currentID, !unavailable.contains(id) { played.insert(id); remaining.removeAll { $0 == id }; return id }
        }
        remaining.removeAll { unavailable.contains($0) }
        if remaining.isEmpty {
            guard repeatMode != .off else { return nil }
            remaining = eligibleIDs.filter { !unavailable.contains($0) }
            guard !remaining.isEmpty else { return nil }
            played.removeAll()
            if isShuffled {
                remaining.shuffle(using: &generator)
                if remaining.count > 1, remaining.first == currentID { remaining.swapAt(0, remaining.count - 1) }
            }
        }
        let id = remaining.removeFirst()
        played.insert(id)
        history.append(id)
        historyIndex = history.count - 1
        return id
    }

    @discardableResult
    public mutating func previous() -> String? {
        let originalIndex = historyIndex
        while historyIndex > 0 {
            historyIndex -= 1
            if let id = currentID, !unavailable.contains(id) { played.insert(id); remaining.removeAll { $0 == id }; return id }
        }
        historyIndex = originalIndex
        return nil
    }

    public func previewNext() -> String? { var copy = self; return copy.next() }
    public func previewPrevious() -> String? { var copy = self; return copy.previous() }
    public var feedWindow: PlaybackPageWindow {
        var preceding = self, following = self
        let previous = preceding.previous().map { PlaybackPage(mediaID: $0, visitIndex: preceding.historyIndex + (preceding.historyVisitOffset ?? 0)) }
        let current = currentID.map { PlaybackPage(mediaID: $0, visitIndex: historyIndex + (historyVisitOffset ?? 0)) }
        let next = following.next().map { PlaybackPage(mediaID: $0, visitIndex: following.historyIndex + (following.historyVisitOffset ?? 0)) }
        return PlaybackPageWindow(previous: previous, current: current, next: next)
    }
    public mutating func markUnavailable(_ id: String) { unavailable.insert(id); remaining.removeAll { $0 == id } }

    public mutating func reconcile(availableIDs: Set<String>) {
        let originalVisit = historyIndex + (historyVisitOffset ?? 0)
        let preceding = history.prefix(historyIndex + 1).filter(availableIDs.contains).count
        eligibleIDs.removeAll { !availableIDs.contains($0) }
        history.removeAll { !availableIDs.contains($0) }
        historyIndex = max(0, preceding - 1)
        historyVisitOffset = history.isEmpty ? nil : originalVisit - historyIndex
        remaining.removeAll { !availableIDs.contains($0) }
        played.formIntersection(availableIDs)
        unavailable.removeAll()
        if history.isEmpty, !remaining.isEmpty {
            let id = remaining.removeFirst(); history = [id]; played.insert(id)
        }
    }

    public func validate() throws {
        let ids = Set(eligibleIDs)
        guard ids.count == eligibleIDs.count, !ids.contains(""),
              !history.count.addingReportingOverflow(historyVisitOffset ?? 0).overflow,
              historyIndex >= 0, history.isEmpty ? historyIndex == 0 : historyIndex < history.count,
              history.allSatisfy(ids.contains), remaining.allSatisfy(ids.contains),
              Set(remaining).count == remaining.count, played.isSubset(of: ids), unavailable.isSubset(of: ids) else {
            throw CatalogError.invalid("Saved playback queue is invalid.")
        }
    }
}

public struct PlaybackBookmark: Codable, Sendable {
    public let version: Int
    public private(set) var queue: PlaybackQueue
    public private(set) var position: Double
    public var shouldAutoplay: Bool { false }

    public init(queue: PlaybackQueue, position: Double) { version = 1; self.queue = queue; self.position = max(0, position.isFinite ? position : 0) }

    public static func restore(_ data: Data, availableIDs: Set<String>) throws -> Self {
        guard data.count <= 4_000_000 else { throw CatalogError.invalid("Saved queue is too large.") }
        var result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1, result.position.isFinite, result.position >= 0 else { throw CatalogError.invalid("Unsupported saved player state.") }
        try result.queue.validate()
        let previous = result.queue.currentID
        result.queue.reconcile(availableIDs: availableIDs)
        if previous != result.queue.currentID { result.position = 0 }
        return result
    }
}
