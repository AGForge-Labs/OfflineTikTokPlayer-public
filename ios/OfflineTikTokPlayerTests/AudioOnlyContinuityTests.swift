import XCTest
import AVFoundation
import Synchronization
@testable import OfflineTikTokPlayer

@MainActor
final class AudioOnlyContinuityTests: XCTestCase {
    func testLibraryAudioOnlyPersistsAndRestoresPausedPCMSelection() async throws {
        let suite = "AudioOnlyContinuity-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "automaticPiP")
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let ownedDirectory = fixture.temporary
        // Registered before own(): LIFO teardown closes playback, then checks deletion.
        addTeardownBlock {
            XCTAssertFalse(FileManager.default.fileExists(atPath: ownedDirectory.path),
                           "Owned media must be removed after acknowledged playback shutdown")
        }
        func makeService(audio: ContinuousAudioPlayer? = nil) -> PlaybackService {
            fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
                bookmarkURL: fixture.bookmark, activateSession: {}, continuousAudio: audio, preferences: preferences))
        }
        let audio = ContinuousAudioPlayer()
        let service = makeService(audio: audio)
        #if DEBUG
        service.debugInitialLoadPhaseEnabled = true
        #endif
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.bID)
        try await until(service: service, audio: audio, stage: "persist-start-B") { service.audioSnapshot.frame > 2_400 }
        let player = service.player, item = service.player.currentItem
        let before = service.audioSnapshot
        service.setAudioOnly(true)
        XCTAssertTrue(service.isAudioOnly)
        XCTAssertTrue(service.surface.isHidden)
        XCTAssertTrue(preferences.bool(forKey: "audioOnly"))
        XCTAssertTrue(preferences.bool(forKey: "automaticPiP"), "Audio only must preserve the saved automatic PiP preference")
        try await until(service: service, audio: audio, stage: "persist-audio-only-progress") { service.audioSnapshot.frame > before.frame + 2_400 }
        XCTAssertEqual(service.audioSnapshot.token, before.token)
        XCTAssertEqual(service.audioSnapshot.visit, before.visit)
        XCTAssertTrue(service.player === player)
        XCTAssertTrue(service.player.currentItem === item)
        XCTAssertEqual(service.queue.currentID, fixture.bID)
        service.pause()
        try await until(service: service, audio: audio, stage: "persist-pause-engine") { !service.audioEngineRunning }
        service.persist()
        let position = service.clock.position
        // Simulate a relaunch by closing the original owner before restoring.
        // Keep its fixture files until the restored owner has also finished.
        try await fixture.closePlayback(service)
        let restoredAudio = ContinuousAudioPlayer()
        let restored = makeService(audio: restoredAudio)
        XCTAssertTrue(restored.isAudioOnly)
        XCTAssertTrue(restored.surface.isHidden)
        #if DEBUG
        restored.debugInitialLoadPhaseEnabled = true
        #endif
        restored.restore()
        // Paused restoration publishes ownership/position without starting the
        // engine merely to consume a command. The fresh render cursor stays zero.
        try await until(service: restored, audio: restoredAudio, stage: "restore-paused-ownership") { restoredAudio.selectedID == fixture.bID && restoredAudio.entry(for: fixture.bID) != nil }
        XCTAssertEqual(restored.queue.currentID, fixture.bID)
        XCTAssertEqual(restoredAudio.presentationPosition(at: CMClockGetTime(CMClockGetHostTimeClock())),
                       position, accuracy: 1.0 / 48_000)
        XCTAssertEqual(restored.queue.eligibleIDs, service.queue.eligibleIDs)
        XCTAssertEqual(restored.clock.position, position, accuracy: 1.0 / 48_000)
        XCTAssertFalse(restored.wantsToPlay)
        XCTAssertFalse(restored.audioEngineRunning)
        let stopped = restored.audioSnapshot.frame
        restored.setAudioOnly(false)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(restored.isAudioOnly)
        XCTAssertFalse(restored.surface.isHidden)
        XCTAssertFalse(preferences.bool(forKey: "audioOnly"))
        XCTAssertFalse(restored.wantsToPlay)
        XCTAssertFalse(restored.audioEngineRunning)
        XCTAssertEqual(restored.audioSnapshot.frame, stopped)
    }

    func testLibraryAudioOnlyHonorsCameraResumePermissionAndExplicitPause() async throws {
        for mode in 0..<3 { // denied, allowed, allowed after explicit user Pause
            let suite = "AudioOnlyInterruption-" + UUID().uuidString
            let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { preferences.removePersistentDomain(forName: suite) }
            let fixture = try await SelectionVideoFixture(test: self)
            defer { fixture.remove() }
            let audio = ContinuousAudioPlayer()
            let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
                bookmarkURL: fixture.bookmark, activateSession: {}, continuousAudio: audio, preferences: preferences))
            #if DEBUG
            service.debugInitialLoadPhaseEnabled = true
            #endif
            service.isInteractingWithFeed = true
            service.start(playlistIDs: [fixture.playlist], at: fixture.bID)
            try await until(service: service, audio: audio, stage: "camera-start-B-mode-\(mode)") { service.audioSnapshot.frame > 2_400 }
            service.handleInterruption(began: true)
            service.setAudioOnly(true)
            service.enteredForeground()
            if mode == 2 { service.pause() }
            // Suspend withdraws permission first; the owned poll acknowledges
            // and pauses the engine before this becomes a frozen-cursor check.
            try await until(service: service, audio: audio, stage: "camera-stop-mode-\(mode)") { !service.audioEngineRunning }
            let stopped = service.audioSnapshot.frame
            XCTAssertFalse(service.wantsToPlay)
            XCTAssertFalse(service.audioEngineRunning)
            service.handleInterruption(began: false, shouldResume: mode != 0)
            if mode == 1 {
                try await until(service: service, audio: audio, stage: "camera-resume-mode-\(mode)") { service.audioSnapshot.frame > stopped + 2_400 }
                XCTAssertTrue(service.wantsToPlay)
            } else {
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertFalse(service.wantsToPlay)
                XCTAssertFalse(service.audioEngineRunning)
                XCTAssertEqual(service.audioSnapshot.frame, stopped)
            }
            XCTAssertTrue(service.isAudioOnly)
            XCTAssertEqual(service.queue.currentID, fixture.bID)
            // Scope-exit defer cannot await; serialize these real native owners explicitly.
            try await fixture.close()
        }
    }

    private func until(service: PlaybackService, audio: ContinuousAudioPlayer, stage: String,
                       file: StaticString = #filePath, line: UInt = #line,
                       _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let completed = condition()
        XCTAssertTrue(completed, "The actual PCM playback condition must complete within five seconds: " + stage,
                      file: file, line: line)
        #if DEBUG
        if !completed {
            // Failure-only cached/owned state: no extra SDK position/session reads.
            let sample = audio.snapshot, selection = audio.debugSelectionState
            let load = service.debugInitialLoadPhaseState, prep = audio.debugPreparationState
            print("AudioOnlyFailureState schema=1 stage=\(stage) deadlineSeconds=5 current=\(service.queue.currentID ?? "none") selected=\(audio.selectedID ?? "none") entryToken=\(service.queue.currentID.flatMap { audio.entry(for: $0)?.token } ?? 0) token=\(sample.token) frame=\(sample.frame) visit=\(sample.visit) ended=\(sample.ended) underrunFrames=\(sample.underrunFrames) selectionVersion=\(sample.selectionVersion) selectedToken=\(selection.selectedToken) selectionPending=\(audio.isSelectionPending(in: sample)) engineRunning=\(service.audioEngineRunning) wantsPlaying=\(service.wantsToPlay) audioOnly=\(service.isAudioOnly) loading=\(service.isLoading) videoReady=\(service.isVideoReady) preparedCount=\(service.preparedAudioCount) loadRequest=\(load.request) generation=\(load.generation) loadPhase=\(load.phase.rawValue) activePreparations=\(prep.activeCalls) sharedPreparations=\(prep.sharedTasks) reservedSlots=\(prep.reservedSlots)")
            for event in service.debugCachedPlaybackDiagnostics.entries.suffix(8) {
                print("AudioOnlyFailureJournal schema=1 stage=\(stage) sequence=\(event.sequence) elapsed=\(event.elapsedSeconds) phase=\(event.phase.rawValue) requested=\(event.snapshot.audioRequested) permitted=\(event.snapshot.audioPermitted) interrupted=\(event.snapshot.audioInterrupted) engineRunning=\(event.snapshot.engineRunning) pipeline=\(event.snapshot.pipeline.rawValue) errorFamily=\(event.error?.family.rawValue ?? 0) errorCode=\(event.error?.code ?? 0)")
            }
            let response = Mutex<ContinuousPCMDecoder.DebugFailureState?>(nil)
            audio.debugDecoderFailureState { state in response.withLock { $0 = state } }
            let evidenceDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while response.withLock({ $0 == nil }), ContinuousClock.now < evidenceDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            if let state = response.withLock({ $0 }) {
                let stats = state.stats
                print("AudioOnlyFailureWorker schema=1 stage=\(stage) returned=true leased=\(stats.leasedReaders) starting=\(stats.startingLeases) retired=\(stats.retiredLeasesAwaitingClose) preparations=\(stats.pendingPreparations) pendingReads=\(stats.readJobsAwaitingAcceptanceOrClose) packets=\(stats.mailboxPackets) shutdown=\(stats.shutdownRequested) closed=\(stats.readerLeasesClosed)")
                for slot in state.slots {
                    print("AudioOnlyFailureSlot schema=1 stage=\(stage) slot=\(slot.index) token=\(slot.token) epoch=\(slot.epoch) cancelled=\(slot.cancelled) finished=\(slot.finished) hasStream=\(slot.stream != nil) cursor=\(slot.stream?.cursor ?? -1) generated=\(slot.stream?.generatedFrames ?? -1) outputCount=\(slot.stream?.outputCount ?? -1)")
                }
                for lease in state.leases {
                    print("AudioOnlyFailureLease schema=1 stage=\(stage) lane=\(lease.index) present=\(lease.present) starting=\(lease.starting) pending=\(lease.readPending) retired=\(lease.retired) requestedFrames=\(lease.requestedFrames) packetFrames=\(lease.packetFrames) packetOffset=\(lease.packetOffset) eof=\(lease.reachedEnd) failed=\(lease.hasFailure)")
                }
            } else {
                print("AudioOnlyFailureWorker schema=1 stage=\(stage) returned=false evidenceDeadlineSeconds=1 playbackDeadlineUnchanged=true")
            }
        }
        #endif
    }
}
