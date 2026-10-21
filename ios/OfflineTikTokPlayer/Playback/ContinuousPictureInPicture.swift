import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation

/// A video-only PiP surface. Its supported sample-buffer delegate forwards user commands to
/// the service that owns continuous audio; muted AVPlayer rate changes are never user commands.
/// The caller must add displayLayer to its visible inline surface and keep its bounds current.
@MainActor
final class ContinuousPictureInPicture: NSObject {
    struct PresentationTicket: Equatable, Sendable {
        fileprivate let generation: Int
        fileprivate let item: ObjectIdentifier
    }
    #if DEBUG
    /// Observes the actual SDK request without replacing its result.
    var onFrameAcquisition: ((AVPlayerItem, CMTime) -> Void)?
    enum DebugRenderStage: Int, Sendable {
        case attempt = 0, hasNewFalse = 1, hasNewTrue = 2, copied = 3, enqueued = 4
        case seekBegin = 5, compositionAssigned = 6, outputAttached = 7, seekBlocked = 8
    }
    struct DebugRenderStamp: Sendable {
        let stage: DebugRenderStage
        // 0 before any seek, 1 while a seek is active, 2 after that first seek.
        let region: Int
        let ticket: PresentationTicket?
        let presentationRevision: Int
        let ownershipUnchanged: Bool
        let nativeSeekTicket: UInt64?
        let entryNs: UInt64, returnNs: UInt64
        let requestedSeconds: Double?, sampleSeconds: Double?
        // Cached values at entry; seekBegin therefore preserves the pre-flush proof.
        let copiedPTS: Double?, submittedPTS: Double?, submittedCount: UInt64
    }
    var onDebugRenderStamp: ((DebugRenderStamp) -> Void)?
    private var debugRenderRevision: Int?
    private var debugBeforeMask: UInt16 = 0, debugDuringMask: UInt16 = 0, debugAfterMask: UInt16 = 0
    private var debugRenderSawSeek = false
    private func debugTraceRender(_ stage: DebugRenderStage, requested: CMTime? = nil,
                                  sample: CMTime? = nil, sourceTicket: PresentationTicket? = nil,
                                  _ operation: () -> Void = {}) {
        guard let observer = onDebugRenderStamp else { operation(); return }
        let revision = sourceTicket?.generation ?? presentationRevision
        if debugRenderRevision != revision {
            debugRenderRevision = revision
            debugBeforeMask = 0; debugDuringMask = 0; debugAfterMask = 0; debugRenderSawSeek = false
        }
        if activeSeekTicket != nil { debugRenderSawSeek = true }
        let region = activeSeekTicket != nil ? 1 : (debugRenderSawSeek ? 2 : 0)
        let bit = UInt16(1) << stage.rawValue
        let mask = region == 0 ? debugBeforeMask : (region == 1 ? debugDuringMask : debugAfterMask)
        guard mask & bit == 0 else { operation(); return }
        if region == 0 { debugBeforeMask |= bit }
        else if region == 1 { debugDuringMask |= bit }
        else { debugAfterMask |= bit }
        let ticket = sourceTicket ?? currentItem.map { PresentationTicket(generation: revision, item: ObjectIdentifier($0)) }
        let activeSeek = activeSeekTicket
        let seek = activeSeekTicket ?? (debugRenderSawSeek ? seekTicket : nil)
        let copied = lastCopiedFramePositionSeconds, submitted = lastFramePositionSeconds
        let count = submittedFrameCount
        let entered = DispatchTime.now().uptimeNanoseconds
        operation()
        let returned = DispatchTime.now().uptimeNanoseconds
        observer(DebugRenderStamp(stage: stage, region: region, ticket: ticket, presentationRevision: revision,
            ownershipUnchanged: revision == presentationRevision
                && ticket?.item == currentItem.map { ObjectIdentifier($0) } && activeSeek == activeSeekTicket,
            nativeSeekTicket: seek, entryNs: entered, returnNs: returned,
            requestedSeconds: requested.flatMap { $0.isNumeric ? CMTimeGetSeconds($0) : nil },
            sampleSeconds: sample.flatMap { $0.isNumeric ? CMTimeGetSeconds($0) : nil },
            copiedPTS: copied, submittedPTS: submitted, submittedCount: count))
    }
    #endif
    enum Event: Int {
        case willStart = 0
        case didStart = 1
        case willStop = 2
        case didStop = 3
        case startFailed = 4
        case frameFailed = 5
        case restoreRequested = 6
        case restoreCompleted = 7
        case restoreUnavailable = 8
        case userPlayRequested = 9
        case userPauseRequested = 10
        case userSkipRequested = 11
        case sourcePrepared = 12
        case sourcePreparationFailed = 13
    }

    let displayLayer = AVSampleBufferDisplayLayer()
    private(set) var controller: AVPictureInPictureController?
    private(set) var submittedFrameCount: UInt64 = 0
    private(set) var lastFramePositionSeconds: Double?
    private(set) var lastCopiedFramePositionSeconds: Double?
    private(set) var pausedFutureFrameRejectionCount: UInt64 = 0
    private(set) var blockedFrameAcquisitionCount: UInt64 = 0
    private(set) var orientationPrepared = false
    var onSetPlaying: ((Bool) -> Void)?
    /// Complete after the service has applied or rejected the seek, including cancellation.
    var onSkip: ((Double, @escaping () -> Void) -> Void)?
    /// Complete true only after the inline UI has actually been restored.
    var onRestoreUI: ((@escaping (Bool) -> Void) -> Void)?
    var onStateChanged: ((Bool, Bool, Bool) -> Void)?
    var onEvent: ((Event, Int?) -> Void)?

    nonisolated private let playbackState = ContinuousPiPPlaybackState()
    private weak var currentItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var observations: [NSKeyValueObservation] = []
    private var frameTimer: Timer?
    private var timebase: CMTimebase?
    private var format: CMVideoFormatDescription?
    private var formatWidth = 0
    private var formatHeight = 0
    private var formatPixelType: OSType = 0
    private var lastEnqueuedTime = CMTime.invalid
    private var hasReportedFrameFailure = false
    private var invalidated = false
    private var frameFeedEnabled = true
    private var preparationTask: Task<Void, Never>?
    private var itemGeneration = 0
    private var presentationRevision = 0
    private var installedTimeline: PresentationTicket?
    private var presentationActive = false
    private var seekTicket: UInt64 = 0
    private var activeSeekTicket: UInt64?
    private var originalComposition: AVVideoComposition?
    private var installedComposition: AVVideoComposition?

    var isReady: Bool { !invalidated && controller != nil && timebase != nil }
    var isFrameFeedSuspended: Bool { !frameFeedEnabled }
    var isFrameFeedRunning: Bool { frameTimer != nil }
    var isVideoReadyForDisplay: Bool { displayLayer.isReadyForDisplay }
    var requestedPositionSeconds: Double { playbackState.read().position }
    var timebasePositionSeconds: Double? {
        guard let timebase else { return nil }
        let seconds = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
        return seconds.isFinite ? seconds : nil
    }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        var createdTimebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                          sourceClock: CMClockGetHostTimeClock(),
                                          timebaseOut: &createdTimebase) == noErr {
            timebase = createdTimebase
            displayLayer.controlTimebase = createdTimebase
            if let createdTimebase {
                CMTimebaseSetTime(createdTimebase, time: .zero)
                CMTimebaseSetRate(createdTimebase, rate: 0)
            }
        }
        guard timebase != nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                playbackDelegate: self)
        let createdController: AVPictureInPictureController? = AVPictureInPictureController(contentSource: source)
        guard let pip = createdController else { return }
        pip.delegate = self
        controller = pip
        observations = [
            pip.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.reportState() }
            },
            pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.reportState() }
            },
            pip.observe(\.isPictureInPictureSuspended, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.reportState() }
            }
        ]
    }

    /// Exactly one item output is attached at a time; this never prepares additional video items.
    @discardableResult
    func setCurrentItem(_ item: AVPlayerItem?) -> PresentationTicket? {
        guard !invalidated else { return nil }
        presentationRevision &+= 1
        installedTimeline = nil
        presentationActive = false
        activeSeekTicket = nil
        stopFrameTimer()
        let ticket = item.map { PresentationTicket(generation: presentationRevision, item: ObjectIdentifier($0)) }
        if currentItem === item {
            // A new service request for the same item needs its own timeline,
            // while its output and in-flight geometry preparation stay reusable.
            flushForSeek()
            return ticket
        }
        preparationTask?.cancel()
        preparationTask = nil
        stopFrameTimer()
        itemGeneration &+= 1
        activeSeekTicket = nil
        let generation = itemGeneration
        if let videoOutput { currentItem?.remove(videoOutput) }
        restoreOriginalComposition()
        currentItem = item
        videoOutput = nil
        orientationPrepared = false
        format = nil
        hasReportedFrameFailure = false
        displayLayer.flushAndRemoveImage()
        lastEnqueuedTime = .invalid
        lastFramePositionSeconds = nil
        lastCopiedFramePositionSeconds = nil
        guard let item else { stopFrameTimer(); return nil }
        originalComposition = item.videoComposition
        let existingComposition = item.videoComposition
        preparationTask = Task { [weak self, weak item] in
            guard let item else { return }
            do {
                let composition: AVVideoComposition
                if let existingComposition { composition = existingComposition }
                else { composition = try await Self.makeVideoComposition(for: item.asset) }
                try Task.checkCancellation()
                guard let self, !self.invalidated, self.itemGeneration == generation,
                      self.currentItem === item else { return }
                if existingComposition == nil {
                    #if DEBUG
                    self.debugTraceRender(.compositionAssigned) {
                        item.videoComposition = composition
                        self.installedComposition = composition
                    }
                    #else
                    item.videoComposition = composition
                    self.installedComposition = composition
                    #endif
                }
                self.orientationPrepared = true
                self.attachOutput(to: item)
                self.onEvent?(.sourcePrepared, nil)
            } catch {
                guard !Task.isCancelled, let self, !self.invalidated, self.itemGeneration == generation,
                      self.currentItem === item else { return }
                self.onEvent?(.sourcePreparationFailed, (error as NSError).code)
            }
        }
        return ticket
    }

    /// Bind the selected audio timeline before any output pull. Ordinary polling
    /// can update this state, but cannot authorize a newly adopted presentation.
    @discardableResult
    func installTimeline(_ ticket: PresentationTicket, positionSeconds: Double,
                         durationSeconds: Double, isPlaying: Bool) -> Bool {
        guard owns(ticket) else { return false }
        presentationActive = false
        installedTimeline = nil
        stopFrameTimer()
        applyPlayback(positionSeconds: positionSeconds, durationSeconds: durationSeconds,
                      isPlaying: isPlaying, forceAnchor: true)
        guard owns(ticket) else { return false }
        installedTimeline = ticket
        return true
    }

    @discardableResult
    func activate(_ ticket: PresentationTicket) -> Bool {
        guard owns(ticket), installedTimeline == ticket, activeSeekTicket == nil else { return false }
        presentationActive = true
        renderFrame()
        if frameFeedEnabled && playbackState.read().isPlaying { startFrameTimer() }
        return true
    }

    private func owns(_ ticket: PresentationTicket) -> Bool {
        !invalidated && ticket.generation == presentationRevision
            && currentItem.map { ObjectIdentifier($0) == ticket.item } == true
    }

    private func attachOutput(to item: AVPlayerItem) {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        // The AVPlayer can continue to render its ordinary inline layer underneath this layer.
        output.suppressesPlayerRendering = false
        #if DEBUG
        debugTraceRender(.outputAttached) {
            item.add(output)
            videoOutput = output
        }
        #else
        item.add(output)
        videoOutput = output
        #endif
        renderFrame()
        if frameFeedEnabled && playbackState.read().isPlaying { startFrameTimer() }
    }

    /// Normalize the preferred source transform into actual output pixels. A layer-only transform
    /// would leave PiP free to display the unrotated pixels. Source frame timing and duration remain intact.
    static func makeVideoComposition(for asset: AVAsset) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: AVFoundationErrorDomain, code: -1)
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        try Task.checkCancellation()
        let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width > 0, bounds.height > 0, duration.isNumeric, CMTimeCompare(duration, .zero) > 0 else {
            throw NSError(domain: AVFoundationErrorDomain, code: -2)
        }
        // The asset properties supply the fallback cadence. A valid source ID tells the compositor
        // to use the source samples' timing, including variable frame rate, rather than inventing 30fps.
        let composition = AVMutableVideoComposition(propertiesOf: asset)
        composition.sourceTrackIDForFrameTiming = track.trackID
        composition.renderSize = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let normalized = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        layer.setTransform(normalized, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    private func restoreOriginalComposition() {
        if let installedComposition, currentItem?.videoComposition === installedComposition {
            currentItem?.videoComposition = originalComposition
        }
        installedComposition = nil
        originalComposition = nil
    }

    /// Position must come from the audio renderer, not the independently muted video player.
    func updatePlayback(positionSeconds: Double, durationSeconds: Double, isPlaying: Bool) {
        applyPlayback(positionSeconds: positionSeconds, durationSeconds: durationSeconds,
                      isPlaying: isPlaying, forceAnchor: false)
    }

    private func applyPlayback(positionSeconds: Double, durationSeconds: Double, isPlaying: Bool,
                               forceAnchor: Bool) {
        guard !invalidated else { return }
        let position = positionSeconds.isFinite ? max(0, positionSeconds) : 0
        let duration = durationSeconds.isFinite ? max(0, durationSeconds) : 0
        let previous = playbackState.read()
        playbackState.update(position: position, duration: duration, isPlaying: isPlaying)
        if let timebase {
            let current = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            if forceAnchor || !current.isFinite || abs(current - position) > 0.08 {
                flushForSeek()
                CMTimebaseSetTime(timebase, time: CMTime(seconds: position, preferredTimescale: 60_000))
            } else if previous.isPlaying != isPlaying || !isPlaying {
                CMTimebaseSetTime(timebase, time: CMTime(seconds: position, preferredTimescale: 60_000))
            }
            CMTimebaseSetRate(timebase, rate: isPlaying ? 1 : 0)
        }
        if previous.isPlaying != isPlaying || previous.duration != duration {
            controller?.invalidatePlaybackState()
        }
        if frameFeedEnabled && isPlaying && currentItem != nil { startFrameTimer() }
        else { stopFrameTimer() }
        renderFrame()
    }

    /// A seek starts a new frame epoch, including the image held by a paused timebase.
    func flushForSeek() {
        displayLayer.flushAndRemoveImage()
        lastEnqueuedTime = .invalid
        lastFramePositionSeconds = nil
        lastCopiedFramePositionSeconds = nil
        hasReportedFrameFailure = false
    }

    /// Stop pulls before native seeking can make its target available. Acquiring it
    /// before completion and then flushing would consume a paused one-shot frame.
    func beginSeek() -> UInt64 {
        seekTicket &+= 1
        activeSeekTicket = seekTicket
        #if DEBUG
        debugTraceRender(.seekBegin) { flushForSeek() }
        #else
        flushForSeek()
        #endif
        return seekTicket
    }

    func completeSeek(_ ticket: UInt64) {
        guard activeSeekTicket == ticket else { return }
        activeSeekTicket = nil
    }

    /// Call when video is intentionally disabled, even if audio remains active.
    func suspendFrameFeed() {
        frameFeedEnabled = false
        stopFrameTimer()
    }

    func resumeFrameFeed() {
        guard !invalidated else { return }
        frameFeedEnabled = true
        renderFrame()
        if playbackState.read().isPlaying && currentItem != nil { startFrameTimer() }
    }

    /// Release on the control thread. No audio session or audio renderer is touched.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        presentationActive = false
        installedTimeline = nil
        #if DEBUG
        onFrameAcquisition = nil
        onDebugRenderStamp = nil
        #endif
        activeSeekTicket = nil
        preparationTask?.cancel()
        preparationTask = nil
        stopFrameTimer()
        observations.removeAll()
        controller?.stopPictureInPicture()
        controller?.delegate = nil
        controller = nil
        if let videoOutput { currentItem?.remove(videoOutput) }
        restoreOriginalComposition()
        videoOutput = nil
        currentItem = nil
        displayLayer.flushAndRemoveImage()
        displayLayer.controlTimebase = nil
        timebase = nil
        format = nil
        onSetPlaying = nil
        onSkip = nil
        onRestoreUI = nil
        onStateChanged = nil
        onEvent = nil
    }

    private func startFrameTimer() {
        guard presentationActive, activeSeekTicket == nil, frameTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            // This timer is installed only on RunLoop.main. No per-frame task or queue is created.
            MainActor.assumeIsolated { self?.renderFrame() }
        }
        timer.tolerance = 1.0 / 120
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func renderFrame() {
        guard !invalidated, frameFeedEnabled, let videoOutput, let timebase else { return }
        #if DEBUG
        let debugSourceTicket = onDebugRenderStamp == nil ? nil
            : currentItem.map { PresentationTicket(generation: presentationRevision, item: ObjectIdentifier($0)) }
        #endif
        guard activeSeekTicket == nil else {
            #if DEBUG
            debugTraceRender(.seekBlocked, sourceTicket: debugSourceTicket)
            #endif
            blockedFrameAcquisitionCount &+= 1
            return
        }
        guard presentationActive else { return }
        #if DEBUG
        debugTraceRender(.attempt, sourceTicket: debugSourceTicket)
        #endif
        if displayLayer.status == .failed {
            if !hasReportedFrameFailure {
                onEvent?(.frameFailed, (displayLayer.error as NSError?)?.code)
                hasReportedFrameFailure = true
            }
            displayLayer.flushAndRemoveImage()
            lastEnqueuedTime = .invalid
        }
        // Respect platform backpressure. No app-owned pixel-buffer queue or decoded-frame history.
        guard displayLayer.isReadyForMoreMediaData else { return }
        let requestedTime = CMTimebaseGetTime(timebase)
        guard requestedTime.isNumeric else { return }
        #if DEBUG
        if let item = currentItem { onFrameAcquisition?(item, requestedTime) }
        #endif
        #if DEBUG
        let hasNew = videoOutput.hasNewPixelBuffer(forItemTime: requestedTime)
        debugTraceRender(hasNew ? .hasNewTrue : .hasNewFalse, requested: requestedTime, sourceTicket: debugSourceTicket)
        guard hasNew else { return }
        #else
        guard videoOutput.hasNewPixelBuffer(forItemTime: requestedTime) else { return }
        #endif
        var displayTime = CMTime.invalid
        guard let pixel = videoOutput.copyPixelBuffer(forItemTime: requestedTime,
                                                      itemTimeForDisplay: &displayTime) else { return }
        if !displayTime.isNumeric { displayTime = requestedTime }
        lastCopiedFramePositionSeconds = CMTimeGetSeconds(displayTime)
        #if DEBUG
        debugTraceRender(.copied, requested: requestedTime, sample: displayTime, sourceTicket: debugSourceTicket)
        #endif
        // A stopped clock cannot advance to a future sample. Do not let an output
        // replay from before a backwards seek pin this epoch ahead of its target.
        // Past samples remain valid for sources with long or variable frame durations.
        if !playbackState.read().isPlaying && CMTimeCompare(displayTime, requestedTime) > 0 {
            pausedFutureFrameRejectionCount &+= 1
            return
        }
        guard !lastEnqueuedTime.isNumeric || CMTimeCompare(displayTime, lastEnqueuedTime) > 0 else { return }
        // Never build a future presentation backlog if the video decoder runs ahead of audio.
        let lead = CMTimeGetSeconds(CMTimeSubtract(displayTime, requestedTime))
        guard lead.isFinite, lead <= 1.0 / 30 else { return }
        let width = CVPixelBufferGetWidth(pixel)
        let height = CVPixelBufferGetHeight(pixel)
        let pixelType = CVPixelBufferGetPixelFormatType(pixel)
        if format == nil || width != formatWidth || height != formatHeight || pixelType != formatPixelType {
            var createdFormat: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                      imageBuffer: pixel,
                                                                      formatDescriptionOut: &createdFormat)
            guard status == noErr, let createdFormat else { reportFrameFailure(status); return }
            format = createdFormat
            formatWidth = width
            formatHeight = height
            formatPixelType = pixelType
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: displayTime,
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                              imageBuffer: pixel,
                                                              formatDescription: format,
                                                              sampleTiming: &timing,
                                                              sampleBufferOut: &sample)
        guard status == noErr, let sample else { reportFrameFailure(status); return }
        displayLayer.enqueue(sample)
        lastEnqueuedTime = displayTime
        lastFramePositionSeconds = CMTimeGetSeconds(displayTime)
        submittedFrameCount &+= 1
        #if DEBUG
        debugTraceRender(.enqueued, requested: requestedTime, sample: displayTime, sourceTicket: debugSourceTicket)
        #endif
    }

    private func reportFrameFailure(_ status: OSStatus) {
        guard !hasReportedFrameFailure else { return }
        hasReportedFrameFailure = true
        onEvent?(.frameFailed, Int(status))
    }

    private func reportState() {
        guard !invalidated, let controller else { return }
        onStateChanged?(controller.isPictureInPictureActive, controller.isPictureInPicturePossible,
                        controller.isPictureInPictureSuspended)
    }

    // Kept separate from the Objective-C delegate entry points for deterministic native tests.
    func handleSetPlayingRequest(_ playing: Bool) {
        guard !invalidated else { return }
        onEvent?(playing ? .userPlayRequested : .userPauseRequested, nil)
        onSetPlaying?(playing)
    }

    func handleSkipRequest(_ seconds: Double, completion completionHandler: @escaping () -> Void) {
        let completion = ContinuousPiPVoidCompletion(completionHandler)
        guard !invalidated, seconds.isFinite, let skip = onSkip else { completion.call(); return }
        onEvent?(.userSkipRequested, nil)
        skip(seconds) { completion.call() }
    }

    func handleRestoreUIRequest(completion completionHandler: @escaping (Bool) -> Void) {
        let completion = ContinuousPiPBoolCompletion(completionHandler)
        guard !invalidated, let restore = onRestoreUI else {
            onEvent?(.restoreUnavailable, nil)
            completion.call(false)
            return
        }
        onEvent?(.restoreRequested, nil)
        restore { [weak self] restored in
            guard completion.call(restored) else { return }
            self?.onEvent?(restored ? .restoreCompleted : .restoreUnavailable, nil)
        }
    }
}

extension ContinuousPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                setPlaying playing: Bool) {
        Task { @MainActor [weak self] in
            self?.handleSetPlayingRequest(playing)
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        let completion = ContinuousPiPVoidCompletion(completionHandler)
        let seconds = CMTimeGetSeconds(skipInterval)
        Task { @MainActor [weak self] in
            guard let self else { completion.call(); return }
            self.handleSkipRequest(seconds) { completion.call() }
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !playbackState.read().isPlaying
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let state = playbackState.read()
        let duration = max(state.duration, state.position + 1.0 / 600)
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60_000))
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }
}

extension ContinuousPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.onEvent?(.willStart, nil); self?.reportState() }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.onEvent?(.didStart, nil); self?.reportState() }
    }
    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.onEvent?(.willStop, nil); self?.reportState() }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.onEvent?(.didStop, nil); self?.reportState() }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        let code = (error as NSError).code
        Task { @MainActor [weak self] in self?.onEvent?(.startFailed, code); self?.reportState() }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        let completion = ContinuousPiPBoolCompletion(completionHandler)
        Task { @MainActor [weak self] in
            guard let self else { completion.call(false); return }
            self.handleRestoreUIRequest { completion.call($0) }
        }
    }
}

// AVKit's synchronous state queries never block on the main queue. This is a control-thread
// lock, wholly outside the audio render path; it protects only three scalar values.
private final class ContinuousPiPPlaybackState: @unchecked Sendable {
    struct State { var position = 0.0; var duration = 0.0; var isPlaying = false }
    private let lock = NSLock()
    private var state = State()
    func update(position: Double, duration: Double, isPlaying: Bool) {
        lock.lock(); defer { lock.unlock() }
        state = State(position: position, duration: duration, isPlaying: isPlaying)
    }
    func read() -> State { lock.lock(); defer { lock.unlock() }; return state }
}

private final class ContinuousPiPVoidCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func call() {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?()
    }
}

private final class ContinuousPiPBoolCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Bool) -> Void)?
    init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
    @discardableResult func call(_ value: Bool) -> Bool {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?(value)
        return callback != nil
    }
}
