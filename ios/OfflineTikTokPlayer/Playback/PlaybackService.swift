import Foundation
import AVFoundation
import AVKit
import MediaPlayer
import Observation
import PlayerCore
import UIKit
import os

@MainActor @Observable
final class PlaybackClock {
    private var timeline = PlaybackTimeline()
    var position: Double { timeline.position }
    var duration: Double { timeline.duration }
    func reset(position: Double, duration: Double) { timeline.reset(position: position, duration: duration) }
    func updateDuration(_ seconds: Double) { timeline.updateDuration(seconds) }
    func sample(position: Double) { timeline.sample(position: position) }
    func beginSeek(to seconds: Double) -> PlaybackTimeline.Seek? { timeline.beginSeek(to: seconds) }
    func completeSeek(_ seek: PlaybackTimeline.Seek, actualPosition: Double) -> Bool {
        timeline.completeSeek(seek, actualPosition: actualPosition)
    }
}

@MainActor @Observable
final class PlaybackService: NSObject {
    struct PlaybackEvent {
        let name: String
        let uptime: Double
        let generation: Int
        let position: Double
        let retainedItems: Int
    }
    typealias SeekPlayer = (AVQueuePlayer, CMTime, @escaping (Bool) -> Void) -> Void
    typealias SeekVideo = @MainActor (AVPlayer, CMTime, @escaping @Sendable (Bool) -> Void) -> Void
    #if DEBUG
    @ObservationIgnored var debugUsesCurrentCustomFrameForReadiness = false
    // One synchronous notification per start, no retained event history or SDK reads.
    struct DebugFrameMonitorReadBatch {
        let request: Int, generation: Int
        let sourceItemMatches: Bool, observedItemMatches: Bool, presentationMatches: Bool
        let selectedMatchesQueue: Bool
        let cachedAudioToken: Int, cachedAudioVisit: Int64
        let reads: PlaybackFrameMonitor.DebugReadBatch
    }
    @ObservationIgnored var onDebugFrameMonitorReadBatch: ((DebugFrameMonitorReadBatch) -> Void)? {
        didSet {
            if onDebugFrameMonitorReadBatch == nil { frameMonitor.onDebugReadBatch = nil }
        }
    }
    @ObservationIgnored var debugAfterFirstFrameMonitorStart: ((AVPlayerItem) -> Void)?
    enum DebugInitialLoadPhase: Int, Sendable {
        case idle = 0, savedLookup = 1, cachedLookupAndResolution = 2, localResolved = 3
        case audioPrepare = 4, audioPrepared = 5, bufferReplaceAndObserve = 6, observedCurrent = 7, error = 8
    }
    struct DebugInitialLoadPhaseState: Sendable {
        let enabled: Bool
        let request: Int
        let generation: Int
        let phase: DebugInitialLoadPhase
    }
    @ObservationIgnored var debugInitialLoadPhaseEnabled = false
    @ObservationIgnored private var debugInitialLoadPhaseRequest = 0
    @ObservationIgnored private var debugInitialLoadPhase: DebugInitialLoadPhase = .idle
    var debugInitialLoadPhaseState: DebugInitialLoadPhaseState {
        DebugInitialLoadPhaseState(enabled: debugInitialLoadPhaseEnabled,
            request: debugInitialLoadPhaseRequest, generation: generation, phase: debugInitialLoadPhase)
    }
    private func debugMarkInitialLoadPhase(_ phase: DebugInitialLoadPhase, request: Int) {
        guard debugInitialLoadPhaseEnabled, generation == request else { return }
        debugInitialLoadPhaseRequest = request
        debugInitialLoadPhase = phase
    }

    enum DebugVideoSeekReason: Int, Sendable {
        case unattributed = 0, readyRestore = 1, readyRewind = 2, sourceVisit = 3, drift = 4
        case userPausedSeek = 5, latestPausedTarget = 6, foreground = 7
        case pipRestore = 8, surfaceRestore = 9, preparedPausedSource = 10
    }
    struct DebugVideoSeekStamp: Sendable {
        let reason: DebugVideoSeekReason
        let request: Int
        let generation: Int
        // Application-owned ticket guarding this native seek, not an SDK ID.
        let nativeSeekTicket: UInt64
        let requestedPosition: Double
        let force: Bool
        // The existing ordinary-drift guard read; forced requests do not read it.
        let ordinaryDriftVideoPositionSeconds: Double?
        let ordinaryDriftReadEntryNs: UInt64?
        let ordinaryDriftReadReturnNs: UInt64?
        // Cached actor-owned state, not another renderer/native snapshot.
        let cachedSelected: Bool
        let selectedMatchesQueue: Bool
        let cachedAudioToken: Int
        let cachedAudioVisit: Int64
        let observedItemMatches: Bool
        let presentationRequestMatches: Bool
        let readyGeneration: Int?
        let pendingAudioSeek: Bool
        let audioLoading: Bool
        let canPlay: Bool
        let videoAllowed: Bool
    }
    @ObservationIgnored var onDebugVideoSeekStamp: ((DebugVideoSeekStamp) -> Void)?
    @ObservationIgnored private var debugVideoSeekReason: DebugVideoSeekReason = .unattributed
    enum DebugVideoStartupKind: Int, Sendable {
        case itemReadyEvent = 0, setRate = 1, playImmediately = 2, startSkipped = 3, firstFrameEvent = 4, readyAccepted = 5
    }
    struct DebugVideoStartupStamp: Sendable {
        let kind: DebugVideoStartupKind
        let request: Int, entryGeneration: Int, returnGeneration: Int
        let entryNs: UInt64, returnNs: UInt64
        let presentationRequest: Int?, presentationUnchanged: Bool
        let audioToken: Int, audioVisit: Int64, readyGeneration: Int?
        let entryVideoReady: Bool, returnVideoReady: Bool, entryLoading: Bool, returnLoading: Bool
        let timelineInstalled: Bool, anchorHostSeconds: Double?, anchorPosition: Double?
    }
    @ObservationIgnored var onDebugVideoStartupStamp: ((DebugVideoStartupStamp) -> Void)?
    struct DebugVideoRenderStamp: Sendable {
        let render: ContinuousPictureInPicture.DebugRenderStamp
        let generation: Int, presentationRequest: Int?
        let presentationMatches: Bool
        let audioToken: Int, audioVisit: Int64
    }
    @ObservationIgnored var onDebugVideoRenderStamp: ((DebugVideoRenderStamp) -> Void)? {
        didSet {
            guard onDebugVideoRenderStamp != nil else { continuousPiP.onDebugRenderStamp = nil; return }
            continuousPiP.onDebugRenderStamp = { [weak self] stamp in
                guard let self, let observer = self.onDebugVideoRenderStamp else { return }
                observer(DebugVideoRenderStamp(render: stamp, generation: self.generation,
                    presentationRequest: self.videoPresentation?.request,
                    presentationMatches: self.videoPresentation?.ticket == stamp.ticket,
                    audioToken: self.audioToken, audioVisit: self.audioVisit))
            }
        }
    }
    private func debugTraceVideoStartup(_ kind: DebugVideoStartupKind, request: Int,
        installed: Bool = false, anchorHostSeconds: Double? = nil, anchorPosition: Double? = nil,
        _ operation: () -> Void) {
        guard let observer = onDebugVideoStartupStamp else { operation(); return }
        let entryGeneration = generation, presentation = videoPresentation
        let token = audioToken, visit = audioVisit, ready = readyGeneration
        let videoReady = isVideoReady, loading = isLoading
        let entered = DispatchTime.now().uptimeNanoseconds
        operation()
        let returned = DispatchTime.now().uptimeNanoseconds
        observer(DebugVideoStartupStamp(kind: kind, request: request,
            entryGeneration: entryGeneration, returnGeneration: generation, entryNs: entered, returnNs: returned,
            presentationRequest: presentation?.request,
            presentationUnchanged: presentation != nil && presentation?.request == videoPresentation?.request
                && presentation?.ticket == videoPresentation?.ticket,
            audioToken: token, audioVisit: visit, readyGeneration: ready,
            entryVideoReady: videoReady, returnVideoReady: isVideoReady,
            entryLoading: loading, returnLoading: isLoading, timelineInstalled: installed,
            anchorHostSeconds: anchorHostSeconds, anchorPosition: anchorPosition))
    }
    struct DebugInitialVideoReadyState: Sendable {
        let audioVisit: Int64
        let readyGeneration: Int?
        let generation: Int
        let syncingVideoGeneration: Int?
    }
    // Timing-only seam: nil preserves the original callback path without an await.
    @ObservationIgnored var onDebugInitialVideoReady: (@MainActor (Int) async -> Void)? = nil
    // Timing-only control of service adoption; the real renderer and ready callback continue.
    @ObservationIgnored var shouldDebugDeferAudioVisit: (@MainActor (Int) -> Bool)? = nil
    var debugInitialVideoReadyState: DebugInitialVideoReadyState {
        DebugInitialVideoReadyState(audioVisit: audioVisit, readyGeneration: readyGeneration,
            generation: generation, syncingVideoGeneration: syncingVideoGeneration)
    }
    #endif
    private static let playbackLog = OSLog(subsystem: "OfflineTikTokPlayer", category: "Playback")
    @ObservationIgnored var onPlaybackEvent: ((PlaybackEvent) -> Void)?
    @ObservationIgnored private var firstProgressGeneration: Int?
    var player: AVQueuePlayer { buffer.player }
    let clock = PlaybackClock()
    private(set) var queue = PlaybackQueue(ids: [])
    private var intent = PlaybackIntent()
    var wantsToPlay: Bool { intent.canPlay }
    private(set) var isLoading = false
    private(set) var isVideoReady = false
    private(set) var hasAudioTrack: Bool?
    var message: String?
    var isInteractingWithFeed = false {
        didSet { updateAudioSuccessor() }
    }
    var speakerSound: Bool {
        didSet { UserDefaults.standard.set(speakerSound, forKey: "speakerSound"); refreshAudioProcessing() }
    }
    var automaticPiP: Bool {
        didSet { pip?.canStartPictureInPictureAutomaticallyFromInline = automaticPiP && presentationPolicy.allowsPictureInPicture; UserDefaults.standard.set(automaticPiP, forKey: "automaticPiP") }
    }
    var audioOnly = false {
        didSet {
            applyPresentation(presentationPolicy.setAudioOnly(audioOnly))
            recordDiagnostic(audioOnly ? .audioOnlySelected : .videoSelected)
        }
    }
    @ObservationIgnored private var presentationPolicy = PlaybackPresentationPolicy()
    @ObservationIgnored private var diagnostics = PlaybackDiagnosticJournal(capacity: 128)
    #if DEBUG
    /// Existing cached journal only: no SDK reads, clocks, file export or new entry.
    var debugCachedPlaybackDiagnostics: PlaybackDiagnosticJournal.DebugCachedSnapshot {
        diagnostics.debugCachedSnapshot
    }
    #endif
    @ObservationIgnored private let continuousPiP = ContinuousPictureInPicture()
    @ObservationIgnored private var pipSkipCompletion: (() -> Void)?
    @ObservationIgnored private var pipSkipDeadline = 0.0
    @ObservationIgnored private var lastUnderrun: Int64 = 0
    private var videoAllowed: Bool { presentationPolicy.presentation != .audioOnly }
    @ObservationIgnored var requestPlayerUI: (() -> Void)?
    @ObservationIgnored private(set) var surface: PlayerSurface!
    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private let library: LibraryRepository
    @ObservationIgnored private let downloads: OfflineDownloads
    @ObservationIgnored private let cloud: OneDriveClient
    @ObservationIgnored private let buffer: PlaybackBuffer
    @ObservationIgnored private let continuousAudio: ContinuousAudioPlayer
    @ObservationIgnored private var audioPollTask: Task<Void, Never>?
    @ObservationIgnored private var audioVisit: Int64 = -1
    @ObservationIgnored private var audioToken = 0
    @ObservationIgnored private var syncingVideoGeneration: Int?
    @ObservationIgnored private var audioLoadingID: String?
    @ObservationIgnored private var pendingAudioSeek: (seek: PlaybackTimeline.Seek, version: Int)?
    var audioSnapshot: ContinuousPCMRenderer.Snapshot { continuousAudio.snapshot }
    var videoFramePositionSeconds: Double? { continuousPiP.lastFramePositionSeconds }
    var copiedVideoFramePositionSeconds: Double? { continuousPiP.lastCopiedFramePositionSeconds }
    var pausedFutureVideoFrameRejectionCount: UInt64 { continuousPiP.pausedFutureFrameRejectionCount }
    var videoFrameAcquisitionBlockedCount: UInt64 { continuousPiP.blockedFrameAcquisitionCount }
    var submittedVideoFrameCount: UInt64 { continuousPiP.submittedFrameCount }
    var videoRequestedPositionSeconds: Double { continuousPiP.requestedPositionSeconds }
    var videoTimebasePositionSeconds: Double? { continuousPiP.timebasePositionSeconds }
    var preparedAudioCount: Int { continuousAudio.preparedCount }
    var audioEngineRunning: Bool { continuousAudio.graph.engine.isRunning }
    var audioRenderQuantumFrames: Int { continuousAudio.graph.maximumRenderFrameCount }
    @ObservationIgnored private let mediaCache: PlaybackMediaCache?
    @ObservationIgnored private var warmTask: Task<Void, Never>?
    @ObservationIgnored private var warmRevision = 0
    @ObservationIgnored private weak var observedItem: AVPlayerItem?
    @ObservationIgnored private var videoPresentation: (request: Int, ticket: ContinuousPictureInPicture.PresentationTicket)?
    @ObservationIgnored private var pendingInitialZeroStart: (request: Int, ticket: ContinuousPictureInPicture.PresentationTicket)?
    private struct InitialZeroVisitOwnership {
        let request: Int
        let mediaID: String
        let token: Int
        let baselineVisit: Int64
        var ticket: ContinuousPictureInPicture.PresentationTicket?
    }
    // One record: a successful zero-selection candidate becomes an item-ticket owner.
    @ObservationIgnored private var initialZeroVisitOwnership: InitialZeroVisitOwnership?
    @ObservationIgnored private var explicitVideoSeekGeneration: Int?
    @ObservationIgnored private var readyGeneration: Int?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private let frameMonitor = PlaybackFrameMonitor()
    @ObservationIgnored private let speakerAudio: SpeakerAudioController
    @ObservationIgnored private let audioRoutes: () -> [AVAudioSession.Port]
    @ObservationIgnored private let seekPlayer: SeekPlayer
    @ObservationIgnored private let seekVideo: SeekVideo
    @ObservationIgnored private var audioCheckTask: Task<Void, Never>?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var remoteRetries = Set<String>()
    @ObservationIgnored private var currentIsLocal = false
    @ObservationIgnored private var endedDuringScroll = false
    @ObservationIgnored private var reachedPreparedEnd = false
    @ObservationIgnored private var lastBookmark = Date.distantPast
    private let bookmarkURL: URL
    @ObservationIgnored private let activateSession: () throws -> Void

    var current: MediaRecord? { queue.currentID.flatMap { library.catalog.mediaByID[$0] } }
    var previousID: String? { queue.previewPrevious() }
    var nextID: String? { queue.previewNext() }

    init(library: LibraryRepository, downloads: OfflineDownloads, cloud: OneDriveClient,
         bookmarkURL: URL = AppFiles.root.appendingPathComponent("playback.json"),
         activateSession: @escaping () throws -> Void = { try AVAudioSession.sharedInstance().setActive(true) },
         buffer: PlaybackBuffer? = nil, continuousAudio: ContinuousAudioPlayer? = nil,
         speakerAudio: SpeakerAudioController? = nil,
         audioRoutes: @escaping () -> [AVAudioSession.Port] = { AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType) },
         seekPlayer: @escaping SeekPlayer = { player, time, completion in
             player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: completion)
         },
         seekVideo: @escaping SeekVideo = { player, time, completion in
             player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: completion)
         }) {
        self.library = library; self.downloads = downloads; self.cloud = cloud
        self.continuousAudio = continuousAudio ?? ContinuousAudioPlayer()
        self.bookmarkURL = bookmarkURL; self.activateSession = activateSession
        self.buffer = buffer ?? PlaybackBuffer()
        self.speakerAudio = speakerAudio ?? SpeakerAudioController()
        self.audioRoutes = audioRoutes; self.seekPlayer = seekPlayer
        self.seekVideo = seekVideo
        mediaCache = PlaybackCacheLoader.make(cloud: cloud)
        automaticPiP = UserDefaults.standard.bool(forKey: "automaticPiP")
        speakerSound = UserDefaults.standard.object(forKey: "speakerSound") as? Bool ?? true
        super.init()
        self.continuousAudio.onSourceSilence { [weak self] _, analysis in
            Task { @MainActor in self?.recordDiagnostic(.sourceTimelineAnalyzed, sourceSilence: analysis) }
        }
        self.continuousAudio.onDecodeFailure { [weak self] token, _ in
            Task { @MainActor in
                guard let self else { return }
                let selected = self.continuousAudio.invalidateForRetry(token: token)
                self.recordDiagnostic(.sourcePreparationFailed)
                self.updateAudioSuccessor()
                if selected {
                    if let pending = self.pendingAudioSeek {
                        _ = self.clock.completeSeek(pending.seek, actualPosition: self.clock.position)
                        self.pendingAudioSeek = nil; self.completePiPSkip()
                    }
                    self.pause(); self.recordPlaybackEvent("decodeFailed")
                    self.message = "Audio could not be decoded. Choose another video or tap Play to retry."
                }
            }
        }
        surface = PlayerSurface(player: player)
        player.isMuted = true
        self.buffer.automaticAdvancementEnabled = false
        self.buffer.usesExternalClock = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        self.buffer.didAdvance = { [weak self] prepared in
            guard let self else { return }
            // Muted video never owns the audio queue. A delayed visual KVO event
            // cannot advance (or pause) the sample timeline.
            if self.continuousAudio.isSelected { return }
            var advanced = self.queue
            guard advanced.next(explicit: false) == prepared.mediaID else {
                self.player.pause(); self.loadCurrent(position: self.clock.position); return
            }
            self.queue = advanced
            self.loadCurrent(adopting: prepared)
        }
        surface.attachPiPDisplayLayer(continuousPiP.displayLayer)
        pip = continuousPiP.controller
        pip?.canStartPictureInPictureAutomaticallyFromInline = automaticPiP
        continuousPiP.onSetPlaying = { [weak self] playing in
            if playing { self?.play() } else { self?.pause() }
        }
        continuousPiP.onSkip = { [weak self] seconds, completion in
            guard let self else { completion(); return }
            self.pipSkipCompletion?()
            self.pipSkipCompletion = completion
            self.pipSkipDeadline = ProcessInfo.processInfo.systemUptime + 1
            self.seek(self.clock.position + seconds)
            if self.pendingAudioSeek == nil { self.completePiPSkip() }
        }
        continuousPiP.onRestoreUI = { [weak self] completion in
            guard let self, let restore = self.requestPlayerUI else { completion(false); return }
            restore()
            DispatchQueue.main.async { [weak self] in
                #if DEBUG
                self?.synchronizeVideoToAudio(force: true, reason: .pipRestore)
                #else
                self?.synchronizeVideoToAudio(force: true)
                #endif
                completion(self?.surface.window != nil)
            }
        }
        continuousPiP.onStateChanged = { [weak self] _, _, _ in self?.samplePiPState() }
        continuousPiP.onEvent = { [weak self] event, code in self?.handlePiPEvent(event, code: code) }
        configureAudio(); installObservers(); installRemoteControls()
        audioPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.sampleContinuousAudio()
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let item = self.observedItem, self.player.currentItem === item else { return }
                guard !self.continuousAudio.isSelected else { return }
                // Read the current item now: an already queued callback can belong to the old item.
                self.clock.sample(position: item.currentTime().seconds)
                if self.firstProgressGeneration != self.generation, item.currentTime().seconds >= 0.05 {
                    self.firstProgressGeneration = self.generation; self.recordPlaybackEvent("clock50ms")
                }
                if Date().timeIntervalSince(self.lastBookmark) > 5 { self.persist(); self.updateNowPlaying() }
            }
        }
    }

    func restore() {
        guard queue.currentID == nil, let data = try? Data(contentsOf: bookmarkURL),
              let bookmark = try? PlaybackBookmark.restore(data, availableIDs: Set(library.catalog.queue(playlistIDs: [], localIDs: downloads.readyIDs))) else { return }
        queue = bookmark.queue; intent.pause()
        loadCurrent(position: bookmark.position)
    }

    func start(playlistIDs: [String], at mediaID: String? = nil, shuffle: Bool = false, offlineOnly: Bool = false) {
        recordPlaybackEvent("start")
        let ids = library.catalog.queue(playlistIDs: playlistIDs, localIDs: downloads.readyIDs,
            offlineOnly: offlineOnly || !downloads.network.isConnected)
        guard !ids.isEmpty else { message = "No playable videos here yet. Download this playlist or import local videos."; return }
        let repeatMode = queue.repeatMode
        queue = PlaybackQueue(ids: ids, startAt: mediaID, shuffle: shuffle)
        queue.repeatMode = repeatMode
        intent.requestPlay(); remoteRetries.removeAll(); message = nil
        activateAudio(); loadCurrent()
    }

    func toggle() { wantsToPlay ? pause() : play() }
    func play() {
        guard current != nil else { return }
        intent.requestPlay(); activateAudio()
        recordDiagnostic(.playRequested)
        resumeContinuousAudio()
        if intent.canPlay, resumeAfterPreparedEnd() { return }
        if player.currentItem == nil || !continuousAudio.isSelected { loadCurrent(position: clock.position) }
        else {
            if clock.duration > 0, clock.position >= clock.duration { seek(0) }
            else if intent.canPlay, videoAllowed { player.play() }
            prepareUpcoming()
            if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { armStallRecovery() }
        }
        persist(); updateNowPlaying()
    }
    func pause() {
        intent.pause()
        recordDiagnostic(.pauseRequested)
        continuousAudio.suspend()
        continuousPiP.updatePlayback(positionSeconds: clock.position, durationSeconds: clock.duration, isPlaying: false)
        cancelStallRecovery()
        player.pause(); persist(); updateNowPlaying()
    }

    #if DEBUG
    /// Test teardown only. Join the currently owned tasks as well as the decoder's
    /// queued cleanup; neither acknowledgement proves SDK-internal quiescence.
    func debugStopPreparation(_ completion: @escaping @Sendable () -> Void) {
        generation += 1; warmRevision += 1
        observedItem = nil; itemObservation = nil; readyGeneration = nil
        let tasks = [loadTask, warmTask, audioCheckTask, audioPollTask, stallTask].compactMap { $0 }
        loadTask = nil; warmTask = nil; audioCheckTask = nil; audioPollTask = nil; stallTask = nil
        for task in tasks { task.cancel() }
        Task {
            for task in tasks { await task.value }
            completion()
        }
    }
    #endif

    func next(explicit: Bool = true) {
        let previousVisit = audioVisit
        sampleContinuousAudio(handleEnd: false)
        if !explicit, audioVisit != previousVisit { return }
        recordPlaybackEvent("next")
        recordDiagnostic(.nextRequested)
        buffer.synchronize()
        endedDuringScroll = false
        let previous = queue.currentID
        guard let next = queue.next(explicit: explicit) else { pause(); return }
        if explicit { intent.requestPlay(); activateAudio() }
        if next == previous, player.currentItem != nil {
            if let prepared = buffer.advance(to: next) { loadCurrent(adopting: prepared) }
            else { seek(0) }
            return
        }
        loadCurrent()
    }

    func previous() {
        sampleContinuousAudio(handleEnd: false)
        recordPlaybackEvent("previous")
        recordDiagnostic(.previousRequested)
        buffer.synchronize()
        endedDuringScroll = false
        guard queue.previous() != nil else { seek(0); return }
        intent.requestPlay(); activateAudio(); loadCurrent()
    }

    func feedDidSettle(direction: Int) {
        isInteractingWithFeed = false
        if direction > 0 { next() }
        else if direction < 0 { previous() }
        else if endedDuringScroll { next(explicit: false) }
    }

    func setShuffle(_ enabled: Bool) { sampleContinuousAudio(handleEnd: false); buffer.synchronize(); queue.setShuffle(enabled); prepareUpcoming(); persist() }
    func cycleRepeat() { sampleContinuousAudio(handleEnd: false); buffer.synchronize(); queue.repeatMode = queue.repeatMode.next; prepareUpcoming(); persist() }
    func seek(_ seconds: Double) {
        explicitVideoSeekGeneration = generation
        pendingInitialZeroStart = nil
        initialZeroVisitOwnership = nil
        if continuousAudio.isSelected, let seek = clock.beginSeek(to: seconds),
           let version = continuousAudio.seek(seek.target) {
            pendingAudioSeek = (seek, version)
            recordDiagnostic(.seekRequested)
            if !intent.canPlay {
                _ = clock.completeSeek(seek, actualPosition: seek.target)
                pendingAudioSeek = nil
                #if DEBUG
                synchronizeVideoToAudio(force: true, reason: .userPausedSeek)
                #else
                synchronizeVideoToAudio(force: true)
                #endif
                completePiPSkip()
            }
            persist(); updateNowPlaying()
            return
        }
        guard let item = player.currentItem, item === observedItem,
              let seek = clock.beginSeek(to: seconds) else { return }
        let request = generation
        continuousAudio.seek(seek.target)
        recordDiagnostic(.seekRequested)
        recordPlaybackEvent("seekRequested")
        seekPlayer(player, CMTime(seconds: seek.target, preferredTimescale: 600)) { [weak self, weak item] finished in
            Task { @MainActor in
                guard let self, let item, finished, self.generation == request, self.player.currentItem === item,
                      self.clock.completeSeek(seek, actualPosition: item.currentTime().seconds) else { return }
                if !self.isVideoReady { self.monitorFirstFrame(item, request: request) }
                self.recordPlaybackEvent("seekCompleted")
                // The latest seek inherits playback intent when it supersedes a
                // paused startup rewind. Explicit Pause/interruption still wins.
                if self.intent.canPlay {
                    self.resumeContinuousAudio()
                    if self.videoAllowed { self.player.playImmediately(atRate: 1) }
                }
                self.persist(); self.updateNowPlaying()
            }
        }
        persist(); updateNowPlaying()
    }

    private func loadCurrent(position: Double = 0, forceRemote: Bool = false, adopting: PlaybackBuffer.Prepared? = nil,
                             audioAlreadySelected: Bool = false) {
        pendingAudioSeek = nil; completePiPSkip()
        pendingInitialZeroStart = nil
        initialZeroVisitOwnership = nil
        if !audioAlreadySelected { audioLoadingID = queue.currentID }
        reachedPreparedEnd = adopting?.reachedEnd ?? false
        if reachedPreparedEnd {
            var following = queue
            if following.next(explicit: false) != nil {
                if intent.canPlay { queue = following; loadCurrent(); return }
            } else { intent.pause(); player.pause() }
        }
        endedDuringScroll = false
        let resume = MediaResumePosition(mediaID: queue.currentID, seconds: position)
        generation += 1; let request = generation
        #if DEBUG
        debugMarkInitialLoadPhase(.idle, request: request)
        #endif
        recordPlaybackEvent("loadRequested")
        cancelStallRecovery()
        loadTask?.cancel(); itemObservation = nil; frameMonitor.cancel(); observedItem = nil; readyGeneration = nil
        videoPresentation = nil
        audioCheckTask?.cancel(); hasAudioTrack = nil
        isVideoReady = false
        if intent.canPlay { message = nil }
        warmTask?.cancel()
        clock.reset(position: position, duration: current?.duration ?? 0)
        isLoading = true
        let allowRemote = downloads.network.isConnected && !downloads.readyIDs.contains(queue.currentID ?? "")
        continuousAudio.setWindow(Set([queue.currentID, previousID, nextID].compactMap { $0 }))
        // An automatic AVQueuePlayer advance must obey the same Saved/offline
        // eligibility as an explicit handoff. Re-resolve a rejected remote stage.
        let eligibleAdoption = adopting.flatMap { $0.isLocal || allowRemote ? $0 : nil }
        let selectedAtRequest = !forceRemote && !audioAlreadySelected && queue.currentID.flatMap { continuousAudio.entry(for: $0) } != nil
        if selectedAtRequest, let id = queue.currentID {
            selectContinuousAudio(id: id, position: position)
            resumeContinuousAudio()
        }
        if !forceRemote, let id = queue.currentID, continuousAudio.entry(for: id) != nil,
           let prepared = eligibleAdoption ?? buffer.advance(to: id, allowRemote: allowRemote) {
            currentIsLocal = prepared.isLocal
            resumeContinuousAudio()
            recordPlaybackEvent("preparedAdoption")
            observeCurrent(prepared.item, position: position, request: request, rewind: prepared.needsRewind)
            prepareUpcoming()
            return
        }
        if !selectedAtRequest && !audioAlreadySelected { continuousAudio.clearSelection() }
        player.pause(); buffer.replace(with: nil)
        loadTask = Task { [weak self] in
            guard let self else { return }
            var visited = Set<String>()
            while let item = self.current, visited.insert(item.id).inserted {
                let itemPosition = resume.seconds(for: item.id)
                self.clock.reset(position: itemPosition, duration: item.duration)
                do {
                    #if DEBUG
                    self.debugMarkInitialLoadPhase(.savedLookup, request: request)
                    #endif
                    let saved = await self.downloads.localURL(for: item)
                    #if DEBUG
                    self.debugMarkInitialLoadPhase(.cachedLookupAndResolution, request: request)
                    #endif
                    let cached: URL?
                    if let asset = item.asset { cached = await self.mediaCache?.file(for: asset) } else { cached = nil }
                    var local = saved ?? cached
                    // AVAssetReader prepares only verified local media. A cold
                    // network selection must download before it can be gapless.
                    if local == nil, let asset = item.asset, self.downloads.network.isConnected {
                        let pinned = [self.current, self.previousID.flatMap { self.library.catalog.mediaByID[$0] },
                                      self.nextID.flatMap { self.library.catalog.mediaByID[$0] }].compactMap { $0?.asset }
                        await self.mediaCache?.setWindow(pinned, revision: self.warmRevision)
                        local = await self.mediaCache?.prefetch(asset, revision: self.warmRevision)
                    }
                    let url: URL
                    if let local { url = local }
                    else {
                        throw AppError.message("This video must finish preparing before playback.")
                    }
                    #if DEBUG
                    self.debugMarkInitialLoadPhase(.localResolved, request: request)
                    #endif
                    try Task.checkCancellation()
                    guard self.generation == request else { return }
                    self.currentIsLocal = local != nil
                    let playerItem = AVPlayerItem(url: url)
                    playerItem.preferredForwardBufferDuration = 8
                    #if DEBUG
                    self.debugMarkInitialLoadPhase(.audioPrepare, request: request)
                    #endif
                    _ = try await self.continuousAudio.prepare(id: item.id, url: url, currentPriority: true)
                    #if DEBUG
                    self.debugMarkInitialLoadPhase(.audioPrepared, request: request)
                    #endif
                    try Task.checkCancellation()
                    guard self.generation == request else { return }
                    if !audioAlreadySelected && !selectedAtRequest { self.selectContinuousAudio(id: item.id, position: itemPosition) }
                    self.resumeContinuousAudio()
                    self.recordPlaybackEvent("coldAudioPrepared")
                    // Audio starts first; video setup still commits before this item joins the queue.
                    let videoPreparation = try? await ContinuousPictureInPicture.prepareVideoResource(for: playerItem)
                    guard !Task.isCancelled, self.generation == request else { return }
                    #if DEBUG
                    self.debugMarkInitialLoadPhase(.bufferReplaceAndObserve, request: request)
                    #endif
                    guard self.buffer.replace(with: playerItem, mediaID: item.id, isLocal: local != nil,
                        videoPreparation: videoPreparation, ifEligible: {
                            !Task.isCancelled && self.generation == request
                        }) else { return }
                    self.observeCurrent(playerItem, position: itemPosition, request: request)
                    #if DEBUG
                    self.debugMarkInitialLoadPhase(.observedCurrent, request: request)
                    #endif
                    self.prepareUpcoming()
                    self.persist(); return
                } catch is CancellationError { return }
                catch ContinuousPCMDecoder.Failure.cancelled {
                    guard self.generation == request, !Task.isCancelled else { return }
                    #if DEBUG
                    self.debugMarkInitialLoadPhase(.error, request: request)
                    #endif
                    self.loadCurrent(position: itemPosition)
                    return
                }
                catch ContinuousAudioPlayer.PreparationError.windowBusy {
                    guard self.generation == request else { return }
                    #if DEBUG
                    self.debugMarkInitialLoadPhase(.error, request: request)
                    #endif
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard self.generation == request else { return }
                    self.loadCurrent(position: itemPosition)
                    return
                }
                catch {
                    guard self.generation == request, !Task.isCancelled else { return }
                    #if DEBUG
                    self.debugMarkInitialLoadPhase(.error, request: request)
                    #endif
                    self.continuousAudio.clearSelection()
                    self.audioLoadingID = nil; self.isLoading = false
                    self.pause()
                    self.recordDiagnostic(.sourcePreparationFailed)
                    self.message = "This video could not be prepared. Tap Play to retry or choose another video."
                    return
                }
            }
            guard self.generation == request else { return }
            #if DEBUG
            self.debugMarkInitialLoadPhase(.error, request: request)
            #endif
            self.isLoading = false; self.pause()
            self.message = "No available videos in this queue. Connect to your library or choose downloaded videos."
        }
    }

    private func observeCurrent(_ playerItem: AVPlayerItem, position: Double, request: Int, rewind: Bool = false) {
        observedItem = playerItem
        videoPresentation = continuousPiP.setCurrentItem(playerItem,
            preparedVideo: buffer.resource(for: playerItem)).map { (request, $0) }
        if position == 0, !rewind, explicitVideoSeekGeneration != request,
           let ticket = currentVideoPresentation(for: playerItem, request: request) {
            pendingInitialZeroStart = (request, ticket)
            if var owner = initialZeroVisitOwnership, owner.request == request,
               owner.mediaID == queue.currentID,
               continuousAudio.entry(for: owner.mediaID)?.token == owner.token {
                owner.ticket = ticket
                initialZeroVisitOwnership = owner
            } else { initialZeroVisitOwnership = nil }
        } else {
            initialZeroVisitOwnership = nil
        }
        refreshAudioProcessing()
        audioCheckTask = Task { [weak self, weak playerItem] in
            guard let playerItem else { return }
            let tracks = try? await playerItem.asset.loadTracks(withMediaType: .audio)
            guard let self, !Task.isCancelled, self.generation == request, self.player.currentItem === playerItem else { return }
            self.hasAudioTrack = tracks.map { !$0.isEmpty }
        }
        // A restored offset must finish seeking before its first-frame epoch begins.
        if position == 0 && !rewind { monitorFirstFrame(playerItem, request: request) }
        armStallRecovery()
        itemObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self, weak playerItem] _, _ in
            Task { @MainActor in
                guard let self, let playerItem, self.generation == request, self.player.currentItem === playerItem else { return }
                if playerItem.status == .readyToPlay {
                    guard self.readyGeneration != request else { return }
                    #if DEBUG
                    if let gate = self.onDebugInitialVideoReady {
                        await gate(request)
                        // The real callback may have become stale while the test
                        // withheld delivery. Never assign readiness to a new item.
                        guard !Task.isCancelled, self.generation == request,
                              self.player.currentItem === playerItem,
                              playerItem.status == .readyToPlay,
                              self.readyGeneration != request else { return }
                    }
                    #endif
                    #if DEBUG
                    self.debugTraceVideoStartup(.readyAccepted, request: request) {}
                    #endif
                    if let owner = self.pendingInitialZeroStart, owner.request == request,
                       self.currentVideoPresentation(for: playerItem, request: request) == owner.ticket {
                        self.pendingInitialZeroStart = nil
                    }
                    self.readyGeneration = request
                    self.refreshAudioProcessing()
                    self.clock.updateDuration(playerItem.duration.seconds)
                    self.isLoading = false
                    #if DEBUG
                    self.debugTraceVideoStartup(.itemReadyEvent, request: request) { self.recordPlaybackEvent("itemReady") }
                    #else
                    self.recordPlaybackEvent("itemReady")
                    #endif
                    // A new or prebuffered item is already at zero; an exact zero seek discards that benefit.
                    if position > 0 || rewind {
                        // Audio already owns its position. Readiness of a reused
                        // muted video must never rewind the audible PCM cursor.
                        #if DEBUG
                        self.synchronizeVideoToAudio(force: true, reason: rewind ? .readyRewind : .readyRestore)
                        #else
                        self.synchronizeVideoToAudio(force: true)
                        #endif
                    } else {
                        let ticket = self.currentVideoPresentation(for: playerItem, request: request)
                        var installed = false
                        var playbackAnchor: (host: CMTime, position: Double)?
                        if self.syncingVideoGeneration != request, let ticket {
                            let host = CMClockGetTime(CMClockGetHostTimeClock())
                            let desired = self.continuousAudio.presentationPosition(at: host)
                            installed = self.continuousPiP.installTimeline(ticket,
                                positionSeconds: desired,
                                durationSeconds: self.clock.duration, isPlaying: self.intent.canPlay)
                            if installed { playbackAnchor = (host, desired) }
                        }
                        if self.intent.canPlay, self.videoAllowed {
                            if installed, let ticket, let anchor = playbackAnchor,
                               self.currentVideoPresentation(for: playerItem, request: request) == ticket {
                                #if DEBUG
                                self.debugTraceVideoStartup(.setRate, request: request, installed: installed,
                                    anchorHostSeconds: anchor.host.seconds, anchorPosition: anchor.position) {
                                    self.player.setRate(1, time: CMTime(seconds: anchor.position, preferredTimescale: 48_000),
                                                        atHostTime: anchor.host)
                                }
                                #else
                                self.player.setRate(1, time: CMTime(seconds: anchor.position, preferredTimescale: 48_000),
                                                    atHostTime: anchor.host)
                                #endif
                            } else {
                                #if DEBUG
                                self.debugTraceVideoStartup(.playImmediately, request: request, installed: installed) {
                                    self.player.playImmediately(atRate: 1)
                                }
                                #else
                                self.player.playImmediately(atRate: 1)
                                #endif
                            }
                        } else {
                            #if DEBUG
                            self.debugTraceVideoStartup(.startSkipped, request: request, installed: installed) {}
                            #endif
                        }
                        if installed, let ticket,
                           self.currentVideoPresentation(for: playerItem, request: request) == ticket {
                            _ = self.continuousPiP.activate(ticket)
                        }
                    }
                    self.updateNowPlaying()
                } else if playerItem.status == .failed {
                    if self.continuousAudio.isSelected { self.message = "Video is unavailable. Audio will continue." }
                    else { self.handlePlaybackFailure() }
                }
            }
        }
    }

    private func monitorFirstFrame(_ playerItem: AVPlayerItem, request: Int) {
        let completion: () -> Void = { [weak self, weak playerItem] in
            guard let self, let playerItem, self.generation == request, self.player.currentItem === playerItem else { return }
            #if DEBUG
            self.debugTraceVideoStartup(.firstFrameEvent, request: request) {
                self.isVideoReady = true
                self.recordPlaybackEvent("firstFrame")
            }
            #else
            self.isVideoReady = true
            self.recordPlaybackEvent("firstFrame")
            #endif
        }
        #if DEBUG
        if let observer = onDebugFrameMonitorReadBatch {
            let expectedItem = ObjectIdentifier(playerItem)
            let expected = videoPresentation
            frameMonitor.onDebugReadBatch = { [weak self] reads in
                guard let self else { return }
                observer(DebugFrameMonitorReadBatch(request: request, generation: self.generation,
                    sourceItemMatches: reads.item == expectedItem,
                    observedItemMatches: self.observedItem.map { ObjectIdentifier($0) == expectedItem } ?? false,
                    presentationMatches: expected != nil && expected?.request == request
                        && self.videoPresentation?.request == expected?.request
                        && self.videoPresentation?.ticket == expected?.ticket,
                    selectedMatchesQueue: self.continuousAudio.selectedID != nil
                        && self.continuousAudio.selectedID == self.queue.currentID,
                    cachedAudioToken: self.audioToken, cachedAudioVisit: self.audioVisit, reads: reads))
            }
        }
        if debugUsesCurrentCustomFrameForReadiness {
            // Capture the raw ticket: audio eligibility can still be pending here.
            let expected = videoPresentation
            frameMonitor.start(item: playerItem, layer: surface.playerLayer, decodedFrameEpoch: { [weak self, weak playerItem] in
                guard let self, let playerItem, let expected,
                      expected.request == request, self.generation == request,
                      self.observedItem === playerItem,
                      self.videoPresentation?.request == request,
                      self.videoPresentation?.ticket == expected.ticket else { return nil }
                return self.continuousPiP.debugCurrentFrameEpoch(for: expected.ticket)
            }, onReady: completion)
        } else {
            frameMonitor.start(item: playerItem, layer: surface.playerLayer, onReady: completion)
        }
        debugAfterFirstFrameMonitorStart?(playerItem)
        #else
        frameMonitor.start(item: playerItem, layer: surface.playerLayer, onReady: completion)
        #endif
    }

    private var initialZeroStartOwnsPendingReady: Bool {
        guard intent.canPlay, readyGeneration == nil, let owner = pendingInitialZeroStart,
              owner.request == generation, explicitVideoSeekGeneration != generation,
              let item = observedItem else { return false }
        return currentVideoPresentation(for: item, request: owner.request) == owner.ticket
    }

    /// Consume before any visit side effects. Missed/intervening visits fall back
    /// to the existing correction path; readiness never consumes this proof.
    private func consumeInitialZeroVisit(_ sample: ContinuousPCMRenderer.Snapshot,
                                         entry: ContinuousAudioPlayer.Entry, changedSource: Bool) -> Bool {
        let owner = initialZeroVisitOwnership
        initialZeroVisitOwnership = nil
        guard let owner, let ticket = owner.ticket, changedSource,
              owner.request == generation, owner.baselineVisit < Int64.max,
              sample.visit == owner.baselineVisit + 1, sample.token == owner.token,
              entry.token == owner.token, entry.id == owner.mediaID,
              queue.currentID == owner.mediaID, continuousAudio.selectedID == owner.mediaID,
              explicitVideoSeekGeneration != generation, pendingAudioSeek == nil,
              intent.canPlay, videoAllowed, !sample.ended,
              let item = observedItem else { return false }
        return currentVideoPresentation(for: item, request: owner.request) == ticket
    }

    private func currentVideoPresentation(for item: AVPlayerItem, request: Int)
        -> ContinuousPictureInPicture.PresentationTicket? {
        guard generation == request, let presentation = videoPresentation, presentation.request == request,
              observedItem === item, player.currentItem === item, audioLoadingID == nil,
              continuousAudio.isSelected, continuousAudio.selectedID == queue.currentID else { return nil }
        return presentation.ticket
    }

    private func prepareUpcoming() {
        warmRevision += 1; let revision = warmRevision, request = generation
        warmTask?.cancel()
        var natural = queue
        let naturalID = natural.next(explicit: false)
        var preview = queue
        var upcoming: [MediaRecord] = []
        for _ in 0..<2 {
            guard let id = preview.next(), id != queue.currentID, !upcoming.contains(where: { $0.id == id }),
                  let item = library.catalog.mediaByID[id] else { break }
            upcoming.append(item)
        }
        let active = current
        let previous = previousID.flatMap { library.catalog.mediaByID[$0] }
        let successor = naturalID.flatMap { library.catalog.mediaByID[$0] }
        let explicitSuccessor = nextID.flatMap { library.catalog.mediaByID[$0] }
        let pcmIDs = Set([active?.id, previous?.id, nextID].compactMap { $0 })
        continuousAudio.setWindow(pcmIDs)
        updateAudioSuccessor()
        if buffer.nextMediaID != naturalID { buffer.discardNext() }
        if buffer.previousMediaID != previous?.id { buffer.discardPrevious() }
        warmTask = Task { [weak self] in
            guard let self else { return }
            let pinned = ([active, previous].compactMap { $0 } + upcoming).compactMap(\.asset)
            await self.mediaCache?.setWindow(pinned, revision: revision)
            guard !Task.isCancelled, self.generation == request else { return }
            // Repeat-one uses the current prefix for its natural boundary; its
            // explicit Next still needs the second slot, including Saved media
            // that the later network-prefetch loop deliberately skips.
            if let explicitSuccessor, explicitSuccessor.id != naturalID,
               self.continuousAudio.entry(for: explicitSuccessor.id) == nil {
                let saved = await self.downloads.localURL(for: explicitSuccessor)
                let cached = if let asset = explicitSuccessor.asset { await self.mediaCache?.file(for: asset) } else { nil as URL? }
                if let local = saved ?? cached { _ = try? await self.continuousAudio.prepare(id: explicitSuccessor.id, url: local) }
                guard !Task.isCancelled, self.generation == request, self.warmRevision == revision else { return }
            }
            // Resolve and enqueue the next AVPlayerItem before waiting for any full-file transfer.
            if let next = successor, !self.buffer.hasPrepared(next.id) {
                let saved = await self.downloads.localURL(for: next)
                let cached: URL?
                if let asset = next.asset { cached = await self.mediaCache?.file(for: asset) } else { cached = nil }
                var url = saved ?? cached
                if url == nil, self.downloads.network.isConnected, let asset = next.asset {
                    url = try? await self.cloud.downloadURL(asset)
                }
                guard !Task.isCancelled, self.generation == request, self.warmRevision == revision else { return }
                if let url {
                    // Full-duration duplicate items avoid an end-notification seek for repeat-one.
                    // Never infer a trim point from a silent tail or catalog duration.
                    let playerItem = AVPlayerItem(url: url)
                    playerItem.preferredForwardBufferDuration = 8
                    if url.isFileURL { _ = try? await self.continuousAudio.prepare(id: next.id, url: url) }
                    guard !Task.isCancelled, self.generation == request, self.warmRevision == revision else { return }
                    let videoPreparation = try? await ContinuousPictureInPicture.prepareVideoResource(for: playerItem)
                    guard !Task.isCancelled, self.generation == request, self.warmRevision == revision else { return }
                    self.buffer.stage(.init(mediaID: next.id, item: playerItem, isLocal: saved != nil || cached != nil),
                        after: active?.id, videoPreparation: videoPreparation, ifEligible: {
                            !Task.isCancelled && self.generation == request && self.warmRevision == revision
                        })
                    self.updateAudioSuccessor()
                    self.refreshAudioProcessing()
                }
            }
            if let previous, self.buffer.previousMediaID != previous.id {
                let saved = await self.downloads.localURL(for: previous)
                let cached = if let asset = previous.asset { await self.mediaCache?.file(for: asset) } else { nil as URL? }
                var url = saved ?? cached
                if url == nil, self.downloads.network.isConnected, let asset = previous.asset {
                    url = try? await self.cloud.downloadURL(asset)
                }
                guard !Task.isCancelled, self.generation == request, self.warmRevision == revision else { return }
                if let url {
                    let item = AVPlayerItem(url: url)
                    item.preferredForwardBufferDuration = 8
                    _ = await PlaybackPreparation.value(within: .milliseconds(500)) { try? await item.asset.load(.isPlayable) }
                    if url.isFileURL { _ = try? await self.continuousAudio.prepare(id: previous.id, url: url) }
                    guard !Task.isCancelled, self.generation == request, self.warmRevision == revision else { return }
                    let videoPreparation = try? await ContinuousPictureInPicture.prepareVideoResource(for: item)
                    guard !Task.isCancelled, self.generation == request, self.warmRevision == revision else { return }
                    self.buffer.stagePrevious(.init(mediaID: previous.id, item: item, isLocal: saved != nil || cached != nil),
                        videoPreparation: videoPreparation, ifEligible: {
                            !Task.isCancelled && self.generation == request && self.warmRevision == revision
                        })
                    self.refreshAudioProcessing()
                }
            }
            guard self.downloads.network.isConnected, self.wantsToPlay else { return }
            // A small rolling window also keeps recently played clips ready for a downward swipe.
            for item in Array(upcoming.prefix(1)) + [previous].compactMap({ $0 }) + Array(upcoming.dropFirst()) + [active].compactMap({ $0 }) {
                guard !Task.isCancelled, self.warmRevision == revision else { return }
                guard let asset = item.asset else { continue }
                if await self.downloads.localURL(for: item) != nil { continue }
                if let url = await self.mediaCache?.prefetch(asset, revision: revision), pcmIDs.contains(item.id) {
                    guard !Task.isCancelled, self.warmRevision == revision, self.generation == request else { return }
                    _ = try? await self.continuousAudio.prepare(id: item.id, url: url)
                    self.updateAudioSuccessor()
                    // Keep the prepared decoder. Promote the file now only for an offline handoff.
                    let requireLocal = !self.downloads.network.isConnected
                    if requireLocal || !self.buffer.hasPrepared(item.id) {
                        let playerItem = AVPlayerItem(url: url)
                        guard !Task.isCancelled, self.warmRevision == revision, self.generation == request else { return }
                        let videoPreparation = try? await ContinuousPictureInPicture.prepareVideoResource(for: playerItem)
                        guard !Task.isCancelled, self.warmRevision == revision, self.generation == request else { return }
                        self.buffer.stage(.init(mediaID: item.id, item: playerItem, isLocal: true), requireLocal: requireLocal,
                            after: active?.id, videoPreparation: videoPreparation, ifEligible: {
                                !Task.isCancelled && self.generation == request && self.warmRevision == revision
                            })
                        self.updateAudioSuccessor()
                        self.refreshAudioProcessing()
                    }
                }
            }
        }
    }

    private func selectContinuousAudio(id: String, position: Double) {
        initialZeroVisitOwnership = nil
        let baseline = continuousAudio.snapshot
        audioVisit = baseline.visit; audioToken = baseline.token
        if continuousAudio.select(id: id, position: position) {
            audioLoadingID = nil
            if position == 0, explicitVideoSeekGeneration != generation, baseline.visit < Int64.max,
               id == queue.currentID, let entry = continuousAudio.entry(for: id), entry.token != baseline.token {
                initialZeroVisitOwnership = InitialZeroVisitOwnership(request: generation,
                    mediaID: id, token: entry.token, baselineVisit: baseline.visit, ticket: nil)
            }
        }
    }

    private func resumeContinuousAudio() {
        guard intent.canPlay, audioLoadingID == nil, continuousAudio.isSelected,
              continuousAudio.selectedID == queue.currentID else { return }
        do { try continuousAudio.setPlaying(true) }
        catch {
            intent.activationCompleted(succeeded: false)
            continuousAudio.suspend(); player.pause()
            message = "Audio could not restart. Tap Play to try again."
            recordPlaybackEvent("engineStartFailed")
        }
    }

    private func updateAudioSuccessor() {
        guard let id = queue.currentID else { return }
        var following = queue
        let next = isInteractingWithFeed ? nil : following.next(explicit: false)
        continuousAudio.follow(from: id, to: next)
        buffer.automaticAdvancementEnabled = false
    }

    private func sampleContinuousAudio(handleEnd: Bool = true) {
        continuousAudio.settlePausedState()
        guard audioLoadingID == nil else { return }
        let sample = continuousAudio.snapshot
        // A natural boundary can publish an older visit after a selection is
        // requested. It must not replace the requested source/queue before that
        // exact command has been consumed by the audio thread.
        guard !continuousAudio.isSelectionPending(in: sample) else {
            // A paused restore does not start the engine to acknowledge selection.
            // Keep fetching its requested video frame as decoding becomes ready,
            // without adopting the old audio snapshot or changing playback intent.
            if !intent.canPlay, continuousAudio.selectedID != nil,
               continuousAudio.selectedID == queue.currentID {
                continuousPiP.updatePlayback(positionSeconds: continuousAudio.presentationPosition(at: CMClockGetTime(CMClockGetHostTimeClock())),
                    durationSeconds: clock.duration, isPlaying: false)
            }
            return
        }
        guard let entry = continuousAudio.entry(forToken: sample.token) else { return }
        if let pending = pendingAudioSeek, sample.selectionVersion == pending.version {
            _ = clock.completeSeek(pending.seek, actualPosition: Double(sample.frame) / 48_000)
            pendingAudioSeek = nil
            completePiPSkip()
        }
        if sample.underrunFrames != lastUnderrun {
            lastUnderrun = sample.underrunFrames; recordDiagnostic(.rendererUnderrun)
        }
        if sample.visit != audioVisit {
            #if DEBUG
            if shouldDebugDeferAudioVisit?(generation) == true { return }
            #endif
            let changedSource = sample.token != audioToken
            let ownedInitialVisit = consumeInitialZeroVisit(sample, entry: entry, changedSource: changedSource)
            audioVisit = sample.visit; audioToken = sample.token
            if !ownedInitialVisit { continuousPiP.flushForSeek() }
            continuousAudio.adoptRendered(id: entry.id)
            if changedSource, entry.id != queue.currentID {
                var following = queue
                guard following.next(explicit: false) == entry.id else {
                    continuousAudio.suspend(); return
                }
                queue = following
                let video = buffer.advance(to: entry.id)
                loadCurrent(position: Double(sample.frame) / 48_000, adopting: video, audioAlreadySelected: true)
            } else if !ownedInitialVisit {
                #if DEBUG
                synchronizeVideoToAudio(force: true, reason: .sourceVisit)
                #else
                synchronizeVideoToAudio(force: true)
                #endif
            }
            prepareUpcoming()
        }
        clock.sample(position: Double(sample.frame) / 48_000)
        clock.updateDuration(Double(entry.frames) / 48_000)
        continuousPiP.updatePlayback(positionSeconds: continuousAudio.presentationPosition(at: CMClockGetTime(CMClockGetHostTimeClock())),
            durationSeconds: clock.duration, isPlaying: intent.canPlay && !sample.ended)
        if pipSkipCompletion != nil, ProcessInfo.processInfo.systemUptime >= pipSkipDeadline { completePiPSkip() }
        if firstProgressGeneration != generation, sample.frame >= 2_400 {
            firstProgressGeneration = generation; recordPlaybackEvent("clock50ms")
        }
        if handleEnd, sample.ended, intent.canPlay {
            if isInteractingWithFeed { endedDuringScroll = true }
            else {
                var following = queue
                if following.next(explicit: false) != nil { next(explicit: false) }
                else { pause() }
            }
        }
        if !initialZeroStartOwnsPendingReady {
            #if DEBUG
            synchronizeVideoToAudio(reason: .drift)
            #else
            synchronizeVideoToAudio()
            #endif
        }
        if Date().timeIntervalSince(lastBookmark) > 5 { persist(); updateNowPlaying() }
    }

    #if DEBUG
    private func synchronizeVideoToAudio(force: Bool = false, reason: DebugVideoSeekReason) {
        guard onDebugVideoSeekStamp != nil else { synchronizeVideoToAudio(force: force); return }
        let previous = debugVideoSeekReason
        debugVideoSeekReason = reason
        defer { debugVideoSeekReason = previous }
        synchronizeVideoToAudio(force: force)
    }
    #endif

    private func synchronizeVideoToAudio(force: Bool = false) {
        #if DEBUG
        let reason = debugVideoSeekReason
        #endif
        guard videoAllowed, continuousAudio.isSelected, audioLoadingID == nil, syncingVideoGeneration != generation,
              let item = player.currentItem, item.status == .readyToPlay else { return }
        let request = generation
        let selectedID = continuousAudio.selectedID
        let presentation = videoPresentation
        let visit = continuousAudio.snapshot
        let expectedToken = selectedID.flatMap { continuousAudio.entry(for: $0)?.token }
        let initialSelectionPending = continuousAudio.isSelectionPending(in: visit)
        let canPlay = intent.canPlay
        var currentItemAfterRead = true
        #if DEBUG
        var ordinaryDriftVideoPositionSeconds: Double? = nil
        var ordinaryDriftReadEntryNs: UInt64? = nil
        var ordinaryDriftReadReturnNs: UInt64? = nil
        #endif
        guard let position = PlaybackTimeline.videoCorrectionTarget(force: force, readVideoPosition: {
            let sampledPosition: Double
            #if DEBUG
            if self.onDebugVideoSeekStamp != nil {
                ordinaryDriftReadEntryNs = DispatchTime.now().uptimeNanoseconds
                sampledPosition = item.currentTime().seconds
                ordinaryDriftReadReturnNs = DispatchTime.now().uptimeNanoseconds
            } else {
                sampledPosition = item.currentTime().seconds
            }
            ordinaryDriftVideoPositionSeconds = sampledPosition
            #else
            sampledPosition = item.currentTime().seconds
            #endif
            // Revalidate the SDK-owned queue before taking the fresh audio goal.
            // No SDK item/position query follows that goal in this decision.
            currentItemAfterRead = self.player.currentItem === item
            return sampledPosition
        }, readAudioPosition: {
            let host = CMClockGetTime(CMClockGetHostTimeClock())
            return self.continuousAudio.presentationPosition(at: host)
        }, isCurrent: {
            guard currentItemAfterRead, self.generation == request,
                  self.observedItem === item, self.videoAllowed,
                  self.audioLoadingID == nil, self.syncingVideoGeneration != request,
                  self.continuousAudio.isSelected, selectedID != nil,
                  self.continuousAudio.selectedID == selectedID, self.queue.currentID == selectedID,
                  self.videoPresentation?.request == presentation?.request,
                  self.videoPresentation?.ticket == presentation?.ticket,
                  self.intent.canPlay == canPlay else { return false }
            // A natural boundary can change the rendered source before service
            // adoption. Forced targets also need that owner; pending explicit
            // selections still own their unacknowledged target.
            if !initialSelectionPending {
                guard let expectedToken, expectedToken > 0, visit.token == expectedToken else { return false }
            }
            let current = self.continuousAudio.snapshot
            return current.token == visit.token && current.visit == visit.visit
                && current.selectionVersion == visit.selectionVersion
        }) else { return }
        syncingVideoGeneration = request
        let videoSeek = continuousPiP.beginSeek()
        #if DEBUG
        if let observer = onDebugVideoSeekStamp {
            observer(DebugVideoSeekStamp(reason: reason, request: request, generation: generation,
                nativeSeekTicket: videoSeek, requestedPosition: position, force: force,
                ordinaryDriftVideoPositionSeconds: ordinaryDriftVideoPositionSeconds,
                ordinaryDriftReadEntryNs: ordinaryDriftReadEntryNs,
                ordinaryDriftReadReturnNs: ordinaryDriftReadReturnNs,
                cachedSelected: continuousAudio.isSelected,
                selectedMatchesQueue: continuousAudio.selectedID == queue.currentID,
                cachedAudioToken: audioToken, cachedAudioVisit: audioVisit,
                observedItemMatches: observedItem === item,
                presentationRequestMatches: videoPresentation?.request == request,
                readyGeneration: readyGeneration, pendingAudioSeek: pendingAudioSeek != nil,
                audioLoading: audioLoadingID != nil, canPlay: intent.canPlay, videoAllowed: videoAllowed))
        }
        #endif
        seekVideo(player, CMTime(seconds: position, preferredTimescale: 48_000)) { [weak self, weak item] finished in
            Task { @MainActor in
                guard let self else { return }
                defer { self.continuousPiP.completeSeek(videoSeek) }
                guard self.syncingVideoGeneration == request else { return }
                self.syncingVideoGeneration = nil
                guard finished, let item, self.generation == request,
                      self.player.currentItem === item, self.videoAllowed else { return }
                let host = CMClockGetTime(CMClockGetHostTimeClock())
                let desired = self.continuousAudio.presentationPosition(at: host)
                // A newer paused request must win even within the drift threshold;
                // compare requested targets rather than native seek quantization.
                let requestedFrameChanged = abs(position - desired) > 0.5 / 48_000
                if !self.intent.canPlay,
                   requestedFrameChanged || abs(item.currentTime().seconds - desired) > 0.080 {
                    #if DEBUG
                    self.synchronizeVideoToAudio(force: true, reason: .latestPausedTarget)
                    #else
                    self.synchronizeVideoToAudio(force: true)
                    #endif
                    return
                }
                // The display layer also needs the requested paused/restored position,
                // even before the engine has acknowledged its first selection command.
                // The epoch was reset before seeking. Release acquisition only
                // now; never flush a target frame already pulled by the timer.
                guard let ticket = self.currentVideoPresentation(for: item, request: request),
                      self.continuousPiP.installTimeline(ticket, positionSeconds: desired,
                          durationSeconds: self.clock.duration, isPlaying: self.intent.canPlay) else { return }
                self.continuousPiP.completeSeek(videoSeek)
                if !self.isVideoReady { self.monitorFirstFrame(item, request: request) }
                // AVPlayer schedules the muted video on the system host clock;
                // it never gates the audio render callback or its next boundary.
                if self.intent.canPlay {
                    self.player.setRate(1, time: CMTime(seconds: desired, preferredTimescale: 48_000),
                                        atHostTime: host)
                }
                if self.currentVideoPresentation(for: item, request: request) == ticket {
                    _ = self.continuousPiP.activate(ticket)
                }
            }
        }
    }

    private func handlePlaybackFailure() {
        cancelStallRecovery()
        guard let item = current else { return }
        if !currentIsLocal, remoteRetries.insert(item.id).inserted {
            loadCurrent(position: clock.position, forceRemote: true); return
        }
        queue.markUnavailable(item.id)
        if queue.next() != nil { loadCurrent() }
        else { isLoading = false; pause(); message = "These videos are currently unavailable. Try a downloaded playlist." }
    }

    private func cancelStallRecovery() { stallTask?.cancel(); stallTask = nil }

    private func armStallRecovery() {
        guard !continuousAudio.isSelected else { return } // A video stall cannot skip audible PCM.
        guard intent.canPlay, stallTask == nil, player.currentItem != nil, let id = queue.currentID else { return }
        let ticket = PlaybackStallTicket(generation: generation, mediaID: id, position: clock.position,
                                         deadline: Date().addingTimeInterval(12))
        stallTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.stallTask = nil
            if ticket.shouldRecover(generation: self.generation, mediaID: self.queue.currentID,
                                    position: self.clock.position, wantsToPlay: self.intent.canPlay, now: Date()) {
                // Refresh a remote URL once, then skip the failed item through the bounded queue.
                self.handlePlaybackFailure()
            } else if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate { self.armStallRecovery() }
        }
    }

    func startPiP() {
        audioOnly = false
        guard let pip, pip.isPictureInPicturePossible else { message = "Play a video on this screen before opening Picture in Picture."; return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    func persist() {
        lastBookmark = Date()
        do { try AppFiles.save(PlaybackBookmark(queue: queue, position: clock.position), to: bookmarkURL) }
        catch { message = "Could not save your playback position." }
    }

    private func configureAudio() {
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers]) }
        catch { message = "Background audio could not be configured." }
    }
    private func activateAudio() {
        guard !intent.isInterrupted else { return }
        recordPlaybackEvent("activationRequested")
        do {
            try activateSession()
            intent.activationCompleted(succeeded: true); refreshAudioProcessing()
            recordDiagnostic(.audioSessionActivated)
            recordPlaybackEvent("activationCompleted")
        } catch {
            intent.activationCompleted(succeeded: false); continuousAudio.suspend(); player.pause(); cancelStallRecovery()
            recordDiagnostic(.audioSessionActivationFailed, error: PlaybackDiagnosticError(family: .audioSession, code: (error as NSError).code))
            message = "Audio is in use. Tap Play after the camera or call finishes."
            recordPlaybackEvent("activationFailed")
        }
    }

    func enteredForeground() {
        applyPresentation(presentationPolicy.applicationDidBecomeActive())
        recordDiagnostic(.appForegrounded)
        let interrupted = intent.isInterrupted
        intent.enteredForeground()
        if interrupted { continuousAudio.suspend(); player.pause(); message = "Audio was interrupted. Tap Play to resume." }
        else {
            #if DEBUG
            synchronizeVideoToAudio(force: true, reason: .foreground)
            #else
            synchronizeVideoToAudio(force: true)
            #endif
        }
    }

    func handleInterruption(began: Bool, shouldResume: Bool = false) {
        recordPlaybackEvent(began ? "interruptionBegan" : (shouldResume ? "interruptionEndedResumeAllowed" : "interruptionEndedNoResume"))
        if began {
            intent.interruptionBegan(); cancelStallRecovery()
            continuousAudio.suspend()
            player.pause(); persist()
        } else if intent.interruptionEnded(shouldResume: shouldResume) {
            activateAudio()
            resumeContinuousAudio()
            if intent.canPlay, !resumeAfterPreparedEnd(), videoAllowed { player.play() }
        }
        updateNowPlaying()
    }

    private func resumeAfterPreparedEnd() -> Bool {
        guard reachedPreparedEnd else { return false }
        reachedPreparedEnd = false
        var following = queue
        if following.next(explicit: false) != nil { queue = following }
        loadCurrent()
        return true
    }

    private func refreshAudioProcessing() {
        // Video is always muted; applying item taps as well would duplicate DSP.
        speakerAudio.update(items: buffer.retainedItems, enabled: false)
        continuousAudio.setSpeakerEnabled(SpeakerAudioMix.shouldEnhance(enabled: speakerSound, routes: audioRoutes()))
    }

    private func applyPresentation(_ actions: PlaybackPresentationPolicy.Actions) {
        surface.isHidden = audioOnly
        pip?.canStartPictureInPictureAutomaticallyFromInline = automaticPiP && presentationPolicy.allowsPictureInPicture
        if actions.stopPictureInPicture { pip?.stopPictureInPicture() }
        if !videoAllowed { player.pause(); continuousPiP.suspendFrameFeed() }
        else { continuousPiP.resumeFrameFeed() }
        if actions.restoreInlineVideo {
            #if DEBUG
            synchronizeVideoToAudio(force: true, reason: .surfaceRestore)
            #else
            synchronizeVideoToAudio(force: true)
            #endif
        }
    }

    private func samplePiPState() {
        guard let pip else { return }
        applyPresentation(presentationPolicy.pictureInPictureChanged(active: pip.isPictureInPictureActive,
            possible: pip.isPictureInPicturePossible, suspended: pip.isPictureInPictureSuspended))
        recordDiagnostic(.pipStateChanged)
    }

    private func completePiPSkip() {
        let completion = pipSkipCompletion
        pipSkipCompletion = nil
        completion?()
    }

    private func handlePiPEvent(_ event: ContinuousPictureInPicture.Event, code: Int?) {
        let phase: PlaybackDiagnosticPhase
        switch event {
        case .willStart: phase = .pipWillStart
        case .didStart: phase = .pipDidStart
        case .willStop: phase = .pipWillStop
        case .didStop: phase = .pipDidStop
        case .startFailed:
            applyPresentation(presentationPolicy.pictureInPictureFailedToStart())
            message = "Picture in Picture could not start. Audio will continue."
            phase = .pipStartFailed
        case .restoreRequested: phase = .inlineRestoreRequested
        case .restoreCompleted: phase = .inlineRestoreCompleted
        case .restoreUnavailable: phase = .inlineRestoreUnavailable
        case .userPlayRequested: phase = .playRequested
        case .userPauseRequested: phase = .pauseRequested
        case .userSkipRequested: phase = .seekRequested
        case .frameFailed: phase = .sampled
        case .sourcePrepared:
            // Composition/output attachment can finish after an initial paused seek.
            if !intent.canPlay {
                #if DEBUG
                synchronizeVideoToAudio(force: true, reason: .preparedPausedSource)
                #else
                synchronizeVideoToAudio(force: true)
                #endif
            }
            phase = .sourcePreparationCompleted
        case .sourcePreparationFailed: phase = .sourcePreparationFailed
        }
        recordDiagnostic(phase, error: code.map { PlaybackDiagnosticError(family: .avKit, code: $0) })
    }

    private func recordDiagnostic(_ phase: PlaybackDiagnosticPhase,
                                  interruptionReason: Int? = nil, interruptionOptions: UInt? = nil,
                                  wasSuspended: Bool? = nil, routeReason: Int? = nil,
                                  error: PlaybackDiagnosticError? = nil,
                                  sourceSilence: ContinuousPCMDecoder.SourceSilence? = nil) {
        let session = AVAudioSession.sharedInstance()
        let routes = audioRoutes()
        let route: PlaybackDiagnosticOutputRoute
        if routes.isEmpty { route = .none }
        else if routes.contains(.airPlay) { route = .airPlay }
        else if routes.contains(.bluetoothA2DP) || routes.contains(.bluetoothHFP) || routes.contains(.bluetoothLE) { route = .bluetooth }
        else if routes.contains(.headphones) { route = .headphones }
        else if routes.contains(.builtInSpeaker) { route = .builtInSpeaker }
        else if routes.contains(.builtInReceiver) { route = .builtInReceiver }
        else { route = .other }
        diagnostics.record(phase, snapshot: PlaybackDiagnosticSnapshot(generation: generation,
            audioRequested: intent.wantsToPlay, audioPermitted: intent.canPlay, audioInterrupted: intent.isInterrupted,
            interruptionReason: interruptionReason, interruptionOptions: interruptionOptions,
            wasSuspended: wasSuspended, routeChangeReason: routeReason,
            engineRunning: continuousAudio.graph.engine.isRunning, audioOnlySelected: audioOnly,
            presentation: presentationPolicy.presentation,
            pipeline: continuousAudio.graph.engine.isRunning && intent.canPlay ? .playing : .paused,
            positionSeconds: clock.position, durationSeconds: clock.duration, playbackRate: Double(player.rate),
            retainedItems: buffer.retainedItemCount, preparedPCMBytes: continuousAudio.renderer.retainedPCMMemoryBytes,
            underrunFrames: UInt64(max(0, continuousAudio.snapshot.underrunFrames)), outputRoute: route,
            sampleRate: session.sampleRate, ioBufferSeconds: session.ioBufferDuration, outputLatencySeconds: session.outputLatency,
            pipActive: pip?.isPictureInPictureActive ?? false, pipPossible: pip?.isPictureInPicturePossible ?? false,
            pipSuspended: pip?.isPictureInPictureSuspended ?? false,
            sourceFrames: sourceSilence?.totalFrames,
            sourceLeadingBelowMinus60DBFrames: sourceSilence?.leadingFrames,
            sourceTrailingBelowMinus60DBFrames: sourceSilence?.trailingFrames), error: error)
    }

    func exportPlaybackDiagnostics() -> URL? {
        recordDiagnostic(.sampled)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OfflinePlayer-playback-diagnostics.json")
        do {
            let data = try diagnostics.exportJSON()
            guard data.count <= 256 * 1_024 else { return nil }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            return url
        } catch { return nil }
    }

    private func recordPlaybackEvent(_ name: StaticString) {
        // Fixed phase names and numerical state only: no media IDs, URLs or titles.
        os_signpost(.event, log: Self.playbackLog, name: name, "generation=%d retained=%d", generation, buffer.retainedItemCount)
        onPlaybackEvent?(PlaybackEvent(name: String(describing: name), uptime: ProcessInfo.processInfo.systemUptime,
            generation: generation, position: player.currentTime().seconds, retainedItems: buffer.retainedItemCount))
    }

    private func installObservers() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate { self.armStallRecovery() }
                else if self.player.timeControlStatus == .playing { self.cancelStallRecovery() }
                self.recordPlaybackEvent(self.player.timeControlStatus == .playing ? "playing" : "waitingOrPaused")
            }
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyPresentation(self.presentationPolicy.applicationDidEnterBackground())
                self.recordDiagnostic(.appBackgrounded)
            }
        })
        notifications.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? AVAudioEngine === self.continuousAudio.graph.engine else { return }
                self.recordDiagnostic(.rendererStopped)
                self.resumeContinuousAudio()
            }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                self.armStallRecovery()
            }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? AVPlayerItem === self.observedItem else { return }
                guard !self.continuousAudio.isSelected else { return }
                self.buffer.synchronize()
                guard note.object as? AVPlayerItem === self.player.currentItem else { return }
                if self.isInteractingWithFeed { self.endedDuringScroll = true }
                else if self.intent.canPlay { self.next(explicit: false) }
            }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                if self.continuousAudio.isSelected {
                    self.recordPlaybackEvent("videoFailed")
                    self.message = "Video is unavailable. Audio will continue."
                } else { self.handlePlaybackFailure() }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                self.recordDiagnostic(type == .began ? .audioInterruptionBegan : .audioInterruptionEnded,
                    interruptionReason: note.userInfo?[AVAudioSessionInterruptionReasonKey] as? Int,
                    interruptionOptions: options.rawValue,
                    wasSuspended: note.userInfo?[AVAudioSessionInterruptionWasSuspendedKey] as? Bool)
                self.handleInterruption(began: type == .began, shouldResume: options.contains(.shouldResume))
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.recordDiagnostic(.audioRouteChanged, routeReason: note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? Int)
                self?.refreshAudioProcessing()
                if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordDiagnostic(.audioMediaServicesReset)
                self.pause(); self.continuousAudio.rebuildAfterMediaServicesReset(); self.buffer.discardPrevious(); self.configureAudio()
                self.loadCurrent(position: self.clock.position)
            }
        })
        notifications.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Adopt a boundary that already happened before dropping its metadata.
                self?.buffer.synchronize()
                self?.warmTask?.cancel(); self?.warmRevision += 1
                self?.buffer.discardNext(); self?.buffer.discardPrevious()
                if let self { self.continuousAudio.trimWindow(preserving: self.queue.currentID) }
                self?.refreshAudioProcessing()
            }
        })
    }

    private func installRemoteControls() {
        let commands = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, action: @escaping @MainActor (PlaybackService) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in action(self) }; return .success
            }
            remoteTargets.append((command, target))
        }
        bind(commands.playCommand) { $0.play() }; bind(commands.pauseCommand) { $0.pause() }
        bind(commands.togglePlayPauseCommand) { $0.toggle() }; bind(commands.nextTrackCommand) { $0.next() }
        bind(commands.previousTrackCommand) { $0.previous() }
        commands.changePlaybackPositionCommand.isEnabled = true
        let target = commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self.seek(event.positionTime) }; return .success
        }
        remoteTargets.append((commands.changePlaybackPositionCommand, target))
    }

    private func updateNowPlaying() {
        guard let item = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: item.title, MPMediaItemPropertyArtist: item.creator,
            MPMediaItemPropertyPlaybackDuration: clock.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.position,
            MPNowPlayingInfoPropertyPlaybackRate: intent.canPlay ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
    }
}
