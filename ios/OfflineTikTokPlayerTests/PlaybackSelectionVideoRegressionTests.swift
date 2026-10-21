import XCTest
import SwiftUI
import UIKit
import AVFoundation
import AudioToolbox
import CoreMedia
import PlayerCore
@testable import OfflineTikTokPlayer

/// Service/render integration regressions. The opaque magenta poster deliberately differs from
/// both generated movies, so a decoded asset or advancing audio clock cannot satisfy visibility.
@MainActor
final class PlaybackSelectionVideoRegressionTests: XCTestCase {
    func testCommandToEngineToneAndSelectedCustomFrameLatency() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer()
        let tap = SelectionOutputTap()
        let seeks = SelectionLatencySeekProbe()
        let service = fixture.service(continuousAudio: audio, seekVideo: seeks.seek)
        seeks.service = service
        let screen = try SelectionVideoScreen(service: service)
        audio.graph.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil) { buffer, time in
            tap.append(buffer, time: time)
        }
        defer {
            tap.stop(); service.pause()
            audio.graph.engine.mainMixerNode.removeTap(onBus: 0)
            audio.graph.engine.stop(); screen.close()
            seeks.dump()
        }
        service.isInteractingWithFeed = true
        print("SelectionLatency scope=engineMixerTap-not-physical-speaker outputLimitMs=100 customReadyLimitMs=250 silenceWindowMs=10 importHashVerification=already-verified")
        let aReference = try await fixture.decodedTone(id: fixture.aID, startSeconds: 0)
        let bReference = try await fixture.decodedTone(id: fixture.bID, startSeconds: 0)
        let sourceQuiet = max(SelectionOutputTap.quietRun(aReference, rate: 48_000),
                              SelectionOutputTap.quietRun(bReference, rate: 48_000))
        XCTAssertEqual(sourceQuiet, 0, "Continuous-tone fixtures must provide no quiet-window allowance that could mask inserted silence")

        await measureSelectionLatency(service, fixture: fixture, tap: tap, seeks: seeks, phase: 0,
                                      id: fixture.aID, frequency: 440, prepared: false, sourceQuiet: sourceQuiet) {
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        }
        assertSelection(service, fixture: fixture, id: fixture.aID)
        await assertVisibleFrame(service, screen: screen, identity: .a, label: "latency-cold-A")
        try await require({ service.preparedAudioCount == 2 }, "B must be prepared before timing Next")

        await measureSelectionLatency(service, fixture: fixture, tap: tap, seeks: seeks, phase: 1,
                                      id: fixture.bID, frequency: 880, prepared: true, sourceQuiet: sourceQuiet) { service.next() }
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertVisibleFrame(service, screen: screen, identity: .b, label: "latency-prepared-B")

        await measureSelectionLatency(service, fixture: fixture, tap: tap, seeks: seeks, phase: 2,
                                      id: fixture.aID, frequency: 440, prepared: true, sourceQuiet: sourceQuiet) { service.previous() }
        assertSelection(service, fixture: fixture, id: fixture.aID)
        await assertVisibleFrame(service, screen: screen, identity: .a, label: "latency-returned-A")
        let validity = tap.validity()
        XCTAssertEqual(validity.invalidTimestamps, 0, "Engine-output timing requires valid host timestamps; no callback-wall-time fallback")
        XCTAssertEqual(validity.droppedFrames, 0, "The bounded tap must retain all measured PCM")
    }

    private func measureSelectionLatency(_ service: PlaybackService, fixture: SelectionVideoFixture,
                                         tap: SelectionOutputTap, seeks: SelectionLatencySeekProbe, phase: Int,
                                         id: String, frequency: Double, prepared: Bool, sourceQuiet: Double,
                                         command: () -> Void) async {
        let firstFrame = tap.begin()
        // Collect only a short outgoing reference around prepared boundaries.
        // Timing starts below, immediately before the command, never after audio progress.
        if prepared { try? await Task.sleep(for: .milliseconds(120)) }
        let submitted = service.submittedVideoFrameCount
        let underruns = service.audioSnapshot.underrunFrames
        let origin = SelectionOutputTap.hostSeconds()
        seeks.phase = phase; seeks.origin = origin
        command()
        var cursor = firstFrame
        var outgoing: SelectionOutputTap.Window?
        var tone: SelectionOutputTap.Window?
        var visible: Double?
        let deadline = ProcessInfo.processInfo.systemUptime + (prepared ? 1 : 5)
        while ProcessInfo.processInfo.systemUptime < deadline {
            while tone == nil, let window = tap.window(at: cursor) {
                cursor += max(1, Int(window.rate * 0.01))
                if prepared, outgoing == nil,
                   SelectionOutputTap.isTone(window.samples, rate: window.rate, frequency: frequency == 440 ? 880 : 440) {
                    outgoing = window
                }
                if window.end >= origin, SelectionOutputTap.isTone(window.samples, rate: window.rate, frequency: frequency) {
                    tone = window
                }
            }
            let asset = service.player.currentItem?.asset as? AVURLAsset
            if asset?.url.standardizedFileURL == fixture.savedURLs[id]?.standardizedFileURL {
                seeks.sampleVideo()
            }
            if visible == nil, service.queue.currentID == id,
               asset?.url.standardizedFileURL == fixture.savedURLs[id]?.standardizedFileURL,
               service.submittedVideoFrameCount > submitted, service.customVideoReadyForDisplay,
               let frame = service.videoFramePositionSeconds,
               abs(frame - service.videoRequestedPositionSeconds) <= 0.080,
               service.isVideoReady, !service.isLoading {
                visible = SelectionOutputTap.hostSeconds()
            }
            if tone != nil && visible != nil { break }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        if prepared { try? await Task.sleep(for: .milliseconds(100)) }
        tap.stop()
        let recorded = tap.samples(since: firstFrame)
        let quiet = SelectionOutputTap.quietRun(recorded.values, rate: recorded.rate)
        let addedQuiet = max(0, quiet - sourceQuiet)
        let timelineHole = SelectionOutputTap.maximumTimelineHole(recorded.hosts, rate: recorded.rate)
        let toneMs = tone.map { ($0.end - origin) * 1_000 }
        let visibleMs = visible.map { ($0 - origin) * 1_000 }
        let underrunDelta = service.audioSnapshot.underrunFrames - underruns
        print("SelectionLatency phase=\(phase) prepared=\(prepared) frequency=\(frequency) outputWindowStartMs=\(tone.map { String(($0.start - origin) * 1_000) } ?? "missing") outputWindowEndMs=\(toneMs.map { String($0) } ?? "missing") customReadyMs=\(visibleMs.map { String($0) } ?? "missing") maxQuietMs=\(quiet * 1_000) sourceQuietMs=\(sourceQuiet * 1_000) addedQuietMs=\(addedQuiet * 1_000) timelineHoleMs=\(timelineHole * 1_000) underrunDelta=\(underrunDelta) tapRate=\(recorded.rate) tapFrames=\(recorded.values.count)")
        XCTAssertNotNil(tone, "The independently classified target tone must reach the real engine mixer tap")
        XCTAssertNotNil(visible, "A fresh selected custom frame must become ready within the phase watchdog")
        if prepared {
            XCTAssertEqual(seeks.alignedPreparedSeekCount[phase] ?? 0, 0,
                           "An already aligned prepared selection must not discard its frame through an exact seek")
            XCTAssertNotNil(outgoing, "Prepared measurement must capture the outgoing tone before the incoming source")
            if let outgoing, let tone { XCTAssertLessThanOrEqual(outgoing.end, tone.start) }
            if let toneMs { XCTAssertLessThanOrEqual(toneMs, 100, "Prepared engine output must begin within 100 ms of the command") }
            if let visibleMs { XCTAssertLessThanOrEqual(visibleMs, 250, "Prepared selected custom video must become ready within 250 ms") }
            XCTAssertEqual(underrunDelta, 0, "Prepared output must introduce no renderer underruns")
            XCTAssertLessThanOrEqual(addedQuiet, 0.000_001, "Prepared boundaries must add no 10 ms RMS-silence windows beyond the decoded source")
            XCTAssertGreaterThan(recorded.rate, 0)
            XCTAssertLessThanOrEqual(timelineHole, 0.5 / max(1, recorded.rate),
                                     "Prepared output timestamps must remain continuous to half a frame; missing callbacks cannot disappear from silence accounting")
        }
    }

    func testNaturalPreparedBoundaryKeepsOutputTimelineAndRevealsSelectedVideo() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer()
        let tap = SelectionOutputTap()
        let seeks = SelectionLatencySeekProbe()
        let service = fixture.service(continuousAudio: audio, seekVideo: seeks.seek)
        seeks.service = service
        let screen = try SelectionVideoScreen(service: service)
        audio.graph.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil) { buffer, time in
            tap.append(buffer, time: time)
        }
        defer {
            tap.stop(); service.pause()
            audio.graph.engine.mainMixerNode.removeTap(onBus: 0)
            audio.graph.engine.stop(); screen.close()
            seeks.dump()
        }
        for id in fixture.ids {
            let source = try await fixture.decodedTone(id: id, startSeconds: 0)
            XCTAssertEqual(SelectionOutputTap.quietRun(source, rate: 48_000), 0)
        }
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await require({ service.audioSnapshot.token > 0 && service.preparedAudioCount == 2 },
                          "Both complete synthetic sources must prepare before the natural boundary")
        let aToken = service.audioSnapshot.token
        // Play the complete presentation. A far seek could introduce unrelated
        // reader reconstruction and cannot stand in for a prepared natural end.
        let runway = await waitUntil(timeout: SelectionVideoFixture.duration + 2) {
            service.audioSnapshot.token == aToken
                && Double(service.audioSnapshot.frame) / 48_000 >= SelectionVideoFixture.duration - 0.5
        }
        XCTAssertTrue(runway, "The complete A presentation must reach its final half second")
        guard runway else { return }
        let first = tap.begin(), submitted = service.submittedVideoFrameCount
        seeks.phase = 3; seeks.origin = SelectionOutputTap.hostSeconds()
        let underruns = service.audioSnapshot.underrunFrames
        var cursor = first
        var outgoing: SelectionOutputTap.Window?
        var incoming: SelectionOutputTap.Window?
        var ready: Double?
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            while incoming == nil, let window = tap.window(at: cursor) {
                cursor += max(1, Int(window.rate * 0.01))
                if outgoing == nil, SelectionOutputTap.isTone(window.samples, rate: window.rate, frequency: 440) { outgoing = window }
                if SelectionOutputTap.isTone(window.samples, rate: window.rate, frequency: 880) { incoming = window }
            }
            if service.queue.currentID == fixture.bID { seeks.sampleVideo() }
            if ready == nil, service.queue.currentID == fixture.bID, service.isVideoReady,
               service.customVideoReadyForDisplay, service.submittedVideoFrameCount > submitted,
               let position = service.videoFramePositionSeconds, position < 2,
               abs(position - service.videoRequestedPositionSeconds) <= 0.080 { ready = SelectionOutputTap.hostSeconds() }
            if incoming != nil, ready != nil, service.audioSnapshot.token != aToken,
               service.audioSnapshot.frame >= 24_000 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        tap.stop()
        let captured = tap.samples(since: first)
        let quiet = SelectionOutputTap.quietRun(captured.values, rate: captured.rate)
        let hole = SelectionOutputTap.maximumTimelineHole(captured.hosts, rate: captured.rate)
        let visibleMs = incoming.flatMap { tone in ready.map { ($0 - tone.start) * 1_000 } }
        print("SelectionNaturalOutput completeSourceSeconds=\(SelectionVideoFixture.duration) outgoingTone=\(outgoing != nil) incomingTone=\(incoming != nil) customReadyFromIncomingWindowMs=\(visibleMs.map { String($0) } ?? "missing") maxQuietMs=\(quiet * 1_000) timelineHoleMs=\(hole * 1_000) underrunDelta=\(service.audioSnapshot.underrunFrames - underruns) nativeSeekCalls=\(seeks.nativeSeekCount[3] ?? 0) tapFrames=\(captured.values.count)")
        XCTAssertNotNil(outgoing, "The captured output must include A before B, rather than starting after the boundary")
        XCTAssertNotNil(incoming, "B's independent tone must reach the real mixer after complete A")
        if let outgoing, let incoming { XCTAssertLessThanOrEqual(outgoing.end, incoming.start) }
        XCTAssertNotNil(ready)
        if let visibleMs { XCTAssertLessThanOrEqual(visibleMs, 250) }
        XCTAssertEqual(quiet, 0, "Continuous source tones must add no detected 10 ms RMS-silence window")
        XCTAssertLessThanOrEqual(hole, 0.5 / max(1, captured.rate))
        XCTAssertEqual(service.audioSnapshot.underrunFrames, underruns)
        XCTAssertEqual(tap.validity().invalidTimestamps, 0)
        XCTAssertEqual(tap.validity().droppedFrames, 0)
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertVisibleFrame(service, screen: screen, identity: .b, label: "latency-natural-complete-A-to-B")
    }

    func testGeneratedSavedFixturesDecodeToExpectedDistinctTones() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        for (id, expected, other) in [(fixture.aID, 440.0, 880.0), (fixture.bID, 880.0, 440.0)] {
            let samples = try await fixture.decodedTone(id: id)
            XCTAssertGreaterThanOrEqual(samples.count, 10_000)
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
            XCTAssertGreaterThan(rms, 0.05, "The saved AAC fixture must decode to non-silent PCM")
            func power(_ frequency: Double) -> Double {
                var real = 0.0, imaginary = 0.0
                for (frame, sample) in samples.enumerated() {
                    let phase = 2 * Double.pi * frequency * Double(frame) / 48_000
                    real += Double(sample) * cos(phase)
                    imaginary += Double(sample) * sin(phase)
                }
                return (real * real + imaginary * imaginary) / pow(Double(max(1, samples.count)), 2)
            }
            let expectedPower = power(expected), otherPower = power(other)
            print("SelectionTone source=\(id == fixture.aID ? "A" : "B") frames=\(samples.count) rms=\(rms) expectedHz=\(expected) expectedPower=\(expectedPower) otherPower=\(otherPower)")
            XCTAssertGreaterThan(expectedPower, 0.0025, "The expected tone needs substantial decoded energy")
            XCTAssertGreaterThan(expectedPower, 100 * max(otherPower, 1e-12),
                                 "Independently decoded Saved A/B must contain their distinct expected tones")
        }
    }

    func testRestoredOffsetRevealsTheSelectedPausedFrame() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        try JSONEncoder().encode(PlaybackBookmark(
            queue: PlaybackQueue(ids: fixture.ids, startAt: fixture.bID), position: 0.4))
            .write(to: fixture.bookmark)
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }

        service.restore()
        try await require({ !service.isLoading && abs(service.player.currentTime().seconds - 0.4) < 0.04 },
                          "The real Saved B item must finish restoring to 0.4 seconds")
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertPausedCustomFrame(service, screen: screen, requested: 0.4, after: 0, label: "restore-0.4-settled")
        if let restored = await assertVisibleFrame(service, screen: screen, identity: .b, label: "restored-B-at-0.4") {
            let center = try XCTUnwrap(restored.blueBarCenter, "The paused restored frame must contain B's blue marker")
            let normalized = center / Double(restored.width)
            print("SelectionRestored position=0.4 blueNormalized=\(normalized) expected=\(38.0 / 160.0)")
            XCTAssertEqual(normalized, 38.0 / 160.0, accuracy: 0.04,
                           "The visible paused B frame must correspond to the restored 0.4-second offset")
        }
        assertPausedCustomFrameState(service, screen: screen, requested: 0.4, after: 0, label: "restore-0.4-captured")
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.player.rate, 0)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertEqual(service.audioSnapshot.selectionVersion, 0,
                       "A paused restore must not start audio to acknowledge its requested position")

        // A short backwards seek must reset the custom display's frame epoch,
        // even though its distance is below the ordinary 80 ms drift threshold.
        let beforeBackward = service.submittedVideoFrameCount
        logCustomFrame(service, screen: screen, label: "backward-0.35-before")
        service.seek(0.35)
        try await require({ abs(service.player.currentTime().seconds - 0.35) < 0.04 },
                          "The selected paused item must complete the backwards seek")
        await assertPausedCustomFrame(service, screen: screen, requested: 0.35, after: beforeBackward,
                                      label: "backward-0.35-settled")
        if let earlier = await assertVisibleFrame(service, screen: screen, identity: .b, label: "paused-B-backwards-to-0.35") {
            let center = try XCTUnwrap(earlier.blueBarCenter)
            let normalized = center / Double(earlier.width)
            print("SelectionPausedBackward position=0.35 blueNormalized=\(normalized) expected=\(28.0 / 160.0)")
            XCTAssertEqual(normalized, 28.0 / 160.0, accuracy: 0.04,
                           "The actual paused composite must replace the later frame after a short backwards seek")
        }
        assertPausedCustomFrameState(service, screen: screen, requested: 0.35, after: beforeBackward,
                                     label: "backward-0.35-captured")
        assertSelection(service, fixture: fixture, id: fixture.bID)
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertEqual(service.audioSnapshot.selectionVersion, 0)
        XCTAssertEqual(service.player.rate, 0)

        // Both requests share one actor turn, so the first native completion must
        // converge on the latest target even though they differ by only 50 ms.
        let beforeCoalesced = service.submittedVideoFrameCount
        logCustomFrame(service, screen: screen, label: "coalesced-0.65-to-0.60-before")
        service.seek(0.65)
        service.seek(0.60)
        try await require({ abs(service.player.currentTime().seconds - 0.60) < 0.04 },
                          "The latest paused seek must supersede the in-flight target")
        await assertPausedCustomFrame(service, screen: screen, requested: 0.60, after: beforeCoalesced,
                                      label: "coalesced-0.60-settled")
        if let newest = await assertVisibleFrame(service, screen: screen, identity: .b, label: "paused-B-latest-0.60") {
            let center = try XCTUnwrap(newest.blueBarCenter)
            let normalized = center / Double(newest.width)
            print("SelectionPausedLatest position=0.60 blueNormalized=\(normalized) expected=\(48.0 / 160.0)")
            XCTAssertEqual(normalized, 48.0 / 160.0, accuracy: 0.04,
                           "The actual paused composite must show the latest coalesced seek target")
        }
        assertPausedCustomFrameState(service, screen: screen, requested: 0.60, after: beforeCoalesced,
                                     label: "coalesced-0.60-captured")
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertEqual(service.audioSnapshot.selectionVersion, 0)
        XCTAssertEqual(service.player.rate, 0)

        service.play()
        try await require({ service.audioSnapshot.token != 0 && service.audioSnapshot.frame > 2_400 },
                          "Restored B must enter the actual audio renderer after explicit Play")
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "restored-B-playing")
    }

    func testPausedRestoreBlocksFrameAcquisitionUntilTheRealSeekCompletionIsReleased() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        try JSONEncoder().encode(PlaybackBookmark(
            queue: PlaybackQueue(ids: fixture.ids, startAt: fixture.bID), position: 0.4))
            .write(to: fixture.bookmark)
        let scheduler = SelectionVideoSeekScheduler()
        let service = fixture.service(seekVideo: scheduler.seek)
        let screen = try SelectionVideoScreen(service: service)
        defer { scheduler.release(); service.pause(); screen.close() }
        var submittedAtStart: UInt64?
        var blockedAtStart: UInt64?
        scheduler.onSeekStarted = { [weak service] in
            submittedAtStart = service?.submittedVideoFrameCount
            blockedAtStart = service?.videoFrameAcquisitionBlockedCount
        }

        service.restore()
        try await require({ scheduler.isHoldingCompletion && scheduler.nativeFinished == true
            && abs(service.player.currentTime().seconds - 0.4) < 0.04 },
                          "The real AVPlayer seek must finish while its service callback remains held")
        let submitted = try XCTUnwrap(submittedAtStart)
        let blocked = try XCTUnwrap(blockedAtStart)
        try await require({ service.videoFrameAcquisitionBlockedCount >= blocked + 2 },
                          "At least two real frame-poll attempts must encounter the held seek gate")
        logCustomFrame(service, screen: screen, label: "held-real-seek-0.4")
        print("SelectionHeldSeek blockedDelta=\(service.videoFrameAcquisitionBlockedCount - blocked) submittedAtStart=\(submitted) submittedNow=\(service.submittedVideoFrameCount)")
        XCTAssertEqual(service.submittedVideoFrameCount, submitted,
                       "No custom frame may be acquired while the real seek callback is withheld")
        XCTAssertNil(service.videoFramePositionSeconds, "The seek's emptied epoch must contain no submitted frame")
        XCTAssertNil(service.copiedVideoFramePositionSeconds, "The held seek must prevent even copying a frame from the old epoch")
        assertSelection(service, fixture: fixture, id: fixture.bID)
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertEqual(service.player.rate, 0)

        scheduler.release()
        await assertPausedCustomFrame(service, screen: screen, requested: 0.4, after: submitted,
                                      label: "released-real-seek-0.4-settled")
        if let pixels = await assertVisibleFrame(service, screen: screen, identity: .b,
                                                 label: "released-real-seek-0.4") {
            let center = try XCTUnwrap(pixels.blueBarCenter)
            let normalized = center / Double(pixels.width)
            print("SelectionHeldSeekReleased position=0.4 blueNormalized=\(normalized) expected=\(38.0 / 160.0)")
            XCTAssertEqual(normalized, 38.0 / 160.0, accuracy: 0.04)
        }
        assertPausedCustomFrameState(service, screen: screen, requested: 0.4, after: submitted,
                                     label: "released-real-seek-0.4-captured")
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertFalse(service.audioEngineRunning)
        XCTAssertEqual(service.audioSnapshot.selectionVersion, 0)
        XCTAssertEqual(service.player.rate, 0)
    }

    func testPreparedRewoundBUncoversItsOwnMovingVideo() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let buffer = PlaybackBuffer()
        let service = fixture.service(buffer: buffer)
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.bID)
        try await require({ service.audioSnapshot.frame > 2_400 && service.preparedAudioCount == 2 },
                          "Both generated Saved sources must be prepared")
        let bToken = service.audioSnapshot.token
        let preparedB = try XCTUnwrap(service.player.currentItem)

        service.previous()
        try await require({ service.queue.currentID == fixture.aID && service.audioSnapshot.token != bToken
            && service.audioSnapshot.frame > 2_400 }, "A must be the real rendered source before selecting B again")
        let seeked = await withCheckedContinuation { continuation in
            preparedB.seek(to: CMTime(seconds: 0.75, preferredTimescale: 48_000),
                           toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(seeked)
        // Force the real prepared-item branch with an unfinished rewind, rather than depending
        // on whether background previous-item seeking happened to win a simulator race.
        buffer.discardNext()
        buffer.discardPrevious()
        buffer.stagePrevious(.init(mediaID: fixture.bID, item: preparedB, isLocal: true, needsRewind: true))
        service.next()
        try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token == bToken
            && service.audioSnapshot.frame > 2_400 }, "Prepared B must replace A in the audio renderer")
        XCTAssertTrue(service.player.currentItem === preparedB, "The test must exercise the rewound prepared object")
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "rewound-prepared-B")
    }

    func testPreparedABAChangesActualAssetAudioTokenAndCompositePixels() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer()
        let service = fixture.service(continuousAudio: audio)
        let context = SelectionProducerContext(renderer: audio.renderer, producer: audio.producerProgressRecorder)
        let screen = try SelectionVideoScreen(service: service, producerContext: context)
        defer { service.pause(); audio.graph.engine.stop(); screen.close() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await require({ service.audioSnapshot.frame > 2_400 && service.preparedAudioCount == 2 },
                          "A and B must both be prepared before the reversal")
        let aToken = service.audioSnapshot.token
        XCTAssertNotEqual(aToken, 0)
        assertSelection(service, fixture: fixture, id: fixture.aID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "initial-A")

        service.next()
        try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token != aToken
            && service.audioSnapshot.token != 0 && service.audioSnapshot.frame > 2_400 },
                          "Selecting B must change the actual render token")
        let bToken = service.audioSnapshot.token
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "selected-B")

        service.previous()
        try await require({ service.queue.currentID == fixture.aID && service.audioSnapshot.token == aToken
            && service.audioSnapshot.frame > 2_400 }, "Previous must return to the prepared A source")
        XCTAssertNotEqual(service.audioSnapshot.token, bToken)
        assertSelection(service, fixture: fixture, id: fixture.aID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "returned-A")
    }

    func testMatchedReturnedAProducerWindowsWithAndWithoutCompositeCapture() async throws {
        for captures in [false, true] {
            do { try await measureReturnedAProducer(captures: captures) }
            catch { XCTFail("Matched producer setup failed: \(error)") }
        }
    }

    private func measureReturnedAProducer(captures: Bool) async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer()
        let service = fixture.service(continuousAudio: audio)
        let screen = try SelectionVideoScreen(service: service)
        var result: SelectionProducerProbe.Result?
        var progressSummary: String?
        let label = captures ? "matched-capture" : "matched-control"
        defer {
            service.pause(); audio.graph.engine.stop(); screen.close()
            result?.dump(label: label)
            if let progressSummary { print(progressSummary) }
        }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await require({ service.preparedAudioCount == 2 && service.audioSnapshot.frame >= 24_000
            && service.isVideoReady && service.customVideoReadyForDisplay }, "Matched A must be prepared and visibly ready")
        let token = service.audioSnapshot.token
        try await matchedHistoryCapture(screen, identity: .a, label: label + "-pre-A")
        service.next()
        try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token != token
            && service.audioSnapshot.frame >= 24_000 && service.isVideoReady && service.customVideoReadyForDisplay },
                          "Matched B must play before the identical return")
        try await matchedHistoryCapture(screen, identity: .b, label: label + "-pre-B")
        service.previous()
        try await require({ service.queue.currentID == fixture.aID && service.audioSnapshot.token == token
            && service.audioSnapshot.frame >= 12_000 && service.isVideoReady && service.customVideoReadyForDisplay },
                          "Matched returned A must play before either observation condition")
        assertSelection(service, fixture: fixture, id: fixture.aID)
        let baseline = service.audioSnapshot
        XCTAssertEqual(baseline.underrunFrames, 0, "The common A/B capture history must not already have starved")
        XCTAssertTrue(service.wantsToPlay && service.audioEngineRunning)
        let probe = SelectionProducerProbe(context: SelectionProducerContext(renderer: audio.renderer,
            producer: audio.producerProgressRecorder))
        let start = ProcessInfo.processInfo.systemUptime
        if captures {
            do {
                let pixels = try await screen.capture(label: label, test: self)
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 29,
                                  "The existing complete-source capture window cannot be extended")
                XCTAssertGreaterThan(pixels.fraction(.a), 0.65)
                XCTAssertLessThan(pixels.magentaFraction, 0.02)
            } catch { XCTFail("Matched compositor capture failed: \(error)") }
        }
        // Both samplers observe the same first eight seconds. A failed capture,
        // new underrun or the existing 29-second source bound still fails.
        let remaining = max(0, 8 - (ProcessInfo.processInfo.systemUptime - start))
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        let observed = probe.stop()
        result = observed
        XCTAssertGreaterThanOrEqual(observed.samples.count, 40, "The independent sampler must provide useful coverage")
        XCTAssertLessThanOrEqual(observed.samples.first.map { Double($0.uptime - observed.origin) / 1_000_000_000 } ?? .infinity, 0.25)
        XCTAssertGreaterThanOrEqual(observed.samples.last.map { Double($0.uptime - observed.origin) / 1_000_000_000 } ?? -1, 7.5,
                                    "The sampler must cover the shared observation window, not just its beginning")
        XCTAssertGreaterThanOrEqual(observed.samples.filter { $0.producer.coherent }.count, 20)
        XCTAssertLessThanOrEqual(Double(observed.maximumGap) / 1_000_000_000, 0.25,
                                 "Gaps in the independent sampler cannot be treated as covered")
        XCTAssertEqual(observed.dropped, 0)
        XCTAssertEqual(service.audioSnapshot.underrunFrames, baseline.underrunFrames,
                       "Neither matched condition may conceal producer starvation")
        XCTAssertEqual(observed.samples.map { $0.audio.underrunFrames }.max() ?? -1, baseline.underrunFrames)
        XCTAssertTrue(observed.samples.allSatisfy { $0.audio.token == baseline.token && $0.audio.visit == baseline.visit && !$0.audio.ended },
                      "Both matched windows must observe the same active returned-A visit")
        XCTAssertTrue(service.wantsToPlay && service.audioEngineRunning)
        if let first = observed.samples.first, let last = observed.samples.last {
            let wall = Double(last.uptime - first.uptime) / 1_000_000_000
            let pcm = Double(last.audio.frame - first.audio.frame) / 48_000
            let quantum = max(1, service.audioRenderQuantumFrames)
            let tolerance = 2 * Double(quantum) / 48_000 + 0.005
            let worstSkew = zip(observed.samples, observed.samples.dropFirst()).map { before, after in
                abs(Double(after.audio.frame - before.audio.frame) / 48_000
                    - Double(after.uptime - before.uptime) / 1_000_000_000)
            }.max() ?? .infinity
            XCTAssertGreaterThan(pcm, 0, "Stopped rendering with zero underruns is not continuity")
            XCTAssertEqual(pcm, wall, accuracy: tolerance)
            XCTAssertLessThanOrEqual(worstSkew, tolerance, "A paused/stalled render clock cannot hide between samples")
            progressSummary = "SelectionProducerProgress label=\(label) wallSeconds=\(wall) pcmSeconds=\(pcm) quantumFrames=\(quantum) maximumProgressSkewMs=\(worstSkew * 1_000)"
        }
    }

    private func matchedHistoryCapture(_ screen: SelectionVideoScreen, identity: SelectionVideoIdentity,
                                       label: String) async throws {
        for observation in 0..<2 {
            let pixels = try await screen.capture(label: label + "-\(observation)", test: self)
            XCTAssertGreaterThan(pixels.fraction(identity), 0.65)
            XCTAssertLessThan(pixels.magentaFraction, 0.02)
            try await Task.sleep(for: .milliseconds(180))
        }
    }

    func testNaturalBoundaryAtPositiveIncomingOffsetRevealsB() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer()
        let service = fixture.service(continuousAudio: audio)
        let context = SelectionProducerContext(renderer: audio.renderer, producer: audio.producerProgressRecorder,
            nativeSamplePurpose: 1)
        let screen = try SelectionVideoScreen(service: service, producerContext: context,
            producerWindowSeconds: 45, producerSampleCapacity: 512)
        defer { service.pause(); audio.graph.engine.stop(); screen.close() }
        try await preparePositiveOffsetNaturalB(service, fixture: fixture)
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "natural-B-positive-offset")
    }

    func testMatchedNaturalBoundaryProducerTraceAndCaptureControls() async throws {
        // Fresh identical histories isolate capture and native-trace overhead.
        // Every arm keeps the same independent snapshot sampler and bounds.
        for condition in [(trace: false, capture: false), (trace: true, capture: false),
                          (trace: false, capture: true), (trace: true, capture: true)] {
            do { try await measureNaturalProducer(trace: condition.trace, capture: condition.capture) }
            catch { XCTFail("Matched natural setup failed: \(error)") }
        }
    }

    private func measureNaturalProducer(trace: Bool, capture: Bool) async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let audio = ContinuousAudioPlayer()
        audio.producerProgressRecorder.setTracingEnabled(trace)
        let service = fixture.service(continuousAudio: audio)
        let screen = try SelectionVideoScreen(service: service)
        let label = "matched-natural-trace-\(trace)-capture-\(capture)"
        let setupStart = ProcessInfo.processInfo.systemUptime
        var result: SelectionProducerProbe.Result?
        var summaries: [String] = []
        defer {
            service.pause(); audio.graph.engine.stop(); screen.close()
            result?.dump(label: label)
            for summary in summaries { print(summary) }
        }
        try await preparePositiveOffsetNaturalB(service, fixture: fixture)
        let ready = await waitUntil {
            service.isVideoReady && (service.surface.playerLayer.isReadyForDisplay
                || screen.customVideoLayer?.isReadyForDisplay == true)
        }
        XCTAssertTrue(ready, "The same natural B visibility gate must precede either condition")
        let baseline = service.audioSnapshot
        let setupMs = (ProcessInfo.processInfo.systemUptime - setupStart) * 1_000
        XCTAssertTrue(service.wantsToPlay && service.audioEngineRunning)
        XCTAssertEqual(audio.producerProgressRecorder.snapshot().tracingEnabled, trace)
        let probe = SelectionProducerProbe(context: SelectionProducerContext(renderer: audio.renderer,
            producer: audio.producerProgressRecorder, nativeSamplePurpose: 1), durationSeconds: 45, capacity: 512)
        let start = ProcessInfo.processInfo.systemUptime
        if capture {
            // Preserve the original compositor identity, moving marker, source,
            // no-new-underrun and 29-second complete-source assertions.
            await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: label)
        }
        let captureSeconds = ProcessInfo.processInfo.systemUptime - start
        let remaining = max(0, 24 - captureSeconds)
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        let observed = probe.stop()
        result = observed
        // The unchanged first-eight-second contract is checked separately from
        // the longer matched window. A slow capture's later tail stays visible.
        summaries.append(assertNaturalProducerWindow(observed, baseline: baseline,
            quantum: service.audioRenderQuantumFrames, seconds: 8, label: label))
        summaries.append(assertNaturalProducerWindow(observed, baseline: baseline,
            quantum: service.audioRenderQuantumFrames, seconds: 24, label: label))
        XCTAssertEqual(observed.dropped, 0)
        XCTAssertEqual(service.audioSnapshot.underrunFrames, baseline.underrunFrames,
                       "Starvation after the matched prefix must not disappear from a long capture")
        XCTAssertTrue(service.wantsToPlay && service.audioEngineRunning)
        assertSelection(service, fixture: fixture, id: fixture.bID)
        summaries.append("SelectionNaturalCondition label=\(label) nativeTrace=\(trace) capture=\(capture) setupMs=\(setupMs) captureSeconds=\(captureSeconds) baselineFrame=\(baseline.frame) baselineUnderruns=\(baseline.underrunFrames) finalUnderruns=\(service.audioSnapshot.underrunFrames)")
    }

    private func assertNaturalProducerWindow(_ result: SelectionProducerProbe.Result,
        baseline: ContinuousPCMRenderer.Snapshot, quantum: Int, seconds: Double, label: String) -> String {
        let samples = result.samples.filter { Double($0.uptime - result.origin) / 1_000_000_000 <= seconds }
        XCTAssertGreaterThanOrEqual(samples.count, Int(seconds * 5), "The independent sampler must provide useful coverage")
        XCTAssertLessThanOrEqual(samples.first.map { Double($0.uptime - result.origin) / 1_000_000_000 } ?? .infinity, 0.25)
        XCTAssertGreaterThanOrEqual(samples.last.map { Double($0.uptime - result.origin) / 1_000_000_000 } ?? -1, seconds - 0.5)
        XCTAssertGreaterThanOrEqual(samples.filter { $0.producer.coherent }.count, Int(seconds * 2.5))
        let gaps = zip(samples, samples.dropFirst()).map { before, after in
            Double(after.uptime - before.uptime) / 1_000_000_000
        }
        XCTAssertLessThanOrEqual(gaps.max() ?? .infinity, 0.25, "Missing observations cannot establish continuity")
        let acquisition = samples.map { Double($0.audioAcquisitionEnd - $0.acquisitionBegin) / 1_000_000_000 }.max() ?? .infinity
        XCTAssertLessThanOrEqual(acquisition, 0.005, "A preempted snapshot read cannot masquerade as a precise sample time")
        XCTAssertEqual(samples.map { $0.audio.underrunFrames }.max() ?? -1, baseline.underrunFrames)
        XCTAssertTrue(samples.allSatisfy { $0.audio.token == baseline.token && $0.audio.visit == baseline.visit && !$0.audio.ended })
        let tolerance = 2 * Double(max(1, quantum)) / 48_000 + 0.005
        let wall = samples.first.flatMap { first in samples.last.map { Double($0.uptime - first.uptime) / 1_000_000_000 } } ?? -1
        let pcm = samples.first.flatMap { first in samples.last.map { Double($0.audio.frame - first.audio.frame) / 48_000 } } ?? -1
        let skew = zip(samples, samples.dropFirst()).map { before, after in
            abs(Double(after.audio.frame - before.audio.frame) / 48_000
                - Double(after.uptime - before.uptime) / 1_000_000_000)
        }.max() ?? .infinity
        XCTAssertGreaterThan(pcm, 0)
        XCTAssertEqual(pcm, wall, accuracy: tolerance)
        XCTAssertLessThanOrEqual(skew, tolerance, "A paused/stalled render clock cannot hide between samples")
        return "SelectionNaturalProducerProgress label=\(label) windowSeconds=\(seconds) samples=\(samples.count) wallSeconds=\(wall) pcmSeconds=\(pcm) maximumProgressSkewMs=\(skew * 1_000) maximumAcquisitionMs=\(acquisition * 1_000)"
    }

    private func preparePositiveOffsetNaturalB(_ service: PlaybackService, fixture: SelectionVideoFixture) async throws {
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await require({ service.audioSnapshot.frame > 2_400 && service.preparedAudioCount == 2 },
                          "Both complete Saved sources must be ready")
        let aToken = service.audioSnapshot.token
        let seekPosition = SelectionVideoFixture.duration - 2
        service.seek(seekPosition)
        // A far seek rebuilds the decoder's original history. Observe real progress with
        // two seconds of runway instead of requiring the main actor to catch A's final
        // 250 ms. A completed natural transition is also valid if scheduling skipped A.
        // This is cold far-seek setup, not a prepared-transition latency limit.
        let reachedRunway = await waitUntil(timeout: 10) {
            let sample = service.audioSnapshot
            return sample.token == aToken && sample.frame >= Int64((seekPosition + 0.05) * 48_000)
                || sample.token != 0 && sample.token != aToken && sample.frame > 0
        }
        let sample = service.audioSnapshot
        print("SelectionBoundary phase=runway reached=\(reachedRunway) sourceA=\(sample.token == aToken) frame=\(sample.frame) visit=\(sample.visit) underrunFrames=\(sample.underrunFrames) engineRunning=\(service.audioEngineRunning) wantsToPlay=\(service.wantsToPlay) position=\(service.clock.position) duration=\(service.clock.duration)")
        guard reachedRunway else {
            // Preserve the original assertion and numeric evidence, then abort
            // this failed setup instead of continuing with the wrong source.
            XCTFail("The real renderer must reach the seek runway or naturally enter B")
            // Sampling happens only after this existing setup guard has failed.
            // Abort this arm: A's failed seek cannot stand in for natural B.
            let identifier = UUID().uuidString.lowercased()
            let written = SelectionNativeWorkerSample.request(purpose: 0, identifier: identifier)
            print("SelectionNativeWorkerRequest purposeCode=0 requestID=\(identifier) written=\(written)")
            throw SelectionVideoTestFailure.timeout
        }
        // The audio thread continues through the boundary while the main actor is briefly busy.
        // This deterministically exercises an arriving frame offset greater than zero.
        if sample.token == aToken {
            let remaining = max(0, SelectionVideoFixture.duration - Double(sample.frame) / 48_000)
            stallMainActorForBoundary(seconds: min(2.2, remaining + 0.2))
        }
        try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token != 0
            && service.audioSnapshot.token != aToken
            && service.clock.position > 0 }, "The service must adopt naturally rendered B at a positive offset")
        assertSelection(service, fixture: fixture, id: fixture.bID)
    }

    func testRapidABASupersedesPendingVideoSeekAndPreservesExplicitPause() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await require({ service.audioSnapshot.frame > 2_400 && service.preparedAudioCount == 2 },
                          "Both Saved sources must be prepared before rapid supersession")
        await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "rapid-baseline-A")
        let aToken = service.audioSnapshot.token
        let priorSelectionVersion = service.audioSnapshot.selectionVersion
        // One main-actor turn: the paused seek has an outstanding native completion when
        // Next and Previous replace its generation. There is no wait for B readiness.
        service.pause()
        service.seek(0.8)
        service.next()
        service.previous()
        service.play()
        try await require({ service.queue.currentID == fixture.aID && service.audioSnapshot.token == aToken
            && service.audioSnapshot.selectionVersion >= priorSelectionVersion + 6
            && service.audioSnapshot.frame > 2_400 }, "The renderer must acknowledge the final A selection")
        print("SelectionRapid beforeVersion=\(priorSelectionVersion) finalVersion=\(service.audioSnapshot.selectionVersion) frame=\(service.audioSnapshot.frame)")
        assertSelection(service, fixture: fixture, id: fixture.aID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "rapid-final-A")
        service.seek(0.35)
        service.pause()
        try await require({ !service.audioEngineRunning }, "Explicit Pause must stop the newest selection")
        let paused = service.audioSnapshot
        try await Task.sleep(for: .milliseconds(250))
        assertSelection(service, fixture: fixture, id: fixture.aID)
        XCTAssertFalse(service.wantsToPlay, "Late video completions must not undo explicit Pause")
        XCTAssertEqual(service.audioSnapshot.token, paused.token)
        XCTAssertEqual(service.audioSnapshot.frame, paused.frame)
        XCTAssertEqual(service.player.rate, 0)
    }

    func testAudioOnlyAndForegroundRestoreSelectedBWithoutOverridingPause() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.bID)
        try await require({ service.audioSnapshot.frame > 2_400 }, "B must be rendered before hiding video")
        let bToken = service.audioSnapshot.token
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "B-before-audio-only")
        service.audioOnly = true
        XCTAssertTrue(service.surface.isHidden)
        let before = service.audioSnapshot.frame
        try await require({ service.audioSnapshot.frame > before + 2_400 }, "Audio only must leave B audio advancing")
        service.pause()
        try await require({ !service.audioEngineRunning }, "Explicit Pause must stop the actual audio engine")
        let pausedFrame = service.audioSnapshot.frame
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        service.enteredForeground()
        service.audioOnly = false
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertVisibleFrame(service, screen: screen, identity: .b, label: "paused-B-restored-inline")
        XCTAssertFalse(service.surface.isHidden)
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.audioSnapshot.token, bToken)
        XCTAssertEqual(service.audioSnapshot.frame, pausedFrame)
        XCTAssertEqual(service.player.rate, 0)
    }

    private func stallMainActorForBoundary(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    private func logCustomFrame(_ service: PlaybackService, screen: SelectionVideoScreen, label: String) {
        print("SelectionCustomFrame label=\(label) submitted=\(service.submittedVideoFrameCount) pts=\(service.videoFramePositionSeconds.map { String($0) } ?? "missing") copiedPTS=\(service.copiedVideoFramePositionSeconds.map { String($0) } ?? "missing") futureRejected=\(service.pausedFutureVideoFrameRejectionCount) requested=\(service.videoRequestedPositionSeconds) timebase=\(service.videoTimebasePositionSeconds.map { String($0) } ?? "missing") customReady=\(screen.customVideoLayer?.isReadyForDisplay == true) playerPosition=\(service.player.currentTime().seconds) clockPosition=\(service.clock.position)")
    }

    private func assertPausedCustomFrame(_ service: PlaybackService, screen: SelectionVideoScreen,
                                         requested: Double, after count: UInt64, label: String,
                                         file: StaticString = #filePath, line: UInt = #line) async {
        let epsilon = 0.000_001
        let settled = await waitUntil {
            guard let pts = service.videoFramePositionSeconds, pts.isFinite else { return false }
            return service.submittedVideoFrameCount > count && screen.customVideoLayer?.isReadyForDisplay == true
                && abs(service.videoRequestedPositionSeconds - requested) <= epsilon
                && pts <= requested + epsilon && requested - pts <= 1.0 / 24.0 + epsilon
        }
        XCTAssertTrue(settled, "The custom display must submit a fresh frame for the settled paused seek", file: file, line: line)
        assertPausedCustomFrameState(service, screen: screen, requested: requested, after: count,
                                     label: label, file: file, line: line)
    }

    private func assertPausedCustomFrameState(_ service: PlaybackService, screen: SelectionVideoScreen,
                                              requested: Double, after count: UInt64, label: String,
                                              file: StaticString = #filePath, line: UInt = #line) {
        logCustomFrame(service, screen: screen, label: label)
        XCTAssertGreaterThan(service.submittedVideoFrameCount, count,
                             "Underlying AVPlayerLayer pixels cannot replace custom-frame submission", file: file, line: line)
        XCTAssertTrue(screen.customVideoLayer?.isReadyForDisplay == true,
                      "The fresh custom frame must remain visible after compositor capture", file: file, line: line)
        let epsilon = 0.000_001
        XCTAssertEqual(service.videoRequestedPositionSeconds, requested, accuracy: epsilon, file: file, line: line)
        guard let pts = service.videoFramePositionSeconds, pts.isFinite else {
            XCTFail("The custom display must expose a finite submitted frame PTS", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(pts, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(pts, requested + epsilon,
                                 "A paused display must not show a future video frame", file: file, line: line)
        XCTAssertLessThanOrEqual(requested - pts, 1.0 / 24.0 + epsilon,
                                 "The 24 fps fixture must settle within one frame before the requested position", file: file, line: line)
    }

    private func assertSelection(_ service: PlaybackService, fixture: SelectionVideoFixture, id: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(service.queue.currentID, id, file: file, line: line)
        XCTAssertEqual(service.current?.id, id, file: file, line: line)
        let asset = service.player.currentItem?.asset as? AVURLAsset
        XCTAssertEqual(asset?.url.standardizedFileURL, fixture.savedURLs[id]?.standardizedFileURL,
                       "The selected metadata must identify the actual AVPlayerItem asset", file: file, line: line)
        XCTAssertTrue(service.surface.playerLayer.player === service.player, file: file, line: line)
    }

    @discardableResult
    private func assertVisibleFrame(_ service: PlaybackService, screen: SelectionVideoScreen,
                                    identity: SelectionVideoIdentity, label: String,
                                    file: StaticString = #filePath, line: UInt = #line) async -> SelectionVideoPixels? {
        let ready = await waitUntil {
            service.isVideoReady && (service.surface.playerLayer.isReadyForDisplay
                || screen.customVideoLayer?.isReadyForDisplay == true)
        }
        XCTAssertTrue(ready, "The selected real video must become ready; an audio clock is insufficient", file: file, line: line)
        do {
            let pixels = try await screen.capture(label: label, test: self)
            pixels.log(label: label, identity: identity)
            XCTAssertGreaterThan(pixels.fraction(identity), 0.65,
                                 "The whole composite must show \(identity), not the opaque poster or another source", file: file, line: line)
            XCTAssertLessThan(pixels.magentaFraction, 0.02,
                              "The real readiness path must uncover video instead of leaving the poster opaque", file: file, line: line)
            return pixels
        } catch {
            XCTFail("Composite capture failed: \(error)", file: file, line: line)
            return nil
        }
    }

    private func assertMovingVisibleVideo(_ service: PlaybackService, screen: SelectionVideoScreen,
                                          identity: SelectionVideoIdentity, label: String,
                                          file: StaticString = #filePath, line: UInt = #line) async {
        guard let first = await assertVisibleFrame(service, screen: screen, identity: identity,
                                                  label: label + "-motion-start", file: file, line: line) else { return }
        do {
            let firstBar = try XCTUnwrap(first.blueBarCenter, "The first composite must contain its decoded blue marker", file: file, line: line)
            let firstBarY = try XCTUnwrap(first.blueBarCenterY, "The first composite must locate the blue marker vertically", file: file, line: line)
            let firstSubmitted = service.submittedVideoFrameCount
            XCTAssertGreaterThan(firstSubmitted, 0, "The first image must have a submitted custom frame", file: file, line: line)
            let firstReady = service.isVideoReady && screen.customVideoLayer?.isReadyForDisplay == true
            XCTAssertTrue(firstReady, "The first composite must have a ready custom video frame", file: file, line: line)
            guard first.fraction(identity) > 0.65, first.magentaFraction < 0.02,
                  firstSubmitted > 0, firstReady else { return }
            var visibleDelta = 0.0
            var states = [first.captureBefore, first.captureAfter]
            guard assertMotionCaptureWindow(states, label: label, file: file, line: line) else { return }
            // The two-dimensional marker is unique throughout the 30-second fixture.
            // Every observation must fit a shorter real-time and media-time window.
            for observation in 2...3 {
                let previousTime = service.player.currentTime().seconds
                let previousAudio = service.audioSnapshot
                _ = await waitUntil(timeout: 1) {
                    let audio = service.audioSnapshot
                    return service.player.currentTime().seconds > previousTime + 0.18
                        && audio.token == previousAudio.token && audio.visit == previousAudio.visit
                        && audio.frame >= previousAudio.frame + 8_640
                }
                let currentAudio = service.audioSnapshot
                let sameWindowSource = previousAudio.token == first.captureBefore.audioToken
                    && previousAudio.visit == first.captureBefore.audioVisit
                let audioAdvanced = sameWindowSource && currentAudio.token == previousAudio.token && currentAudio.visit == previousAudio.visit
                    && currentAudio.frame >= previousAudio.frame + 8_640
                let noUnderrun = currentAudio.underrunFrames == previousAudio.underrunFrames
                    && previousAudio.underrunFrames == first.captureBefore.audioUnderrunFrames
                print("SelectionMotionInterval label=\(label) observation=\(observation) audioDelta=\(currentAudio.frame - previousAudio.frame) underrunDelta=\(currentAudio.underrunFrames - previousAudio.underrunFrames) sameToken=\(currentAudio.token == previousAudio.token) sameVisit=\(currentAudio.visit == previousAudio.visit)")
                guard audioAdvanced, noUnderrun else {
                    XCTFail("audioClockHold/underruns: PCM must advance at least 8640 frames in the same visit without new underruns", file: file, line: line)
                    return
                }
                let videoAdvanced = service.player.currentTime().seconds > previousTime + 0.18
                XCTAssertTrue(videoAdvanced, "The selected AVPlayerItem clock must actually advance for each observation", file: file, line: line)
                guard videoAdvanced else { return }
                let captureLabel = label + "-motion-observation-\(observation)"
                let next = try await screen.capture(label: captureLabel, test: self)
                next.log(label: captureLabel, identity: identity)
                states += [next.captureBefore, next.captureAfter]
                guard assertMotionCaptureWindow(states, label: label, file: file, line: line) else { return }
                XCTAssertGreaterThan(next.fraction(identity), 0.65, file: file, line: line)
                XCTAssertLessThan(next.magentaFraction, 0.02, file: file, line: line)
                let ready = service.isVideoReady && screen.customVideoLayer?.isReadyForDisplay == true
                XCTAssertTrue(ready, "The actual custom video must remain ready during motion proof", file: file, line: line)
                let nextBar = try XCTUnwrap(next.blueBarCenter, "Every composite must contain its decoded blue marker", file: file, line: line)
                let nextBarY = try XCTUnwrap(next.blueBarCenterY, "Every composite must locate the blue marker vertically", file: file, line: line)
                guard next.fraction(identity) > 0.65, next.magentaFraction < 0.02, ready else { return }
                visibleDelta = hypot(nextBar - firstBar, nextBarY - firstBarY)
                print("SelectionMotion label=\(label) observation=\(observation) deltaPixels=\(visibleDelta)")
                if visibleDelta > 3 { break }
            }
            XCTAssertGreaterThan(visibleDelta, 3,
                                 "Advancing clocks must produce different visible video frames", file: file, line: line)
            let customAdvanced = await waitUntil(timeout: 1) {
                service.submittedVideoFrameCount > firstSubmitted && screen.customVideoLayer?.isReadyForDisplay == true
            }
            XCTAssertTrue(customAdvanced, "Motion proof requires new custom-frame submission beyond the first capture", file: file, line: line)
        } catch { XCTFail("Moving-frame proof failed: \(error)", file: file, line: line) }
    }

    private func assertMotionCaptureWindow(_ states: [SelectionVideoCaptureState], label: String,
                                            file: StaticString, line: UInt) -> Bool {
        guard let first = states.first, let last = states.last else { return false }
        let wall = last.uptime - first.uptime
        let positions = states.map(\.playerPosition)
        let media = (positions.max() ?? .infinity) - (positions.min() ?? -.infinity)
        let pcm = Double(last.audioFrame - first.audioFrame) / 48_000
        let validPositions = positions.allSatisfy { $0.isFinite && $0 >= 0 }
        let stableSource = first.audioToken != 0 && states.allSatisfy {
            $0.audioToken == first.audioToken && $0.audioVisit == first.audioVisit
        }
        let monotonicPCM = zip(states, states.dropFirst()).allSatisfy { pair in pair.0.audioFrame <= pair.1.audioFrame }
        let noUnderruns = states.allSatisfy { $0.audioUnderrunFrames == first.audioUnderrunFrames }
        print("SelectionMotionWindow label=\(label) captures=\(states.count / 2) wallSeconds=\(wall) mediaSeconds=\(media) pcmSeconds=\(pcm) stableSource=\(stableSource) monotonicPCM=\(monotonicPCM) noUnderruns=\(noUnderruns)")
        XCTAssertGreaterThanOrEqual(wall, 0, file: file, line: line)
        XCTAssertLessThan(wall, 29, "The capture window must fit inside the fixture's nonrepeating 30-second presentation", file: file, line: line)
        XCTAssertTrue(validPositions, "Capture media-time brackets must be finite and nonnegative", file: file, line: line)
        XCTAssertLessThan(media, 29, "The bracketed media window must exclude a full presentation or loop", file: file, line: line)
        XCTAssertGreaterThanOrEqual(pcm, 0, file: file, line: line)
        XCTAssertLessThan(pcm, 29, file: file, line: line)
        XCTAssertTrue(stableSource && monotonicPCM, "No PCM token, visit or loop change may cross the capture window", file: file, line: line)
        XCTAssertTrue(noUnderruns, "audioClockHold/underruns: capture acquisition must not conceal a new PCM underrun", file: file, line: line)
        return wall >= 0 && wall < 29 && validPositions && media < 29 && pcm >= 0 && pcm < 29
            && stableSource && monotonicPCM && noUnderruns
    }

    private func require(_ condition: () -> Bool, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        guard await waitUntil(condition) else {
            XCTFail(message, file: file, line: line)
            throw SelectionVideoTestFailure.timeout
        }
    }

    private func waitUntil(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return condition()
    }
}

enum SelectionVideoIdentity: String { case a, b }
private enum SelectionVideoTestFailure: Error {
    case timeout, sample, capture, unsafeCapturePath
    case simulatorCaptureUnavailable
    case simulatorCaptureRejected(Int)
}

@MainActor
final class SelectionVideoFixture {
    static let duration = 30.0
    let temporary: URL
    let cloud: OneDriveClient
    let downloads: OfflineDownloads
    let library: LibraryRepository
    let ids: [String]
    let playlist = "local:selected-video-regression-" + UUID().uuidString
    var aID: String { ids[0] }
    var bID: String { ids[1] }
    var bookmark: URL { temporary.appendingPathComponent("playback.json") }
    private(set) var savedURLs: [String: URL] = [:]
    private let previousSpeakerSound = UserDefaults.standard.object(forKey: "speakerSound")
    private let previousAutomaticPiP = UserDefaults.standard.object(forKey: "automaticPiP")

    init() async throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        cloud = OneDriveClient(account: MicrosoftAccount())
        downloads = OfflineDownloads(cloud: cloud, network: NetworkStatus(),
            storageRoot: temporary.appendingPathComponent("Downloads", isDirectory: true), usesBackgroundSession: false)
        library = LibraryRepository(cloud: cloud, catalogURL: temporary.appendingPathComponent("catalog.json"))
        ids = ["local:selected-A-" + UUID().uuidString, "local:selected-B-" + UUID().uuidString]
        do {
            for (index, identity) in [SelectionVideoIdentity.a, .b].enumerated() {
                let source = try XCTUnwrap(Bundle(for: PlaybackSelectionVideoRegressionTests.self)
                    .url(forResource: "test-selection-" + identity.rawValue, withExtension: "mp4"))
                _ = try await downloads.importLocal(source, mediaID: ids[index])
            }
            let records = ids.map { MediaRecord(id: $0, title: "Generated selection fixture", creator: "Test", duration: Self.duration) }
            try library.install(LibraryCatalog(libraryID: "local:selection-regression", media: records,
                                               playlists: [PlaylistRecord(id: playlist, name: "Generated", itemIDs: ids)]))
            for record in records {
                let saved = await downloads.localURL(for: record)
                savedURLs[record.id] = try XCTUnwrap(saved)
            }
        } catch { remove(); throw error }
    }

    func service(buffer: PlaybackBuffer? = nil, continuousAudio: ContinuousAudioPlayer? = nil,
                 seekVideo: PlaybackService.SeekVideo? = nil) -> PlaybackService {
        let result: PlaybackService
        if let seekVideo {
            result = PlaybackService(library: library, downloads: downloads, cloud: cloud,
                                     bookmarkURL: bookmark, activateSession: {}, buffer: buffer, continuousAudio: continuousAudio, seekVideo: seekVideo)
        } else {
            result = PlaybackService(library: library, downloads: downloads, cloud: cloud,
                                     bookmarkURL: bookmark, activateSession: {}, buffer: buffer, continuousAudio: continuousAudio)
        }
        result.speakerSound = false
        result.automaticPiP = false
        return result
    }

    /// This verifies encoded fixture identity independently of PlaybackService and its token.
    /// It does not claim to measure which tone reached a physical speaker.
    func decodedTone(id: String, startSeconds: Double = 0.5) async throws -> [Float] {
        let asset = AVURLAsset(url: try XCTUnwrap(savedURLs[id]))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw SelectionVideoTestFailure.sample }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: startSeconds, preferredTimescale: 48_000),
                                      duration: CMTime(value: 12_000, timescale: 48_000))
        guard reader.startReading() else { throw reader.error ?? SelectionVideoTestFailure.sample }
        defer { reader.cancelReading() }
        var left: [Float] = []
        while let sample = output.copyNextSampleBuffer(), left.count < 12_000 {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw SelectionVideoTestFailure.sample }
            let byteCount = CMBlockBufferGetDataLength(block)
            guard byteCount > 0, byteCount % 8 == 0, byteCount <= 1_048_576 else { throw SelectionVideoTestFailure.sample }
            var values = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw SelectionVideoTestFailure.sample }
            for index in stride(from: 0, to: values.count, by: 2) where left.count < 12_000 {
                left.append(values[index])
            }
        }
        guard reader.status != .failed else { throw reader.error ?? SelectionVideoTestFailure.sample }
        return left
    }

    func remove() {
        downloads.shutdownLocalSession()
        for id in ids { downloads.remove(id) }
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let owned = temporary.standardizedFileURL
        // Only this fixture's UUID directory is recursively removed. Cleanup is
        // idempotent when initialization failed or a prior cleanup already ran.
        if UUID(uuidString: owned.lastPathComponent) != nil,
           owned.deletingLastPathComponent().resolvingSymlinksInPath() == parent,
           owned.resolvingSymlinksInPath().deletingLastPathComponent() == parent,
           manager.fileExists(atPath: owned.path) {
            do { try manager.removeItem(at: owned) }
            catch { print("SelectionFixture cleanupErrorCode=\((error as NSError).code)") }
        }
        if let previousSpeakerSound { UserDefaults.standard.set(previousSpeakerSound, forKey: "speakerSound") }
        else { UserDefaults.standard.removeObject(forKey: "speakerSound") }
        if let previousAutomaticPiP { UserDefaults.standard.set(previousAutomaticPiP, forKey: "automaticPiP") }
        else { UserDefaults.standard.removeObject(forKey: "automaticPiP") }
    }

}

@MainActor
private final class SelectionLatencySeekProbe {
    weak var service: PlaybackService? {
        didSet {
            service?.onPlaybackEvent = { [weak self] event in
                guard let self, self.phase >= 0 else { return }
                let observed = SelectionOutputTap.hostSeconds()
                self.diagnostics.append(.playback(name: event.name, commandMs: (observed - self.origin) * 1_000,
                    eventUptime: event.uptime, generation: event.generation, clockPosition: event.clockPosition), phase: self.phase)
            }
        }
    }
    var phase = -1 {
        didSet {
            videoMilestones.removeAll(keepingCapacity: true)
            diagnostics.prepare(phase: phase)
        }
    }
    var origin = 0.0
    private var videoMilestones = Set<String>()
    private let diagnostics = SelectionLatencyDiagnostics()
    private(set) var alignedPreparedSeekCount: [Int: Int] = [:]
    private(set) var nativeSeekCount: [Int: Int] = [:]
    var droppedCount: Int { diagnostics.droppedCount }

    init() { videoMilestones.reserveCapacity(2); diagnostics.prepare(phase: phase) }

    func sampleVideo() {
        guard videoMilestones.count < 2, let service else { return }
        for (name, position) in [("firstCopied", service.copiedVideoFramePositionSeconds),
                                 ("firstSubmitted", service.videoFramePositionSeconds)] {
            guard let position, videoMilestones.insert(name).inserted else { continue }
            diagnostics.append(.video(name: name, commandMs: (SelectionOutputTap.hostSeconds() - origin) * 1_000,
                framePosition: position, requested: service.videoRequestedPositionSeconds,
                playerPosition: service.player.currentTime().seconds, playerRate: Double(service.player.rate)), phase: phase)
        }
    }

    func seek(_ player: AVPlayer, _ time: CMTime, _ completion: @escaping @Sendable (Bool) -> Void) {
        let started = SelectionOutputTap.hostSeconds()
        let phase = self.phase, origin = self.origin, requested = time.seconds
        let current = player.currentTime().seconds, rate = Double(player.rate)
        nativeSeekCount[phase, default: 0] += 1
        if phase > 0, abs(current - requested) <= 0.080, rate > 0.999 {
            alignedPreparedSeekCount[phase, default: 0] += 1
        }
        let diagnostics = self.diagnostics
        diagnostics.append(.seekStart(commandMs: (started - origin) * 1_000, requested: requested,
            playerPosition: current, playerRate: rate), phase: phase)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, diagnostics] finished in
            let completed = SelectionOutputTap.hostSeconds()
            // Forward the real completion before recording or scheduling diagnostics.
            completion(finished)
            diagnostics.append(.nativeComplete(commandMs: (completed - origin) * 1_000,
                seekMs: (completed - started) * 1_000, finished: finished), phase: phase)
            Task { @MainActor [weak self, diagnostics] in
                guard let service = self?.service else { return }
                let observed = SelectionOutputTap.hostSeconds()
                diagnostics.append(.completionObserved(commandMs: (observed - origin) * 1_000,
                    requested: requested, playerPosition: service.player.currentTime().seconds,
                    playerRate: Double(service.player.rate)), phase: phase)
            }
        }
    }

    /// Call only after the timed measurement has stopped. Late completions retain
    /// their original phase and are emitted by the next dump without resetting it.
    func dump() {
        let snapshot = diagnostics.takeUndumpedSnapshot()
        for phase in snapshot.phases {
            for event in phase.events { print(event.line(phase: phase.id)) }
            print("SelectionLatencyDiagnostics phase=\(phase.id) events=\(phase.totalCount) emitted=\(phase.events.count) droppedCount=\(phase.droppedCount)")
        }
        XCTAssertEqual(snapshot.droppedCount, 0, "Bounded latency diagnostics must not silently discard evidence")
    }
}

/// Typed test-only diagnostics. Every phase reserves its fixed capacity once;
/// formatting and console I/O happen after releasing the recorder lock in dump().
private final class SelectionLatencyDiagnostics: @unchecked Sendable {
    enum Event: Sendable {
        case playback(name: String, commandMs: Double, eventUptime: Double, generation: Int, clockPosition: Double)
        case video(name: String, commandMs: Double, framePosition: Double, requested: Double, playerPosition: Double, playerRate: Double)
        case seekStart(commandMs: Double, requested: Double, playerPosition: Double, playerRate: Double)
        case nativeComplete(commandMs: Double, seekMs: Double, finished: Bool)
        case completionObserved(commandMs: Double, requested: Double, playerPosition: Double, playerRate: Double)

        func line(phase: Int) -> String {
            switch self {
            case let .playback(name, commandMs, eventUptime, generation, clockPosition):
                return "SelectionLatencyEvent phase=\(phase) name=\(name) commandMs=\(commandMs) eventUptime=\(eventUptime) generation=\(generation) clockPosition=\(clockPosition)"
            case let .video(name, commandMs, framePosition, requested, playerPosition, playerRate):
                return "SelectionLatencyVideo phase=\(phase) name=\(name) commandMs=\(commandMs) framePosition=\(framePosition) requested=\(requested) playerPosition=\(playerPosition) playerRate=\(playerRate)"
            case let .seekStart(commandMs, requested, playerPosition, playerRate):
                return "SelectionLatencySeek phase=\(phase) event=start commandMs=\(commandMs) requested=\(requested) playerPosition=\(playerPosition) drift=\(playerPosition - requested) playerRate=\(playerRate)"
            case let .nativeComplete(commandMs, seekMs, finished):
                return "SelectionLatencySeek phase=\(phase) event=nativeComplete commandMs=\(commandMs) seekMs=\(seekMs) finished=\(finished)"
            case let .completionObserved(commandMs, requested, playerPosition, playerRate):
                return "SelectionLatencySeek phase=\(phase) event=completionObserved commandMs=\(commandMs) playerPosition=\(playerPosition) requested=\(requested) drift=\(playerPosition - requested) playerRate=\(playerRate)"
            }
        }
    }

    struct PhaseSnapshot {
        let id: Int
        let events: [Event]
        let totalCount: Int
        let droppedCount: Int
    }
    struct Snapshot {
        let phases: [PhaseSnapshot]
        let droppedCount: Int
    }
    private final class Phase {
        var events: [Event] = []
        var dumpedCount = 0
        var droppedCount = 0
        init(capacity: Int) { events.reserveCapacity(capacity) }
    }
    private let lock = NSLock()
    private let capacity = 256
    private var phases: [Int: Phase] = [:]

    init() { phases.reserveCapacity(5) }

    var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return phases.values.reduce(0) { $0 + $1.droppedCount }
    }

    func prepare(phase id: Int) {
        lock.lock(); defer { lock.unlock() }
        if phases[id] == nil { phases[id] = Phase(capacity: capacity) }
    }

    func append(_ event: Event, phase id: Int) {
        lock.lock(); defer { lock.unlock() }
        let phase: Phase
        if let existing = phases[id] { phase = existing }
        else { phase = Phase(capacity: capacity); phases[id] = phase }
        guard phase.events.count < capacity else { phase.droppedCount += 1; return }
        phase.events.append(event)
    }

    func takeUndumpedSnapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var result: [PhaseSnapshot] = []
        result.reserveCapacity(phases.count)
        var dropped = 0
        for id in phases.keys.sorted() {
            guard let phase = phases[id] else { continue }
            result.append(PhaseSnapshot(id: id, events: Array(phase.events.dropFirst(phase.dumpedCount)),
                totalCount: phase.events.count, droppedCount: phase.droppedCount))
            phase.dumpedCount = phase.events.count
            dropped += phase.droppedCount
        }
        return Snapshot(phases: result, droppedCount: dropped)
    }
}

/// Test-only mixer capture. Copies are bounded to twelve seconds at 48 kHz;
/// no disk writes, microphone recording, or physical-speaker claim is involved.
private final class SelectionOutputTap: @unchecked Sendable {
    struct Window {
        let samples: [Float]
        let rate: Double
        let start: Double
        let end: Double
    }
    private let lock = NSLock()
    private let capacity = 12 * 48_000
    private var values: [Float] = []
    private var hosts: [Double] = []
    private var rate = 0.0
    private var enabled = false
    private var invalidTimestamps = 0
    private var droppedFrames = 0
    init() { values.reserveCapacity(capacity); hosts.reserveCapacity(capacity) }
    static func hostSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    func begin() -> Int {
        lock.lock(); defer { lock.unlock() }
        enabled = true
        return values.count
    }
    func stop() { lock.lock(); enabled = false; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        guard time.isHostTimeValid, buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
              buffer.format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData else {
            invalidTimestamps += 1; return
        }
        let actualRate = buffer.format.sampleRate
        if rate == 0 { rate = actualRate }
        guard abs(actualRate - rate) < 0.1 else { invalidTimestamps += 1; return }
        let start = AVAudioTime.seconds(forHostTime: time.hostTime)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0, start.isFinite else { invalidTimestamps += 1; return }
        let frames = min(Int(buffer.frameLength), capacity - values.count)
        droppedFrames += Int(buffer.frameLength) - frames
        for frame in 0..<frames {
            let left = channels[0][buffer.format.isInterleaved ? frame * channelCount : frame]
            let right = channelCount > 1 ? (buffer.format.isInterleaved ? channels[0][frame * channelCount + 1] : channels[1][frame]) : left
            values.append((left + right) * 0.5)
            hosts.append(start + Double(frame) / actualRate)
        }
    }
    func window(at index: Int) -> Window? {
        lock.lock(); defer { lock.unlock() }
        let count = Int(rate * 0.02)
        guard count > 0, index >= 0, index + count <= values.count else { return nil }
        return Window(samples: Array(values[index..<(index + count)]), rate: rate,
                      start: hosts[index], end: hosts[index + count - 1] + 1 / rate)
    }
    func samples(since index: Int) -> (values: [Float], hosts: [Double], rate: Double) {
        lock.lock(); defer { lock.unlock() }
        return (Array(values[min(index, values.count)...]), Array(hosts[min(index, hosts.count)...]), rate)
    }
    func validity() -> (invalidTimestamps: Int, droppedFrames: Int) {
        lock.lock(); defer { lock.unlock() }
        return (invalidTimestamps, droppedFrames)
    }
    static func isTone(_ samples: [Float], rate: Double, frequency: Double) -> Bool {
        guard !samples.isEmpty, rate > 0 else { return false }
        func power(_ hz: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for (index, value) in samples.enumerated() {
                let phase = 2 * Double.pi * hz * Double(index) / rate
                real += Double(value) * cos(phase); imaginary += Double(value) * sin(phase)
            }
            return (real * real + imaginary * imaginary) / pow(Double(samples.count), 2)
        }
        let energy = power(frequency)
        return energy > 0.001 && energy > 10 * max(power(frequency == 440 ? 880 : 440), 1e-12)
    }
    static func quietRun(_ samples: [Float], rate: Double) -> Double {
        let window = Int(rate * 0.01)
        guard window > 0, samples.count >= window else { return 0 }
        var longest = 0, run = 0
        for start in stride(from: 0, through: samples.count - window, by: window) {
            var square = 0.0
            for value in samples[start..<(start + window)] { square += Double(value) * Double(value) }
            if sqrt(square / Double(window)) < 0.01 { run += 1; longest = max(longest, run) }
            else { run = 0 }
        }
        return Double(longest * window) / rate
    }
    static func maximumTimelineHole(_ hosts: [Double], rate: Double) -> Double {
        guard rate > 0, hosts.count > 1 else { return 0 }
        var largest = 0.0
        for index in 1..<hosts.count {
            let interval = hosts[index] - hosts[index - 1]
            guard interval.isFinite, interval > 0 else { return .infinity }
            largest = max(largest, interval - 1 / rate)
        }
        return largest
    }
}

@MainActor
private final class SelectionVideoSeekScheduler {
    var onSeekStarted: (@MainActor () -> Void)?
    private(set) var nativeFinished: Bool?
    private var intercepted = false
    private var released = false
    private var heldCompletion: (@Sendable (Bool) -> Void)?
    var isHoldingCompletion: Bool { heldCompletion != nil }

    func seek(_ player: AVPlayer, _ time: CMTime, _ completion: @escaping @Sendable (Bool) -> Void) {
        let hold = !intercepted && abs(time.seconds - 0.4) < 0.000_001
        if hold { intercepted = true; onSeekStarted?() }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { completion(finished); return }
                if hold, !self.released { self.nativeFinished = finished; self.heldCompletion = completion }
                else { completion(finished) }
            }
        }
    }

    func release() {
        // Teardown can precede the native callback. In that case the callback
        // passes through when it arrives instead of becoming a leaked hold.
        released = true
        guard let completion = heldCompletion, let finished = nativeFinished else { return }
        heldCompletion = nil
        completion(finished)
    }
}

private struct SelectionVideoCaptureState {
    let uptime: Double
    let playerPosition: Double
    let audioFrame: Int64
    let audioVisit: Int64
    let audioToken: Int
    let audioUnderrunFrames: Int64
}

private struct SelectionProducerContext: Sendable {
    let renderer: ContinuousPCMRenderer
    let producer: ContinuousPCMDecoder.ProgressRecorder
    let nativeSamplePurpose: Int?

    init(renderer: ContinuousPCMRenderer, producer: ContinuousPCMDecoder.ProgressRecorder,
         nativeSamplePurpose: Int? = nil) {
        self.renderer = renderer; self.producer = producer
        self.nativeSamplePurpose = nativeSamplePurpose
    }
}

/// Synthetic native tests request one bounded CI worker stack only after an
/// existing setup failure or an observed new underrun. The host verifies PID,
/// exact Simulator/app ownership and a two-sample run cap before profiling.
private enum SelectionNativeWorkerSample {
    private struct Request: Encodable {
        let schemaVersion: Int
        let requestID: String
        let processID: Int
        let purposeCode: Int
    }

    @discardableResult
    static func request(purpose: Int, identifier: String = UUID().uuidString.lowercased()) -> Bool {
        guard (0...1).contains(purpose), UUID(uuidString: identifier)?.uuidString.lowercased() == identifier else { return false }
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "OfflinePlayer-TestWorkerTrace-" + identifier
        let partial = temporary.appendingPathComponent(prefix + ".partial")
        let request = temporary.appendingPathComponent(prefix + ".request.json")
        guard [partial, request].allSatisfy({
            $0.deletingLastPathComponent() == temporary
                && $0.resolvingSymlinksInPath().deletingLastPathComponent() == temporary
                && !manager.fileExists(atPath: $0.path)
        }) else { return false }
        var created = false
        defer { if created { try? manager.removeItem(at: partial) } }
        do {
            let data = try JSONEncoder().encode(Request(schemaVersion: 1, requestID: identifier,
                processID: Int(ProcessInfo.processInfo.processIdentifier), purposeCode: purpose))
            guard data.count <= 1_024 else { return false }
            try data.write(to: partial, options: .withoutOverwriting)
            created = true
            try manager.moveItem(at: partial, to: request)
            return true
        } catch { return false }
    }
}

/// A test-only sampler independent of both the UI and decode queues, with fixed
/// numeric records, no media, no console I/O and no unbounded seqlock read.
/// After a proven underrun, an enabled probe may write one bounded stack request.
/// Ordinary probes keep 128 records/eight seconds; full captures cap at 512/45s.
private final class SelectionProducerProbe: @unchecked Sendable {
    struct Sample: Sendable {
        let uptime: UInt64
        let acquisitionBegin: UInt64
        let audioAcquisitionEnd: UInt64
        let producerAcquisitionEnd: UInt64
        let audio: ContinuousPCMRenderer.Snapshot
        let producer: ContinuousPCMDecoder.ProgressSnapshot
    }
    struct Result: Sendable {
        let origin: UInt64
        let initial: ContinuousPCMRenderer.Snapshot?
        let samples: [Sample]
        let skipped: Int
        let dropped: Int
        let maximumGap: UInt64
        let durationSeconds: Double
        let capacity: Int
        let nativeSampleRequestID: String?
        let nativeSampleWriteCode: Int

        func dump(label: String) {
            let delta: String
            if let initial, let last = samples.last { delta = String(last.audio.underrunFrames - initial.underrunFrames) }
            else { delta = "missing" }
            let observedMs = samples.last.map { String(Double($0.uptime - origin) / 1_000_000) } ?? "missing"
            print("SelectionProducerWindow label=\(label) requestedSeconds=\(durationSeconds) capacity=\(capacity) observedUntilMs=\(observedMs) samples=\(samples.count) skipped=\(skipped) dropped=\(dropped) maxSamplerGapMs=\(Double(maximumGap) / 1_000_000) underrunDelta=\(delta) nativeSampleRequestID=\(nativeSampleRequestID ?? "none") nativeSampleWriteCode=\(nativeSampleWriteCode)")
            for sample in samples {
                let progress = sample.producer
                let age = progress.phaseEnteredUptimeNanoseconds > 0 && sample.producerAcquisitionEnd >= progress.phaseEnteredUptimeNanoseconds
                    ? Double(sample.producerAcquisitionEnd - progress.phaseEnteredUptimeNanoseconds) / 1_000_000 : -1
                print("SelectionProducerSample label=\(label) elapsedMs=\(Double(sample.uptime - origin) / 1_000_000) audioAcquisitionMs=\(Double(sample.audioAcquisitionEnd - sample.acquisitionBegin) / 1_000_000) producerAcquisitionMs=\(Double(sample.producerAcquisitionEnd - sample.audioAcquisitionEnd) / 1_000_000) nativeTrace=\(progress.tracingEnabled) audioToken=\(sample.audio.token) audioVisit=\(sample.audio.visit) audioFrame=\(sample.audio.frame) ended=\(sample.audio.ended) underrunFrames=\(sample.audio.underrunFrames) phase=\(progress.phase.rawValue) phaseToken=\(progress.token) slot=\(progress.slot) epoch=\(progress.epoch) phaseAgeMs=\(age) phaseSequence=\(progress.phaseSequence) pumpCount=\(progress.pumpCount) currentTokenAtLastPump=\(progress.currentTokenAtLastPump) acceptedFrames=\(progress.acceptedFrames) appendCount=\(progress.appendCount) lastAcceptedNs=\(progress.lastAcceptedUptimeNanoseconds) lastAcceptedToken=\(progress.lastAcceptedToken) lastAcceptedSlot=\(progress.lastAcceptedSlot) lastAcceptedEpoch=\(progress.lastAcceptedEpoch) slot0Token=\(progress.slot0.token) slot0Epoch=\(progress.slot0.epoch) slot0Accepted=\(progress.slot0.acceptedFrames) slot0Appends=\(progress.slot0.appendCount) slot0LastAcceptedNs=\(progress.slot0.lastAcceptedUptimeNanoseconds) slot1Token=\(progress.slot1.token) slot1Epoch=\(progress.slot1.epoch) slot1Accepted=\(progress.slot1.acceptedFrames) slot1Appends=\(progress.slot1.appendCount) slot1LastAcceptedNs=\(progress.slot1.lastAcceptedUptimeNanoseconds) slot2Token=\(progress.slot2.token) slot2Epoch=\(progress.slot2.epoch) slot2Accepted=\(progress.slot2.acceptedFrames) slot2Appends=\(progress.slot2.appendCount) slot2LastAcceptedNs=\(progress.slot2.lastAcceptedUptimeNanoseconds) coherent=\(progress.coherent)")
            }
        }
    }

    private let context: SelectionProducerContext
    private let timer: DispatchSourceTimer
    private let origin = DispatchTime.now().uptimeNanoseconds
    private let initial: ContinuousPCMRenderer.Snapshot?
    private let durationSeconds: Double
    private let durationNanoseconds: UInt64
    private let capacity: Int
    private let nativeSampleIdentifier: String?
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var stopped = false
    private var skipped = 0
    private var dropped = 0
    private var previousSample: UInt64?
    private var maximumGap: UInt64 = 0
    private var baselineUnderruns: Int64?
    private var nativeSampleRequested = false
    // 0 no request, 1 attempted/pending, 2 written, 3 failed to write.
    private var nativeSampleWriteCode = 0

    init(context: SelectionProducerContext, durationSeconds: Double = 8, capacity: Int = 128) {
        precondition(durationSeconds > 0 && durationSeconds <= 45
            && capacity >= Int(ceil(durationSeconds * 10)) && capacity <= 512)
        self.context = context
        self.durationSeconds = durationSeconds
        durationNanoseconds = UInt64(durationSeconds * 1_000_000_000)
        self.capacity = capacity
        nativeSampleIdentifier = context.nativeSamplePurpose.map { _ in UUID().uuidString.lowercased() }
        let baseline = context.renderer.diagnosticSnapshot
        initial = baseline
        baselineUnderruns = baseline?.underrunFrames
        timer = DispatchSource.makeTimerSource(flags: .strict,
            queue: DispatchQueue(label: "OfflinePlayer.TestProducerProbe", qos: .utility))
        samples.reserveCapacity(capacity)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    private func sample() {
        let begin = DispatchTime.now().uptimeNanoseconds
        if begin - origin >= durationNanoseconds { timer.cancel(); return }
        let audio = context.renderer.diagnosticSnapshot
        let audioEnd = DispatchTime.now().uptimeNanoseconds
        let producer = context.producer.snapshot()
        let producerEnd = DispatchTime.now().uptimeNanoseconds
        record(audio: audio, producer: producer, begin: begin,
            audioEnd: audioEnd, producerEnd: producerEnd)
    }

    private func record(audio: ContinuousPCMRenderer.Snapshot?, producer: ContinuousPCMDecoder.ProgressSnapshot,
        begin: UInt64, audioEnd: UInt64, producerEnd: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        guard let audio else { skipped += 1; return }
        guard samples.count < capacity else { dropped += 1; return }
        if let previousSample { maximumGap = max(maximumGap, audioEnd - previousSample) }
        previousSample = audioEnd
        samples.append(Sample(uptime: audioEnd, acquisitionBegin: begin, audioAcquisitionEnd: audioEnd,
            producerAcquisitionEnd: producerEnd, audio: audio, producer: producer))
        if baselineUnderruns == nil { baselineUnderruns = audio.underrunFrames }
        guard let purpose = context.nativeSamplePurpose, let identifier = nativeSampleIdentifier,
              !nativeSampleRequested,
              audio.underrunFrames > (baselineUnderruns ?? audio.underrunFrames) else { return }
        nativeSampleRequested = true; nativeSampleWriteCode = 1
        // Serialize this small, failure-triggered file write with stop(). A
        // request must not appear after teardown and sample a later fixture.
        let written = SelectionNativeWorkerSample.request(purpose: purpose, identifier: identifier)
        nativeSampleWriteCode = written ? 2 : 3
    }

    func stop() -> Result {
        timer.cancel()
        lock.lock(); defer { lock.unlock() }
        stopped = true
        return Result(origin: origin, initial: initial, samples: samples, skipped: skipped,
                      dropped: dropped, maximumGap: maximumGap, durationSeconds: durationSeconds, capacity: capacity,
                      nativeSampleRequestID: nativeSampleRequested ? nativeSampleIdentifier : nil,
                      nativeSampleWriteCode: nativeSampleWriteCode)
    }

    deinit { timer.cancel() }
}

@MainActor
private final class SelectionVideoScreen {
    let window: UIWindow
    let service: PlaybackService
    private weak var previousKeyWindow: UIWindow?
    private let producerContext: SelectionProducerContext?
    private let producerWindowSeconds: Double
    private let producerSampleCapacity: Int
    private var producerResults: [(String, SelectionProducerProbe.Result)] = []
    private var captureLogs: [String] = []
    private var droppedDiagnostics = 0
    var customVideoLayer: AVSampleBufferDisplayLayer? {
        service.surface.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.last
    }

    init(service: PlaybackService, producerContext: SelectionProducerContext? = nil,
         producerWindowSeconds: Double = 8, producerSampleCapacity: Int = 128) throws {
        self.service = service
        self.producerContext = producerContext
        self.producerWindowSeconds = producerWindowSeconds
        self.producerSampleCapacity = producerSampleCapacity
        producerResults.reserveCapacity(40); captureLogs.reserveCapacity(128)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: SelectionVideoHarness(service: service))
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
        for line in captureLogs { print(line) }
        for (label, result) in producerResults { result.dump(label: label) }
        XCTAssertEqual(droppedDiagnostics, 0, "Bounded capture diagnostics must not discard evidence")
    }

    func capture(label: String, test: XCTestCase) async throws -> SelectionVideoPixels {
        let producerProbe = producerContext.map {
            SelectionProducerProbe(context: $0, durationSeconds: producerWindowSeconds, capacity: producerSampleCapacity)
        }
        defer {
            if let producerProbe {
                let result = producerProbe.stop()
                if producerResults.count < 40 { producerResults.append((label, result)) }
                else { droppedDiagnostics += 1 }
            }
        }
        let before = captureState()
        let started = before.uptime
        var completed = false
        logCapture(label: label, phase: "before", started: started, failed: false)
        defer { logCapture(label: label, phase: "after", started: started, failed: !completed) }
        window.rootViewController?.view.layoutIfNeeded()
        CATransaction.flush()
        let image: UIImage
        let scaleX: CGFloat
        let scaleY: CGFloat
        #if targetEnvironment(simulator)
        // drawHierarchy can omit hardware-backed video. Require the host compositor on
        // Simulator; never replace missing onscreen pixels with decoded asset images.
        image = try await compositorImage()
        guard let cg = image.cgImage, window.bounds.width > 0, window.bounds.height > 0 else {
            throw SelectionVideoTestFailure.capture
        }
        scaleX = CGFloat(cg.width) / window.bounds.width
        scaleY = CGFloat(cg.height) / window.bounds.height
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var drewHierarchy = false
        image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard drewHierarchy else { throw SelectionVideoTestFailure.capture }
        scaleX = 1; scaleY = 1
        #endif
        let attachment = XCTAttachment(image: image)
        attachment.name = "Selected-video-composite-" + label
        attachment.lifetime = .keepAlways
        test.add(attachment)
        // This is the complete onscreen hierarchy cropped to the real surface, never an
        // AVAssetImageGenerator image substituted underneath the opaque poster.
        let points = service.surface.convert(service.surface.bounds, to: window)
        let rect = CGRect(x: points.minX * scaleX, y: points.minY * scaleY,
                          width: points.width * scaleX, height: points.height * scaleY).integral
        guard let cg = image.cgImage, rect.width > 0, rect.height > 0,
              CGRect(x: 0, y: 0, width: cg.width, height: cg.height).contains(rect),
              let cropped = cg.cropping(to: rect) else { throw SelectionVideoTestFailure.capture }
        var pixels = try SelectionVideoPixels(cropped, scaleX: Double(scaleX), scaleY: Double(scaleY), captureBefore: before)
        pixels.captureAfter = captureState()
        completed = true
        return pixels
    }

    private func captureState() -> SelectionVideoCaptureState {
        let audio = service.audioSnapshot
        return SelectionVideoCaptureState(uptime: ProcessInfo.processInfo.systemUptime,
            playerPosition: service.player.currentTime().seconds, audioFrame: audio.frame,
            audioVisit: audio.visit, audioToken: audio.token, audioUnderrunFrames: audio.underrunFrames)
    }

    private func logCapture(label: String, phase: String, started: Double, failed: Bool) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let audio = service.audioSnapshot
        guard captureLogs.count < 128 else { droppedDiagnostics += 1; return }
        captureLogs.append("SelectionCapture label=\(label) phase=\(phase) uptime=\(uptime) elapsed=\(uptime - started) failed=\(failed) playerPosition=\(service.player.currentTime().seconds) playerRate=\(service.player.rate) audioFrame=\(audio.frame) audioVisit=\(audio.visit) audioToken=\(audio.token) audioUnderrunFrames=\(audio.underrunFrames) engineRunning=\(service.audioEngineRunning) wantsToPlay=\(service.wantsToPlay) requested=\(service.videoRequestedPositionSeconds) timebase=\(service.videoTimebasePositionSeconds.map { String($0) } ?? "missing") copiedPTS=\(service.copiedVideoFramePositionSeconds.map { String($0) } ?? "missing") submittedPTS=\(service.videoFramePositionSeconds.map { String($0) } ?? "missing") submitted=\(service.submittedVideoFrameCount) futureRejected=\(service.pausedFutureVideoFrameRejectionCount) customReady=\(customVideoLayer?.isReadyForDisplay == true)")
    }

    #if targetEnvironment(simulator)
    private struct CaptureRequest: Encodable { let schemaVersion: Int; let requestID: String }
    private struct CaptureResponse: Decodable {
        let schemaVersion: Int
        let requestID: String
        let errorCode: Int
        let imageName: String
    }

    private func compositorImage() async throws -> UIImage {
        let manager = FileManager.default
        guard UIApplication.shared.applicationState == .active, window.isKeyWindow else {
            throw SelectionVideoTestFailure.capture
        }
        let temporary = manager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let identifier = UUID().uuidString.lowercased()
        let prefix = "OfflinePlayer-TestFrameCapture-" + identifier
        let request = temporary.appendingPathComponent(prefix + ".request.json")
        let response = temporary.appendingPathComponent(prefix + ".response.json")
        let image = temporary.appendingPathComponent(prefix + ".png")
        let paths = [request, response, image]
        for path in paths {
            guard path.deletingLastPathComponent() == temporary,
                  path.resolvingSymlinksInPath().deletingLastPathComponent() == temporary,
                  !manager.fileExists(atPath: path.path) else { throw SelectionVideoTestFailure.unsafeCapturePath }
        }
        defer { for path in paths { try? manager.removeItem(at: path) } }
        try JSONEncoder().encode(CaptureRequest(schemaVersion: 1, requestID: identifier)).write(to: request, options: .atomic)
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while !manager.fileExists(atPath: response.path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                // scripts/capture-simulator-test-frames.py must run beside the native test.
                throw SelectionVideoTestFailure.simulatorCaptureUnavailable
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        func validate(_ path: URL, maximum: Int) throws {
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard path.deletingLastPathComponent() == temporary,
                  path.resolvingSymlinksInPath().deletingLastPathComponent() == temporary,
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= maximum else {
                throw SelectionVideoTestFailure.unsafeCapturePath
            }
        }
        try validate(response, maximum: 4_096)
        let data = try Data(contentsOf: response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "requestID", "errorCode", "imageName"]) else {
            throw SelectionVideoTestFailure.unsafeCapturePath
        }
        let result = try JSONDecoder().decode(CaptureResponse.self, from: data)
        guard result.schemaVersion == 1, result.requestID == identifier,
              UUID(uuidString: result.requestID)?.uuidString.lowercased() == identifier,
              result.imageName == image.lastPathComponent else { throw SelectionVideoTestFailure.unsafeCapturePath }
        guard result.errorCode == 0 else { throw SelectionVideoTestFailure.simulatorCaptureRejected(result.errorCode) }
        try validate(image, maximum: 32 * 1_024 * 1_024)
        guard let captured = UIImage(contentsOfFile: image.path), let cg = captured.cgImage,
              UIApplication.shared.applicationState == .active, window.isKeyWindow,
              cg.width > 0, cg.height > 0, cg.width <= 10_000, cg.height <= 10_000,
              cg.width * cg.height <= 25_000_000 else { throw SelectionVideoTestFailure.capture }
        return captured
    }
    #endif
}

private struct SelectionVideoHarness: View {
    let service: PlaybackService
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FeedVideoSurface(surface: service.surface, isActive: true, isReady: service.isVideoReady) {
                Color(red: 1, green: 0, blue: 1)
            }.frame(width: 320, height: 192)
        }
    }
}

private struct SelectionVideoPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    let scaleX: Double
    let scaleY: Double
    let blueBarCenter: Double?
    let blueBarCenterY: Double?
    let captureBefore: SelectionVideoCaptureState
    var captureAfter: SelectionVideoCaptureState
    init(_ image: CGImage, scaleX: Double, scaleY: Double, captureBefore: SelectionVideoCaptureState) throws {
        width = image.width; height = image.height
        self.scaleX = scaleX; self.scaleY = scaleY
        self.captureBefore = captureBefore; self.captureAfter = captureBefore
        var storage = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = storage.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw SelectionVideoTestFailure.capture }
        bytes = storage
        var sumX = 0.0, sumY = 0.0, blueCount = 0
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            if storage[offset + 2] > 150 && storage[offset] < 100 && storage[offset + 1] < 100 {
                sumX += Double(pixel % width)
                sumY += Double(pixel / width)
                blueCount += 1
            }
        }
        blueBarCenter = blueCount >= 4 ? sumX / Double(blueCount) : nil
        blueBarCenterY = blueCount >= 4 ? sumY / Double(blueCount) : nil
    }

    func log(label: String, identity: SelectionVideoIdentity) {
        print("SelectionPixels label=\(label) expected=\(identity.rawValue) fraction=\(fraction(identity)) magenta=\(magentaFraction) blueCenterX=\(blueBarCenter.map { String($0) } ?? "missing") blueCenterY=\(blueBarCenterY.map { String($0) } ?? "missing") scaleX=\(scaleX) scaleY=\(scaleY)")
    }

    func fraction(_ identity: SelectionVideoIdentity) -> Double {
        fraction { r, g, b in identity == .a ? r > 150 && g < 100 && b < 100 : g > 150 && r < 100 && b < 100 }
    }
    var magentaFraction: Double { fraction { $0 > 150 && $1 < 100 && $2 > 150 } }
    private func fraction(_ predicate: (UInt8, UInt8, UInt8) -> Bool) -> Double {
        var count = 0
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            if predicate(bytes[offset], bytes[offset + 1], bytes[offset + 2]) { count += 1 }
        }
        return Double(count) / Double(max(1, width * height))
    }
}
