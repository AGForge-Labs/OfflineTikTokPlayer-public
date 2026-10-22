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

    #if DEBUG
    // The observed CAS/load values are the original acceptance operands. This
    // overload runs only with an explicitly installed immutable recorder.
    fileprivate func acquire(token: Int, recorder: ContinuousPCMRenderer.DebugFirstFailureRecorder,
                             visit: Int64, cursor: Int64) -> Bool {
        let claim = access.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing)
        guard claim.exchanged else {
            recorder.record(.init(reason: .sourceBusy, token: token, visit: visit, cursor: cursor,
                observedAccess: claim.original))
            return false
        }
        let observed = readyToken.load(ordering: .sequentiallyConsistent)
        guard observed == token else {
            release()
            recorder.record(.init(reason: .sourceTokenChanged, token: token, visit: visit, cursor: cursor,
                observedReadyToken: observed))
            return false
        }
        return true
    }
    #endif

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

    #if DEBUG
    // Keep the original prefix/epoch/read/write order and short-circuit loads.
    // Unreached operands stay nil; no request/availability accessor is queried.
    fileprivate func copyFrame(_ frame: Int64, into output: UnsafeMutablePointer<Float>,
                               recorder: ContinuousPCMRenderer.DebugFirstFailureRecorder,
                               token: Int, visit: Int64) -> Bool {
        let prefixFrames = prefixCount.load(ordering: .relaxed)
        if frame < Int64(prefixFrames) {
            output.update(from: prefix.advanced(by: Int(frame) * channels), count: channels)
            return true
        }
        let epoch = committedEpoch.load(ordering: .acquiring)
        guard epoch == renderedEpoch else {
            recorder.record(.init(reason: .epochMismatch, token: token, visit: visit, cursor: frame,
                prefixFrames: prefixFrames, expectedEpoch: renderedEpoch, observedEpoch: epoch))
            return false
        }
        let read = readPosition.load(ordering: .relaxed)
        guard read == frame else {
            recorder.record(.init(reason: .positionMismatch, token: token, visit: visit, cursor: frame,
                prefixFrames: prefixFrames, expectedEpoch: renderedEpoch, observedEpoch: epoch,
                observedReadPosition: read))
            return false
        }
        let written = writePosition.load(ordering: .acquiring)
        guard written > frame else {
            recorder.record(.init(reason: .unpublishedFrame, token: token, visit: visit, cursor: frame,
                prefixFrames: prefixFrames, expectedEpoch: renderedEpoch, observedEpoch: epoch,
                observedReadPosition: read, observedWritePosition: written))
            return false
        }
        output.update(from: ring.advanced(by: Int(frame % Int64(ringCapacityFrames)) * channels), count: channels)
        readPosition.store(frame + 1, ordering: .releasing)
        return true
    }
    #endif
}

/// One permanent PCM timeline, independent of video readiness and UI callback timing.
/// `render` has exactly one caller (the audio thread). Control methods have one serial
/// caller. Decoder methods on sources have one serial producer. No storage is created,
/// released, locked, decoded or dispatched from `render`.
public final class ContinuousPCMRenderer: @unchecked Sendable {
    #if DEBUG
    public enum DebugFirstFailureReason: Int, Sendable, Equatable {
        case sourceMissing = 1, sourceBusy = 2, sourceTokenChanged = 3
        case epochMismatch = 4, positionMismatch = 5, unpublishedFrame = 6
    }
    public enum DebugFirstFailurePublication: Int, Sendable, Equatable {
        case notCaptured = 0, publishing = 1, captured = 2
    }
    /// Nil operands were not reached by the original short-circuit guard.
    public struct DebugFirstFailureEvent: Sendable, Equatable {
        public let reason: DebugFirstFailureReason
        public let token: Int
        public let visit: Int64
        public let cursor: Int64
        public let observedFirstToken: Int?, observedSecondToken: Int?, observedThirdToken: Int?
        public let observedAccess: Int?, observedReadyToken: Int?
        public let prefixFrames: Int?, expectedEpoch: Int?, observedEpoch: Int?
        public let observedReadPosition: Int64?, observedWritePosition: Int64?
        fileprivate init(reason: DebugFirstFailureReason, token: Int, visit: Int64, cursor: Int64,
                         observedFirstToken: Int? = nil, observedSecondToken: Int? = nil, observedThirdToken: Int? = nil,
                         observedAccess: Int? = nil, observedReadyToken: Int? = nil,
                         prefixFrames: Int? = nil, expectedEpoch: Int? = nil, observedEpoch: Int? = nil,
                         observedReadPosition: Int64? = nil, observedWritePosition: Int64? = nil) {
            self.reason = reason; self.token = token; self.visit = visit; self.cursor = cursor
            self.observedFirstToken = observedFirstToken; self.observedSecondToken = observedSecondToken
            self.observedThirdToken = observedThirdToken; self.observedAccess = observedAccess
            self.observedReadyToken = observedReadyToken; self.prefixFrames = prefixFrames
            self.expectedEpoch = expectedEpoch; self.observedEpoch = observedEpoch
            self.observedReadPosition = observedReadPosition; self.observedWritePosition = observedWritePosition
        }
    }
    public struct DebugFirstFailureSnapshot: Sendable {
        public let targetVisit: Int64
        public let publication: DebugFirstFailurePublication
        public let earlierVisitFailureObserved: Bool, laterVisitFailureObserved: Bool
        public let event: DebugFirstFailureEvent?
    }
    /// One preallocated publication for actual visit 3, regardless of source token.
    /// No reset, retry, clock, allocation, SDK object or writer hook.
    public final class DebugFirstFailureRecorder: @unchecked Sendable {
        public let targetVisit: Int64 = 3
        private let publication = Atomic<Int>(0)
        private let earlierVisitFailure = Atomic<Bool>(false)
        private let laterVisitFailure = Atomic<Bool>(false)
        private var payload: DebugFirstFailureEvent?
        public init() {}
        fileprivate func record(_ event: DebugFirstFailureEvent) {
            guard event.visit == targetVisit else {
                if event.visit < targetVisit { earlierVisitFailure.store(true, ordering: .releasing) }
                else { laterVisitFailure.store(true, ordering: .releasing) }
                return
            }
            guard publication.compareExchange(expected: 0, desired: 1,
                ordering: .acquiringAndReleasing).exchanged else { return }
            payload = event
            publication.store(2, ordering: .releasing)
        }
        /// Nonblocking observation. Publishing and notCaptured never expose a payload.
        /// The earlier/later flags are independent monotonic observations.
        public func snapshot() -> DebugFirstFailureSnapshot {
            let value = publication.load(ordering: .acquiring)
            return DebugFirstFailureSnapshot(targetVisit: targetVisit,
                publication: DebugFirstFailurePublication(rawValue: value)!,
                earlierVisitFailureObserved: earlierVisitFailure.load(ordering: .acquiring),
                laterVisitFailureObserved: laterVisitFailure.load(ordering: .acquiring),
                event: value == 2 ? payload : nil)
        }
    }
    #endif
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
    #if DEBUG
    public let debugRenderAccounting: DebugRenderAccountingRecorder?
    public let debugFirstFailure: DebugFirstFailureRecorder?
    #endif
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

    #if DEBUG
    public init(sampleRate: Double = 48_000, channels: Int = 2,
                prefixFrames: Int = 96_000, ringFrames: Int = 192_000,
                debugRenderAccounting: DebugRenderAccountingRecorder? = nil,
                debugFirstFailure: DebugFirstFailureRecorder? = nil) {
        precondition(sampleRate.isFinite && sampleRate > 0 && (1...8).contains(channels))
        precondition(prefixFrames > 0 && ringFrames > 0)
        self.debugRenderAccounting = debugRenderAccounting
        self.debugFirstFailure = debugFirstFailure
        self.sampleRate = sampleRate; self.channels = channels
        retainedPCMMemoryBytes = 3 * (prefixFrames + ringFrames) * channels * MemoryLayout<Float>.stride
        first = ContinuousPCMSource(channels: channels, prefixFrames: prefixFrames, ringFrames: ringFrames)
        second = ContinuousPCMSource(channels: channels, prefixFrames: prefixFrames, ringFrames: ringFrames)
        third = ContinuousPCMSource(channels: channels, prefixFrames: prefixFrames, ringFrames: ringFrames)
        speaker = SpeakerAudioProcessor(sampleRate: sampleRate, channels: channels, enabled: true)
    }
    #else
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
    #endif

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
        #if DEBUG
        return debugReadSnapshot(captureReceipt: false).snapshot
        #else
        while true {
            let version = stateVersion.load(ordering: .sequentiallyConsistent)
            if version & 1 != 0 { continue }
            let value = Snapshot(token: stateToken.load(ordering: .sequentiallyConsistent), frame: stateFrame.load(ordering: .sequentiallyConsistent),
                                 visit: stateVisit.load(ordering: .sequentiallyConsistent), ended: stateEnded.load(ordering: .sequentiallyConsistent),
                                 underrunFrames: stateUnderrun.load(ordering: .sequentiallyConsistent),
                                 selectionVersion: stateSelectionVersion.load(ordering: .sequentiallyConsistent))
            if version == stateVersion.load(ordering: .sequentiallyConsistent) { return value }
        }
        #endif
    }
    #if DEBUG
    /// Reader-local diagnostics only. No clock, allocation, writer hook or retry limit.
    public struct DebugSnapshotReadReceipt: Sendable {
        public private(set) var attempts: UInt64 = 0
        public private(set) var oddVersionRetries: UInt64 = 0
        public private(set) var changedVersionRetries: UInt64 = 0
        public private(set) var firstVersion: Int?
        public private(set) var acceptedVersion: Int = 0
        public private(set) var overflow = false
        fileprivate init() {}
        fileprivate mutating func attempted(_ version: Int) {
            if firstVersion == nil { firstVersion = version }
            if attempts == .max { overflow = true } else { attempts += 1 }
        }
        fileprivate mutating func odd() {
            if oddVersionRetries == .max { overflow = true } else { oddVersionRetries += 1 }
        }
        fileprivate mutating func changed() {
            if changedVersionRetries == .max { overflow = true } else { changedVersionRetries += 1 }
        }
        fileprivate mutating func accepted(_ version: Int) { acceptedVersion = version }
    }

    public func debugSnapshotWithReadReceipt() -> (snapshot: Snapshot, receipt: DebugSnapshotReadReceipt) {
        let result = debugReadSnapshot(captureReceipt: true)
        return (result.snapshot, result.receipt!)
    }

    // Both DEBUG entry points use this exact atomic sequence. Nil receipt does no counting.
    private func debugReadSnapshot(captureReceipt: Bool) -> (snapshot: Snapshot, receipt: DebugSnapshotReadReceipt?) {
        var receipt: DebugSnapshotReadReceipt? = captureReceipt ? DebugSnapshotReadReceipt() : nil
        while true {
            let version = stateVersion.load(ordering: .sequentiallyConsistent)
            receipt?.attempted(version)
            if version & 1 != 0 { receipt?.odd(); continue }
            let value = Snapshot(token: stateToken.load(ordering: .sequentiallyConsistent), frame: stateFrame.load(ordering: .sequentiallyConsistent),
                                 visit: stateVisit.load(ordering: .sequentiallyConsistent), ended: stateEnded.load(ordering: .sequentiallyConsistent),
                                 underrunFrames: stateUnderrun.load(ordering: .sequentiallyConsistent),
                                 selectionVersion: stateSelectionVersion.load(ordering: .sequentiallyConsistent))
            let acceptedVersion = stateVersion.load(ordering: .sequentiallyConsistent)
            if version == acceptedVersion {
                receipt?.accepted(acceptedVersion)
                return (value, receipt)
            }
            receipt?.changed()
        }
    }
    #endif

    public func render(interleaved output: UnsafeMutableBufferPointer<Float>, frameCount: Int) {
        guard frameCount > 0, frameCount <= output.count / channels, let base = output.baseAddress else { return }
        #if DEBUG
        debugRenderAccounting?.kernelEntered(frames: frameCount)
        var debugCopied = 0, debugEOF = 0, debugUnderrun = 0
        var debugOriginToken = 0, debugOriginEpoch = 0, debugOriginSpans = 0
        var debugOriginVisit: Int64 = 0, debugOriginFirst: Int64 = 0, debugOriginEnd: Int64 = 0
        #endif
        // Initialize only the requested span. Silence here is pause/EOF/starvation,
        // never an implicit boundary fade or a fabricated source trim.
        for index in 0..<(frameCount * channels) { base[index] = 0 }
        consumeSelection()
        let consumedPlaying = playing.load(ordering: .acquiring)
        if consumedPlaying, activeToken > 0 {
            let shouldEnhance = enhance.load(ordering: .acquiring)
            var outputFrame = 0
            while outputFrame < frameCount {
                #if DEBUG
                guard let source = acquireRenderSource(activeToken) else {
                    #if DEBUG
                    if debugRenderAccounting != nil { debugUnderrun = frameCount - outputFrame }
                    #endif
                    underrun += Int64(frameCount - outputFrame); break
                }
                #else
                guard let source = find(activeToken), source.acquire(token: activeToken) else {
                    underrun += Int64(frameCount - outputFrame); break
                }
                #endif
                #if DEBUG
                if debugRenderAccounting?.capturesPCMOrigin == true {
                    // Plain render-owned fields, read under the existing source claim.
                    // Multiple spans (including a loop or EOF adoption) invalidate this receipt.
                    debugOriginSpans += 1
                    debugOriginToken = activeToken; debugOriginVisit = visit
                    debugOriginEpoch = source.renderedEpoch
                    debugOriginFirst = cursor; debugOriginEnd = cursor
                }
                #endif
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
                        #if DEBUG
                        if debugRenderAccounting != nil { debugEOF = frameCount - outputFrame }
                        #endif
                        source.release(); ended = true; break
                    }
                    guard nextSource.totalFrames > 0 else {
                        #if DEBUG
                        if debugRenderAccounting != nil { debugEOF = frameCount - outputFrame }
                        #endif
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
                    #if DEBUG
                    guard copyRenderFrame(source, into: destination) else { starved = true; break }
                    #else
                    guard source.copyFrame(cursor, into: destination) else { starved = true; break }
                    #endif
                    if shouldEnhance { speaker.process(UnsafeMutableBufferPointer(start: destination, count: channels)) }
                    cursor += 1; outputFrame += 1
                }
                #if DEBUG
                if debugRenderAccounting?.capturesPCMOrigin == true { debugOriginEnd = cursor }
                #endif
                source.release()
                if starved {
                    #if DEBUG
                    if debugRenderAccounting != nil { debugUnderrun = frameCount - outputFrame }
                    #endif
                    underrun += Int64(frameCount - outputFrame); break
                }
            }
            #if DEBUG
            if debugRenderAccounting != nil { debugCopied = outputFrame }
            #endif
        }
        publishSnapshot()
        #if DEBUG
        debugRenderAccounting?.kernelCompleted(copied: debugCopied,
            paused: !consumedPlaying && activeToken > 0 ? frameCount : 0,
            inactive: activeToken <= 0 ? frameCount : 0, eof: debugEOF,
            underrun: debugUnderrun, token: activeToken, visit: visit,
            origin: debugRenderAccounting?.capturesPCMOrigin == true ? DebugPCMOriginReceipt(
                valid: consumedPlaying && debugCopied == frameCount && debugEOF == 0 && debugUnderrun == 0
                    && debugOriginSpans == 1 && debugOriginEpoch > 0
                    && debugOriginToken == activeToken && debugOriginVisit == visit,
                completion: 0, token: debugOriginToken, visit: debugOriginVisit,
                epoch: debugOriginEpoch, firstFrame: debugOriginFirst, endFrame: debugOriginEnd) : nil)
        #endif
    }

    #if DEBUG
    private func acquireRenderSource(_ token: Int) -> ContinuousPCMSource? {
        if let recorder = debugFirstFailure {
            guard let source = findRenderSource(token, recorder: recorder),
                  source.acquire(token: token, recorder: recorder, visit: visit, cursor: cursor) else { return nil }
            return source
        }
        guard let source = find(token), source.acquire(token: token) else { return nil }
        return source
    }

    private func copyRenderFrame(_ source: ContinuousPCMSource, into output: UnsafeMutablePointer<Float>) -> Bool {
        if let recorder = debugFirstFailure {
            return source.copyFrame(cursor, into: output, recorder: recorder, token: activeToken, visit: visit)
        }
        return source.copyFrame(cursor, into: output)
    }

    private func findRenderSource(_ token: Int, recorder: DebugFirstFailureRecorder) -> ContinuousPCMSource? {
        guard token > 0 else { return nil }
        let firstToken = first.token
        if firstToken == token { return first }
        let secondToken = second.token
        if secondToken == token { return second }
        let thirdToken = third.token
        if thirdToken == token { return third }
        recorder.record(.init(reason: .sourceMissing, token: token, visit: visit, cursor: cursor,
            observedFirstToken: firstToken, observedSecondToken: secondToken, observedThirdToken: thirdToken))
        return nil
    }
    #endif

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

#if DEBUG
extension ContinuousPCMRenderer {
    /// One fully copied single-source kernel span; not a mixer/tap or worker snapshot.
    /// Source entry/completion publications can retain this last completed receipt.
    public struct DebugPCMOriginReceipt: Sendable, Equatable {
        public var valid: Bool
        public var completion: UInt64
        public var token: Int
        public var visit: Int64
        public var epoch: Int
        public var firstFrame: Int64
        public var endFrame: Int64
    }
    /// Completed app-written pairs only; no PCM, sample-time or callback history.
    public struct DebugSourceOutputSnapshot: Sendable {
        public var enabled = false
        public var callbacks: UInt64 = 0, frames: UInt64 = 0
        public var stereoZeroFrames: UInt64 = 0, nonfiniteFrames: UInt64 = 0
        public var longestZeroRun: UInt64 = 0, trailingZeroRun: UInt64 = 0
        public var invalidCallbacks: UInt64 = 0
        public var lastHostTime: UInt64 = 0, lastFrameCount: UInt64 = 0
        public var lastHostTimeValid = false
    }
    public struct DebugSourceOutputSpan: Sendable {
        public let callbacks: UInt64, frames: UInt64
        public let stereoZeroFrames: UInt64, nonfiniteFrames: UInt64
    }
    /// A value copy of one record, not a joint snapshot with renderer/worker state.
    public struct DebugRenderAccountingSnapshot: Sendable {
        public var sequence: UInt64 = 0
        public var sourceCallbacksEntered: UInt64 = 0
        public var sourceCallbacksCompleted: UInt64 = 0
        public var sourceFramesRequested: UInt64 = 0
        public var sourceFramesCompleted: UInt64 = 0
        public var invalidLayoutCallbacks: UInt64 = 0
        public var invalidLayoutFrames: UInt64 = 0
        public var kernelCallsEntered: UInt64 = 0
        public var kernelCallsCompleted: UInt64 = 0
        public var kernelFramesRequested: UInt64 = 0
        public var kernelFramesClassified: UInt64 = 0
        public var copiedPCMFrames: UInt64 = 0
        public var pausedPositiveTokenFrames: UInt64 = 0
        public var inactiveFrames: UInt64 = 0
        public var eofRemainderFrames: UInt64 = 0
        public var underrunFrames: UInt64 = 0
        public var lastKernelToken: Int = 0
        public var lastKernelVisit: Int64 = 0
        public var lastSourceFrameCount: UInt64 = 0
        public var lastSourceHostTimeValid = false
        public var lastSourceHostTime: UInt64 = 0
        public var pcmOrigin: DebugPCMOriginReceipt?
        public var sourceOutput = DebugSourceOutputSnapshot()
        public var overflowed = false

        /// Source-local completed-callback coverage only. Caller must establish
        /// the same graph owner; host bounds do not establish tap containment.
        public func sourceOutputSpan(since before: Self) -> DebugSourceOutputSpan? {
            let b = before.sourceOutput, e = sourceOutput
            guard b.enabled, e.enabled, !before.overflowed, !overflowed,
                  b.callbacks > 0, e.callbacks > b.callbacks, e.frames > b.frames,
                  before.sourceCallbacksEntered == before.sourceCallbacksCompleted,
                  sourceCallbacksEntered == sourceCallbacksCompleted,
                  before.kernelCallsEntered == before.kernelCallsCompleted, kernelCallsEntered == kernelCallsCompleted,
                  b.callbacks == before.sourceCallbacksCompleted, e.callbacks == sourceCallbacksCompleted,
                  sourceFramesCompleted >= before.sourceFramesCompleted,
                  e.frames - b.frames == sourceFramesCompleted - before.sourceFramesCompleted,
                  e.invalidCallbacks == b.invalidCallbacks,
                  e.stereoZeroFrames >= b.stereoZeroFrames, e.nonfiniteFrames >= b.nonfiniteFrames,
                  b.lastHostTimeValid, e.lastHostTimeValid, e.lastHostTime > b.lastHostTime else { return nil }
            return DebugSourceOutputSpan(callbacks: e.callbacks - b.callbacks, frames: e.frames - b.frames,
                stereoZeroFrames: e.stereoZeroFrames - b.stereoZeroFrames,
                nonfiniteFrames: e.nonfiniteFrames - b.nonfiniteFrames)
        }
    }

    /// Optional immutable render configuration. One graph/kernel render writer only.
    /// All storage is fixed before rendering; methods allocate, scan, clock and lock nothing.
    /// Entry/completion are separate short publications, never odd across render/SDK work.
    public final class DebugRenderAccountingRecorder: @unchecked Sendable {
        public let capturesPCMOrigin: Bool
        public let capturesSourceOutput: Bool
        private var state = DebugRenderAccountingSnapshot() // Render writer only.
        private var outputPending = DebugSourceOutputSnapshot()
        private var outputOpen = false
        private let sequence = Atomic<UInt64>(0)
        private let publicationExhausted = Atomic<Bool>(false)
        private final class PublicationBank: @unchecked Sendable {
            // .max is odd and can never be a published accounting sequence.
            let sequence = Atomic<UInt64>(.max)
            var value = DebugRenderAccountingSnapshot()
        }
        private let first = PublicationBank()
        private let second = PublicationBank()
        private let third = PublicationBank()
        private var publishedBank = 0 // Render writer only.
        private let observerActive = Atomic<Bool>(false)
        private let observerHazard = Atomic<Int>(-1)
        private let testHooks: PublicationTestHooks?

        /// Internal test seam only; the public/app initializer cannot install hooks.
        /// Deliberately blocking hooks are used solely by bounded portable tests.
        struct PublicationTestHooks: Sendable {
            let initialSequence: UInt64
            let initialSourceFramesRequested: UInt64
            let publicationPrepared: (@Sendable () -> Void)?
            let readerPinned: (@Sendable () -> Void)?
            init(initialSequence: UInt64 = 0, initialSourceFramesRequested: UInt64 = 0,
                 publicationPrepared: (@Sendable () -> Void)? = nil,
                 readerPinned: (@Sendable () -> Void)? = nil) {
                self.initialSequence = initialSequence
                self.initialSourceFramesRequested = initialSourceFramesRequested
                self.publicationPrepared = publicationPrepared; self.readerPinned = readerPinned
            }
        }

        public init(capturePCMOrigin: Bool = false, captureSourceOutput: Bool = false) {
            capturesPCMOrigin = capturePCMOrigin; capturesSourceOutput = captureSourceOutput; testHooks = nil
            state.sourceOutput.enabled = captureSourceOutput
            if capturePCMOrigin {
                state.pcmOrigin = DebugPCMOriginReceipt(valid: false, completion: 0,
                    token: 0, visit: 0, epoch: 0, firstFrame: 0, endFrame: 0)
            }
            first.value = state
            first.sequence.store(0, ordering: .sequentiallyConsistent)
        }
        init(capturePCMOrigin: Bool = false, captureSourceOutput: Bool = false, testHooks: PublicationTestHooks) {
            precondition(testHooks.initialSequence & 1 == 0)
            capturesPCMOrigin = capturePCMOrigin; capturesSourceOutput = captureSourceOutput; self.testHooks = testHooks
            state.sourceOutput.enabled = captureSourceOutput
            if capturePCMOrigin {
                state.pcmOrigin = DebugPCMOriginReceipt(valid: false, completion: 0,
                    token: 0, visit: 0, epoch: 0, firstFrame: 0, endFrame: 0)
            }
            state.sequence = testHooks.initialSequence
            state.sourceFramesRequested = testHooks.initialSourceFramesRequested
            first.value = state
            first.sequence.store(state.sequence, ordering: .sequentiallyConsistent)
            sequence.store(state.sequence, ordering: .sequentiallyConsistent)
        }

        private func bank(at index: Int) -> PublicationBank {
            switch index {
            case 0: return first
            case 1: return second
            case 2: return third
            default: preconditionFailure("Three publication banks")
            }
        }

        /// Only supplied callback arguments are observed; no host-clock conversion occurs here.
        public func sourceCallbackEntered(frames: Int, hostTimeValid: Bool, hostTime: UInt64) {
            if capturesSourceOutput {
                if outputOpen { state.sourceOutput.invalidCallbacks = add(state.sourceOutput.invalidCallbacks, 1) }
                outputPending = state.sourceOutput
                outputOpen = true
            }
            state.sourceCallbacksEntered = add(state.sourceCallbacksEntered, 1)
            state.sourceFramesRequested = add(state.sourceFramesRequested, UInt64(max(0, frames)))
            state.lastSourceFrameCount = UInt64(max(0, frames))
            state.lastSourceHostTimeValid = hostTimeValid
            state.lastSourceHostTime = hostTime
            publish()
        }

        public func sourceCallbackCompleted(frames: Int, invalidLayout: Bool) {
            state.sourceCallbacksCompleted = add(state.sourceCallbacksCompleted, 1)
            state.sourceFramesCompleted = add(state.sourceFramesCompleted, UInt64(max(0, frames)))
            if invalidLayout {
                state.invalidLayoutCallbacks = add(state.invalidLayoutCallbacks, 1)
                state.invalidLayoutFrames = add(state.invalidLayoutFrames, UInt64(max(0, frames)))
            }
            if capturesSourceOutput {
                if outputOpen {
                    let expected = UInt64(max(0, frames))
                    let invalid = invalidLayout || frames <= 0 || !state.lastSourceHostTimeValid
                        || outputPending.frames < state.sourceOutput.frames
                        || outputPending.frames - state.sourceOutput.frames != expected
                        || (outputPending.callbacks > 0 && state.lastSourceHostTime <= outputPending.lastHostTime)
                    if invalid { outputPending.invalidCallbacks = add(outputPending.invalidCallbacks, 1) }
                    outputPending.callbacks = add(outputPending.callbacks, 1)
                    outputPending.lastHostTime = state.lastSourceHostTime
                    outputPending.lastHostTimeValid = state.lastSourceHostTimeValid
                    outputPending.lastFrameCount = expected
                    state.sourceOutput = outputPending
                    outputOpen = false
                } else { state.sourceOutput.invalidCallbacks = add(state.sourceOutput.invalidCallbacks, 1) }
            }
            publish()
        }

        /// The graph supplies the same values it just stored, after DSP. Nothing
        /// is published per pair; an incomplete callback never becomes complete.
        public func sourceOutputPair(left: Float, right: Float) {
            guard capturesSourceOutput else { return }
            guard outputOpen else {
                state.sourceOutput.invalidCallbacks = add(state.sourceOutput.invalidCallbacks, 1)
                return
            }
            outputPending.frames = add(outputPending.frames, 1)
            if !left.isFinite || !right.isFinite {
                outputPending.nonfiniteFrames = add(outputPending.nonfiniteFrames, 1)
                outputPending.trailingZeroRun = 0
            } else if left == 0 && right == 0 {
                outputPending.stereoZeroFrames = add(outputPending.stereoZeroFrames, 1)
                outputPending.trailingZeroRun = add(outputPending.trailingZeroRun, 1)
                outputPending.longestZeroRun = max(outputPending.longestZeroRun, outputPending.trailingZeroRun)
            } else { outputPending.trailingZeroRun = 0 }
        }

        /// Accepted calls only: the original output-span guard has already succeeded.
        fileprivate func kernelEntered(frames: Int) {
            state.kernelCallsEntered = add(state.kernelCallsEntered, 1)
            state.kernelFramesRequested = add(state.kernelFramesRequested, UInt64(frames))
            publish()
        }

        fileprivate func kernelCompleted(copied: Int, paused: Int, inactive: Int, eof: Int,
                                         underrun: Int, token: Int, visit: Int64,
                                         origin: DebugPCMOriginReceipt? = nil) {
            state.kernelCallsCompleted = add(state.kernelCallsCompleted, 1)
            state.copiedPCMFrames = add(state.copiedPCMFrames, UInt64(copied))
            state.pausedPositiveTokenFrames = add(state.pausedPositiveTokenFrames, UInt64(paused))
            state.inactiveFrames = add(state.inactiveFrames, UInt64(inactive))
            state.eofRemainderFrames = add(state.eofRemainderFrames, UInt64(eof))
            state.underrunFrames = add(state.underrunFrames, UInt64(underrun))
            state.kernelFramesClassified = add(state.kernelFramesClassified, UInt64(copied))
            state.kernelFramesClassified = add(state.kernelFramesClassified, UInt64(paused))
            state.kernelFramesClassified = add(state.kernelFramesClassified, UInt64(inactive))
            state.kernelFramesClassified = add(state.kernelFramesClassified, UInt64(eof))
            state.kernelFramesClassified = add(state.kernelFramesClassified, UInt64(underrun))
            state.lastKernelToken = token
            state.lastKernelVisit = visit
            if capturesPCMOrigin, var origin {
                origin.completion = state.kernelCallsCompleted
                state.pcmOrigin = origin
            }
            publish()
        }

        static func saturatingAdd(_ value: UInt64, _ amount: UInt64) -> (value: UInt64, overflowed: Bool) {
            let result = value.addingReportingOverflow(amount)
            return (result.overflow ? .max : result.partialValue, result.overflow)
        }

        private func add(_ value: UInt64, _ amount: UInt64) -> UInt64 {
            let result = Self.saturatingAdd(value, amount)
            if result.overflowed { state.overflowed = true }
            return result.value
        }

        private func publish() {
            // Sequence exhaustion fails closed without wrapping/reusing a version.
            // Rendering continues; no writer waits for an observer.
            guard !publicationExhausted.load(ordering: .relaxed) else { return }
            guard state.sequence <= UInt64.max - 2 else {
                publicationExhausted.store(true, ordering: .sequentiallyConsistent)
                return
            }
            state.sequence += 2
            let hazard = observerHazard.load(ordering: .sequentiallyConsistent)
            // With one observer, the current bank and hazard exclude at most two.
            // Selection is constant work; rendering never waits for its observer.
            let next: Int
            if publishedBank != 0 && hazard != 0 { next = 0 }
            else if publishedBank != 1 && hazard != 1 { next = 1 }
            else { next = 2 }
            let target = bank(at: next)
            target.value = state
            testHooks?.publicationPrepared?()
            target.sequence.store(state.sequence, ordering: .sequentiallyConsistent)
            sequence.store(state.sequence, ordering: .sequentiallyConsistent)
            publishedBank = next
        }

        /// Bounded off-render observation. Nil means unavailable, including exhausted publication.
        public func snapshot() -> DebugRenderAccountingSnapshot? {
            // One off-render observer only. Overlap stays explicitly unavailable;
            // no caller waits and no prior sample is synthesized as a fresh read.
            guard observerActive.compareExchange(expected: false, desired: true,
                ordering: .sequentiallyConsistent).exchanged else { return nil }
            defer {
                observerHazard.store(-1, ordering: .sequentiallyConsistent)
                observerActive.store(false, ordering: .sequentiallyConsistent)
            }
            for _ in 0..<3 {
                guard !publicationExhausted.load(ordering: .sequentiallyConsistent) else { return nil }
                let before = sequence.load(ordering: .sequentiallyConsistent)
                var selected = -1
                for index in 0..<3 {
                    if bank(at: index).sequence.load(ordering: .sequentiallyConsistent) == before {
                        selected = index; break
                    }
                }
                guard selected >= 0 else { continue }
                observerHazard.store(selected, ordering: .sequentiallyConsistent)
                let selectedBank = bank(at: selected)
                guard before == sequence.load(ordering: .sequentiallyConsistent),
                      selectedBank.sequence.load(ordering: .sequentiallyConsistent) == before else {
                    observerHazard.store(-1, ordering: .sequentiallyConsistent)
                    continue
                }
                // The matching descriptor was still published after the hazard.
                // The writer excludes this bank until our unconditional release.
                testHooks?.readerPinned?()
                let result = selectedBank.value
                guard !publicationExhausted.load(ordering: .sequentiallyConsistent) else { return nil }
                return result
            }
            return nil
        }
    }
}
#endif
