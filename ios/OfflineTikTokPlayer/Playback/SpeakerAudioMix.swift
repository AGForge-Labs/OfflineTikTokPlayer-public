import AVFoundation
import MediaToolbox
import AudioToolbox
import PlayerCore

/// Each tap owns a render-thread state. No application locks, I/O or allocation in process().
private final class SpeakerTapState {
    var processor: SpeakerAudioProcessor?
    var scratch: [Float] = []
    var interleaved = false

    func prepare(_ format: AudioStreamBasicDescription) {
        let count = Int(format.mChannelsPerFrame)
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let packed = format.mFormatFlags & kAudioFormatFlagIsPacked != 0
        guard format.mFormatID == kAudioFormatLinearPCM, isFloat, packed,
              format.mBitsPerChannel == 32, (1...8).contains(count) else {
            processor = nil; scratch = []; return
        }
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        scratch = Array(repeating: 0, count: count)
        processor = SpeakerAudioProcessor(sampleRate: format.mSampleRate, channels: count, enabled: true)
    }

    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard let processor, frames > 0 else { return }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        let channels = scratch.count
        guard channels > 0, list.count == (interleaved ? 1 : channels) else { return }
        for buffer in list {
            let samples = frames * (interleaved ? channels : 1)
            guard buffer.mData != nil, Int(buffer.mDataByteSize) >= samples * MemoryLayout<Float>.size else { return }
        }
        scratch.withUnsafeMutableBufferPointer { frame in
            for index in 0..<frames {
                for channel in 0..<channels {
                    let buffer = list[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
                    frame[channel] = buffer[interleaved ? index * channels + channel : index]
                }
                processor.process(frame)
                for channel in 0..<channels {
                    let buffer = list[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
                    buffer[interleaved ? index * channels + channel : index] = frame[channel]
                }
            }
        }
    }
}

enum SpeakerAudioMix {
    static func shouldEnhance(enabled: Bool, routes: [AVAudioSession.Port]) -> Bool {
        enabled && !routes.isEmpty && routes.allSatisfy { $0 == .builtInSpeaker }
    }

    static func make(tracks: [AVAssetTrack]) -> AVAudioMix? {
        guard !tracks.isEmpty else { return nil }
        var parameters: [AVAudioMixInputParameters] = []
        for track in tracks {
            let state = Unmanaged.passRetained(SpeakerTapState())
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: state.toOpaque(),
                init: { _, info, storage in storage.pointee = info },
                finalize: { tap in Unmanaged<SpeakerTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
                prepare: { tap, _, format in
                    Unmanaged<SpeakerTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
                },
                unprepare: { tap in
                    let state = Unmanaged<SpeakerTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    state.processor = nil; state.scratch = []
                },
                process: { tap, frames, _, buffers, framesOut, flagsOut in
                    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
                    guard status == noErr else { framesOut.pointee = 0; return }
                    let state = Unmanaged<SpeakerTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    if flagsOut.pointee & kMTAudioProcessingTapFlag_StartOfStream != 0 { state.processor?.reset() }
                    state.process(buffers, frames: framesOut.pointee)
                })
            var tap: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                   kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
            guard status == noErr, let tap else { state.release(); return nil }
            let input = AVMutableAudioMixInputParameters(track: track)
            input.audioTapProcessor = tap
            parameters.append(input)
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters
        return mix
    }
}

@MainActor
final class SpeakerAudioController {
    typealias TrackLoader = @MainActor (AVPlayerItem) async -> [AVAssetTrack]?
    private struct Entry {
        weak var item: AVPlayerItem?
        let enabled: Bool
        let token: UUID
        let task: Task<Void, Never>?
        var awaitingEnqueue = false
        var retryWhenReady = false
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var enabled = false
    private let preparationBudget: Duration
    private let loadTracks: TrackLoader

    init(preparationBudget: Duration = .milliseconds(500),
         loadTracks: @escaping TrackLoader = { try? await $0.asset.loadTracks(withMediaType: .audio) }) {
        self.preparationBudget = preparationBudget
        self.loadTracks = loadTracks
    }

    /// Configure before the item enters AVQueuePlayer, so play doesn't rebuild its audio path.
    func prepare(_ item: AVPlayerItem, within budget: Duration? = nil) async {
        let id = ObjectIdentifier(item), token = UUID()
        entries[id]?.task?.cancel()
        entries[id] = Entry(item: item, enabled: enabled, token: token, task: nil, awaitingEnqueue: true)
        let loader = loadTracks
        let tracks = enabled ? await PlaybackPreparation.value(within: budget ?? preparationBudget) { await loader(item) } : nil
        guard !Task.isCancelled, entries[id]?.token == token else {
            if entries[id]?.token == token { entries.removeValue(forKey: id) }
            return
        }
        // A route or Original-sound change can happen while metadata is loading.
        item.audioMix = enabled ? tracks.flatMap { SpeakerAudioMix.make(tracks: $0) } : nil
        entries[id] = Entry(item: item, enabled: enabled, token: token, task: nil, awaitingEnqueue: true,
                            retryWhenReady: enabled && tracks == nil)
    }

    func update(items: [AVPlayerItem], enabled: Bool) {
        self.enabled = enabled
        let ids = Set(items.map(ObjectIdentifier.init))
        for (id, entry) in entries where entry.item == nil || (!ids.contains(id) && !entry.awaitingEnqueue) {
            entry.task?.cancel(); entries.removeValue(forKey: id)
        }
        for item in items {
            let id = ObjectIdentifier(item)
            entries[id]?.awaitingEnqueue = false
            if let entry = entries[id], entry.item === item, entry.enabled == enabled,
               !(entry.retryWhenReady && item.status == .readyToPlay) { continue }
            entries[id]?.task?.cancel()
            let token = UUID()
            if !enabled {
                item.audioMix = nil
                entries[id] = Entry(item: item, enabled: false, token: token, task: nil)
                continue
            }
            let loader = loadTracks, budget = preparationBudget
            let task = Task { [weak self, weak item] in
                guard let item else { return }
                let tracks = await PlaybackPreparation.value(within: budget) { await loader(item) }
                guard let self, !Task.isCancelled,
                      self.entries[id]?.token == token else { return }
                item.audioMix = tracks.flatMap { SpeakerAudioMix.make(tracks: $0) }
            }
            entries[id] = Entry(item: item, enabled: true, token: token, task: task,
                                retryWhenReady: item.status != .readyToPlay)
        }
    }

    deinit { for entry in entries.values { entry.task?.cancel() } }
}
