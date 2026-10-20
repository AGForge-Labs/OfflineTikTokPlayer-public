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

    private final class Description: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack?
        let totalFrames: Int64
        init(asset: AVURLAsset, track: AVAssetTrack?, totalFrames: Int64) {
            self.asset = asset; self.track = track; self.totalFrames = totalFrames
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
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
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
        let description = Description(asset: asset, track: selected, totalFrames: frames)
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
                            let stream = try Stream(description: description, startFrame: 0)
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
            let stream = try Stream(description: slot.description, startFrame: request.startFrame)
            guard slot.source.beginStream(epoch: request.epoch) else { return }
            slot.stream = stream; slot.epoch = request.epoch; slot.finished = false
        }
        guard !slot.finished else { return }
        for _ in 0..<chunks {
            guard slot.source.token == slot.token, slot.source.streamRequest.epoch == slot.epoch else { return }
            let capacity = min(8_192, slot.source.writableStreamFrames)
            guard capacity > 0 else { return }
            let count = try scratch.withUnsafeMutableBufferPointer {
                try slot.stream.read(into: $0, maximumFrames: capacity)
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

    private static func frame(_ time: CMTime) throws -> Int64 {
        guard time.isNumeric, time.seconds.isFinite, abs(time.seconds) < 86_400 else { throw Failure.invalidTimeline }
        return CMTimeConvertScale(time, timescale: 48_000, method: .roundHalfAwayFromZero).value
    }

    /// Bounded sequential decoding on the complete presentation timeline.
    /// AVAssetReader applies container edits and the codec's declared trimming.
    /// Remaining trim attachments are applied from timestamps, never amplitude.
    private final class Stream {
        private let reader: AVAssetReader?
        private let output: AVAssetReaderAudioMixOutput?
        private var samples: [Float] = []
        private var sampleOffset = 0
        private var sampleCount = 0
        private var sampleStart: Int64 = 0
        private var cursor: Int64
        private var eof = false
        private(set) var totalFrames: Int64
        private var analysisValid: Bool
        private var analysisReported = false
        private var firstAboveThreshold: Int64?
        private var lastAboveThreshold: Int64?
        private var peak: Float = 0

        init(description: Description, startFrame: Int64) throws {
            totalFrames = description.totalFrames; cursor = max(0, startFrame)
            analysisValid = startFrame == 0
            guard let track = description.track else { reader = nil; output = nil; eof = true; return }
            let reader = try AVAssetReader(asset: description.asset)
            let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure.cannotDecode }
            reader.add(output)
            if startFrame > 0 {
                let start = CMTime(value: startFrame, timescale: 48_000)
                reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
            }
            guard reader.startReading() else { throw Failure.cannotDecode }
            self.reader = reader; self.output = output
        }

        deinit { reader?.cancelReading() }

        func read(into destination: UnsafeMutableBufferPointer<Float>, maximumFrames: Int) throws -> Int {
            let maximum = min(maximumFrames, destination.count / 2)
            let firstFrame = cursor
            var written = 0
            while written < maximum {
                if sampleCount == 0, !eof { try nextSample() }
                if sampleCount == 0, eof {
                    let count = min(maximum - written, Int(max(0, totalFrames - cursor)))
                    guard count > 0 else { break }
                    destination.baseAddress!.advanced(by: written * 2).initialize(repeating: 0, count: count * 2)
                    cursor += Int64(count); written += count; continue
                }
                let end = sampleStart + Int64(sampleCount)
                if end <= cursor { sampleCount = 0; continue }
                if sampleStart > cursor {
                    let count = min(maximum - written, Int(sampleStart - cursor))
                    destination.baseAddress!.advanced(by: written * 2).initialize(repeating: 0, count: count * 2)
                    cursor += Int64(count); written += count; continue
                }
                let offset = Int(cursor - sampleStart)
                let count = min(maximum - written, sampleCount - offset)
                samples.withUnsafeBufferPointer {
                    destination.baseAddress!.advanced(by: written * 2).update(from: $0.baseAddress!.advanced(by: (sampleOffset + offset) * 2), count: count * 2)
                }
                cursor += Int64(count); written += count
                if cursor >= end { sampleCount = 0 }
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
            guard analysisValid, !analysisReported, eof, sampleCount == 0, cursor >= totalFrames else { return nil }
            analysisReported = true
            return SourceSilence(totalFrames: totalFrames,
                leadingFrames: firstAboveThreshold ?? totalFrames,
                trailingFrames: lastAboveThreshold.map { totalFrames - $0 - 1 } ?? totalFrames,
                peak: peak)
        }

        private func nextSample() throws {
            guard let output, let reader else { eof = true; return }
            guard let buffer = output.copyNextSampleBuffer() else {
                guard reader.status == .completed else { throw Failure.cannotDecode }
                eof = true; return
            }
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  asbd.pointee.mFormatID == kAudioFormatLinearPCM,
                  asbd.pointee.mSampleRate == 48_000,
                  asbd.pointee.mChannelsPerFrame == 2,
                  asbd.pointee.mBytesPerFrame == 8,
                  asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  let block = CMSampleBufferGetDataBuffer(buffer) else { throw Failure.unsupportedPCM }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes > 0, bytes % 8 == 0 else { throw Failure.unsupportedPCM }
            let frames = bytes / 8
            // Reject an unexpectedly huge demux packet rather than allowing one
            // source to defeat the fixed prefix/ring memory budget.
            guard frames <= 131_072 else { throw Failure.oversizedPacket }
            let outputPTS = CMSampleBufferGetOutputPresentationTimeStamp(buffer)
            let outputDuration = CMSampleBufferGetOutputDuration(buffer)
            let start = try ContinuousPCMDecoder.frame(outputPTS)
            // Output PTS may also contain a track edit/offset. Only the explicit
            // trim attachment identifies samples to omit from the PCM buffer;
            // subtracting raw PTS would mistake a legitimate edit for priming.
            let trim: Int64
            if let dictionary = CMGetAttachment(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                attachmentModeOut: nil) as? [String: Any] {
                trim = max(0, try ContinuousPCMDecoder.frame(CMTimeMakeFromDictionary(dictionary as CFDictionary)))
            } else { trim = 0 }
            let valid = outputDuration.isNumeric ? try ContinuousPCMDecoder.frame(outputDuration) : Int64(frames) - trim
            guard trim <= Int64(frames), valid >= 0, trim + valid <= Int64(frames) + 1 else { throw Failure.invalidTimeline }
            let validFrames = min(Int64(frames) - trim, valid)
            samples = [Float](repeating: 0, count: frames * 2)
            let result = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
            }
            guard result == kCMBlockBufferNoErr else { throw Failure.cannotDecode }
            sampleStart = start; sampleOffset = Int(trim); sampleCount = Int(validFrames)
            totalFrames = max(totalFrames, sampleStart + validFrames)
        }
    }
}
