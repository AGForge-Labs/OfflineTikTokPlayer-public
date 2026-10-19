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
    }
    let player = AVQueuePlayer()
    private var next: Prepared?
    private var loopReserve: Prepared?
    private var active: Prepared?
    private var previous: Prepared?
    private var observation: NSKeyValueObservation?
    var didAdvance: ((Prepared) -> Void)?
    var automaticAdvancementEnabled = true { didSet { updateEndAction() } }
    var previousMediaID: String? { previous?.mediaID }
    var retainedItemCount: Int {
        Set((player.items() + [active?.item, next?.item, loopReserve?.item, previous?.item].compactMap { $0 }).map(ObjectIdentifier.init)).count
    }
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
        player.automaticallyWaitsToMinimizeStalling = !localWindow
    }

    private func retainPrevious() {
        if let active, active.mediaID != next?.mediaID {
            previous = Prepared(mediaID: active.mediaID, item: active.item, isLocal: active.isLocal, needsRewind: true)
        }
    }

    /// KVO may be delivered after a swipe. Always reconcile actual object identity.
    func synchronize() {
        guard let prepared = next, player.currentItem === prepared.item else { return }
        retainPrevious(); active = prepared; next = loopReserve; loopReserve = nil; updateEndAction()
        didAdvance?(prepared)
    }

    func replace(with item: AVPlayerItem?, mediaID: String? = nil, isLocal: Bool = true) {
        if let active, active.item !== item {
            previous = Prepared(mediaID: active.mediaID, item: active.item, isLocal: active.isLocal, needsRewind: true)
        }
        active = item.flatMap { item in mediaID.map { Prepared(mediaID: $0, item: item, isLocal: isLocal) } }
        next = nil; loopReserve = nil
        player.removeAllItems()
        if let item { player.insert(item, after: nil) }
        updateEndAction()
    }

    func discardNext() {
        for item in player.items().dropFirst() { player.remove(item) }
        next = nil; loopReserve = nil
        updateEndAction()
    }

    func discardPrevious() { previous = nil }
    func stagePrevious(_ prepared: Prepared) {
        guard previous?.mediaID != prepared.mediaID else { return }
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
            player.pause()
            previous = nil
            replace(with: prepared.item, mediaID: mediaID, isLocal: prepared.isLocal)
            return prepared
        }
        guard let prepared = next, prepared.mediaID == mediaID, prepared.item.status != .failed,
              prepared.isLocal || allowRemote,
              player.currentItem === prepared.item || player.items().dropFirst().first === prepared.item else { return nil }
        retainPrevious(); next = loopReserve; loopReserve = nil; active = prepared
        if player.currentItem !== prepared.item { player.advanceToNextItem() }
        updateEndAction()
        return prepared
    }
}
