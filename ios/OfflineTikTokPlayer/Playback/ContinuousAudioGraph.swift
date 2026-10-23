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
    var maximumRenderFrameCount: Int { storage.maximumFrameCount.load(ordering: .acquiring) }

    private final class RenderAnchor: @unchecked Sendable {
        let sequence = Atomic<Int>(0)
        let token = Atomic<Int>(0)
        let frame = Atomic<Int64>(0)
        let hostSeconds = Atomic<UInt64>(0)
        var version = 0 // Render owner only.
        func publish(_ sample: ContinuousPCMRenderer.Snapshot, hostEnd: Double) {
            version &+= 2
            sequence.store(version - 1, ordering: .sequentiallyConsistent)
            token.store(sample.token, ordering: .sequentiallyConsistent)
            frame.store(sample.frame, ordering: .sequentiallyConsistent)
            hostSeconds.store(hostEnd.bitPattern, ordering: .sequentiallyConsistent)
            sequence.store(version, ordering: .sequentiallyConsistent)
        }
        func read() -> (token: Int, frame: Int64, hostEnd: Double)? {
            while true {
                let version = sequence.load(ordering: .sequentiallyConsistent)
                if version == 0 { return nil }
                if version & 1 != 0 { continue }
                let result = (token.load(ordering: .sequentiallyConsistent), frame.load(ordering: .sequentiallyConsistent),
                              Double(bitPattern: hostSeconds.load(ordering: .sequentiallyConsistent)))
                if sequence.load(ordering: .sequentiallyConsistent) == version { return result }
            }
        }
    }

    /// Position of the current source expected at the speaker at `hostTime`.
    /// The render timestamp, rather than AVPlayer's item clock, is authoritative.
    func presentationPosition(token: Int, at hostTime: CMTime) -> Double? {
        guard let anchor = anchor.read(), anchor.token == token else { return nil }
        return max(0, Double(anchor.frame) / 48_000 + hostTime.seconds - anchor.hostEnd - source.outputPresentationLatency)
    }

    #if DEBUG
    // Store-level calibration only: the caller is the sole offline manual-render owner
    // and must not overlap this publication with renderOffline. No SDK callback is replaced.
    @MainActor func debugPublishSyntheticRenderAnchor(_ sample: ContinuousPCMRenderer.Snapshot,
        hostEnd: Double) -> Bool {
        guard engine.isInManualRenderingMode, engine.manualRenderingMode == .offline,
              sample.token > 0, sample.visit > 0, sample.frame >= 0, hostEnd.isFinite else { return false }
        anchor.publish(sample, hostEnd: hostEnd)
        return true
    }
    @MainActor var debugRenderAnchorPublicationSequence: Int {
        anchor.sequence.load(ordering: .sequentiallyConsistent)
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
                    hostEnd: AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime) + Double(count) / 48_000)
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
