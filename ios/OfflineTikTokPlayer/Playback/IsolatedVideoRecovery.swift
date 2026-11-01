import AVFoundation
import CoreMedia
import Foundation

/// A bounded hard-recovery decoder. Its item never owns audible playback.
/// The original audible item's outputs remain installed while this one runs.
@MainActor
final class IsolatedVideoRecovery {
    let item: AVPlayerItem
    let player: AVPlayer
    let resource: ContinuousPictureInPicture.PreparedVideoResource
    private(set) var isAligning = false
    private var alignmentTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var closed = false
    private var pendingAlignments: [UInt64: Task<Void, Never>] = [:]
    private var alignmentIntent: (position: Double, playing: Bool)?
    private var clockContext: UInt64?
    private var lastPlaying: Bool?
    private var scheduledStart: (host: Double, position: Double)?
    private var usedStartupRecovery = false
    #if DEBUG
    private(set) var debugSeekCount = 0
    var debugScheduleStart: ((AVPlayer, CMTime, CMTime) -> Void)?
    #endif

    private init(item: AVPlayerItem, resource: ContinuousPictureInPicture.PreparedVideoResource) {
        self.item = item; self.resource = resource
        player = AVPlayer(playerItem: item)
        player.isMuted = true; player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = false
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    }

    static func prepare(from source: AVPlayerItem) async throws -> IsolatedVideoRecovery {
        let asset: AVAsset
        if let source = source.asset as? AVURLAsset { asset = AVURLAsset(url: source.url) }
        else { asset = source.asset }
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = source.videoComposition
        item.preferredForwardBufferDuration = 2
        let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
        try Task.checkCancellation()
        guard let resource = plan.install(ifEligible: { !Task.isCancelled }) else { throw Failure.preparation }
        let decoder = IsolatedVideoRecovery(item: item, resource: resource)
        do {
            let deadline = ContinuousClock.now + .seconds(6)
            while item.status == .unknown {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw Failure.preparation }
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            guard item.status == .readyToPlay else { throw Failure.preparation }
            return decoder
        } catch {
            decoder.close()
            throw error
        }
    }

    /// Only the muted decoder is sought. The supplied clock is the CPP timeline
    /// that the service anchors to the currently audible owner.
    func synchronize(to clock: CMTimebase, playing: Bool, force: Bool = false, context: UInt64 = 0,
                     onAligned: @escaping @MainActor () -> Void) {
        guard !closed else { return }
        let target = CMTimebaseGetTime(clock)
        guard target.isNumeric else { return }
        if clockContext != context || lastPlaying != playing {
            scheduledStart = nil; usedStartupRecovery = false
            clockContext = context; lastPlaying = playing
        }
        if !playing && !force {
            // Ordinary paused clock samples must not cancel the in-flight seek
            // that is obtaining the requested paused picture.
            if isAligning, let intent = alignmentIntent, !intent.playing,
               abs(intent.position - target.seconds) <= 1.0 / 48_000 { return }
            suspend(); return
        }
        guard force || !isAligning else { return }
        let native = player.currentTime()
        if !force, playing {
            let now = ProcessInfo.processInfo.systemUptime
            let rate = item.timebase.map { CMTimebaseGetEffectiveRate($0) } ?? 0
            if let start = scheduledStart {
                if rate > 0, native.isNumeric, native.seconds > start.position + 1.0 / 48_000 {
                    scheduledStart = nil
                } else {
                    // setRate returning is not proof of a running native clock.
                    // Permit only one delayed retry per explicit presentation context.
                    guard now - start.host >= 1.5, !usedStartupRecovery else { return }
                    usedStartupRecovery = true; scheduledStart = nil
                }
            } else if rate <= 0 {
                scheduledStart = (now, native.isNumeric ? native.seconds : target.seconds)
                return
            }
        }
        if !force, native.isNumeric, abs(native.seconds - target.seconds) <= 0.080 {
            if playing && player.rate == 0 { player.playImmediately(atRate: 1) }
            return
        }
        cancelAlignment()
        let request = revision
        isAligning = true; alignmentIntent = (target.seconds, playing)
        player.pause()
        #if DEBUG
        debugSeekCount += 1
        #endif
        let pending = Task { [weak self] in
            guard let self else { return }
            defer { self.pendingAlignments[request] = nil }
            guard !self.closed, self.revision == request else { return }
            let finished = await withCheckedContinuation { continuation in
                self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) {
                    continuation.resume(returning: $0)
                }
            }
            guard finished, !Task.isCancelled, !self.closed, self.revision == request else {
                if !self.closed, self.revision == request {
                    self.isAligning = false; self.alignmentTask = nil; self.alignmentIntent = nil
                }
                return
            }
            let fresh = CMTimebaseGetTime(clock)
            guard fresh.isNumeric else {
                self.isAligning = false; self.alignmentTask = nil; self.alignmentIntent = nil; return
            }
            if playing {
                let host = CMClockGetTime(CMClockGetHostTimeClock())
                self.scheduledStart = (ProcessInfo.processInfo.systemUptime, fresh.seconds)
                #if DEBUG
                if let schedule = self.debugScheduleStart { schedule(self.player, fresh, host) }
                else { self.player.setRate(1, time: fresh, atHostTime: host) }
                #else
                self.player.setRate(1, time: fresh, atHostTime: host)
                #endif
            } else { self.player.pause() }
            guard !Task.isCancelled, !self.closed, self.revision == request else { return }
            self.isAligning = false; self.alignmentTask = nil; self.alignmentIntent = nil
            onAligned()
        }
        alignmentTask = pending; pendingAlignments[request] = pending
    }

    @discardableResult
    func suspend() -> Task<Void, Never>? {
        cancelAlignment()
        lastPlaying = nil; scheduledStart = nil; usedStartupRecovery = false
        player.pause()
        return pendingWork()
    }

    @discardableResult
    func close() -> Task<Void, Never>? {
        guard !closed else { return pendingWork() }
        closed = true
        cancelAlignment()
        player.pause()
        player.replaceCurrentItem(with: nil)
        resource.retire()
        return pendingWork()
    }

    private func cancelAlignment() {
        revision &+= 1
        let pending = alignmentTask
        alignmentTask = nil; isAligning = false; alignmentIntent = nil
        pending?.cancel()
        item.cancelPendingSeeks()
    }

    private func pendingWork() -> Task<Void, Never>? {
        let tasks = Array(pendingAlignments.values)
        guard !tasks.isEmpty else { return nil }
        return Task { for task in tasks { await task.value } }
    }

    private enum Failure: Error { case preparation }
}
