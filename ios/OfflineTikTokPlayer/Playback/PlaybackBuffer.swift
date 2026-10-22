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
    }
    let player = AVQueuePlayer()
    private var next: Prepared?
    private var loopReserve: Prepared?
    private var active: Prepared?
    private var previous: Prepared?
    private var observation: NSKeyValueObservation?
    var didAdvance: ((Prepared) -> Void)?
    var automaticAdvancementEnabled = true { didSet { updateEndAction() } }
    var usesExternalClock = false { didSet { updateEndAction() } }
    var previousMediaID: String? { previous?.mediaID }
    #if DEBUG
    let debugSuppressesPlayerRendering: Bool
    let debugNativeGeometry: Bool?
    var debugPreviousNeedsRewind: Bool? { previous?.needsRewind }
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

    private func retainPrevious(before prepared: Prepared) {
        if let active, active.mediaID != prepared.mediaID {
            previous?.item.cancelPendingSeeks()
            previous = Prepared(mediaID: active.mediaID, item: active.item, isLocal: active.isLocal,
                                needsRewind: true, videoResource: active.videoResource)
        }
    }

    private func preparePreviousStart() {
        guard let previous, previous.needsRewind, previous.item.status == .readyToPlay,
              previous.item !== player.currentItem else { return }
        let item = previous.item
        // Rewind off-screen, not on the Previous button's critical path. Weak
        // captures and cancellation on eviction bound preparation to one item.
        item.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
            Task { @MainActor in
                guard let self, let item, finished, self.previous?.item === item,
                      self.player.currentItem !== item, abs(item.currentTime().seconds) < 0.005 else { return }
                self.previous?.needsRewind = false
            }
        }
    }

    /// KVO may be delivered after a swipe. Always reconcile actual object identity.
    func synchronize() {
        let oldResources = videoResources
        defer { retireReleased(oldResources) }
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
        return status != .failed && items.count == 2 && items.first === current && items.last === committed.item
            && player.currentItem === current && active?.item === current
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
        loopReserve = prepared
        updateEndAction()
    }

    func advance(to mediaID: String, allowRemote: Bool = true) -> Prepared? {
        let oldResources = videoResources
        defer { retireReleased(oldResources) }
        if !hasPrepared(mediaID), let prepared = previous, prepared.mediaID == mediaID, prepared.item.status != .failed,
           prepared.isLocal || allowRemote {
            #if DEBUG
            onDebugAdvanceBranch?(.previousReplacement, prepared.mediaID, ObjectIdentifier(prepared.item))
            #endif
            player.pause()
            previous = nil
            replace(with: prepared.item, mediaID: mediaID, isLocal: prepared.isLocal,
                    videoResource: prepared.videoResource)
            return prepared
        }
        guard let prepared = next, prepared.mediaID == mediaID, prepared.item.status != .failed,
              prepared.isLocal || allowRemote,
              player.currentItem === prepared.item || player.items().dropFirst().first === prepared.item else { return nil }
        #if DEBUG
        onDebugAdvanceBranch?(.queuedAdvance, prepared.mediaID, ObjectIdentifier(prepared.item))
        #endif
        retainPrevious(before: prepared); next = loopReserve; loopReserve = nil; active = prepared
        if player.currentItem !== prepared.item { player.advanceToNextItem() }
        updateEndAction()
        preparePreviousStart()
        return prepared
    }
}
