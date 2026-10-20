import Synchronization

public struct ContinuousPCMStreamRequest: Equatable, Sendable {
    public let epoch: Int
    public let startFrame: Int64
}

/// Fixed storage shared by one serial decoder and one audio render thread.
/// The owner must retire an unused slot through its renderer before preparing it again.
public final class ContinuousPCMSource: @unchecked Sendable {
    public let channels: Int
    public let prefixCapacityFrames: Int
    public let ringCapacityFrames: Int
    private let prefix: UnsafeMutablePointer<Float>
    private let ring: UnsafeMutablePointer<Float>
    private let readyToken = Atomic<Int>(0)
    // Single-attempt ownership claim: 0 idle, 1 renderer, 2 preparation/retirement.
    // This is never waited on by the audio thread. A failed retirement changes nothing.
    private let access = Atomic<Int>(0)
    fileprivate let successor = Atomic<Int>(0)
    private let count = Atomic<Int64>(0)
    private let prefixCount = Atomic<Int>(0)
    private let requestEpoch = Atomic<Int>(0)
    private let requestStart = Atomic<Int64>(0)
    private let committedEpoch = Atomic<Int>(0)
    private let readPosition = Atomic<Int64>(0)
    private let writePosition = Atomic<Int64>(0)
    // Render-thread owned after publication; exclusive preparation/retirement
    // clears the one-shot warm token. Storage outlives every render request.
    fileprivate var renderedToken = 0
    fileprivate var renderedEpoch = 0
    private var warmNextVisitToken = 0

    fileprivate init(channels: Int, prefixFrames: Int, ringFrames: Int) {
        self.channels = channels
        prefixCapacityFrames = prefixFrames; ringCapacityFrames = ringFrames
        prefix = .allocate(capacity: prefixFrames * channels)
        ring = .allocate(capacity: ringFrames * channels)
        prefix.initialize(repeating: 0, count: prefixFrames * channels)
        ring.initialize(repeating: 0, count: ringFrames * channels)
    }

    deinit {
        prefix.deinitialize(count: prefixCapacityFrames * channels); prefix.deallocate()
        ring.deinitialize(count: ringCapacityFrames * channels); ring.deallocate()
    }

    public var token: Int { readyToken.load(ordering: .sequentiallyConsistent) }
    public var totalFrames: Int64 { count.load(ordering: .acquiring) }
    public var prefixFrameCount: Int { prefixCount.load(ordering: .acquiring) }
    public var availableStreamFrames: Int {
        max(0, Int(writePosition.load(ordering: .acquiring) - readPosition.load(ordering: .acquiring)))
    }
    /// Readiness for one visit's committed stream. Recheck the epoch around the
    /// count so old ring contents cannot satisfy a restart's preparation gate.
    public func availableStreamFrames(for epoch: Int) -> Int {
        guard epoch > 0, epoch & 1 == 0,
              requestEpoch.load(ordering: .sequentiallyConsistent) == epoch,
              committedEpoch.load(ordering: .acquiring) == epoch else { return 0 }
        let available = availableStreamFrames
        guard requestEpoch.load(ordering: .sequentiallyConsistent) == epoch,
              committedEpoch.load(ordering: .acquiring) == epoch else { return 0 }
        return min(ringCapacityFrames, available)
    }
    public var writableStreamFrames: Int { max(0, ringCapacityFrames - availableStreamFrames) }
    public var streamRequest: ContinuousPCMStreamRequest {
        // Only the renderer changes requests while a slot is live. This accessor
        // runs off the audio thread and retries a concurrent request publication.
        while true {
            let epoch = requestEpoch.load(ordering: .sequentiallyConsistent)
            if epoch & 1 != 0 { continue }
            let start = requestStart.load(ordering: .sequentiallyConsistent)
            if epoch == requestEpoch.load(ordering: .sequentiallyConsistent) {
                return ContinuousPCMStreamRequest(epoch: epoch, startFrame: start)
            }
        }
    }

    /// Prepare an empty/retired slot. Publish the complete pinned prefix atomically.
    /// Tokens identify preparations, not media, and must be positive and never reused.
    @discardableResult
    public func prepare(token: Int, totalFrames: Int64, prefix samples: UnsafeBufferPointer<Float>) -> Bool {
        guard token > 0, self.token == 0,
              totalFrames > 0, samples.count % channels == 0,
              samples.count / channels == min(Int64(prefixCapacityFrames), totalFrames) else { return false }
        guard access.compareExchange(expected: 0, desired: 2, ordering: .acquiringAndReleasing).exchanged else { return false }
        defer { access.store(0, ordering: .releasing) }
        let frames = samples.count / channels
        warmNextVisitToken = 0
        if let base = samples.baseAddress { prefix.update(from: base, count: samples.count) }
        count.store(totalFrames, ordering: .releasing)
        prefixCount.store(frames, ordering: .releasing)
        successor.store(0, ordering: .releasing)
        committedEpoch.store(0, ordering: .releasing)
        readPosition.store(Int64(frames), ordering: .releasing)
        writePosition.store(Int64(frames), ordering: .releasing)
        requestStart.store(Int64(frames), ordering: .sequentiallyConsistent)
        requestEpoch.store(2, ordering: .sequentiallyConsistent)
        readyToken.store(token, ordering: .sequentiallyConsistent)
        return true
    }

    /// A stream reset is safe because a new render epoch stops reading the old ring
    /// before publishing its request. Prefix playback does not use the ring.
    @discardableResult
    public func beginStream(epoch: Int) -> Bool {
        guard token > 0, epoch > 0, epoch & 1 == 0, requestEpoch.load(ordering: .sequentiallyConsistent) == epoch else { return false }
        committedEpoch.store(0, ordering: .releasing)
        let start = requestStart.load(ordering: .sequentiallyConsistent)
        readPosition.store(start, ordering: .releasing)
        writePosition.store(start, ordering: .releasing)
        guard requestEpoch.load(ordering: .sequentiallyConsistent) == epoch else { return false }
        committedEpoch.store(epoch, ordering: .releasing)
        return true
    }

    /// One producer, one consumer. Returns whole interleaved frames accepted.
    @discardableResult
    public func append(interleaved samples: UnsafeBufferPointer<Float>, epoch: Int) -> Int {
        guard token > 0, samples.count % channels == 0,
              epoch == requestEpoch.load(ordering: .sequentiallyConsistent),
              epoch == committedEpoch.load(ordering: .acquiring) else { return 0 }
        let written = writePosition.load(ordering: .relaxed)
        let read = readPosition.load(ordering: .acquiring)
        let available = max(0, ringCapacityFrames - Int(written - read))
        let frames = min(samples.count / channels, available)
        guard frames > 0, let base = samples.baseAddress else { return 0 }
        for frame in 0..<frames {
            let target = Int((written + Int64(frame)) % Int64(ringCapacityFrames)) * channels
            ring.advanced(by: target).update(from: base.advanced(by: frame * channels), count: channels)
        }
        // A restart can be requested while this bounded copy is in progress.
        // Its epoch remains uncommitted; none of this old data can be consumed.
        guard epoch == requestEpoch.load(ordering: .sequentiallyConsistent) else { return 0 }
        writePosition.store(written + Int64(frames), ordering: .releasing)
        return frames
    }

    public func finishStream(totalFrames: Int64, epoch: Int) {
        guard token > 0, epoch == requestEpoch.load(ordering: .sequentiallyConsistent),
              epoch == committedEpoch.load(ordering: .acquiring), totalFrames > 0 else { return }
        count.store(totalFrames, ordering: .releasing)
    }

    fileprivate func invalidate(canRetire: () -> Bool) -> Bool {
        guard access.compareExchange(expected: 0, desired: 2, ordering: .acquiringAndReleasing).exchanged else { return false }
        // Recheck after claiming the slot: a boundary may have made it current
        // after the owner's earlier snapshot, before this ownership claim.
        guard canRetire() else {
            access.store(0, ordering: .releasing); return false
        }
        // Retired storage is outside the prepared graph. Its old outgoing edge
        // must not pin another slot after the owner drops this slot's metadata.
        successor.store(0, ordering: .releasing)
        warmNextVisitToken = 0
        readyToken.store(0, ordering: .sequentiallyConsistent)
        access.store(0, ordering: .releasing)
        return true
    }

    fileprivate func acquire(token: Int) -> Bool {
        guard access.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing).exchanged else { return false }
        guard readyToken.load(ordering: .sequentiallyConsistent) == token else {
            release(); return false
        }
        return true
    }

    fileprivate func release() { access.store(0, ordering: .releasing) }

    fileprivate func restart(token: Int, frame: Int64) {
        // A brand-new source may already have a full decode-ahead ring. Preserve it
        // for the initial visit. An outgoing retained source can prepare this same
        // head while its neighbour plays; consume that preparation once on return.
        if frame == 0, renderedToken != token || warmNextVisitToken == token {
            renderedToken = token; renderedEpoch = requestEpoch.load(ordering: .sequentiallyConsistent)
            warmNextVisitToken = 0
            return
        }
        warmNextVisitToken = 0
        renderedToken = token
        requestStream(from: frame)
    }

    /// Called under the outgoing source's render claim, before another token is
    /// published as current. The existing worker can rebuild this fixed head now,
    /// rather than starting a cold reader when Previous consumes its prefix.
    fileprivate func prepareNextVisit(token: Int) {
        renderedToken = token
        requestStream(from: 0)
        warmNextVisitToken = token
    }

    private func requestStream(from frame: Int64) {
        renderedEpoch = requestEpoch.load(ordering: .sequentiallyConsistent) &+ 2
        committedEpoch.store(0, ordering: .releasing)
        requestEpoch.store(renderedEpoch - 1, ordering: .sequentiallyConsistent)
        requestStart.store(max(Int64(prefixCount.load(ordering: .sequentiallyConsistent)), frame), ordering: .releasing)
        requestEpoch.store(renderedEpoch, ordering: .sequentiallyConsistent)
    }

    fileprivate func copyFrame(_ frame: Int64, into output: UnsafeMutablePointer<Float>) -> Bool {
        if frame < Int64(prefixCount.load(ordering: .relaxed)) {
            output.update(from: prefix.advanced(by: Int(frame) * channels), count: channels)
            return true
        }
        guard committedEpoch.load(ordering: .acquiring) == renderedEpoch,
              readPosition.load(ordering: .relaxed) == frame,
              writePosition.load(ordering: .acquiring) > frame else { return false }
        output.update(from: ring.advanced(by: Int(frame % Int64(ringCapacityFrames)) * channels), count: channels)
        readPosition.store(frame + 1, ordering: .releasing)
        return true
    }
}

/// One permanent PCM timeline, independent of video readiness and UI callback timing.
/// `render` has exactly one caller (the audio thread). Control methods have one serial
/// caller. Decoder methods on sources have one serial producer. No storage is created,
/// released, locked, decoded or dispatched from `render`.
public final class ContinuousPCMRenderer: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let token: Int
        public let frame: Int64
        public let visit: Int64
        public let ended: Bool
        public let underrunFrames: Int64
        /// Last serial selection command actually consumed by the render thread.
        /// Zero is the initial state; publishing a newer command does not acknowledge it.
        public let selectionVersion: Int
    }
    public let sampleRate: Double
    public let channels: Int
    public let retainedPCMMemoryBytes: Int
    private let first: ContinuousPCMSource
    private let second: ContinuousPCMSource
    private let third: ContinuousPCMSource
    private let speaker: SpeakerAudioProcessor
    private let playing = Atomic<Bool>(false)
    private let enhance = Atomic<Bool>(false)
    private let commandVersion = Atomic<Int>(0)
    private let commandToken = Atomic<Int>(0)
    private let commandFrame = Atomic<Int64>(0)
    private var nextCommandVersion = 0 // Serial control owner.
    private let stateVersion = Atomic<Int>(0)
    private let stateToken = Atomic<Int>(0)
    private let stateFrame = Atomic<Int64>(0)
    private let stateVisit = Atomic<Int64>(0)
    private let stateEnded = Atomic<Bool>(false)
    private let stateUnderrun = Atomic<Int64>(0)
    private let stateSelectionVersion = Atomic<Int>(0)
    private let liveToken = Atomic<Int>(0)
    private let livePendingToken = Atomic<Int>(0)
    // Only the render thread mutates this cursor and its processor.
    private var activeToken = 0
    private var cursor: Int64 = 0
    private var visit: Int64 = 0
    private var ended = false
    private var underrun: Int64 = 0
    private var consumedCommandVersion = 0
    private var nextStateVersion = 0

    public init(sampleRate: Double = 48_000, channels: Int = 2,
                prefixFrames: Int = 96_000, ringFrames: Int = 192_000) {
        precondition(sampleRate.isFinite && sampleRate > 0 && (1...8).contains(channels))
        precondition(prefixFrames > 0 && ringFrames > 0)
        self.sampleRate = sampleRate; self.channels = channels
        retainedPCMMemoryBytes = 3 * (prefixFrames + ringFrames) * channels * MemoryLayout<Float>.stride
        first = ContinuousPCMSource(channels: channels, prefixFrames: prefixFrames, ringFrames: ringFrames)
        second = ContinuousPCMSource(channels: channels, prefixFrames: prefixFrames, ringFrames: ringFrames)
        third = ContinuousPCMSource(channels: channels, prefixFrames: prefixFrames, ringFrames: ringFrames)
        speaker = SpeakerAudioProcessor(sampleRate: sampleRate, channels: channels, enabled: true)
    }

    public func source(at index: Int) -> ContinuousPCMSource {
        switch index { case 0: return first; case 1: return second; case 2: return third; default: preconditionFailure("Three PCM slots") }
    }

    /// Call from the same serial owner as selection and successor changes.
    /// A pending command or prepared boundary pins its source until render acknowledgement.
    @discardableResult
    public func retireSource(at index: Int) -> Bool {
        let source = source(at: index), token = source.token
        guard token > 0 else { return true }
        let state = snapshot
        let pendingSelection = commandVersion.load(ordering: .sequentiallyConsistent) != state.selectionVersion
        guard state.token != token, !(pendingSelection && commandToken.load(ordering: .sequentiallyConsistent) == token),
              first.successor.load(ordering: .acquiring) != token,
              second.successor.load(ordering: .acquiring) != token,
              third.successor.load(ordering: .acquiring) != token else { return false }
        return source.invalidate {
            liveToken.load(ordering: .sequentiallyConsistent) != token && livePendingToken.load(ordering: .sequentiallyConsistent) != token
        }
    }

    @discardableResult
    public func setSuccessor(token: Int, for sourceToken: Int) -> Bool {
        guard token == 0 || find(token) != nil, let source = find(sourceToken) else { return false }
        source.successor.store(token, ordering: .releasing)
        return true
    }

    /// Publish a selection and return its serial command version. Compare it with
    /// `snapshot.selectionVersion` to distinguish pending from rendered positions.
    @discardableResult
    public func select(token: Int, frame: Int64 = 0) -> Int {
        livePendingToken.store(token, ordering: .sequentiallyConsistent)
        nextCommandVersion &+= 2
        commandVersion.store(nextCommandVersion - 1, ordering: .sequentiallyConsistent)
        commandFrame.store(max(0, frame), ordering: .sequentiallyConsistent)
        commandToken.store(token, ordering: .sequentiallyConsistent)
        commandVersion.store(nextCommandVersion, ordering: .sequentiallyConsistent)
        return nextCommandVersion
    }

    public func setPlaying(_ value: Bool) { playing.store(value, ordering: .releasing) }
    public func setSpeakerEnabled(_ value: Bool) { enhance.store(value, ordering: .releasing) }

    /// Coherent source-frame cursor. Read off the audio thread.
    public var snapshot: Snapshot {
        while true {
            let version = stateVersion.load(ordering: .sequentiallyConsistent)
            if version & 1 != 0 { continue }
            let value = Snapshot(token: stateToken.load(ordering: .sequentiallyConsistent), frame: stateFrame.load(ordering: .sequentiallyConsistent),
                                 visit: stateVisit.load(ordering: .sequentiallyConsistent), ended: stateEnded.load(ordering: .sequentiallyConsistent),
                                 underrunFrames: stateUnderrun.load(ordering: .sequentiallyConsistent),
                                 selectionVersion: stateSelectionVersion.load(ordering: .sequentiallyConsistent))
            if version == stateVersion.load(ordering: .sequentiallyConsistent) { return value }
        }
    }

    public func render(interleaved output: UnsafeMutableBufferPointer<Float>, frameCount: Int) {
        guard frameCount > 0, frameCount <= output.count / channels, let base = output.baseAddress else { return }
        // Initialize only the requested span. Silence here is pause/EOF/starvation,
        // never an implicit boundary fade or a fabricated source trim.
        for index in 0..<(frameCount * channels) { base[index] = 0 }
        consumeSelection()
        if playing.load(ordering: .acquiring), activeToken > 0 {
            let shouldEnhance = enhance.load(ordering: .acquiring)
            var outputFrame = 0
            while outputFrame < frameCount {
                guard let source = find(activeToken), source.acquire(token: activeToken) else {
                    underrun += Int64(frameCount - outputFrame); break
                }
                let total = source.totalFrames
                if cursor >= total {
                    let next = source.successor.load(ordering: .acquiring)
                    if next == activeToken {
                        cursor = 0; visit &+= 1; ended = false
                        source.restart(token: next, frame: 0)
                        source.release()
                        continue
                    }
                    guard next > 0, let nextSource = find(next), nextSource.acquire(token: next) else {
                        source.release(); ended = true; break
                    }
                    guard nextSource.totalFrames > 0 else {
                        nextSource.release(); source.release(); ended = true; break
                    }
                    source.prepareNextVisit(token: activeToken)
                    activeToken = next; cursor = 0; visit &+= 1; ended = false
                    liveToken.store(next, ordering: .sequentiallyConsistent)
                    nextSource.restart(token: next, frame: 0)
                    nextSource.release()
                    source.release()
                    continue
                }
                var starved = false
                // Hold the single-reader claim for this source span. Decoder ring
                // writes remain independent; retirement never races a live span.
                while outputFrame < frameCount, cursor < total {
                    let destination = base.advanced(by: outputFrame * channels)
                    guard source.copyFrame(cursor, into: destination) else { starved = true; break }
                    if shouldEnhance { speaker.process(UnsafeMutableBufferPointer(start: destination, count: channels)) }
                    cursor += 1; outputFrame += 1
                }
                source.release()
                if starved { underrun += Int64(frameCount - outputFrame); break }
            }
        }
        publishSnapshot()
    }

    private func find(_ token: Int) -> ContinuousPCMSource? {
        guard token > 0 else { return nil }
        if first.token == token { return first }
        if second.token == token { return second }
        if third.token == token { return third }
        return nil
    }

    private func consumeSelection() {
        let version = commandVersion.load(ordering: .sequentiallyConsistent)
        guard version != consumedCommandVersion, version & 1 == 0 else { return }
        let token = commandToken.load(ordering: .sequentiallyConsistent), frame = commandFrame.load(ordering: .sequentiallyConsistent)
        guard version == commandVersion.load(ordering: .sequentiallyConsistent) else { return }
        consumedCommandVersion = version
        guard token > 0, let source = find(token), source.acquire(token: token) else {
            if token == 0 { activeToken = 0; liveToken.store(0, ordering: .sequentiallyConsistent); cursor = 0; ended = false }
            return
        }
        if token != activeToken, let previous = find(activeToken), previous.acquire(token: activeToken) {
            previous.prepareNextVisit(token: activeToken)
            previous.release()
        }
        activeToken = token; cursor = min(frame, source.totalFrames); visit &+= 1; ended = false
        liveToken.store(token, ordering: .sequentiallyConsistent)
        source.restart(token: token, frame: cursor)
        source.release()
    }

    private func publishSnapshot() {
        nextStateVersion &+= 2
        stateVersion.store(nextStateVersion - 1, ordering: .sequentiallyConsistent)
        stateToken.store(activeToken, ordering: .sequentiallyConsistent); stateFrame.store(cursor, ordering: .sequentiallyConsistent)
        stateVisit.store(visit, ordering: .sequentiallyConsistent); stateEnded.store(ended, ordering: .sequentiallyConsistent)
        stateUnderrun.store(underrun, ordering: .sequentiallyConsistent)
        stateSelectionVersion.store(consumedCommandVersion, ordering: .sequentiallyConsistent)
        stateVersion.store(nextStateVersion, ordering: .sequentiallyConsistent)
        if commandVersion.load(ordering: .sequentiallyConsistent) == consumedCommandVersion {
            // This compare-exchange cannot clear a newer pending target.
            _ = livePendingToken.compareExchange(expected: commandToken.load(ordering: .sequentiallyConsistent), desired: 0,
                                                 ordering: .acquiringAndReleasing)
        }
    }
}
