import XCTest
import SwiftUI
import UIKit
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import PlayerCore
@testable import OfflineTikTokPlayer

/// Service/render integration regressions. The opaque magenta poster deliberately differs from
/// both generated movies, so a decoded asset or advancing audio clock cannot satisfy visibility.
@MainActor
final class PlaybackSelectionVideoRegressionTests: XCTestCase {
    // Stop targeted arms from creating more owners after an unacknowledged close.
    private static var targetedFixtureOwnershipLost = false
    // One test-module nonce per app process, not an operating-system birth timestamp.
    private static let runtimeHostModuleNonce = UUID().uuidString.lowercased()

    private func recordRuntimeHost() throws {
        let process = ProcessInfo.processInfo
        let receipt: [String: Any] = ["schema": 1,
            "simulatorUDID": process.environment["SIMULATOR_UDID"] ?? "unknown",
            "pid": Int(process.processIdentifier),
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "moduleNonce": Self.runtimeHostModuleNonce, "testName": self.name]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print("NativeRuntimeHost " + String(decoding: data, as: UTF8.self))
    }
    /// Real mixer output and actual custom-layer submission, without screenshot or SDK-position probes.
    /// This is selected-frame readiness evidence, not compositor pixels or physical speaker output.
    func testProductionSelectionLatencyAndStreamingContinuityWithoutCapture() async throws {
        try await runProductionSelectionBenchmark(traceVideoSeeks: true)
    }

    func testDefaultProductionSelectionLatencyAndStreamingContinuityWithoutCapture() async throws {
        try await runProductionSelectionBenchmark(traceVideoSeeks: false)
    }

    func testDefaultProductionRenderAccountingBaseline() async throws {
        try await runProductionSelectionBenchmark(traceVideoSeeks: false, renderAccounting: false)
    }

    func testDefaultProductionRenderAccountingEnabled() async throws {
        #if DEBUG
        try await runProductionSelectionBenchmark(traceVideoSeeks: false, renderAccounting: true)
        #else
        XCTFail("Render accounting diagnostic requires DEBUG")
        #endif
    }

    func testFrameReadinessMonitorBenchmarkDefaultThenCurrentCustomFrame() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, alternative) in [false, true].enumerated() {
            print("FrameMonitorBenchmarkArm schema=1 order=default-then-custom ordinal=\(ordinal) alternative=\(alternative) serviceTracing=true nativeRefillTrace=false playbackAcceptance=unchanged physicalPixels=unmeasured")
            try await runProductionSelectionBenchmark(traceVideoSeeks: true, frameMonitorAlternative: alternative,
                                                       recordHost: false)
        }
        #else
        XCTFail("Frame-monitor diagnostic requires DEBUG controls")
        #endif
    }

    func testFrameReadinessMonitorBenchmarkCurrentCustomFrameThenDefault() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, alternative) in [true, false].enumerated() {
            print("FrameMonitorBenchmarkArm schema=1 order=custom-then-default ordinal=\(ordinal) alternative=\(alternative) serviceTracing=true nativeRefillTrace=false playbackAcceptance=unchanged physicalPixels=unmeasured")
            try await runProductionSelectionBenchmark(traceVideoSeeks: true, frameMonitorAlternative: alternative,
                                                       recordHost: false)
        }
        #else
        XCTFail("Frame-monitor diagnostic requires DEBUG controls")
        #endif
    }

    func testNativeRefillTraceCurrentCustomFrameThenDefault() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, alternative) in [true, false].enumerated() {
            print("FrameMonitorBenchmarkArm schema=1 order=custom-then-default ordinal=\(ordinal) alternative=\(alternative) serviceTracing=true nativeRefillTrace=true playbackAcceptance=unchanged physicalPixels=unmeasured")
            try await runProductionSelectionBenchmark(traceVideoSeeks: true, frameMonitorAlternative: alternative,
                                                       recordHost: false, traceNativeRefill: true)
        }
        #else
        XCTFail("Native-refill diagnostic requires DEBUG controls")
        #endif
    }

    func testNativeRefillTraceDefaultThenCurrentCustomFrame() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for (ordinal, alternative) in [false, true].enumerated() {
            print("FrameMonitorBenchmarkArm schema=1 order=default-then-custom ordinal=\(ordinal) alternative=\(alternative) serviceTracing=true nativeRefillTrace=true playbackAcceptance=unchanged physicalPixels=unmeasured")
            try await runProductionSelectionBenchmark(traceVideoSeeks: true, frameMonitorAlternative: alternative,
                                                       recordHost: false, traceNativeRefill: true)
        }
        #else
        XCTFail("Native-refill diagnostic requires DEBUG controls")
        #endif
    }

    /// Capability only: copying B consumes its output. This arm never measures Next.
    func testPreparedNextVideoFirstFrameCapabilityBeforeSelection() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            let tap = ProductionSelectionOutputTap()
            let seeks = ProductionSelectionSeekRecorder()
            let startup = ProductionVideoStartupTrace(serviceTracing: false)
            let originalSources = (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }
            let originalBytes = audio.renderer.retainedPCMMemoryBytes
            audio.graph.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil) { value, time in
                tap.append(value, time: time)
            }
            defer {
                tap.stop()
                audio.graph.engine.mainMixerNode.removeTap(onBus: 0)
            }

            // Match the untouched benchmark's cold A measurement and eight-second stream.
            let cold = await self.measureProductionSelection(service, screen: screen, fixture: fixture,
                audio: audio, tap: tap, seeks: seeks, startup: startup, phase: 0, id: fixture.aID,
                frequency: 440, prepared: false, preparedBefore: true) {
                    service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
                }
            let baseline = audio.renderer.snapshot
            let streamBefore = self.productionSelectionState(service, fixture: fixture, audio: audio, id: fixture.aID)
            let probe = ProductionRendererProbe(renderer: audio.renderer)
            try? await Task.sleep(for: .seconds(8))
            let streamResult = probe.stop()
            let streamFinal = audio.renderer.snapshot
            let streamAfter = self.productionSelectionState(service, fixture: fixture, audio: audio, id: fixture.aID)
            let stream = ProductionSelectionStream(phase: 0, baseline: baseline, final: streamFinal,
                before: streamBefore, after: streamAfter, quantum: service.audioRenderQuantumFrames,
                result: streamResult, memoryBytes: audio.renderer.retainedPCMMemoryBytes,
                sameStorage: originalSources == (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) })
            // Keep assertions and logs outside the capability acquisition bracket.
            defer {
                self.assertProductionSelection(cold, tap: tap)
                self.assertProductionStream(stream)
                XCTAssertEqual(originalBytes, 6_912_000)
                XCTAssertEqual(audio.renderer.retainedPCMMemoryBytes, originalBytes)
                XCTAssertEqual(originalSources, (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) })
                seeks.assertUnused()
            }

            // This is exactly the existing phase-1 PCM gate and 120 ms lead.
            // Never wait for video staging, readyToPlay, or an output to become available.
            let preparedBefore = await self.waitUntil(timeout: 5) {
                service.preparedAudioCount == 2 && audio.entry(for: fixture.bID) != nil
            }
            _ = tap.begin()
            try await Task.sleep(for: .milliseconds(120))
            let checkpoint = DispatchTime.now().uptimeNanoseconds
            let checkpointAudio = audio.renderer.snapshot
            let queued = buffer.player.items()
            let currentA = queued.first
            let queuedB = queued.dropFirst().first
            let resource = queuedB.flatMap { buffer.resource(for: $0) }
            let output = resource?.output
            let aURLMatches = (currentA?.asset as? AVURLAsset)?.url.standardizedFileURL
                == fixture.savedURLs[fixture.aID]?.standardizedFileURL
            let bURLMatches = (queuedB?.asset as? AVURLAsset)?.url.standardizedFileURL
                == fixture.savedURLs[fixture.bID]?.standardizedFileURL
            let outputsAtCheckpoint = queuedB?.outputs.count ?? -1
            let retainedAtCheckpoint = buffer.retainedItemCount
            let stagedAtCheckpoint = buffer.hasPrepared(fixture.bID)
            let currentToken = audio.entry(for: fixture.aID)?.token ?? 0
            let nextToken = audio.entry(for: fixture.bID)?.token ?? 0

            guard preparedBefore, queued.count == 2, let currentA, let queuedB, let resource, let output,
                  aURLMatches, bURLMatches, stagedAtCheckpoint, outputsAtCheckpoint == 1,
                  resource.item === queuedB, resource.isAttached, !resource.isRetired, !resource.isBorrowed,
                  queuedB.outputs.contains(where: { $0 === output }),
                  service.player.currentItem === currentA, service.queue.currentID == fixture.aID,
                  audio.selectedID == fixture.aID, currentToken > 0, nextToken > 0,
                  checkpointAudio.token == currentToken, !checkpointAudio.ended,
                  retainedAtCheckpoint <= 3 else {
                print("PreparedNextFrameCapability schema=1 checkpointNs=\(checkpoint) pcmPrepared=\(preparedBefore) queueCount=\(queued.count) aURLMatches=\(aURLMatches) bURLMatches=\(bURLMatches) staged=\(stagedAtCheckpoint) outputPresent=\(output != nil) outputs=\(outputsAtCheckpoint) retainedItems=\(retainedAtCheckpoint) queryCount=0 copyCount=0 setupValid=false availability=unmeasured latencyEvidence=false compositorPixels=unmeasured")
                XCTFail("The exact pre-Next checkpoint did not contain the required A/B owners; no extra preparation wait is allowed")
                return
            }
            let initialBStatus = queuedB.status.rawValue
            @MainActor func ownsPreparedB() -> Bool {
                let items = buffer.player.items()
                return service.queue.currentID == fixture.aID && audio.selectedID == fixture.aID
                    && service.player.currentItem === currentA && items.count == 2
                    && items.first === currentA && items.dropFirst().first === queuedB
                    && buffer.nextMediaID == fixture.bID && buffer.resource(for: queuedB) === resource
                    && resource.item === queuedB && resource.output === output
                    && resource.isAttached && !resource.isRetired && !resource.isBorrowed
                    && queuedB.outputs.count == 1 && queuedB.outputs.contains(where: { $0 === output })
            }

            let queryEntry = DispatchTime.now().uptimeNanoseconds
            let reportedAvailable = output.hasNewPixelBuffer(forItemTime: .zero)
            let queryReturn = DispatchTime.now().uptimeNanoseconds
            guard ownsPreparedB() else {
                print("PreparedNextFrameCapability schema=1 checkpointNs=\(checkpoint) queryEntryNs=\(queryEntry) queryReturnNs=\(queryReturn) queryCount=1 copyCount=0 setupValid=true ownerStable=false availability=unverified latencyEvidence=false compositorPixels=unmeasured")
                XCTFail("Prepared B ownership changed during the opaque availability query; no copy is authorized")
                return
            }
            var returnedPTS = CMTime.invalid
            let copyEntry = DispatchTime.now().uptimeNanoseconds
            var pixel = output.copyPixelBuffer(forItemTime: .zero, itemTimeForDisplay: &returnedPTS)
            let copyReturn = DispatchTime.now().uptimeNanoseconds
            let ownerStable = ownsPreparedB()
            let afterAudio = audio.renderer.snapshot
            let returnedBuffer = pixel != nil
            let numericPTS = returnedPTS.isNumeric
            let zeroPTS = numericPTS && CMTimeCompare(returnedPTS, .zero) == 0
            var width = 0, height = 0, rowBytes = 0
            var pixelFormat: OSType = 0
            var lockStatus: CVReturn = kCVReturnError
            var greenFraction: Double?, redFraction: Double?, magentaFraction: Double?
            var blueX: Double?, blueY: Double?
            if let image = pixel {
                width = CVPixelBufferGetWidth(image); height = CVPixelBufferGetHeight(image)
                rowBytes = CVPixelBufferGetBytesPerRow(image)
                pixelFormat = CVPixelBufferGetPixelFormatType(image)
                // Fixed public fixture only. No copied image, decoded history, or retained frame queue.
                if width == 160, height == 96, rowBytes >= width * 4, rowBytes <= 4096,
                   pixelFormat == kCVPixelFormatType_32BGRA {
                    lockStatus = CVPixelBufferLockBaseAddress(image, .readOnly)
                    if lockStatus == kCVReturnSuccess {
                        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
                        if let base = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) {
                            var green = 0, red = 0, magenta = 0, blue = 0
                            var sumX = 0.0, sumY = 0.0
                            for y in 0..<height {
                                for x in 0..<width {
                                    let offset = y * rowBytes + x * 4
                                    let b = base[offset], g = base[offset + 1], r = base[offset + 2]
                                    if g > 150 && r < 100 && b < 100 { green += 1 }
                                    if r > 150 && g < 100 && b < 100 { red += 1 }
                                    if r > 150 && g < 100 && b > 150 { magenta += 1 }
                                    if b > 150 && r < 100 && g < 100 {
                                        blue += 1; sumX += Double(x); sumY += Double(y)
                                    }
                                }
                            }
                            let count = Double(width * height)
                            greenFraction = Double(green) / count
                            redFraction = Double(red) / count
                            magentaFraction = Double(magenta) / count
                            if blue >= 4 { blueX = sumX / Double(blue); blueY = sumY / Double(blue) }
                        }
                    }
                }
            }
            pixel = nil // Release the sole copied buffer before teardown or any later action.
            let validPixels = (greenFraction ?? 0) > 0.65 && (redFraction ?? 1) < 0.02
                && (magentaFraction ?? 1) < 0.02
                && blueX.map { abs($0 - 7.5) <= 2 } == true
                && blueY.map { abs($0 - 11.5) <= 2 } == true
            let audioOwnerStable = afterAudio.token == currentToken && afterAudio.token == checkpointAudio.token
                && afterAudio.visit == checkpointAudio.visit
                && afterAudio.selectionVersion == checkpointAudio.selectionVersion && !afterAudio.ended
            let preexistingFrameProven = reportedAvailable && returnedBuffer && numericPTS && zeroPTS
                && validPixels && ownerStable && audioOwnerStable
            let classification = preexistingFrameProven ? "available-before-copy"
                : returnedBuffer ? "copy-returned-without-preexisting-proof" : "no-buffer-returned"
            print("PreparedNextFrameCapability schema=1 checkpointNs=\(checkpoint) queryEntryNs=\(queryEntry) queryReturnNs=\(queryReturn) copyEntryNs=\(copyEntry) copyReturnNs=\(copyReturn) queryCount=1 copyCount=1 setupValid=true initialBStatus=\(initialBStatus) ownerStable=\(ownerStable) audioOwnerStable=\(audioOwnerStable) reportedAvailable=\(reportedAvailable) returnedBuffer=\(returnedBuffer) numericPTS=\(numericPTS) zeroPTS=\(zeroPTS) ptsSeconds=\(numericPTS ? String(returnedPTS.seconds) : "invalid") width=\(width) height=\(height) rowBytes=\(rowBytes) pixelFormat=\(pixelFormat) lockStatus=\(lockStatus) greenFraction=\(greenFraction.map { String($0) } ?? "unavailable") redFraction=\(redFraction.map { String($0) } ?? "unavailable") magentaFraction=\(magentaFraction.map { String($0) } ?? "unavailable") blueX=\(blueX.map { String($0) } ?? "unavailable") blueY=\(blueY.map { String($0) } ?? "unavailable") retainedItems=\(buffer.retainedItemCount) availability=\(classification) preexistingFrameProven=\(preexistingFrameProven) decoderAbsenceProven=false latencyEvidence=false compositorPixels=unmeasured")
            XCTAssertTrue(ownerStable); XCTAssertTrue(audioOwnerStable)
            XCTAssertEqual(afterAudio.token, checkpointAudio.token)
            XCTAssertEqual(afterAudio.visit, checkpointAudio.visit)
            XCTAssertEqual(afterAudio.selectionVersion, checkpointAudio.selectionVersion)
            XCTAssertGreaterThanOrEqual(afterAudio.frame, checkpointAudio.frame)
            XCTAssertEqual(afterAudio.underrunFrames, checkpointAudio.underrunFrames)
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)
            XCTAssertEqual(queuedB.outputs.count, 1)
            XCTAssertFalse(reportedAvailable && !returnedBuffer,
                           "An available-buffer report without an actual copy cannot prove capability")
            if returnedBuffer {
                XCTAssertTrue(numericPTS && zeroPTS, "A copied nonzero/invalid PTS cannot prove the initial frame")
                XCTAssertEqual(width, 160); XCTAssertEqual(height, 96)
                XCTAssertEqual(pixelFormat, kCVPixelFormatType_32BGRA)
                XCTAssertEqual(lockStatus, kCVReturnSuccess)
                XCTAssertTrue(validPixels, "The actual copied pixels must be B's initial green frame and blue marker")
            }
            // Nil with a false query is a retained observation, never a decoder-absence assertion.
            // No Next is issued: the existing untouched latency/pixel suite remains authoritative.
        }
        #else
        XCTFail("Prepared-frame capability diagnostic requires DEBUG")
        #endif
    }

    func testFrameReadinessMonitorUsesOnePreparedOutputWhileReadyIsWithheld() async throws {
        try recordRuntimeHost()
        #if DEBUG
        for alternative in [false, true] {
            let buffer = PlaybackBuffer()
            try await withOwnedNaturalFixture(buffer: buffer, recordHost: false) { fixture, audio, service, screen in
                service.isInteractingWithFeed = true
                service.debugUsesCurrentCustomFrameForReadiness = alternative
                service.debugInitialLoadPhaseEnabled = true
                var starts = 0, overflow = false
                defer {
                    service.debugAfterFirstFrameMonitorStart = nil; service.onDebugInitialVideoReady = nil
                    service.debugInitialLoadPhaseEnabled = false
                }
                for phase in 0..<3 {
                    if phase > 0 {
                        try await require({ service.preparedAudioCount == 2
                            && (phase == 1 ? buffer.hasPrepared(fixture.bID)
                                : buffer.previousMediaID == fixture.aID && buffer.debugPreviousNeedsRewind == false) },
                            "Both actual audio and the selected prepared video must exist before the control action")
                    }
                    let expectedID = phase == 1 ? fixture.bID : fixture.aID
                    let previousGeneration = service.debugInitialVideoReadyState.generation
                    let requestedGeneration = previousGeneration + 1 // Diagnostic expectation, not the owner.
                    let beforeStarts = starts
                    var gate: SelectionInitialReadyOrderingProbe?
                    var ownerConflict = false
                    var ownerCaptures = 0, sameOwnerRestarts = 0
                    var rejectedStarts = 0, readyDeliveries = 0, staleReadyDeliveries = 0
                    var observedCount = -1, observedPreparedIdentity = false
                    var observedItem: ObjectIdentifier?, observedResource: ObjectIdentifier?, observedOutput: ObjectIdentifier?
                    service.debugAfterFirstFrameMonitorStart = { [weak service] item in
                        guard let service else { return }
                        guard starts < 8 else { overflow = true; return }
                        starts += 1
                        let outputs = item.outputs
                        let resource = buffer.resource(for: item)
                        let state = service.debugInitialVideoReadyState
                        guard state.generation > previousGeneration,
                              service.queue.currentID == expectedID, audio.selectedID == expectedID,
                              let resource, resource.item === item, let output = resource.output,
                              resource.isAttached, resource.isBorrowed, !resource.isRetired,
                              outputs.contains(where: { $0 === output }) else {
                            rejectedStarts += 1; return
                        }
                        // The hook runs after this exact monitor starts and before
                        // its KVO is registered. Cold retries may have a later generation.
                        if let gate {
                            if state.generation == gate.generation,
                               observedItem == ObjectIdentifier(item),
                               observedResource == ObjectIdentifier(resource),
                               observedOutput == ObjectIdentifier(output) { sameOwnerRestarts += 1 }
                            else { ownerConflict = true }
                            return // Never rearm or rehold a captured owner.
                        }
                        observedCount = outputs.count; observedPreparedIdentity = true
                        observedItem = ObjectIdentifier(item); observedResource = ObjectIdentifier(resource)
                        observedOutput = ObjectIdentifier(output)
                        gate = SelectionInitialReadyOrderingProbe(generation: state.generation)
                        ownerCaptures += 1
                    }
                    service.onDebugInitialVideoReady = { [weak service] request in
                        guard readyDeliveries < 8 else { overflow = true; return }
                        readyDeliveries += 1
                        guard let service, let gate, request == gate.generation,
                              service.debugInitialVideoReadyState.generation == gate.generation,
                              service.queue.currentID == expectedID, audio.selectedID == expectedID else {
                            staleReadyDeliveries += 1; return
                        }
                        await gate.hold(request: request)
                    }
                    defer { gate?.release() }
                    switch phase {
                    case 0: service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
                    case 1: service.next()
                    default: service.previous()
                    }
                    let held = await waitUntil(timeout: 3) {
                        guard let gate else { return false }
                        return gate.isHolding && ownerCaptures == 1 && rejectedStarts == 0 && !ownerConflict
                            && starts == beforeStarts + 1 + sameOwnerRestarts
                            && service.debugInitialVideoReadyState.generation == gate.generation
                            && service.queue.currentID == expectedID && audio.selectedID == expectedID
                    }
                    if !held {
                        let state = service.debugInitialVideoReadyState, load = service.debugInitialLoadPhaseState
                        print("FrameMonitorHeldGateFailure schema=1 alternative=\(alternative) phase=\(phase) requestedGeneration=\(requestedGeneration) ownerGeneration=\(gate.map { String($0.generation) } ?? "unknown") currentGeneration=\(state.generation) readyGeneration=\(state.readyGeneration.map { String($0) } ?? "unknown") beforeStarts=\(beforeStarts) starts=\(starts) ownerCaptures=\(ownerCaptures) sameOwnerRestarts=\(sameOwnerRestarts) rejectedStarts=\(rejectedStarts) ownerConflict=\(ownerConflict) readyDeliveries=\(readyDeliveries) staleReadyDeliveries=\(staleReadyDeliveries) gateEntered=\(gate?.entered ?? 0) gateActive=\(gate?.active ?? 0) gateTimedOut=\(gate?.timedOut ?? false) gateCancelled=\(gate?.cancelled ?? false) gateOverflow=\(gate?.overflow ?? false) gateDropped=\(gate?.dropped ?? 0) overflow=\(overflow) loadEnabled=\(load.enabled) loadRequest=\(load.request) loadGeneration=\(load.generation) loadPhase=\(load.phase.rawValue)")
                    }
                    XCTAssertTrue(held)
                    guard held, let gate else { throw SelectionVideoTestFailure.timeout }
                    let request = gate.generation
                    let current = try XCTUnwrap(service.player.currentItem)
                    let resource = try XCTUnwrap(buffer.resource(for: current))
                    let preparedOutput = try XCTUnwrap(resource.output)
                    let outputs = current.outputs
                    // The default monitor may legitimately finish and detach
                    // before this async held observation. Its exact two-output
                    // attachment is proved synchronously at start, before KVO.
                    XCTAssertEqual(observedCount, alternative ? 1 : 2)
                    if alternative { XCTAssertEqual(outputs.count, 1) }
                    else { XCTAssertTrue(outputs.count == 1 || outputs.count == 2) }
                    XCTAssertTrue(observedPreparedIdentity)
                    XCTAssertEqual(observedItem, ObjectIdentifier(current))
                    XCTAssertEqual(observedResource, ObjectIdentifier(resource))
                    XCTAssertEqual(observedOutput, ObjectIdentifier(preparedOutput))
                    XCTAssertTrue(outputs.contains { $0 === preparedOutput })
                    XCTAssertTrue(resource.isAttached); XCTAssertTrue(resource.isBorrowed)
                    XCTAssertFalse(resource.isRetired)
                    XCTAssertNil(service.copiedVideoFramePositionSeconds)
                    XCTAssertNil(service.videoFramePositionSeconds)
                    XCTAssertNotEqual(service.debugInitialVideoReadyState.readyGeneration, request)
                    XCTAssertFalse(gate.timedOut); XCTAssertFalse(gate.cancelled); XCTAssertFalse(gate.overflow)
                    XCTAssertEqual(gate.dropped, 0); XCTAssertFalse(overflow)
                    XCTAssertFalse(ownerConflict); XCTAssertEqual(rejectedStarts, 0); XCTAssertEqual(ownerCaptures, 1)
                    print("FrameMonitorHeldReady schema=1 alternative=\(alternative) phase=\(phase) startOutputs=\(observedCount) heldOutputs=\(outputs.count) expectedStartOutputs=\(alternative ? 1 : 2) preparedIdentity=\(observedPreparedIdentity) currentEpochImage=false request=\(request) held=true startBeforeStatusObservation=true")
                    gate.release()
                    try await require({ self.explicitInitialReadySourceSettled(service, screen: screen) },
                                      "Actual selected custom/native readiness must settle after releasing the real callback")
                    XCTAssertFalse(gate.isHolding, "This source's gate must be released before the next source action")
                    XCTAssertFalse(ownerConflict); XCTAssertEqual(ownerCaptures, 1)
                    XCTAssertEqual(service.debugInitialVideoReadyState.generation, request)
                    assertSelection(service, fixture: fixture, id: phase == 1 ? fixture.bID : fixture.aID)
                    XCTAssertEqual(service.audioSnapshot.underrunFrames, 0)
                }
                let visible = await assertVisibleFrame(service, screen: screen, identity: .a,
                    label: alternative ? "monitor-single-output-returned-A" : "monitor-default-output-returned-A")
                XCTAssertNotNil(visible)
            }
        }
        #else
        XCTFail("Frame-monitor diagnostic requires DEBUG controls")
        #endif
    }

    func testReturnedChannelAuditDistinguishesStereoSilenceFromAntiphaseCancellation() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        func buffer(left: Float, right: Float) throws -> AVAudioPCMBuffer {
            let result = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            result.frameLength = 480
            let channels = try XCTUnwrap(result.floatChannelData)
            for frame in 0..<480 { channels[0][frame] = left; channels[1][frame] = right }
            return result
        }
        func time(_ frame: Int) -> AVAudioTime {
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100 + Double(frame) / 48_000))
        }
        for stereoSilent in [true, false] {
            let tap = ProductionSelectionOutputTap()
            let pcm = try buffer(left: stereoSilent ? 0 : 0.25, right: stereoSilent ? 0 : -0.25)
            XCTAssertEqual(tap.begin(auditChannels: true), 0)
            tap.append(pcm, time: time(0))
            let end = tap.stop()
            XCTAssertEqual(tap.stop(), end)
            let audit = tap.channelAudit()
            let mono = tap.samples(from: 0, to: end)
            XCTAssertEqual(mono.values.count, 480)
            XCTAssertTrue(mono.values.allSatisfy { $0 == 0 })
            // Both arms still fail the benchmark's original zero-quiet acceptance.
            XCTAssertEqual(ProductionSelectionOutputTap.quietRun(mono.values, rate: mono.rate), 0.01)
            XCTAssertFalse(ProductionSelectionOutputTap.isTone(mono.values, rate: mono.rate, frequency: 440))
            XCTAssertEqual(audit.observedFrames, 480); XCTAssertEqual(audit.minimumRunFrames, 480)
            XCTAssertEqual(audit.monoZeroFrames, 480)
            XCTAssertEqual(audit.stereoZeroFrames, stereoSilent ? 480 : 0)
            XCTAssertEqual(audit.leftSquareSum, stereoSilent ? 0 : 30)
            XCTAssertEqual(audit.rightSquareSum, stereoSilent ? 0 : 30)
            XCTAssertEqual(audit.nonfiniteFrames, 0)
            XCTAssertEqual(audit.qualifiedRuns, 1); XCTAssertEqual(audit.retainedRuns, 1)
            XCTAssertEqual(audit.droppedRuns, 0); XCTAssertFalse(audit.overflow)
            let run = try XCTUnwrap(audit.run(at: 0))
            XCTAssertEqual(run.frames, 480); XCTAssertEqual(run.firstFrame, 0); XCTAssertEqual(run.endFrame, 480)
            XCTAssertEqual(run.stereoZeroFrames, stereoSilent ? 480 : 0)
            XCTAssertEqual(run.leftSquareSum, stereoSilent ? 0 : 30)
            XCTAssertEqual(run.rightSquareSum, stereoSilent ? 0 : 30)
            XCTAssertNil(audit.run(at: 1)); XCTAssertNil(audit.run(at: 4))
        }
        let overflowTap = ProductionSelectionOutputTap()
        let zero = try buffer(left: 0, right: 0), tone = try buffer(left: 0.25, right: 0.25)
        overflowTap.begin(auditChannels: true)
        for ordinal in 0..<5 {
            overflowTap.append(zero, time: time(ordinal * 960))
            overflowTap.append(tone, time: time(ordinal * 960 + 480))
        }
        overflowTap.stop()
        let overflow = overflowTap.channelAudit()
        XCTAssertEqual(overflow.observedFrames, 4_800); XCTAssertEqual(overflow.monoZeroFrames, 2_400)
        XCTAssertEqual(overflow.qualifiedRuns, 5); XCTAssertEqual(overflow.retainedRuns, 4)
        XCTAssertEqual(overflow.droppedRuns, 1); XCTAssertTrue(overflow.overflow)
        for ordinal in 0..<4 {
            let run = try XCTUnwrap(overflow.run(at: ordinal))
            XCTAssertEqual(run.firstFrame, ordinal * 960); XCTAssertEqual(run.frames, 480)
        }
        XCTAssertNil(overflow.run(at: 4))
    }

    private func runProductionSelectionBenchmark(traceVideoSeeks: Bool, frameMonitorAlternative: Bool? = nil,
                                                recordHost: Bool = true, traceNativeRefill: Bool = false,
                                                renderAccounting: Bool? = nil) async throws {
        if recordHost { try recordRuntimeHost() }
        guard !Self.targetedFixtureOwnershipLost else {
            XCTFail("A previous targeted fixture did not acknowledge cleanup; no new owners may be created")
            return
        }
        let fixture = try await SelectionVideoFixture()
        var mayRemoveFixture = true
        defer { if mayRemoveFixture { fixture.remove() } }
        var references: [(samples: [Float], frequency: Double)] = []
        for (id, frequency) in [(fixture.aID, 440.0), (fixture.bID, 880.0)] {
            references.append((try await fixture.decodedTone(id: id), frequency))
        }
        #if DEBUG
        let nativeActivity = traceNativeRefill ? ContinuousPCMDecoder.DebugNativeLaneActivityRecorder() : nil
        let accounting = renderAccounting == true ? ContinuousPCMRenderer.DebugRenderAccountingRecorder() : nil
        let audio = ContinuousAudioPlayer(debugNativeLaneActivityRecorder: nativeActivity,
                                          debugRenderAccounting: accounting)
        if let enabled = renderAccounting {
            print("ProductionRenderAccountingScope schema=1 enabled=\(enabled) immutableAtConstruction=true nativeRefillTrace=\(traceNativeRefill) videoSeekTrace=\(traceVideoSeeks) defaultVideoMonitor=\(frameMonitorAlternative == nil) samplesPerWindow=128 windows=3 intervalMs=100 snapshotAttempts=3 clocksOnRender=false pcmScan=false jointCoherence=false playbackAcceptance=unchanged")
            XCTAssertFalse(traceNativeRefill); XCTAssertFalse(traceVideoSeeks)
            XCTAssertNil(frameMonitorAlternative)
        }
        let nativeTrace = nativeActivity.map { ProductionNativeRefillTrace(recorder: $0, audio: audio) }
        #else
        let audio = ContinuousAudioPlayer()
        #endif
        let tap = ProductionSelectionOutputTap()
        let seeks = ProductionSelectionSeekRecorder()
        let startup = ProductionVideoStartupTrace(serviceTracing: traceVideoSeeks)
        let monitorBuffer = frameMonitorAlternative.map { _ in PlaybackBuffer() }
        let service: PlaybackService
        if traceVideoSeeks {
            service = fixture.service(buffer: monitorBuffer, continuousAudio: audio, seekVideo: seeks.seek)
        } else {
            service = fixture.service(buffer: monitorBuffer, continuousAudio: audio)
        }
        #if DEBUG
        var monitorRows: [(phase: Int, selectedID: String?, expectedID: String?, outputs: Int, preparedIdentity: Bool)] = []
        var monitorOverflow = false
        var monitorPhase = -1
        var monitorExpectedID: String?
        if let alternative = frameMonitorAlternative {
            service.debugUsesCurrentCustomFrameForReadiness = alternative
            service.debugAfterFirstFrameMonitorStart = { [weak service] item in
                guard monitorRows.count < 8 else { monitorOverflow = true; return }
                let outputs = item.outputs
                let matched = monitorBuffer?.resource(for: item)?.output.map { expected in
                    outputs.contains { $0 === expected }
                } ?? false
                monitorRows.append((monitorPhase, service?.queue.currentID, monitorExpectedID, outputs.count, matched))
            }
        }
        if traceVideoSeeks {
            service.onDebugVideoSeekStamp = { [weak seeks, weak startup] stamp in
                seeks?.record(stamp); startup?.recordSeek(stamp)
            }
            service.onDebugVideoStartupStamp = { [weak startup] stamp in startup?.record(stamp) }
            service.onDebugVideoRenderStamp = { [weak startup] stamp in startup?.recordRender(stamp) }
        }
        defer {
            if frameMonitorAlternative != nil { service.debugAfterFirstFrameMonitorStart = nil }
            if traceVideoSeeks {
                service.onDebugVideoSeekStamp = nil; service.onDebugVideoStartupStamp = nil
                service.onDebugVideoRenderStamp = nil
            }
        }
        #endif
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
                audio: audio, tap: tap, seeks: seeks, startup: startup, phase: phase, id: id,
                frequency: frequency, prepared: prepared, preparedBefore: preparedBefore) {
                #if DEBUG
                if frameMonitorAlternative != nil {
                    monitorPhase = phase
                    monitorExpectedID = id
                }
                #endif
                switch phase {
                case 0: service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
                case 1: service.next()
                default: service.previous()
                }
            }
            measurements.append(measurement)
            if phase == 2 {
                returnedOrigin = ProductionSelectionOutputTap.hostSeconds()
                returnedStart = tap.begin(auditChannels: true)
            }
            let baseline = audio.renderer.snapshot
            let before = productionSelectionState(service, fixture: fixture, audio: audio, id: id)
            #if DEBUG
            let probe = ProductionRendererProbe(renderer: audio.renderer, nativeTrace: nativeTrace,
                nativePhase: phase, nativeExpectedToken: measurement.state.expectedToken,
                nativeCommandUnderruns: measurement.before.underrunFrames, renderAccounting: accounting)
            #else
            let probe = ProductionRendererProbe(renderer: audio.renderer)
            #endif
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
        let preparationAck = preparation.result, decoderAck = shutdown.result
        mayRemoveFixture = cleanupReturned && decoderAck == true && preparationAck == true
        print("ProductionSelectionCleanupAcknowledgements schema=1 cleanupReturned=\(cleanupReturned) preparationAckPresent=\(preparationAck != nil) preparationAckValue=\(preparationAck.map { $0 ? "true" : "false" } ?? "unknown") decoderAckPresent=\(decoderAck != nil) decoderAckValue=\(decoderAck.map { $0 ? "true" : "false" } ?? "unknown") nativeRefillTrace=\(traceNativeRefill) fixtureRemoveAllowed=\(mayRemoveFixture) availabilityScope=after-cleanup-wait")
        #if DEBUG
        nativeTrace?.dumpAfterCleanup()
        #endif
        print("ProductionSelectionCleanup completed=\(mayRemoveFixture) ownedTasksJoined=\(preparation.result == true) producerTracing=absent sdkInternalQuiescence=unverified syntheticFixtureRetained=\(!mayRemoveFixture)")
        XCTAssertTrue(mayRemoveFixture, "Queued decoder cleanup must return before removing only this synthetic fixture")
        if !mayRemoveFixture { Self.targetedFixtureOwnershipLost = true; fixture.restorePreferences() }
        #if DEBUG
        if let alternative = frameMonitorAlternative {
            print("FrameMonitorBenchmarkOutputs schema=1 alternative=\(alternative) rows=\(monitorRows.count) capacity=8 overflow=\(monitorOverflow) originalGuardsRetained=true physicalPixels=unmeasured")
            XCTAssertGreaterThanOrEqual(monitorRows.count, 3)
            XCTAssertLessThanOrEqual(monitorRows.count, 8)
            XCTAssertFalse(monitorOverflow)
            XCTAssertEqual(Set(monitorRows.map { $0.phase }), Set(0..<3))
            for (ordinal, row) in monitorRows.enumerated() {
                let expected = row.phase == 1 ? fixture.bID : fixture.aID
                let selectedMatches = row.selectedID == expected && row.expectedID == expected
                print("FrameMonitorBenchmarkOutput schema=1 alternative=\(alternative) ordinal=\(ordinal) phase=\(row.phase) outputs=\(row.outputs) expectedOutputs=\(alternative ? 1 : 2) preparedIdentity=\(row.preparedIdentity) selectedIDMatchesPhase=\(selectedMatches)")
                XCTAssertEqual(row.outputs, alternative ? 1 : 2)
                XCTAssertTrue(row.preparedIdentity)
                XCTAssertTrue((0..<3).contains(row.phase))
                XCTAssertTrue(selectedMatches)
            }
        }
        #endif
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
        #if DEBUG
        if let enabled = renderAccounting {
            for stream in streams { assertProductionRenderAccounting(stream, enabled: enabled) }
        }
        #endif
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
        let channelAudit = tap.channelAudit()
        print("ProductionSelectionReturnedChannelAudit schema=1 minimumRunFrames=\(channelAudit.minimumRunFrames) observedFrames=\(channelAudit.observedFrames) monoZeroFrames=\(channelAudit.monoZeroFrames) stereoZeroFrames=\(channelAudit.stereoZeroFrames) leftSquareSum=\(channelAudit.leftSquareSum) rightSquareSum=\(channelAudit.rightSquareSum) nonfiniteFrames=\(channelAudit.nonfiniteFrames) qualifiedRuns=\(channelAudit.qualifiedRuns) retainedRuns=\(channelAudit.retainedRuns) capacity=4 droppedRuns=\(channelAudit.droppedRuns) overflow=\(channelAudit.overflow) exactMonoZero=true playbackAcceptance=unchanged")
        XCTAssertEqual(channelAudit.observedFrames, returned.values.count)
        XCTAssertEqual(channelAudit.nonfiniteFrames, 0)
        XCTAssertLessThanOrEqual(channelAudit.retainedRuns, 4)
        XCTAssertEqual(channelAudit.droppedRuns, 0)
        XCTAssertFalse(channelAudit.overflow)
        for ordinal in 0..<4 {
            guard let run = channelAudit.run(at: ordinal) else { continue }
            let firstOffset = returnedOrigin.map { (run.firstHost - $0) * 1_000 }
            let endOffset = returnedOrigin.map { (run.endHost - $0) * 1_000 }
            print("ProductionSelectionReturnedChannelRun schema=1 ordinal=\(ordinal) firstFrame=\(run.firstFrame - channelAudit.firstFrame) endFrame=\(run.endFrame - channelAudit.firstFrame) frames=\(run.frames) startOffsetMs=\(firstOffset.map { String($0) } ?? "unknown") endOffsetMs=\(endOffset.map { String($0) } ?? "unknown") leftSquareSum=\(run.leftSquareSum) rightSquareSum=\(run.rightSquareSum) stereoZeroFrames=\(run.stereoZeroFrames)")
        }
        #if DEBUG
        let cachedJournal = service.debugCachedPlaybackDiagnostics
        print("ProductionSelectionCachedJournal schema=1 capacity=\(cachedJournal.capacity) retained=\(cachedJournal.entries.count) dropped=\(cachedJournal.droppedEvents) originPresent=\(cachedJournal.originUptime == nil ? 0 : 1) originUptime=\(cachedJournal.originUptime ?? 0) traceVideoSeeks=\(traceVideoSeeks ? 1 : 0) cachedOnly=1 newRecordCalls=0")
        XCTAssertEqual(cachedJournal.capacity, 128)
        XCTAssertLessThanOrEqual(cachedJournal.entries.count, 128)
        for (ordinal, entry) in cachedJournal.entries.prefix(128).enumerated() {
            let s = entry.snapshot
            print("ProductionSelectionCachedJournalEntry schema=1 ordinal=\(ordinal) sequence=\(entry.sequence) elapsedSeconds=\(entry.elapsedSeconds) phase=\(entry.phase.rawValue) generation=\(s.generation) audioRequested=\(s.audioRequested ? 1 : 0) audioPermitted=\(s.audioPermitted ? 1 : 0) audioInterrupted=\(s.audioInterrupted ? 1 : 0) interruptionReasonPresent=\(s.interruptionReason == nil ? 0 : 1) interruptionReason=\(s.interruptionReason ?? 0) interruptionOptionsPresent=\(s.interruptionOptions == nil ? 0 : 1) interruptionOptions=\(s.interruptionOptions ?? 0) wasSuspendedPresent=\(s.wasSuspended == nil ? 0 : 1) wasSuspended=\(s.wasSuspended == true ? 1 : 0) routeReasonPresent=\(s.routeChangeReason == nil ? 0 : 1) routeReason=\(s.routeChangeReason ?? 0) engineRunning=\(s.engineRunning ? 1 : 0) audioOnly=\(s.audioOnlySelected ? 1 : 0) presentation=\(s.presentation.rawValue) pipeline=\(s.pipeline.rawValue) positionPresent=\(s.positionSeconds == nil ? 0 : 1) positionSeconds=\(s.positionSeconds ?? 0) durationPresent=\(s.durationSeconds == nil ? 0 : 1) durationSeconds=\(s.durationSeconds ?? 0) ratePresent=\(s.playbackRate == nil ? 0 : 1) playbackRate=\(s.playbackRate ?? 0) retainedItems=\(s.retainedItems) preparedPCMBytes=\(s.preparedPCMBytes) underrunFrames=\(s.underrunFrames) outputRoute=\(s.outputRoute.rawValue) sampleRatePresent=\(s.sampleRate == nil ? 0 : 1) sampleRate=\(s.sampleRate ?? 0) ioBufferPresent=\(s.ioBufferSeconds == nil ? 0 : 1) ioBufferSeconds=\(s.ioBufferSeconds ?? 0) outputLatencyPresent=\(s.outputLatencySeconds == nil ? 0 : 1) outputLatencySeconds=\(s.outputLatencySeconds ?? 0) pipActive=\(s.pipActive ? 1 : 0) pipPossible=\(s.pipPossible ? 1 : 0) pipSuspended=\(s.pipSuspended ? 1 : 0) sourceFramesPresent=\(s.sourceFrames == nil ? 0 : 1) sourceFrames=\(s.sourceFrames ?? 0) leadingFramesPresent=\(s.sourceLeadingBelowMinus60DBFrames == nil ? 0 : 1) leadingFrames=\(s.sourceLeadingBelowMinus60DBFrames ?? 0) trailingFramesPresent=\(s.sourceTrailingBelowMinus60DBFrames == nil ? 0 : 1) trailingFrames=\(s.sourceTrailingBelowMinus60DBFrames ?? 0) errorPresent=\(entry.error == nil ? 0 : 1) errorFamily=\(entry.error?.family.rawValue ?? 0) errorCode=\(entry.error?.code ?? 0)")
        }
        #endif
        let anomalies = ProductionSelectionOutputTap.anomalyLocations(returned, origin: returnedOrigin, frequency: 440)
        print("ProductionSelectionReturnedAnomalySummary schema=1 available=\(anomalies.available) originHostSeconds=\(returnedOrigin.map { String($0) } ?? "unknown") monitorStopHostSeconds=unknown quietCount=\(anomalies.quietCount) badToneCount=\(anomalies.badToneCount) retainedRecords=\(anomalies.records.count) perKindCapacity=4 droppedAnomalyCount=\(anomalies.droppedAnomalyCount) indices=recording-relative endFrame=exclusive")
        for record in anomalies.records {
            print("ProductionSelectionReturnedAnomaly schema=1 kind=\(record.kind) windowOrdinal=\(record.windowOrdinal) firstFrame=\(record.firstFrame) endFrame=\(record.endFrame) startOffsetMs=\(record.startOffsetMs.map { String($0) } ?? "unknown") endOffsetMs=\(record.endOffsetMs.map { String($0) } ?? "unknown") rms=\(record.rms)")
        }
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
        if traceVideoSeeks {
            seeks.dumpAndAssert()
        } else {
            #if DEBUG
            XCTAssertNil(service.onDebugVideoSeekStamp, "The default production benchmark must leave the seek observer unset")
            XCTAssertNil(service.onDebugVideoStartupStamp)
            XCTAssertNil(service.onDebugVideoRenderStamp)
            #endif
            seeks.assertUnused()
        }
        startup.dumpAndAssert()
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
        seeks: ProductionSelectionSeekRecorder, startup: ProductionVideoStartupTrace, phase: Int, id: String, frequency: Double,
        prepared: Bool, preparedBefore: Bool, command: () -> Void) async -> ProductionSelectionMeasurement {
        let first = tap.begin()
        if prepared { try? await Task.sleep(for: .milliseconds(120)) }
        let before = audio.renderer.snapshot
        let expectedTokenBefore = audio.entry(for: id)?.token ?? 0
        let submitted = service.submittedVideoFrameCount
        seeks.phase = phase
        startup.phase = phase
        let origin = ProductionSelectionOutputTap.hostSeconds()
        command()
        let commandReturned = ProductionSelectionOutputTap.hostSeconds()
        var cursor = first
        var outgoing: ProductionSelectionOutputTap.Tone?
        var tone: ProductionSelectionOutputTap.Tone?
        var displayReady: Double?
        var ready: Double?
        let deadline = ProcessInfo.processInfo.systemUptime + (prepared ? 1 : 5)
        var pollUptime = ProcessInfo.processInfo.systemUptime
        while pollUptime < deadline {
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
            startup.beginPoll()
            if ready == nil, state.selected, state.audio.visit > before.visit,
               state.submitted > submitted, startup.observeLayerReady(screen.customVideoLayer?.isReadyForDisplay == true),
               let frame = state.frame, let copied = state.copied,
               frame.isFinite, copied.isFinite, state.requested.isFinite, frame >= 0, copied >= 0,
               abs(frame - state.requested) <= 0.080, abs(copied - frame) <= 0.080 {
                if displayReady == nil { displayReady = ProductionSelectionOutputTap.hostSeconds() }
                if state.videoReady && !state.loading {
                    ready = ProductionSelectionOutputTap.hostSeconds()
                }
            }
            startup.recordPoll(uptime: pollUptime, readyLatched: ready != nil,
                state: state, beforeVisit: before.visit, beforeSubmitted: submitted)
            if tone != nil && ready != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
            pollUptime = ProcessInfo.processInfo.systemUptime
        }
        let last = tap.stop()
        let finalState = productionSelectionState(service, fixture: fixture, audio: audio, id: id)
        startup.finishPhase(state: finalState, beforeVisit: before.visit, beforeSubmitted: submitted)
        return ProductionSelectionMeasurement(phase: phase, prepared: prepared, preparedBefore: preparedBefore,
            frequency: frequency, first: first, last: last, origin: origin,
            commandReturnHostSeconds: commandReturned, outgoing: outgoing, tone: tone,
            displayReady: displayReady, ready: ready, before: before,
            expectedTokenBefore: expectedTokenBefore, beforeSubmitted: submitted,
            state: finalState)
    }

    private func assertProductionSelection(_ value: ProductionSelectionMeasurement, tap: ProductionSelectionOutputTap) {
        let recorded = tap.samples(from: value.first, to: value.last)
        let quiet = ProductionSelectionOutputTap.quietRun(recorded.values, rate: recorded.rate)
        let hole = ProductionSelectionOutputTap.maximumTimelineHole(recorded.hosts, rate: recorded.rate)
        let toneMs = value.tone.map { ($0.end - value.origin) * 1_000 }
        let readyMs = value.ready.map { ($0 - value.origin) * 1_000 }
        let state = value.state
        print("ProductionSelectionLatency phase=\(value.phase) prepared=\(value.prepared) preparedBefore=\(value.preparedBefore) frequency=\(value.frequency) commandHostSeconds=\(value.origin) toneStartMs=\(value.tone.map { String(($0.start - value.origin) * 1_000) } ?? "missing") toneEndMs=\(toneMs.map { String($0) } ?? "missing") customDisplayReadyMs=\(value.displayReady.map { String(($0 - value.origin) * 1_000) } ?? "missing") videoReadyMs=\(readyMs.map { String($0) } ?? "missing") metadataMatches=\(state.metadataMatches) assetMatches=\(state.assetMatches) sourceIDMatches=\(state.sourceIDMatches) expectedToken=\(state.expectedToken) token=\(state.audio.token) visit=\(state.audio.visit) beforeVisit=\(value.before.visit) frame=\(state.audio.frame) ended=\(state.audio.ended) copiedPTS=\(state.copied.map { String($0) } ?? "missing") submittedPTS=\(state.frame.map { String($0) } ?? "missing") requested=\(state.requested) submitted=\(state.submitted) beforeSubmitted=\(value.beforeSubmitted) engineRunning=\(state.engineRunning) wantsPlaying=\(state.wantsPlaying) quietMs=\(quiet * 1_000) maximumHoleMs=\(hole * 1_000) underrunDelta=\(state.audio.underrunFrames - value.before.underrunFrames) producerTracing=absent physicalOutput=unverified compositorPixels=unverified")
        print("ProductionSelectionCommandReturn schema=1 phase=\(value.phase) commandHostSeconds=\(value.origin) returnHostSeconds=\(value.commandReturnHostSeconds) synchronousCommandSpanMs=\((value.commandReturnHostSeconds - value.origin) * 1_000)")
        XCTAssertTrue(value.origin.isFinite); XCTAssertTrue(value.commandReturnHostSeconds.isFinite)
        XCTAssertGreaterThanOrEqual(value.commandReturnHostSeconds, value.origin)
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
            #if DEBUG
            if sample.nativeTraceEnabled {
                print("ProductionSelectionNativeLanes schema=1 phase=\(value.phase) beginNs=\(sample.begin) endNs=\(sample.end) token=\(sample.audio.token) visit=\(sample.audio.visit) frame=\(sample.audio.frame) underrunFrames=\(sample.audio.underrunFrames) lane0Available=\(sample.lane0 != nil) lane0Packed=\(sample.lane0?.packedState ?? 0) lane0Sequence=\(sample.lane0?.copySequence ?? 0) lane0Stage=\(sample.lane0?.stageCode ?? 0) lane0Overflow=\(sample.lane0?.sequenceOverflowed ?? false) lane1Available=\(sample.lane1 != nil) lane1Packed=\(sample.lane1?.packedState ?? 0) lane1Sequence=\(sample.lane1?.copySequence ?? 0) lane1Stage=\(sample.lane1?.stageCode ?? 0) lane1Overflow=\(sample.lane1?.sequenceOverflowed ?? false) lane2Available=\(sample.lane2 != nil) lane2Packed=\(sample.lane2?.packedState ?? 0) lane2Sequence=\(sample.lane2?.copySequence ?? 0) lane2Stage=\(sample.lane2?.stageCode ?? 0) lane2Overflow=\(sample.lane2?.sequenceOverflowed ?? false) coherence=individual-packed-words-only")
            }
            #endif
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


    #if DEBUG
    /// Cumulative record differences are diagnostic evidence, not a new timing allowance.
    /// Samples retain unavailable/overflow states and stay inside the original acquisition bracket.
    private func assertProductionRenderAccounting(_ value: ProductionSelectionStream, enabled: Bool) {
        typealias Accounting = ContinuousPCMRenderer.DebugRenderAccountingSnapshot
        let samples = value.result.samples.filter {
            $0.end >= value.result.origin && $0.end - value.result.origin <= 8_000_000_000
        }
        let available = samples.compactMap { $0.renderAccounting }
        let unavailable = enabled ? samples.count - available.count : 0
        print("ProductionRenderAccountingWindow schema=1 phase=\(value.phase) enabled=\(enabled) samples=\(samples.count) available=\(available.count) unavailable=\(unavailable) snapshotAttempts=3 coherence=accounting-record-only rendererJointCoherence=false observerReadInsideAcquisition=true baselineToken=\(value.baseline.token) finalToken=\(value.final.token) baselineVisit=\(value.baseline.visit) finalVisit=\(value.final.visit)")
        if !enabled {
            XCTAssertTrue(available.isEmpty, "Nil observer must not synthesize zero counters")
            return
        }
        XCTAssertEqual(unavailable, 0, "Unavailable accounting is retained and fails diagnostic quality")
        for sample in samples {
            let stored = sample.renderAccounting
            func number(_ key: KeyPath<Accounting, UInt64>) -> String {
                stored.map { String($0[keyPath: key]) } ?? "unknown"
            }
            let sourceInFlight = stored.map { String($0.sourceCallbacksEntered > $0.sourceCallbacksCompleted) } ?? "unknown"
            let kernelInFlight = stored.map { String($0.kernelCallsEntered > $0.kernelCallsCompleted) } ?? "unknown"
            print("ProductionRenderAccountingSample schema=1 phase=\(value.phase) beginNs=\(sample.begin) endNs=\(sample.end) available=\(stored != nil) sequence=\(number(\.sequence)) sourceEntered=\(number(\.sourceCallbacksEntered)) sourceCompleted=\(number(\.sourceCallbacksCompleted)) sourceRequestedFrames=\(number(\.sourceFramesRequested)) sourceCompletedFrames=\(number(\.sourceFramesCompleted)) kernelEntered=\(number(\.kernelCallsEntered)) kernelCompleted=\(number(\.kernelCallsCompleted)) kernelRequestedFrames=\(number(\.kernelFramesRequested)) kernelClassifiedFrames=\(number(\.kernelFramesClassified)) copiedPCMFrames=\(number(\.copiedPCMFrames)) pausedPositiveTokenFrames=\(number(\.pausedPositiveTokenFrames)) inactiveFrames=\(number(\.inactiveFrames)) eofRemainderFrames=\(number(\.eofRemainderFrames)) underrunFrames=\(number(\.underrunFrames)) sourceInFlight=\(sourceInFlight) kernelInFlight=\(kernelInFlight) overflowed=\(stored.map { String($0.overflowed) } ?? "unknown") coherence=accounting-record-only rendererJointCoherence=false")
            guard let record = stored else { continue }
            XCTAssertFalse(record.overflowed)
            XCTAssertLessThanOrEqual(record.sourceCallbacksCompleted, record.sourceCallbacksEntered)
            XCTAssertLessThanOrEqual(record.kernelCallsCompleted, record.kernelCallsEntered)
            if record.sourceCallbacksEntered >= record.sourceCallbacksCompleted {
                XCTAssertLessThanOrEqual(record.sourceCallbacksEntered - record.sourceCallbacksCompleted, 1)
            }
            if record.kernelCallsEntered >= record.kernelCallsCompleted {
                XCTAssertLessThanOrEqual(record.kernelCallsEntered - record.kernelCallsCompleted, 1)
            }
            XCTAssertLessThanOrEqual(record.sourceFramesCompleted, record.sourceFramesRequested)
            XCTAssertLessThanOrEqual(record.kernelFramesClassified, record.kernelFramesRequested)
            var classified: UInt64 = 0, sumOverflow = false
            for frames in [record.copiedPCMFrames, record.pausedPositiveTokenFrames,
                           record.inactiveFrames, record.eofRemainderFrames, record.underrunFrames] {
                let next = classified.addingReportingOverflow(frames)
                classified = next.partialValue; sumOverflow = sumOverflow || next.overflow
            }
            XCTAssertFalse(sumOverflow)
            XCTAssertEqual(classified, record.kernelFramesClassified)
            if record.kernelCallsEntered == record.kernelCallsCompleted {
                XCTAssertEqual(record.kernelFramesRequested, record.kernelFramesClassified)
            }
            if record.sourceCallbacksEntered == record.sourceCallbacksCompleted,
               record.kernelCallsEntered == record.kernelCallsCompleted {
                let total = record.kernelFramesRequested.addingReportingOverflow(record.invalidLayoutFrames)
                XCTAssertFalse(total.overflow)
                XCTAssertEqual(record.sourceFramesCompleted, total.partialValue)
            }
            XCTAssertEqual(record.invalidLayoutCallbacks, 0); XCTAssertEqual(record.invalidLayoutFrames, 0)
        }
        guard let firstSample = samples.first, let lastSample = samples.last,
              let first = firstSample.renderAccounting, let last = lastSample.renderAccounting else { return }
        func delta(_ key: KeyPath<Accounting, UInt64>) -> String {
            let before = first[keyPath: key], after = last[keyPath: key]
            XCTAssertGreaterThanOrEqual(after, before)
            return after >= before ? String(after - before) : "invalid"
        }
        for (endpoint, sample, record) in [("first", firstSample, first), ("last", lastSample, last)] {
            print("ProductionRenderAccountingEndpoint schema=1 phase=\(value.phase) endpoint=\(endpoint) beginNs=\(sample.begin) endNs=\(sample.end) sequence=\(record.sequence) sourceCallbacksEntered=\(record.sourceCallbacksEntered) sourceCallbacksCompleted=\(record.sourceCallbacksCompleted) sourceFramesRequested=\(record.sourceFramesRequested) sourceFramesCompleted=\(record.sourceFramesCompleted) invalidLayoutCallbacks=\(record.invalidLayoutCallbacks) invalidLayoutFrames=\(record.invalidLayoutFrames) kernelCallsEntered=\(record.kernelCallsEntered) kernelCallsCompleted=\(record.kernelCallsCompleted) kernelFramesRequested=\(record.kernelFramesRequested) kernelFramesClassified=\(record.kernelFramesClassified) copiedPCMFrames=\(record.copiedPCMFrames) pausedPositiveTokenFrames=\(record.pausedPositiveTokenFrames) inactiveFrames=\(record.inactiveFrames) eofRemainderFrames=\(record.eofRemainderFrames) underrunFrames=\(record.underrunFrames) lastKernelToken=\(record.lastKernelToken) lastKernelVisit=\(record.lastKernelVisit) lastSourceFrameCount=\(record.lastSourceFrameCount) lastSourceHostTimeValid=\(record.lastSourceHostTimeValid) lastSourceHostTime=\(record.lastSourceHostTime) sourceInFlight=\(record.sourceCallbacksEntered > record.sourceCallbacksCompleted) kernelInFlight=\(record.kernelCallsEntered > record.kernelCallsCompleted) uncompletedSourceFrames=\(record.sourceFramesRequested >= record.sourceFramesCompleted ? record.sourceFramesRequested - record.sourceFramesCompleted : 0) unclassifiedKernelFrames=\(record.kernelFramesRequested >= record.kernelFramesClassified ? record.kernelFramesRequested - record.kernelFramesClassified : 0) overflowed=\(record.overflowed) recordCoherent=true rendererJointCoherence=false")
        }
        print("ProductionRenderAccountingDelta schema=1 phase=\(value.phase) firstBeginNs=\(firstSample.begin) firstEndNs=\(firstSample.end) lastBeginNs=\(lastSample.begin) lastEndNs=\(lastSample.end) sourceCallbacksEntered=\(delta(\.sourceCallbacksEntered)) sourceCallbacksCompleted=\(delta(\.sourceCallbacksCompleted)) sourceFramesRequested=\(delta(\.sourceFramesRequested)) sourceFramesCompleted=\(delta(\.sourceFramesCompleted)) invalidLayoutCallbacks=\(delta(\.invalidLayoutCallbacks)) invalidLayoutFrames=\(delta(\.invalidLayoutFrames)) kernelCallsEntered=\(delta(\.kernelCallsEntered)) kernelCallsCompleted=\(delta(\.kernelCallsCompleted)) kernelFramesRequested=\(delta(\.kernelFramesRequested)) kernelFramesClassified=\(delta(\.kernelFramesClassified)) copiedPCMFrames=\(delta(\.copiedPCMFrames)) pausedPositiveTokenFrames=\(delta(\.pausedPositiveTokenFrames)) inactiveFrames=\(delta(\.inactiveFrames)) eofRemainderFrames=\(delta(\.eofRemainderFrames)) underrunFrames=\(delta(\.underrunFrames)) firstSourceInFlight=\(first.sourceCallbacksEntered > first.sourceCallbacksCompleted) firstKernelInFlight=\(first.kernelCallsEntered > first.kernelCallsCompleted) lastSourceInFlight=\(last.sourceCallbacksEntered > last.sourceCallbacksCompleted) lastKernelInFlight=\(last.kernelCallsEntered > last.kernelCallsCompleted) endpointScope=independent-record-reads priorInflightCompletionMayBeIncluded=true playbackAcceptance=unchanged")
    }
    #endif

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

    func testStaleHeldReadyCallbackCannotDisplaceNewInitialZeroOwner() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            let oldRequest = service.debugInitialVideoReadyState.generation + 1
            let currentRequest = oldRequest + 1
            let old = SelectionInitialReadyOrderingProbe(generation: oldRequest)
            let current = SelectionInitialReadyOrderingProbe(generation: currentRequest)
            service.onDebugInitialVideoReady = { request in
                if request == oldRequest { await old.hold(request: request) }
                else if request == currentRequest { await current.hold(request: request) }
            }
            service.onDebugVideoSeekStamp = { stamp in current.record(stamp) }
            defer {
                // Both holds are finite and released before the existing owned
                // task/decoder cleanup, including every setup or assertion exit.
                old.release(); current.release()
                service.onDebugInitialVideoReady = nil
                service.onDebugVideoSeekStamp = nil
            }
            let baselineUnderruns = service.audioSnapshot.underrunFrames
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return old.isHolding && state.generation == oldRequest && state.readyGeneration == nil
                    && sample.token > 0 && state.audioVisit == sample.visit && !sample.ended
                    && service.preparedAudioCount == 2 && buffer.hasPrepared(fixture.bID)
            }, "Real A readiness must be held and fresh B must be staged before supersession")
            let a = service.audioSnapshot
            let bToken = try XCTUnwrap(audio.entry(for: fixture.bID)).token
            XCTAssertNotEqual(a.token, bToken)
            assertSelection(service, fixture: fixture, id: fixture.aID)

            service.next()
            let currentHeld = await waitUntil(timeout: 1) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return old.isHolding && current.isHolding && state.generation == currentRequest
                    && state.readyGeneration == nil && sample.token == bToken && sample.visit > a.visit
                    && state.audioVisit == sample.visit && !sample.ended
            }
            XCTAssertTrue(currentHeld, "Both real callbacks must overlap before releasing only the stale one")
            guard currentHeld else { throw SelectionVideoTestFailure.timeout }
            let beforeOldRelease = service.audioSnapshot
            let submitted = service.submittedVideoFrameCount
            let oldActiveBeforeRelease = old.active
            let oldStillHeldAfterSupersession = old.isHolding && oldActiveBeforeRelease > 0
            XCTAssertTrue(oldStillHeldAfterSupersession,
                          "A cancelled or timed-out old callback cannot stand in for stale delivery")
            guard oldStillHeldAfterSupersession else { throw SelectionVideoTestFailure.timeout }
            old.release()
            let oldExited = await waitUntil(timeout: 0.25) { old.active == 0 }
            XCTAssertTrue(oldExited, "The stale real callback's bounded hold must actually return")
            guard oldExited else { throw SelectionVideoTestFailure.timeout }
            let survivedOldDelivery = await waitUntil(timeout: 0.75) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return current.isHolding && state.generation == currentRequest && state.readyGeneration == nil
                    && sample.token == bToken && sample.visit == beforeOldRelease.visit && !sample.ended
                    && state.audioVisit == sample.visit && sample.frame >= beforeOldRelease.frame + 9_600
            }
            let held = service.audioSnapshot, heldState = service.debugInitialVideoReadyState
            let native = service.player.currentTime().seconds
            let drift = abs(native - Double(held.frame) / 48_000)
            current.stopRecording()
            print("InitialZeroStaleReadyControl schema=1 oldRequest=\(oldRequest) currentRequest=\(currentRequest) oldEntered=\(old.entered) oldActiveBeforeRelease=\(oldActiveBeforeRelease) oldStillHeldAfterSupersession=\(oldStillHeldAfterSupersession) oldActive=\(old.active) currentEntered=\(current.entered) currentActive=\(current.active) oldCancelled=\(old.cancelled) currentCancelled=\(current.cancelled) oldTimedOut=\(old.timedOut) currentTimedOut=\(current.timedOut) oldExited=\(oldExited) survivedOldDelivery=\(survivedOldDelivery) readyGeneration=\(heldState.readyGeneration.map { String($0) } ?? "missing") nativePosition=\(native) absoluteDrift=\(drift) reasons=\(current.reasons.map { String($0) }.joined(separator: ",")) underrunDelta=\(held.underrunFrames - baselineUnderruns) ownerProof=observable-pending-ready-behavior")
            XCTAssertTrue(survivedOldDelivery)
            XCTAssertEqual(old.active, 0); XCTAssertTrue(current.isHolding)
            XCTAssertFalse(old.timedOut); XCTAssertFalse(current.timedOut)
            XCTAssertFalse(old.cancelled); XCTAssertFalse(current.cancelled)
            XCTAssertFalse(old.overflow); XCTAssertFalse(current.overflow)
            XCTAssertEqual(old.dropped, 0); XCTAssertEqual(current.dropped, 0)
            XCTAssertNil(heldState.readyGeneration, "Old delivery must not mark any generation ready")
            XCTAssertEqual(heldState.generation, currentRequest)
            XCTAssertNil(heldState.syncingVideoGeneration)
            XCTAssertEqual(service.submittedVideoFrameCount, submitted,
                           "Stale readiness must not authorize the new item's frame feed")
            XCTAssertTrue(drift.isFinite); XCTAssertGreaterThan(drift, 0.080)
            XCTAssertFalse(current.reasons.contains(PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue))
            XCTAssertFalse(current.reasons.contains(PlaybackService.DebugVideoSeekReason.drift.rawValue),
                           "Old delivery must not remove the current owner's ordinary-drift deferral")
            XCTAssertEqual(held.underrunFrames, baselineUnderruns)
            assertSelection(service, fixture: fixture, id: fixture.bID)
            guard survivedOldDelivery else { throw SelectionVideoTestFailure.timeout }

            current.release()
            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                guard let frame = service.videoFramePositionSeconds,
                      let copied = service.copiedVideoFramePositionSeconds else { return false }
                return current.active == 0 && state.generation == currentRequest && state.readyGeneration == currentRequest
                    && state.syncingVideoGeneration == nil && sample.token == bToken && sample.visit == held.visit
                    && sample.frame >= held.frame + 2_400 && !sample.ended
                    && service.submittedVideoFrameCount > submitted && service.isVideoReady && !service.isLoading
                    && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                    && abs(frame - service.videoRequestedPositionSeconds) <= 0.080 && abs(copied - frame) <= 0.080
                    && abs(service.player.currentTime().seconds - Double(sample.frame) / 48_000) <= 0.080
                    && screen.customVideoLayer?.isReadyForDisplay == true
            }, "Only current readiness release may reveal aligned selected B with continued PCM")
            assertSelection(service, fixture: fixture, id: fixture.bID)
            XCTAssertTrue(service.wantsToPlay); XCTAssertTrue(service.audioEngineRunning)
            await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "stale-ready-released-current-B")
            let displayed = service.audioSnapshot
            XCTAssertEqual(displayed.token, bToken); XCTAssertEqual(displayed.visit, held.visit)
            XCTAssertFalse(displayed.ended); XCTAssertGreaterThan(displayed.frame, held.frame)
            XCTAssertEqual(displayed.underrunFrames, baselineUnderruns)

            service.pause()
            try await require({ !service.audioEngineRunning }, "Explicit final Pause must settle the actual audio engine")
            let paused = service.audioSnapshot
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertFalse(service.wantsToPlay); XCTAssertFalse(service.audioEngineRunning)
            XCTAssertEqual(service.player.rate, 0)
            XCTAssertEqual(service.audioSnapshot.token, paused.token)
            XCTAssertEqual(service.audioSnapshot.visit, paused.visit)
            XCTAssertEqual(service.audioSnapshot.frame, paused.frame)
            XCTAssertEqual(service.audioSnapshot.underrunFrames, baselineUnderruns)
        }
        #else
        XCTFail("Stale initial-ready controls require DEBUG hooks")
        #endif
    }

    func testInitialReadyBindsNativeVideoToAdvancedAudioWithoutReseeking() async throws {
        #if DEBUG
        try await withOwnedNaturalFixture { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            let request = service.debugInitialVideoReadyState.generation + 1
            let probe = SelectionInitialReadyOrderingProbe(generation: request)
            service.onDebugInitialVideoReady = { generation in await probe.hold(request: generation) }
            service.onDebugVideoSeekStamp = { stamp in probe.record(stamp) }
            defer {
                probe.release()
                service.onDebugInitialVideoReady = nil
                service.onDebugVideoSeekStamp = nil
            }
            let baselineUnderruns = service.audioSnapshot.underrunFrames
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return probe.isHolding && state.generation == request && state.readyGeneration == nil
                    && state.syncingVideoGeneration == nil && sample.token > 0 && !sample.ended
                    && state.audioVisit == sample.visit && sample.frame >= 9_600
            }, "Real initial readiness must remain held while acknowledged PCM advances at least 200 ms")
            let held = captureInitialReadyNativeClock(service)
            let token = try XCTUnwrap(audio.entry(for: fixture.aID)).token
            XCTAssertEqual(held.after.token, token)
            XCTAssertTrue(held.sameIdentity); XCTAssertLessThanOrEqual(held.acquisitionSeconds, 0.005)
            XCTAssertTrue(held.nativePosition.isFinite); XCTAssertGreaterThan(held.alignmentErrorSeconds, 0.080)
            XCTAssertTrue(probe.reasons.isEmpty, "The existing initial owner must prevent pre-release corrections")
            XCTAssertFalse(probe.timedOut); XCTAssertFalse(probe.cancelled); XCTAssertFalse(probe.overflow)
            XCTAssertEqual(probe.dropped, 0); XCTAssertEqual(held.after.underrunFrames, baselineUnderruns)
            guard held.sameIdentity, held.acquisitionSeconds <= 0.005,
                  held.nativePosition.isFinite, held.alignmentErrorSeconds > 0.080,
                  probe.isHolding, probe.reasons.isEmpty else { throw SelectionVideoTestFailure.timeout }

            // The ready-generation read below cannot run midway through the
            // synchronous actor callback. Do not wait for a drift seek to finish:
            // the window must include the first native clock after ready binding.
            probe.release()
            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return probe.active == 0 && state.generation == request && state.readyGeneration == request
                    && sample.token == token && sample.visit == held.after.visit && !sample.ended
            }, "The real ready callback must return before the post-ready native-clock window")
            var observations: [InitialReadyNativeClockObservation] = []
            observations.reserveCapacity(32)
            for _ in 0..<32 {
                let value = captureInitialReadyNativeClock(service)
                observations.append(value)
                if let first = observations.first,
                   value.end - first.begin >= 200_000_000,
                   value.after.frame >= first.before.frame + 9_600 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            probe.stopRecording()
            let postReady = service.audioSnapshot
            let submitted = service.submittedVideoFrameCount
            let revealed = await waitUntil(timeout: 5) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                guard let frame = service.videoFramePositionSeconds,
                      let copied = service.copiedVideoFramePositionSeconds else { return false }
                return state.generation == request && state.readyGeneration == request
                    && state.syncingVideoGeneration == nil && sample.token == token && sample.visit == held.after.visit
                    && sample.frame >= postReady.frame + 2_400 && !sample.ended
                    && service.submittedVideoFrameCount > submitted && service.isVideoReady && !service.isLoading
                    && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                    && abs(frame - service.videoRequestedPositionSeconds) <= 0.080 && abs(copied - frame) <= 0.080
                    && abs(service.player.currentTime().seconds - Double(sample.frame) / 48_000) <= 0.080
                    && screen.customVideoLayer?.isReadyForDisplay == true
            }
            assertSelection(service, fixture: fixture, id: fixture.aID)
            await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "initial-ready-native-clock-A")
            let final = service.audioSnapshot
            XCTAssertEqual(final.token, token); XCTAssertEqual(final.visit, held.after.visit)
            XCTAssertFalse(final.ended); XCTAssertGreaterThan(final.frame, postReady.frame)
            XCTAssertEqual(final.underrunFrames, baselineUnderruns)
            // Keep numeric dumps and analysis outside the observed clock/window
            // and moving-pixel acquisition; the owned helper still joins cleanup.
            service.pause(); audio.graph.engine.stop()
            let gaps = zip(observations, observations.dropFirst()).map { Double($1.begin - $0.end) / 1_000_000_000 }
            let wall = observations.first.flatMap { first in observations.last.map { Double($0.end - first.begin) / 1_000_000_000 } } ?? -1
            let pcm = observations.first.flatMap { first in observations.last.map { Double($0.after.frame - first.before.frame) / 48_000 } } ?? -1
            print("InitialReadyNativeClockControl schema=1 request=\(request) heldBeforeFrame=\(held.before.frame) heldAfterFrame=\(held.after.frame) heldNativePosition=\(held.nativePosition) heldAcquisitionMs=\(held.acquisitionSeconds * 1_000) heldSameIdentity=\(held.sameIdentity) heldOffsetErrorMs=\(held.alignmentErrorSeconds * 1_000) observations=\(observations.count) capacity=32 requestedIntervalMs=10 wallSeconds=\(wall) pcmSeconds=\(pcm) maximumGapMs=\((gaps.max() ?? .infinity) * 1_000) revealed=\(revealed) reasons=\(probe.reasons.map { String($0) }.joined(separator: ",")) nativeReadsPerObservation=1 rendererReadsPerObservation=2 latencyAcceptance=false physicalOutput=unverified")
            XCTAssertTrue(revealed, "Ready binding must reveal a fresh selected custom frame with continuing aligned PCM")
            for value in observations {
                print("InitialReadyNativeClockObservation schema=1 request=\(request) beginNs=\(value.begin) endNs=\(value.end) acquisitionMs=\(value.acquisitionSeconds * 1_000) token=\(value.after.token) visit=\(value.after.visit) beforeFrame=\(value.before.frame) afterFrame=\(value.after.frame) nativePosition=\(value.nativePosition) alignmentErrorMs=\(value.alignmentErrorSeconds * 1_000) sameIdentity=\(value.sameIdentity) underrunFrames=\(value.after.underrunFrames)")
                XCTAssertTrue(value.sameIdentity)
                XCTAssertEqual(value.after.token, token); XCTAssertEqual(value.after.visit, held.after.visit)
                XCTAssertLessThanOrEqual(value.acquisitionSeconds, 0.005)
                XCTAssertTrue(value.nativePosition.isFinite)
                XCTAssertLessThanOrEqual(value.alignmentErrorSeconds, 0.080,
                                         "Initial native clock must bind advanced audio without a corrective seek")
                XCTAssertEqual(value.before.underrunFrames, baselineUnderruns)
                XCTAssertEqual(value.after.underrunFrames, baselineUnderruns)
            }
            XCTAssertGreaterThanOrEqual(observations.count, 5); XCTAssertLessThanOrEqual(observations.count, 32)
            XCTAssertGreaterThanOrEqual(wall, 0.2); XCTAssertGreaterThanOrEqual(pcm, 0.2)
            XCTAssertLessThanOrEqual(gaps.max() ?? .infinity, 0.050)
            XCTAssertFalse(probe.reasons.contains(PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue))
            XCTAssertFalse(probe.reasons.contains(PlaybackService.DebugVideoSeekReason.drift.rawValue),
                           "The real release window must not repair its initial binding through an exact drift seek")
            XCTAssertFalse(probe.timedOut); XCTAssertFalse(probe.cancelled); XCTAssertFalse(probe.overflow)
            XCTAssertEqual(probe.dropped, 0)
        }
        #else
        XCTFail("Initial-ready native-clock controls require DEBUG hooks")
        #endif
    }

    #if DEBUG
    private struct InitialReadyNativeClockObservation {
        let begin: UInt64, end: UInt64
        let before: ContinuousPCMRenderer.Snapshot, after: ContinuousPCMRenderer.Snapshot
        let nativePosition: Double
        var acquisitionSeconds: Double { Double(end - begin) / 1_000_000_000 }
        var sameIdentity: Bool {
            before.token > 0 && before.token == after.token && before.visit == after.visit
                && before.selectionVersion == after.selectionVersion && !before.ended && !after.ended
                && after.frame >= before.frame
        }
        var alignmentErrorSeconds: Double {
            guard sameIdentity, nativePosition.isFinite else { return .infinity }
            // Distance to the actual renderer-frame bracket, without adding a
            // second timing tolerance to the existing 80 ms alignment limit.
            return max(0, max(Double(before.frame) / 48_000 - nativePosition,
                              nativePosition - Double(after.frame) / 48_000))
        }
    }

    private func captureInitialReadyNativeClock(_ service: PlaybackService) -> InitialReadyNativeClockObservation {
        let begin = DispatchTime.now().uptimeNanoseconds
        let before = service.audioSnapshot
        let native = service.player.currentTime().seconds
        let after = service.audioSnapshot
        let end = DispatchTime.now().uptimeNanoseconds
        return InitialReadyNativeClockObservation(begin: begin, end: end, before: before, after: after,
                                                  nativePosition: native)
    }
    #endif

    func testExplicitSeekEntryBeforeInitialOwnerInstallationPreservesNativeCorrection() async throws {
        #if DEBUG
        try await withOwnedNaturalFixture { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            service.debugInitialLoadPhaseEnabled = true
            let request = service.debugInitialVideoReadyState.generation + 1
            let probe = SelectionInitialReadyOrderingProbe(generation: request)
            service.onDebugInitialVideoReady = { generation in await probe.hold(request: generation) }
            service.onDebugVideoSeekStamp = { stamp in probe.record(stamp) }
            defer {
                probe.release()
                service.onDebugInitialVideoReady = nil
                service.onDebugVideoSeekStamp = nil
            }
            let before = service.audioSnapshot
            // No await: the cold load Task cannot install its item/owner before
            // this real seek entry. Its guard may reject the target; history is
            // intentionally conservative even for that no-op request.
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            let beforeInstallation = service.player.currentItem == nil
                && service.debugInitialVideoReadyState.generation == request
                && service.debugInitialVideoReadyState.readyGeneration == nil
            XCTAssertTrue(beforeInstallation)
            guard beforeInstallation else { return }
            service.seek(0.04)
            // Cold setup has the original natural case's three-second budget.
            // Its completion is separate from the unchanged correction deadline.
            let initialHeld = await waitUntil(timeout: 3) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                let expected = audio.entry(for: fixture.aID)?.token ?? 0
                return probe.isHolding && state.generation == request && state.readyGeneration != request
                    && expected > 0 && sample.token == expected && state.audioVisit == sample.visit
            }
            guard initialHeld else {
                XCTFail("The real cold initial-ready callback and acknowledged audio visit must be held before checking correction")
                let phase = service.debugInitialLoadPhaseState
                print("InitialZeroExplicitSeekSetup schema=1 held=false request=\(request) loadRequest=\(phase.request) generation=\(phase.generation) loadPhase=\(phase.phase.rawValue) phaseEnabled=\(phase.enabled)")
                await recordNaturalRunwayFailure(audio: audio,
                    expectedToken: audio.entry(for: fixture.aID)?.token ?? 0, stage: "explicit-preinstall-setup")
                return
            }
            let correctedWhileHeld = await waitUntil(timeout: 1.5) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                let expected = audio.entry(for: fixture.aID)?.token ?? 0
                return probe.isHolding && state.generation == request && state.readyGeneration != request
                    && expected > 0 && sample.token == expected && state.audioVisit == sample.visit
                    && probe.reasons.contains { $0 == PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue
                        || $0 == PlaybackService.DebugVideoSeekReason.drift.rawValue }
            }
            let held = service.audioSnapshot
            probe.stopRecording()
            print("InitialZeroExplicitSeekControl schema=1 mode=preinstall request=\(request) beforeInstallation=\(beforeInstallation) requestedSeconds=0.04 targetAcceptance=unverified correctedWhileHeld=\(correctedWhileHeld) held=\(probe.isHolding) reasons=\(probe.reasons.map { String($0) }.joined(separator: ",")) underrunDelta=\(held.underrunFrames - before.underrunFrames)")
            XCTAssertTrue(correctedWhileHeld, "Explicit seek entry before owner installation must leave native correction eligible")
            XCTAssertTrue(probe.isHolding); XCTAssertFalse(probe.timedOut); XCTAssertFalse(probe.cancelled)
            XCTAssertFalse(probe.overflow); XCTAssertEqual(probe.dropped, 0)
            XCTAssertEqual(held.underrunFrames, before.underrunFrames)
            guard correctedWhileHeld else { return }
            try await finishExplicitInitialReadyControl(service, screen: screen, fixture: fixture,
                probe: probe, token: held.token, baselineUnderruns: before.underrunFrames,
                label: "initial-zero-explicit-preinstall-A")
        }
        #else
        XCTFail("Initial-zero explicit seek controls require DEBUG hooks")
        #endif
    }

    func testPauseSeekResumeBeforeFirstReturnedVisitPreservesExplicitForce() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await require({ self.explicitInitialReadySourceSettled(service, screen: screen)
                && service.preparedAudioCount == 2 }, "Initial A must settle before the explicit resumed-seek control")
            let aToken = service.audioSnapshot.token
            service.next()
            try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token != aToken
                && self.explicitInitialReadySourceSettled(service, screen: screen)
                && service.preparedAudioCount == 2 }, "Prepared B must settle before the explicit resumed-seek control")
            try await require({ buffer.previousMediaID == fixture.aID && buffer.debugPreviousNeedsRewind == false },
                              "Retained A must finish its real offscreen rewind")
            let before = service.audioSnapshot
            let request = service.debugInitialVideoReadyState.generation + 1
            let probe = SelectionInitialReadyOrderingProbe(generation: request)
            service.onDebugInitialVideoReady = { generation in await probe.hold(request: generation) }
            service.onDebugVideoSeekStamp = { stamp in probe.record(stamp) }
            defer {
                probe.release()
                service.onDebugInitialVideoReady = nil
                service.onDebugVideoSeekStamp = nil
            }
            // One actor turn: neither readiness delivery nor the actor's audio
            // poll can run between these real actions. The paused seek clears
            // pendingAudioSeek before play restores intent.
            service.previous()
            service.pause()
            service.seek(0.4)
            service.play()
            let correctedWhileHeld = await waitUntil(timeout: 1.5) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return probe.isHolding && state.generation == request && state.readyGeneration != request
                    && sample.token == aToken && sample.visit > before.visit && state.audioVisit == sample.visit
                    && sample.frame >= 19_200
                    && probe.reasons.contains(PlaybackService.DebugVideoSeekReason.userPausedSeek.rawValue)
            }
            let held = service.audioSnapshot
            probe.stopRecording()
            print("InitialZeroExplicitSeekControl schema=1 mode=paused-resumed request=\(request) requestedSeconds=0.4 correctedWhileHeld=\(correctedWhileHeld) held=\(probe.isHolding) playingIntent=\(service.wantsToPlay) reasons=\(probe.reasons.map { String($0) }.joined(separator: ",")) underrunDelta=\(held.underrunFrames - before.underrunFrames) historyOnlyBarrier=unproven")
            XCTAssertTrue(correctedWhileHeld, "Explicit paused force must remain eligible while initial readiness is withheld")
            XCTAssertTrue(service.wantsToPlay); XCTAssertTrue(service.audioEngineRunning)
            XCTAssertTrue(probe.isHolding); XCTAssertFalse(probe.timedOut); XCTAssertFalse(probe.cancelled)
            XCTAssertFalse(probe.overflow); XCTAssertEqual(probe.dropped, 0)
            XCTAssertEqual(held.underrunFrames, before.underrunFrames)
            guard correctedWhileHeld else { throw SelectionVideoTestFailure.timeout }
            try await finishExplicitInitialReadyControl(service, screen: screen, fixture: fixture,
                probe: probe, token: aToken, baselineUnderruns: before.underrunFrames,
                label: "initial-zero-explicit-paused-resumed-A")
        }
        #else
        XCTFail("Initial-zero explicit seek controls require DEBUG hooks")
        #endif
    }

    #if DEBUG
    private func explicitInitialReadySourceSettled(_ service: PlaybackService, screen: SelectionVideoScreen) -> Bool {
        let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
        return sample.token > 0 && sample.frame > 2_400 && !sample.ended
            && state.readyGeneration == state.generation && state.audioVisit == sample.visit
            && state.syncingVideoGeneration == nil && service.isVideoReady && !service.isLoading
            && screen.customVideoLayer?.isReadyForDisplay == true
    }

    private func finishExplicitInitialReadyControl(_ service: PlaybackService, screen: SelectionVideoScreen,
        fixture: SelectionVideoFixture, probe: SelectionInitialReadyOrderingProbe, token: Int,
        baselineUnderruns: Int64, label: String) async throws {
        let submitted = service.submittedVideoFrameCount
        let before = service.audioSnapshot
        XCTAssertEqual(before.token, token); XCTAssertFalse(before.ended)
        probe.release()
        try await require({
            let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
            guard let frame = service.videoFramePositionSeconds,
                  let copied = service.copiedVideoFramePositionSeconds else { return false }
            return state.generation == probe.generation && state.readyGeneration == probe.generation
                && state.syncingVideoGeneration == nil && sample.token == token && sample.visit == before.visit
                && sample.frame >= before.frame + 2_400 && !sample.ended
                && service.submittedVideoFrameCount > submitted && service.isVideoReady && !service.isLoading
                && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                && abs(frame - service.videoRequestedPositionSeconds) <= 0.080 && abs(copied - frame) <= 0.080
                && abs(service.player.currentTime().seconds - Double(sample.frame) / 48_000) <= 0.080
                && screen.customVideoLayer?.isReadyForDisplay == true
        }, "Released real readiness must reveal a fresh selected and aligned custom frame")
        assertSelection(service, fixture: fixture, id: fixture.aID)
        XCTAssertTrue(service.wantsToPlay); XCTAssertTrue(service.audioEngineRunning)
        XCTAssertEqual(service.audioSnapshot.underrunFrames, baselineUnderruns)
        await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: label)
        XCTAssertEqual(service.audioSnapshot.token, token)
        XCTAssertEqual(service.audioSnapshot.visit, before.visit); XCTAssertFalse(service.audioSnapshot.ended)
        XCTAssertGreaterThan(service.audioSnapshot.frame, before.frame)
        XCTAssertEqual(service.audioSnapshot.underrunFrames, baselineUnderruns)
    }
    #endif

    func testReturnedVideoWaitsForInitialReadyCallbackBeforeVisitOrDriftSeek() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await require({
                let state = service.debugInitialVideoReadyState
                let sample = service.audioSnapshot
                return sample.token != 0 && sample.frame > 2_400 && service.preparedAudioCount == 2
                    && state.readyGeneration == state.generation && state.audioVisit == sample.visit
                    && state.syncingVideoGeneration == nil && service.isVideoReady
                    && screen.customVideoLayer?.isReadyForDisplay == true
            }, "Initial A must finish its real readiness path before the ordering control")
            let aToken = service.audioSnapshot.token
            assertSelection(service, fixture: fixture, id: fixture.aID)

            service.next()
            try await require({
                let state = service.debugInitialVideoReadyState
                let sample = service.audioSnapshot
                return service.queue.currentID == fixture.bID && sample.token != 0 && sample.token != aToken
                    && sample.frame > 2_400 && service.preparedAudioCount == 2
                    && state.readyGeneration == state.generation && state.audioVisit == sample.visit
                    && state.syncingVideoGeneration == nil && service.isVideoReady
                    && screen.customVideoLayer?.isReadyForDisplay == true
            }, "Prepared B must settle before holding returned A's real ready callback")
            assertSelection(service, fixture: fixture, id: fixture.bID)
            try await require({ buffer.previousMediaID == fixture.aID && buffer.debugPreviousNeedsRewind == false },
                              "Retained A must finish its real offscreen rewind for the initial zero-start control")
            let beforeReturn = service.audioSnapshot
            let returnedGeneration = service.debugInitialVideoReadyState.generation + 1
            let probe = SelectionInitialReadyOrderingProbe(generation: returnedGeneration)
            service.onDebugInitialVideoReady = { request in await probe.hold(request: request) }
            // Record before Previous: the bad seek can precede entry into the held callback.
            service.onDebugVideoSeekStamp = { stamp in probe.record(stamp) }
            defer {
                // This body exits before withOwnedNaturalFixture performs its existing
                // preparation/decoder acknowledgements and owned-file cleanup.
                probe.release()
                service.onDebugInitialVideoReady = nil
                service.onDebugVideoSeekStamp = nil
            }

            service.previous()
            let visitProcessed = await waitUntil(timeout: 1.5) {
                let state = service.debugInitialVideoReadyState
                let sample = service.audioSnapshot
                return probe.isHolding && state.generation == returnedGeneration
                    && state.readyGeneration != returnedGeneration && sample.token == aToken
                    && sample.visit > beforeReturn.visit && state.audioVisit == sample.visit
            }
            XCTAssertTrue(visitProcessed,
                          "The real returned-A callback must be held after the service processes its acknowledged visit")
            guard visitProcessed else { throw SelectionVideoTestFailure.timeout }
            let heldBaseline = service.audioSnapshot
            let progressedWhileHeld = await waitUntil(timeout: 0.75) {
                let state = service.debugInitialVideoReadyState
                let sample = service.audioSnapshot
                return probe.isHolding && state.generation == returnedGeneration
                    && state.readyGeneration != returnedGeneration && state.audioVisit == sample.visit
                    && sample.token == aToken && sample.visit == heldBaseline.visit
                    && sample.frame >= heldBaseline.frame + 9_600
            }
            let held = service.audioSnapshot
            let heldState = service.debugInitialVideoReadyState
            let nativePosition = service.player.currentTime().seconds
            let drift = abs(nativePosition - Double(held.frame) / 48_000)
            probe.stopRecording()
            print("InitialReadyOrdering phase=held generation=\(returnedGeneration) heldCallbacks=\(probe.entered) activeCallbacks=\(probe.active) timedOut=\(probe.timedOut) cancelled=\(probe.cancelled) overflow=\(probe.overflow) visitProcessed=\(visitProcessed) progressed=\(progressedWhileHeld) cachedVisit=\(heldState.audioVisit) renderVisit=\(held.visit) renderFrame=\(held.frame) nativePosition=\(nativePosition) absoluteDrift=\(drift) readyGeneration=\(heldState.readyGeneration.map { String($0) } ?? "missing") syncingGeneration=\(heldState.syncingVideoGeneration.map { String($0) } ?? "missing") seekReasons=\(probe.reasons.map { String($0) }.joined(separator: ",")) dropped=\(probe.dropped) underrunDelta=\(held.underrunFrames - beforeReturn.underrunFrames)")
            XCTAssertTrue(progressedWhileHeld, "Real PCM must advance 200 ms while initial readiness remains withheld")
            XCTAssertTrue(probe.isHolding)
            XCTAssertFalse(probe.timedOut); XCTAssertFalse(probe.cancelled); XCTAssertFalse(probe.overflow)
            XCTAssertEqual(probe.dropped, 0)
            XCTAssertEqual(heldState.generation, returnedGeneration)
            XCTAssertNotEqual(heldState.readyGeneration, returnedGeneration)
            XCTAssertEqual(heldState.audioVisit, held.visit)
            XCTAssertEqual(held.token, aToken); XCTAssertEqual(held.visit, heldBaseline.visit)
            XCTAssertEqual(held.underrunFrames, beforeReturn.underrunFrames)
            XCTAssertEqual(service.player.currentItem?.status, .readyToPlay)
            XCTAssertTrue(drift.isFinite)
            // A premature seek can already have aligned native time. It still fails
            // the forbidden-reason assertions below. A passing no-seek control must
            // prove that ordinary drift would otherwise be eligible.
            if !probe.reasons.contains(PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue)
                && !probe.reasons.contains(PlaybackService.DebugVideoSeekReason.drift.rawValue) {
                XCTAssertGreaterThan(drift, 0.080, "A passing control must make ordinary drift eligible before callback delivery")
            }
            XCTAssertNil(heldState.syncingVideoGeneration, "Initial callback ownership must not be displaced by a seek")
            XCTAssertFalse(probe.reasons.contains(PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue),
                           "A newly acknowledged visit must not seek before its initial ready callback owns the timeline")
            XCTAssertFalse(probe.reasons.contains(PlaybackService.DebugVideoSeekReason.drift.rawValue),
                           "Ordinary drift must not seek before the initial ready callback owns the timeline")
            assertSelection(service, fixture: fixture, id: fixture.aID)

            let submittedBeforeRelease = service.submittedVideoFrameCount
            probe.release()
            try await require({
                let state = service.debugInitialVideoReadyState
                let sample = service.audioSnapshot
                guard let frame = service.videoFramePositionSeconds,
                      let copied = service.copiedVideoFramePositionSeconds else { return false }
                return state.generation == returnedGeneration && state.readyGeneration == returnedGeneration
                    && state.syncingVideoGeneration == nil && sample.token == aToken && sample.visit == held.visit
                    && sample.frame >= held.frame + 2_400 && !sample.ended
                    && service.submittedVideoFrameCount > submittedBeforeRelease
                    && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                    && abs(frame - service.videoRequestedPositionSeconds) <= 0.080
                    && abs(copied - frame) <= 0.080
                    && abs(service.player.currentTime().seconds - Double(sample.frame) / 48_000) <= 0.080
                    && service.isVideoReady && !service.isLoading
                    && screen.customVideoLayer?.isReadyForDisplay == true
            }, "Releasing the real callback must produce a fresh selected and aligned custom frame with continued PCM")
            XCTAssertTrue(service.audioEngineRunning); XCTAssertTrue(service.wantsToPlay)
            XCTAssertEqual(service.audioSnapshot.underrunFrames, beforeReturn.underrunFrames)
            assertSelection(service, fixture: fixture, id: fixture.aID)
            await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "initial-ready-released-returned-A")
            let final = service.audioSnapshot
            XCTAssertEqual(final.token, aToken); XCTAssertEqual(final.visit, held.visit)
            XCTAssertGreaterThan(final.frame, held.frame)
            XCTAssertEqual(final.underrunFrames, beforeReturn.underrunFrames)
        }
        #else
        XCTFail("Initial-ready ordering controls require DEBUG hooks")
        #endif
    }

    func testReturnedVideoReadyBeforeFirstVisitDoesNotForceSourceVisitSeek() async throws {
        #if DEBUG
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer) { fixture, audio, service, screen in
            service.isInteractingWithFeed = true
            service.debugInitialLoadPhaseEnabled = true
            defer { service.debugInitialLoadPhaseEnabled = false }
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            var initialState: PlaybackService.DebugInitialVideoReadyState?
            var initialAudio: ContinuousPCMRenderer.Snapshot?
            var initialVideoReady = false, initialLoading = true
            var initialCustomReady: Bool?, initialBPrepared: Bool?
            var initialPreparedCount: Int?
            do {
                try await require({
                    let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                    initialState = state; initialAudio = sample
                    initialVideoReady = service.isVideoReady; initialLoading = service.isLoading
                    initialCustomReady = nil; initialPreparedCount = nil; initialBPrepared = nil
                    // Preserve the original short circuit: the native layer and
                    // buffer predicates are read only when their earlier guards pass.
                    guard sample.token > 0 && sample.frame > 2_400 && !sample.ended
                        && state.readyGeneration == state.generation && state.audioVisit == sample.visit
                        && state.syncingVideoGeneration == nil && initialVideoReady && !initialLoading else { return false }
                    let customReady = screen.customVideoLayer?.isReadyForDisplay == true
                    initialCustomReady = customReady
                    guard customReady else { return false }
                    let preparedCount = service.preparedAudioCount
                    initialPreparedCount = preparedCount
                    guard preparedCount == 2 else { return false }
                    let prepared = buffer.hasPrepared(fixture.bID)
                    initialBPrepared = prepared
                    return prepared
                }, "Initial A and prepared B must settle before the ready-before-visit control")
            } catch {
                let load = service.debugInitialLoadPhaseState
                print("InitialReadySetupFailure schema=1 currentGeneration=\(initialState.map { String($0.generation) } ?? "unknown") readyGeneration=\(initialState?.readyGeneration.map { String($0) } ?? "unknown") cachedVisit=\(initialState.map { String($0.audioVisit) } ?? "unknown") syncingGeneration=\(initialState?.syncingVideoGeneration.map { String($0) } ?? "unknown") token=\(initialAudio.map { String($0.token) } ?? "unknown") frame=\(initialAudio.map { String($0.frame) } ?? "unknown") visit=\(initialAudio.map { String($0.visit) } ?? "unknown") ended=\(initialAudio.map { String($0.ended) } ?? "unknown") videoReady=\(initialVideoReady) loading=\(initialLoading) customReady=\(initialCustomReady.map { String($0) } ?? "unread") preparedCount=\(initialPreparedCount.map { String($0) } ?? "unread") preparedB=\(initialBPrepared.map { String($0) } ?? "unread") loadEnabled=\(load.enabled) loadRequest=\(load.request) loadGeneration=\(load.generation) loadPhase=\(load.phase.rawValue)")
                throw error
            }
            let aToken = service.audioSnapshot.token
            assertSelection(service, fixture: fixture, id: fixture.aID)
            service.next()
            try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token != aToken
                && self.explicitInitialReadySourceSettled(service, screen: screen)
                && service.preparedAudioCount == 2 }, "Prepared B must settle before returning to A")
            assertSelection(service, fixture: fixture, id: fixture.bID)
            try await require({ buffer.previousMediaID == fixture.aID && buffer.debugPreviousNeedsRewind == false },
                              "Retained A must finish its real offscreen rewind before Previous")
            let before = service.audioSnapshot
            let oldVisit = service.debugInitialVideoReadyState.audioVisit
            XCTAssertEqual(oldVisit, before.visit)
            XCTAssertEqual(audio.selectedID, fixture.bID)
            XCTAssertEqual(audio.entry(for: fixture.aID)?.token, aToken)
            let request = service.debugInitialVideoReadyState.generation + 1
            let probe = SelectionInitialReadyOrderingProbe(generation: request)
            var holdAdoption = true, gateTimedOut = false, gateOverflow = false
            var blockedAttempts = 0
            let gateDeadline = ProcessInfo.processInfo.systemUptime + 3
            service.shouldDebugDeferAudioVisit = { generation in
                guard generation == request, holdAdoption else { return false }
                guard ProcessInfo.processInfo.systemUptime < gateDeadline else {
                    gateTimedOut = true; return false
                }
                if blockedAttempts < 128 { blockedAttempts += 1 }
                else { gateOverflow = true }
                return true
            }
            service.onDebugVideoSeekStamp = { stamp in probe.record(stamp) }
            defer {
                // Release before the existing owned preparation/decoder cleanup on every exit.
                holdAdoption = false
                service.shouldDebugDeferAudioVisit = nil
                service.onDebugVideoSeekStamp = nil
            }

            // Keep the real initial-ready callback unmodified and unheld. Only the
            // main-actor visit adoption is deferred; native PCM continues rendering A.
            service.previous()
            let readyBeforeVisit = await waitUntil(timeout: 1.5) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return blockedAttempts > 0 && !gateTimedOut && !gateOverflow
                    && state.generation == request && state.readyGeneration == request
                    && state.audioVisit == oldVisit && sample.token == aToken && sample.visit > oldVisit
                    && state.syncingVideoGeneration == nil && !sample.ended
                    && audio.selectedID == fixture.aID && service.wantsToPlay && service.audioEngineRunning
            }
            XCTAssertTrue(readyBeforeVisit,
                          "Real returned-A readiness must finish while only its first visit adoption is held")
            guard readyBeforeVisit else { throw SelectionVideoTestFailure.timeout }
            let readySample = service.audioSnapshot
            let progressedWhileHeld = await waitUntil(timeout: 0.75) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return !gateTimedOut && !gateOverflow && state.readyGeneration == request
                    && state.audioVisit == oldVisit && sample.token == aToken && sample.visit == readySample.visit
                    && sample.frame >= readySample.frame + 9_600 && !sample.ended
            }
            let held = service.audioSnapshot
            XCTAssertTrue(progressedWhileHeld, "Actual A PCM must continue for 200 ms before service visit adoption")
            XCTAssertEqual(held.underrunFrames, before.underrunFrames)
            XCTAssertFalse(gateTimedOut); XCTAssertFalse(gateOverflow)
            XCTAssertTrue(probe.reasons.isEmpty, "The qualified zero-start readiness must not require a seek")
            assertSelection(service, fixture: fixture, id: fixture.aID)
            guard progressedWhileHeld, !gateTimedOut, !gateOverflow else { throw SelectionVideoTestFailure.timeout }

            let submitted = service.submittedVideoFrameCount
            holdAdoption = false
            let adopted = await waitUntil(timeout: 1.5) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return state.generation == request && state.readyGeneration == request
                    && state.audioVisit == held.visit && sample.token == aToken && sample.visit == held.visit
                    && sample.frame > held.frame && !sample.ended
            }
            XCTAssertTrue(adopted, "The next real poll must acknowledge the exact held A visit after release")
            XCTAssertFalse(probe.reasons.contains(PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue),
                           "A ready zero-start must not be replaced by a forced seek on its first acknowledged visit")
            guard adopted else { throw SelectionVideoTestFailure.timeout }
            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                guard let frame = service.videoFramePositionSeconds,
                      let copied = service.copiedVideoFramePositionSeconds else { return false }
                return state.generation == request && state.readyGeneration == request
                    && state.audioVisit == held.visit && state.syncingVideoGeneration == nil
                    && sample.token == aToken && sample.visit == held.visit && !sample.ended
                    && sample.frame >= held.frame + 2_400 && service.submittedVideoFrameCount > submitted
                    && service.isVideoReady && !service.isLoading && screen.customVideoLayer?.isReadyForDisplay == true
                    && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                    && abs(frame - service.videoRequestedPositionSeconds) <= 0.080 && abs(copied - frame) <= 0.080
                    && abs(service.player.currentTime().seconds - Double(sample.frame) / 48_000) <= 0.080
            }, "The acknowledged visit must reveal fresh selected and aligned A frames with continued PCM")
            assertSelection(service, fixture: fixture, id: fixture.aID)
            await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "ready-before-first-visit-returned-A")
            let final = service.audioSnapshot
            probe.stopRecording()
            print("ReadyBeforeFirstVisitControl schema=1 request=\(request) readyBeforeVisit=\(readyBeforeVisit) oldVisit=\(oldVisit) heldVisit=\(held.visit) blockedAttempts=\(blockedAttempts) gateTimedOut=\(gateTimedOut) gateOverflow=\(gateOverflow) progressedWhileHeld=\(progressedWhileHeld) adopted=\(adopted) seekReasons=\(probe.reasons.map { String($0) }.joined(separator: ",")) dropped=\(probe.dropped) underrunDelta=\(final.underrunFrames - before.underrunFrames) latencyAcceptance=false heldAdoption=diagnostic-only")
            XCTAssertFalse(probe.reasons.contains(PlaybackService.DebugVideoSeekReason.sourceVisit.rawValue))
            XCTAssertEqual(probe.dropped, 0)
            XCTAssertEqual(final.token, aToken); XCTAssertEqual(final.visit, held.visit)
            XCTAssertFalse(final.ended); XCTAssertGreaterThan(final.frame, held.frame)
            XCTAssertEqual(final.underrunFrames, before.underrunFrames)
            XCTAssertEqual(audio.selectedID, fixture.aID)
            XCTAssertTrue(service.wantsToPlay); XCTAssertTrue(service.audioEngineRunning)
        }
        #else
        XCTFail("Ready-before-first-visit ordering controls require DEBUG hooks")
        #endif
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

    func testForegroundDoesNotSeekStaleVideoOwnerBeforeNaturalVisitAdoption() async throws {
        try recordRuntimeHost()
        #if DEBUG
        try await runForegroundVisitOwnershipControl(repeatOne: false)
        #else
        XCTFail("Forced foreground ownership controls require DEBUG hooks")
        #endif
    }

    func testForegroundCorrectsSameTokenLoopBeforeVisitAdoption() async throws {
        try recordRuntimeHost()
        #if DEBUG
        try await runForegroundVisitOwnershipControl(repeatOne: true)
        #else
        XCTFail("Forced foreground ownership controls require DEBUG hooks")
        #endif
    }

    #if DEBUG
    private func runForegroundVisitOwnershipControl(repeatOne: Bool) async throws {
        let buffer = PlaybackBuffer()
        try await withOwnedNaturalFixture(buffer: buffer, recordHost: false) { fixture, audio, service, screen in
            // Natural PCM succession must remain enabled; feed interaction would disable it.
            service.isInteractingWithFeed = false
            service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
            try await require({ self.explicitInitialReadySourceSettled(service, screen: screen)
                && service.preparedAudioCount == 2 && buffer.hasPrepared(fixture.bID) },
                "Real A readiness and both complete Saved PCM sources must precede the foreground control")
            assertSelection(service, fixture: fixture, id: fixture.aID)
            let itemA = try XCTUnwrap(service.player.currentItem)
            let aToken = try XCTUnwrap(audio.entry(for: fixture.aID)?.token)
            XCTAssertGreaterThan(aToken, 0)
            if repeatOne {
                service.cycleRepeat(); service.cycleRepeat()
                XCTAssertEqual(service.queue.repeatMode, .one)
                try await require({ buffer.hasPrepared(fixture.aID) && service.preparedAudioCount == 2
                    && self.explicitInitialReadySourceSettled(service, screen: screen) },
                    "Repeat-one must prepare its real same-source successor before crossing the boundary")
            } else {
                XCTAssertEqual(service.queue.repeatMode, .off)
            }
            let incomingID = repeatOne ? fixture.aID : fixture.bID
            let incomingToken = try XCTUnwrap(audio.entry(for: incomingID)?.token)
            XCTAssertGreaterThan(incomingToken, 0)
            if repeatOne { XCTAssertEqual(incomingToken, aToken) }
            else { XCTAssertNotEqual(incomingToken, aToken) }
            let request = service.debugInitialVideoReadyState.generation
            let beforeSeek = service.audioSnapshot
            XCTAssertEqual(beforeSeek.token, aToken)
            XCTAssertFalse(audio.isSelectionPending(in: beforeSeek))
            guard beforeSeek.visit <= Int64.max - 2 else {
                XCTFail("The real renderer visit must leave room for one explicit seek and one natural boundary")
                throw SelectionVideoTestFailure.timeout
            }
            let minimumNaturalVisit = beforeSeek.visit + 2
            let originalSources = (0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }
            let originalBytes = audio.renderer.retainedPCMMemoryBytes
            var holdAdoption = true, gateTimedOut = false, gateOverflow = false
            var blockedAttempts = 0
            var gateDeadline: Double?
            var foregroundSeeks: [PlaybackService.DebugVideoSeekStamp] = []
            foregroundSeeks.reserveCapacity(8)
            var droppedForegroundSeeks = 0
            service.shouldDebugDeferAudioVisit = { generation in
                guard holdAdoption, generation == request else { return false }
                let sample = service.audioSnapshot
                // Let the explicit far-seek acknowledgement proceed. Only the subsequent
                // real natural boundary is held, including repeat-one's unchanged token.
                guard sample.token == incomingToken, sample.visit >= minimumNaturalVisit,
                      sample.selectionVersion > beforeSeek.selectionVersion,
                      !audio.isSelectionPending(in: sample) else { return false }
                let now = ProcessInfo.processInfo.systemUptime
                if gateDeadline == nil { gateDeadline = now + 3 }
                guard now < (gateDeadline ?? now) else { gateTimedOut = true; return false }
                guard blockedAttempts < 128 else { gateOverflow = true; return false }
                blockedAttempts += 1
                return true
            }
            defer {
                // Release before the unchanged owned preparation/decoder acknowledgement helper.
                holdAdoption = false
                service.shouldDebugDeferAudioVisit = nil
                service.onDebugVideoSeekStamp = nil
            }

            // This is the existing natural control's cold far-seek setup budget,
            // separate from every existing 250 ms prepared-selection acceptance limit.
            service.seek(SelectionVideoFixture.duration - 2)
            let heldBoundary = await waitUntil(timeout: 10) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return blockedAttempts > 0 && !gateTimedOut && !gateOverflow
                    && state.generation == request && state.readyGeneration == request
                    && state.syncingVideoGeneration == nil && state.audioVisit < sample.visit
                    && service.queue.currentID == fixture.aID && audio.selectedID == fixture.aID
                    && service.player.currentItem === itemA && itemA.status == .readyToPlay
                    && sample.token == incomingToken && sample.visit >= minimumNaturalVisit
                    && sample.selectionVersion > beforeSeek.selectionVersion && sample.frame > 2_400
                    && !sample.ended && !audio.isSelectionPending(in: sample) && !service.isLoading && !service.audioOnly
                    && service.wantsToPlay && service.audioEngineRunning
            }
            XCTAssertTrue(heldBoundary,
                "The real natural renderer visit must advance while ready A and its selected metadata remain unadopted")
            guard heldBoundary else { throw SelectionVideoTestFailure.timeout }
            let firstHeld = service.audioSnapshot
            let progressedWhileHeld = await waitUntil(timeout: 0.75) {
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                return !gateTimedOut && !gateOverflow && state.generation == request
                    && state.readyGeneration == request && state.syncingVideoGeneration == nil
                    && state.audioVisit < sample.visit && sample.token == incomingToken
                    && sample.visit == firstHeld.visit && sample.selectionVersion == firstHeld.selectionVersion
                    && sample.frame >= firstHeld.frame + 9_600 && !sample.ended
                    && !audio.isSelectionPending(in: sample)
            }
            XCTAssertTrue(progressedWhileHeld, "Real PCM must continue for 200 ms while visit adoption alone is held")
            let held = service.audioSnapshot
            let heldState = service.debugInitialVideoReadyState
            let qualified = progressedWhileHeld && !gateTimedOut && !gateOverflow
                && heldState.generation == request && heldState.readyGeneration == request
                && heldState.syncingVideoGeneration == nil && heldState.audioVisit < held.visit
                && service.queue.currentID == fixture.aID && audio.selectedID == fixture.aID
                && service.player.currentItem === itemA && itemA.status == .readyToPlay
                && held.token == incomingToken && held.visit == firstHeld.visit
                && held.selectionVersion == firstHeld.selectionVersion && !held.ended
                && !audio.isSelectionPending(in: held) && !service.isLoading && !service.audioOnly
                && service.wantsToPlay && service.audioEngineRunning
            XCTAssertTrue(qualified, "The exact real owner mismatch or same-token loop must still qualify immediately before foreground")
            XCTAssertEqual(held.underrunFrames, firstHeld.underrunFrames)
            guard qualified else { throw SelectionVideoTestFailure.timeout }
            assertSelection(service, fixture: fixture, id: fixture.aID)
            service.onDebugVideoSeekStamp = { stamp in
                guard stamp.reason == .foreground else { return }
                if foregroundSeeks.count < 8 { foregroundSeeks.append(stamp) }
                else { droppedForegroundSeeks += 1 }
            }
            let foregroundEntry = ProcessInfo.processInfo.systemUptime
            service.enteredForeground()
            let foregroundReturn = ProcessInfo.processInfo.systemUptime
            service.onDebugVideoSeekStamp = nil
            let afterForeground = service.audioSnapshot
            let submitted = service.submittedVideoFrameCount
            holdAdoption = false
            service.shouldDebugDeferAudioVisit = nil
            let returnedWithinHold = gateDeadline.map { foregroundReturn < $0 } ?? false
            print("ForegroundVisitOwnershipDecision schema=1 repeatOne=\(repeatOne) request=\(request) qualified=\(qualified) selectedToken=\(aToken) renderedToken=\(held.token) renderedVisit=\(held.visit) renderedFrame=\(held.frame) selectionVersion=\(held.selectionVersion) cachedVisit=\(heldState.audioVisit) readyGeneration=\(heldState.readyGeneration.map { String($0) } ?? "missing") syncingGeneration=\(heldState.syncingVideoGeneration.map { String($0) } ?? "missing") blockedAttempts=\(blockedAttempts) foregroundSeeks=\(foregroundSeeks.count) targets=\(foregroundSeeks.map { String($0.requestedPosition) }.joined(separator: ",")) foregroundCallSeconds=\(foregroundReturn - foregroundEntry) returnedWithinHold=\(returnedWithinHold) latencyAcceptance=false heldAdoption=diagnostic-only")
            XCTAssertTrue(returnedWithinHold, "The foreground observation must finish inside the bounded adoption hold")
            XCTAssertEqual(afterForeground.token, held.token); XCTAssertEqual(afterForeground.visit, held.visit)
            XCTAssertEqual(afterForeground.selectionVersion, held.selectionVersion)
            XCTAssertGreaterThanOrEqual(afterForeground.frame, held.frame); XCTAssertFalse(afterForeground.ended)
            XCTAssertEqual(afterForeground.underrunFrames, held.underrunFrames)
            XCTAssertEqual(foregroundSeeks.count, repeatOne ? 1 : 0,
                repeatOne ? "A selected same-token natural loop must retain its legitimate forced correction"
                          : "Foreground must not seek stale A using the already-rendered B position")
            XCTAssertEqual(droppedForegroundSeeks, 0)
            for stamp in foregroundSeeks {
                XCTAssertEqual(stamp.request, request); XCTAssertEqual(stamp.generation, request)
                XCTAssertTrue(stamp.force); XCTAssertTrue(stamp.observedItemMatches)
                XCTAssertTrue(stamp.selectedMatchesQueue); XCTAssertTrue(stamp.presentationRequestMatches)
                XCTAssertNil(stamp.ordinaryDriftVideoPositionSeconds)
                XCTAssertNil(stamp.ordinaryDriftReadEntryNs); XCTAssertNil(stamp.ordinaryDriftReadReturnNs)
                XCTAssertTrue(stamp.requestedPosition.isFinite)
                XCTAssertGreaterThanOrEqual(stamp.requestedPosition, 0)
                XCTAssertLessThan(stamp.requestedPosition, SelectionVideoFixture.duration)
            }
            try await require({
                let state = service.debugInitialVideoReadyState, sample = service.audioSnapshot
                guard let frame = service.videoFramePositionSeconds,
                      let copied = service.copiedVideoFramePositionSeconds else { return false }
                guard service.queue.currentID == incomingID && audio.selectedID == incomingID
                    && state.readyGeneration == state.generation && state.syncingVideoGeneration == nil
                    && state.audioVisit == held.visit && sample.token == incomingToken && sample.visit == held.visit
                    && sample.frame >= held.frame + 2_400 && !sample.ended && !audio.isSelectionPending(in: sample)
                    && service.submittedVideoFrameCount > submitted && service.isVideoReady && !service.isLoading
                    && screen.customVideoLayer?.isReadyForDisplay == true
                    && frame.isFinite && copied.isFinite && frame >= 0 && copied >= 0
                    && abs(frame - service.videoRequestedPositionSeconds) <= 0.080 && abs(copied - frame) <= 0.080
                    else { return false }
                // Keep the native 80 ms guard, with a fresh renderer goal after
                // the one opaque native read. No SDK getter follows that goal.
                let nativePosition = service.player.currentTime().seconds
                let fresh = service.audioSnapshot
                return fresh.token == incomingToken && fresh.visit == held.visit
                    && fresh.selectionVersion == sample.selectionVersion && fresh.frame >= sample.frame
                    && fresh.underrunFrames == sample.underrunFrames && !fresh.ended
                    && nativePosition.isFinite
                    && abs(nativePosition - Double(fresh.frame) / 48_000) <= 0.080
            }, "Release must adopt the actual incoming source and reveal fresh aligned frames with continuing PCM")
            assertSelection(service, fixture: fixture, id: incomingID)
            await assertMovingVisibleVideo(service, screen: screen, identity: repeatOne ? .a : .b,
                label: repeatOne ? "foreground-same-token-loop-A" : "foreground-stale-A-adopted-B")
            let final = service.audioSnapshot
            XCTAssertEqual(final.token, incomingToken); XCTAssertEqual(final.visit, held.visit)
            XCTAssertGreaterThan(final.frame, held.frame); XCTAssertFalse(final.ended)
            XCTAssertEqual(final.underrunFrames, firstHeld.underrunFrames)
            XCTAssertTrue(service.wantsToPlay); XCTAssertTrue(service.audioEngineRunning)
            XCTAssertFalse(gateTimedOut); XCTAssertFalse(gateOverflow)
            XCTAssertGreaterThan(blockedAttempts, 0); XCTAssertLessThanOrEqual(blockedAttempts, 128)
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 3)
            XCTAssertLessThanOrEqual(service.preparedAudioCount, 3)
            XCTAssertEqual(originalBytes, 6_912_000)
            XCTAssertEqual(audio.renderer.retainedPCMMemoryBytes, originalBytes)
            XCTAssertEqual((0..<3).map { ObjectIdentifier(audio.renderer.source(at: $0)) }, originalSources)
            print("ForegroundVisitOwnershipControl schema=1 repeatOne=\(repeatOne) request=\(request) cachedVisit=\(heldState.audioVisit) renderedToken=\(held.token) renderedVisit=\(held.visit) selectionVersion=\(held.selectionVersion) blockedAttempts=\(blockedAttempts) gateTimedOut=\(gateTimedOut) gateOverflow=\(gateOverflow) foregroundSeeks=\(foregroundSeeks.count) droppedForegroundSeeks=\(droppedForegroundSeeks) foregroundCallSeconds=\(foregroundReturn - foregroundEntry) returnedWithinHold=\(returnedWithinHold) underrunDelta=\(final.underrunFrames - firstHeld.underrunFrames) latencyAcceptance=false heldAdoption=diagnostic-only")
        }
    }
    #endif


    func testNaturalBoundaryAtPositiveIncomingOffsetRevealsB() async throws {
        try await runNaturalBoundary(traceNativeLaneActivity: false)
    }

    func testNaturalBoundaryWithNativeLaneActivityRevealsB() async throws {
        try await runNaturalBoundary(traceNativeLaneActivity: true)
    }

    private func runNaturalBoundary(traceNativeLaneActivity: Bool) async throws {
        #if DEBUG
        var observations: [(probe: NaturalNativeRunwayProbe, reached: Bool)] = []
        if traceNativeLaneActivity { observations.reserveCapacity(2) }
        // Dump only after the existing owned cleanup has run. Stored endpoints,
        // not this later dump time, determine each phase's coverage.
        defer { for observation in observations { observation.probe.dumpAndAssert(reached: observation.reached) } }
        #endif
        try await withOwnedNaturalFixture(traceNativeLaneActivity: traceNativeLaneActivity) { fixture, audio, service, screen in
        #if DEBUG
        service.debugInitialLoadPhaseEnabled = traceNativeLaneActivity
        let preparationProbe = traceNativeLaneActivity
            ? NaturalNativeRunwayProbe(phase: "initial-preparation", minimumFailureSeconds: nil) : nil
        preparationProbe?.sample(audio: audio, service: service, renderer: service.audioSnapshot, force: true)
        #endif
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        // Same predicate and three-second deadline as the original require call.
        // This known failed guard must not throw through teardown before its state
        // can be captured. Unrelated thrown errors retain the existing rethrow path.
        let prepared = await waitUntil(timeout: 3) {
            let sample = service.audioSnapshot
            #if DEBUG
            preparationProbe?.sample(audio: audio, service: service, renderer: sample)
            #endif
            return sample.frame > 2_400 && service.preparedAudioCount == 2
        }
        #if DEBUG
        preparationProbe?.sample(audio: audio, service: service, renderer: service.audioSnapshot, force: true)
        if let preparationProbe { observations.append((preparationProbe, prepared)) }
        #endif
        guard prepared else {
            XCTFail("Both complete Saved sources must be ready")
            #if DEBUG
            await recordNaturalRunwayFailure(audio: audio,
                expectedToken: audio.entry(for: fixture.aID)?.token ?? 0, stage: "initial-preparation")
            #endif
            return
        }
        let aToken = service.audioSnapshot.token
        let seekPosition = SelectionVideoFixture.duration - 2
        #if DEBUG
        let nativeProbe = traceNativeLaneActivity
            ? NaturalNativeRunwayProbe(phase: "seek-runway", minimumFailureSeconds: 9.5) : nil
        nativeProbe?.sample(audio: audio, service: service, renderer: service.audioSnapshot, force: true)
        #endif
        service.seek(seekPosition)
        // A far seek rebuilds the decoder's original history. Observe real progress with
        // two seconds of runway instead of requiring the main actor to catch A's final
        // 250 ms. A completed natural transition is also valid if scheduling skipped A.
        // This is cold far-seek setup, not a prepared-transition latency limit.
        let reachedRunway = await waitUntil(timeout: 10) {
            let sample = service.audioSnapshot
            #if DEBUG
            nativeProbe?.sample(audio: audio, service: service, renderer: sample)
            #endif
            return sample.token == aToken && sample.frame >= Int64((seekPosition + 0.05) * 48_000)
                || sample.token != 0 && sample.token != aToken && sample.frame > 0
        }
        let sample = service.audioSnapshot
        print("SelectionBoundary phase=runway reached=\(reachedRunway) sourceA=\(sample.token == aToken) frame=\(sample.frame) visit=\(sample.visit) underrunFrames=\(sample.underrunFrames) engineRunning=\(service.audioEngineRunning) wantsToPlay=\(service.wantsToPlay) position=\(service.clock.position) duration=\(service.clock.duration)")
        #if DEBUG
        nativeProbe?.sample(audio: audio, service: service, renderer: sample, force: true)
        if let nativeProbe { observations.append((nativeProbe, reachedRunway)) }
        #endif
        guard reachedRunway else {
            // Keep this an assertion failure, with the original numeric evidence,
            // instead of throwing a setup error through deferred fixture cleanup.
            XCTFail("The real renderer must reach the seek runway or naturally enter B")
            #if DEBUG
            await recordNaturalRunwayFailure(audio: audio, expectedToken: aToken)
            #endif
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
    }

    /// Cleanup runs on normal return and on a retained original error. File removal
    /// requires both existing acknowledgements; failure retains only this fixture.
    private func withOwnedNaturalFixture(traceNativeLaneActivity: Bool = false, buffer: PlaybackBuffer? = nil, recordHost: Bool = true, _ body: @MainActor (SelectionVideoFixture, ContinuousAudioPlayer,
        PlaybackService, SelectionVideoScreen) async throws -> Void) async throws {
        if recordHost { try recordRuntimeHost() }
        guard !Self.targetedFixtureOwnershipLost else {
            XCTFail("A previous targeted fixture did not acknowledge cleanup; no new owners may be created")
            throw SelectionVideoTestFailure.timeout
        }
        let fixture = try await SelectionVideoFixture()
        #if DEBUG
        let activity = traceNativeLaneActivity ? ContinuousPCMDecoder.DebugNativeLaneActivityRecorder() : nil
        let audio = ContinuousAudioPlayer(debugNativeLaneActivityRecorder: activity)
        #else
        let audio = ContinuousAudioPlayer()
        #endif
        let service = fixture.service(buffer: buffer, continuousAudio: audio)
        var screen: SelectionVideoScreen?
        var originalError: Error?
        do {
            let created = try SelectionVideoScreen(service: service)
            screen = created
            try await body(fixture, audio, service, created)
        } catch { originalError = error }
        service.pause(); audio.graph.engine.stop(); screen?.close()
        #if DEBUG
        let preparation = ProductionSelectionShutdown()
        let decoder = ProductionSelectionShutdown()
        service.debugStopPreparation { preparation.complete(true) }
        audio.debugShutdown { decoder.complete($0) }
        let returned = await waitUntil(timeout: 3) { preparation.result != nil && decoder.result != nil }
        let canRemove = returned && preparation.result == true && decoder.result == true
        print("NaturalFixtureCleanup schema=1 ownedTasksJoined=\(preparation.result == true) decoderClosed=\(decoder.result == true) removeAllowed=\(canRemove) originalErrorRetained=\(originalError != nil) syntheticFilesRetained=\(!canRemove) sdkInternalQuiescence=unverified olderCancelledTasks=unverified")
        XCTAssertTrue(canRemove, "Owned task and decoder close acknowledgements must precede synthetic file removal")
        if canRemove { fixture.remove() }
        else { Self.targetedFixtureOwnershipLost = true; fixture.restorePreferences() }
        #else
        fixture.remove()
        #endif
        if let originalError { throw originalError }
    }

    #if DEBUG
    /// Independent main-actor observation, at most 128 records of three lane words.
    /// No sampler task, worker request, SDK query or decode-path clock is added.
    @MainActor private final class NaturalNativeRunwayProbe {
        struct Sample {
            let begin: UInt64
            let end: UInt64
            let renderer: ContinuousPCMRenderer.Snapshot
            let lanes: [ContinuousPCMDecoder.DebugNativeLaneActivitySnapshot?]
            let load: PlaybackService.DebugInitialLoadPhaseState
        }
        private let origin = DispatchTime.now().uptimeNanoseconds
        private let phase: String
        private let minimumFailureSeconds: Double?
        private var samples: [Sample] = []
        private var dropped = 0
        init(phase: String, minimumFailureSeconds: Double?) {
            self.phase = phase; self.minimumFailureSeconds = minimumFailureSeconds
            samples.reserveCapacity(128)
        }
        func sample(audio: ContinuousAudioPlayer, service: PlaybackService, renderer: ContinuousPCMRenderer.Snapshot, force: Bool = false) {
            let begin = DispatchTime.now().uptimeNanoseconds
            if !force, let last = samples.last, begin - last.begin < 100_000_000 { return }
            guard samples.count < 128 else { dropped += 1; return }
            let lanes = (0..<3).map { audio.debugNativeLaneActivitySnapshot(at: $0) }
            let load = service.debugInitialLoadPhaseState
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Sample(begin: begin, end: end, renderer: renderer, lanes: lanes, load: load))
        }
        func dumpAndAssert(reached: Bool) {
            let gaps = zip(samples, samples.dropFirst()).map { Double($1.begin - $0.begin) / 1_000_000_000 }
            let acquisition = samples.map { Double($0.end - $0.begin) / 1_000_000_000 }.max() ?? .infinity
            let first = samples.first.map { Double($0.begin - origin) / 1_000_000_000 } ?? .infinity
            let elapsed = samples.last.map { Double($0.end - origin) / 1_000_000_000 } ?? -1
            print("NaturalNativeActivityCoverage schema=1 phase=\(phase) reached=\(reached) samples=\(samples.count) capacity=128 lanes=3 dropped=\(dropped) firstMs=\(first * 1000) observedSeconds=\(elapsed) maximumGapMs=\((gaps.max() ?? 0) * 1000) maximumAcquisitionMs=\(acquisition * 1000) cadenceMs=100 rendererAndLanesCoherent=false hotClocks=false internalSDKCause=unestablished")
            XCTAssertGreaterThan(samples.count, 0); XCTAssertLessThanOrEqual(samples.count, 128)
            XCTAssertEqual(dropped, 0); XCTAssertLessThanOrEqual(first, 0.25)
            XCTAssertLessThanOrEqual(gaps.max() ?? 0, 0.25); XCTAssertLessThanOrEqual(acquisition, 0.005)
            if !reached, let minimumFailureSeconds { XCTAssertGreaterThanOrEqual(elapsed, minimumFailureSeconds) }
            for (ordinal, sample) in samples.enumerated() {
                XCTAssertEqual(sample.lanes.count, 3)
                print("NaturalNativeActivityRenderer schema=1 phase=\(phase) ordinal=\(ordinal) beginNs=\(sample.begin) endNs=\(sample.end) token=\(sample.renderer.token) visit=\(sample.renderer.visit) frame=\(sample.renderer.frame) underrunFrames=\(sample.renderer.underrunFrames) selectionVersion=\(sample.renderer.selectionVersion) coherence=renderer-only-before-lane-reads")
                print("NaturalInitialLoadPhase schema=1 phase=\(phase) ordinal=\(ordinal) enabled=\(sample.load.enabled) request=\(sample.load.request) generation=\(sample.load.generation) code=\(sample.load.phase.rawValue) current=\(sample.load.enabled && sample.load.request == sample.load.generation) coherence=main-actor-cached-after-independent-lane-reads sdkInternalCause=unestablished")
                for (index, lane) in sample.lanes.enumerated() {
                    XCTAssertNotNil(lane)
                    if let lane {
                        XCTAssertEqual(lane.laneIndex, index); XCTAssertFalse(lane.sequenceOverflowed)
                        print("NaturalNativeActivity schema=1 phase=\(phase) ordinal=\(ordinal) lane=\(lane.laneIndex) packedState=\(lane.packedState) copySequence=\(lane.copySequence) stage=\(lane.stageCode) overflowed=\(lane.sequenceOverflowed) coherence=one-packed-word")
                    }
                }
            }
        }
    }

    private func naturalFailureEndpoints(audio: ContinuousAudioPlayer, phase: String, expectedToken: Int) -> [String] {
        let sample = audio.snapshot
        let selection = audio.debugSelectionState
        var rows = ["NaturalFailureRenderer schema=1 phase=\(phase) expectedToken=\(expectedToken) token=\(sample.token) frame=\(sample.frame) visit=\(sample.visit) ended=\(sample.ended) underrunFrames=\(sample.underrunFrames) selectionVersion=\(sample.selectionVersion) selectedToken=\(selection.selectedToken) pendingVersion=\(selection.pendingVersion.map { String($0) } ?? "none") selectionPending=\(audio.isSelectionPending(in: sample))"]
        rows.reserveCapacity(4)
        for index in 0..<3 {
            let source = audio.renderer.source(at: index)
            let token = source.token
            let request = source.streamRequest
            let ready = source.availableStreamFrames(for: request.epoch)
            let writable = source.writableStreamFrames
            let after = source.streamRequest
            let tokenAfter = source.token
            rows.append("NaturalFailureSource schema=1 phase=\(phase) slot=\(index) token=\(token) tokenAfter=\(tokenAfter) epoch=\(request.epoch) startFrame=\(request.startFrame) epochAfter=\(after.epoch) startAfter=\(after.startFrame) requestStable=\(request == after && token == tokenAfter) readyFrames=\(ready) writableFrames=\(writable) totalFrames=\(source.totalFrames) prefixFrames=\(source.prefixFrameCount) coherence=individual-accessors")
        }
        return rows
    }

    private func recordNaturalRunwayFailure(audio: ContinuousAudioPlayer, expectedToken: Int, stage: String = "seek-runway") async {
        // Called only after the unchanged preparation or runway guard has failed.
        let before = naturalFailureEndpoints(audio: audio, phase: stage + "-before-worker", expectedToken: expectedToken)
        let mailbox = NaturalFailureStateMailbox()
        audio.debugDecoderFailureState { mailbox.complete($0) }
        let returned = await waitUntil(timeout: 1) { mailbox.result != nil }
        let state = mailbox.result
        let after = naturalFailureEndpoints(audio: audio, phase: stage + "-after-worker", expectedToken: expectedToken)
        for row in before { print(row) }
        print("NaturalFailureWorker schema=1 stage=\(stage) returnedWithinOneSecond=\(returned) snapshotAvailable=\(state != nil) nativePhaseAvailable=false sdkWaitEstablished=false")
        if let state {
            let stats = state.stats
            print("NaturalFailureWorkerStats schema=1 leased=\(stats.leasedReaders) peakLeased=\(stats.peakLeasedReaders) retired=\(stats.retiredLeasesAwaitingClose) starting=\(stats.startingLeases) preparations=\(stats.pendingPreparations) pendingReads=\(stats.readJobsAwaitingAcceptanceOrClose) packets=\(stats.mailboxPackets) occupiedPackets=\(stats.pendingOrMailboxPacketSlots) overflowed=\(stats.counterOverflowed) shutdown=\(stats.shutdownRequested) closed=\(stats.readerLeasesClosed) preparationTokens=\(state.preparationTokens.map { String($0) }.joined(separator: ",")) coherence=worker-owned-fields")
            for slot in state.slots {
                print("NaturalFailureSlot schema=1 slot=\(slot.index) token=\(slot.token) workerEpoch=\(slot.epoch) finished=\(slot.finished) cancelled=\(slot.cancelled) lease=\(slot.leaseIndex) hasStream=\(slot.stream != nil) coherence=worker-owned-fields")
                if let stream = slot.stream {
                    print("NaturalFailureStream schema=1 slot=\(slot.index) cursor=\(stream.cursor) generatedFrames=\(stream.generatedFrames) outputStart=\(stream.outputStart) outputCount=\(stream.outputCount) converterFinished=\(stream.converterFinished) eof=\(stream.reachedEnd) coherence=worker-owned-fields")
                }
            }
            for lease in state.leases {
                print("NaturalFailureLease schema=1 lane=\(lease.index) present=\(lease.present) starting=\(lease.starting) readPending=\(lease.readPending) retired=\(lease.retired) demandFrames=\(lease.requestedFrames) packetFrames=\(lease.packetFrames) packetOffset=\(lease.packetOffset) eof=\(lease.reachedEnd) hasFailure=\(lease.hasFailure) coherence=worker-owned-fields")
            }
        }
        for row in after { print(row) }
    }
    #endif

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

    func testWaitUntilLatchesSuccessAndPreservesDeadlineAndCancellation() async {
        var successCalls = 0
        let succeeded = await waitUntil(timeout: 0.25) {
            successCalls += 1
            return successCalls == 2 // Script: false, true, false.
        }
        XCTAssertTrue(succeeded, "A valid sample must latch without another predicate/SDK evaluation")
        XCTAssertEqual(successCalls, 2)

        for wouldBecomeTrue in [false, true] {
            var deadlineCalls = 0
            let expired = await waitUntil(timeout: 0) {
                deadlineCalls += 1
                return wouldBecomeTrue && deadlineCalls > 1
            }
            XCTAssertFalse(expired, "A false sample at the deadline is final, even if a second call would pass")
            XCTAssertEqual(deadlineCalls, 1)
        }

        let cancelled = await Task { @MainActor in
            var calls = 0
            let result = await self.waitUntil(timeout: 1) {
                calls += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            }
            return (result, calls)
        }.value
        XCTAssertFalse(cancelled.0, "Cancellation of the poll sleep must return false")
        XCTAssertEqual(cancelled.1, 1, "Cancellation must not cause a second predicate/SDK evaluation")
    }

    private func waitUntil(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if condition() { return true }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
    }
}

/// Both benchmarks retain three predicate summaries; only the existing traced
/// benchmark receives up to 32 default-off DEBUG service stamps. Main actor only.
@MainActor
private final class ProductionVideoStartupTrace {
    struct Poll { let uptime: Double; let readyLatched: Bool; let mask: UInt16; let evaluated: UInt16 }
    let serviceTracing: Bool
    var phase = 0
    private var layerReady: Bool?
    private var lastPolls = [Poll?](repeating: nil, count: 3)
    private var finalMasks = [UInt16?](repeating: nil, count: 3)
    private var badPhase = false
    #if DEBUG
    private enum Event {
        case startup(Int, PlaybackService.DebugVideoStartupStamp)
        case seek(Int, UInt64, PlaybackService.DebugVideoSeekStamp)
    }
    private var events: [Event] = []
    private var dropped = 0, overflow = false
    // Three phases x three seek regions x nine first-only scalar stages. No item/image ownership.
    private var renderSlots: [PlaybackService.DebugVideoRenderStamp?] = []
    private var renderConflicts = 0, renderOwnershipFailures = 0
    #endif
    init(serviceTracing: Bool) {
        self.serviceTracing = serviceTracing
        #if DEBUG
        if serviceTracing {
            events.reserveCapacity(32)
            renderSlots = Array(repeating: nil, count: 81)
        }
        #endif
    }
    func beginPoll() { layerReady = nil }
    func observeLayerReady(_ value: Bool) -> Bool { layerReady = value; return value }
    private func predicates(_ state: ProductionSelectionState, beforeVisit: Int64, beforeSubmitted: UInt64) -> UInt16 {
        var result: UInt16 = 0
        if state.selected { result |= 1 << 0 }
        if state.audio.visit > beforeVisit { result |= 1 << 1 }
        if state.submitted > beforeSubmitted { result |= 1 << 2 }
        if layerReady == true { result |= 1 << 3 }
        if let frame = state.frame, let copied = state.copied,
           frame.isFinite, copied.isFinite, state.requested.isFinite, frame >= 0, copied >= 0 {
            result |= 1 << 4
            if abs(frame - state.requested) <= 0.080 { result |= 1 << 5 }
            if abs(copied - frame) <= 0.080 { result |= 1 << 6 }
        }
        if state.videoReady { result |= 1 << 7 }
        if !state.loading { result |= 1 << 8 }
        return result
    }
    func recordPoll(uptime: Double, readyLatched: Bool, state: ProductionSelectionState,
                    beforeVisit: Int64, beforeSubmitted: UInt64) {
        guard (0..<3).contains(phase) else { badPhase = true; return }
        lastPolls[phase] = Poll(uptime: uptime, readyLatched: readyLatched,
            mask: predicates(state, beforeVisit: beforeVisit, beforeSubmitted: beforeSubmitted),
            evaluated: layerReady == nil ? 503 : 511)
    }
    func finishPhase(state: ProductionSelectionState, beforeVisit: Int64, beforeSubmitted: UInt64) {
        guard (0..<3).contains(phase) else { badPhase = true; return }
        layerReady = nil // No second custom-layer query at the terminal snapshot.
        finalMasks[phase] = predicates(state, beforeVisit: beforeVisit, beforeSubmitted: beforeSubmitted)
    }
    #if DEBUG
    private func append(_ event: Event) {
        guard serviceTracing, events.count < 32 else {
            if dropped < Int.max { dropped += 1 } else { overflow = true }
            return
        }
        events.append(event)
    }
    func record(_ stamp: PlaybackService.DebugVideoStartupStamp) { append(.startup(phase, stamp)) }
    func recordSeek(_ stamp: PlaybackService.DebugVideoSeekStamp) {
        guard serviceTracing else { return }
        append(.seek(phase, DispatchTime.now().uptimeNanoseconds, stamp))
    }
    func recordRender(_ stamp: PlaybackService.DebugVideoRenderStamp) {
        guard serviceTracing, (0..<3).contains(phase), (0..<3).contains(stamp.render.region),
              (0..<9).contains(stamp.render.stage.rawValue) else { badPhase = true; return }
        let index = phase * 27 + stamp.render.region * 9 + stamp.render.stage.rawValue
        guard renderSlots[index] == nil else {
            if renderConflicts < Int.max { renderConflicts += 1 } else { overflow = true }
            return
        }
        renderSlots[index] = stamp
        if stamp.render.ticket == nil || !stamp.render.ownershipUnchanged || !stamp.presentationMatches {
            if renderOwnershipFailures < Int.max { renderOwnershipFailures += 1 } else { overflow = true }
        }
    }
    private func dumpRenderRows() {
        print("ProductionSelectionRenderSummary schema=1 enabled=\(serviceTracing) phases=3 regions=3 stages=9 capacity=81 conflicts=\(renderConflicts) ownershipFailures=\(renderOwnershipFailures) storage=scalar-first-only")
        guard serviceTracing else { return }
        for phase in 0..<3 {
            var observedCopy = false, observedEnqueue = false
            for region in 0..<3 {
                // A missing stage is unavailable, never a false SDK result or proof of idle.
                let offset = phase * 27 + region * 9
                var observedMask: UInt16 = 0
                for stage in 0..<9 where renderSlots[offset + stage] != nil { observedMask |= UInt16(1) << stage }
                print("ProductionSelectionRenderRegion schema=1 phase=\(phase) region=\(region) observedMask=\(observedMask) firstSeekOnly=true")
                for stage in 0..<9 {
                    guard let s = renderSlots[offset + stage] else { continue }
                    if stage == 3 { observedCopy = true }
                    if stage == 4 { observedEnqueue = true }
                    let r = s.render
                    print("ProductionSelectionRenderStage schema=1 phase=\(phase) region=\(region) stage=\(stage) entryNs=\(r.entryNs) returnNs=\(r.returnNs) presentationRevision=\(r.presentationRevision) ownershipUnchanged=\(r.ownershipUnchanged) nativeSeekTicket=\(r.nativeSeekTicket.map { String($0) } ?? "unknown") request=\(s.presentationRequest.map { String($0) } ?? "unknown") generation=\(s.generation) presentationMatches=\(s.presentationMatches) token=\(s.audioToken) visit=\(s.audioVisit) requested=\(r.requestedSeconds.map { String($0) } ?? "unknown") samplePTS=\(r.sampleSeconds.map { String($0) } ?? "unknown") cachedCopiedPTS=\(r.copiedPTS.map { String($0) } ?? "unknown") cachedSubmittedPTS=\(r.submittedPTS.map { String($0) } ?? "unknown") submittedCount=\(r.submittedCount) resourceOwnership=\(r.resourceOwnership)")
                }
            }
            XCTAssertTrue(observedCopy, "The traced selection must retain its actual copy observation")
            XCTAssertTrue(observedEnqueue, "The traced selection must retain its actual enqueue observation")
        }
    }
    #endif
    func dumpAndAssert() {
        for phase in 0..<3 {
            if let poll = lastPolls[phase] {
                print("ProductionSelectionReadyPredicates schema=1 phase=\(phase) lastPollEntryUptime=\(poll.uptime) readyLatched=\(poll.readyLatched) lastPollMask=\(poll.mask) lastPollEvaluatedMask=\(poll.evaluated) terminalMask=\(finalMasks[phase].map { String($0) } ?? "unknown") terminalEvaluatedMask=503 allTrueMask=511 serviceTracing=\(serviceTracing)")
            }
        }
        XCTAssertFalse(badPhase)
        #if DEBUG
        print("ProductionSelectionStartupSummary schema=1 enabled=\(serviceTracing) events=\(events.count) capacity=32 dropped=\(dropped) overflow=\(overflow)")
        for (ordinal, event) in events.enumerated() {
            switch event {
            case .startup(let phase, let s):
                print("ProductionSelectionStartup schema=1 ordinal=\(ordinal) phase=\(phase) kind=\(s.kind.rawValue) request=\(s.request) entryGeneration=\(s.entryGeneration) returnGeneration=\(s.returnGeneration) entryNs=\(s.entryNs) returnNs=\(s.returnNs) presentationRequest=\(s.presentationRequest.map { String($0) } ?? "unknown") presentationUnchanged=\(s.presentationUnchanged) token=\(s.audioToken) visit=\(s.audioVisit) readyGeneration=\(s.readyGeneration.map { String($0) } ?? "unknown") entryVideoReady=\(s.entryVideoReady) returnVideoReady=\(s.returnVideoReady) entryLoading=\(s.entryLoading) returnLoading=\(s.returnLoading) timelineInstalled=\(s.timelineInstalled) anchorHostSeconds=\(s.anchorHostSeconds.map { String($0) } ?? "unknown") anchorPosition=\(s.anchorPosition.map { String($0) } ?? "unknown")")
            case .seek(let phase, let seenNs, let s):
                print("ProductionSelectionStartupSeekOrder schema=1 ordinal=\(ordinal) phase=\(phase) observedNs=\(seenNs) reason=\(s.reason.rawValue) request=\(s.request) generation=\(s.generation) nativeSeekTicket=\(s.nativeSeekTicket) force=\(s.force) ordinaryDriftReadEntryNs=\(s.ordinaryDriftReadEntryNs.map { String($0) } ?? "unknown") ordinaryDriftReadReturnNs=\(s.ordinaryDriftReadReturnNs.map { String($0) } ?? "unknown") ordinaryDriftReadSpanNs=\(s.ordinaryDriftReadEntryNs.flatMap { begin in s.ordinaryDriftReadReturnNs.flatMap { end in end >= begin ? String(end - begin) : nil } } ?? "unknown")")
            }
        }
        XCTAssertEqual(dropped, 0); XCTAssertFalse(overflow)
        dumpRenderRows()
        XCTAssertEqual(renderConflicts, 0); XCTAssertEqual(renderOwnershipFailures, 0)
        #endif
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
    let commandReturnHostSeconds: Double
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
        #if DEBUG
        let nativeTraceEnabled: Bool
        let lane0: ContinuousPCMDecoder.DebugNativeLaneActivitySnapshot?
        let lane1: ContinuousPCMDecoder.DebugNativeLaneActivitySnapshot?
        let lane2: ContinuousPCMDecoder.DebugNativeLaneActivitySnapshot?
        let renderAccounting: ContinuousPCMRenderer.DebugRenderAccountingSnapshot?
        #endif
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

    #if DEBUG
    private let nativeTrace: ProductionNativeRefillTrace?
    private let nativePhase: Int
    private let nativeExpectedToken: Int
    private let nativeCommandUnderruns: Int64
    private let renderAccounting: ContinuousPCMRenderer.DebugRenderAccountingRecorder?
    init(renderer: ContinuousPCMRenderer, nativeTrace: ProductionNativeRefillTrace? = nil,
         nativePhase: Int = -1, nativeExpectedToken: Int = 0, nativeCommandUnderruns: Int64 = 0,
         renderAccounting: ContinuousPCMRenderer.DebugRenderAccountingRecorder? = nil) {
        self.renderer = renderer
        self.nativeTrace = nativeTrace
        self.nativePhase = nativePhase; self.nativeExpectedToken = nativeExpectedToken
        self.nativeCommandUnderruns = nativeCommandUnderruns
        self.renderAccounting = renderAccounting
        samples.reserveCapacity(128)
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test.production-render-sampler", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }
    #else
    init(renderer: ContinuousPCMRenderer) {
        self.renderer = renderer
        samples.reserveCapacity(128)
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test.production-render-sampler", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }
    #endif

    private func sample() {
        let begin = DispatchTime.now().uptimeNanoseconds
        guard begin >= origin, begin - origin < 8_000_000_000 else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        acquiring = true
        #if DEBUG
        let firstWindowSample = samples.isEmpty
        #endif
        lock.unlock()
        let audio = renderer.snapshot
        #if DEBUG
        let lane0 = nativeTrace?.recorder.snapshot(at: 0)
        let lane1 = nativeTrace?.recorder.snapshot(at: 1)
        let lane2 = nativeTrace?.recorder.snapshot(at: 2)
        let accounting = renderAccounting?.snapshot()
        #endif
        let end = DispatchTime.now().uptimeNanoseconds
        #if DEBUG
        var requestFromStoredWindowSample = false
        #endif
        lock.lock()
        acquiring = false
        if !stopped {
            if samples.count < 128 {
                #if DEBUG
                samples.append(Sample(begin: begin, end: end, audio: audio,
                    nativeTraceEnabled: nativeTrace != nil, lane0: lane0, lane1: lane1, lane2: lane2,
                    renderAccounting: accounting))
                requestFromStoredWindowSample = end >= origin && end - origin < 8_000_000_000
                #else
                samples.append(Sample(begin: begin, end: end, audio: audio))
                #endif
            }
            else { dropped += 1 }
        }
        lock.unlock()
        #if DEBUG
        // Stop/drop/late acquisitions cannot trigger a request. A retained
        // pre-stop observation may still deliver its async response after stop;
        // request/reply times and nonjoint coherence qualify that later state.
        if requestFromStoredWindowSample {
            nativeTrace?.observeFirstUnderrun(audio, renderer: renderer, phase: nativePhase, expectedToken: nativeExpectedToken,
                commandUnderruns: nativeCommandUnderruns, firstWindowSample: firstWindowSample,
                observationBegin: begin, observationEnd: end)
        }
        #endif
    }

    func stop() -> Result {
        timer.cancel()
        lock.lock(); defer { lock.unlock() }
        stopped = true
        return Result(origin: origin, samples: samples, dropped: dropped, acquisitionOutstanding: acquiring)
    }
}

#if DEBUG
/// One arm-owned failure request/response, shared by its three existing probes.
/// No producer sampling task, native getter, media reference or per-call history.
private final class ProductionNativeRefillTrace: @unchecked Sendable {
    private struct SourceEndpoint: Sendable {
        let slot: Int, token: Int, tokenAfter: Int
        let prefixFrames: Int, availableRaw: Int, writableRaw: Int
        let totalFrames: Int64
    }
    let recorder: ContinuousPCMDecoder.DebugNativeLaneActivityRecorder
    @MainActor private weak var audio: ContinuousAudioPlayer?
    private let lock = NSLock()
    private var requested = false, issued = false
    private var observationBegin: UInt64 = 0, observationEnd: UInt64 = 0
    private var enqueueNs: UInt64 = 0, issueNs: UInt64 = 0, replyNs: UInt64 = 0
    private var phase = -1
    private var token = 0
    private var visit: Int64 = 0, frame: Int64 = 0, underruns: Int64 = 0, commandUnderruns: Int64 = 0
    private var firstWindowSample = false
    private var sourceBeginNs: UInt64 = 0, sourceEndNs: UInt64 = 0
    private var sources: [SourceEndpoint] = [] // One fixed three-source endpoint, not a history.
    private var response: ContinuousPCMDecoder.DebugFailureState?

    @MainActor init(recorder: ContinuousPCMDecoder.DebugNativeLaneActivityRecorder, audio: ContinuousAudioPlayer) {
        self.recorder = recorder
        self.audio = audio
    }

    func observeFirstUnderrun(_ value: ContinuousPCMRenderer.Snapshot, renderer: ContinuousPCMRenderer,
                             phase: Int, expectedToken: Int,
                             commandUnderruns: Int64, firstWindowSample: Bool,
                             observationBegin: UInt64, observationEnd: UInt64) {
        guard phase == 1 || phase == 2, expectedToken > 0, value.token == expectedToken,
              !value.ended, value.underrunFrames > commandUnderruns else { return }
        lock.lock()
        guard !requested else { lock.unlock(); return }
        requested = true
        self.observationBegin = observationBegin; self.observationEnd = observationEnd
        self.phase = phase; self.firstWindowSample = firstWindowSample
        token = value.token; visit = value.visit; frame = value.frame; underruns = value.underrunFrames
        self.commandUnderruns = commandUnderruns
        sourceBeginNs = DispatchTime.now().uptimeNanoseconds
        sources.reserveCapacity(3)
        for index in 0..<3 {
            let source = renderer.source(at: index)
            let before = source.token
            let total = source.totalFrames, prefix = source.prefixFrameCount
            let available = source.availableStreamFrames, writable = source.writableStreamFrames
            let after = source.token
            sources.append(SourceEndpoint(slot: index, token: before, tokenAfter: after,
                prefixFrames: prefix, availableRaw: available, writableRaw: writable, totalFrames: total))
        }
        sourceEndNs = DispatchTime.now().uptimeNanoseconds
        enqueueNs = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        // One task per arm, only after a real positive underrun. No wait in the
        // observation window; failure of main/worker delivery stays explicit.
        Task { @MainActor [weak self] in
            guard let self, let audio = self.audio else { return }
            self.markIssued()
            audio.debugDecoderFailureState { [weak self] state in
                guard let self else { return }
                self.storeResponse(state)
            }
        }
    }

    private func markIssued() {
        lock.lock(); issued = true; issueNs = DispatchTime.now().uptimeNanoseconds; lock.unlock()
    }

    private func storeResponse(_ state: ContinuousPCMDecoder.DebugFailureState) {
        lock.lock(); response = state; replyNs = DispatchTime.now().uptimeNanoseconds; lock.unlock()
    }

    func dumpAfterCleanup() {
        lock.lock()
        let requestObserved = requested, requestIssued = issued, state = response
        let begin = observationBegin, end = observationEnd
        let requestEnqueueNs = enqueueNs, requestIssueNs = issueNs, workerReplyNs = replyNs
        let triggerPhase = phase, triggerToken = token, triggerVisit = visit, triggerFrame = frame
        let triggerUnderruns = underruns, commandBaseline = commandUnderruns, positiveAtFirstSample = firstWindowSample
        let sourceRecords = sources, sourcesBegin = sourceBeginNs, sourcesEnd = sourceEndNs
        lock.unlock()
        print("ProductionNativeRefillScope schema=1 enabled=true lanes=3 windows=3 maximumSamplesPerWindow=128 intervalMs=100 windowSeconds=8 failureRequestsPerArm=1 failurePriority=B-then-A-fallback coldSubstitution=false snapshotWaitInsideWindow=false realtimeQueries=false")
        print("ProductionNativeRefillFailure schema=1 enabled=true requested=\(requestObserved) requestIssued=\(requestIssued) workerResponseAvailable=\(state != nil) phase=\(triggerPhase) target=\(triggerPhase == 1 ? "B-priority" : triggerPhase == 2 ? "A-fallback" : "none") token=\(triggerToken) visit=\(triggerVisit) frame=\(triggerFrame) underrunFrames=\(triggerUnderruns) commandBaselineUnderruns=\(commandBaseline) positiveAtFirstWindowSample=\(positiveAtFirstSample) onsetBeforeFirstObservation=\(positiveAtFirstSample) observationBeginNs=\(begin) observationEndNs=\(end) requestEnqueueNs=\(requestEnqueueNs) requestIssueNs=\(requestIssueNs) workerReplyNs=\(workerReplyNs) requestCapacity=1 requestDeliveryOutsideAcquisition=true snapshotScope=worker-cached-state jointLaneRendererCoherence=false onsetExact=false coldSubstitution=false")
        print("ProductionNativeRefillSourceScope schema=1 available=\(sourceRecords.count == 3) count=\(sourceRecords.count) capacity=3 beginNs=\(sourcesBegin) endNs=\(sourcesEnd) epochQualified=false streamRequestReads=0 scope=first-observed-failure-after-renderer-acquisition")
        for source in sourceRecords.prefix(3) {
            print("ProductionNativeRefillSource schema=1 slot=\(source.slot) token=\(source.token) tokenAfter=\(source.tokenAfter) tokenStable=\(source.token == source.tokenAfter) prefixFrames=\(source.prefixFrames) totalFrames=\(source.totalFrames) rawAvailableFrames=\(source.availableRaw) rawWritableFrames=\(source.writableRaw) epochQualified=false coherence=individual-atomic-accessors")
        }
        for index in 0..<3 {
            let lane = recorder.snapshot(at: index)
            print("ProductionNativeRefillCleanupLane schema=1 lane=\(index) available=\(lane != nil) packedState=\(lane?.packedState ?? 0) copySequence=\(lane?.copySequence ?? 0) stage=\(lane?.stageCode ?? 0) overflowed=\(lane?.sequenceOverflowed ?? false) scope=after-cleanup-wait")
        }
        guard let state else { return }
        let s = state.stats
        print("ProductionNativeRefillWorker schema=1 leasedReaders=\(s.leasedReaders) peakLeasedReaders=\(s.peakLeasedReaders) retiredLeasesAwaitingClose=\(s.retiredLeasesAwaitingClose) startingLeases=\(s.startingLeases) pendingPreparations=\(s.pendingPreparations) pendingReads=\(s.readJobsAwaitingAcceptanceOrClose) mailboxPackets=\(s.mailboxPackets) pendingOrMailboxPacketSlots=\(s.pendingOrMailboxPacketSlots) shutdownRequested=\(s.shutdownRequested) readerLeasesClosed=\(s.readerLeasesClosed) overflowed=\(s.counterOverflowed)")
        for slot in state.slots.prefix(3) {
            print("ProductionNativeRefillSlot schema=1 slot=\(slot.index) token=\(slot.token) epoch=\(slot.epoch) finished=\(slot.finished) cancelled=\(slot.cancelled) lease=\(slot.leaseIndex) streamAvailable=\(slot.stream != nil) cursor=\(slot.stream?.cursor ?? 0) generatedFrames=\(slot.stream?.generatedFrames ?? 0) outputStart=\(slot.stream?.outputStart ?? 0) outputCount=\(slot.stream?.outputCount ?? 0) converterFinished=\(slot.stream?.converterFinished ?? false) reachedEnd=\(slot.stream?.reachedEnd ?? false)")
        }
        for lease in state.leases.prefix(3) {
            print("ProductionNativeRefillLease schema=1 lane=\(lease.index) present=\(lease.present) starting=\(lease.starting) readPending=\(lease.readPending) retired=\(lease.retired) requestedFrames=\(lease.requestedFrames) packetFrames=\(lease.packetFrames) packetOffset=\(lease.packetOffset) reachedEnd=\(lease.reachedEnd) hasFailure=\(lease.hasFailure)")
        }
    }
}
#endif

/// Fixed 12-second storage for actual mixer PCM and its AVAudioTime host timeline.
/// The tap is disabled during the first two 8-second renderer-only windows.
private final class ProductionSelectionOutputTap: @unchecked Sendable {
    struct Tone { let start: Double; let end: Double }
    struct Window { let samples: [Float]; let rate: Double; let start: Double; let end: Double }
    struct Recording { let values: [Float]; let hosts: [Double]; let rate: Double }
    struct Anomaly {
        let kind: Int // 0 = existing 10 ms RMS quiet test; 1 = existing 20 ms tone test.
        let windowOrdinal: Int, firstFrame: Int, endFrame: Int
        let startOffsetMs: Double?, endOffsetMs: Double?
        let rms: Double
    }
    struct ChannelRun {
        let firstFrame: Int, firstHost: Double
        var endFrame: Int, endHost: Double
        var leftSquareSum: Double, rightSquareSum: Double
        var stereoZeroFrames: Int
        var frames: Int { endFrame - firstFrame }
    }
    struct ChannelAudit {
        let firstFrame: Int, minimumRunFrames: Int, observedFrames: Int
        let monoZeroFrames: Int, stereoZeroFrames: Int, nonfiniteFrames: Int
        let leftSquareSum: Double, rightSquareSum: Double
        let qualifiedRuns: Int, retainedRuns: Int, droppedRuns: Int, overflow: Bool
        let first: ChannelRun?, second: ChannelRun?, third: ChannelRun?, fourth: ChannelRun?
        func run(at ordinal: Int) -> ChannelRun? {
            switch ordinal {
            case 0: return first
            case 1: return second
            case 2: return third
            case 3: return fourth
            default: return nil
            }
        }
    }
    private let lock = NSLock()
    private let capacity = 12 * 48_000
    private var values: [Float] = []
    private var hosts: [Double] = []
    private var rate = 0.0
    private var enabled = false
    private var invalidTimestamps = 0
    private var droppedFrames = 0
    // Protected by the existing tap lock; no extra PCM storage or hot allocation.
    private var auditEnabled = false
    private var auditFirstFrame = 0, auditMinimumRunFrames = 0, auditObservedFrames = 0
    private var auditMonoZeroFrames = 0, auditStereoZeroFrames = 0, auditNonfiniteFrames = 0
    private var auditLeftSquareSum = 0.0, auditRightSquareSum = 0.0
    private var auditQualifiedRuns = 0, auditDroppedRuns = 0
    private var auditOverflow = false
    private var auditPending: ChannelRun?
    private var auditFirst: ChannelRun?, auditSecond: ChannelRun?, auditThird: ChannelRun?, auditFourth: ChannelRun?

    init() { values.reserveCapacity(capacity); hosts.reserveCapacity(capacity) }
    static func hostSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    @discardableResult
    func begin(auditChannels: Bool = false) -> Int {
        lock.lock(); defer { lock.unlock() }
        if auditEnabled { finishChannelRun() }
        enabled = true; auditEnabled = auditChannels
        if auditChannels {
            auditFirstFrame = values.count; auditMinimumRunFrames = 0; auditObservedFrames = 0
            auditMonoZeroFrames = 0; auditStereoZeroFrames = 0; auditNonfiniteFrames = 0
            auditLeftSquareSum = 0; auditRightSquareSum = 0
            auditQualifiedRuns = 0; auditDroppedRuns = 0; auditOverflow = false
            auditPending = nil; auditFirst = nil; auditSecond = nil; auditThird = nil; auditFourth = nil
        }
        return values.count
    }
    @discardableResult
    func stop() -> Int {
        lock.lock(); defer { lock.unlock() }
        enabled = false
        if auditEnabled { finishChannelRun(); auditEnabled = false }
        return values.count
    }

    func channelAudit() -> ChannelAudit {
        lock.lock(); defer { lock.unlock() }
        return ChannelAudit(firstFrame: auditFirstFrame, minimumRunFrames: auditMinimumRunFrames,
            observedFrames: auditObservedFrames, monoZeroFrames: auditMonoZeroFrames,
            stereoZeroFrames: auditStereoZeroFrames, nonfiniteFrames: auditNonfiniteFrames,
            leftSquareSum: auditLeftSquareSum, rightSquareSum: auditRightSquareSum,
            qualifiedRuns: auditQualifiedRuns, retainedRuns: min(4, auditQualifiedRuns),
            droppedRuns: auditDroppedRuns, overflow: auditOverflow,
            first: auditFirst, second: auditSecond, third: auditThird, fourth: auditFourth)
    }

    /// Called only under the existing append/stop lock.
    private func finishChannelRun() {
        guard let run = auditPending else { return }
        auditPending = nil
        guard auditMinimumRunFrames > 0, run.frames >= auditMinimumRunFrames else { return }
        switch auditQualifiedRuns {
        case 0: auditFirst = run
        case 1: auditSecond = run
        case 2: auditThird = run
        case 3: auditFourth = run
        default: auditDroppedRuns += 1; auditOverflow = true
        }
        auditQualifiedRuns += 1
    }

    private func auditChannels(left: Float, right: Float, mono: Float, frame: Int,
                               host: Double, rate: Double) {
        auditObservedFrames += 1
        if auditMinimumRunFrames == 0 { auditMinimumRunFrames = Int(rate * 0.01) }
        guard left.isFinite, right.isFinite, mono.isFinite else {
            auditNonfiniteFrames += 1; finishChannelRun(); return
        }
        guard mono == 0 else { finishChannelRun(); return }
        let leftSquare = Double(left) * Double(left), rightSquare = Double(right) * Double(right)
        let stereoZero = left == 0 && right == 0 ? 1 : 0
        auditMonoZeroFrames += 1; auditStereoZeroFrames += stereoZero
        auditLeftSquareSum += leftSquare; auditRightSquareSum += rightSquare
        if auditPending == nil {
            auditPending = ChannelRun(firstFrame: frame, firstHost: host, endFrame: frame,
                endHost: host, leftSquareSum: 0, rightSquareSum: 0, stereoZeroFrames: 0)
        }
        auditPending?.endFrame = frame + 1
        auditPending?.endHost = host + 1 / rate
        auditPending?.leftSquareSum += leftSquare
        auditPending?.rightSquareSum += rightSquare
        auditPending?.stereoZeroFrames += stereoZero
    }

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
            let mono = (left + right) * 0.5
            let host = start + Double(frame) / actualRate
            if auditEnabled { auditChannels(left: left, right: right, mono: mono, frame: values.count, host: host, rate: actualRate) }
            values.append(mono)
            hosts.append(host)
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

    /// Replay unchanged classifications after cleanup; never clip either recording edge.
    static func anomalyLocations(_ recording: Recording, origin: Double?, frequency: Double)
        -> (available: Bool, records: [Anomaly], quietCount: Int, badToneCount: Int, droppedAnomalyCount: Int) {
        guard recording.rate.isFinite, recording.rate > 0,
              recording.values.count == recording.hosts.count else { return (false, [], 0, 0, 0) }
        var records: [Anomaly] = []
        records.reserveCapacity(8)
        var quietCount = 0, badToneCount = 0
        for kind in 0..<2 {
            let frames = Int(recording.rate * (kind == 0 ? 0.01 : 0.02))
            guard frames > 0, recording.values.count >= frames else { continue }
            for first in stride(from: 0, through: recording.values.count - frames, by: frames) {
                let end = first + frames
                var square = 0.0
                for value in recording.values[first..<end] { square += Double(value) * Double(value) }
                let rms = sqrt(square / Double(frames))
                let anomalous = kind == 0 ? rms < 0.01
                    : !isTone(Array(recording.values[first..<end]), rate: recording.rate, frequency: frequency)
                guard anomalous else { continue }
                let ordinal = kind == 0 ? quietCount : badToneCount
                if kind == 0 { quietCount += 1 } else { badToneCount += 1 }
                guard ordinal < 4 else { continue }
                let validOrigin = origin.flatMap { $0.isFinite ? $0 : nil }
                records.append(Anomaly(kind: kind, windowOrdinal: first / frames,
                    firstFrame: first, endFrame: end,
                    startOffsetMs: validOrigin.map { (recording.hosts[first] - $0) * 1_000 },
                    endOffsetMs: validOrigin.map { (recording.hosts[end - 1] + 1 / recording.rate - $0) * 1_000 },
                    rms: rms))
            }
        }
        return (true, records, quietCount, badToneCount, max(0, quietCount - 4) + max(0, badToneCount - 4))
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

/// Seek forwarding timestamps/targets plus optional cached DEBUG decision stamps.
/// Neither path queries native player state; all output remains post-cleanup.
private final class ProductionSelectionSeekRecorder: @unchecked Sendable {
    struct Event {
        let phase: Int
        let target: Double
        let forwardedTimeValue: CMTimeValue
        let forwardedTimeTimescale: CMTimeScale
        let entered: Double
        var returnHostSeconds: Double?
        var completed: Double?
        var finished: Bool?
        #if DEBUG
        var stamp: PlaybackService.DebugVideoSeekStamp?
        #endif
    }
    private let lock = NSLock()
    private var currentPhase = -1
    private var events: [Event] = []
    private var dropped = 0
    #if DEBUG
    private var pendingStamp: PlaybackService.DebugVideoSeekStamp?
    private var stampConflicts = 0

    func record(_ stamp: PlaybackService.DebugVideoSeekStamp) {
        lock.lock(); defer { lock.unlock() }
        if pendingStamp != nil { stampConflicts += 1 }
        pendingStamp = stamp
    }
    #endif
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
        #if DEBUG
        let stamp = pendingStamp
        pendingStamp = nil
        #endif
        if events.count < 32 {
            index = events.count
            var event = Event(phase: currentPhase, target: time.seconds,
                              forwardedTimeValue: time.value, forwardedTimeTimescale: time.timescale, entered: entered)
            #if DEBUG
            event.stamp = stamp
            #endif
            events.append(event)
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
        // Timestamp immediately after the real forwarding call returns. The
        // native completion may legitimately occur before or after this point.
        let returned = ProductionSelectionOutputTap.hostSeconds()
        lock.lock()
        if let index { events[index].returnHostSeconds = returned }
        lock.unlock()
    }

    func assertUnused(file: StaticString = #filePath, line: UInt = #line) {
        lock.lock()
        let count = events.count, lost = dropped
        #if DEBUG
        let conflicts = stampConflicts, pending = pendingStamp != nil
        #endif
        lock.unlock()
        print("ProductionSelectionDefaultSeekPath recordedSeeks=\(count) dropped=\(lost) nativeSeekForwarder=default producerTracing=absent nativeLaneTracing=absent observer=unset")
        XCTAssertEqual(count, 0, "The default path must not pass native seeks through the benchmark recorder", file: file, line: line)
        XCTAssertEqual(lost, 0, file: file, line: line)
        #if DEBUG
        XCTAssertEqual(conflicts, 0, file: file, line: line)
        XCTAssertFalse(pending, file: file, line: line)
        #endif
    }

    func dumpAndAssert() {
        lock.lock()
        let result = events, lost = dropped
        #if DEBUG
        let conflicts = stampConflicts, pending = pendingStamp != nil
        #endif
        lock.unlock()
        print("ProductionSelectionSeekSummary events=\(result.count) capacity=32 dropped=\(lost) nativePositionGetters=0 producerTracing=absent")
        XCTAssertLessThanOrEqual(result.count, 32); XCTAssertEqual(lost, 0)
        #if DEBUG
        print("ProductionSelectionSeekStampSummary schema=1 conflicts=\(conflicts) pending=\(pending) storage=existing32events-plus-one-pending")
        XCTAssertEqual(conflicts, 0); XCTAssertFalse(pending)
        #endif
        for (index, event) in result.enumerated() {
            print("ProductionSelectionSeek ordinal=\(index) phase=\(event.phase) target=\(event.target) enteredHostSeconds=\(event.entered) completedHostSeconds=\(event.completed.map { String($0) } ?? "missing") finished=\(event.finished.map { String($0) } ?? "missing")")
            XCTAssertTrue((0...2).contains(event.phase)); XCTAssertTrue(event.target.isFinite)
            XCTAssertTrue(event.entered.isFinite)
            if let completed = event.completed { XCTAssertGreaterThanOrEqual(completed, event.entered) }
            print("ProductionSelectionSeekReturn schema=1 ordinal=\(index) phase=\(event.phase) enteredHostSeconds=\(event.entered) returnHostSeconds=\(event.returnHostSeconds.map { String($0) } ?? "missing") forwardingSynchronousSpanMs=\(event.returnHostSeconds.map { String(($0 - event.entered) * 1_000) } ?? "missing")")
            XCTAssertNotNil(event.returnHostSeconds, "Every forwarded seek must retain its synchronous return timestamp")
            if let returned = event.returnHostSeconds {
                XCTAssertTrue(returned.isFinite)
                XCTAssertGreaterThanOrEqual(returned, event.entered)
            }
            #if DEBUG
            XCTAssertNotNil(event.stamp, "Every forwarded benchmark seek must retain its decision stamp")
            if let stamp = event.stamp {
                print("ProductionSelectionSeekReason schema=1 ordinal=\(index) phase=\(event.phase) reason=\(stamp.reason.rawValue) request=\(stamp.request) generation=\(stamp.generation) nativeSeekTicket=\(stamp.nativeSeekTicket) requestedPosition=\(stamp.requestedPosition) force=\(stamp.force) cachedSelected=\(stamp.cachedSelected) selectedMatchesQueue=\(stamp.selectedMatchesQueue) cachedAudioToken=\(stamp.cachedAudioToken) cachedAudioVisit=\(stamp.cachedAudioVisit) observedItemMatches=\(stamp.observedItemMatches) presentationRequestMatches=\(stamp.presentationRequestMatches) readyGeneration=\(stamp.readyGeneration.map { String($0) } ?? "missing") pendingAudioSeek=\(stamp.pendingAudioSeek) audioLoading=\(stamp.audioLoading) canPlay=\(stamp.canPlay) videoAllowed=\(stamp.videoAllowed)")
                XCTAssertNotEqual(stamp.reason, .unattributed)
                XCTAssertGreaterThan(stamp.nativeSeekTicket, 0)
                XCTAssertTrue(stamp.requestedPosition.isFinite)
                // Reconstruct the original application request exactly as forwarded.
                // The actual integer fields were retained from CMTime, never from target.seconds.
                let expectedTime = CMTime(seconds: stamp.requestedPosition, preferredTimescale: 48_000)
                print("ProductionSelectionSeekExactTime schema=1 ordinal=\(index) phase=\(event.phase) expectedValue=\(expectedTime.value) expectedTimescale=\(expectedTime.timescale) forwardedValue=\(event.forwardedTimeValue) forwardedTimescale=\(event.forwardedTimeTimescale) force=\(stamp.force) ordinaryDriftVideoPositionSeconds=\(stamp.ordinaryDriftVideoPositionSeconds.map { String($0) } ?? "not-read") ordinarySignedDriftSeconds=\(stamp.ordinaryDriftVideoPositionSeconds.map { String($0 - stamp.requestedPosition) } ?? "not-read")")
                XCTAssertEqual(expectedTime.value, event.forwardedTimeValue)
                XCTAssertEqual(expectedTime.timescale, event.forwardedTimeTimescale)
                if stamp.force { XCTAssertNil(stamp.ordinaryDriftVideoPositionSeconds) }
                else { XCTAssertNotNil(stamp.ordinaryDriftVideoPositionSeconds) }
            }
            #endif
        }
    }
}

private final class ProductionSelectionShutdown: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    var result: Bool? { lock.lock(); defer { lock.unlock() }; return value }
    func complete(_ result: Bool) { lock.lock(); value = result; lock.unlock() }
}

#if DEBUG
private final class NaturalFailureStateMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuousPCMDecoder.DebugFailureState?
    var result: ContinuousPCMDecoder.DebugFailureState? { lock.lock(); defer { lock.unlock() }; return value }
    func complete(_ result: ContinuousPCMDecoder.DebugFailureState) { lock.lock(); value = result; lock.unlock() }
}
#endif

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
        restorePreferences()
    }

    func restorePreferences() {
        if let previousSpeakerSound { UserDefaults.standard.set(previousSpeakerSound, forKey: "speakerSound") }
        else { UserDefaults.standard.removeObject(forKey: "speakerSound") }
        if let previousAutomaticPiP { UserDefaults.standard.set(previousAutomaticPiP, forKey: "automaticPiP") }
        else { UserDefaults.standard.removeObject(forKey: "automaticPiP") }
    }

}

#if DEBUG
@MainActor
private final class SelectionInitialReadyOrderingProbe {
    let generation: Int
    private(set) var entered = 0, active = 0, dropped = 0
    private(set) var timedOut = false, cancelled = false, overflow = false
    private(set) var reasons: [Int] = []
    private var released = false, recording = true
    private var deadline: Double?
    var isHolding: Bool { active > 0 && !released && !timedOut && !cancelled }

    init(generation: Int) { self.generation = generation; reasons.reserveCapacity(32) }

    func hold(request: Int) async {
        guard request == generation, !released else { return }
        guard entered < 8 else { overflow = true; return }
        entered += 1; active += 1
        defer { active -= 1 }
        if deadline == nil { deadline = ProcessInfo.processInfo.systemUptime + 3 }
        while !released, ProcessInfo.processInfo.systemUptime < (deadline ?? 0) {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { cancelled = true; return }
        }
        if !released { timedOut = true }
    }

    func record(_ stamp: PlaybackService.DebugVideoSeekStamp) {
        guard recording, stamp.generation == generation else { return }
        if reasons.count < 32 { reasons.append(stamp.reason.rawValue) }
        else { dropped += 1 }
    }

    func stopRecording() { recording = false }
    func release() { released = true }
}
#endif

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
