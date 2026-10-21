import Foundation
import AVFoundation
import AudioToolbox
import Synchronization
import PlayerCore

/// One serial worker owns converters, preparation and renderer publication.
/// Three fixed native-reader lanes own every AVAssetReader operation. Leases
/// include retired/blocked sessions; a permit is reusable only after lane close.
/// Each lease has one mailbox/pending packet slot (<=128 KiB at eight channels).
/// Budget two owned payloads per lease for an old local Array binding overlapping
/// a new handoff, plus a separate lane PCM buffer (<=128 KiB). The unchanged
/// parser also caps each parsed packet at 1 MiB; none is a total RSS/SDK bound.
/// Converter input/output and the existing prefix/ring allocations are additional.
/// No native-reader SDK object or borrowed sample buffer crosses a lane boundary.
/// Pending input is neither EOF nor discard work; it never increments yieldCount.
/// Preparation retains the old eight logical 8192-frame initial-fill calls,
/// including the EOF probe when the complete source occupies the pinned prefix.
/// Limitations: a blocked native call cannot be interrupted by this design.
/// Three blocked leases cause bounded backpressure; current-source availability
/// and SDK-internal memory/thread behavior are not guaranteed.
final class ContinuousPCMDecoder: @unchecked Sendable {
    enum Failure: Error, Equatable, Sendable {
        case localFileRequired, invalidTimeline, unsupportedPCM, oversizedPacket
        case cannotDecode, slotInUse, cancelled
    }

    struct Prepared: Sendable {
        let token: Int
        let totalFrames: Int64
        let hasAudio: Bool
    }

    /// A measurement of the complete decoded presentation at -60 dBFS. Quiet
    /// source frames remain untouched; these counts are not player underruns.
    struct SourceSilence: Sendable {
        let totalFrames: Int64
        let leadingFrames: Int64
        let trailingFrames: Int64
        let peak: Float
    }

    private final class Cancellation: @unchecked Sendable {
        let value = Atomic<Bool>(false)
    }

    private enum ReadControl: Error { case deferred, pending }

    #if DEBUG
    /// An on-worker logical snapshot, never sampled by the audio callback.
    /// Pending jobs include completed payloads queued for worker acceptance and
    /// retired jobs awaiting close. These fields do not identify an SDK wait.
    struct DebugWorkerStats: Sendable {
        let leasedReaders: Int
        let peakLeasedReaders: Int
        let retiredLeasesAwaitingClose: Int
        let startingLeases: Int
        let pendingPreparations: Int
        let readJobsAwaitingAcceptanceOrClose: Int
        let mailboxPackets: Int
        let pendingOrMailboxPacketSlots: Int
        // Conservative capacity, not measured allocations: one old local payload
        // may overlap the next handoff although only one mailbox slot is used.
        let packetAllocationUpperBound: Int
        let maximumLeases = 3
        let maximumNativeFramesPerPacket = 4_096
        let maximumChannels = 8
        let maximumLaneBufferBytes = 131_072
        let maximumOwnedPacketBytes = 131_072
        let maximumOwnedPacketsPerLease = 2
        let maximumOwnedPayloadBytesPerLease = 262_144
        // Retained in Stream output before source-position discard, not a claim
        // that those frames have already reached the renderer or speaker.
        let positiveInputRanDryBuffersRetained: UInt64
        let positiveInputRanDryFramesRetained: UInt64
        let counterOverflowed: Bool
        let shutdownRequested: Bool
        let readerLeasesClosed: Bool
    }

    /// One-shot test gate immediately before native acquisition. This models an
    /// outstanding call boundary; it makes no claim about an SDK-internal wait.
    final class DebugNativeReadGate: @unchecked Sendable {
        private let target = Atomic<Int>(0)
        private let entered = Atomic<Bool>(false)
        private let returned = Atomic<Bool>(false)
        private let released = Atomic<Bool>(false)
        private let timedOut = Atomic<Bool>(false)
        private let semaphore = DispatchSemaphore(value: 0)

        func arm(token: Int) -> Bool {
            guard token > 0, !entered.load(ordering: .acquiring),
                  !released.load(ordering: .acquiring) else { return false }
            return target.compareExchange(expected: 0, desired: token,
                ordering: .acquiringAndReleasing).exchanged
        }
        var didEnter: Bool { entered.load(ordering: .acquiring) }
        var isHolding: Bool { didEnter && !returned.load(ordering: .acquiring) }
        var didTimeOut: Bool { timedOut.load(ordering: .acquiring) }

        func release() {
            if !released.exchange(true, ordering: .acquiringAndReleasing) { semaphore.signal() }
        }
        fileprivate func beforeCopy(token: Int) {
            guard token > 0, target.compareExchange(expected: token, desired: 0,
                ordering: .acquiringAndReleasing).exchanged else { return }
            entered.store(true, ordering: .releasing)
            timedOut.store(semaphore.wait(timeout: .now() + .seconds(5)) == .timedOut,
                ordering: .releasing)
            returned.store(true, ordering: .releasing)
        }
    }
    private var debugNativeReadGate: DebugNativeReadGate?
    func debugSetNativeReadGate(_ gate: DebugNativeReadGate) {
        worker.async { [self] in debugNativeReadGate = gate }
    }
    #endif

    private final class Description: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack?
        let totalFrames: Int64
        let endTime: CMTime
        let nativeRate: Double
        let nativeChannels: UInt32
        #if DEBUG
        var debugReadToken = 0
        var debugReadGate: DebugNativeReadGate?
        #endif
        init(asset: AVURLAsset, track: AVAssetTrack?, totalFrames: Int64, endTime: CMTime, nativeRate: Double, nativeChannels: UInt32) {
            self.asset = asset; self.track = track; self.totalFrames = totalFrames
            self.endTime = endTime
            self.nativeRate = nativeRate; self.nativeChannels = nativeChannels
        }
    }

    /// The converter worker alone reads/writes these mailbox fields. A converter
    /// input callback may execute elsewhere synchronously, but no worker completion
    /// can mutate the mailbox until that convert call has returned.
    private final class ReaderLease: @unchecked Sendable {
        let index: Int
        let lane: ReaderLane
        private let request: @Sendable (ReaderLease) -> Void
        var starting = true
        var readPending = false
        var retired = false
        var failure: Failure?
        var packet: NativePacket?
        var packetOffset = 0
        var requestedFrames = 0
        private(set) var reachedEnd = false
        var totalFrames: Int64

        init(index: Int, lane: ReaderLane, totalFrames: Int64,
             request: @escaping @Sendable (ReaderLease) -> Void) {
            self.index = index; self.lane = lane; self.totalFrames = totalFrames
            self.request = request
        }
        func read(into destination: AVAudioPCMBuffer, maximumFrames: Int) throws -> Int {
            guard !retired else { throw Failure.cancelled }
            if let failure { throw failure }
            let maximum = min(4_096, maximumFrames, Int(destination.frameCapacity))
            guard maximum > 0, let target = destination.floatChannelData?[0] else {
                throw Failure.unsupportedPCM
            }
            if let packet {
                let count = min(maximum, packet.frames - packetOffset)
                guard count > 0 else { throw Failure.cannotDecode }
                let channels = Int(destination.format.channelCount)
                guard packet.samples.count == packet.frames * channels else { throw Failure.unsupportedPCM }
                packet.samples.withUnsafeBufferPointer {
                    target.update(from: $0.baseAddress!.advanced(by: packetOffset * channels),
                                  count: count * channels)
                }
                packetOffset += count
                destination.frameLength = AVAudioFrameCount(count)
                if packetOffset == packet.frames {
                    self.packet = nil; packetOffset = 0
                    reachedEnd = packet.reachedEnd
                }
                return count
            }
            destination.frameLength = 0
            if reachedEnd { return 0 }
            if requestedFrames == 0, !readPending { requestedFrames = maximum }
            throw ReadControl.pending
        }
        func accept(_ value: NativePacket) throws {
            guard value.frames >= 0, value.frames <= 4_096,
                  value.samples.count <= 4_096 * 8,
                  value.frames > 0 || value.reachedEnd else { throw Failure.cannotDecode }
            totalFrames = value.totalFrames
            if value.frames == 0 { reachedEnd = true }
            else { packet = value; packetOffset = 0 }
        }
        func requestIfNeeded() {
            if !retired, !starting, !readPending, packet == nil, !reachedEnd,
               failure == nil, requestedFrames > 0 { request(self) }
        }
        func discard() {
            retired = true; requestedFrames = 0; packet = nil; packetOffset = 0
        }
    }

    private struct NativePacket: Sendable {
        let samples: [Float]
        let frames: Int
        let reachedEnd: Bool
        let totalFrames: Int64
    }

    /// Each fixed lane exclusively owns its NativeReader and native PCM buffer.
    /// Closing is queued behind any outstanding read; no cross-thread reader
    /// cancellation is attempted. Completions transfer owned scalar/Float data.
    private final class ReaderLane: @unchecked Sendable {
        private let queue: DispatchQueue
        private var reader: NativeReader?
        private var buffer: AVAudioPCMBuffer?

        init(index: Int) {
            queue = DispatchQueue(label: "OfflineTikTokPlayer.NativeRead.\(index)", qos: .userInitiated)
        }
        func start(_ description: Description,
                   completion: @escaping @Sendable (Result<Int64, Failure>) -> Void) {
            queue.async { [self] in
                let result: Result<Int64, Failure> = autoreleasepool {
                    do {
                        guard reader == nil, buffer == nil else { throw Failure.slotInUse }
                        let created = try NativeReader(description: description)
                        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                            sampleRate: description.nativeRate, channels: description.nativeChannels,
                            interleaved: true),
                            let createdBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)
                            else { throw Failure.unsupportedPCM }
                        reader = created; buffer = createdBuffer
                        return .success(created.totalFrames)
                    } catch { return .failure((error as? Failure) ?? .cannotDecode) }
                }
                completion(result)
            }
        }
        func read(maximumFrames: Int,
                  completion: @escaping @Sendable (Result<NativePacket, Failure>) -> Void) {
            let maximum = min(4_096, max(1, maximumFrames))
            queue.async { [self] in
                let result: Result<NativePacket, Failure> = autoreleasepool {
                    do {
                        guard let reader, let buffer else { throw Failure.cannotDecode }
                        let count = try reader.read(into: buffer, maximumFrames: maximum)
                        let channels = Int(buffer.format.channelCount)
                        guard (0...maximum).contains(count), (1...8).contains(channels),
                              let samples = buffer.floatChannelData?[0],
                              count > 0 || reader.reachedEnd else { throw Failure.cannotDecode }
                        let owned = Array(UnsafeBufferPointer(start: samples, count: count * channels))
                        return .success(NativePacket(samples: owned, frames: count,
                            reachedEnd: reader.reachedEnd, totalFrames: reader.totalFrames))
                    } catch { return .failure((error as? Failure) ?? .cannotDecode) }
                }
                completion(result)
            }
        }
        func close(completion: @escaping @Sendable () -> Void) {
            queue.async { [self] in
                autoreleasepool {
                    buffer = nil
                    reader = nil // NativeReader.deinit/cancelReading run only here.
                }
                completion()
            }
        }
    }

    private final class Slot {
        let token: Int
        let source: ContinuousPCMSource
        let description: Description
        let cancellation: Cancellation
        var stream: Stream?
        var epoch: Int
        var finished = false
        init(token: Int, source: ContinuousPCMSource, description: Description,
             cancellation: Cancellation, stream: Stream, epoch: Int) {
            self.token = token; self.source = source; self.description = description
            self.cancellation = cancellation; self.stream = stream; self.epoch = epoch
        }
    }

    private final class Preparation {
        let token: Int
        let index: Int
        let source: ContinuousPCMSource
        let description: Description
        let cancellation: Cancellation
        var continuation: CheckedContinuation<Prepared, Error>?
        var stream: Stream?
        var prefix: [Float]
        var prefixCount = 0
        var published = false
        // A logical read is not consumed by a temporary partial/pending return.
        var initialChunks = 8
        var initialGoal = 0
        var initialWritten = 0

        init(token: Int, index: Int, source: ContinuousPCMSource, description: Description,
             cancellation: Cancellation, continuation: CheckedContinuation<Prepared, Error>) {
            self.token = token; self.index = index; self.source = source
            self.description = description; self.cancellation = cancellation
            self.continuation = continuation
            prefix = [Float](repeating: 0, count: source.prefixCapacityFrames * 2)
        }
    }

    private let renderer: ContinuousPCMRenderer
    private let worker = DispatchQueue(label: "OfflineTikTokPlayer.PCMDecode", qos: .userInitiated)
    private let lanes = (0..<3).map { ReaderLane(index: $0) }
    private let readerClosures = DispatchGroup()
    private var leases: [ReaderLease?] = [nil, nil, nil]
    private var preparations: [Preparation?] = [nil, nil, nil]
    private var slots: [Slot?] = [nil, nil, nil]
    private var timer: DispatchSourceTimer?
    private var scratch = [Float](repeating: 0, count: 8_192 * 2)
    private var stopped = false
    private var pumpScheduled = false
    private var failureHandler: (@Sendable (Int, Failure) -> Void)?
    private var sourceSilenceHandler: (@Sendable (Int, SourceSilence) -> Void)?
    private let yieldCount = Atomic<Int64>(0)
    #if DEBUG
    private var peakLeasedReaders = 0
    private var positiveInputRanDryBuffersRetained: UInt64 = 0
    private var positiveInputRanDryFramesRetained: UInt64 = 0
    private var workerCounterOverflowed = false
    #endif

    /// Counts only the original eight-discard-buffer yields, never native pending.
    var cooperativeYieldCount: Int64 { yieldCount.load(ordering: .acquiring) }

    init(renderer: ContinuousPCMRenderer) {
        self.renderer = renderer
        let timer = DispatchSource.makeTimerSource(queue: worker)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
    }

    deinit {
        // Normal owners call shutdown. If a direct caller omits it, retain each
        // remaining lane through close so SDK reader destruction still occurs
        // there, and match its outstanding DispatchGroup entry exactly once.
        let group = readerClosures
        for lease in leases.compactMap({ $0 }) where !lease.retired {
            lease.lane.close { group.leave() }
        }
    }

    /// Metadata loading may suspend; decoding and publishing are serialized.
    /// Token values identify a preparation, never a media URL or persistent ID.
    func prepare(url: URL, token: Int, slot index: Int) async throws -> Prepared {
        guard url.isFileURL else { throw Failure.localFileRequired }
        guard token > 0, (0..<3).contains(index) else { throw Failure.invalidTimeline }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        // An approximate endpoint must never become an implicit content trim.
        guard try await asset.load(.providesPreciseDurationAndTiming) else { throw Failure.unsupportedPCM }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        // Do not mix alternate-language tracks together. Select the first enabled
        // audio track, matching the asset's ordinary default presentation.
        var selected: AVAssetTrack?
        for track in tracks where selected == nil {
            if try await track.load(.isEnabled) { selected = track }
        }
        selected = selected ?? tracks.first
        var end = duration
        if let selected {
            let range = try await selected.load(.timeRange)
            if range.end.isNumeric, CMTimeCompare(range.end, end) > 0 { end = range.end }
        }
        let frames = try Self.frame(end)
        guard frames > 0 else { throw Failure.invalidTimeline }
        var nativeRate = 48_000.0, nativeChannels: UInt32 = 2
        if let selected {
            let formats = try await selected.load(.formatDescriptions)
            guard let format = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  asbd.pointee.mSampleRate.isFinite, asbd.pointee.mSampleRate > 0,
                  (1...8).contains(asbd.pointee.mChannelsPerFrame) else { throw Failure.unsupportedPCM }
            nativeRate = asbd.pointee.mSampleRate; nativeChannels = asbd.pointee.mChannelsPerFrame
        }
        let description = Description(asset: asset, track: selected, totalFrames: frames, endTime: end,
            nativeRate: nativeRate, nativeChannels: nativeChannels)
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                worker.async { [self] in
                    guard !stopped, !cancellation.value.load(ordering: .acquiring) else {
                        continuation.resume(throwing: Failure.cancelled); return
                    }
                    if let old = slots[index], old.source.token != old.token { retireSlot(at: index) }
                    let source = renderer.source(at: index)
                    guard preparations[index] == nil, slots[index] == nil, source.token == 0 else {
                        continuation.resume(throwing: Failure.slotInUse); return
                    }
                    #if DEBUG
                    description.debugReadToken = token
                    description.debugReadGate = debugNativeReadGate
                    #endif
                    preparations[index] = Preparation(token: token, index: index, source: source,
                        description: description, cancellation: cancellation, continuation: continuation)
                    schedulePump()
                }
            }
        } onCancel: {
            cancellation.value.store(true, ordering: .releasing)
            self.worker.async { [self] in
                for index in preparations.indices where preparations[index]?.token == token {
                    finishPreparation(at: index, failure: .cancelled)
                }
                for index in slots.indices where slots[index]?.token == token { retireSlot(at: index) }
                schedulePump()
            }
        }
    }

    func retain(tokens: Set<Int>) {
        worker.async { [self] in
            for index in preparations.indices {
                if let pending = preparations[index], !tokens.contains(pending.token) {
                    finishPreparation(at: index, failure: .cancelled)
                }
            }
            for index in slots.indices {
                if let slot = slots[index], !tokens.contains(slot.token) { retireSlot(at: index) }
            }
            schedulePump()
        }
    }

    func setFailureHandler(_ handler: @escaping @Sendable (Int, Failure) -> Void) {
        worker.async { [self] in failureHandler = handler }
    }
    func setSourceSilenceHandler(_ handler: @escaping @Sendable (Int, SourceSilence) -> Void) {
        worker.async { [self] in sourceSilenceHandler = handler }
    }

    func shutdown() {
        worker.async { [self] in
            stopped = true
            timer?.setEventHandler {}; timer?.cancel(); timer = nil
            for index in preparations.indices { finishPreparation(at: index, failure: .cancelled) }
            for index in slots.indices { retireSlot(at: index) }
            for lease in leases.compactMap({ $0 }) { retire(lease) }
        }
    }

    #if DEBUG
    func debugWorkerStats(_ completion: @escaping @Sendable (DebugWorkerStats) -> Void) {
        worker.async { [self] in
            let present = leases.compactMap { $0 }
            let pending = present.filter { $0.readPending }.count
            let packets = present.filter { $0.packet != nil }.count
            completion(DebugWorkerStats(leasedReaders: present.count,
                peakLeasedReaders: peakLeasedReaders,
                retiredLeasesAwaitingClose: present.filter { $0.retired }.count,
                startingLeases: present.filter { $0.starting }.count,
                pendingPreparations: preparations.compactMap { $0 }.count,
                readJobsAwaitingAcceptanceOrClose: pending, mailboxPackets: packets,
                pendingOrMailboxPacketSlots: pending + packets,
                packetAllocationUpperBound: 2 * present.count,
                positiveInputRanDryBuffersRetained: positiveInputRanDryBuffersRetained,
                positiveInputRanDryFramesRetained: positiveInputRanDryFramesRetained,
                counterOverflowed: workerCounterOverflowed,
                shutdownRequested: stopped, readerLeasesClosed: present.isEmpty))
        }
    }

    private func notePositiveInputRanDry(frames: Int) {
        let buffers = positiveInputRanDryBuffersRetained.addingReportingOverflow(1)
        let samples = positiveInputRanDryFramesRetained.addingReportingOverflow(UInt64(frames))
        positiveInputRanDryBuffersRetained = buffers.overflow ? .max : buffers.partialValue
        positiveInputRanDryFramesRetained = samples.overflow ? .max : samples.partialValue
        workerCounterOverflowed = workerCounterOverflowed || buffers.overflow || samples.overflow
    }

    /// Queued acknowledgement includes native lane cancellation/release, not just
    /// stopped=true. A permanently blocked call therefore never reports success.
    func debugAfterShutdown(_ completion: @escaping @Sendable (Bool) -> Void) {
        worker.async { [self] in
            guard stopped else { completion(false); return }
            readerClosures.notify(queue: worker) { [self] in
                completion(stopped && leases.allSatisfy { $0 == nil }
                    && preparations.allSatisfy { $0 == nil } && slots.allSatisfy { $0 == nil })
            }
        }
    }
    #endif

    private func acquireReader(_ description: Description) throws -> ReaderLease {
        guard let index = leases.firstIndex(where: { $0 == nil }) else { throw ReadControl.pending }
        let total = try Self.frame(description.endTime, rate: description.nativeRate)
        let lease = ReaderLease(index: index, lane: lanes[index], totalFrames: total) { [weak self] lease in
            self?.requestRead(lease)
        }
        leases[index] = lease
        #if DEBUG
        peakLeasedReaders = max(peakLeasedReaders, leases.compactMap { $0 }.count)
        #endif
        readerClosures.enter()
        lease.lane.start(description) { [weak self, weak lease] result in
            guard let self, let lease else { return }
            self.worker.async { [weak self, weak lease] in
                guard let self, let lease, self.leases[index] === lease, !lease.retired else { return }
                lease.starting = false
                switch result {
                case .success(let total): lease.totalFrames = total
                case .failure(let failure): lease.failure = failure
                }
                lease.requestIfNeeded()
                self.schedulePump()
            }
        }
        return lease
    }

    private func requestRead(_ lease: ReaderLease) {
        guard !stopped, leases[lease.index] === lease, !lease.retired,
              !lease.starting, !lease.readPending, lease.packet == nil,
              !lease.reachedEnd, lease.failure == nil, lease.requestedFrames > 0 else { return }
        let requested = min(4_096, max(1, lease.requestedFrames))
        lease.requestedFrames = 0; lease.readPending = true
        lease.lane.read(maximumFrames: requested) { [weak self, weak lease] result in
            guard let self, let lease else { return }
            self.worker.async { [weak self, weak lease] in
                guard let self, let lease, self.leases[lease.index] === lease, !lease.retired else { return }
                lease.readPending = false
                do {
                    switch result {
                    case .success(let packet): try lease.accept(packet)
                    case .failure(let failure): lease.failure = failure
                    }
                } catch { lease.failure = (error as? Failure) ?? .cannotDecode }
                self.schedulePump()
            }
        }
    }

    private func retire(_ lease: ReaderLease) {
        guard !lease.retired else { return }
        lease.discard()
        // This bounded, queued close retains shutdown ownership until the SDK
        // call returns. ReaderLane stores no completion/decoder owner cycle.
        lease.lane.close { [self, lease] in
            worker.async { [self, lease] in
                if leases[lease.index] === lease { leases[lease.index] = nil }
                readerClosures.leave()
                schedulePump()
            }
        }
    }
    private func retireStream(_ stream: Stream?) {
        if let lease = stream?.readerLease { retire(lease) }
    }
    private func retireSlot(at index: Int) {
        guard let slot = slots[index] else { return }
        slots[index] = nil
        retireStream(slot.stream)
        slot.stream = nil
    }

    private func makeStream(description: Description, startFrame: Int64,
                            shouldCancel: @escaping () -> Bool) throws -> Stream {
        let lease: ReaderLease?
        if description.track == nil { lease = nil }
        else { lease = try acquireReader(description) }
        do {
            let stream = try Stream(description: description, startFrame: startFrame, native: lease,
                                    shouldCancel: shouldCancel)
            #if DEBUG
            stream.onPositiveInputRanDry = { [weak self] frames in self?.notePositiveInputRanDry(frames: frames) }
            #endif
            return stream
        } catch {
            if let lease { retire(lease) }
            throw error
        }
    }

    private func schedulePump() {
        guard !stopped, !pumpScheduled else { return }
        pumpScheduled = true
        worker.async { [weak self] in
            guard let self else { return }
            self.pumpScheduled = false
            self.pump()
        }
    }

    private func pump() {
        guard !stopped else { return }
        let more: Bool = autoreleasepool {
            let active = renderer.snapshot.token
            var more = false
            for index in slots.indices where preparations[index] == nil && slots[index]?.token == active {
                more = serviceSlot(at: index, chunks: 8) || more
            }
            for index in preparations.indices where preparations[index] != nil {
                do { more = try advancePreparation(at: index) || more }
                catch ReadControl.pending { }
                catch ReadControl.deferred {
                    yieldCount.store(yieldCount.load(ordering: .relaxed) &+ 1, ordering: .releasing)
                    more = true
                } catch { finishPreparation(at: index, failure: (error as? Failure) ?? .cannotDecode) }
            }
            for index in slots.indices where preparations[index] == nil && slots[index]?.token != active {
                more = serviceSlot(at: index, chunks: 2) || more
            }
            return more
        }
        if more { schedulePump() }
    }

    private func serviceSlot(at index: Int, chunks: Int) -> Bool {
        guard let slot = slots[index] else { return false }
        if slot.cancellation.value.load(ordering: .acquiring) || slot.source.token != slot.token {
            retireSlot(at: index); return false
        }
        do { return try fill(slot, chunks: chunks) }
        catch ReadControl.pending { return false }
        catch ReadControl.deferred {
            yieldCount.store(yieldCount.load(ordering: .relaxed) &+ 1, ordering: .releasing)
            return true
        } catch {
            if (error as? Failure) == .cancelled {
                if slot.source.token != slot.token || slot.cancellation.value.load(ordering: .acquiring) {
                    retireSlot(at: index)
                }
            } else {
                retireSlot(at: index)
                failureHandler?(slot.token, (error as? Failure) ?? .cannotDecode)
            }
            return false
        }
    }

    private func advancePreparation(at index: Int) throws -> Bool {
        guard let pending = preparations[index] else { return false }
        guard !pending.cancellation.value.load(ordering: .acquiring) else { throw Failure.cancelled }
        if pending.stream == nil {
            let source = pending.source, token = pending.token, cancellation = pending.cancellation
            pending.stream = try makeStream(description: pending.description, startFrame: 0) {
                cancellation.value.load(ordering: .acquiring)
                    || (source.token != 0 && (source.token != token || source.streamRequest.epoch != 2))
            }
        }
        guard let stream = pending.stream else { throw Failure.cannotDecode }
        var budget = 8 * 8_192
        if !pending.published {
            while pending.prefixCount < pending.source.prefixCapacityFrames && !stream.reachedEnd {
                let capacity = min(8_192, budget, pending.source.prefixCapacityFrames - pending.prefixCount)
                guard capacity > 0 else { return true }
                let count = try scratch.withUnsafeMutableBufferPointer {
                    try stream.read(into: $0, maximumFrames: capacity)
                }
                guard count > 0 || stream.reachedEnd else { throw Failure.cannotDecode }
                if count > 0 {
                    let offset = pending.prefixCount * 2
                    pending.prefix.withUnsafeMutableBufferPointer { destination in
                        scratch.withUnsafeBufferPointer {
                            destination.baseAddress!.advanced(by: offset).update(from: $0.baseAddress!, count: count * 2)
                        }
                    }
                    pending.prefixCount += count; budget -= count
                }
            }
            guard pending.prefixCount == min(Int64(pending.source.prefixCapacityFrames), stream.totalFrames) else {
                throw Failure.cannotDecode
            }
            guard !pending.cancellation.value.load(ordering: .acquiring) else { throw Failure.cancelled }
            let published = pending.prefix.withUnsafeBufferPointer {
                pending.source.prepare(token: pending.token, totalFrames: stream.totalFrames,
                    prefix: UnsafeBufferPointer(rebasing: $0[..<(pending.prefixCount * 2)]))
            }
            guard published else { throw Failure.slotInUse }
            let request = pending.source.streamRequest
            guard pending.source.beginStream(epoch: request.epoch) else { throw Failure.cancelled }
            pending.published = true
            slots[index] = Slot(token: pending.token, source: pending.source, description: pending.description,
                cancellation: pending.cancellation, stream: stream, epoch: request.epoch)
        }
        guard let slot = slots[index], slot.token == pending.token,
              slot.source.token == pending.token, slot.source.streamRequest.epoch == slot.epoch else {
            throw Failure.cancelled
        }
        while pending.initialChunks > 0 {
            if pending.initialGoal == 0 {
                pending.initialGoal = min(8_192, slot.source.writableStreamFrames)
                pending.initialWritten = 0
                if pending.initialGoal == 0 {
                    finishPreparation(at: index, failure: nil); return false
                }
            }
            guard budget > 0 else { return true }
            let capacity = min(budget, pending.initialGoal - pending.initialWritten)
            let count = try scratch.withUnsafeMutableBufferPointer {
                try stream.read(into: $0, maximumFrames: capacity)
            }
            reportSourceSilence(stream, token: slot.token)
            if count == 0 {
                slot.source.finishStream(totalFrames: stream.totalFrames, epoch: slot.epoch)
                slot.finished = true
                finishPreparation(at: index, failure: nil); return false
            }
            let accepted = scratch.withUnsafeBufferPointer {
                slot.source.append(interleaved: UnsafeBufferPointer(rebasing: $0[..<(count * 2)]), epoch: slot.epoch)
            }
            guard accepted == count else { throw Failure.cancelled }
            pending.initialWritten += count; budget -= count
            if pending.initialWritten == pending.initialGoal || stream.reachedEnd {
                pending.initialChunks -= 1; pending.initialGoal = 0; pending.initialWritten = 0
            }
        }
        finishPreparation(at: index, failure: nil)
        return false
    }

    private func finishPreparation(at index: Int, failure: Failure?) {
        guard let pending = preparations[index] else { return }
        preparations[index] = nil
        let continuation = pending.continuation
        pending.continuation = nil
        if let failure {
            if slots[index]?.token == pending.token { retireSlot(at: index) }
            else { retireStream(pending.stream) }
            continuation?.resume(throwing: failure)
        } else if let stream = pending.stream {
            continuation?.resume(returning: Prepared(token: pending.token,
                totalFrames: stream.totalFrames, hasAudio: pending.description.track != nil))
        } else {
            continuation?.resume(throwing: Failure.cannotDecode)
        }
    }

    private func reportSourceSilence(_ stream: Stream, token: Int) {
        if let analysis = stream.takeSourceSilence() { sourceSilenceHandler?(token, analysis) }
    }

    private func fill(_ slot: Slot, chunks: Int) throws -> Bool {
        let request = slot.source.streamRequest
        if request.epoch != slot.epoch {
            retireStream(slot.stream)
            slot.stream = nil
            if request.startFrame >= slot.source.totalFrames {
                guard slot.source.beginStream(epoch: request.epoch) else { throw Failure.cancelled }
                slot.epoch = request.epoch; slot.finished = true
                slot.source.finishStream(totalFrames: slot.source.totalFrames, epoch: slot.epoch)
                return false
            }
            let source = slot.source, token = slot.token, cancellation = slot.cancellation
            let stream = try makeStream(description: slot.description, startFrame: request.startFrame) {
                cancellation.value.load(ordering: .acquiring)
                    || source.token != token || source.streamRequest.epoch != request.epoch
            }
            guard slot.source.beginStream(epoch: request.epoch) else {
                retireStream(stream); throw Failure.cancelled
            }
            slot.stream = stream; slot.epoch = request.epoch; slot.finished = false
        }
        guard !slot.finished, let stream = slot.stream else { return false }
        var budget = chunks * 8_192
        while budget > 0 {
            guard slot.source.token == slot.token, slot.source.streamRequest.epoch == slot.epoch else {
                throw Failure.cancelled
            }
            let capacity = min(8_192, budget, slot.source.writableStreamFrames)
            guard capacity > 0 else { return false }
            let count = try scratch.withUnsafeMutableBufferPointer {
                try stream.read(into: $0, maximumFrames: capacity)
            }
            reportSourceSilence(stream, token: slot.token)
            if count == 0 {
                slot.source.finishStream(totalFrames: stream.totalFrames, epoch: slot.epoch)
                slot.finished = true; return false
            }
            let accepted = scratch.withUnsafeBufferPointer {
                slot.source.append(interleaved: UnsafeBufferPointer(rebasing: $0[..<(count * 2)]), epoch: slot.epoch)
            }
            guard accepted == count else { throw Failure.cancelled }
            budget -= count
        }
        return slot.source.writableStreamFrames > 0
    }

    private static func frame(_ time: CMTime, rate: Double = 48_000) throws -> Int64 {
        guard time.isNumeric, time.seconds.isFinite, abs(time.seconds) < 86_400 else { throw Failure.invalidTimeline }
        guard rate.isFinite, rate > 0, rate.rounded() == rate, rate <= 384_000 else { throw Failure.unsupportedPCM }
        return CMTimeConvertScale(time, timescale: CMTimeScale(rate), method: .roundHalfAwayFromZero).value
    }

    /// Native-rate demux/decode followed by an explicit, flushed converter. The
    /// reader's implicit sample-rate conversion is deliberately avoided: native
    /// regression runs found that it could omit buffered resampler tail samples.
    private final class Stream {
        private let native: ReaderLease?
        private let converter: AVAudioConverter?
        private let input: AVAudioPCMBuffer?
        private let output: AVAudioPCMBuffer?
        private let nativeRate: Double
        private let shouldCancel: () -> Bool
        private var outputStart: Int64 = 0
        private var outputCount = 0
        private var generatedFrames: Int64 = 0
        private var supportFramesSupplied: Int64 = 0
        private var converterFinished = false
        // A zero-output native suspension does not end the logical discard
        // attempt. Preserve only its actual skipped buffers across that boundary.
        private var discardedBeforePending = 0
        private var cursor: Int64
        private var eof = false
        private(set) var totalFrames: Int64
        private var analysisValid: Bool
        private var analysisReported = false
        private var firstAboveThreshold: Int64?
        private var lastAboveThreshold: Int64?
        private var peak: Float = 0
        #if DEBUG
        var onPositiveInputRanDry: ((Int) -> Void)?
        #endif

        var readerLease: ReaderLease? { native }
        var reachedEnd: Bool { eof }

        init(description: Description, startFrame: Int64, native: ReaderLease?,
             shouldCancel: @escaping () -> Bool) throws {
            totalFrames = description.totalFrames; cursor = max(0, startFrame)
            nativeRate = description.nativeRate
            self.shouldCancel = shouldCancel
            analysisValid = startFrame == 0
            guard description.track != nil else {
                self.native = nil; converter = nil; input = nil; output = nil; return
            }
            guard let native else { throw Failure.cannotDecode }
            guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: description.nativeRate,
                    channels: description.nativeChannels, interleaved: true),
                  let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
                  let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_096),
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else { throw Failure.unsupportedPCM }
            if description.nativeChannels == 1 { converter.channelMap = [0, 0] }
            self.native = native; self.converter = converter; self.input = input; self.output = output
            // A reopen starts from the source's beginning and discards converted
            // output up to the requested frame. This retains exactly the original
            // SRC phase/history with bounded storage. Ordinary loop/reversal
            // refills only need to rebuild the fixed two-second pinned prefix.
        }

        func read(into destination: UnsafeMutableBufferPointer<Float>, maximumFrames: Int) throws -> Int {
            let maximum = min(maximumFrames, destination.count / 2)
            let firstFrame = cursor
            var written = 0
            var skippedBuffers = discardedBeforePending
            discardedBeforePending = 0
            while written < maximum {
                if shouldCancel() { throw Failure.cancelled }
                if native == nil {
                    let count = min(maximum - written, Int(max(0, totalFrames - cursor)))
                    guard count > 0 else { eof = true; break }
                    destination.baseAddress!.advanced(by: written * 2).update(repeating: 0, count: count * 2)
                    cursor += Int64(count); written += count; continue
                }
                if outputCount == 0, !eof {
                    do { try convertNext() }
                    catch ReadControl.pending {
                        // Preserve already-written frames and run source analysis
                        // below. Zero progress alone propagates pending to pump.
                        if written == 0 {
                            discardedBeforePending = skippedBuffers
                            throw ReadControl.pending
                        }
                        break
                    }
                }
                if eof {
                    // No synthetic zeros may conceal an unflushed/short converter.
                    guard cursor >= totalFrames else { throw Failure.cannotDecode }
                    break
                }
                let end = outputStart + Int64(outputCount)
                if end <= cursor {
                    outputCount = 0
                    skippedBuffers += 1
                    // Yield only before emitting anything. No copied frames can
                    // be lost, and initial prefix preparation is unaffected.
                    if written == 0, skippedBuffers >= 8 { throw ReadControl.deferred }
                    continue
                }
                if outputStart >= totalFrames { outputCount = 0; continue }
                guard outputStart <= cursor, let samples = output?.floatChannelData?[0] else { throw Failure.invalidTimeline }
                let offset = Int(cursor - outputStart)
                let count = min(maximum - written, outputCount - offset, Int(max(0, totalFrames - cursor)))
                guard count > 0 else { outputCount = 0; continue }
                destination.baseAddress!.advanced(by: written * 2).update(from: samples.advanced(by: offset * 2), count: count * 2)
                cursor += Int64(count); written += count
                if cursor >= end { outputCount = 0 }
            }
            if analysisValid {
                // Inspect only the PCM already copied by this read. This adds no
                // demux pass, allocations, retained audio or render-thread work.
                for frame in 0..<written {
                    let left = destination[frame * 2], right = destination[frame * 2 + 1]
                    guard left.isFinite, right.isFinite else { analysisValid = false; break }
                    let magnitude = max(abs(left), abs(right))
                    peak = max(peak, magnitude)
                    if magnitude >= 0.001 {
                        if firstAboveThreshold == nil { firstAboveThreshold = firstFrame + Int64(frame) }
                        lastAboveThreshold = firstFrame + Int64(frame)
                    }
                }
            }
            return written
        }

        func takeSourceSilence() -> SourceSilence? {
            guard analysisValid, !analysisReported, eof, cursor >= totalFrames else { return nil }
            analysisReported = true
            return SourceSilence(totalFrames: totalFrames,
                leadingFrames: firstAboveThreshold ?? totalFrames,
                trailingFrames: lastAboveThreshold.map { totalFrames - $0 - 1 } ?? totalFrames,
                peak: peak)
        }

        private func convertNext() throws {
            guard !converterFinished else { eof = true; return }
            guard let native, let converter, let input, let output else { throw Failure.cannotDecode }
            for _ in 0..<8 {
                if shouldCancel() { throw Failure.cancelled }
                output.frameLength = 0
                var inputFailure: Failure?
                var waitingForNative = false
                var conversionError: NSError?
                let sourceTarget = totalFrames, rate = nativeRate
                var suppliedSupport = supportFramesSupplied
                let status = converter.convert(to: output, error: &conversionError) { requested, status in
                    do {
                        guard requested > 0 else { status.pointee = .noDataNow; return nil }
                        let count = try native.read(into: input,
                            maximumFrames: min(Int(requested), Int(input.frameCapacity)))
                        if count == 0 {
                            guard native.reachedEnd else { throw Failure.cannotDecode }
                            // Preserve the original bounded native-domain support
                            // after true EOF; never fabricate converted output.
                            let requiredNative = (sourceTarget * Int64(rate) + 47_999) / 48_000
                            let support = max(0, requiredNative - native.totalFrames)
                            let maximumSupport = Int64(ceil(rate / 96_000 + 0.5))
                            guard support <= maximumSupport else { throw Failure.invalidTimeline }
                            let needed = support - suppliedSupport
                            if needed > 0 {
                                let frames = min(Int(needed), Int(requested), Int(input.frameCapacity))
                                guard frames > 0, let samples = input.floatChannelData?[0] else {
                                    throw Failure.cannotDecode
                                }
                                samples.update(repeating: 0, count: frames * Int(input.format.channelCount))
                                input.frameLength = AVAudioFrameCount(frames)
                                suppliedSupport += Int64(frames)
                                status.pointee = .haveData; return input
                            }
                            status.pointee = .endOfStream; return nil
                        }
                        status.pointee = .haveData; return input
                    } catch ReadControl.pending {
                        waitingForNative = true
                        status.pointee = .noDataNow; return nil
                    } catch {
                        inputFailure = (error as? Failure) ?? .cannotDecode
                        status.pointee = .endOfStream; return nil
                    }
                }
                supportFramesSupplied = suppliedSupport
                if let inputFailure { throw inputFailure }
                guard status != .error, conversionError == nil else { throw Failure.cannotDecode }
                if status == .endOfStream { converterFinished = true }
                outputStart = generatedFrames; outputCount = Int(output.frameLength)
                generatedFrames += Int64(outputCount)
                #if DEBUG
                if status == .inputRanDry, outputCount > 0 { onPositiveInputRanDry?(outputCount) }
                #endif
                // The callback only marks demand. SDK work is dispatched after
                // synchronous convert returns, even if inputRanDry produced PCM.
                native.requestIfNeeded()
                if outputCount > 0 { return }
                if converterFinished { eof = true; return }
                if waitingForNative { throw ReadControl.pending }
            }
            throw Failure.cannotDecode
        }
    }

    /// Preserve native PCM sample counts; only explicit codec trim attachments
    /// may remove samples. Timestamps place edits/gaps on the source timeline.
    private final class NativeReader {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        #if DEBUG
        private let debugReadToken: Int
        private let debugReadGate: DebugNativeReadGate?
        #endif
        private let rate: Double
        private let channels: Int
        private var samples: [Float] = []
        private var sampleOffset = 0
        private var sampleCount = 0
        private var sampleStart: Int64 = 0
        private var cursor: Int64 = 0
        private var eof = false
        private(set) var totalFrames: Int64
        var reachedEnd: Bool { eof && sampleCount == 0 && cursor >= totalFrames }

        init(description: Description) throws {
            guard let track = description.track else { throw Failure.cannotDecode }
            #if DEBUG
            debugReadToken = description.debugReadToken
            debugReadGate = description.debugReadGate
            #endif
            rate = description.nativeRate; channels = Int(description.nativeChannels)
            totalFrames = try ContinuousPCMDecoder.frame(description.endTime, rate: rate)
            reader = try AVAssetReader(asset: description.asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure.cannotDecode }
            reader.add(output)
            // The default range extends to positive infinity and may expose
            // decoder postroll outside a compressed asset's presentation.
            // Request the complete declared asset/track interval explicitly.
            reader.timeRange = CMTimeRange(start: .zero, duration: description.endTime)
            guard reader.startReading() else { throw Failure.cannotDecode }
        }

        deinit { reader.cancelReading() }

        func read(into destination: AVAudioPCMBuffer, maximumFrames: Int) throws -> Int {
            guard let target = destination.floatChannelData?[0] else { throw Failure.unsupportedPCM }
            let maximum = min(maximumFrames, Int(destination.frameCapacity))
            var written = 0
            while written < maximum {
                if sampleCount == 0, !eof { try nextSample() }
                if sampleCount == 0, eof {
                    let count = min(maximum - written, Int(max(0, totalFrames - cursor)))
                    guard count > 0 else { break }
                    target.advanced(by: written * channels).update(repeating: 0, count: count * channels)
                    cursor += Int64(count); written += count; continue
                }
                let end = sampleStart + Int64(sampleCount)
                if end <= cursor { sampleCount = 0; continue }
                if sampleStart > cursor {
                    let count = min(maximum - written, Int(sampleStart - cursor))
                    target.advanced(by: written * channels).update(repeating: 0, count: count * channels)
                    cursor += Int64(count); written += count; continue
                }
                let offset = Int(cursor - sampleStart)
                let count = min(maximum - written, sampleCount - offset)
                samples.withUnsafeBufferPointer {
                    target.advanced(by: written * channels).update(from: $0.baseAddress!.advanced(by: (sampleOffset + offset) * channels), count: count * channels)
                }
                cursor += Int64(count); written += count
                if cursor >= end { sampleCount = 0 }
            }
            destination.frameLength = AVAudioFrameCount(written)
            return written
        }

        private func nextSample() throws {
            #if DEBUG
            debugReadGate?.beforeCopy(token: debugReadToken)
            #endif
            guard let buffer = output.copyNextSampleBuffer() else {
                guard reader.status == .completed else { throw Failure.cannotDecode }
                eof = true; return
            }
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  asbd.pointee.mFormatID == kAudioFormatLinearPCM,
                  asbd.pointee.mSampleRate == rate,
                  asbd.pointee.mChannelsPerFrame == channels,
                  asbd.pointee.mBytesPerFrame == channels * 4,
                  asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  let block = CMSampleBufferGetDataBuffer(buffer) else { throw Failure.unsupportedPCM }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes > 0, bytes % (channels * 4) == 0 else { throw Failure.unsupportedPCM }
            let frames = bytes / (channels * 4)
            // Reject an unexpectedly huge demux packet rather than allowing one
            // source to defeat the fixed prefix/ring memory budget.
            guard bytes <= 1_048_576 else { throw Failure.oversizedPacket }
            let outputPTS = CMSampleBufferGetOutputPresentationTimeStamp(buffer)
            let start = try ContinuousPCMDecoder.frame(outputPTS, rate: rate)
            // Output PTS may also contain a track edit/offset. Only the explicit
            // trim attachment identifies samples to omit from the PCM buffer;
            // subtracting raw PTS would mistake a legitimate edit for priming.
            func trim(_ key: CFString) throws -> Int64 {
                guard let dictionary = CMGetAttachment(buffer, key: key, attachmentModeOut: nil) as? [String: Any] else { return 0 }
                return max(0, try ContinuousPCMDecoder.frame(CMTimeMakeFromDictionary(dictionary as CFDictionary), rate: rate))
            }
            let trimStart = try trim(kCMSampleBufferAttachmentKey_TrimDurationAtStart)
            let trimEnd = try trim(kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
            guard trimStart + trimEnd <= Int64(frames) else { throw Failure.invalidTimeline }
            let decodedFrames = Int64(frames) - trimStart - trimEnd
            let outputDuration = CMSampleBufferGetOutputDuration(buffer)
            if outputDuration.isNumeric {
                let durationFrames = try ContinuousPCMDecoder.frame(outputDuration, rate: rate)
                // The native-rate output has no SRC discrepancy. A scaled edit
                // needs an explicit time-pitch implementation, not silent sample
                // deletion or duplication to force it onto the timeline.
                guard abs(durationFrames - decodedFrames) <= 1 else { throw Failure.unsupportedPCM }
            }
            // Explicit finite reader ranges can still straddle a packet. Keep
            // the intersection with the precise declared presentation, after
            // declared codec trims; decoder postroll cannot extend playback.
            let validFrames = max(0, min(decodedFrames, totalFrames - start))
            samples = [Float](repeating: 0, count: frames * channels)
            let result = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
            }
            guard result == kCMBlockBufferNoErr else { throw Failure.cannotDecode }
            sampleStart = start; sampleOffset = Int(trimStart); sampleCount = Int(validFrames)
        }
    }
}
