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
    /// Real mixer output and actual custom-layer submission, without screenshot or SDK-position probes.
    /// This is selected-frame readiness evidence, not compositor pixels or physical speaker output.
    func testProductionSelectionLatencyAndStreamingContinuityWithoutCapture() async throws {
        let fixture = try await SelectionVideoFixture()
        var mayRemoveFixture = true
        defer { if mayRemoveFixture { fixture.remove() } }
        var references: [(samples: [Float], frequency: Double)] = []
        for (id, frequency) in [(fixture.aID, 440.0), (fixture.bID, 880.0)] {
            references.append((try await fixture.decodedTone(id: id), frequency))
        }
        let audio = ContinuousAudioPlayer()
        let tap = ProductionSelectionOutputTap()
        let seeks = ProductionSelectionSeekRecorder()
        let service = fixture.service(continuousAudio: audio, seekVideo: seeks.seek)
        let screen = try SelectionVideoScreen(service: service)
        // From here, deletion requires the decoder's queued cleanup acknowledgement.
        mayRemoveFixture = false
        let originalSources = (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }
        let originalBytes = audio.renderer.retainedPCMMemoryBytes
        audio.graph.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil) { buffer, time in
            tap.append(buffer, time: time)
        }
        var measurements: [ProductionSelectionMeasurement] = []
        var streams: [ProductionSelectionStream] = []
        measurements.reserveCapacity(3); streams.reserveCapacity(3)
        var returnedStart: Int?
        var returnedEnd: Int?
        var returnedOrigin: Double?
        for phase in 0..<3 {
            let id = phase == 1 ? fixture.bID : fixture.aID
            let frequency = phase == 1 ? 880.0 : 440.0
            let prepared = phase != 0
            let preparedBefore: Bool
            if prepared {
                preparedBefore = await waitUntil(timeout: 5) {
                    service.preparedAudioCount == 2 && audio.entry(for: id) != nil
                }
            } else { preparedBefore = true }
            let measurement = await measureProductionSelection(service, screen: screen, fixture: fixture,
                audio: audio, tap: tap, seeks: seeks, phase: phase, id: id,
                frequency: frequency, prepared: prepared, preparedBefore: preparedBefore) {
                switch phase {
                case 0: service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
                case 1: service.next()
                default: service.previous()
                }
            }
            measurements.append(measurement)
            if phase == 2 {
                returnedOrigin = ProductionSelectionOutputTap.hostSeconds()
                returnedStart = tap.begin()
            }
            let baseline = audio.renderer.snapshot
            let before = productionSelectionState(service, fixture: fixture, audio: audio, id: id)
            let probe = ProductionRendererProbe(renderer: audio.renderer)
            try? await Task.sleep(for: .seconds(8))
            let result = probe.stop()
            let final = audio.renderer.snapshot
            let after = productionSelectionState(service, fixture: fixture, audio: audio, id: id)
            streams.append(ProductionSelectionStream(phase: phase, baseline: baseline, final: final,
                before: before, after: after, quantum: service.audioRenderQuantumFrames, result: result,
                memoryBytes: audio.renderer.retainedPCMMemoryBytes,
                sameStorage: originalSources == (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }))
            if phase == 2 { returnedEnd = tap.stop() }
        }

        // No dumps, spectral analysis or assertions interrupt any streaming window.
        tap.stop(); service.pause()
        audio.graph.engine.mainMixerNode.removeTap(onBus: 0)
        audio.graph.engine.stop(); screen.close()
        let shutdown = ProductionSelectionShutdown()
        let preparation = ProductionSelectionShutdown()
        #if DEBUG
        service.debugStopPreparation { preparation.complete(true) }
        audio.debugShutdown { shutdown.complete($0) }
        #endif
        let cleanupReturned = await waitUntil(timeout: 3) { shutdown.result != nil && preparation.result != nil }
        mayRemoveFixture = cleanupReturned && shutdown.result == true && preparation.result == true
        print("ProductionSelectionCleanup completed=\(mayRemoveFixture) ownedTasksJoined=\(preparation.result == true) producerTracing=absent sdkInternalQuiescence=unverified syntheticFixtureRetained=\(!mayRemoveFixture)")
        XCTAssertTrue(mayRemoveFixture, "Queued decoder cleanup must return before removing only this synthetic fixture")
        for reference in references {
            XCTAssertGreaterThanOrEqual(reference.samples.count, 10_000)
            XCTAssertTrue(ProductionSelectionOutputTap.isTone(reference.samples, rate: 48_000, frequency: reference.frequency))
            XCTAssertEqual(ProductionSelectionOutputTap.quietRun(reference.samples, rate: 48_000), 0,
                           "Independently decoded encoded fixtures must contain no 10 ms RMS-silence windows")
        }
        XCTAssertEqual(originalBytes, 6_912_000)
        XCTAssertEqual(Set(originalSources).count, 3)
        XCTAssertEqual(audio.renderer.sampleRate, 48_000); XCTAssertEqual(audio.renderer.channels, 2)
        for slot in 0..<3 {
            XCTAssertEqual(audio.renderer.source(at: slot).prefixCapacityFrames, 96_000)
            XCTAssertEqual(audio.renderer.source(at: slot).ringCapacityFrames, 192_000)
        }
        XCTAssertEqual(measurements.count, 3); XCTAssertEqual(streams.count, 3)
        XCTAssertLessThanOrEqual(streams.reduce(0) { $0 + $1.result.samples.count }, 384)
        for measurement in measurements { assertProductionSelection(measurement, tap: tap) }
        for stream in streams { assertProductionStream(stream) }
        if measurements.count == 3 {
            XCTAssertGreaterThan(measurements[0].state.expectedToken, 0)
            XCTAssertNotEqual(measurements[0].state.expectedToken, measurements[1].state.expectedToken)
            XCTAssertEqual(measurements[0].state.expectedToken, measurements[2].state.expectedToken,
                           "Previous must reuse the retained A preparation")
            XCTAssertGreaterThan(measurements[1].state.audio.visit, measurements[0].state.audio.visit)
            XCTAssertGreaterThan(measurements[2].state.audio.visit, measurements[1].state.audio.visit)
        }
        let returned = tap.samples(from: returnedStart ?? tap.count, to: returnedEnd ?? tap.count)
        let returnedSeconds = returned.rate > 0 ? Double(returned.values.count) / returned.rate : 0
        let returnedWall = returned.hosts.first.flatMap { first in returned.hosts.last.map { $0 - first + 1 / max(1, returned.rate) } } ?? 0
        let returnedQuiet = ProductionSelectionOutputTap.quietRun(returned.values, rate: returned.rate)
        let returnedHole = ProductionSelectionOutputTap.maximumTimelineHole(returned.hosts, rate: returned.rate)
        let toneBlocks = ProductionSelectionOutputTap.toneBlocks(returned.values, rate: returned.rate, frequency: 440)
        let validity = tap.validity()
        print("ProductionSelectionReturnedOutput seconds=\(returnedSeconds) wallSeconds=\(returnedWall) firstHostOffsetMs=\(((returned.hosts.first ?? .infinity) - (returnedOrigin ?? 0)) * 1_000) lastHostOffsetMs=\(((returned.hosts.last ?? -.infinity) - (returnedOrigin ?? .infinity)) * 1_000) frames=\(returned.values.count) rate=\(returned.rate) toneBlocks=\(toneBlocks.total) correctToneBlocks=\(toneBlocks.correct) quietMs=\(returnedQuiet * 1_000) maximumHoleMs=\(returnedHole * 1_000) invalidTimestamps=\(validity.invalidTimestamps) droppedFrames=\(validity.droppedFrames) retainedFrames=\(tap.count) capacityFrames=576000")
        XCTAssertGreaterThanOrEqual(returnedSeconds, 7.5); XCTAssertGreaterThanOrEqual(returnedWall, 7.5)
        XCTAssertTrue(returned.values.allSatisfy { $0.isFinite })
        XCTAssertGreaterThanOrEqual(toneBlocks.total, 375); XCTAssertEqual(toneBlocks.correct, toneBlocks.total)
        XCTAssertEqual(returnedQuiet, 0)
        XCTAssertLessThanOrEqual(returnedHole, 0.5 / max(1, returned.rate))
        XCTAssertEqual(validity.invalidTimestamps, 0); XCTAssertEqual(validity.droppedFrames, 0)
        XCTAssertLessThanOrEqual(tap.count, 12 * 48_000)
        XCTAssertLessThanOrEqual((returned.hosts.first ?? .infinity) - (returnedOrigin ?? 0), 0.25)
        XCTAssertGreaterThanOrEqual((returned.hosts.last ?? -.infinity) - (returnedOrigin ?? .infinity), 7.5)
        XCTAssertEqual(audio.renderer.snapshot.underrunFrames, 0,
                       "Startup starvation cannot disappear behind a clean streaming baseline")
        seeks.dumpAndAssert()
    }

    private func productionSelectionState(_ service: PlaybackService, fixture: SelectionVideoFixture,
        audio: ContinuousAudioPlayer, id: String) -> ProductionSelectionState {
        let asset = service.player.currentItem?.asset as? AVURLAsset
        let expected = audio.entry(for: id)
        return ProductionSelectionState(audio: audio.renderer.snapshot, expectedToken: expected?.token ?? 0,
            metadataMatches: service.queue.currentID == id && service.current?.id == id,
            assetMatches: asset?.url.standardizedFileURL == fixture.savedURLs[id]?.standardizedFileURL,
            sourceIDMatches: expected?.id == id && audio.selectedID == id,
            engineRunning: service.audioEngineRunning, wantsPlaying: service.wantsToPlay,
            preparedCount: service.preparedAudioCount, submitted: service.submittedVideoFrameCount,
            copied: service.copiedVideoFramePositionSeconds, frame: service.videoFramePositionSeconds,
            requested: service.videoRequestedPositionSeconds, videoReady: service.isVideoReady,
            loading: service.isLoading)
    }

    private func measureProductionSelection(_ service: PlaybackService, screen: SelectionVideoScreen,
        fixture: SelectionVideoFixture, audio: ContinuousAudioPlayer, tap: ProductionSelectionOutputTap,
        seeks: ProductionSelectionSeekRecorder, phase: Int, id: String, frequency: Double,
        prepared: Bool, preparedBefore: Bool, command: () -> Void) async -> ProductionSelectionMeasurement {
        let first = tap.begin()
        if prepared { try? await Task.sleep(for: .milliseconds(120)) }
        let before = audio.renderer.snapshot
        let expectedTokenBefore = audio.entry(for: id)?.token ?? 0
        let submitted = service.submittedVideoFrameCount
        seeks.phase = phase
        let origin = ProductionSelectionOutputTap.hostSeconds()
        command()
        var cursor = first
        var outgoing: ProductionSelectionOutputTap.Tone?
        var tone: ProductionSelectionOutputTap.Tone?
        var displayReady: Double?
        var ready: Double?
        let deadline = ProcessInfo.processInfo.systemUptime + (prepared ? 1 : 5)
        while ProcessInfo.processInfo.systemUptime < deadline {
            while tone == nil, let window = tap.window(at: cursor) {
                cursor += max(1, Int(window.rate * 0.01))
                if prepared, outgoing == nil, window.end <= origin,
                   ProductionSelectionOutputTap.isTone(window.samples, rate: window.rate, frequency: frequency == 440 ? 880 : 440) {
                    outgoing = .init(start: window.start, end: window.end)
                }
                if window.end >= origin,
                   ProductionSelectionOutputTap.isTone(window.samples, rate: window.rate, frequency: frequency) {
                    tone = .init(start: window.start, end: window.end)
                }
            }
            let state = productionSelectionState(service, fixture: fixture, audio: audio, id: id)
            if ready == nil, state.selected, state.audio.visit > before.visit,
               state.submitted > submitted, screen.customVideoLayer?.isReadyForDisplay == true,
               let frame = state.frame, let copied = state.copied,
               frame.isFinite, copied.isFinite, state.requested.isFinite, frame >= 0, copied >= 0,
               abs(frame - state.requested) <= 0.080, abs(copied - frame) <= 0.080 {
                if displayReady == nil { displayReady = ProductionSelectionOutputTap.hostSeconds() }
                if state.videoReady && !state.loading {
                    ready = ProductionSelectionOutputTap.hostSeconds()
                }
            }
            if tone != nil && ready != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let last = tap.stop()
        return ProductionSelectionMeasurement(phase: phase, prepared: prepared, preparedBefore: preparedBefore,
            frequency: frequency, first: first, last: last, origin: origin, outgoing: outgoing, tone: tone,
            displayReady: displayReady, ready: ready, before: before,
            expectedTokenBefore: expectedTokenBefore, beforeSubmitted: submitted,
            state: productionSelectionState(service, fixture: fixture, audio: audio, id: id))
    }

    private func assertProductionSelection(_ value: ProductionSelectionMeasurement, tap: ProductionSelectionOutputTap) {
        let recorded = tap.samples(from: value.first, to: value.last)
        let quiet = ProductionSelectionOutputTap.quietRun(recorded.values, rate: recorded.rate)
        let hole = ProductionSelectionOutputTap.maximumTimelineHole(recorded.hosts, rate: recorded.rate)
        let toneMs = value.tone.map { ($0.end - value.origin) * 1_000 }
        let readyMs = value.ready.map { ($0 - value.origin) * 1_000 }
        let state = value.state
        print("ProductionSelectionLatency phase=\(value.phase) prepared=\(value.prepared) preparedBefore=\(value.preparedBefore) frequency=\(value.frequency) commandHostSeconds=\(value.origin) toneStartMs=\(value.tone.map { String(($0.start - value.origin) * 1_000) } ?? "missing") toneEndMs=\(toneMs.map { String($0) } ?? "missing") customDisplayReadyMs=\(value.displayReady.map { String(($0 - value.origin) * 1_000) } ?? "missing") videoReadyMs=\(readyMs.map { String($0) } ?? "missing") metadataMatches=\(state.metadataMatches) assetMatches=\(state.assetMatches) sourceIDMatches=\(state.sourceIDMatches) expectedToken=\(state.expectedToken) token=\(state.audio.token) visit=\(state.audio.visit) beforeVisit=\(value.before.visit) frame=\(state.audio.frame) ended=\(state.audio.ended) copiedPTS=\(state.copied.map { String($0) } ?? "missing") submittedPTS=\(state.frame.map { String($0) } ?? "missing") requested=\(state.requested) submitted=\(state.submitted) beforeSubmitted=\(value.beforeSubmitted) engineRunning=\(state.engineRunning) wantsPlaying=\(state.wantsPlaying) quietMs=\(quiet * 1_000) maximumHoleMs=\(hole * 1_000) underrunDelta=\(state.audio.underrunFrames - value.before.underrunFrames) producerTracing=absent physicalOutput=unverified compositorPixels=unverified")
        XCTAssertTrue(value.preparedBefore)
        XCTAssertNotNil(value.tone, "The independently classified target must reach the actual mixer tap")
        XCTAssertNotNil(value.ready, "A fresh, selected and aligned actual custom submission must become ready")
        XCTAssertTrue(state.selected); XCTAssertTrue(state.videoReady); XCTAssertFalse(state.loading)
        XCTAssertGreaterThan(state.audio.visit, value.before.visit)
        XCTAssertGreaterThan(state.submitted, value.beforeSubmitted)
        if value.prepared {
            XCTAssertGreaterThan(value.expectedTokenBefore, 0)
            XCTAssertEqual(state.expectedToken, value.expectedTokenBefore)
            XCTAssertEqual(state.preparedCount, 2)
            XCTAssertNotNil(value.outgoing)
            if let outgoing = value.outgoing, let tone = value.tone { XCTAssertLessThanOrEqual(outgoing.end, tone.start) }
            XCTAssertLessThanOrEqual(toneMs ?? .infinity, 100)
            XCTAssertLessThanOrEqual(readyMs ?? .infinity, 250)
            XCTAssertEqual(state.audio.underrunFrames, value.before.underrunFrames)
            XCTAssertEqual(quiet, 0)
            XCTAssertTrue(recorded.values.allSatisfy { $0.isFinite })
            XCTAssertLessThanOrEqual(hole, 0.5 / max(1, recorded.rate))
        }
    }

    private func assertProductionStream(_ value: ProductionSelectionStream) {
        let result = value.result
        let samples = result.samples.filter { $0.end >= result.origin && $0.end - result.origin <= 8_000_000_000 }
        let elapsed = samples.map { Double($0.end - result.origin) / 1_000_000_000 }
        let gaps = zip(samples, samples.dropFirst()).map { before, after in Double(after.end - before.end) / 1_000_000_000 }
        let acquisition = samples.map { Double($0.end - $0.begin) / 1_000_000_000 }.max() ?? .infinity
        let wall = samples.first.flatMap { first in samples.last.map { Double($0.end - first.end) / 1_000_000_000 } } ?? -1
        let pcm = samples.first.flatMap { first in samples.last.map { Double($0.audio.frame - first.audio.frame) / 48_000 } } ?? -1
        let skew = zip(samples, samples.dropFirst()).map { before, after in
            abs(Double(after.audio.frame - before.audio.frame) / 48_000 - Double(after.end - before.end) / 1_000_000_000)
        }.max() ?? .infinity
        let tolerance = 2 * Double(max(1, value.quantum)) / 48_000 + 0.005
        print("ProductionSelectionStream phase=\(value.phase) seconds=8 samples=\(samples.count) rendererCoherentSamples=\(samples.count) firstMs=\((elapsed.first ?? .infinity) * 1_000) lastMs=\((elapsed.last ?? -1) * 1_000) maximumGapMs=\((gaps.max() ?? .infinity) * 1_000) maximumAcquisitionMs=\(acquisition * 1_000) wallSeconds=\(wall) pcmSeconds=\(pcm) maximumSkewMs=\(skew * 1_000) toleranceMs=\(tolerance * 1_000) quantum=\(value.quantum) dropped=\(result.dropped) acquisitionOutstanding=\(result.acquisitionOutstanding) baselineToken=\(value.baseline.token) finalToken=\(value.final.token) baselineVisit=\(value.baseline.visit) finalVisit=\(value.final.visit) baselineFrame=\(value.baseline.frame) finalFrame=\(value.final.frame) baselineUnderruns=\(value.baseline.underrunFrames) finalUnderruns=\(value.final.underrunFrames) retainedPCMBytes=\(value.memoryBytes) sameStorage=\(value.sameStorage) producerTracing=absent")
        for sample in samples {
            print("ProductionSelectionRenderSample phase=\(value.phase) originNs=\(result.origin) beginNs=\(sample.begin) endNs=\(sample.end) elapsedMs=\(Double(sample.end - result.origin) / 1_000_000) acquisitionMs=\(Double(sample.end - sample.begin) / 1_000_000) rendererCoherent=true token=\(sample.audio.token) visit=\(sample.audio.visit) frame=\(sample.audio.frame) ended=\(sample.audio.ended) underrunFrames=\(sample.audio.underrunFrames)")
        }
        XCTAssertGreaterThanOrEqual(samples.count, 40); XCTAssertLessThanOrEqual(samples.count, 128)
        XCTAssertGreaterThanOrEqual(samples.count, 20, "Every returned renderer snapshot is coherent; no producer-coherence claim is made")
        XCTAssertLessThanOrEqual(elapsed.first ?? .infinity, 0.25)
        XCTAssertGreaterThanOrEqual(elapsed.last ?? -1, 7.5)
        XCTAssertLessThanOrEqual(gaps.max() ?? .infinity, 0.25)
        XCTAssertLessThanOrEqual(acquisition, 0.005)
        XCTAssertEqual(result.dropped, 0); XCTAssertFalse(result.acquisitionOutstanding)
        XCTAssertTrue(value.before.selected && value.after.selected)
        XCTAssertEqual(value.before.expectedToken, value.after.expectedToken)
        XCTAssertEqual(value.baseline.token, value.before.expectedToken)
        XCTAssertEqual(value.final.token, value.baseline.token); XCTAssertEqual(value.final.visit, value.baseline.visit)
        XCTAssertFalse(value.baseline.ended); XCTAssertFalse(value.final.ended)
        XCTAssertEqual(value.final.underrunFrames, value.baseline.underrunFrames)
        XCTAssertTrue(samples.allSatisfy { $0.audio.token == value.baseline.token && $0.audio.visit == value.baseline.visit
            && !$0.audio.ended && $0.audio.underrunFrames == value.baseline.underrunFrames })
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { before, after in after.audio.frame >= before.audio.frame })
        XCTAssertGreaterThan(pcm, 0); XCTAssertEqual(pcm, wall, accuracy: tolerance)
        XCTAssertLessThanOrEqual(skew, tolerance)
        XCTAssertEqual(value.memoryBytes, 6_912_000); XCTAssertTrue(value.sameStorage)
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
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
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

    func testNaturalBoundaryAtPositiveIncomingOffsetRevealsB() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
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
            // Keep this an assertion failure, with the original numeric evidence,
            // instead of throwing a setup error through deferred fixture cleanup.
            XCTFail("The real renderer must reach the seek runway or naturally enter B")
            return
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
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "natural-B-positive-offset")
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

private struct ProductionSelectionState {
    let audio: ContinuousPCMRenderer.Snapshot
    let expectedToken: Int
    let metadataMatches: Bool
    let assetMatches: Bool
    let sourceIDMatches: Bool
    let engineRunning: Bool
    let wantsPlaying: Bool
    let preparedCount: Int
    let submitted: UInt64
    let copied: Double?
    let frame: Double?
    let requested: Double
    let videoReady: Bool
    let loading: Bool
    var selected: Bool {
        expectedToken > 0 && audio.token == expectedToken && !audio.ended && metadataMatches
            && assetMatches && sourceIDMatches && engineRunning && wantsPlaying
    }
}

private struct ProductionSelectionMeasurement {
    let phase: Int
    let prepared: Bool
    let preparedBefore: Bool
    let frequency: Double
    let first: Int
    let last: Int
    let origin: Double
    let outgoing: ProductionSelectionOutputTap.Tone?
    let tone: ProductionSelectionOutputTap.Tone?
    let displayReady: Double?
    let ready: Double?
    let before: ContinuousPCMRenderer.Snapshot
    let expectedTokenBefore: Int
    let beforeSubmitted: UInt64
    let state: ProductionSelectionState
}

private struct ProductionSelectionStream {
    let phase: Int
    let baseline: ContinuousPCMRenderer.Snapshot
    let final: ContinuousPCMRenderer.Snapshot
    let before: ProductionSelectionState
    let after: ProductionSelectionState
    let quantum: Int
    let result: ProductionRendererProbe.Result
    let memoryBytes: Int
    let sameStorage: Bool
}

/// Independent serial observer of the unchanged renderer API. A read occurs outside the
/// result lock: stop never waits for a seqlock acquisition, and an outstanding read fails coverage.
private final class ProductionRendererProbe: @unchecked Sendable {
    struct Sample: Sendable {
        let begin: UInt64
        let end: UInt64
        let audio: ContinuousPCMRenderer.Snapshot
    }
    struct Result: Sendable {
        let origin: UInt64
        let samples: [Sample]
        let dropped: Int
        let acquisitionOutstanding: Bool
    }
    private let renderer: ContinuousPCMRenderer
    private let origin = DispatchTime.now().uptimeNanoseconds
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var samples: [Sample] = []
    private var stopped = false
    private var acquiring = false
    private var dropped = 0

    init(renderer: ContinuousPCMRenderer) {
        self.renderer = renderer
        samples.reserveCapacity(128)
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test.production-render-sampler", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    private func sample() {
        let begin = DispatchTime.now().uptimeNanoseconds
        guard begin >= origin, begin - origin < 8_000_000_000 else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        acquiring = true
        lock.unlock()
        let audio = renderer.snapshot
        let end = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        acquiring = false
        if !stopped {
            if samples.count < 128 { samples.append(Sample(begin: begin, end: end, audio: audio)) }
            else { dropped += 1 }
        }
        lock.unlock()
    }

    func stop() -> Result {
        timer.cancel()
        lock.lock(); defer { lock.unlock() }
        stopped = true
        return Result(origin: origin, samples: samples, dropped: dropped, acquisitionOutstanding: acquiring)
    }
}

/// Fixed 12-second storage for actual mixer PCM and its AVAudioTime host timeline.
/// The tap is disabled during the first two 8-second renderer-only windows.
private final class ProductionSelectionOutputTap: @unchecked Sendable {
    struct Tone { let start: Double; let end: Double }
    struct Window { let samples: [Float]; let rate: Double; let start: Double; let end: Double }
    struct Recording { let values: [Float]; let hosts: [Double]; let rate: Double }
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
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    @discardableResult
    func begin() -> Int { lock.lock(); defer { lock.unlock() }; enabled = true; return values.count }
    @discardableResult
    func stop() -> Int { lock.lock(); defer { lock.unlock() }; enabled = false; return values.count }

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
            let right = channelCount > 1
                ? (buffer.format.isInterleaved ? channels[0][frame * channelCount + 1] : channels[1][frame]) : left
            values.append((left + right) * 0.5)
            hosts.append(start + Double(frame) / actualRate)
        }
    }

    func window(at index: Int) -> Window? {
        lock.lock(); defer { lock.unlock() }
        let frames = Int(rate * 0.02)
        guard frames > 0, index >= 0, index + frames <= values.count else { return nil }
        return Window(samples: Array(values[index..<(index + frames)]), rate: rate,
                      start: hosts[index], end: hosts[index + frames - 1] + 1 / rate)
    }

    func samples(from first: Int, to last: Int) -> Recording {
        lock.lock(); defer { lock.unlock() }
        let lower = min(max(0, first), values.count), upper = min(max(first, last), values.count)
        return Recording(values: Array(values[lower..<upper]), hosts: Array(hosts[lower..<upper]), rate: rate)
    }

    func validity() -> (invalidTimestamps: Int, droppedFrames: Int) {
        lock.lock(); defer { lock.unlock() }; return (invalidTimestamps, droppedFrames)
    }

    static func isTone(_ samples: [Float], rate: Double, frequency: Double) -> Bool {
        guard !samples.isEmpty, rate.isFinite, rate > 0, samples.allSatisfy({ $0.isFinite }) else { return false }
        func power(_ hz: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for (index, value) in samples.enumerated() {
                let phase = 2 * Double.pi * hz * Double(index) / rate
                real += Double(value) * cos(phase); imaginary += Double(value) * sin(phase)
            }
            return (real * real + imaginary * imaginary) / pow(Double(samples.count), 2)
        }
        let expected = power(frequency)
        return expected > 0.001 && expected > 10 * max(power(frequency == 440 ? 880 : 440), 1e-12)
    }

    static func toneBlocks(_ samples: [Float], rate: Double, frequency: Double) -> (correct: Int, total: Int) {
        let frames = Int(rate * 0.02)
        guard frames > 0, samples.count >= frames else { return (0, 0) }
        var correct = 0, total = 0
        for start in stride(from: 0, through: samples.count - frames, by: frames) {
            total += 1
            if isTone(Array(samples[start..<(start + frames)]), rate: rate, frequency: frequency) { correct += 1 }
        }
        return (correct, total)
    }

    static func quietRun(_ samples: [Float], rate: Double) -> Double {
        let frames = Int(rate * 0.01)
        guard frames > 0, samples.count >= frames else { return 0 }
        var longest = 0, run = 0
        for start in stride(from: 0, through: samples.count - frames, by: frames) {
            var square = 0.0
            for value in samples[start..<(start + frames)] { square += Double(value) * Double(value) }
            if sqrt(square / Double(frames)) < 0.01 { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        return Double(longest * frames) / rate
    }

    static func maximumTimelineHole(_ hosts: [Double], rate: Double) -> Double {
        guard rate > 0, hosts.count > 1 else { return 0 }
        var maximum = 0.0
        for index in 1..<hosts.count {
            let interval = hosts[index] - hosts[index - 1]
            guard interval.isFinite, interval > 0 else { return .infinity }
            maximum = max(maximum, interval - 1 / rate)
        }
        return maximum
    }
}

/// Only seek forwarding timestamps/targets; no native player state getter or event hook.
private final class ProductionSelectionSeekRecorder: @unchecked Sendable {
    struct Event {
        let phase: Int
        let target: Double
        let entered: Double
        var completed: Double?
        var finished: Bool?
    }
    private let lock = NSLock()
    private var currentPhase = -1
    private var events: [Event] = []
    private var dropped = 0
    init() { events.reserveCapacity(32) }
    var phase: Int {
        get { lock.lock(); defer { lock.unlock() }; return currentPhase }
        set { lock.lock(); currentPhase = newValue; lock.unlock() }
    }

    @MainActor
    func seek(_ player: AVPlayer, _ time: CMTime, _ completion: @escaping @Sendable (Bool) -> Void) {
        let entered = ProductionSelectionOutputTap.hostSeconds()
        lock.lock()
        let index: Int?
        if events.count < 32 {
            index = events.count
            events.append(Event(phase: currentPhase, target: time.seconds, entered: entered))
        } else { dropped += 1; index = nil }
        lock.unlock()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [self] finished in
            let completed = ProductionSelectionOutputTap.hostSeconds()
            completion(finished)
            // Forward the real completion before recorder mutation or logging.
            lock.lock(); defer { lock.unlock() }
            if let index {
                if events[index].completed == nil {
                    events[index].completed = completed; events[index].finished = finished
                } else { dropped += 1 }
            }
        }
    }

    func dumpAndAssert() {
        lock.lock(); let result = events, lost = dropped; lock.unlock()
        print("ProductionSelectionSeekSummary events=\(result.count) capacity=32 dropped=\(lost) nativePositionGetters=0 producerTracing=absent")
        XCTAssertLessThanOrEqual(result.count, 32); XCTAssertEqual(lost, 0)
        for (index, event) in result.enumerated() {
            print("ProductionSelectionSeek ordinal=\(index) phase=\(event.phase) target=\(event.target) enteredHostSeconds=\(event.entered) completedHostSeconds=\(event.completed.map { String($0) } ?? "missing") finished=\(event.finished.map { String($0) } ?? "missing")")
            XCTAssertTrue((0...2).contains(event.phase)); XCTAssertTrue(event.target.isFinite)
            XCTAssertTrue(event.entered.isFinite)
            if let completed = event.completed { XCTAssertGreaterThanOrEqual(completed, event.entered) }
        }
    }
}

private final class ProductionSelectionShutdown: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    var result: Bool? { lock.lock(); defer { lock.unlock() }; return value }
    func complete(_ result: Bool) { lock.lock(); value = result; lock.unlock() }
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
        downloads = OfflineDownloads(cloud: cloud, network: NetworkStatus())
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
                                     bookmarkURL: bookmark, activateSession: {}, buffer: buffer,
                                     continuousAudio: continuousAudio, seekVideo: seekVideo)
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
    func decodedTone(id: String) async throws -> [Float] {
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
        reader.timeRange = CMTimeRange(start: CMTime(value: 24_000, timescale: 48_000),
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

@MainActor
private final class SelectionVideoScreen {
    let window: UIWindow
    let service: PlaybackService
    private weak var previousKeyWindow: UIWindow?
    var customVideoLayer: AVSampleBufferDisplayLayer? {
        service.surface.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.last
    }

    init(service: PlaybackService) throws {
        self.service = service
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
    }

    func capture(label: String, test: XCTestCase) async throws -> SelectionVideoPixels {
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
        print("SelectionCapture label=\(label) phase=\(phase) uptime=\(uptime) elapsed=\(uptime - started) failed=\(failed) playerPosition=\(service.player.currentTime().seconds) playerRate=\(service.player.rate) audioFrame=\(audio.frame) audioVisit=\(audio.visit) audioToken=\(audio.token) audioUnderrunFrames=\(audio.underrunFrames) engineRunning=\(service.audioEngineRunning) wantsToPlay=\(service.wantsToPlay) requested=\(service.videoRequestedPositionSeconds) timebase=\(service.videoTimebasePositionSeconds.map { String($0) } ?? "missing") copiedPTS=\(service.copiedVideoFramePositionSeconds.map { String($0) } ?? "missing") submittedPTS=\(service.videoFramePositionSeconds.map { String($0) } ?? "missing") submitted=\(service.submittedVideoFrameCount) futureRejected=\(service.pausedFutureVideoFrameRejectionCount) customReady=\(customVideoLayer?.isReadyForDisplay == true)")
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
