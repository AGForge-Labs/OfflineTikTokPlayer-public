import AVFoundation
import PlayerCore

/// Main-actor policy around a single audio graph. IDs and URLs stay here/the
/// decoder; the render thread sees only small visit tokens and PCM.
@MainActor
final class ContinuousAudioPlayer {
    struct Entry { let id: String; let token: Int; let slot: Int; let frames: Int64 }
    let renderer = ContinuousPCMRenderer()
    private(set) var graph: ContinuousAudioGraph
    private let decoder: ContinuousPCMDecoder
    private var entries: [String: Entry] = [:]
    private var preparing: [String: Task<Entry, Error>] = [:]
    private var reservedSlots = Set<Int>()
    private var reservedTokens = Set<Int>()
    private var nextToken = 1
    private var window = Set<String>()
    private var successors: [Int: Int] = [:]
    private(set) var selectedID: String?
    private var renderingPermitted = false
    private var failedTokens = Set<Int>()
    private var pendingPosition: (version: Int, position: Double)?

    init() {
        graph = ContinuousAudioGraph(renderer: renderer)
        decoder = ContinuousPCMDecoder(renderer: renderer)
    }
    deinit { decoder.shutdown(); graph.engine.stop() }
    var isSelected: Bool { selectedID != nil }
    var preparedCount: Int { entries.count }
    var snapshot: ContinuousPCMRenderer.Snapshot { renderer.snapshot }
    var currentEntry: Entry? { entries.values.first { $0.token == renderer.snapshot.token } }
    func entry(for id: String) -> Entry? {
        entries[id].flatMap { failedTokens.contains($0.token) ? nil : $0 }
    }
    func entry(forToken token: Int) -> Entry? { entries.values.first { $0.token == token } }

    func setWindow(_ ids: Set<String>) {
        window = ids
        for (id, task) in preparing where !ids.contains(id) { task.cancel() }
        // Clear stale links before retiring an offscreen slot. The current
        // natural successor is installed explicitly after preparation.
        let retained = Set(entries.values.filter { ids.contains($0.id) }.map(\.token))
        for (token, next) in successors where !retained.contains(next) {
            renderer.setSuccessor(token: 0, for: token)
            successors[token] = nil
        }
        evictUnused()
    }

    private func evictUnused() {
        let active = renderer.snapshot.token
        for entry in Array(entries.values) where (!window.contains(entry.id) || failedTokens.contains(entry.token)) && entry.token != active {
            if renderer.retireSource(at: entry.slot) {
                entries[entry.id] = nil; successors[entry.token] = nil; failedTokens.remove(entry.token)
            }
        }
        decoder.retain(tokens: Set(entries.values.map(\.token)).union(reservedTokens))
    }

    func prepare(id: String, url: URL, currentPriority: Bool = false) async throws -> Entry {
        if let entry = entries[id], !failedTokens.contains(entry.token) { return entry }
        if let task = preparing[id] { return try await task.value }
        var available: Int?
        // Rapid direction changes may briefly pin all slots. Yield to the one
        // decoder and render acknowledgement instead of skipping valid media.
        for _ in 0..<200 {
            try Task.checkCancellation()
            evictUnused()
            let used = Set(entries.values.map(\.slot)).union(reservedSlots)
            available = (0..<3).first(where: { !used.contains($0) })
            if available == nil, currentPriority {
                let active = renderer.snapshot.token
                // A new playlist's current item outranks an optional neighbour.
                // Otherwise old-active + desired previous/next can pin all three
                // slots forever while the new current waits for preparation.
                for victim in Array(entries.values) where victim.id != id && victim.token != active {
                    for (token, next) in successors where next == victim.token {
                        renderer.setSuccessor(token: 0, for: token); successors[token] = nil
                    }
                    if renderer.retireSource(at: victim.slot) {
                        entries[victim.id] = nil; successors[victim.token] = nil
                        available = victim.slot
                        decoder.retain(tokens: Set(entries.values.map(\.token)).union(reservedTokens))
                        break
                    }
                }
            }
            if available != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let slot = available else { throw PreparationError.windowBusy }
        let token = nextToken; nextToken += 1
        reservedSlots.insert(slot); reservedTokens.insert(token)
        let task = Task { [decoder] in
            let prepared = try await decoder.prepare(url: url, token: token, slot: slot)
            return Entry(id: id, token: token, slot: slot, frames: prepared.totalFrames)
        }
        preparing[id] = task
        do {
            let entry = try await task.value
            // The worker can report a stream failure after publishing the
            // prefix but before this actor receives the prepared Entry.
            guard !failedTokens.contains(token) else { throw ContinuousPCMDecoder.Failure.cannotDecode }
            preparing[id] = nil; reservedSlots.remove(slot); reservedTokens.remove(token)
            entries[id] = entry
            evictUnused()
            return entry
        } catch {
            preparing[id] = nil; reservedSlots.remove(slot); reservedTokens.remove(token)
            failedTokens.remove(token)
            _ = renderer.retireSource(at: slot)
            decoder.retain(tokens: Set(entries.values.map(\.token)).union(reservedTokens))
            throw error
        }
    }

    @discardableResult
    func select(id: String, position: Double = 0) -> Bool {
        guard let entry = entries[id] else { return false }
        selectedID = id
        let bounded = min(Double(entry.frames) / 48_000, max(0, position.isFinite ? position : 0))
        let version = renderer.select(token: entry.token, frame: Int64(bounded * 48_000))
        pendingPosition = (version, bounded)
        return true
    }

    func follow(from id: String, to successor: String?) {
        guard let source = entries[id] else { return }
        let next = successor.flatMap { entry(for: $0)?.token } ?? 0
        renderer.setSuccessor(token: next, for: source.token)
        successors[source.token] = next
    }
    func setPlaying(_ playing: Bool) throws {
        // An engine that iOS stopped during interruption/configuration must be
        // started again only after the service has reactivated its session.
        renderer.setPlaying(playing)
        do {
            if playing, !graph.engine.isRunning { graph.engine.prepare(); try graph.engine.start() }
            renderingPermitted = playing
        } catch {
            renderer.setPlaying(false); renderingPermitted = false
            throw error
        }
    }
    func setSpeakerEnabled(_ enabled: Bool) { renderer.setSpeakerEnabled(enabled) }
    func adoptRendered(id: String) { selectedID = id }
    func isSelectionPending(in sample: ContinuousPCMRenderer.Snapshot) -> Bool {
        pendingPosition.map { $0.version != sample.selectionVersion } ?? false
    }
    func presentationPosition(at hostTime: CMTime) -> Double {
        let sample = renderer.snapshot
        if let pendingPosition, pendingPosition.version != sample.selectionVersion { return pendingPosition.position }
        pendingPosition = nil
        guard renderingPermitted, graph.engine.isRunning else { return Double(sample.frame) / 48_000 }
        return graph.presentationPosition(token: sample.token, at: hostTime) ?? Double(sample.frame) / 48_000
    }
    func onDecodeFailure(_ handler: @escaping @Sendable (Int, ContinuousPCMDecoder.Failure) -> Void) {
        decoder.setFailureHandler(handler)
    }
    func onSourceSilence(_ handler: @escaping @Sendable (Int, ContinuousPCMDecoder.SourceSilence) -> Void) {
        decoder.setSourceSilenceHandler(handler)
    }
    @discardableResult
    func invalidateForRetry(token: Int) -> Bool {
        let knownEntry = entries.values.contains { $0.token == token }
        guard knownEntry || reservedTokens.contains(token) else { return false }
        failedTokens.insert(token)
        // Reservations must fail publication, but cannot own current playback.
        guard knownEntry else { return false }
        for entry in entries.values { renderer.setSuccessor(token: 0, for: entry.token) }
        successors.removeAll()
        let sample = renderer.snapshot
        let requested = selectedID.flatMap { entries[$0]?.token }
        let relevant: Int?
        if isSelectionPending(in: sample) { relevant = requested }
        else { relevant = sample.token > 0 ? sample.token : requested }
        let selected = relevant == token
        if selected {
            suspend(); pendingPosition = nil; renderer.select(token: 0); selectedID = nil
        }
        evictUnused()
        return selected
    }
    func suspend() { renderingPermitted = false; renderer.setPlaying(false) }
    func settlePausedState() {
        guard !renderingPermitted, graph.engine.isRunning else { return }
        let sample = renderer.snapshot
        if let selectedID, entries[selectedID]?.token != sample.token { return }
        if selectedID == nil, sample.token != 0 { return }
        if let pendingPosition, pendingPosition.version != sample.selectionVersion { return }
        pendingPosition = nil
        graph.engine.pause()
        evictUnused()
    }
    @discardableResult
    func seek(_ position: Double) -> Int? {
        guard let selectedID, select(id: selectedID, position: position) else { return nil }
        return pendingPosition?.version
    }
    func clearSelection() { suspend(); selectedID = nil; pendingPosition = nil }
    func rebuildAfterMediaServicesReset() {
        suspend()
        graph.engine.stop()
        graph = ContinuousAudioGraph(renderer: renderer)
    }
    func trimWindow(preserving requestedID: String? = nil) {
        setWindow(Set([currentEntry?.id, selectedID, requestedID].compactMap { $0 }))
    }
    enum PreparationError: Error { case windowBusy }
}
