import Foundation
import AVFoundation
import AudioToolbox
import Synchronization
import PlayerCore

/// The only producer for the three fixed PCM sources. All AVAssetReader and
/// buffer work runs on one serial worker; the audio callback never calls here.
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

    private enum ReadControl: Error { case deferred }

    #if DEBUG
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

    private final class Slot {
        let token: Int
        let source: ContinuousPCMSource
        let description: Description
        let cancellation: Cancellation
        var stream: Stream
        var epoch: Int = 1
        var finished = false
        init(token: Int, source: ContinuousPCMSource, description: Description, cancellation: Cancellation, stream: Stream) {
            self.token = token; self.source = source; self.description = description
            self.cancellation = cancellation; self.stream = stream
        }
    }

    private let renderer: ContinuousPCMRenderer
    private let worker = DispatchQueue(label: "OfflineTikTokPlayer.PCMDecode", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var slots: [Slot?] = [nil, nil, nil]
    private var scratch = [Float](repeating: 0, count: 8_192 * 2)
    private var stopped = false
    private var failureHandler: (@Sendable (Int, Failure) -> Void)?
    private var sourceSilenceHandler: (@Sendable (Int, SourceSilence) -> Void)?
    private let yieldCount = Atomic<Int64>(0)

    /// Numeric cooperative scheduling evidence; never includes source identity.
    var cooperativeYieldCount: Int64 { yieldCount.load(ordering: .acquiring) }

    init(renderer: ContinuousPCMRenderer) {
        self.renderer = renderer
        let timer = DispatchSource.makeTimerSource(queue: worker)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
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
        let hasAudio = selected != nil
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                worker.async { [self] in
                    autoreleasepool {
                        do {
                            guard !stopped, !cancellation.value.load(ordering: .acquiring) else { throw Failure.cancelled }
                            let source = renderer.source(at: index)
                            #if DEBUG
                            description.debugReadToken = token
                            description.debugReadGate = debugNativeReadGate
                            #endif
                            let stream = try Stream(description: description, startFrame: 0,
                                shouldCancel: { cancellation.value.load(ordering: .acquiring) })
                            var prefix = [Float](repeating: 0, count: source.prefixCapacityFrames * 2)
                            let count = try prefix.withUnsafeMutableBufferPointer {
                                try stream.read(into: $0, maximumFrames: source.prefixCapacityFrames)
                            }
                            guard !cancellation.value.load(ordering: .acquiring) else { throw Failure.cancelled }
                            let published = prefix.withUnsafeBufferPointer {
                                source.prepare(token: token, totalFrames: stream.totalFrames,
                                    prefix: UnsafeBufferPointer(rebasing: $0[..<(count * 2)]))
                            }
                            guard published else { throw Failure.slotInUse }
                            let state = Slot(token: token, source: source, description: description, cancellation: cancellation, stream: stream)
                            slots[index] = state
                            guard source.beginStream(epoch: source.streamRequest.epoch) else { throw Failure.cancelled }
                            state.epoch = source.streamRequest.epoch
                            try fill(state, chunks: 8)
                            continuation.resume(returning: Prepared(token: token, totalFrames: stream.totalFrames, hasAudio: hasAudio))
                        } catch {
                            continuation.resume(throwing: (error as? Failure) ?? Failure.cannotDecode)
                        }
                    }
                }
            }
        } onCancel: {
            cancellation.value.store(true, ordering: .releasing)
            self.worker.async { [self] in
                for index in slots.indices where slots[index]?.token == token { slots[index] = nil }
            }
        }
    }

    /// Drop readers that are no longer in the bounded current/adjacent window.
    /// Storage retirement itself remains the renderer/source owner's decision.
    func retain(tokens: Set<Int>) {
        worker.async { [self] in
            for index in slots.indices {
                if let slot = slots[index], !tokens.contains(slot.token) { slots[index] = nil }
            }
        }
    }

    /// The callback runs on the decode worker. Only an ephemeral numeric token
    /// and a fixed reason code cross this boundary; native NSError text may
    /// contain a private filename/URL and must not enter diagnostics.
    func setFailureHandler(_ handler: @escaping @Sendable (Int, Failure) -> Void) {
        worker.async { [self] in failureHandler = handler }
    }

    /// Runs once on the serial worker after a complete start-to-EOF decode. A
    /// cancelled/partial decode or a seek/reopen produces no guessed measurement.
    func setSourceSilenceHandler(_ handler: @escaping @Sendable (Int, SourceSilence) -> Void) {
        worker.async { [self] in sourceSilenceHandler = handler }
    }

    func shutdown() {
        worker.async { [self] in
            stopped = true
            timer?.setEventHandler {}; timer?.cancel(); timer = nil
            slots = [nil, nil, nil]
        }
    }

    #if DEBUG
    /// Observe queued shutdown completion without deleting a fixture under an
    /// outstanding native read. This does not prove SDK-internal quiescence.
    func debugAfterShutdown(_ completion: @escaping @Sendable (Bool) -> Void) {
        worker.async { [self] in completion(stopped) }
    }
    #endif

    private func pump() {
        guard !stopped else { return }
        autoreleasepool {
            let active = renderer.snapshot.token
            // Current replenishment takes precedence over speculative neighbours.
            for isCurrent in [true, false] {
                for index in slots.indices {
                    guard let slot = slots[index], (slot.token == active) == isCurrent else { continue }
                    if slot.cancellation.value.load(ordering: .acquiring) || slot.source.token != slot.token {
                        slots[index] = nil; continue
                    }
                    do { try fill(slot, chunks: isCurrent ? 8 : 2) }
                    catch {
                        if (error as? Failure) == .cancelled {
                            if slot.source.token != slot.token || slot.cancellation.value.load(ordering: .acquiring) {
                                slots[index] = nil
                            }
                            // Retirement/task cancellation is normal cleanup.
                            // An epoch change retains this slot for the next pump.
                            continue
                        }
                        // A failed reader must not publish fabricated success/EOF.
                        // Its source will report an underrun if it is selected.
                        slots[index] = nil
                        failureHandler?(slot.token, (error as? Failure) ?? .cannotDecode)
                    }
                }
            }
        }
    }

    private func fill(_ slot: Slot, chunks: Int) throws {
        let request = slot.source.streamRequest
        if request.epoch != slot.epoch {
            if request.startFrame >= slot.source.totalFrames {
                // A fully pinned short source loops entirely from its prefix.
                // No decoder is needed beyond EOF, and reopening there must not
                // turn a successful loop into a reader failure or new analysis.
                guard slot.source.beginStream(epoch: request.epoch) else { return }
                slot.epoch = request.epoch; slot.finished = true
                slot.source.finishStream(totalFrames: slot.source.totalFrames, epoch: slot.epoch)
                return
            }
            let source = slot.source, token = slot.token, cancellation = slot.cancellation
            let stream = try Stream(description: slot.description, startFrame: request.startFrame,
                shouldCancel: {
                    cancellation.value.load(ordering: .acquiring) || source.token != token || source.streamRequest.epoch != request.epoch
                })
            guard slot.source.beginStream(epoch: request.epoch) else { return }
            slot.stream = stream; slot.epoch = request.epoch; slot.finished = false
        }
        guard !slot.finished else { return }
        for _ in 0..<chunks {
            guard slot.source.token == slot.token, slot.source.streamRequest.epoch == slot.epoch else { return }
            let capacity = min(8_192, slot.source.writableStreamFrames)
            guard capacity > 0 else { return }
            let count: Int
            do {
                count = try scratch.withUnsafeMutableBufferPointer {
                    try slot.stream.read(into: $0, maximumFrames: capacity)
                }
            } catch ReadControl.deferred {
                yieldCount.store(yieldCount.load(ordering: .relaxed) &+ 1, ordering: .releasing)
                // Stream keeps its converter and generated-frame cursor. Returning
                // to the pump lets the current source refill before the next
                // bounded discard step of a retained, far-away seek.
                return
            }
            if let analysis = slot.stream.takeSourceSilence() {
                sourceSilenceHandler?(slot.token, analysis)
            }
            if count == 0 {
                slot.source.finishStream(totalFrames: slot.stream.totalFrames, epoch: slot.epoch)
                slot.finished = true; return
            }
            let accepted = scratch.withUnsafeBufferPointer {
                slot.source.append(interleaved: UnsafeBufferPointer(rebasing: $0[..<(count * 2)]), epoch: slot.epoch)
            }
            // Only a new render epoch can invalidate an append after a read. The
            // next pump reopens at that request; stale PCM is never carried over.
            guard accepted == count else { return }
        }
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
        private let native: NativeReader?
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
        private var cursor: Int64
        private var eof = false
        private(set) var totalFrames: Int64
        private var analysisValid: Bool
        private var analysisReported = false
        private var firstAboveThreshold: Int64?
        private var lastAboveThreshold: Int64?
        private var peak: Float = 0

        init(description: Description, startFrame: Int64, shouldCancel: @escaping () -> Bool) throws {
            totalFrames = description.totalFrames; cursor = max(0, startFrame)
            nativeRate = description.nativeRate
            self.shouldCancel = shouldCancel
            analysisValid = startFrame == 0
            guard description.track != nil else {
                native = nil; converter = nil; input = nil; output = nil; return
            }
            let native = try NativeReader(description: description)
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
            var skippedBuffers = 0
            while written < maximum {
                if shouldCancel() { throw Failure.cancelled }
                if native == nil {
                    let count = min(maximum - written, Int(max(0, totalFrames - cursor)))
                    guard count > 0 else { eof = true; break }
                    destination.baseAddress!.advanced(by: written * 2).update(repeating: 0, count: count * 2)
                    cursor += Int64(count); written += count; continue
                }
                if outputCount == 0, !eof { try convertNext() }
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
                var conversionError: NSError?
                let sourceTarget = totalFrames, rate = nativeRate
                var suppliedSupport = supportFramesSupplied
                let status = converter.convert(to: output, error: &conversionError) { requested, status in
                    do {
                        guard requested > 0 else { status.pointee = .noDataNow; return nil }
                        let count = try native.read(into: input, maximumFrames: min(Int(requested), Int(input.frameCapacity)))
                        if count == 0 {
                            guard native.reachedEnd else { throw Failure.cannotDecode }
                            // A fractional target frame may require the next native
                            // sample for interpolation. Supply only the mathematically
                            // required zero support outside the original timeline;
                            // never append fabricated output PCM or change its end.
                            let target = sourceTarget
                            // Integral rates and the <24-hour source limit make
                            // this integer ceiling safe without floating ambiguity.
                            let requiredNative = (target * Int64(rate) + 47_999) / 48_000
                            let support = max(0, requiredNative - native.totalFrames)
                            let maximumSupport = Int64(ceil(rate / 96_000 + 0.5))
                            guard support <= maximumSupport else { throw Failure.invalidTimeline }
                            let needed = support - suppliedSupport
                            if needed > 0 {
                                let frames = min(Int(needed), Int(requested), Int(input.frameCapacity))
                                guard frames > 0, let samples = input.floatChannelData?[0] else { throw Failure.cannotDecode }
                                samples.update(repeating: 0, count: frames * Int(input.format.channelCount))
                                input.frameLength = AVAudioFrameCount(frames)
                                suppliedSupport += Int64(frames)
                                status.pointee = .haveData; return input
                            }
                            status.pointee = .endOfStream; return nil
                        }
                        status.pointee = .haveData; return input
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
                if outputCount > 0 { return }
                if converterFinished { eof = true; return }
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
