import AVFoundation

/// One persistent player for the feed, background audio, remote commands and PiP.
/// The second item is prepared while the current item plays, never after a swipe.
@MainActor
final class PlaybackBuffer {
    struct Prepared {
        let mediaID: String
        let item: AVPlayerItem
        let isLocal: Bool
        var needsRewind = false
        var reachedEnd = false
        var videoResource: ContinuousPictureInPicture.PreparedVideoResource? = nil
        // Fresh staged items also have needsRewind=false. Only an owned native
        // offscreen rewind may establish this separate startup provenance.
        fileprivate(set) var completedPreviousZeroRewind = false
        init(mediaID: String, item: AVPlayerItem, isLocal: Bool, needsRewind: Bool = false,
             reachedEnd: Bool = false, videoResource: ContinuousPictureInPicture.PreparedVideoResource? = nil) {
            self.mediaID = mediaID; self.item = item; self.isLocal = isLocal
            self.needsRewind = needsRewind; self.reachedEnd = reachedEnd; self.videoResource = videoResource
        }
    }
    let player = AVQueuePlayer()
    private var next: Prepared?
    private var loopReserve: Prepared?
    private var active: Prepared?
    private var previousRevision: UInt64 = 0
    private var previous: Prepared? {
        didSet { if previousRevision < .max { previousRevision += 1 } }
    }
    private var observation: NSKeyValueObservation?
    var didAdvance: ((Prepared) -> Void)?
    var automaticAdvancementEnabled = true { didSet { updateEndAction() } }
    var usesExternalClock = false { didSet { updateEndAction() } }
    var previousMediaID: String? { previous?.mediaID }
    #if DEBUG
    let debugSuppressesPlayerRendering: Bool
    let debugNativeGeometry: Bool?
    var debugPreviousNeedsRewind: Bool? { previous?.needsRewind }
    var debugPreviousCompletedZeroRewind: Bool? { previous?.completedPreviousZeroRewind }
    var debugPreviousRevision: UInt64 { previousRevision }
    var onDebugPreviousRewindCompletion: (@MainActor (UInt64, Bool, Bool) -> Void)?
    var onDebugPreviousRewindRead: (@MainActor () -> Void)?
    var debugQueuedPreviousAdvance: Bool?
    func debugResourceIdentity(for item: ObjectIdentifier) -> ObjectIdentifier? {
        videoResources.first {
            $0.item.map(ObjectIdentifier.init) == item && $0.isAttached && !$0.isRetired
        }.map(ObjectIdentifier.init)
    }
    enum DebugAdvanceRoute: Int { case previousReplacement = 0, queuedAdvance = 1 }
    var onDebugAdvanceBranch: (@MainActor (DebugAdvanceRoute, String, ObjectIdentifier) -> Void)?
    #endif
    var retainedItems: [AVPlayerItem] {
        var ids = Set<ObjectIdentifier>()
        return (player.items() + [active?.item, next?.item, loopReserve?.item, previous?.item].compactMap { $0 })
            .filter { ids.insert(ObjectIdentifier($0)).inserted }
    }
    var retainedItemCount: Int { retainedItems.count }
    var nextMediaID: String? { next?.mediaID }
    var hasLoopReserve: Bool { loopReserve != nil }
    private var videoResources: [ContinuousPictureInPicture.PreparedVideoResource] {
        [active, previous, next, loopReserve].compactMap { $0?.videoResource }
    }
    private func sameOwner(_ first: Prepared?, _ second: Prepared?) -> Bool {
        first?.item === second?.item && first?.mediaID == second?.mediaID
            && first?.videoResource === second?.videoResource
    }
    func resource(for item: AVPlayerItem) -> ContinuousPictureInPicture.PreparedVideoResource? {
        videoResources.first { $0.item === item && $0.isAttached && !$0.isRetired }
    }
    private func retireReleased(_ candidates: [ContinuousPictureInPicture.PreparedVideoResource]) {
        var seen = Set<ObjectIdentifier>()
        for resource in candidates where seen.insert(ObjectIdentifier(resource)).inserted {
            // Re-read final slots after each retirement's SDK calls, which may notify observers.
            if !videoResources.contains(where: { $0 === resource }) { resource.retire() }
        }
    }
    /// Metadata only; the consuming advance still validates the live item/owner.
    func hasRemotePreparation(for mediaID: String) -> Bool {
        [next, loopReserve, previous].compactMap { $0 }.contains { $0.mediaID == mediaID && !$0.isLocal }
    }

    func hasPrepared(_ mediaID: String) -> Bool {
        guard let next else { return false }
        return next.mediaID == mediaID && next.item.status != .failed && player.items().dropFirst().first === next.item
    }

    #if DEBUG
    init(debugSuppressesPlayerRendering: Bool) {
        self.debugSuppressesPlayerRendering = debugSuppressesPlayerRendering
        debugNativeGeometry = nil
        player.actionAtItemEnd = .pause
        observation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.synchronize() }
        }
    }
    init(debugNativeGeometry: Bool) {
        self.debugNativeGeometry = debugNativeGeometry
        debugSuppressesPlayerRendering = false
        player.actionAtItemEnd = .pause
        observation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.synchronize() }
        }
    }
    func debugPrepareVideoResource(for item: AVPlayerItem) async throws -> ContinuousPictureInPicture.VideoResourcePreparation {
        if let enabled = debugNativeGeometry {
            return try await ContinuousPictureInPicture.debugPrepareVideoResource(for: item, nativeGeometry: enabled)
        }
        return try await ContinuousPictureInPicture.prepareVideoResource(for: item)
    }
    #endif
    init() {
        #if DEBUG
        debugSuppressesPlayerRendering = false
        debugNativeGeometry = nil
        #endif
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

    @discardableResult
    private func retainPrevious(before prepared: Prepared, ifEligible: () -> Bool = { true }) -> Bool {
        guard ifEligible() else { return false }
        if let outgoing = active, outgoing.mediaID != prepared.mediaID {
            let oldPrevious = previous
            oldPrevious?.item.cancelPendingSeeks()
            guard ifEligible(), let live = active, live.item === outgoing.item,
                  sameOwner(live, outgoing), sameOwner(previous, oldPrevious) else { return false }
            previous = Prepared(mediaID: live.mediaID, item: live.item, isLocal: live.isLocal,
                                needsRewind: true, videoResource: live.videoResource)
        }
        return true
    }

    private func preparePreviousStart() {
        // Keep the saturated value invalid even after a final slot mutation.
        guard let candidate = previous, candidate.needsRewind, previousRevision < UInt64.max - 1 else { return }
        let revision = previousRevision, item = candidate.item
        let status = item.status, current = player.currentItem
        // SDK reads can notify observers. Recheck the slot after both reads;
        // item identity alone cannot distinguish a later retained visit of A.
        guard previousRevision == revision, sameOwner(previous, candidate),
              previous?.needsRewind == true, status == .readyToPlay, current !== item else { return }
        previousRevision += 1
        let rewindRevision = previousRevision
        // Rewind off-screen, not on the Previous button's critical path. Weak
        // captures and cancellation on eviction bound preparation to one item.
        item.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
            Task { @MainActor in
                guard let self, let item else { return }
                let accepted = self.completePreviousRewind(item, revision: rewindRevision, finished: finished)
                #if DEBUG
                self.onDebugPreviousRewindCompletion?(rewindRevision, finished, accepted)
                #endif
            }
        }
    }

    private func completePreviousRewind(_ item: AVPlayerItem, revision: UInt64, finished: Bool) -> Bool {
        guard finished, revision < .max, previousRevision == revision,
              previous?.item === item, previous?.needsRewind == true else { return false }
        let position = item.currentTime().seconds
        let current = player.currentItem
        #if DEBUG
        onDebugPreviousRewindRead?()
        #endif
        guard previousRevision == revision, var committed = previous,
              committed.item === item, committed.needsRewind, current !== item,
              position.isFinite, abs(position) < 0.005 else { return false }
        committed.needsRewind = false
        committed.completedPreviousZeroRewind = true
        previous = committed
        return true
    }

    /// KVO may be delivered after a swipe. Always reconcile actual object identity.
    func synchronize() {
        let oldResources = videoResources
        defer { retireReleased(oldResources) }
        let prepared: Prepared
        if let next, player.currentItem === next.item {
            prepared = next
            guard retainPrevious(before: prepared) else { return }
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
                                needsRewind: repeating, reachedEnd: !repeating, videoResource: last.videoResource)
            next = nil
            player.pause()
            player.insert(last.item, after: nil)
        } else { return }
        active = prepared; loopReserve = nil; updateEndAction()
        preparePreviousStart()
        didAdvance?(prepared)
    }

    @discardableResult
    func replace(with item: AVPlayerItem?, mediaID: String? = nil, isLocal: Bool = true,
                 videoResource: ContinuousPictureInPicture.PreparedVideoResource? = nil,
                 videoPreparation: ContinuousPictureInPicture.VideoResourcePreparation? = nil,
                 ifEligible: () -> Bool = { true }) -> Bool {
        let incoming = videoResource ?? (videoPreparation == nil ? item.flatMap { resource(for: $0) } : nil)
        let oldResources = videoResources + [incoming].compactMap { $0 }
        defer { retireReleased(oldResources) }
        guard ifEligible() else { return false }
        if let active, active.item !== item {
            previous?.item.cancelPendingSeeks()
            previous = Prepared(mediaID: active.mediaID, item: active.item, isLocal: active.isLocal,
                                needsRewind: true, videoResource: active.videoResource)
        }
        // Publish the final eviction state before installing any additional SDK output.
        active = nil
        next = nil; loopReserve = nil
        player.removeAllItems()
        retireReleased(oldResources.filter { $0 !== incoming })
        guard ifEligible() else { updateEndAction(); return false }
        #if DEBUG
        let installed = videoPreparation?.install(debugSuppressesPlayerRendering: debugSuppressesPlayerRendering,
                                                  ifEligible: ifEligible) ?? incoming
        #else
        let installed = videoPreparation?.install(ifEligible: ifEligible) ?? incoming
        #endif
        guard ifEligible() else { installed?.retire(); updateEndAction(); return false }
        active = item.flatMap { item in mediaID.map {
            Prepared(mediaID: $0, item: item, isLocal: isLocal, videoResource: installed)
        } }
        if let item { player.insert(item, after: nil) }
        updateEndAction()
        preparePreviousStart()
        return true
    }

    func discardNext() {
        let oldResources = videoResources
        defer { retireReleased(oldResources) }
        for item in player.items().dropFirst() { player.remove(item) }
        next = nil; loopReserve = nil
        updateEndAction()
    }

    func discardPrevious() {
        let oldResources = videoResources
        defer { retireReleased(oldResources) }
        previous?.item.cancelPendingSeeks(); previous = nil
    }

    /// Move a retained item into its intended forward slot without cancelling its rewind.
    /// False means exact queued ownership was not confirmed, not that no move committed.
    @discardableResult
    func promotePreviousToNext(mediaID: String, after currentID: String, allowRemote: Bool = true,
                               ifEligible: () -> Bool = { true }) -> Bool {
        guard ifEligible(), let candidate = previous, let current = active?.item else { return false }
        let oldResources = videoResources
        defer { retireReleased(oldResources) }
        @MainActor func ownsMoveSource(status: AVPlayerItem.Status, items: [AVPlayerItem],
                                       currentItem: AVPlayerItem?) -> Bool {
            return candidate.mediaID == mediaID && mediaID != currentID
                && candidate.item !== current && status != .failed
                && items.count == 1 && items.first === current && currentItem === current
                && active?.mediaID == currentID && active?.item === current
                && previous?.mediaID == mediaID && previous?.item === candidate.item
                && previous?.videoResource === candidate.videoResource && (previous?.isLocal == true || allowRemote)
                && next == nil && loopReserve == nil
        }
        let initialStatus = candidate.item.status
        let initialItems = player.items()
        let initialCurrent = player.currentItem
        guard ownsMoveSource(status: initialStatus, items: initialItems, currentItem: initialCurrent),
              player.canInsert(candidate.item, after: current) else { return false }
        let finalStatus = candidate.item.status
        let finalItems = player.items()
        let finalCurrent = player.currentItem
        // All potentially reentrant SDK reads precede the caller's final ownership check.
        guard ifEligible(),
              ownsMoveSource(status: finalStatus, items: finalItems, currentItem: finalCurrent),
              let committed = previous else { return false }
        // Destination ownership precedes source removal and all insertion notifications.
        // Copy the live Prepared value: a completed rewind must not become pending again.
        next = committed
        previous = nil
        player.insert(committed.item, after: current)
        updateEndAction()
        // A newer owner may have claimed these slots during an SDK notification.
        // Never undo that owner's move or remove/retire its item on this return path.
        let status = committed.item.status
        let items = player.items()
        let currentItem = player.currentItem
        return ifEligible() && status != .failed && items.count == 2 && items.first === current && items.last === committed.item
            && currentItem === current && active?.mediaID == currentID && active?.item === current
            && next?.mediaID == mediaID && next?.item === committed.item
            && next?.videoResource === committed.videoResource && loopReserve == nil
    }

    @discardableResult
    func stagePrevious(_ prepared: Prepared,
                       videoPreparation: ContinuousPictureInPicture.VideoResourcePreparation? = nil,
                       ifEligible: () -> Bool = { true }) -> Bool {
        let candidates = videoResources + [prepared.videoResource].compactMap { $0 }
        defer { retireReleased(candidates) }
        guard ifEligible(), previous?.mediaID != prepared.mediaID else { return false }
        previous?.item.cancelPendingSeeks()
        previous = nil
        retireReleased(candidates.filter { $0 !== prepared.videoResource })
        guard ifEligible() else { return false }
        var committed = prepared
        committed.completedPreviousZeroRewind = false
        #if DEBUG
        committed.videoResource = videoPreparation?.install(debugSuppressesPlayerRendering: debugSuppressesPlayerRendering,
                                                             ifEligible: ifEligible) ?? prepared.videoResource
        #else
        committed.videoResource = videoPreparation?.install(ifEligible: ifEligible) ?? prepared.videoResource
        #endif
        guard ifEligible() else { committed.videoResource?.retire(); return false }
        previous = committed
        return true
    }

    @discardableResult
    func stage(_ prepared: Prepared, requireLocal: Bool = false, after mediaID: String? = nil,
               videoPreparation: ContinuousPictureInPicture.VideoResourcePreparation? = nil,
               ifEligible: () -> Bool = { true }) -> Bool {
        let candidates = videoResources + [prepared.videoResource].compactMap { $0 }
        defer { retireReleased(candidates) }
        guard ifEligible() else { return false }
        synchronize()
        if let mediaID, active?.mediaID != mediaID { return false }
        guard let current = player.currentItem else { return false }
        guard !requireLocal || prepared.isLocal else { return false }
        if let next, next.mediaID == prepared.mediaID, next.item.status != .failed,
           player.items().dropFirst().first === next.item,
           !(requireLocal && !next.isLocal && prepared.isLocal) { return false }
        discardNext()
        guard ifEligible(), player.canInsert(prepared.item, after: current) else { return false }
        var committed = prepared
        committed.completedPreviousZeroRewind = false
        #if DEBUG
        committed.videoResource = videoPreparation?.install(debugSuppressesPlayerRendering: debugSuppressesPlayerRendering,
                                                             ifEligible: ifEligible) ?? prepared.videoResource
        #else
        committed.videoResource = videoPreparation?.install(ifEligible: ifEligible) ?? prepared.videoResource
        #endif
        guard ifEligible() else { committed.videoResource?.retire(); return false }
        player.insert(prepared.item, after: current)
        next = committed
        updateEndAction()
        return true
    }

    /// Keep the following loop boundary prepared too. This is bounded to exactly
    /// one reserve, and each replica has its own audio-processing tap state.
    func stageLoopReserve(_ prepared: Prepared) {
        let candidates = videoResources + [prepared.videoResource].compactMap { $0 }
        defer { retireReleased(candidates) }
        synchronize()
        guard loopReserve == nil, let next, active?.mediaID == prepared.mediaID,
              next.mediaID == prepared.mediaID, player.items().count == 2,
              player.canInsert(prepared.item, after: next.item) else { return }
        player.insert(prepared.item, after: next.item)
        var committed = prepared
        committed.completedPreviousZeroRewind = false
        loopReserve = committed
        updateEndAction()
    }

    /// Evict only the captured forward window, then transfer the live retained item.
    /// An unsuccessful move may have committed; the caller must resolve afresh rather
    /// than retry replacement with a captured Prepared value.
    private func queuePrevious(_ candidate: Prepared, allowRemote: Bool,
                               ifEligible: () -> Bool) -> Bool {
        guard let outgoing = active else { return false }
        let staged = next, reserve = loopReserve
        let forward = [staged?.item, reserve?.item].compactMap { $0 }
        @MainActor func ownsSource() -> Bool {
            sameOwner(active, outgoing)
                && previous?.item === candidate.item && previous?.mediaID == candidate.mediaID
                && previous?.videoResource === candidate.videoResource
                && (previous?.isLocal == true || allowRemote)
        }
        let items = player.items(), current = player.currentItem, status = candidate.item.status
        guard ifEligible(), ownsSource(), status != .failed,
              sameOwner(next, staged), sameOwner(loopReserve, reserve),
              candidate.item !== outgoing.item, candidate.mediaID != outgoing.mediaID,
              current === outgoing.item,
              items.map(ObjectIdentifier.init) == ([outgoing.item] + forward).map(ObjectIdentifier.init) else { return false }
        // Clear the old slots before SDK notifications can install a newer window.
        next = nil; loopReserve = nil
        var remaining = forward
        for item in forward {
            let items = player.items(), current = player.currentItem
            guard ifEligible(), ownsSource(), next == nil, loopReserve == nil,
                  current === outgoing.item,
                  items.map(ObjectIdentifier.init) == ([outgoing.item] + remaining).map(ObjectIdentifier.init) else { return false }
            player.remove(item)
            remaining.removeFirst()
        }
        return promotePreviousToNext(mediaID: candidate.mediaID, after: outgoing.mediaID,
            allowRemote: allowRemote, ifEligible: {
                ifEligible() && self.sameOwner(self.active, outgoing)
                    && (self.sameOwner(self.previous, candidate) || self.sameOwner(self.next, candidate))
            })
    }

    func advance(to mediaID: String, allowRemote: Bool = true,
                 ifEligible: () -> Bool = { true }) -> Prepared? {
        let oldResources = videoResources
        defer { retireReleased(oldResources) }
        guard ifEligible() else { return nil }
        let alreadyQueued = hasPrepared(mediaID)
        guard ifEligible() else { return nil }
        if !alreadyQueued, let prepared = previous, prepared.mediaID == mediaID {
            let status = prepared.item.status
            guard ifEligible(), previous?.item === prepared.item, status != .failed,
                  previous?.isLocal == true || allowRemote else { return nil }
            #if DEBUG
            let queuedPrevious = usesExternalClock && debugQueuedPreviousAdvance != false
            #else
            let queuedPrevious = usesExternalClock
            #endif
            if queuedPrevious {
                guard queuePrevious(prepared, allowRemote: allowRemote, ifEligible: ifEligible) else { return nil }
            } else {
                let outgoing = active
                #if DEBUG
                onDebugAdvanceBranch?(.previousReplacement, prepared.mediaID, ObjectIdentifier(prepared.item))
                #endif
                guard ifEligible(), sameOwner(active, outgoing), sameOwner(previous, prepared),
                      previous?.isLocal == true || allowRemote else { return nil }
                player.pause()
                guard ifEligible(), sameOwner(active, outgoing), sameOwner(previous, prepared),
                      previous?.isLocal == true || allowRemote, let committed = previous else { return nil }
                previous = nil
                guard replace(with: committed.item, mediaID: mediaID, isLocal: committed.isLocal,
                    videoResource: committed.videoResource, ifEligible: ifEligible) else { return nil }
                let current = player.currentItem
                guard ifEligible(), current === committed.item, sameOwner(active, committed) else { return nil }
                var replaced = committed
                replaced.completedPreviousZeroRewind = false
                return replaced
            }
        }
        guard let prepared = next, prepared.mediaID == mediaID else { return nil }
        let outgoing = active, reserve = loopReserve
        #if DEBUG
        onDebugAdvanceBranch?(.queuedAdvance, prepared.mediaID, ObjectIdentifier(prepared.item))
        #endif
        let status = prepared.item.status, items = player.items(), current = player.currentItem
        @MainActor func ownsAdvance() -> Bool {
            sameOwner(active, outgoing) && next?.item === prepared.item
                && next?.mediaID == mediaID && next?.videoResource === prepared.videoResource
                && (next?.isLocal == true || allowRemote) && sameOwner(loopReserve, reserve)
        }
        guard ifEligible(), ownsAdvance(), status != .failed,
              current === prepared.item || items.dropFirst().first === prepared.item,
              retainPrevious(before: prepared, ifEligible: { ifEligible() && ownsAdvance() }),
              ifEligible(), ownsAdvance() else { return nil }
        // Cancellation and eligibility can advance the native queue reentrantly.
        // Its pre-retention currentItem must never decide a second advance.
        let commitItems = player.items(), commitCurrent = player.currentItem
        guard ifEligible(), ownsAdvance(),
              commitCurrent === prepared.item || commitItems.dropFirst().first === prepared.item,
              let committed = next else { return nil }
        next = loopReserve; loopReserve = nil; active = committed
        if commitCurrent !== committed.item { player.advanceToNextItem() }
        let advanced = player.currentItem
        guard ifEligible(), advanced === committed.item, sameOwner(active, committed) else { return nil }
        updateEndAction()
        preparePreviousStart()
        let finalCurrent = player.currentItem
        guard ifEligible(), finalCurrent === committed.item, sameOwner(active, committed) else { return nil }
        return committed
    }
}
