import Foundation
import AVFoundation
import AudioToolbox
import Synchronization
import PlayerCore

/// One serial worker owns converters, preparation and renderer publication.
/// Three fixed native-reader lanes own every native file/asset-reader operation. Leases
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
    /// Worker-only counterfactual. Asset identities are local ordinals, never URLs.
    /// Both arms retain the same asset on each lease until actual close acceptance.
    struct DebugReaderAdmissionState: Sendable {
        struct Event: Sendable {
            let ordinal: Int, kind: Int, asset: Int, lease: Int, lane: Int, token: Int
            let matchingMask: Int, retiredMask: Int, freeMask: Int
        }
        let excludesSameAsset: Bool, overflowed: Bool
        let exclusions: Int, overlaps: Int, events: [Event]
    }
    final class DebugReaderAdmissionRecorder: @unchecked Sendable {
        let excludesSameAsset: Bool
        private var nextAsset = 0, nextLease = 0, exclusions = 0, overlaps = 0
        private var overflowed = false
        private var events: [DebugReaderAdmissionState.Event] = []
        init(excludesSameAsset: Bool) {
            self.excludesSameAsset = excludesSameAsset
            events.reserveCapacity(256)
        }
        fileprivate func asset() -> Int {
            guard nextAsset < 64 else { overflowed = true; return 0 }
            nextAsset += 1; return nextAsset
        }
        fileprivate func lease() -> Int {
            guard nextLease < 128 else { overflowed = true; return 0 }
            nextLease += 1; return nextLease
        }
        fileprivate func note(kind: Int, asset: Int, lease: Int, lane: Int, token: Int,
                              matchingMask: Int = 0, retiredMask: Int = 0, freeMask: Int = 0) {
            // kind: 1 admitted, 2 excluded, 3 actual close accepted.
            if kind == 2 { exclusions = min(257, exclusions + 1) }
            if kind == 1 && matchingMask != 0 { overlaps = min(257, overlaps + 1) }
            guard events.count < 256, asset > 0, kind != 1 || lease > 0 else {
                overflowed = true; return
            }
            events.append(.init(ordinal: events.count, kind: kind, asset: asset, lease: lease,
                lane: lane, token: token, matchingMask: matchingMask, retiredMask: retiredMask, freeMask: freeMask))
        }
        fileprivate func snapshot() -> DebugReaderAdmissionState {
            .init(excludesSameAsset: excludesSameAsset, overflowed: overflowed,
                  exclusions: exclusions, overlaps: overlaps, events: events)
        }
    }

    enum DebugNativeLaneActivityStage: UInt64, Sendable {
        case none = 0, construction = 1, startReading = 2, nativeReadEntered = 3
        case copyEntered = 4, copyReturned = 5, parser = 6, nativeReadReturned = 7, close = 8
        case startReadingReturned = 9, constructionReturned = 10, buffersReady = 11
        case startResultReady = 12, startCompletionReturned = 13, closeReturned = 14
    }
    struct DebugNativeLaneActivitySnapshot: Sendable {
        let laneIndex: Int
        let packedState: UInt64
        let copySequence: UInt64
        let stageCode: UInt64
        let sequenceOverflowed: Bool
    }
    enum DebugWorkerActivityStage: UInt64, Sendable {
        case none = 0, pumpEntered = 1, rendererSnapshotEntered = 2, rendererSnapshotReturned = 3
        case fillEntered = 4, fillReturned = 5, converterEntered = 6, converterReturned = 7
        case requestEntered = 8, requestReturned = 9, shutdownEntered = 10, shutdownReturned = 11
        case closeAcceptanceEntered = 12, closeAcceptanceReturned = 13, pumpReturned = 14
        case streamConstructionEntered = 15, streamConstructionReturned = 16
        case streamReleaseEntered = 17, streamReleaseReturned = 18
        case packetAcceptanceEntered = 19, packetAcceptanceReturned = 20, readEnqueued = 21
        case acknowledgementEntered = 22, acknowledgementReturned = 23
    }
    struct DebugWorkerActivitySnapshot: Sendable {
        let packedState: UInt64, sequence: UInt64, stageCode: UInt64, token: UInt64
        let overflowed: Bool
    }
    /// Three independent scalar records. Only the owning serial native lane
    /// writes its record. Readers load one packed word; leases/lanes/worker
    /// observations have no shared coherence or timing guarantee.
    final class DebugNativeLaneActivityRecorder: @unchecked Sendable {
        /// One worker writer, one packed scalar read. Token/sequence saturation
        /// invalidates diagnostics without changing decoding or wrapping identity.
        fileprivate final class WorkerRecord: @unchecked Sendable {
            private let packed = Atomic<UInt64>(0)
            private var sequence: UInt64 = 0
            private var overflowed = false
            fileprivate var conversionGate: DebugNativeReadGate? // Worker only; calibration only.
            fileprivate static let tokenMask: UInt64 = (1 << 24) - 1
            fileprivate static let sequenceMask: UInt64 = (1 << 34) - 1
            fileprivate func publish(_ stage: DebugWorkerActivityStage, token: Int = 0) {
                if sequence == Self.sequenceMask { overflowed = true } else { sequence += 1 }
                let valid = token >= 0 && UInt64(token) <= Self.tokenMask
                if !valid { overflowed = true }
                packed.store((sequence << 29) | ((valid ? UInt64(token) : 0) << 5)
                    | stage.rawValue | (overflowed ? UInt64(1) << 63 : 0), ordering: .releasing)
            }
            fileprivate func beforeConversion(token: Int) {
                publish(.converterEntered, token: token)
                // Deliberate calibration hold is before the real SDK call.
                conversionGate?.beforeCopy(token: token)
            }
            fileprivate func snapshot() -> DebugWorkerActivitySnapshot {
                let value = packed.load(ordering: .acquiring)
                return DebugWorkerActivitySnapshot(packedState: value,
                    sequence: (value >> 29) & Self.sequenceMask, stageCode: value & 31,
                    token: (value >> 5) & Self.tokenMask, overflowed: value & (UInt64(1) << 63) != 0)
            }
        }
        fileprivate let worker = WorkerRecord()
        func workerSnapshot() -> DebugWorkerActivitySnapshot { worker.snapshot() }
        fileprivate final class Record: @unchecked Sendable {
            let laneIndex: Int
            let beforeCopyThread: (@Sendable (Int, UInt64) -> Void)?
            init(laneIndex: Int, beforeCopyThread: (@Sendable (Int, UInt64) -> Void)?) {
                self.laneIndex = laneIndex; self.beforeCopyThread = beforeCopyThread
            }
            private let packed = Atomic<UInt64>(0)
            private var sequence: UInt64 = 0 // Owning lane only.
            private var overflowed = false // Latched, never wraps the sequence.
            fileprivate static let maximumSequence = (UInt64(1) << 59) - 1
            fileprivate static let overflowBit = UInt64(1) << 63

            fileprivate func publish(_ stage: DebugNativeLaneActivityStage) {
                packed.store((sequence << 4) | stage.rawValue | (overflowed ? Self.overflowBit : 0),
                             ordering: .releasing)
            }
            fileprivate func enterCopy() {
                if sequence == Self.maximumSequence { overflowed = true }
                else { sequence += 1 }
                publish(.copyEntered)
            }
            fileprivate func recordExecutingThreadBeforeGate() {
                guard sequence < Self.maximumSequence, !overflowed else { return }
                beforeCopyThread?(laneIndex, sequence + 1)
            }
            fileprivate func load() -> UInt64 { packed.load(ordering: .acquiring) }
        }
        private let first: Record, second: Record, third: Record
        init(beforeCopyThread: (@Sendable (Int, UInt64) -> Void)? = nil) {
            first = Record(laneIndex: 0, beforeCopyThread: beforeCopyThread)
            second = Record(laneIndex: 1, beforeCopyThread: beforeCopyThread)
            third = Record(laneIndex: 2, beforeCopyThread: beforeCopyThread)
        }
        fileprivate func record(at laneIndex: Int) -> Record {
            switch laneIndex {
            case 0: return first
            case 1: return second
            case 2: return third
            default: preconditionFailure("Three native lanes")
            }
        }
        func snapshot(at laneIndex: Int) -> DebugNativeLaneActivitySnapshot? {
            guard (0..<3).contains(laneIndex) else { return nil }
            let value = record(at: laneIndex).load()
            return DebugNativeLaneActivitySnapshot(laneIndex: laneIndex, packedState: value,
                copySequence: (value >> 4) & Record.maximumSequence, stageCode: value & 15,
                sequenceOverflowed: value & Record.overflowBit != 0)
        }
    }

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
        // Effective downstream status, retained before source-position discard.
        // DEBUG-controlled observations are separated from actual native status.
        // None of these counts claims renderer-written or speaker output frames.
        let positiveInputRanDryBuffersRetained: UInt64
        let positiveInputRanDryFramesRetained: UInt64
        let nativePositiveInputRanDryBuffersRetained: UInt64
        let nativePositiveInputRanDryFramesRetained: UInt64
        let injectedPositiveInputRanDryBuffersRetained: UInt64
        let injectedPositiveInputRanDryFramesRetained: UInt64
        let positiveInputRanDryContractInjectionEnabled: Bool
        let counterOverflowed: Bool
        let shutdownRequested: Bool
        let readerLeasesClosed: Bool
    }

    /// Requested only after a test has already failed. All mutable fields below
    /// are read on the existing worker; no native object or SDK state is queried.
    struct DebugStreamState: Sendable {
        let cursor: Int64
        let generatedFrames: Int64
        let outputStart: Int64
        let outputCount: Int
        let converterFinished: Bool
        let reachedEnd: Bool
    }
    struct DebugSlotState: Sendable {
        let index: Int
        let token: Int
        let epoch: Int
        let finished: Bool
        let cancelled: Bool
        let leaseIndex: Int
        let stream: DebugStreamState?
    }
    struct DebugLeaseState: Sendable {
        let index: Int
        let admissionAssetID: Int, admissionLeaseID: Int
        let present: Bool
        let starting: Bool
        let readPending: Bool
        let retired: Bool
        let requestedFrames: Int
        let packetFrames: Int
        let packetOffset: Int
        let reachedEnd: Bool
        let hasFailure: Bool
    }
    struct DebugFailureState: Sendable {
        let stats: DebugWorkerStats
        let preparationTokens: [Int] // Exactly three physical preparation slots.
        let slots: [DebugSlotState] // Exactly three physical playback slots.
        let leases: [DebugLeaseState] // Exactly three physical native lanes.
        let admission: DebugReaderAdmissionState?
    }

    /// One-shot test gate immediately before native acquisition. This models an
    /// outstanding call boundary; it makes no claim about an SDK-internal wait.
    final class DebugNativeReadGate: @unchecked Sendable {
        private let target = Atomic<Int>(0)
        private let entered = Atomic<Bool>(false)
        private let returned = Atomic<Bool>(false)
        private let released = Atomic<Bool>(false)
        private let timedOut = Atomic<Bool>(false)
        private let lane = Atomic<Int>(-1)
        private let semaphore = DispatchSemaphore(value: 0)

        func arm(token: Int) -> Bool {
            guard token > 0, !entered.load(ordering: .acquiring),
                  !released.load(ordering: .acquiring) else { return false }
            return target.compareExchange(expected: 0, desired: token,
                ordering: .acquiringAndReleasing).exchanged
        }
        var didEnter: Bool { entered.load(ordering: .acquiring) }
        var enteredLane: Int { didEnter ? lane.load(ordering: .acquiring) : -1 }
        var isHolding: Bool { didEnter && !returned.load(ordering: .acquiring) }
        var didTimeOut: Bool { timedOut.load(ordering: .acquiring) }

        func release() {
            if !released.exchange(true, ordering: .acquiringAndReleasing) { semaphore.signal() }
        }
        fileprivate func beforeCopy(token: Int, laneIndex: Int = -1) {
            guard token > 0, target.compareExchange(expected: token, desired: 0,
                ordering: .acquiringAndReleasing).exchanged else { return }
            lane.store(laneIndex, ordering: .relaxed)
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
    func debugSetWorkerConversionGate(_ gate: DebugNativeReadGate) {
        worker.async { [self] in debugNativeLaneActivityRecorder?.worker.conversionGate = gate }
    }
    #endif

    private final class Description: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack?
        let totalFrames: Int64
        let endTime: CMTime
        let nativeRate: Double
        let nativeChannels: UInt32
        let filePresentation: AudioFilePresentation?
        #if DEBUG
        var debugReadToken = 0
        var debugAdmissionAssetID = 0
        var debugAdmissionLastExcludedMask = -1
        var debugReadGate: DebugNativeReadGate?
        let debugNativeLaneActivityRecorder: DebugNativeLaneActivityRecorder?
        #endif
        #if DEBUG
        init(asset: AVURLAsset, track: AVAssetTrack?, totalFrames: Int64, endTime: CMTime, nativeRate: Double, nativeChannels: UInt32, filePresentation: AudioFilePresentation?,
             debugNativeLaneActivityRecorder: DebugNativeLaneActivityRecorder?) {
            self.debugNativeLaneActivityRecorder = debugNativeLaneActivityRecorder
            self.asset = asset; self.track = track; self.totalFrames = totalFrames
            self.endTime = endTime
            self.nativeRate = nativeRate; self.nativeChannels = nativeChannels
            self.filePresentation = filePresentation
        }
        #else
        init(asset: AVURLAsset, track: AVAssetTrack?, totalFrames: Int64, endTime: CMTime, nativeRate: Double, nativeChannels: UInt32, filePresentation: AudioFilePresentation?) {
            self.asset = asset; self.track = track; self.totalFrames = totalFrames
            self.endTime = endTime
            self.nativeRate = nativeRate; self.nativeChannels = nativeChannels
            self.filePresentation = filePresentation
        }
        #endif
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
        #if DEBUG
        var debugToken = 0
        var debugAdmissionAsset: AVURLAsset?
        var debugAdmissionAssetID = 0
        var debugAdmissionLeaseID = 0
        #endif

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
        private var reader: (any NativePCMReading)?
        private var buffer: AVAudioPCMBuffer?
        #if DEBUG
        private let index: Int
        private var debugActivity: DebugNativeLaneActivityRecorder.Record?
        #endif

        init(index: Int) {
            #if DEBUG
            self.index = index
            #endif
            queue = DispatchQueue(label: "OfflineTikTokPlayer.NativeRead.\(index)", qos: .userInitiated)
        }
        func start(_ description: Description, readStartFrame: Int64,
                   completion: @escaping @Sendable (Result<Int64, Failure>) -> Void) {
            queue.async { [self] in
                let result: Result<Int64, Failure> = autoreleasepool {
                    do {
                        guard reader == nil, buffer == nil else { throw Failure.slotInUse }
                        #if DEBUG
                        debugActivity = description.debugNativeLaneActivityRecorder?.record(at: index)
                        debugActivity?.publish(.construction)
                        #endif
                        let created: any NativePCMReading
                        if let layout = description.filePresentation,
                           let fileReader = NativeAudioFileReader.open(url: description.asset.url,
                               totalFrames: description.totalFrames, readStartFrame: readStartFrame,
                               matchesPacketTable: { priming, valid in
                                   layout.matches(primingFrames: priming, validFrames: valid,
                                       presentationFrames: description.totalFrames)
                               }) {
                            #if DEBUG
                            let activity = debugActivity, gate = description.debugReadGate
                            let token = description.debugReadToken, laneIndex = index
                            fileReader.beforeRead = {
                                activity?.recordExecutingThreadBeforeGate()
                                gate?.beforeCopy(token: token, laneIndex: laneIndex)
                                activity?.enterCopy()
                            }
                            fileReader.afterRead = {
                                activity?.publish(.copyReturned)
                                activity?.publish(.parser)
                            }
                            #endif
                            created = fileReader
                        } else {
                            #if DEBUG
                            created = try NativeReader(description: description, readStartFrame: readStartFrame, debugActivity: debugActivity)
                            #else
                            created = try NativeReader(description: description, readStartFrame: readStartFrame)
                            #endif
                        }
                        #if DEBUG
                        debugActivity?.publish(.constructionReturned)
                        #endif
                        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                            sampleRate: description.nativeRate, channels: description.nativeChannels,
                            interleaved: true),
                            let createdBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)
                            else { throw Failure.unsupportedPCM }
                        #if DEBUG
                        debugActivity?.publish(.buffersReady)
                        #endif
                        reader = created; buffer = createdBuffer
                        return .success(created.totalFrames)
                    } catch { return .failure((error as? Failure) ?? .cannotDecode) }
                }
                #if DEBUG
                debugActivity?.publish(.startResultReady)
                #endif
                completion(result)
                #if DEBUG
                debugActivity?.publish(.startCompletionReturned)
                #endif
            }
        }
        func read(maximumFrames: Int,
                  completion: @escaping @Sendable (Result<NativePacket, Failure>) -> Void) {
            let maximum = min(4_096, max(1, maximumFrames))
            queue.async { [self] in
                let result: Result<NativePacket, Failure> = autoreleasepool {
                    #if DEBUG
                    var debugEnteredNativeRead = false
                    #endif
                    do {
                        guard let reader, let buffer else { throw Failure.cannotDecode }
                        #if DEBUG
                        if let debugActivity {
                            debugActivity.publish(.nativeReadEntered)
                            debugEnteredNativeRead = true
                        }
                        #endif
                        let count = try reader.read(into: buffer, maximumFrames: maximum)
                        #if DEBUG
                        if debugEnteredNativeRead {
                            debugActivity?.publish(.nativeReadReturned)
                            debugEnteredNativeRead = false
                        }
                        #endif
                        let channels = Int(buffer.format.channelCount)
                        guard (0...maximum).contains(count), (1...8).contains(channels),
                              let samples = buffer.floatChannelData?[0],
                              count > 0 || reader.reachedEnd else { throw Failure.cannotDecode }
                        let owned = Array(UnsafeBufferPointer(start: samples, count: count * channels))
                        return .success(NativePacket(samples: owned, frames: count,
                            reachedEnd: reader.reachedEnd, totalFrames: reader.totalFrames))
                    } catch {
                        #if DEBUG
                        if debugEnteredNativeRead { debugActivity?.publish(.nativeReadReturned) }
                        #endif
                        return .failure((error as? Failure) ?? .cannotDecode)
                    }
                }
                completion(result)
            }
        }
        func close(completion: @escaping @Sendable () -> Void) {
            queue.async { [self] in
                #if DEBUG
                debugActivity?.publish(.close)
                #endif
                autoreleasepool {
                    buffer = nil
                    reader = nil // SDK reader release/cancellation runs only on this lane.
                }
                #if DEBUG
                debugActivity?.publish(.closeReturned)
                debugActivity = nil
                #endif
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
    private let debugNativeLaneActivityRecorder: DebugNativeLaneActivityRecorder?
    private let debugReaderAdmission: DebugReaderAdmissionRecorder?
    private let debugAcceptedPCMOrigin: DebugAcceptedPCMOriginRecorder?
    private var peakLeasedReaders = 0
    private var positiveInputRanDryBuffersRetained: UInt64 = 0
    private var positiveInputRanDryFramesRetained: UInt64 = 0
    private var nativePositiveInputRanDryBuffersRetained: UInt64 = 0
    private var nativePositiveInputRanDryFramesRetained: UInt64 = 0
    private var injectedPositiveInputRanDryBuffersRetained: UInt64 = 0
    private var injectedPositiveInputRanDryFramesRetained: UInt64 = 0
    private var positiveInputRanDryContractInjectionEnabled = false
    private var workerCounterOverflowed = false
    #endif

    /// Counts only the original eight-discard-buffer yields, never native pending.
    var cooperativeYieldCount: Int64 { yieldCount.load(ordering: .acquiring) }

    #if DEBUG
    init(renderer: ContinuousPCMRenderer, debugNativeLaneActivityRecorder: DebugNativeLaneActivityRecorder? = nil,
         debugAcceptedPCMOrigin: DebugAcceptedPCMOriginRecorder? = nil,
         debugReaderAdmission: DebugReaderAdmissionRecorder? = nil) {
        self.debugNativeLaneActivityRecorder = debugNativeLaneActivityRecorder
        self.debugReaderAdmission = debugReaderAdmission
        self.debugAcceptedPCMOrigin = debugAcceptedPCMOrigin
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
    #else
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
    #endif

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
        let selectedIsEnabled = selected != nil
        selected = selected ?? tracks.first
        var end = duration
        if let selected {
            let range = try await selected.load(.timeRange)
            if range.end.isNumeric, CMTimeCompare(range.end, end) > 0 { end = range.end }
        }
        let frames = try Self.frame(end)
        guard frames > 0 else { throw Failure.invalidTimeline }
        var nativeRate = 48_000.0, nativeChannels: UInt32 = 2
        var canUseAudioFile = false
        if let selected {
            let formats = try await selected.load(.formatDescriptions)
            guard let format = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  asbd.pointee.mSampleRate.isFinite, asbd.pointee.mSampleRate > 0,
                  (1...8).contains(asbd.pointee.mChannelsPerFrame) else { throw Failure.unsupportedPCM }
            nativeRate = asbd.pointee.mSampleRate; nativeChannels = asbd.pointee.mChannelsPerFrame
            canUseAudioFile = selectedIsEnabled && formats.count == 1 && nativeRate == 48_000 && nativeChannels == 2
                && asbd.pointee.mFormatID == kAudioFormatMPEG4AAC
        }
        // Only exact, single, unscaled native-grid AAC mappings can opt in.
        // The lane then checks these primitives against the actual codec packet table.
        func exactAudioFrame(_ time: CMTime) -> Int64? {
            guard time.isNumeric, CMTimeCompare(time, .zero) >= 0 else { return nil }
            let scaled = CMTimeConvertScale(time, timescale: 48_000, method: .roundHalfAwayFromZero)
            guard scaled.isNumeric, CMTimeCompare(time, scaled) == 0 else { return nil }
            return scaled.value
        }
        let filePresentation: AudioFilePresentation?
        if canUseAudioFile, tracks.count == 1, let selected,
           let segments = try? await selected.load(.segments), segments.count == 1,
           let segment = segments.first, !segment.isEmpty,
           CMTimeCompare(segment.timeMapping.source.duration, segment.timeMapping.target.duration) == 0,
           let sourceStart = exactAudioFrame(segment.timeMapping.source.start),
           let sourceFrames = exactAudioFrame(segment.timeMapping.source.duration),
           let targetStart = exactAudioFrame(segment.timeMapping.target.start),
           let targetFrames = exactAudioFrame(segment.timeMapping.target.duration) {
            filePresentation = AudioFilePresentation(sourceStart: sourceStart, sourceFrames: sourceFrames,
                targetStart: targetStart, targetFrames: targetFrames)
        } else { filePresentation = nil }
        #if DEBUG
        let description = Description(asset: asset, track: selected, totalFrames: frames, endTime: end,
            nativeRate: nativeRate, nativeChannels: nativeChannels, filePresentation: filePresentation,
            debugNativeLaneActivityRecorder: debugNativeLaneActivityRecorder)
        #else
        let description = Description(asset: asset, track: selected, totalFrames: frames, endTime: end,
            nativeRate: nativeRate, nativeChannels: nativeChannels, filePresentation: filePresentation)
        #endif
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
            #if DEBUG
            let activity = debugNativeLaneActivityRecorder?.worker
            activity?.publish(.shutdownEntered)
            defer { activity?.publish(.shutdownReturned) }
            #endif
            stopped = true
            timer?.setEventHandler {}; timer?.cancel(); timer = nil
            for index in preparations.indices { finishPreparation(at: index, failure: .cancelled) }
            for index in slots.indices { retireSlot(at: index) }
            for lease in leases.compactMap({ $0 }) { retire(lease) }
        }
    }

    #if DEBUG
    /// Worker-coherent metadata only. Call after measured output stops; no SDK
    /// query, scan or observer wait occurs here. Nil means not configured.
    func debugAcceptedPCMOriginSnapshot(_ completion: @escaping @Sendable (DebugAcceptedPCMOriginSnapshot?) -> Void) {
        worker.async { [self] in completion(debugAcceptedPCMOrigin?.snapshotOnWorker()) }
    }

    /// Default off; applies only to subsequently created Streams. Map one real,
    /// successful positive haveData result per Stream to the downstream inputRanDry
    /// contract. PCM, frame length, error and endOfStream are never substituted.
    func debugSetPositiveInputRanDryContractInjectionEnabled(_ enabled: Bool) {
        worker.async { [self] in positiveInputRanDryContractInjectionEnabled = enabled }
    }

    func debugWorkerStats(_ completion: @escaping @Sendable (DebugWorkerStats) -> Void) {
        worker.async { [self] in
            completion(debugWorkerStatsNow())
        }
    }

    // Worker owner only. The existing stats accessor retains its original fields.
    private func debugWorkerStatsNow() -> DebugWorkerStats {
            let present = leases.compactMap { $0 }
            let pending = present.filter { $0.readPending }.count
            let packets = present.filter { $0.packet != nil }.count
            return DebugWorkerStats(leasedReaders: present.count,
                peakLeasedReaders: peakLeasedReaders,
                retiredLeasesAwaitingClose: present.filter { $0.retired }.count,
                startingLeases: present.filter { $0.starting }.count,
                pendingPreparations: preparations.compactMap { $0 }.count,
                readJobsAwaitingAcceptanceOrClose: pending, mailboxPackets: packets,
                pendingOrMailboxPacketSlots: pending + packets,
                packetAllocationUpperBound: 2 * present.count,
                positiveInputRanDryBuffersRetained: positiveInputRanDryBuffersRetained,
                positiveInputRanDryFramesRetained: positiveInputRanDryFramesRetained,
                nativePositiveInputRanDryBuffersRetained: nativePositiveInputRanDryBuffersRetained,
                nativePositiveInputRanDryFramesRetained: nativePositiveInputRanDryFramesRetained,
                injectedPositiveInputRanDryBuffersRetained: injectedPositiveInputRanDryBuffersRetained,
                injectedPositiveInputRanDryFramesRetained: injectedPositiveInputRanDryFramesRetained,
                positiveInputRanDryContractInjectionEnabled: positiveInputRanDryContractInjectionEnabled,
                counterOverflowed: workerCounterOverflowed,
                shutdownRequested: stopped, readerLeasesClosed: present.isEmpty)
    }

    func debugFailureState(_ completion: @escaping @Sendable (DebugFailureState) -> Void) {
        worker.async { [self] in
            let activity = debugNativeLaneActivityRecorder?.worker
            activity?.publish(.requestEntered)
            defer { activity?.publish(.requestReturned) }
            let slotStates = (0..<3).map { index in
                let slot = slots[index]
                return DebugSlotState(index: index, token: slot?.token ?? 0, epoch: slot?.epoch ?? 0,
                    finished: slot?.finished ?? false,
                    cancelled: slot?.cancellation.value.load(ordering: .acquiring) ?? false,
                    leaseIndex: slot?.stream?.readerLease?.index ?? -1,
                    stream: slot?.stream?.debugProgress)
            }
            let leaseStates = (0..<3).map { index in
                let lease = leases[index]
                return DebugLeaseState(index: index, admissionAssetID: lease?.debugAdmissionAssetID ?? 0,
                    admissionLeaseID: lease?.debugAdmissionLeaseID ?? 0, present: lease != nil,
                    starting: lease?.starting ?? false, readPending: lease?.readPending ?? false,
                    retired: lease?.retired ?? false, requestedFrames: lease?.requestedFrames ?? 0,
                    packetFrames: lease?.packet?.frames ?? 0, packetOffset: lease?.packetOffset ?? 0,
                    reachedEnd: lease?.reachedEnd ?? false, hasFailure: lease?.failure != nil)
            }
            completion(DebugFailureState(stats: debugWorkerStatsNow(),
                preparationTokens: preparations.map { $0?.token ?? 0 },
                slots: slotStates, leases: leaseStates, admission: debugReaderAdmission?.snapshot()))
        }
    }

    private func notePositiveInputRanDry(frames: Int, injected: Bool) {
        let buffers = positiveInputRanDryBuffersRetained.addingReportingOverflow(1)
        let samples = positiveInputRanDryFramesRetained.addingReportingOverflow(UInt64(frames))
        positiveInputRanDryBuffersRetained = buffers.overflow ? .max : buffers.partialValue
        positiveInputRanDryFramesRetained = samples.overflow ? .max : samples.partialValue
        let originalBuffers = injected ? injectedPositiveInputRanDryBuffersRetained : nativePositiveInputRanDryBuffersRetained
        let originalFrames = injected ? injectedPositiveInputRanDryFramesRetained : nativePositiveInputRanDryFramesRetained
        let classifiedBuffers = originalBuffers.addingReportingOverflow(1)
        let classifiedFrames = originalFrames.addingReportingOverflow(UInt64(frames))
        if injected {
            injectedPositiveInputRanDryBuffersRetained = classifiedBuffers.overflow ? .max : classifiedBuffers.partialValue
            injectedPositiveInputRanDryFramesRetained = classifiedFrames.overflow ? .max : classifiedFrames.partialValue
        } else {
            nativePositiveInputRanDryBuffersRetained = classifiedBuffers.overflow ? .max : classifiedBuffers.partialValue
            nativePositiveInputRanDryFramesRetained = classifiedFrames.overflow ? .max : classifiedFrames.partialValue
        }
        workerCounterOverflowed = workerCounterOverflowed || buffers.overflow || samples.overflow
            || classifiedBuffers.overflow || classifiedFrames.overflow
    }

    /// Queued acknowledgement includes native lane cancellation/release, not just
    /// stopped=true. A permanently blocked call therefore never reports success.
    func debugAfterShutdown(_ completion: @escaping @Sendable (Bool) -> Void) {
        worker.async { [self] in
            guard stopped else { completion(false); return }
            readerClosures.notify(queue: worker) { [self] in
                let activity = debugNativeLaneActivityRecorder?.worker
                activity?.publish(.acknowledgementEntered)
                defer { activity?.publish(.acknowledgementReturned) }
                completion(stopped && leases.allSatisfy { $0 == nil }
                    && preparations.allSatisfy { $0 == nil } && slots.allSatisfy { $0 == nil })
            }
        }
    }
    func debugAfterShutdownWithAdmission(_ completion: @escaping @Sendable (Bool, DebugReaderAdmissionState?) -> Void) {
        debugAfterShutdown { [self] closed in completion(closed, debugReaderAdmission?.snapshot()) }
    }
    #endif

    private func acquireReader(_ description: Description, readStartFrame: Int64) throws -> ReaderLease {
        #if DEBUG
        var matchingMask = 0, retiredMask = 0, freeMask = 0
        if let recorder = debugReaderAdmission {
            if description.debugAdmissionAssetID == 0 { description.debugAdmissionAssetID = recorder.asset() }
            for index in 0..<3 where leases[index] == nil { freeMask |= 1 << index }
            for lease in leases.compactMap({ $0 }) where lease.debugAdmissionAsset === description.asset {
                matchingMask |= 1 << lease.index
                if lease.retired { retiredMask |= 1 << lease.index }
            }
            if recorder.excludesSameAsset && matchingMask != 0 {
                let signature = matchingMask | (retiredMask << 3) | (freeMask << 6)
                if description.debugAdmissionLastExcludedMask != signature {
                    recorder.note(kind: 2, asset: description.debugAdmissionAssetID, lease: 0, lane: -1,
                        token: description.debugReadToken, matchingMask: matchingMask, retiredMask: retiredMask, freeMask: freeMask)
                    description.debugAdmissionLastExcludedMask = signature
                }
                throw ReadControl.pending
            }
        }
        #endif
        guard let index = leases.firstIndex(where: { $0 == nil }) else { throw ReadControl.pending }
        let total = try Self.frame(description.endTime, rate: description.nativeRate)
        let lease = ReaderLease(index: index, lane: lanes[index], totalFrames: total) { [weak self] lease in
            self?.requestRead(lease)
        }
        leases[index] = lease
        #if DEBUG
        lease.debugToken = description.debugReadToken
        if let recorder = debugReaderAdmission {
            lease.debugAdmissionAsset = description.asset
            lease.debugAdmissionAssetID = description.debugAdmissionAssetID
            lease.debugAdmissionLeaseID = recorder.lease()
            description.debugAdmissionLastExcludedMask = -1
            recorder.note(kind: 1, asset: lease.debugAdmissionAssetID, lease: lease.debugAdmissionLeaseID,
                lane: index, token: lease.debugToken, matchingMask: matchingMask, retiredMask: retiredMask, freeMask: freeMask)
        }
        peakLeasedReaders = max(peakLeasedReaders, leases.compactMap { $0 }.count)
        #endif
        readerClosures.enter()
        lease.lane.start(description, readStartFrame: readStartFrame) { [weak self, weak lease] result in
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
        #if DEBUG
        debugNativeLaneActivityRecorder?.worker.publish(.readEnqueued, token: lease.debugToken)
        #endif
        lease.lane.read(maximumFrames: requested) { [weak self, weak lease] result in
            guard let self, let lease else { return }
            self.worker.async { [weak self, weak lease] in
                guard let self, let lease, self.leases[lease.index] === lease, !lease.retired else { return }
                #if DEBUG
                let activity = self.debugNativeLaneActivityRecorder?.worker
                activity?.publish(.packetAcceptanceEntered, token: lease.debugToken)
                defer { activity?.publish(.packetAcceptanceReturned, token: lease.debugToken) }
                #endif
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
                #if DEBUG
                let activity = debugNativeLaneActivityRecorder?.worker
                activity?.publish(.closeAcceptanceEntered, token: lease.debugToken)
                defer { activity?.publish(.closeAcceptanceReturned, token: lease.debugToken) }
                if leases[lease.index] === lease {
                    debugReaderAdmission?.note(kind: 3, asset: lease.debugAdmissionAssetID,
                        lease: lease.debugAdmissionLeaseID, lane: lease.index, token: lease.debugToken)
                }
                #endif
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
        #if DEBUG
        debugAcceptedPCMOrigin?.close(token: slot.token)
        #endif
        slots[index] = nil
        retireStream(slot.stream)
        #if DEBUG
        debugNativeLaneActivityRecorder?.worker.publish(.streamReleaseEntered, token: slot.token)
        #endif
        slot.stream = nil
        #if DEBUG
        debugNativeLaneActivityRecorder?.worker.publish(.streamReleaseReturned, token: slot.token)
        #endif
    }

    private func makeStream(description: Description, startFrame: Int64,
                            shouldCancel: @escaping () -> Bool) throws -> Stream {
        let readStartFrame = PCMReadRange.startFrame(requestedFrame: startFrame,
            nativeSampleRate: description.nativeRate)
        let lease: ReaderLease?
        if description.track == nil { lease = nil }
        else { lease = try acquireReader(description, readStartFrame: readStartFrame) }
        do {
            let stream = try Stream(description: description, startFrame: startFrame,
                                    readStartFrame: readStartFrame, native: lease, shouldCancel: shouldCancel)
            #if DEBUG
            stream.injectNextPositiveHaveDataAsInputRanDry = positiveInputRanDryContractInjectionEnabled
            stream.onPositiveInputRanDry = { [weak self] frames, injected in
                self?.notePositiveInputRanDry(frames: frames, injected: injected)
            }
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
        #if DEBUG
        let activity = debugNativeLaneActivityRecorder?.worker
        activity?.publish(.pumpEntered)
        defer { activity?.publish(.pumpReturned) }
        #endif
        guard !stopped else { return }
        let more: Bool = autoreleasepool {
            #if DEBUG
            activity?.publish(.rendererSnapshotEntered)
            #endif
            let active = renderer.snapshot.token
            #if DEBUG
            activity?.publish(.rendererSnapshotReturned, token: active)
            #endif
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
        #if DEBUG
        let activity = debugNativeLaneActivityRecorder?.worker
        activity?.publish(.fillEntered, token: slot.token)
        defer { activity?.publish(.fillReturned, token: slot.token) }
        #endif
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
            #if DEBUG
            if let origin = debugAcceptedPCMOrigin {
                pending.prefix.withUnsafeBufferPointer {
                    origin.recordPrefix(token: pending.token, slot: pending.index,
                        interleaved: UnsafeBufferPointer(rebasing: $0[..<(pending.prefixCount * 2)]))
                }
            }
            #endif
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
            #if DEBUG
            if let origin = debugAcceptedPCMOrigin, accepted > 0 {
                let start = stream.debugProgress.cursor - Int64(count)
                scratch.withUnsafeBufferPointer {
                    origin.recordRing(token: slot.token, slot: pending.index, epoch: slot.epoch,
                        startFrame: start, interleaved: UnsafeBufferPointer(rebasing: $0[..<(accepted * 2)]))
                }
            }
            #endif
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
            #if DEBUG
            debugNativeLaneActivityRecorder?.worker.publish(.streamReleaseEntered, token: slot.token)
            #endif
            slot.stream = nil
            #if DEBUG
            debugNativeLaneActivityRecorder?.worker.publish(.streamReleaseReturned, token: slot.token)
            #endif
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
            #if DEBUG
            if let origin = debugAcceptedPCMOrigin, accepted > 0 {
                let start = stream.debugProgress.cursor - Int64(count)
                let index = slots.firstIndex(where: { $0 === slot }) ?? -1
                scratch.withUnsafeBufferPointer {
                    origin.recordRing(token: slot.token, slot: index, epoch: slot.epoch,
                        startFrame: start, interleaved: UnsafeBufferPointer(rebasing: $0[..<(accepted * 2)]))
                }
            }
            #endif
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
        private let debugWorkerActivity: DebugNativeLaneActivityRecorder.WorkerRecord?
        private let debugToken: Int
        var injectNextPositiveHaveDataAsInputRanDry = false
        var onPositiveInputRanDry: ((Int, Bool) -> Void)?
        var debugProgress: DebugStreamState {
            DebugStreamState(cursor: cursor, generatedFrames: generatedFrames,
                outputStart: outputStart, outputCount: outputCount,
                converterFinished: converterFinished, reachedEnd: eof)
        }
        #endif

        var readerLease: ReaderLease? { native }
        var reachedEnd: Bool { eof }

        init(description: Description, startFrame: Int64, readStartFrame: Int64, native: ReaderLease?,
             shouldCancel: @escaping () -> Bool) throws {
            totalFrames = description.totalFrames; cursor = max(0, startFrame)
            generatedFrames = readStartFrame; outputStart = readStartFrame
            nativeRate = description.nativeRate
            self.shouldCancel = shouldCancel
            analysisValid = startFrame == 0
            #if DEBUG
            let activity = description.debugNativeLaneActivityRecorder?.worker
            self.debugWorkerActivity = activity; self.debugToken = description.debugReadToken
            activity?.publish(.streamConstructionEntered, token: description.debugReadToken)
            defer { activity?.publish(.streamConstructionReturned, token: description.debugReadToken) }
            #endif
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
            // SRC sources reopen from zero to preserve their original phase and
            // filter history. A distant native-48k seek instead discards only its
            // two-second decode preroll, retaining the exact requested output
            // coordinates and complete endpoint. Ordinary loop/reversal heads
            // keep their original zero-based path.
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
                #if DEBUG
                debugWorkerActivity?.beforeConversion(token: debugToken)
                #endif
                let nativeStatus = converter.convert(to: output, error: &conversionError) { requested, status in
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
                #if DEBUG
                debugWorkerActivity?.publish(.converterReturned, token: debugToken)
                #endif
                supportFramesSupplied = suppliedSupport
                if let inputFailure { throw inputFailure }
                guard nativeStatus != .error, conversionError == nil else { throw Failure.cannotDecode }
                #if DEBUG
                let injected = injectNextPositiveHaveDataAsInputRanDry
                    && nativeStatus == .haveData && output.frameLength > 0
                if injected { injectNextPositiveHaveDataAsInputRanDry = false }
                let status: AVAudioConverterOutputStatus = injected ? .inputRanDry : nativeStatus
                #else
                let status = nativeStatus
                #endif
                if status == .endOfStream { converterFinished = true }
                outputStart = generatedFrames; outputCount = Int(output.frameLength)
                generatedFrames += Int64(outputCount)
                #if DEBUG
                if status == .inputRanDry, outputCount > 0 { onPositiveInputRanDry?(outputCount, injected) }
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
    private final class NativeReader: NativePCMReading {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        #if DEBUG
        private let debugReadToken: Int
        private let debugReadGate: DebugNativeReadGate?
        private let debugActivity: DebugNativeLaneActivityRecorder.Record?
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

        #if DEBUG
        init(description: Description, readStartFrame: Int64, debugActivity: DebugNativeLaneActivityRecorder.Record?) throws {
            guard let track = description.track else { throw Failure.cannotDecode }
            #if DEBUG
            self.debugActivity = debugActivity
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
            // Configure before reading. Retain the complete declared endpoint;
            // only a distant native-48k seek may begin at its decode preroll.
            // No content boundary, ordinary loop or resampled history is trimmed.
            guard readStartFrame >= 0, readStartFrame == 0 || rate == 48_000 else { throw Failure.invalidTimeline }
            cursor = readStartFrame
            let readStart = CMTime(value: readStartFrame, timescale: 48_000)
            reader.timeRange = CMTimeRange(start: readStart,
                duration: CMTimeSubtract(description.endTime, readStart))
            debugActivity?.publish(.startReading)
            let started = reader.startReading()
            debugActivity?.publish(.startReadingReturned)
            guard started else { throw Failure.cannotDecode }
        }
        #else
        init(description: Description, readStartFrame: Int64) throws {
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
            // Configure before reading. Retain the complete declared endpoint;
            // only a distant native-48k seek may begin at its decode preroll.
            // No content boundary, ordinary loop or resampled history is trimmed.
            guard readStartFrame >= 0, readStartFrame == 0 || rate == 48_000 else { throw Failure.invalidTimeline }
            cursor = readStartFrame
            let readStart = CMTime(value: readStartFrame, timescale: 48_000)
            reader.timeRange = CMTimeRange(start: readStart,
                duration: CMTimeSubtract(description.endTime, readStart))
            guard reader.startReading() else { throw Failure.cannotDecode }
        }
        #endif

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
            debugActivity?.recordExecutingThreadBeforeGate()
            debugReadGate?.beforeCopy(token: debugReadToken, laneIndex: debugActivity?.laneIndex ?? -1)
            debugActivity?.enterCopy()
            #endif
            guard let buffer = output.copyNextSampleBuffer() else {
                #if DEBUG
                debugActivity?.publish(.copyReturned)
                debugActivity?.publish(.parser)
                #endif
                guard reader.status == .completed else { throw Failure.cannotDecode }
                eof = true; return
            }
            #if DEBUG
            debugActivity?.publish(.copyReturned)
            debugActivity?.publish(.parser)
            #endif
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
