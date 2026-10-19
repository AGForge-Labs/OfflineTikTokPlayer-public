import Foundation
import AVFoundation
import AVKit
import MediaPlayer
import Observation
import PlayerCore

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
    var player: AVQueuePlayer { buffer.player }
    let clock = PlaybackClock()
    private(set) var queue = PlaybackQueue(ids: [])
    private(set) var wantsToPlay = false
    private(set) var isLoading = false
    private(set) var isVideoReady = false
    private(set) var hasAudioTrack: Bool?
    var message: String?
    var isInteractingWithFeed = false
    var speakerSound: Bool {
        didSet { UserDefaults.standard.set(speakerSound, forKey: "speakerSound"); refreshAudioProcessing() }
    }
    var automaticPiP: Bool {
        didSet { pip?.canStartPictureInPictureAutomaticallyFromInline = automaticPiP; UserDefaults.standard.set(automaticPiP, forKey: "automaticPiP") }
    }
    @ObservationIgnored var requestPlayerUI: (() -> Void)?
    @ObservationIgnored private(set) var surface: PlayerSurface!
    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private let library: LibraryRepository
    @ObservationIgnored private let downloads: OfflineDownloads
    @ObservationIgnored private let cloud: OneDriveClient
    @ObservationIgnored private let buffer = PlaybackBuffer()
    @ObservationIgnored private let mediaCache: PlaybackMediaCache?
    @ObservationIgnored private var warmTask: Task<Void, Never>?
    @ObservationIgnored private var warmRevision = 0
    @ObservationIgnored private weak var observedItem: AVPlayerItem?
    @ObservationIgnored private var readyGeneration: Int?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private let frameMonitor = PlaybackFrameMonitor()
    @ObservationIgnored private let speakerAudio = SpeakerAudioController()
    @ObservationIgnored private var audioCheckTask: Task<Void, Never>?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var remoteRetries = Set<String>()
    @ObservationIgnored private var currentIsLocal = false
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var endedDuringScroll = false
    @ObservationIgnored private var lastBookmark = Date.distantPast
    private let bookmarkURL = AppFiles.root.appendingPathComponent("playback.json")

    var current: MediaRecord? { queue.currentID.flatMap { library.catalog.mediaByID[$0] } }
    var previousID: String? { queue.previewPrevious() }
    var nextID: String? { queue.previewNext() }

    init(library: LibraryRepository, downloads: OfflineDownloads, cloud: OneDriveClient) {
        self.library = library; self.downloads = downloads; self.cloud = cloud
        mediaCache = PlaybackCacheLoader.make(cloud: cloud)
        automaticPiP = UserDefaults.standard.bool(forKey: "automaticPiP")
        speakerSound = UserDefaults.standard.object(forKey: "speakerSound") as? Bool ?? true
        super.init()
        surface = PlayerSurface(player: player)
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.actionAtItemEnd = .pause
        pip = AVPictureInPictureController(playerLayer: surface.playerLayer)
        pip?.delegate = self; pip?.canStartPictureInPictureAutomaticallyFromInline = automaticPiP
        configureAudio(); installObservers(); installRemoteControls()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let item = self.observedItem, self.player.currentItem === item else { return }
                // Read the current item now: an already queued callback can belong to the old item.
                self.clock.sample(position: item.currentTime().seconds)
                if Date().timeIntervalSince(self.lastBookmark) > 5 { self.persist(); self.updateNowPlaying() }
            }
        }
    }

    func restore() {
        guard queue.currentID == nil, let data = try? Data(contentsOf: bookmarkURL),
              let bookmark = try? PlaybackBookmark.restore(data, availableIDs: Set(library.catalog.queue(playlistIDs: [], localIDs: downloads.readyIDs))) else { return }
        queue = bookmark.queue; wantsToPlay = false
        loadCurrent(position: bookmark.position)
    }

    func start(playlistIDs: [String], at mediaID: String? = nil, shuffle: Bool = false, offlineOnly: Bool = false) {
        let ids = library.catalog.queue(playlistIDs: playlistIDs, localIDs: downloads.readyIDs,
            offlineOnly: offlineOnly || !downloads.network.isConnected)
        guard !ids.isEmpty else { message = "No playable videos here yet. Download this playlist or import local videos."; return }
        let repeatMode = queue.repeatMode
        queue = PlaybackQueue(ids: ids, startAt: mediaID, shuffle: shuffle)
        queue.repeatMode = repeatMode
        wantsToPlay = true; remoteRetries.removeAll(); message = nil
        activateAudio(); loadCurrent()
    }

    func toggle() { wantsToPlay ? pause() : play() }
    func play() {
        guard current != nil else { return }
        wantsToPlay = true; activateAudio()
        if player.currentItem == nil { loadCurrent(position: clock.position) }
        else {
            if clock.duration > 0, clock.position >= clock.duration - 0.05 { seek(0) }
            player.play()
            prepareUpcoming()
            if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { armStallRecovery() }
        }
        persist(); updateNowPlaying()
    }
    func pause() {
        wantsToPlay = false; resumeAfterInterruption = false
        cancelStallRecovery()
        player.pause(); persist(); updateNowPlaying()
    }

    func next(explicit: Bool = true) {
        endedDuringScroll = false
        let previous = queue.currentID
        guard let next = queue.next(explicit: explicit) else { pause(); return }
        if next == previous, player.currentItem != nil { seek(0); if wantsToPlay { player.play() }; return }
        wantsToPlay = true; activateAudio(); loadCurrent()
    }

    func previous() {
        endedDuringScroll = false
        guard queue.previous() != nil else { seek(0); return }
        wantsToPlay = true; activateAudio(); loadCurrent()
    }

    func feedDidSettle(direction: Int) {
        isInteractingWithFeed = false
        if direction > 0 { next() }
        else if direction < 0 { previous() }
        else if endedDuringScroll { next(explicit: false) }
    }

    func setShuffle(_ enabled: Bool) { queue.setShuffle(enabled); prepareUpcoming(); persist() }
    func cycleRepeat() { queue.repeatMode = queue.repeatMode.next; prepareUpcoming(); persist() }
    func seek(_ seconds: Double) {
        guard let item = player.currentItem, item === observedItem,
              let seek = clock.beginSeek(to: seconds) else { return }
        let request = generation
        player.seek(to: CMTime(seconds: seek.target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.generation == request, self.player.currentItem === item,
                      self.clock.completeSeek(seek, actualPosition: item.currentTime().seconds) else { return }
                if !self.isVideoReady { self.monitorFirstFrame(item, request: request) }
                self.persist(); self.updateNowPlaying()
            }
        }
        persist(); updateNowPlaying()
    }

    private func loadCurrent(position: Double = 0, forceRemote: Bool = false) {
        endedDuringScroll = false
        let resume = MediaResumePosition(mediaID: queue.currentID, seconds: position)
        generation += 1; let request = generation
        cancelStallRecovery()
        loadTask?.cancel(); itemObservation = nil; frameMonitor.cancel(); observedItem = nil; readyGeneration = nil
        audioCheckTask?.cancel(); hasAudioTrack = nil
        isVideoReady = false
        warmTask?.cancel()
        clock.reset(position: position, duration: current?.duration ?? 0)
        isLoading = true
        if !forceRemote, position == 0, let id = queue.currentID,
           let prepared = buffer.advance(to: id, allowRemote: downloads.network.isConnected && !downloads.readyIDs.contains(id)) {
            currentIsLocal = prepared.isLocal
            observeCurrent(prepared.item, position: 0, request: request)
            prepareUpcoming()
            return
        }
        player.pause(); buffer.replace(with: nil)
        loadTask = Task { [weak self] in
            guard let self else { return }
            var visited = Set<String>()
            while let item = self.current, visited.insert(item.id).inserted {
                let itemPosition = resume.seconds(for: item.id)
                self.clock.reset(position: itemPosition, duration: item.duration)
                do {
                    let saved = await self.downloads.localURL(for: item)
                    let cached: URL?
                    if let asset = item.asset { cached = await self.mediaCache?.file(for: asset) } else { cached = nil }
                    let local = saved ?? cached
                    let url: URL
                    if let local { url = local }
                    else {
                        guard self.downloads.network.isConnected, let asset = item.asset else { throw AppError.message("No offline copy of this video.") }
                        url = try await self.cloud.downloadURL(asset, forceRefresh: forceRemote)
                    }
                    try Task.checkCancellation()
                    guard self.generation == request else { return }
                    self.currentIsLocal = local != nil
                    let playerItem = AVPlayerItem(url: url)
                    playerItem.preferredForwardBufferDuration = 8
                    await self.speakerAudio.prepare(playerItem)
                    try Task.checkCancellation()
                    guard self.generation == request else { return }
                    self.buffer.replace(with: playerItem)
                    self.observeCurrent(playerItem, position: itemPosition, request: request)
                    self.prepareUpcoming()
                    self.persist(); return
                } catch is CancellationError { return }
                catch {
                    guard self.generation == request else { return }
                    if !self.wantsToPlay { self.isLoading = false; return }
                    self.queue.markUnavailable(item.id)
                    guard self.queue.next() != nil else { break }
                }
            }
            guard self.generation == request else { return }
            self.isLoading = false; self.pause()
            self.message = "No available videos in this queue. Connect to your library or choose downloaded videos."
        }
    }

    private func observeCurrent(_ playerItem: AVPlayerItem, position: Double, request: Int) {
        observedItem = playerItem
        refreshAudioProcessing()
        audioCheckTask = Task { [weak self, weak playerItem] in
            guard let playerItem else { return }
            let tracks = try? await playerItem.asset.loadTracks(withMediaType: .audio)
            guard let self, !Task.isCancelled, self.generation == request, self.player.currentItem === playerItem else { return }
            self.hasAudioTrack = tracks.map { !$0.isEmpty }
        }
        // A restored offset must finish seeking before its first-frame epoch begins.
        if position == 0 { monitorFirstFrame(playerItem, request: request) }
        armStallRecovery()
        itemObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self, weak playerItem] _, _ in
            Task { @MainActor in
                guard let self, let playerItem, self.generation == request, self.player.currentItem === playerItem else { return }
                if playerItem.status == .readyToPlay {
                    guard self.readyGeneration != request else { return }
                    self.readyGeneration = request
                    self.clock.updateDuration(playerItem.duration.seconds)
                    self.isLoading = false
                    // A new or prebuffered item is already at zero; an exact zero seek discards that benefit.
                    if position > 0 { self.seek(position) }
                    if self.wantsToPlay { self.player.playImmediately(atRate: 1) }
                    self.updateNowPlaying()
                } else if playerItem.status == .failed { self.handlePlaybackFailure() }
            }
        }
    }

    private func monitorFirstFrame(_ playerItem: AVPlayerItem, request: Int) {
        frameMonitor.start(item: playerItem, layer: surface.playerLayer) { [weak self, weak playerItem] in
            guard let self, let playerItem, self.generation == request, self.player.currentItem === playerItem else { return }
            self.isVideoReady = true
        }
    }

    private func prepareUpcoming() {
        warmRevision += 1; let revision = warmRevision, request = generation
        warmTask?.cancel()
        var preview = queue
        var upcoming: [MediaRecord] = []
        for _ in 0..<2 {
            guard let id = preview.next(), id != queue.currentID, !upcoming.contains(where: { $0.id == id }),
                  let item = library.catalog.mediaByID[id] else { break }
            upcoming.append(item)
        }
        let active = current
        let previous = previousID.flatMap { library.catalog.mediaByID[$0] }
        if buffer.nextMediaID != upcoming.first?.id { buffer.discardNext() }
        warmTask = Task { [weak self] in
            guard let self else { return }
            let pinned = ([active, previous].compactMap { $0 } + upcoming).compactMap(\.asset)
            await self.mediaCache?.setWindow(pinned, revision: revision)
            guard !Task.isCancelled, self.generation == request else { return }
            // Resolve and enqueue the next AVPlayerItem before waiting for any full-file transfer.
            if let next = upcoming.first, !self.buffer.hasPrepared(next.id) {
                let saved = await self.downloads.localURL(for: next)
                let cached: URL?
                if let asset = next.asset { cached = await self.mediaCache?.file(for: asset) } else { cached = nil }
                var url = saved ?? cached
                if url == nil, self.downloads.network.isConnected, let asset = next.asset {
                    url = try? await self.cloud.downloadURL(asset)
                }
                guard !Task.isCancelled, self.generation == request, self.warmRevision == revision else { return }
                if let url {
                    let playerItem = AVPlayerItem(url: url)
                    playerItem.preferredForwardBufferDuration = 8
                    await self.speakerAudio.prepare(playerItem)
                    guard !Task.isCancelled, self.generation == request, self.warmRevision == revision else { return }
                    self.buffer.stage(.init(mediaID: next.id, item: playerItem, isLocal: saved != nil || cached != nil))
                    self.refreshAudioProcessing()
                }
            }
            guard self.downloads.network.isConnected, self.wantsToPlay else { return }
            // A small rolling window also keeps recently played clips ready for a downward swipe.
            for item in Array(upcoming.prefix(1)) + [previous].compactMap({ $0 }) + Array(upcoming.dropFirst()) + [active].compactMap({ $0 }) {
                guard !Task.isCancelled, self.warmRevision == revision else { return }
                guard let asset = item.asset else { continue }
                if await self.downloads.localURL(for: item) != nil { continue }
                if let url = await self.mediaCache?.prefetch(asset, revision: revision), item.id == upcoming.first?.id {
                    guard !Task.isCancelled, self.warmRevision == revision, self.generation == request else { return }
                    // Keep the prepared decoder. Promote the file now only for an offline handoff.
                    let requireLocal = !self.downloads.network.isConnected
                    if requireLocal || !self.buffer.hasPrepared(item.id) {
                        let playerItem = AVPlayerItem(url: url)
                        await self.speakerAudio.prepare(playerItem)
                        guard !Task.isCancelled, self.warmRevision == revision, self.generation == request else { return }
                        self.buffer.stage(.init(mediaID: item.id, item: playerItem, isLocal: true), requireLocal: requireLocal)
                        self.refreshAudioProcessing()
                    }
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
        guard wantsToPlay, stallTask == nil, player.currentItem != nil, let id = queue.currentID else { return }
        let ticket = PlaybackStallTicket(generation: generation, mediaID: id, position: clock.position,
                                         deadline: Date().addingTimeInterval(12))
        stallTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.stallTask = nil
            if ticket.shouldRecover(generation: self.generation, mediaID: self.queue.currentID,
                                    position: self.clock.position, wantsToPlay: self.wantsToPlay, now: Date()) {
                // Refresh a remote URL once, then skip the failed item through the bounded queue.
                self.handlePlaybackFailure()
            } else if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate { self.armStallRecovery() }
        }
    }

    func startPiP() {
        guard let pip, pip.isPictureInPicturePossible else { message = "Play a video on this screen before opening Picture in Picture."; return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    func persist() {
        lastBookmark = Date()
        do { try AppFiles.save(PlaybackBookmark(queue: queue, position: clock.position), to: bookmarkURL) }
        catch { message = "Could not save your playback position." }
    }

    private func configureAudio() {
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default) }
        catch { message = "Background audio could not be configured." }
    }
    private func activateAudio() {
        do { try AVAudioSession.sharedInstance().setActive(true); refreshAudioProcessing() }
        catch { message = "Audio is unavailable right now." }
    }

    private func refreshAudioProcessing() {
        let routes = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        speakerAudio.update(items: player.items(), enabled: SpeakerAudioMix.shouldEnhance(enabled: speakerSound, routes: routes))
    }

    private func installObservers() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate { self.armStallRecovery() }
                else if self.player.timeControlStatus == .playing { self.cancelStallRecovery() }
            }
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                self.armStallRecovery()
            }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                if self.isInteractingWithFeed { self.endedDuringScroll = true }
                else { self.next(explicit: false) }
            }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                self.handlePlaybackFailure()
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began {
                    let shouldResume = self.wantsToPlay; self.pause(); self.resumeAfterInterruption = shouldResume
                } else {
                    let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                    if self.resumeAfterInterruption && options.contains(.shouldResume) { self.play() }
                    self.resumeAfterInterruption = false
                }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.refreshAudioProcessing()
                if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configureAudio(); self?.loadCurrent(position: self?.clock.position ?? 0) }
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
            MPNowPlayingInfoPropertyPlaybackRate: wantsToPlay ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
    }
}

extension PlaybackService: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        requestPlayerUI?()
        DispatchQueue.main.async { completionHandler(true) }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        message = "Picture in Picture could not start. Try again while the video is playing."
    }
}
