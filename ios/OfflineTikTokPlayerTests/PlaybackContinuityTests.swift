import XCTest
import AVFoundation
import AudioToolbox
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class PlaybackContinuityTests: XCTestCase {
    func testSupersedingStartupSeekResumesOnlyTheLatestSeekWithPlayIntent() async throws {
        let fixture = try await ServiceFixture()
        defer { fixture.remove() }
        let bookmark = PlaybackBookmark(queue: PlaybackQueue(ids: fixture.ids, startAt: fixture.ids[0]), position: 0.4)
        try JSONEncoder().encode(bookmark).write(to: fixture.bookmark)
        var seeks: [(CMTime, (Bool) -> Void)] = []
        let service = PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
            bookmarkURL: fixture.bookmark, activateSession: {}, seekPlayer: { _, time, completion in seeks.append((time, completion)) })
        defer { service.pause() }
        service.restore(); service.play()
        try await until { !seeks.isEmpty }
        XCTAssertEqual(service.player.rate, 0, "The restored-position seek must gate startup")
        service.seek(0.2)
        XCTAssertEqual(seeks.count, 2)
        seeks[0].1(false)
        let latest = seeks[1]
        let finished = await service.player.seek(to: latest.0, toleranceBefore: .zero, toleranceAfter: .zero)
        latest.1(finished)
        try await until { service.player.rate > 0 }
        XCTAssertTrue(service.wantsToPlay)
        // A new scrub followed by explicit Pause must never resurrect playback.
        service.seek(0.3); service.pause()
        let paused = seeks[2]
        let pausedFinished = await service.player.seek(to: paused.0, toleranceBefore: .zero, toleranceAfter: .zero)
        paused.1(pausedFinished)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(service.wantsToPlay); XCTAssertEqual(service.player.rate, 0)
    }

    func testCoalescedAndDrainedLoopBoundariesReconcileActualCurrentItem() throws {
        for drain in [false, true] {
            let buffer = PlaybackBuffer(), original = try item(), reserve = try item()
            defer { buffer.replace(with: nil); buffer.discardPrevious() }
            buffer.replace(with: original, mediaID: "loop")
            buffer.stage(.init(mediaID: "loop", item: try item(), isLocal: true))
            buffer.stageLoopReserve(.init(mediaID: "loop", item: reserve, isLocal: true))
            var adopted: PlaybackBuffer.Prepared?
            buffer.didAdvance = { adopted = $0 }
            buffer.player.advanceToNextItem(); buffer.player.advanceToNextItem()
            if drain { buffer.player.advanceToNextItem() }
            buffer.synchronize()
            XCTAssertTrue(adopted?.item === reserve)
            XCTAssertEqual(adopted?.needsRewind, drain)
            XCTAssertTrue(buffer.player.currentItem === reserve)
            XCTAssertNil(buffer.nextMediaID); XCTAssertFalse(buffer.hasLoopReserve)
            XCTAssertEqual(buffer.player.items().count, 1)
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 2)
            buffer.stage(.init(mediaID: "loop", item: try item(), isLocal: true), after: "loop")
            XCTAssertTrue(buffer.hasPrepared("loop"))
        }
    }

    func testProductionServiceMeasuresIdenticalColdNextPreviousAndRetainsPreviousMix() async throws {
        let fixture = try await ServiceFixture()
        defer { fixture.remove() }
        let oldSpeakerPreference = UserDefaults.standard.object(forKey: "speakerSound")
        defer { UserDefaults.standard.set(oldSpeakerPreference, forKey: "speakerSound") }
        var trials: [[String: Any]] = []
        // Serial, bounded trials of the same local source, route and 50 ms clock threshold.
        for trial in 0..<3 {
            let buffer = PlaybackBuffer()
            var loads: [ObjectIdentifier: Int] = [:]
            let audio = SpeakerAudioController { item in
                loads[ObjectIdentifier(item), default: 0] += 1
                return try? await item.asset.loadTracks(withMediaType: .audio)
            }
            let service = PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
                bookmarkURL: fixture.bookmark, activateSession: { try AVAudioSession.sharedInstance().setActive(true) },
                buffer: buffer, speakerAudio: audio, audioRoutes: { [.builtInSpeaker] })
            service.speakerSound = true; service.isInteractingWithFeed = true
            var events: [[String: Any]] = []
            service.onPlaybackEvent = { event in
                events.append(["phase": event.name, "uptime": event.uptime, "generation": event.generation,
                               "position": event.position.isFinite ? event.position : -1, "retainedItems": event.retainedItems])
            }
            defer { service.onPlaybackEvent = nil; service.pause(); buffer.replace(with: nil); buffer.discardPrevious() }
            let coldStart = ProcessInfo.processInfo.systemUptime
            service.start(playlistIDs: [fixture.playlist], at: fixture.ids[0])
            try await until { service.player.currentTime().seconds >= 0.05 }
            let cold = ProcessInfo.processInfo.systemUptime - coldStart
            service.pause()
            let first = try XCTUnwrap(service.player.currentItem)
            try await until { first.audioMix != nil }
            let firstMix = try XCTUnwrap(first.audioMix)
            let firstLoads = loads[ObjectIdentifier(first)]
            try await until { buffer.hasPrepared(fixture.ids[1]) }
            try await Task.sleep(for: .milliseconds(500))
            let queuedReady = buffer.player.items().last?.status == .readyToPlay
            let nextStart = ProcessInfo.processInfo.systemUptime
            service.next()
            try await until { service.queue.currentID == fixture.ids[1] && service.player.currentTime().seconds >= 0.05 }
            let next = ProcessInfo.processInfo.systemUptime - nextStart
            service.pause()
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(first.audioMix === firstMix, "Retained Previous must keep its configured mix")
            XCTAssertEqual(loads[ObjectIdentifier(first)], firstLoads)
            let previousStart = ProcessInfo.processInfo.systemUptime
            service.previous()
            try await until { service.queue.currentID == fixture.ids[0] && service.player.currentTime().seconds >= 0.05 }
            let previous = ProcessInfo.processInfo.systemUptime - previousStart
            XCTAssertTrue(service.player.currentItem === first)
            XCTAssertTrue(first.audioMix === firstMix, "Previous must not rebuild its audio path on handoff")
            XCTAssertEqual(loads[ObjectIdentifier(first)], firstLoads, "Previous must not reload its audio-track metadata")
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 4)
            XCTAssertLessThan(max(cold, next, previous), 2, "Synthetic local startup stalled; this is not an immediate-play acceptance threshold")
            let result: [String: Any] = ["trial": trial, "coldClock50msSeconds": cold, "nextClock50msSeconds": next,
                "previousClock50msSeconds": previous, "queuedReadyBeforeHandoff": queuedReady,
                "previousMixReused": first.audioMix === firstMix, "previousTrackLoads": loads[ObjectIdentifier(first)] ?? 0,
                "retainedItems": buffer.retainedItemCount, "events": events]
            trials.append(result)
            print("Production service timing: trial=\(trial), cold=\(cold), next=\(next), previous=\(previous), queuedReady=\(queuedReady), previousMixReused=\(first.audioMix === firstMix)")
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: trials, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Production-service-identical-startup-phases"; attachment.lifetime = .keepAlways; add(attachment)
        print("Production service phase trace: \(String(data: try JSONSerialization.data(withJSONObject: trials, options: [.sortedKeys]), encoding: .utf8)!)")
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Playback condition did not complete in five seconds")
    }

    @MainActor private struct ServiceFixture {
        let temporary: URL
        let cloud: OneDriveClient
        let downloads: OfflineDownloads
        let library: LibraryRepository
        let ids: [String]
        let playlist = "local:service-timing"
        var bookmark: URL { temporary.appendingPathComponent("playback.json") }
        init() async throws {
            temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            cloud = OneDriveClient(account: MicrosoftAccount())
            downloads = OfflineDownloads(cloud: cloud, network: NetworkStatus())
            library = LibraryRepository(cloud: cloud, catalogURL: temporary.appendingPathComponent("catalog.json"))
            ids = (0..<2).map { "local:service-\($0)-" + UUID().uuidString }
            let source = try XCTUnwrap(Bundle(for: PlaybackContinuityTests.self).url(forResource: "test-video", withExtension: "mp4"))
            for id in ids { _ = try await downloads.importLocal(source, mediaID: id) }
            try library.install(LibraryCatalog(libraryID: "local:test", media: ids.map { MediaRecord(id: $0, title: "Synthetic", creator: "Fixture", duration: 1.2) },
                playlists: [PlaylistRecord(id: playlist, name: "Synthetic", itemIDs: ids)]))
        }
        func remove() { for id in ids { downloads.remove(id) }; try? FileManager.default.removeItem(at: temporary) }
    }
    func testAutomaticHandoffReResolvesRemotePreparationWhenASavedCopyIsAvailable() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let cloud = OneDriveClient(account: MicrosoftAccount()), network = NetworkStatus()
        let downloads = OfflineDownloads(cloud: cloud, network: network)
        let library = LibraryRepository(cloud: cloud, catalogURL: temporary.appendingPathComponent("catalog.json"))
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let ids = (0..<2).map { "local:handoff-\($0)-" + UUID().uuidString }
        let records = ids.map { MediaRecord(id: $0, title: "Synthetic tone", creator: "Fixture", duration: 1.2) }
        for id in ids { _ = try await downloads.importLocal(source, mediaID: id) }
        defer { for id in ids { downloads.remove(id) } }
        try library.install(LibraryCatalog(libraryID: "local:test", media: records,
            playlists: [PlaylistRecord(id: "local:handoff", name: "Synthetic", itemIDs: ids)]))
        let buffer = PlaybackBuffer()
        let service = PlaybackService(library: library, downloads: downloads, cloud: cloud,
            bookmarkURL: temporary.appendingPathComponent("playback.json"), activateSession: {}, buffer: buffer)
        defer { service.pause(); buffer.replace(with: nil); buffer.discardPrevious() }
        service.start(playlistIDs: ["local:handoff"], at: ids[0])
        let preparedDeadline = Date().addingTimeInterval(5)
        while !buffer.hasPrepared(ids[1]), Date() < preparedDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(buffer.hasPrepared(ids[1]))
        buffer.player.pause(); buffer.discardNext()
        // Emulate a stage resolved before its Saved download finished.
        let remote = AVPlayerItem(url: source)
        buffer.stage(.init(mediaID: ids[1], item: remote, isLocal: false))
        buffer.player.advanceToNextItem(); buffer.synchronize()
        let deadline = Date().addingTimeInterval(5)
        while service.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.queue.currentID, ids[1])
        XCTAssertFalse(service.player.currentItem === remote, "Automatic handoff must not bypass Saved eligibility")
        let savedCandidate = await downloads.localURL(for: records[1])
        let saved = try XCTUnwrap(savedCandidate)
        let current = try XCTUnwrap(service.player.currentItem)
        XCTAssertEqual((current.asset as? AVURLAsset)?.url, saved)
    }

    func testServiceReadinessAndForegroundRespectInterruptionPauseAndActivationFailure() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let cloud = OneDriveClient(account: MicrosoftAccount()), network = NetworkStatus()
        let downloads = OfflineDownloads(cloud: cloud, network: network)
        let library = LibraryRepository(cloud: cloud, catalogURL: temporary.appendingPathComponent("catalog.json"))
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let id = "local:continuity-" + UUID().uuidString
        _ = try await downloads.importLocal(url, mediaID: id)
        defer { downloads.remove(id) }
        try library.install(LibraryCatalog(libraryID: "local:test", media: [MediaRecord(id: id, title: "Synthetic tone", creator: "Fixture", duration: 1.2)], playlists: []))
        var activations = 0, rejectActivation = false
        let service = PlaybackService(library: library, downloads: downloads, cloud: cloud,
            bookmarkURL: temporary.appendingPathComponent("playback.json"), activateSession: {
                activations += 1
                if rejectActivation { throw NSError(domain: "SyntheticBusySession", code: 1) }
            })
        defer { service.pause() }
        service.start(playlistIDs: [], at: id)
        service.handleInterruption(began: true); service.handleInterruption(began: true)
        let deadline = Date().addingTimeInterval(5)
        while service.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.player.rate, 0, "Async readiness must not restart an interrupted session")
        service.enteredForeground()
        service.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(activations, 2)
        service.persist(); service.enteredForeground()
        XCTAssertTrue(service.wantsToPlay, "A normal background/foreground cycle must preserve playback")
        XCTAssertEqual(activations, 2)
        service.handleInterruption(began: true); service.pause()
        service.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(activations, 2, "An explicit pause must cancel automatic reactivation")
        service.enteredForeground(); XCTAssertEqual(service.player.rate, 0)
        rejectActivation = true; service.play()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(service.player.rate, 0)
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.queue.currentID, id)
    }

    private func item() throws -> AVPlayerItem {
        AVPlayerItem(url: try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4")))
    }

    func testPreparedBoundaryAdvancesAutomaticallyWithoutZeroSeek() async throws {
        let buffer = PlaybackBuffer(), first = try item(), second = try item()
        defer { buffer.player.pause(); buffer.replace(with: nil) }
        buffer.replace(with: first, mediaID: "a")
        var transitions = 0
        buffer.didAdvance = { prepared in
            XCTAssertEqual(prepared.mediaID, "b"); transitions += 1
        }
        buffer.stage(.init(mediaID: "b", item: second, isLocal: true))
        XCTAssertEqual(buffer.player.actionAtItemEnd, .advance)
        buffer.player.playImmediately(atRate: 1)
        let deadline = Date().addingTimeInterval(6)
        while transitions == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(transitions, 1)
        XCTAssertTrue(buffer.player.currentItem === second)
        XCTAssertEqual(buffer.player.actionAtItemEnd, .pause, "The final item must remain visible at queue end")
        let end = Date().addingTimeInterval(4)
        while buffer.player.rate != 0, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(buffer.player.rate, 0)
        XCTAssertTrue(buffer.player.currentItem === second)
        XCTAssertEqual(transitions, 1)
    }

    func testRepeatUsesCompletePreparedItemAndExplicitNextCanReplaceIt() throws {
        let buffer = PlaybackBuffer(), original = try item(), repeated = try item(), skipped = try item()
        defer { buffer.replace(with: nil) }
        buffer.replace(with: original, mediaID: "a")
        buffer.stage(.init(mediaID: "a", item: repeated, isLocal: true))
        XCTAssertEqual(repeated.forwardPlaybackEndTime, .invalid)
        XCTAssertEqual(repeated.reversePlaybackEndTime, original.reversePlaybackEndTime)
        buffer.stage(.init(mediaID: "b", item: skipped, isLocal: true))
        XCTAssertTrue(buffer.advance(to: "b")?.item === skipped)
    }

    func testRapidForwardBackwardReusesPreparedPreviousAndBoundsRetainedItems() throws {
        let buffer = PlaybackBuffer()
        buffer.replace(with: try item(), mediaID: "a")
        defer { buffer.replace(with: nil) }
        for _ in 0..<100 {
            buffer.stage(.init(mediaID: "b", item: try item(), isLocal: true))
            XCTAssertNotNil(buffer.advance(to: "b"))
            XCTAssertNotNil(buffer.advance(to: "a"))
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)
            XCTAssertLessThanOrEqual(buffer.player.items().count, 2)
        }
        buffer.discardPrevious()
        XCTAssertLessThanOrEqual(buffer.retainedItemCount, 2)
    }

    func testFeedGestureDefersAutomaticBoundaryAndPauseIsNotLost() throws {
        let buffer = PlaybackBuffer(), original = try item()
        buffer.replace(with: original, mediaID: "a")
        defer { buffer.replace(with: nil) }
        buffer.stage(.init(mediaID: "b", item: try item(), isLocal: true))
        buffer.automaticAdvancementEnabled = false
        XCTAssertEqual(buffer.player.actionAtItemEnd, .pause)
        buffer.player.pause()
        buffer.automaticAdvancementEnabled = true
        XCTAssertEqual(buffer.player.rate, 0)
        XCTAssertTrue(buffer.player.currentItem === original)
        XCTAssertEqual(buffer.player.actionAtItemEnd, .advance)
    }

    func testPreparedPreviousRewindsBeforePlaybackAndMeasuresClockLatency() async throws {
        let buffer = PlaybackBuffer(), first = try item(), second = try item()
        defer { buffer.player.pause(); buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.replace(with: first, mediaID: "a")
        let coldStart = ProcessInfo.processInfo.systemUptime
        buffer.player.playImmediately(atRate: 1)
        var deadline = Date().addingTimeInterval(5)
        while first.currentTime().seconds < 0.1, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(first.currentTime().seconds, 0.1)
        let cold = ProcessInfo.processInfo.systemUptime - coldStart
        buffer.stage(.init(mediaID: "b", item: second, isLocal: true))
        XCTAssertNotNil(buffer.advance(to: "b"))
        // Give the same preparation window as an ordinary prepared swipe.
        try await Task.sleep(for: .milliseconds(500))
        let start = ProcessInfo.processInfo.systemUptime
        let previous = try XCTUnwrap(buffer.advance(to: "a"))
        XCTAssertTrue(previous.item === first)
        let rewoundBeforeHandoff = !previous.needsRewind
        XCTAssertTrue(rewoundBeforeHandoff, "The local ready history item should rewind during preparation")
        XCTAssertEqual(buffer.player.rate, 0, "History must not briefly play its former offset")
        if previous.needsRewind {
            let finished = await withCheckedContinuation { continuation in
                buffer.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(finished)
        }
        XCTAssertEqual(first.currentTime().seconds, 0, accuracy: 0.005)
        buffer.player.playImmediately(atRate: 1)
        deadline = Date().addingTimeInterval(5)
        while first.currentTime().seconds < 0.1, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(first.currentTime().seconds, 0.1)
        let previousLatency = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(previousLatency, 2, "Reusing history must not repeatedly resolve the asset URL or metadata")
        print("Previous clock timing fixture: cold=\(cold), retainedPreviousIncludingRewind=\(previousLatency), rewindPreparedBeforeHandoff=\(rewoundBeforeHandoff), retainedItems=\(buffer.retainedItemCount)")
    }

    func testStalePreparationCannotAttachAfterAnAlreadyAdvancedBoundary() throws {
        let buffer = PlaybackBuffer(), first = try item(), second = try item()
        defer { buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.replace(with: first, mediaID: "a")
        buffer.stage(.init(mediaID: "b", item: second, isLocal: true), after: "a")
        buffer.player.advanceToNextItem() // KVO is queued, as with a boundary racing a swipe.
        buffer.stage(.init(mediaID: "stale", item: try item(), isLocal: true), after: "a")
        XCTAssertTrue(buffer.player.currentItem === second)
        XCTAssertNil(buffer.nextMediaID)
        XCTAssertEqual(buffer.player.items().count, 1)
        XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)
    }

    func testLoopReserveHasAFixedBoundAndExplicitSkipRemovesIt() throws {
        let buffer = PlaybackBuffer()
        defer { buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.replace(with: try item(), mediaID: "a")
        buffer.stagePrevious(.init(mediaID: "history", item: try item(), isLocal: true))
        buffer.stage(.init(mediaID: "a", item: try item(), isLocal: true))
        for _ in 0..<50 { buffer.stageLoopReserve(.init(mediaID: "a", item: try item(), isLocal: true)) }
        XCTAssertEqual(buffer.player.items().count, 3)
        XCTAssertEqual(buffer.retainedItemCount, 4)
        XCTAssertFalse(buffer.player.automaticallyWaitsToMinimizeStalling)
        buffer.stage(.init(mediaID: "b", item: try item(), isLocal: true))
        XCTAssertFalse(buffer.hasLoopReserve)
        XCTAssertEqual(buffer.player.items().count, 2)
        XCTAssertNotNil(buffer.advance(to: "b"))
        XCTAssertFalse(buffer.hasLoopReserve)
        XCTAssertEqual(buffer.player.actionAtItemEnd, .pause)
        XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)
    }

    func testHTTPPreparationKeepsAutomaticStallRecoveryUntilLocalHandoff() throws {
        let buffer = PlaybackBuffer()
        defer { buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.replace(with: try item(), mediaID: "a", isLocal: false)
        buffer.stage(.init(mediaID: "b", item: try item(), isLocal: false))
        XCTAssertTrue(buffer.player.automaticallyWaitsToMinimizeStalling)
        buffer.stage(.init(mediaID: "b", item: try item(), isLocal: true), requireLocal: true)
        XCTAssertNotNil(buffer.advance(to: "b", allowRemote: false))
        XCTAssertFalse(buffer.player.automaticallyWaitsToMinimizeStalling)
    }

    func testFullDurationLoopsRecordBoundarySchedulingAndEncodedSourceSilence() async throws {
        let first = try item(), asset = first.asset
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1
        ])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var samples = 0, firstAudible: Int?, lastAudible: Int?
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            _ = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            bytes.withUnsafeBytes { data in
                for value in data.bindMemory(to: Float.self) {
                    if abs(value) > 0.001 { if firstAudible == nil { firstAudible = samples }; lastAudible = samples }
                    samples += 1
                }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(samples, 48000)
        let buffer = PlaybackBuffer()
        defer { buffer.player.pause(); buffer.didAdvance = nil; buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.replace(with: first, mediaID: "loop")
        var departed = first, completeTimes: [Double] = [], schedulingGaps: [Double] = []
        var callbackOffsets: [Double] = [], arrivingPositions: [Double] = []
        var anchorHost: Double?, anchorPosition = 0.0
        buffer.didAdvance = { prepared in
            completeTimes.append(departed.currentTime().seconds)
            let host = ProcessInfo.processInfo.systemUptime
            let arrived = prepared.item.currentTime().seconds
            XCTAssertTrue(arrived.isFinite)
            if let anchorHost {
                let callbackOffset = host - anchorHost - (duration - anchorPosition)
                callbackOffsets.append(callbackOffset)
                // KVO delivery may lag while the incoming item is already playing.
                // Subtract that progress instead of reporting it as a player gap.
                schedulingGaps.append(callbackOffset - arrived)
                arrivingPositions.append(arrived)
            }
            departed = prepared.item
            anchorHost = host
            anchorPosition = arrived
            if completeTimes.count < 3 {
                buffer.stageLoopReserve(.init(mediaID: "loop", item: AVPlayerItem(asset: asset), isLocal: true))
                XCTAssertLessThanOrEqual(buffer.retainedItemCount, 4)
            }
        }
        buffer.stage(.init(mediaID: "loop", item: AVPlayerItem(asset: asset), isLocal: true))
        buffer.stageLoopReserve(.init(mediaID: "loop", item: AVPlayerItem(asset: asset), isLocal: true))
        XCTAssertEqual(buffer.player.items().count, 3)
        buffer.player.playImmediately(atRate: 1)
        let deadline = Date().addingTimeInterval(10)
        while first.currentTime().seconds < 0.1, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        anchorHost = ProcessInfo.processInfo.systemUptime; anchorPosition = first.currentTime().seconds
        while completeTimes.count < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(completeTimes.count, 3)
        for end in completeTimes { XCTAssertGreaterThanOrEqual(end, duration - 0.025, "Looping must not cut off the source tail") }
        for gap in schedulingGaps { XCTAssertLessThan(abs(gap), 0.15, "Prepared loop scheduling added an observable gap") }
        let metrics: [String: Any] = ["durationSeconds": duration, "decodedSourceSamples48000Hz": samples,
            "sourceLeadingBelowMinus60dBSeconds": Double(firstAudible ?? samples) / 48000,
            "sourceTrailingBelowMinus60dBSeconds": Double(samples - 1 - (lastAudible ?? -1)) / 48000,
            "completedItemTimes": completeTimes, "boundaryClockGapEstimatesSeconds": schedulingGaps,
            "rawCallbackOffsetsSeconds": callbackOffsets, "arrivingItemPositionsSeconds": arrivingPositions]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics, options: .sortedKeys), uniformTypeIdentifier: "public.json")
        attachment.name = "Full-source-loop-boundaries"; attachment.lifetime = .keepAlways; add(attachment)
        print("Full source loop metrics: \(metrics)")
    }
}
