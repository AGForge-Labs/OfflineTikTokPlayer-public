import AVFoundation
import PlayerCore
import Synchronization
#if DEBUG
import Darwin
#endif

/// The graph survives item, loop and presentation changes. Only the kernel's
/// cursor changes at a prepared boundary. No AVPlayerItem carries audible audio.
final class ContinuousAudioGraph {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let source: AVAudioSourceNode
    private let anchor: RenderAnchor
    private let storage: RenderStorage
    @MainActor private var intervalIssuer: UInt64 = 0
    var maximumRenderFrameCount: Int { storage.maximumFrameCount.load(ordering: .acquiring) }

    private final class RenderAnchor: @unchecked Sendable {
        let sequence = Atomic<Int>(0)
        let token = Atomic<Int>(0)
        let visit = Atomic<Int64>(0)
        let selectionVersion = Atomic<Int>(0)
        let frame = Atomic<Int64>(0)
        let hostSeconds = Atomic<UInt64>(0)
        let activeInterval = Atomic<UInt64>(0) // Control writer; zero withdraws extrapolation permission.
        let publishedInterval = Atomic<UInt64>(0) // Render writer, inside the existing coherent publication.
        var version = 0 // Render owner only.
        func publish(_ sample: ContinuousPCMRenderer.Snapshot, hostEnd: Double, interval: UInt64) {
            version &+= 2
            sequence.store(version - 1, ordering: .sequentiallyConsistent)
            token.store(sample.token, ordering: .sequentiallyConsistent)
            visit.store(sample.visit, ordering: .sequentiallyConsistent)
            selectionVersion.store(sample.selectionVersion, ordering: .sequentiallyConsistent)
            frame.store(sample.frame, ordering: .sequentiallyConsistent)
            hostSeconds.store(hostEnd.bitPattern, ordering: .sequentiallyConsistent)
            publishedInterval.store(interval, ordering: .sequentiallyConsistent)
            sequence.store(version, ordering: .sequentiallyConsistent)
        }
        func read() -> (token: Int, visit: Int64, selectionVersion: Int, frame: Int64, hostEnd: Double, interval: UInt64)? {
            while true {
                let version = sequence.load(ordering: .sequentiallyConsistent)
                if version == 0 { return nil }
                if version & 1 != 0 { continue }
                let result = (token.load(ordering: .sequentiallyConsistent), visit.load(ordering: .sequentiallyConsistent),
                              selectionVersion.load(ordering: .sequentiallyConsistent), frame.load(ordering: .sequentiallyConsistent),
                              Double(bitPattern: hostSeconds.load(ordering: .sequentiallyConsistent)),
                              publishedInterval.load(ordering: .sequentiallyConsistent))
                if sequence.load(ordering: .sequentiallyConsistent) == version { return result }
            }
        }
    }

    /// Position of the current source expected at the speaker at `hostTime`.
    /// The render timestamp, rather than AVPlayer's item clock, is authoritative.
    @MainActor func presentationPosition(token: Int, visit: Int64, selectionVersion: Int, at hostTime: CMTime) -> Double? {
        let interval = anchor.activeInterval.load(ordering: .acquiring)
        guard interval > 0, let sample = anchor.read(), sample.token == token, sample.visit == visit,
              sample.selectionVersion == selectionVersion, sample.interval == interval else { return nil }
        let latency = source.outputPresentationLatency
        #if DEBUG
        debugAfterPresentationLatencyRead?()
        #endif
        // The same media can be selected again while this SDK getter returns.
        // A newer publication for this owner remains valid; another visit does not.
        guard let current = anchor.read(), current.token == token, current.visit == visit,
              current.selectionVersion == selectionVersion, current.interval == interval,
              anchor.activeInterval.load(ordering: .acquiring) == interval else { return nil }
        return max(0, Double(sample.frame) / 48_000 + hostTime.seconds - sample.hostEnd - latency)
    }

    @MainActor func beginPlayingInterval(restarting: Bool) -> Bool {
        if !restarting, anchor.activeInterval.load(ordering: .acquiring) > 0 { return true }
        guard intervalIssuer < UInt64.max - 1 else {
            intervalIssuer = .max; endPlayingInterval(); return false
        }
        intervalIssuer += 1
        anchor.activeInterval.store(intervalIssuer, ordering: .releasing)
        return true
    }

    @MainActor func endPlayingInterval() {
        anchor.activeInterval.store(0, ordering: .releasing)
    }

    #if DEBUG
    // Store-level calibration only: the caller is the sole offline manual-render owner
    // and must not overlap this publication with renderOffline. No SDK callback is replaced.
    @MainActor func debugPublishSyntheticRenderAnchor(_ sample: ContinuousPCMRenderer.Snapshot,
        hostEnd: Double, capturedPlayingInterval: UInt64? = nil) -> Bool {
        guard engine.isInManualRenderingMode, engine.manualRenderingMode == .offline,
              sample.token > 0, sample.visit > 0, sample.frame >= 0, hostEnd.isFinite else { return false }
        anchor.publish(sample, hostEnd: hostEnd,
            interval: capturedPlayingInterval ?? anchor.activeInterval.load(ordering: .acquiring))
        return true
    }
    @MainActor var debugRenderAnchorPublicationSequence: Int {
        anchor.sequence.load(ordering: .sequentiallyConsistent)
    }
    @MainActor var debugPlayingInterval: UInt64 { anchor.activeInterval.load(ordering: .acquiring) }
    @MainActor var debugAfterPresentationLatencyRead: (() -> Void)?
    @MainActor func debugSetInactiveIntervalIssuer(_ value: UInt64) -> Bool {
        guard engine.isInManualRenderingMode, engine.manualRenderingMode == .offline,
              anchor.activeInterval.load(ordering: .acquiring) == 0, value >= intervalIssuer else { return false }
        intervalIssuer = value; return true
    }
    #endif

    private final class RenderStorage: @unchecked Sendable {
        let renderer: ContinuousPCMRenderer
        #if DEBUG
        let debugRenderAccounting: ContinuousPCMRenderer.DebugRenderAccountingRecorder?
        #endif
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 512 * 2)
        let maximumFrameCount = Atomic<Int>(0)
        init(_ renderer: ContinuousPCMRenderer) {
            self.renderer = renderer
            #if DEBUG
            debugRenderAccounting = renderer.debugRenderAccounting
            #endif
            scratch.initialize(repeating: 0, count: 512 * 2)
        }
        deinit { scratch.deinitialize(count: 512 * 2); scratch.deallocate() }
    }

    init(renderer: ContinuousPCMRenderer) {
        let storage = RenderStorage(renderer)
        self.storage = storage
        let anchor = RenderAnchor()
        self.anchor = anchor
        source = AVAudioSourceNode(format: format) { isSilence, timestamp, count, audioBufferList in
            // Capture before any render work. A paused or superseded callback
            // must not gain permission merely because it finishes after resume.
            let playingInterval = anchor.activeInterval.load(ordering: .acquiring)
            #if DEBUG
            let receipts = storage.debugRenderAccounting?.callbackLedger
            // Optional diagnostic clocks only. End is before final ledger publication,
            // not an assertion that the SDK has returned from this closure.
            let executionEntryHost = receipts?.capturesExecutionTime == true ? mach_absolute_time() : 0
            if let receipts, let accounting = storage.debugRenderAccounting {
                let value = timestamp.pointee
                receipts.beginSource(stamp: .init(host: value.mHostTime, sample: value.mSampleTime, rate: 48_000,
                    nativeFlags: value.mFlags.rawValue,
                    valid: (value.mFlags.contains(.hostTimeValid) ? 1 : 0) | (value.mFlags.contains(.sampleTimeValid) ? 2 : 0)),
                    frames: count, counters: accounting.renderWriterCounters(), executionEntryHost: executionEntryHost)
            }
            storage.debugRenderAccounting?.sourceCallbackEntered(frames: Int(count),
                hostTimeValid: timestamp.pointee.mFlags.contains(.hostTimeValid),
                hostTime: timestamp.pointee.mHostTime)
            #endif
            // One render writer; expose the actual callback quantum rather than
            // assuming that the fixed scratch chunk is the hardware buffer size.
            if Int(count) > storage.maximumFrameCount.load(ordering: .relaxed) {
                storage.maximumFrameCount.store(Int(count), ordering: .releasing)
            }
            isSilence.pointee = false
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            #if DEBUG
            receipts?.layout(buffers: UInt32(buffers.count),
                channels0: buffers.count > 0 ? buffers[0].mNumberChannels : 0,
                channels1: buffers.count > 1 ? buffers[1].mNumberChannels : 0,
                bytes0: buffers.count > 0 ? buffers[0].mDataByteSize : 0,
                bytes1: buffers.count > 1 ? buffers[1].mDataByteSize : 0,
                dataPresent: buffers.count == 2 && buffers[0].mData != nil && buffers[1].mData != nil)
            #endif
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                #if DEBUG
                storage.debugRenderAccounting?.sourceCallbackCompleted(frames: Int(count), invalidLayout: true)
                if let accounting = storage.debugRenderAccounting {
                    receipts?.endSource(result: kAudio_ParamError, counters: accounting.renderWriterCounters(),
                        executionEndHost: receipts?.capturesExecutionTime == true ? mach_absolute_time() : 0)
                }
                #endif
                return kAudio_ParamError
            }
            var offset = 0
            while offset < Int(count) {
                let frames = min(512, Int(count) - offset)
                storage.renderer.render(interleaved: UnsafeMutableBufferPointer(start: storage.scratch, count: frames * 2), frameCount: frames)
                #if DEBUG
                if let accounting = storage.debugRenderAccounting, receipts != nil {
                    receipts?.observeChunk(accounting.renderWriterCounters())
                }
                if let audit = storage.debugRenderAccounting, audit.capturesSourceOutput {
                    for frame in 0..<frames {
                        let l = storage.scratch[frame * 2]
                        left[offset + frame] = l
                        let r = storage.scratch[frame * 2 + 1]
                        right[offset + frame] = r
                        audit.sourceOutputPair(left: l, right: r)
                    }
                } else {
                    for frame in 0..<frames {
                        left[offset + frame] = storage.scratch[frame * 2]
                        right[offset + frame] = storage.scratch[frame * 2 + 1]
                    }
                }
                #else
                for frame in 0..<frames {
                    left[offset + frame] = storage.scratch[frame * 2]
                    right[offset + frame] = storage.scratch[frame * 2 + 1]
                }
                #endif
                offset += frames
            }
            if timestamp.pointee.mFlags.contains(.hostTimeValid) {
                anchor.publish(storage.renderer.snapshot,
                    hostEnd: AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime) + Double(count) / 48_000,
                    interval: playingInterval)
            }
            #if DEBUG
            storage.debugRenderAccounting?.sourceCallbackCompleted(frames: Int(count), invalidLayout: false)
            if let accounting = storage.debugRenderAccounting {
                receipts?.endSource(result: noErr, counters: accounting.renderWriterCounters(),
                    executionEndHost: receipts?.capturesExecutionTime == true ? mach_absolute_time() : 0)
            }
            #endif
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }
}
