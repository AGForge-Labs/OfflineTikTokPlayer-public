import XCTest
import AVFoundation
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class AudioOutputContinuityTests: XCTestCase {
    private enum SyntheticFailure: Error { case engineStart }

    func testConfigurationChangeReactivatesSessionBeforeRestartingCurrentOutput() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer()
        var activations = 0
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads,
            cloud: fixture.cloud, bookmarkURL: fixture.bookmark, activateSession: {
                activations += 1
                try AVAudioSession.sharedInstance().setActive(true)
            }, continuousAudio: audio))
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { service.audioSnapshot.frame > 4_800 }
        let before = service.audioSnapshot, baselineActivations = activations
        var activationCountAtRestart: Int?
        audio.graph.engine.stop()
        audio.debugAfterEngineStart = {
            audio.debugAfterEngineStart = nil
            activationCountAtRestart = activations
        }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: audio.graph.engine)
        try await until { activations > baselineActivations && service.audioSnapshot.frame > before.frame + 4_800 }
        XCTAssertGreaterThan(activations, baselineActivations, "Output recovery must reactivate the session before trusting an engine restart")
        XCTAssertGreaterThan(try XCTUnwrap(activationCountAtRestart), baselineActivations,
                             "The successful session activation must precede the real engine start")
        assertSameSelection(service, before, id: fixture.aID)
        service.pause()
    }

    func testOneEngineStartFailureRecoversWithoutManualPlayOrSelectionChange() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer(), service = fixture.service(continuousAudio: audio)
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { service.audioSnapshot.frame > 4_800 }
        let before = service.audioSnapshot
        var failures = 0
        audio.graph.engine.stop()
        audio.debugAfterEngineStart = {
            audio.debugAfterEngineStart = nil
            failures += 1
            throw SyntheticFailure.engineStart
        }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: audio.graph.engine)
        try await until { failures == 1 }
        let afterFailure = service.audioSnapshot
        try await until { service.audioSnapshot.frame > afterFailure.frame + 4_800 && service.wantsToPlay }
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(service.wantsToPlay)
        XCTAssertTrue(service.audioEngineRunning)
        assertSameSelection(service, before, id: fixture.aID)
        service.pause()
    }

    func testMediaServicesResetRetainsPlayingIntentAndCurrentSelection() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer(), service = fixture.service(continuousAudio: audio)
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        service.cycleRepeat(); service.cycleRepeat()
        try await until { service.audioSnapshot.frame > 4_800 }
        let position = service.clock.position
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        try await until { service.wantsToPlay && service.clock.position > position + 0.1 }
        XCTAssertEqual(service.queue.currentID, fixture.aID)
        XCTAssertEqual(service.queue.repeatMode, .one)
        XCTAssertTrue(service.audioEngineRunning)
        service.pause()
    }

    func testDelayedConfigurationRecoveryCannotUndoExplicitPauseOrDeniedInterruption() async throws {
        for denied in [false, true] {
            let fixture = try await SelectionVideoFixture(test: self)
            defer { fixture.remove() }
            let audio = ContinuousAudioPlayer(), service = fixture.service(continuousAudio: audio)
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await until { service.audioSnapshot.frame > 4_800 }
            audio.graph.engine.stop()
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: audio.graph.engine)
            if denied {
                service.handleInterruption(began: true)
                service.handleInterruption(began: false, shouldResume: false)
            } else { service.pause() }
            try await Task.sleep(for: .milliseconds(1_300))
            XCTAssertFalse(service.wantsToPlay)
            XCTAssertFalse(service.audioEngineRunning)
            XCTAssertEqual(service.queue.currentID, fixture.aID)
            try await fixture.close()
        }
    }

    func testStaleActivationFailureCannotSuspendNewerSameMediaPlay() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer()
        weak var owned: PlaybackService?
        var inject = false
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads,
            cloud: fixture.cloud, bookmarkURL: fixture.bookmark, activateSession: {
                try AVAudioSession.sharedInstance().setActive(true)
                if inject {
                    inject = false
                    owned?.pause(); owned?.play()
                    throw SyntheticFailure.engineStart
                }
            }, continuousAudio: audio))
        owned = service
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { service.audioSnapshot.frame > 4_800 }
        let before = service.audioSnapshot
        inject = true; service.play()
        XCTAssertTrue(service.wantsToPlay, "An old failure must not revoke the newer successful Play")
        let after = service.audioSnapshot
        try await until { service.audioSnapshot.frame > after.frame + 4_800 }
        assertSameSelection(service, before, id: fixture.aID)
        service.pause()
    }

    func testStaleActivationSuccessCannotOverrideNewerFailedActivation() async throws {
        let fixture = try await SelectionVideoFixture(test: self)
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer()
        weak var owned: PlaybackService?
        var stage = 0
        let service = fixture.own(PlaybackService(library: fixture.library, downloads: fixture.downloads,
            cloud: fixture.cloud, bookmarkURL: fixture.bookmark, activateSession: {
                if stage == 2 { throw SyntheticFailure.engineStart }
                try AVAudioSession.sharedInstance().setActive(true)
                if stage == 1 { stage = 2; owned?.play() }
            }, continuousAudio: audio))
        owned = service
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await until { service.audioSnapshot.frame > 4_800 }
        stage = 1; service.play()
        XCTAssertFalse(service.wantsToPlay, "The old success must not overwrite the newer session denial")
        XCTAssertEqual(service.queue.currentID, fixture.aID)
        service.pause()
    }

    func testRepeatedLoopsKeepRealSourceNodeOutputAudibleWithSpeakerProcessing() throws {
        let renderer = ContinuousPCMRenderer(sampleRate: 48_000, channels: 2, prefixFrames: 4_800, ringFrames: 512)
        var input = [Float](); input.reserveCapacity(9_600)
        for index in 0..<4_800 {
            let sample = Float(0.04 * sin(2 * Double.pi * 200 * Double(index) / 48_000))
            input.append(sample); input.append(-sample)
        }
        XCTAssertTrue(input.withUnsafeBufferPointer { renderer.source(at: 0).prepare(token: 1, totalFrames: 4_800, prefix: $0) })
        renderer.setSuccessor(token: 1, for: 1)
        renderer.select(token: 1, frame: 0); renderer.setSpeakerEnabled(true); renderer.setPlaying(true)
        let graph = ContinuousAudioGraph(renderer: renderer)
        try graph.engine.enableManualRenderingMode(.offline, format: graph.format, maximumFrameCount: 4_800)
        try graph.engine.start()
        defer { graph.engine.stop() }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: 4_800))
        var lowestRMS = Double.greatestFiniteMagnitude
        for _ in 0..<1_000 {
            XCTAssertEqual(try graph.engine.renderOffline(4_800, to: output), .success)
            let channels = try XCTUnwrap(output.floatChannelData)
            var power = 0.0, allFinite = true
            for frame in 0..<4_800 {
                let sample = Double(channels[0][frame])
                allFinite = allFinite && sample.isFinite
                power += sample * sample
            }
            lowestRMS = min(lowestRMS, sqrt(power / 4_800))
            XCTAssertTrue(allFinite)
        }
        XCTAssertGreaterThan(lowestRMS, 0.02, "A repeated audible source must not decay into silence")
        XCTAssertEqual(renderer.snapshot.token, 1)
        XCTAssertGreaterThanOrEqual(renderer.snapshot.visit, 1_000)
        XCTAssertEqual(renderer.snapshot.underrunFrames, 0)
        print("AUDIO_LOOP_SOAK loops=1000 mediaSeconds=100 minimumRMS=\(lowestRMS) underruns=\(renderer.snapshot.underrunFrames)")
    }

    private func assertSameSelection(_ service: PlaybackService, _ before: ContinuousPCMRenderer.Snapshot, id: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(service.queue.currentID, id, file: file, line: line)
        XCTAssertEqual(service.audioSnapshot.token, before.token, file: file, line: line)
        XCTAssertEqual(service.audioSnapshot.visit, before.visit, file: file, line: line)
        XCTAssertEqual(service.audioSnapshot.selectionVersion, before.selectionVersion, file: file, line: line)
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Expected actual output/session recovery without a user playback command", file: file, line: line)
    }
}
