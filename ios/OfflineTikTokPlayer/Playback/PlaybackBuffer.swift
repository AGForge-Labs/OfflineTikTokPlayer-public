import AVFoundation

/// One persistent player for the feed, background audio, remote commands and PiP.
/// The second item is prepared while the current item plays, never after a swipe.
@MainActor
final class PlaybackBuffer {
    struct Prepared {
        let mediaID: String
        let item: AVPlayerItem
        let isLocal: Bool
    }
    let player = AVQueuePlayer()
    private var next: Prepared?
    var nextMediaID: String? { next?.mediaID }
    func hasPrepared(_ mediaID: String) -> Bool {
        guard let next else { return false }
        return next.mediaID == mediaID && next.item.status != .failed && player.items().dropFirst().first === next.item
    }

    init() { player.actionAtItemEnd = .pause }

    func replace(with item: AVPlayerItem?) {
        next = nil
        player.removeAllItems()
        if let item { player.insert(item, after: nil) }
    }

    func discardNext() {
        for item in player.items().dropFirst() { player.remove(item) }
        next = nil
    }

    func stage(_ prepared: Prepared, requireLocal: Bool = false) {
        guard let current = player.currentItem else { return }
        guard !requireLocal || prepared.isLocal else { return }
        if let next, next.mediaID == prepared.mediaID, next.item.status != .failed,
           player.items().dropFirst().first === next.item,
           !(requireLocal && !next.isLocal && prepared.isLocal) { return }
        discardNext()
        guard player.canInsert(prepared.item, after: current) else { return }
        player.insert(prepared.item, after: current)
        next = prepared
    }

    func advance(to mediaID: String, allowRemote: Bool = true) -> Prepared? {
        guard let prepared = next, prepared.mediaID == mediaID, prepared.item.status != .failed,
              prepared.isLocal || allowRemote,
              player.items().dropFirst().first === prepared.item else { return nil }
        next = nil
        player.advanceToNextItem()
        return prepared
    }
}
