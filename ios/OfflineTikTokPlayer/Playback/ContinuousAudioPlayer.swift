import AVFoundation
import PlayerCore
import Synchronization

/// Main-actor policy around a single audio graph. IDs and URLs stay here/the
/// decoder; the render thread sees only small visit tokens and PCM.
@MainActor
final class ContinuousAudioPlayer {
    struct Entry: Sendable { let id: String; let token: Int; let slot: Int; let frames: Int64 }
    private struct PreparationJob: Sendable {
        let token: Int
        let slot: Int
        var runner: Task<Void, Never>?
        var invalidated = false
        var waiters: [UUID: ContinuousAudioPreparationWaiter] = [:]
    }
    private struct PreparationSubscription: Sendable {
        let id: String
        let token: Int
        let key: UUID
        let waiter: ContinuousAudioPreparationWaiter
    }
    let renderer: ContinuousPCMRenderer
    private(set) var graph: ContinuousAudioGraph
    private let decoder: ContinuousPCMDecoder
    #if DEBUG
    private nonisolated let debugNativeLaneActivityRecorder: ContinuousPCMDecoder.DebugNativeLaneActivityRecorder?
    private var debugActivePreparationCalls = 0
    private var debugPreparationCounterOverflowed = false
    #endif
    private var entries: [String: Entry] = [:]
    private var preparing: [String: PreparationJob] = [:]
    private var reservedSlots = Set<Int>()
    private var reservedTokens = Set<Int>()
    private var nextToken = 1
    private var window = Set<String>()
    private var successors: [Int: Int] = [:]
    private(set) var selectedID: String?
    private var renderingPermitted = false
    private var failedTokens = Set<Int>()
    private var pendingPosition: (version: Int, position: Double)?

    #if DEBUG
    init(debugNativeLaneActivityRecorder: ContinuousPCMDecoder.DebugNativeLaneActivityRecorder? = nil,
         debugRenderAccounting: ContinuousPCMRenderer.DebugRenderAccountingRecorder? = nil,
         debugAcceptedPCMOrigin: DebugAcceptedPCMOriginRecorder? = nil,
         debugFirstFailure: ContinuousPCMRenderer.DebugFirstFailureRecorder? = nil) {
        renderer = ContinuousPCMRenderer(debugRenderAccounting: debugRenderAccounting, debugFirstFailure: debugFirstFailure)
        self.debugNativeLaneActivityRecorder = debugNativeLaneActivityRecorder
        graph = ContinuousAudioGraph(renderer: renderer)
        decoder = ContinuousPCMDecoder(renderer: renderer, debugNativeLaneActivityRecorder: debugNativeLaneActivityRecorder,
                                       debugAcceptedPCMOrigin: debugAcceptedPCMOrigin)
    }
    #else
    init() {
        renderer = ContinuousPCMRenderer()
        graph = ContinuousAudioGraph(renderer: renderer)
        decoder = ContinuousPCMDecoder(renderer: renderer)
    }
    #endif
    deinit {
        for job in preparing.values {
            job.runner?.cancel()
            for waiter in job.waiters.values { waiter.resolve(.failure(CancellationError())) }
        }
        decoder.shutdown(); graph.engine.stop()
    }
    var isSelected: Bool { selectedID != nil }

    #if DEBUG
    func debugAcceptedPCMOriginSnapshot(_ completion: @escaping @Sendable (DebugAcceptedPCMOriginSnapshot?) -> Void) {
        decoder.debugAcceptedPCMOriginSnapshot(completion)
    }

    struct DebugPreparationState: Sendable {
        let activeCalls: Int
        let sharedTasks: Int
        let reservedSlots: Int
        let nextToken: Int
        let counterOverflowed: Bool
    }
    var debugPreparationState: DebugPreparationState {
        DebugPreparationState(activeCalls: debugActivePreparationCalls,
            sharedTasks: preparing.count, reservedSlots: reservedSlots.count,
            nextToken: nextToken, counterOverflowed: debugPreparationCounterOverflowed)
    }
    func debugSetNativeReadGate(_ gate: ContinuousPCMDecoder.DebugNativeReadGate) {
        decoder.debugSetNativeReadGate(gate)
    }
    /// Direct independent scalar record read; it does not cohere with the worker snapshot.
    nonisolated func debugNativeLaneActivitySnapshot(at laneIndex: Int) -> ContinuousPCMDecoder.DebugNativeLaneActivitySnapshot? {
        debugNativeLaneActivityRecorder?.snapshot(at: laneIndex)
    }
    var debugSelectionState: (selectedToken: Int, pendingVersion: Int?) {
        (selectedID.flatMap { entries[$0]?.token } ?? 0, pendingPosition?.version)
    }
    func debugDecoderFailureState(_ completion: @escaping @Sendable (ContinuousPCMDecoder.DebugFailureState) -> Void) {
        decoder.debugFailureState(completion)
    }
    func debugShutdown(_ completion: @escaping @Sendable (Bool) -> Void) {
        cancelPreparations(outside: [])
        decoder.shutdown()
        decoder.debugAfterShutdown(completion)
    }
    #endif
    var preparedCount: Int { entries.count }
    var snapshot: ContinuousPCMRenderer.Snapshot { renderer.snapshot }
    var currentEntry: Entry? { entries.values.first { $0.token == renderer.snapshot.token } }
    func entry(for id: String) -> Entry? {
        entries[id].flatMap { failedTokens.contains($0.token) ? nil : $0 }
    }
    func entry(forToken token: Int) -> Entry? { entries.values.first { $0.token == token } }

    func setWindow(_ ids: Set<String>) {
        window = ids
        cancelPreparations(outside: ids)
        // Clear stale links before retiring an offscreen slot. The current
        // natural successor is installed explicitly after preparation.
        let retained = Set(entries.values.filter { ids.contains($0.id) }.map(\.token))
        for (token, next) in successors where !retained.contains(next) {
            renderer.setSuccessor(token: 0, for: token)
            successors[token] = nil
        }
        evictUnused()
    }

    private func cancelPreparations(outside ids: Set<String>) {
        for id in Array(preparing.keys) where !ids.contains(id) {
            // Keep the job and its reservation until its runner settles. New
            // callers can await that cancellation without creating another job.
            preparing[id]?.invalidated = true
            preparing[id]?.runner?.cancel()
        }
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
        #if DEBUG
        let debugCallCounted = debugActivePreparationCalls < Int.max
        if debugCallCounted { debugActivePreparationCalls += 1 }
        else { debugPreparationCounterOverflowed = true }
        defer { if debugCallCounted { debugActivePreparationCalls -= 1 } }
        #endif
        if let entry = entries[id], !failedTokens.contains(entry.token) { return entry }
        var available: Int?
        // Rapid direction changes may briefly pin all slots. Yield to the one
        // decoder and render acknowledgement instead of skipping valid media.
        for _ in 0..<200 {
            try Task.checkCancellation()
            // Another caller can publish a cache entry/job while this caller
            // sleeps for a slot. Coalesce again before any new reservation.
            if let entry = entries[id], !failedTokens.contains(entry.token) { return entry }
            if let token = preparing[id]?.token {
                let subscription = subscribeToPreparation(id: id, token: token)
                return try await waitForPreparation(subscription)
            }
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
        try Task.checkCancellation()
        if let entry = entries[id], !failedTokens.contains(entry.token) { return entry }
        if let token = preparing[id]?.token {
            let subscription = subscribeToPreparation(id: id, token: token)
            return try await waitForPreparation(subscription)
        }
        guard let slot = available else { throw PreparationError.windowBusy }
        let token = nextToken; nextToken += 1
        reservedSlots.insert(slot); reservedTokens.insert(token)
        preparing[id] = PreparationJob(token: token, slot: slot)
        let subscription = subscribeToPreparation(id: id, token: token)
        // Exactly one runner observes the real decoder result. Neither the job
        // nor CAP is captured strongly across the native/metadata await.
        let runner = Task { @MainActor [weak self, decoder] in
            let result: Result<ContinuousPCMDecoder.Prepared, Error>
            do { result = .success(try await decoder.prepare(url: url, token: token, slot: slot)) }
            catch { result = .failure(error) }
            self?.finishPreparation(id: id, token: token, slot: slot, result: result)
        }
        preparing[id]?.runner = runner
        return try await waitForPreparation(subscription)
    }

    private func subscribeToPreparation(id: String, token: Int) -> PreparationSubscription {
        let subscription = PreparationSubscription(id: id, token: token,
            key: UUID(), waiter: ContinuousAudioPreparationWaiter())
        // Called synchronously after the matching job lookup/creation. There is
        // no suspension between choosing the job and registering this waiter.
        guard preparing[id]?.token == token else {
            subscription.waiter.resolve(.failure(ContinuousPCMDecoder.Failure.cancelled))
            return subscription
        }
        preparing[id]?.waiters[subscription.key] = subscription.waiter
        return subscription
    }

    private func waitForPreparation(_ subscription: PreparationSubscription) async throws -> Entry {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                subscription.waiter.install(continuation)
            }
        } onCancel: {
            // Completing the caller is independent of native completion and of
            // this short actor cleanup. No per-caller task awaits the shared job.
            subscription.waiter.resolve(.failure(CancellationError()))
            Task { @MainActor [weak self] in
                guard let self, self.preparing[subscription.id]?.token == subscription.token else { return }
                self.preparing[subscription.id]?.waiters[subscription.key] = nil
            }
        }
    }

    private func finishPreparation(id: String, token: Int, slot: Int,
                                   result: Result<ContinuousPCMDecoder.Prepared, Error>) {
        guard let job = preparing[id], job.token == token, job.slot == slot else { return }
        preparing[id] = nil; reservedSlots.remove(slot); reservedTokens.remove(token)
        let outcome: Result<Entry, Error>
        if job.invalidated { outcome = .failure(ContinuousPCMDecoder.Failure.cancelled) }
        else {
            switch result {
            case .success(let prepared):
                // Failure may arrive after prefix publication but before this
                // actor receives the prepared result, as in the original path.
                outcome = failedTokens.contains(token)
                    ? .failure(ContinuousPCMDecoder.Failure.cannotDecode)
                    : .success(Entry(id: id, token: token, slot: slot, frames: prepared.totalFrames))
            case .failure(let error): outcome = .failure(error)
            }
        }
        switch outcome {
        case .success(let entry):
            entries[id] = entry
            evictUnused()
        case .failure:
            failedTokens.remove(token)
            if renderer.source(at: slot).token == token { _ = renderer.retireSource(at: slot) }
            decoder.retain(tokens: Set(entries.values.map(\.token)).union(reservedTokens))
        }
        // The shared job owns finalization even when its creating caller left.
        // Canceled cells are already terminal; resolving them again is a no-op.
        for waiter in job.waiters.values { waiter.resolve(outcome) }
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
    func clearSelection() {
        suspend(); selectedID = nil
        // Keep the old slot pinned until the render callback acknowledges silence.
        // A delayed failure for that old token no longer owns this pending selection.
        let version = renderer.select(token: 0)
        pendingPosition = (version, 0)
    }
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

/// A one-shot caller result. Only this cell crosses cancellation-handler
/// threads; job membership and all playback policy stay on the main actor.
private final class ContinuousAudioPreparationWaiter: Sendable {
    private typealias Outcome = Result<ContinuousAudioPlayer.Entry, Error>
    private struct State {
        var completed = false
        var continuation: CheckedContinuation<ContinuousAudioPlayer.Entry, Error>?
        var result: Outcome?
    }
    private let state = Mutex(State())

    // Exactly one installation per registered subscription. Completion can win
    // before it: keep that one result only until installation consumes it.
    func install(_ continuation: CheckedContinuation<ContinuousAudioPlayer.Entry, Error>) {
        let ready: Outcome? = state.withLock { value in
            if value.completed {
                let result = value.result; value.result = nil
                return result
            }
            value.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    func resolve(_ result: Result<ContinuousAudioPlayer.Entry, Error>) {
        let continuation: CheckedContinuation<ContinuousAudioPlayer.Entry, Error>? = state.withLock { value in
            guard !value.completed else { return nil }
            value.completed = true
            let continuation = value.continuation; value.continuation = nil
            if continuation == nil { value.result = result }
            return continuation
        }
        continuation?.resume(with: result)
    }
}
