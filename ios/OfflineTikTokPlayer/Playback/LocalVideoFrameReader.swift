@preconcurrency import AVFoundation
import Foundation
import IOSurface

/// A temporary decoder for the single current picture. The caller supplies a complete
/// local asset and the same composition and pixel format as its prepared video route.
@MainActor
final class LocalVideoFrameReader {
    private let state: LocalVideoReadState

    init(asset: AVURLAsset, composition: AVVideoComposition?, pixelFormat: OSType, start: CMTime) {
        state = LocalVideoReadState(asset: asset, composition: composition, pixelFormat: pixelFormat, start: start)
        if asset.url.isFileURL, pixelFormat != 0, start.isNumeric, start.epoch == 0, CMTimeCompare(start, .zero) >= 0 {
            LocalVideoReadLane.shared.select(state)
        }
    }

    func frame(at target: CMTime) -> (pixel: CVPixelBuffer, position: CMTime)? {
        LocalVideoReadLane.shared.frame(for: state, at: target)
    }

    func cancel() { LocalVideoReadLane.shared.cancel(state) }
    deinit { LocalVideoReadLane.shared.cancel(state) }
}

private final class LocalVideoReadState: @unchecked Sendable {
    struct Frame {
        let pixel: CVPixelBuffer
        let position: CMTime
        let duration: CMTime
        let bytes: Int
    }

    let asset: AVURLAsset
    let composition: AVVideoComposition?
    let pixelFormat: OSType
    // Mutable fields are protected by the lane's lock. No AVFoundation read runs under it.
    var target: CMTime
    var frames: [Frame] = []
    var bytes = 0
    var endpoint: CMTime?
    var reachedEnd = false

    init(asset: AVURLAsset, composition: AVVideoComposition?, pixelFormat: OSType, start: CMTime) {
        self.asset = asset
        self.composition = composition
        self.pixelFormat = pixelFormat
        self.target = start
    }

    func discardSuperseded() {
        while frames.count > 1, CMTimeCompare(frames[1].position, target) <= 0 {
            bytes -= frames.removeFirst().bytes
        }
    }
}

private final class LocalVideoReadLane: @unchecked Sendable {
    static let shared = LocalVideoReadLane()
    private let capacity = 6
    private let byteLimit = 64 * 1_024 * 1_024
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "OfflineTikTokPlayer.LocalVideoFrameReader", qos: .userInitiated)
    private var selected: LocalVideoReadState?
    private var scheduled = false

    // Only the serial queue owns these native objects. A blocked native call occupies
    // this one lane. Intermediate replacements never queue additional readers or reads.
    private var owner: LocalVideoReadState?
    private var source: Source?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderOutput?
    private var lastPosition = CMTime.invalid
    private var openedFor = CMTime.invalid

    func select(_ state: LocalVideoReadState) {
        lock.withLock {
            clear(selected)
            selected = state
            wake()
        }
    }

    func cancel(_ state: LocalVideoReadState) {
        lock.withLock {
            guard selected === state else { return }
            clear(state)
            selected = nil
            wake()
        }
    }

    func frame(for state: LocalVideoReadState, at target: CMTime) -> (CVPixelBuffer, CMTime)? {
        lock.withLock {
            guard selected === state, target.isNumeric, target.epoch == 0,
                  CMTimeCompare(target, state.target) >= 0 else { return nil }
            state.target = target
            state.discardSuperseded()
            if canRead(state) { wake() }
            guard let first = state.frames.first, CMTimeCompare(first.position, target) <= 0,
                  state.endpoint.map({ CMTimeCompare(target, $0) < 0 }) ?? true else { return nil }
            if state.frames.count > 1 || CMTimeCompare(target, first.position) == 0 {
                return (first.pixel, first.position)
            }
            // An unconfirmed tail may have a newer frame already due. Only EOF can
            // establish the final display interval without a real successor.
            guard state.reachedEnd, var end = state.endpoint else { return nil }
            if first.duration.isNumeric, CMTimeCompare(first.duration, .zero) > 0 {
                end = CMTimeMinimum(end, CMTimeAdd(first.position, first.duration))
            }
            return CMTimeCompare(target, end) < 0 ? (first.pixel, first.position) : nil
        }
    }

    private func clear(_ state: LocalVideoReadState?) {
        state?.frames.removeAll()
        state?.bytes = 0
    }

    private func canRead(_ state: LocalVideoReadState) -> Bool {
        !state.reachedEnd && state.frames.count < capacity && state.bytes <= byteLimit - (state.frames.last?.bytes ?? 0)
    }

    /// Called with the lock held. There is at most one outstanding pump or metadata load.
    private func wake() {
        guard !scheduled else { return }
        scheduled = true
        queue.async { self.pump() }
    }

    private enum Work { case change(LocalVideoReadState?), read(LocalVideoReadState, CMTime), idle }

    private func pump() {
        while true {
            let work: Work = lock.withLock {
                if owner !== selected { return .change(selected) }
                guard let state = selected, canRead(state) else {
                    scheduled = false
                    return .idle
                }
                return .read(state, state.target)
            }
            switch work {
            case .idle: return
            case .change(let state):
                closeDecoder()
                source = nil
                owner = state
                guard let state else { continue }
                Task.detached(priority: .userInitiated) {
                    let loaded = try? await Source(state)
                    self.queue.async {
                        self.lock.withLock {
                            if self.selected === state {
                                self.source = loaded
                                state.endpoint = loaded?.end
                                state.reachedEnd = loaded == nil
                            }
                        }
                        self.pump()
                    }
                }
                return
            case .read(let state, let target):
                autoreleasepool { read(state, target: target) }
            }
        }
    }

    private func closeDecoder() {
        reader?.cancelReading()
        output = nil
        reader = nil
        lastPosition = .invalid
        openedFor = .invalid
    }

    private func finish(_ state: LocalVideoReadState, completed: Bool) {
        closeDecoder()
        lock.withLock {
            guard selected === state else { return }
            state.reachedEnd = true
            if !completed { clear(state) }
        }
    }

    private func read(_ state: LocalVideoReadState, target: CMTime) {
        guard let source, CMTimeCompare(target, source.end) < 0 else {
            finish(state, completed: false)
            return
        }
        let progress = lastPosition.isNumeric ? CMTimeMaximum(lastPosition, openedFor) : openedFor
        if reader == nil || (progress.isNumeric && CMTimeSubtract(target, progress).seconds > 1) {
            closeDecoder()
            let active = lock.withLock {
                guard selected === state else { return false }
                clear(state)
                return true
            }
            guard active else { return }
            guard let anchor = source.anchor(for: target), let native = try? AVAssetReader(asset: state.asset) else {
                finish(state, completed: false)
                return
            }
            let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: state.pixelFormat,
                                            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            let decoded: AVAssetReaderOutput
            if let composition = state.composition {
                let composed = AVAssetReaderVideoCompositionOutput(videoTracks: source.tracks, videoSettings: settings)
                composed.videoComposition = composition
                decoded = composed
            } else {
                decoded = AVAssetReaderTrackOutput(track: source.tracks[0], outputSettings: settings)
            }
            decoded.alwaysCopiesSampleData = false
            guard native.canAdd(decoded) else { finish(state, completed: false); return }
            native.add(decoded)
            native.timeRange = CMTimeRange(start: anchor, end: source.end)
            reader = native
            output = decoded
            openedFor = target
            guard lock.withLock({ selected === state }) else { return }
            guard native.startReading() else { finish(state, completed: false); return }
        }
        guard lock.withLock({ selected === state }) else { return }
        guard let sample = output?.copyNextSampleBuffer() else {
            finish(state, completed: reader?.status == .completed)
            return
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]],
           attachments.first?[kCMSampleAttachmentKey_DoNotDisplay as String] as? Bool == true { return }
        let position = CMSampleBufferGetOutputPresentationTimeStamp(sample)
        guard CMSampleBufferDataIsReady(sample), position.isNumeric, position.epoch == 0,
              !lastPosition.isNumeric || CMTimeCompare(position, lastPosition) > 0,
              let pixel = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetPixelFormatType(pixel) == state.pixelFormat else {
            finish(state, completed: false)
            return
        }
        lastPosition = position
        let surfaceBytes = CVPixelBufferGetIOSurface(pixel).map { IOSurfaceGetAllocSize($0.takeUnretainedValue()) } ?? 0
        let cost = max(surfaceBytes, CVPixelBufferGetDataSize(pixel))
        let frame = LocalVideoReadState.Frame(pixel: pixel, position: position, duration: CMSampleBufferGetOutputDuration(sample), bytes: cost)
        let stored = lock.withLock {
            guard selected === state else { return true }
            // Always leave enough capacity for a successor. Decoder scratch storage
            // is owned by AVFoundation; this cap covers the retained decoded window.
            guard cost > 0, cost <= byteLimit / 2, cost <= byteLimit - state.bytes else { return false }
            state.frames.append(frame)
            state.bytes += cost
            state.discardSuperseded()
            return true
        }
        if !stored { finish(state, completed: false) }
    }

    private struct Source: @unchecked Sendable {
        let tracks: [AVAssetTrack]
        let end: CMTime
        let cursorTrack: AVAssetTrack?
        let segments: [AVAssetTrackSegment]
        let cadence: CMTime?

        init?(_ state: LocalVideoReadState) async throws {
            let asset = state.asset
            guard asset.url.isFileURL, try await asset.load(.isReadable) else { return nil }
            tracks = try await asset.loadTracks(withMediaType: .video)
            guard let first = tracks.first, state.composition != nil || tracks.count == 1 else { return nil }
            let duration = try await asset.load(.duration)
            if let composition = state.composition {
                end = duration
                let timing = composition.sourceTrackIDForFrameTiming
                cursorTrack = tracks.first { $0.trackID == timing }
                cadence = timing == kCMPersistentTrackID_Invalid ? composition.frameDuration : nil
            } else {
                end = CMTimeMinimum(duration, CMTimeRangeGetEnd(try await first.load(.timeRange)))
                cursorTrack = first
                cadence = nil
            }
            guard end.isNumeric, end.epoch == 0, CMTimeCompare(end, .zero) > 0 else { return nil }
            if let cursorTrack, (try? await cursorTrack.load(.canProvideSampleCursors)) == true {
                segments = (try? await cursorTrack.load(.segments)) ?? []
            } else { segments = [] }
        }

        /// Start on an authored boundary before the target. An arbitrary reader
        /// timeRange can trim the first sample and manufacture a new output PTS.
        func anchor(for target: CMTime) -> CMTime? {
            if CMTimeCompare(target, .zero) == 0 { return .zero }
            // A short prefix can be decoded intact even without a sample index.
            let prefix: CMTime? = target.seconds <= 1 ? .zero : nil
            if let cadence, cadence.isNumeric, cadence.value > 0 {
                let ticks = CMTimeConvertScale(target, timescale: cadence.timescale, method: .roundTowardZero)
                guard ticks.isNumeric else { return prefix }
                let index = max(0, ticks.value / cadence.value - 1)
                return CMTime(value: index * cadence.value, timescale: cadence.timescale)
            }
            guard let cursorTrack, let segment = segments.first(where: { CMTimeRangeContainsTime($0.timeMapping.target, time: target) }) else { return prefix }
            let mapping = segment.timeMapping
            if segment.isEmpty { return mapping.target.start }
            let sourceTime = CMTimeMapTimeFromRangeToRange(target, fromRange: mapping.target, toRange: mapping.source)
            guard sourceTime.isNumeric, let cursor = cursorTrack.makeSampleCursor(presentationTimeStamp: sourceTime) else { return prefix }
            _ = cursor.stepInPresentationOrder(byCount: -1)
            let stamp = cursor.presentationTimeStamp
            guard stamp.isNumeric, CMTimeCompare(stamp, sourceTime) <= 0 else { return prefix }
            if CMTimeCompare(stamp, mapping.source.start) <= 0 { return mapping.target.start }
            let anchor = CMTimeMapTimeFromRangeToRange(stamp, fromRange: mapping.source, toRange: mapping.target)
            return anchor.isNumeric && CMTimeCompare(anchor, target) <= 0 ? anchor : prefix
        }
    }
}
