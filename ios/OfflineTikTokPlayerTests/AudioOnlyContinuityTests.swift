import XCTest
import AVFoundation
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
        let service = makeService()
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.bID)
        try await until { service.audioSnapshot.frame > 2_400 }
        let player = service.player, item = service.player.currentItem
        let before = service.audioSnapshot
        service.setAudioOnly(true)
        XCTAssertTrue(service.isAudioOnly)
        XCTAssertTrue(service.surface.isHidden)
        XCTAssertTrue(preferences.bool(forKey: "audioOnly"))
        XCTAssertTrue(preferences.bool(forKey: "automaticPiP"), "Audio only must preserve the saved automatic PiP preference")
        try await until { service.audioSnapshot.frame > before.frame + 2_400 }
        XCTAssertEqual(service.audioSnapshot.token, before.token)
        XCTAssertEqual(service.audioSnapshot.visit, before.visit)
        XCTAssertTrue(service.player === player)
        XCTAssertTrue(service.player.currentItem === item)
        XCTAssertEqual(service.queue.currentID, fixture.bID)
        service.pause()
        try await until { !service.audioEngineRunning }
        service.persist()
        let position = service.clock.position
        // Simulate a relaunch by closing the original owner before restoring.
        // Keep its fixture files until the restored owner has also finished.
        try await fixture.closePlayback(service)
        let restoredAudio = ContinuousAudioPlayer()
        let restored = makeService(audio: restoredAudio)
        XCTAssertTrue(restored.isAudioOnly)
        XCTAssertTrue(restored.surface.isHidden)
        restored.restore()
        // Paused restoration publishes ownership/position without starting the
        // engine merely to consume a command. The fresh render cursor stays zero.
        try await until { restoredAudio.selectedID == fixture.bID && restoredAudio.entry(for: fixture.bID) != nil }
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
            let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads, cloud: fixture.cloud,
                bookmarkURL: fixture.bookmark, activateSession: {}, preferences: preferences))
            service.isInteractingWithFeed = true
            service.start(playlistIDs: [fixture.playlist], at: fixture.bID)
            try await until { service.audioSnapshot.frame > 2_400 }
            service.handleInterruption(began: true)
            service.setAudioOnly(true)
            service.enteredForeground()
            if mode == 2 { service.pause() }
            // Suspend withdraws permission first; the owned poll acknowledges
            // and pauses the engine before this becomes a frozen-cursor check.
            try await until { !service.audioEngineRunning }
            let stopped = service.audioSnapshot.frame
            XCTAssertFalse(service.wantsToPlay)
            XCTAssertFalse(service.audioEngineRunning)
            service.handleInterruption(began: false, shouldResume: mode != 0)
            if mode == 1 {
                try await until { service.audioSnapshot.frame > stopped + 2_400 }
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

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "The actual PCM playback condition must complete within five seconds")
    }
}
