import AVFoundation
import PlayerCore
import Synchronization

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
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                #if DEBUG
                storage.debugRenderAccounting?.sourceCallbackCompleted(frames: Int(count), invalidLayout: true)
                #endif
                return kAudio_ParamError
            }
            var offset = 0
            while offset < Int(count) {
                let frames = min(512, Int(count) - offset)
                storage.renderer.render(interleaved: UnsafeMutableBufferPointer(start: storage.scratch, count: frames * 2), frameCount: frames)
                for frame in 0..<frames {
                    left[offset + frame] = storage.scratch[frame * 2]
                    right[offset + frame] = storage.scratch[frame * 2 + 1]
                }
                offset += frames
            }
            if timestamp.pointee.mFlags.contains(.hostTimeValid) {
                anchor.publish(storage.renderer.snapshot,
                    hostEnd: AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime) + Double(count) / 48_000)
            }
            #if DEBUG
            storage.debugRenderAccounting?.sourceCallbackCompleted(frames: Int(count), invalidLayout: false)
            #endif
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }
}
