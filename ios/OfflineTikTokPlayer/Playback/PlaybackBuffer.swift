import AVFoundation

/// One persistent player for the feed, background audio, remote commands and PiP.
/// The second item is prepared while the current item plays, never after a swipe.
@MainActor
final class PlaybackBuffer {
    enum NativePauseOwner: Int, Sendable { case service = 1, buffer = 2 }
    enum NativePauseReason: Int, Sendable {
        case queueAdvanceMismatch = 1, pauseRequested = 2, scrollQueueExhausted = 3, coldReplacement = 4
        case engineRestartFailed = 5, audioSessionActivationFailed = 6, foregroundInterrupted = 7
        case interruptionBegan = 8, presentationVideoDisabled = 9
        case recoverMissingCurrent = 101, previousAdoption = 102
    }
    struct NativePauseEvent: Sendable {
        let owner: NativePauseOwner
        let reason: NativePauseReason
        // Each owner has its own command namespace. Once saturated, this is no
        // longer a unique command ID; the explicit flag preserves that limit.
        let commandID: UInt64
        let commandIDSaturated: Bool
        let entryUptime: Double
        let returnUptime: Double
        // Buffer callbacks cannot learn service identity before the native call.
        let entryGeneration: Int?
    }
    enum DiagnosticAction: Int, Sendable {
        case offscreenSeekBegin = 0, offscreenSeekNativeCompletion = 1, offscreenSeekObserved = 2
        case cancelPendingSeeks = 3, previousAdoptionBegin = 4, previousAdoptionObserved = 5
    }
    enum DiagnosticReason: Int, Sendable {
        case none = 0, retainPrevious = 1, replace = 2, discardPrevious = 3, stagePrevious = 4
    }
    struct DiagnosticEvent: Sendable {
        let action: DiagnosticAction
        let reason: DiagnosticReason
        let operationID: UInt64
        // Native completion time can precede MainActor delivery. Identity is
        // measured only at actor observation, never on the native callback.
        let actionUptime: Double
        let targetIsCurrent: Bool?
        let finished: Bool?
    }
    struct Prepared {
        let mediaID: String
        let item: AVPlayerItem
        let isLocal: Bool
        var needsRewind = false
        var reachedEnd = false
    }
    let player = AVQueuePlayer()
    private var next: Prepared?
    private var loopReserve: Prepared?
    private var active: Prepared?
    private var previous: Prepared?
    private var observation: NSKeyValueObservation?
    var onDiagnosticEvent: ((DiagnosticEvent) -> Void)?
    private var diagnosticOperationID: UInt64 = 0
    #if DEBUG
    var debugNativePlayerTraceEnabled = false
    var onNativePauseDiagnostic: ((NativePauseEvent) -> Void)?
    private(set) var debugNativePlayerPauseCount: UInt64 = 0
    #endif
    var didAdvance: ((Prepared) -> Void)?
    var automaticAdvancementEnabled = true { didSet { updateEndAction() } }
    var usesExternalClock = false { didSet { updateEndAction() } }
    var previousMediaID: String? { previous?.mediaID }
    var retainedItems: [AVPlayerItem] {
        var ids = Set<ObjectIdentifier>()
        return (player.items() + [active?.item, next?.item, loopReserve?.item, previous?.item].compactMap { $0 })
            .filter { ids.insert(ObjectIdentifier($0)).inserted }
    }
    var retainedItemCount: Int { retainedItems.count }
    var nextMediaID: String? { next?.mediaID }
    var hasLoopReserve: Bool { loopReserve != nil }
    func hasPrepared(_ mediaID: String) -> Bool {
        guard let next else { return false }
        return next.mediaID == mediaID && next.item.status != .failed && player.items().dropFirst().first === next.item
    }

    init() {
        player.actionAtItemEnd = .pause
        observation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.synchronize() }
        }
    }

    private func updateEndAction() {
        player.actionAtItemEnd = automaticAdvancementEnabled && next != nil ? .advance : .pause
        // Full local files need no HTTP stall-minimization delay. Streamed items
        // keep AVFoundation's waiting/recovery policy until a verified local handoff.
        let localWindow = active?.isLocal == true && next?.isLocal != false && loopReserve?.isLocal != false
        // Host-clock setRate requires waiting disabled, including while a remote
        // neighbour is staged. Standalone streamed players retain automatic recovery.
        player.automaticallyWaitsToMinimizeStalling = !usesExternalClock && !localWindow
    }

    private func retainPrevious(before prepared: Prepared) {
        if let active, active.mediaID != prepared.mediaID {
            cancelPreviousSeeks(reason: .retainPrevious)
            previous = Prepared(mediaID: active.mediaID, item: active.item, isLocal: active.isLocal, needsRewind: true)
        }
    }

    private func preparePreviousStart() {
        guard let previous, previous.needsRewind, previous.item.status == .readyToPlay,
              previous.item !== player.currentItem else { return }
        let item = previous.item
        let operationID = beginDiagnostic(.offscreenSeekBegin, targetIsCurrent: false)
        // Rewind off-screen, not on the Previous button's critical path. Weak
        // captures and cancellation on eviction bound preparation to one item.
        item.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
            let nativeCompletionUptime = operationID.map { _ in ProcessInfo.processInfo.systemUptime }
            Task { @MainActor [weak self, weak item] in
                guard let self else { return }
                self.recordDiagnostic(.offscreenSeekNativeCompletion, operationID: operationID,
                    actionUptime: nativeCompletionUptime, finished: finished)
                guard let item else { return }
                var observedCurrent: Bool?
                if operationID != nil, self.onDiagnosticEvent != nil {
                    observedCurrent = self.player.currentItem === item
                    self.recordDiagnostic(.offscreenSeekObserved, operationID: operationID,
                        targetIsCurrent: observedCurrent, finished: finished)
                }
                guard finished, self.previous?.item === item else { return }
                // Reuse the optional diagnostic identity read; with observation
                // disabled this keeps the original short-circuited native reads.
                guard !(observedCurrent ?? (self.player.currentItem === item)),
                      abs(item.currentTime().seconds) < 0.005 else { return }
                self.previous?.needsRewind = false
            }
        }
    }

    /// IDs identify commands, not items. A cancellation has its own ID because
    /// it can affect multiple pending rewind IDs; their completions stay paired.
    private func beginDiagnostic(_ action: DiagnosticAction, reason: DiagnosticReason = .none,
                                 targetIsCurrent: Bool?) -> UInt64? {
        guard onDiagnosticEvent != nil else { return nil }
        diagnosticOperationID &+= 1
        let operationID = diagnosticOperationID
        recordDiagnostic(action, operationID: operationID, reason: reason, targetIsCurrent: targetIsCurrent)
        return operationID
    }

    private func recordDiagnostic(_ action: DiagnosticAction, operationID: UInt64?,
                                  reason: DiagnosticReason = .none, actionUptime: Double? = nil,
                                  targetIsCurrent: Bool? = nil, finished: Bool? = nil) {
        guard let operationID, let observer = onDiagnosticEvent else { return }
        observer(DiagnosticEvent(action: action, reason: reason, operationID: operationID,
            actionUptime: actionUptime ?? ProcessInfo.processInfo.systemUptime,
            targetIsCurrent: targetIsCurrent, finished: finished))
    }

    private func cancelPreviousSeeks(reason: DiagnosticReason) {
        guard let item = previous?.item else { return }
        if onDiagnosticEvent != nil {
            _ = beginDiagnostic(.cancelPendingSeeks, reason: reason, targetIsCurrent: player.currentItem === item)
        }
        item.cancelPendingSeeks()
    }

    private func pauseNativePlayer(reason: NativePauseReason) {
        #if DEBUG
        if debugNativePlayerTraceEnabled, let observer = onNativePauseDiagnostic {
            let increment = debugNativePlayerPauseCount.addingReportingOverflow(1)
            debugNativePlayerPauseCount = increment.overflow ? .max : increment.partialValue
            let commandID = debugNativePlayerPauseCount
            let entry = ProcessInfo.processInfo.systemUptime
            player.pause()
            let returned = ProcessInfo.processInfo.systemUptime
            // Publish only after the real call. The interval includes existing
            // synchronous callbacks/descheduling, not just SDK execution time.
            observer(NativePauseEvent(owner: .buffer, reason: reason, commandID: commandID,
                commandIDSaturated: increment.overflow, entryUptime: entry, returnUptime: returned, entryGeneration: nil))
            return
        }
        #endif
        player.pause()
    }

    /// KVO may be delivered after a swipe. Always reconcile actual object identity.
    func synchronize() {
        let prepared: Prepared
        if let next, player.currentItem === next.item {
            prepared = next
            retainPrevious(before: prepared)
            self.next = loopReserve
        } else if let reserve = loopReserve, player.currentItem === reserve.item {
            // Multiple currentItem changes can coalesce before MainActor KVO runs.
            prepared = reserve
            next = nil
        } else if player.currentItem == nil, let last = loopReserve ?? next {
            // A suspended main actor can miss two or three loop boundaries. Recover
            // the complete source through the service's guarded rewind, not a tail trim.
            let repeating = last.mediaID == active?.mediaID && last.mediaID == next?.mediaID
            prepared = Prepared(mediaID: last.mediaID, item: last.item, isLocal: last.isLocal,
                                needsRewind: repeating, reachedEnd: !repeating)
            next = nil
            pauseNativePlayer(reason: .recoverMissingCurrent)
            player.insert(last.item, after: nil)
        } else { return }
        active = prepared; loopReserve = nil; updateEndAction()
        preparePreviousStart()
        didAdvance?(prepared)
    }

    func replace(with item: AVPlayerItem?, mediaID: String? = nil, isLocal: Bool = true) {
        if let active, active.item !== item {
            cancelPreviousSeeks(reason: .replace)
            previous = Prepared(mediaID: active.mediaID, item: active.item, isLocal: active.isLocal, needsRewind: true)
        }
        active = item.flatMap { item in mediaID.map { Prepared(mediaID: $0, item: item, isLocal: isLocal) } }
        next = nil; loopReserve = nil
        player.removeAllItems()
        if let item { player.insert(item, after: nil) }
        updateEndAction()
        preparePreviousStart()
    }

    func discardNext() {
        for item in player.items().dropFirst() { player.remove(item) }
        next = nil; loopReserve = nil
        updateEndAction()
    }

    func discardPrevious() { cancelPreviousSeeks(reason: .discardPrevious); previous = nil }
    func stagePrevious(_ prepared: Prepared) {
        guard previous?.mediaID != prepared.mediaID else { return }
        cancelPreviousSeeks(reason: .stagePrevious)
        previous = prepared
    }

    func stage(_ prepared: Prepared, requireLocal: Bool = false, after mediaID: String? = nil) {
        synchronize()
        if let mediaID, active?.mediaID != mediaID { return }
        guard let current = player.currentItem else { return }
        guard !requireLocal || prepared.isLocal else { return }
        if let next, next.mediaID == prepared.mediaID, next.item.status != .failed,
           player.items().dropFirst().first === next.item,
           !(requireLocal && !next.isLocal && prepared.isLocal) { return }
        discardNext()
        guard player.canInsert(prepared.item, after: current) else { return }
        player.insert(prepared.item, after: current)
        next = prepared
        updateEndAction()
    }

    /// Keep the following loop boundary prepared too. This is bounded to exactly
    /// one reserve, and each replica has its own audio-processing tap state.
    func stageLoopReserve(_ prepared: Prepared) {
        synchronize()
        guard loopReserve == nil, let next, active?.mediaID == prepared.mediaID,
              next.mediaID == prepared.mediaID, player.items().count == 2,
              player.canInsert(prepared.item, after: next.item) else { return }
        player.insert(prepared.item, after: next.item)
        loopReserve = prepared
        updateEndAction()
    }

    func advance(to mediaID: String, allowRemote: Bool = true) -> Prepared? {
        if !hasPrepared(mediaID), let prepared = previous, prepared.mediaID == mediaID, prepared.item.status != .failed,
           prepared.isLocal || allowRemote {
            let operationID = onDiagnosticEvent == nil ? nil
                : beginDiagnostic(.previousAdoptionBegin, targetIsCurrent: player.currentItem === prepared.item)
            pauseNativePlayer(reason: .previousAdoption)
            previous = nil
            replace(with: prepared.item, mediaID: mediaID, isLocal: prepared.isLocal)
            if operationID != nil, onDiagnosticEvent != nil {
                recordDiagnostic(.previousAdoptionObserved, operationID: operationID,
                    targetIsCurrent: player.currentItem === prepared.item)
            }
            return prepared
        }
        guard let prepared = next, prepared.mediaID == mediaID, prepared.item.status != .failed,
              prepared.isLocal || allowRemote,
              player.currentItem === prepared.item || player.items().dropFirst().first === prepared.item else { return nil }
        retainPrevious(before: prepared); next = loopReserve; loopReserve = nil; active = prepared
        if player.currentItem !== prepared.item { player.advanceToNextItem() }
        updateEndAction()
        preparePreviousStart()
        return prepared
    }
}
