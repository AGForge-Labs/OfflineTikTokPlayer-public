import XCTest
import AVFoundation
@testable import OfflineTikTokPlayer

/// Lifecycle contracts for buffered video rendering resources.
/// Bundled inputs are the project's synthetic color/tone videos; no files are
/// created or removed, and acquisition observations do not establish scanout.
@MainActor
final class ContinuousPictureInPictureResourceTests: XCTestCase {
    private typealias Resource = ContinuousPictureInPicture.PreparedVideoResource

    func testOffscreenPreparationInstallsActualGeometryAndSingleStagedOutput() async throws {
        let item = try makeItem()
        let active = try makeItem("test-slideshow")
        let buffer = PlaybackBuffer()
        buffer.player.isMuted = true
        buffer.player.pause()
        defer { buffer.replace(with: nil); buffer.discardPrevious() }
        let tracks = try await item.asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let duration = try await item.asset.load(.duration)
        XCTAssertTrue(item.outputs.isEmpty)
        XCTAssertNil(item.videoComposition)

        let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
        XCTAssertTrue(item.outputs.isEmpty, "Preparation must not attach an SDK output")
        XCTAssertNil(item.videoComposition, "Preparation must not mutate the item")
        buffer.replace(with: active, mediaID: "b", isLocal: true)
        var eligibilityChecks = 0
        XCTAssertTrue(buffer.stage(.init(mediaID: "a", item: item, isLocal: true), after: "b",
                                   videoPreparation: plan, ifEligible: {
            eligibilityChecks += 1
            return true
        }))
        let resource = try XCTUnwrap(buffer.resource(for: item))
        defer { resource.retire() }
        let output = try XCTUnwrap(resource.output)
        XCTAssertGreaterThanOrEqual(eligibilityChecks, 1)
        XCTAssertLessThanOrEqual(eligibilityChecks, 8, "Eligibility rechecks must remain synchronous and bounded")
        XCTAssertTrue(resource.item === item)
        XCTAssertTrue(resource.isAttached)
        XCTAssertFalse(resource.isRetired)
        XCTAssertFalse(resource.isBorrowed)
        XCTAssertEqual(item.outputs.count, 1)
        XCTAssertTrue(item.outputs.first === output)
        XCTAssertFalse(output.suppressesPlayerRendering)
        // The setter copies its argument. Inspect the actual installed getter,
        // rather than comparing it to the mutable composition used to build it.
        let installed = try XCTUnwrap(item.videoComposition)
        XCTAssertEqual(installed.renderSize, CGSize(width: 256, height: 454))
        XCTAssertEqual(installed.sourceTrackIDForFrameTiming, track.trackID)
        XCTAssertEqual(CMTimeCompare(try XCTUnwrap(installed.instructions.first).timeRange.duration, duration), 0)

        XCTAssertTrue(buffer.hasPrepared("a"))
        XCTAssertTrue(buffer.resource(for: item) === resource)
        XCTAssertTrue(item.outputs.first === output)
        XCTAssertEqual(item.outputs.count, 1)
        XCTAssertTrue(item.videoComposition === installed)
    }

    func testPreparedResourcesSurviveABAReturnWithoutOutputPullBeforeActivation() async throws {
        #if DEBUG
        let itemA = try makeItem()
        let itemB = try makeItem("test-slideshow")
        let resourceA = try await installResource(for: itemA)
        let resourceB = try await installResource(for: itemB)
        let outputA = try XCTUnwrap(resourceA.output)
        let outputB = try XCTUnwrap(resourceB.output)
        let buffer = PlaybackBuffer()
        let bridge = ContinuousPictureInPicture()
        buffer.player.isMuted = true
        buffer.player.pause()
        defer {
            bridge.onFrameAcquisition = nil
            bridge.invalidate()
            buffer.player.pause()
            buffer.replace(with: nil)
            buffer.discardPrevious()
            resourceA.retire()
            resourceB.retire()
        }
        var requestsA = 0
        var requestsB = 0
        var unexpectedItem = false
        var requestOverflow = false
        bridge.onFrameAcquisition = { item, _ in
            if requestsA + requestsB >= 256 { requestOverflow = true; return }
            if item === itemA { requestsA += 1 }
            else if item === itemB { requestsB += 1 }
            else { unexpectedItem = true }
        }

        buffer.replace(with: itemA, mediaID: "a", isLocal: true, videoResource: resourceA)
        buffer.stage(.init(mediaID: "b", item: itemB, isLocal: true, videoResource: resourceB), after: "a")
        let firstA = try XCTUnwrap(bridge.setCurrentItem(itemA, preparedVideo: resourceA))
        XCTAssertTrue(bridge.installTimeline(firstA, positionSeconds: 0, durationSeconds: 1.2, isPlaying: false))
        bridge.updatePlayback(positionSeconds: 0, durationSeconds: 1.2, isPlaying: false)
        bridge.suspendFrameFeed()
        bridge.resumeFrameFeed()
        try await exerciseInactiveFeed(bridge)
        XCTAssertEqual(requestsA + requestsB, 0)
        XCTAssertEqual(bridge.submittedFrameCount, 0)
        XCTAssertNil(bridge.lastCopiedFramePositionSeconds)

        let selectedB = try XCTUnwrap(buffer.advance(to: "b"))
        XCTAssertTrue(selectedB.item === itemB)
        let ticketB = try XCTUnwrap(bridge.setCurrentItem(itemB, preparedVideo: buffer.resource(for: itemB)))
        XCTAssertTrue(resourceA.isAttached)
        XCTAssertFalse(resourceA.isRetired)
        XCTAssertFalse(resourceA.isBorrowed)
        XCTAssertTrue(buffer.resource(for: itemA) === resourceA)
        XCTAssertTrue(itemA.outputs.contains { $0 === outputA })
        XCTAssertTrue(resourceB.isBorrowed)
        XCTAssertTrue(bridge.installTimeline(ticketB, positionSeconds: 0, durationSeconds: 1.2, isPlaying: false))
        try await exerciseInactiveFeed(bridge)
        XCTAssertEqual(requestsA + requestsB, 0)

        let returnedA = try XCTUnwrap(buffer.advance(to: "a"))
        XCTAssertTrue(returnedA.item === itemA)
        let finalA = try XCTUnwrap(bridge.setCurrentItem(itemA, preparedVideo: buffer.resource(for: itemA)))
        XCTAssertTrue(resourceA.isBorrowed)
        XCTAssertFalse(resourceB.isBorrowed)
        XCTAssertFalse(resourceA.isRetired)
        XCTAssertFalse(resourceB.isRetired)
        XCTAssertTrue(itemA.outputs.contains { $0 === outputA })
        XCTAssertTrue(itemB.outputs.contains { $0 === outputB })
        XCTAssertTrue(resourceA.output === outputA)
        XCTAssertTrue(resourceB.output === outputB)
        XCTAssertFalse(bridge.activate(firstA), "A departed ticket cannot activate the returned item")
        XCTAssertFalse(bridge.activate(ticketB))
        XCTAssertTrue(bridge.installTimeline(finalA, positionSeconds: 0, durationSeconds: 1.2, isPlaying: false))
        XCTAssertEqual(requestsA + requestsB, 0)
        XCTAssertTrue(bridge.activate(finalA))
        let acquired = await waitUntil {
            bridge.updatePlayback(positionSeconds: 0, durationSeconds: 1.2, isPlaying: false)
            return requestsA > 0
        }
        XCTAssertTrue(acquired, "The activated real output must reach the SDK acquisition path")
        XCTAssertEqual(requestsB, 0)
        XCTAssertFalse(unexpectedItem)
        XCTAssertFalse(requestOverflow)
        #else
        XCTFail("This acquisition contract requires the DEBUG observer")
        #endif
    }

    func testRejectedInstallEligibilityConsumesPlanWithoutMutatingItem() async throws {
        let item = try makeItem()
        let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
        var checks = 0
        XCTAssertNil(plan.install(ifEligible: { checks += 1; return false }))
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(item.outputs.isEmpty)
        XCTAssertNil(item.videoComposition)
        XCTAssertNil(plan.install(ifEligible: { true }), "A rejected plan must not be installed later")
        XCTAssertTrue(item.outputs.isEmpty)
        XCTAssertNil(item.videoComposition)

        let active = try makeItem("test-slideshow")
        let buffer = PlaybackBuffer()
        defer { buffer.replace(with: nil); buffer.discardPrevious() }
        buffer.replace(with: active, mediaID: "active", isLocal: true)
        let rejectedStagePlan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
        XCTAssertFalse(buffer.stage(.init(mediaID: "rejected", item: item, isLocal: true), after: "active",
                                    videoPreparation: rejectedStagePlan, ifEligible: { false }))
        XCTAssertTrue(item.outputs.isEmpty)
        XCTAssertNil(item.videoComposition)
        XCTAssertNil(buffer.resource(for: item))
        XCTAssertFalse(buffer.hasPrepared("rejected"))
    }

    func testRejectedAndEvictedResourcesDeferDetachUntilActiveBorrowIsReleased() async throws {
        let itemA = try makeItem()
        let itemB = try makeItem("test-slideshow")
        let itemC = try makeItem()
        let rejectedItem = try makeItem("test-slideshow")
        let resourceA = try await installResource(for: itemA)
        let resourceB = try await installResource(for: itemB)
        let resourceC = try await installResource(for: itemC)
        let rejected = try await installResource(for: rejectedItem)
        let outputA = try XCTUnwrap(resourceA.output)
        let outputB = try XCTUnwrap(resourceB.output)
        let outputC = try XCTUnwrap(resourceC.output)
        let rejectedOutput = try XCTUnwrap(rejected.output)
        let buffer = PlaybackBuffer()
        let bridge = ContinuousPictureInPicture()
        buffer.player.isMuted = true
        defer {
            bridge.invalidate()
            buffer.player.pause()
            buffer.replace(with: nil)
            buffer.discardPrevious()
            for resource in [resourceA, resourceB, resourceC, rejected] { resource.retire() }
        }
        buffer.replace(with: itemA, mediaID: "a", isLocal: true, videoResource: resourceA)
        XCTAssertNotNil(bridge.setCurrentItem(rejectedItem, preparedVideo: rejected))
        buffer.stage(.init(mediaID: "rejected", item: rejectedItem, isLocal: true, videoResource: rejected), after: "wrong-id")
        XCTAssertTrue(rejected.isRetired)
        XCTAssertTrue(rejected.isBorrowed)
        XCTAssertTrue(rejected.isAttached)
        XCTAssertTrue(rejected.output === rejectedOutput)
        bridge.setCurrentItem(nil)
        XCTAssertFalse(rejected.isBorrowed)
        XCTAssertFalse(rejected.isAttached)
        XCTAssertNil(rejected.output)
        XCTAssertFalse(rejectedItem.outputs.contains { $0 === rejectedOutput })

        buffer.stage(.init(mediaID: "b", item: itemB, isLocal: true, videoResource: resourceB), after: "a")
        XCTAssertTrue(buffer.hasPrepared("b"))
        buffer.stage(.init(mediaID: "c", item: itemC, isLocal: true, videoResource: resourceC), after: "a")
        XCTAssertTrue(buffer.hasPrepared("c"))
        XCTAssertTrue(resourceB.isRetired)
        XCTAssertFalse(resourceB.isAttached)
        XCTAssertNil(resourceB.output)
        XCTAssertFalse(itemB.outputs.contains { $0 === outputB })
        XCTAssertFalse(resourceC.isRetired)
        buffer.discardNext()
        XCTAssertTrue(resourceC.isRetired)
        XCTAssertNil(resourceC.output)
        XCTAssertFalse(itemC.outputs.contains { $0 === outputC })

        XCTAssertNotNil(bridge.setCurrentItem(itemA, preparedVideo: resourceA))
        let replacement = try makeItem("test-slideshow")
        buffer.replace(with: replacement, mediaID: "d", isLocal: true)
        XCTAssertFalse(resourceA.isRetired, "The retained previous slot still owns A")
        buffer.discardPrevious()
        XCTAssertTrue(resourceA.isRetired)
        XCTAssertTrue(resourceA.isBorrowed)
        XCTAssertTrue(resourceA.isAttached)
        XCTAssertTrue(resourceA.output === outputA)
        bridge.setCurrentItem(nil)
        XCTAssertFalse(resourceA.isAttached)
        XCTAssertFalse(resourceA.isBorrowed)
        XCTAssertNil(resourceA.output)
        XCTAssertFalse(itemA.outputs.contains { $0 === outputA })
    }

    func testRetirementPreservesExternallyReplacedComposition() async throws {
        let item = try makeItem()
        let resource = try await installResource(for: item)
        defer { resource.retire() }
        let output = try XCTUnwrap(resource.output)
        let originalInstalled = try XCTUnwrap(item.videoComposition)
        let external = AVMutableVideoComposition(propertiesOf: item.asset)
        external.renderSize = CGSize(width: 256, height: 454)
        external.frameDuration = CMTime(value: 1, timescale: 24)
        item.videoComposition = external
        let actualExternal = try XCTUnwrap(item.videoComposition)
        XCTAssertFalse(actualExternal === originalInstalled)
        resource.retire()
        XCTAssertTrue(resource.isRetired)
        XCTAssertFalse(resource.isAttached)
        XCTAssertNil(resource.output)
        XCTAssertFalse(item.outputs.contains { $0 === output })
        XCTAssertTrue(item.videoComposition === actualExternal)
        resource.retire()
        XCTAssertTrue(item.videoComposition === actualExternal)
    }

    func testRepeatedBufferTransitionsBoundActualAttachedOutputs() async throws {
        let buffer = PlaybackBuffer()
        let bridge = ContinuousPictureInPicture()
        buffer.player.isMuted = true
        buffer.player.pause()
        // Fixed six transitions, at most 25 installed resources over the whole
        // test. Retired objects/items stay strongly reachable so output removal
        // is observed independently of SDK deinitialization.
        var items: [AVPlayerItem] = []
        var resources: [Resource] = []
        defer {
            bridge.invalidate()
            buffer.player.pause()
            buffer.replace(with: nil)
            buffer.discardPrevious()
            for resource in resources { resource.retire() }
        }
        func record(_ item: AVPlayerItem, _ resource: Resource) {
            items.append(item)
            resources.append(resource)
        }
        func assertBound(file: StaticString = #filePath, line: UInt = #line) {
            let actualOutputs = items.reduce(0) { $0 + $1.outputs.count }
            let retiredBorrowed = resources.filter { $0.isRetired && $0.isBorrowed }.count
            let attached = resources.filter { $0.isAttached }.count
            XCTAssertLessThanOrEqual(buffer.retainedItemCount, 4, file: file, line: line)
            XCTAssertLessThanOrEqual(retiredBorrowed, 1, file: file, line: line)
            XCTAssertLessThanOrEqual(actualOutputs, 4 + retiredBorrowed, file: file, line: line)
            XCTAssertEqual(actualOutputs, attached, file: file, line: line)
            for (item, resource) in zip(items, resources) {
                XCTAssertLessThanOrEqual(item.outputs.count, 1, file: file, line: line)
                if let output = resource.output {
                    XCTAssertTrue(item.outputs.contains { $0 === output }, file: file, line: line)
                } else {
                    XCTAssertTrue(item.outputs.isEmpty, file: file, line: line)
                }
            }
        }

        let initial = try makeItem()
        let initialResource = try await installResource(for: initial)
        record(initial, initialResource)
        buffer.replace(with: initial, mediaID: "initial", isLocal: true, videoResource: initialResource)
        XCTAssertNotNil(bridge.setCurrentItem(initial, preparedVideo: initialResource))
        var currentID = "initial"
        for index in 0..<6 {
            let next = try makeItem("test-slideshow")
            let nextPlan = try await ContinuousPictureInPicture.prepareVideoResource(for: next)
            let nextID = "next-\(index)"
            XCTAssertTrue(buffer.stage(.init(mediaID: nextID, item: next, isLocal: true), after: currentID,
                                       videoPreparation: nextPlan, ifEligible: { true }))
            let nextResource = try XCTUnwrap(buffer.resource(for: next))
            record(next, nextResource)
            assertBound()

            let advanced = try XCTUnwrap(buffer.advance(to: nextID))
            XCTAssertTrue(advanced.item === next)
            buffer.discardPrevious()
            XCTAssertEqual(resources.filter { $0.isRetired && $0.isBorrowed }.count, 1)
            assertBound()
            currentID = nextID

            let previous = try makeItem()
            let previousPlan = try await ContinuousPictureInPicture.prepareVideoResource(for: previous)
            XCTAssertTrue(buffer.stagePrevious(.init(mediaID: "previous-\(index)", item: previous, isLocal: true),
                                               videoPreparation: previousPlan, ifEligible: { true }))
            record(previous, try XCTUnwrap(buffer.resource(for: previous)))
            let loopNext = try makeItem("test-slideshow")
            let loopPlan = try await ContinuousPictureInPicture.prepareVideoResource(for: loopNext)
            XCTAssertTrue(buffer.stage(.init(mediaID: currentID, item: loopNext, isLocal: true), after: currentID,
                                       videoPreparation: loopPlan, ifEligible: { true }))
            record(loopNext, try XCTUnwrap(buffer.resource(for: loopNext)))
            let reserve = try makeItem()
            let reserveResource = try await installResource(for: reserve)
            record(reserve, reserveResource)
            buffer.stageLoopReserve(.init(mediaID: currentID, item: reserve, isLocal: true, videoResource: reserveResource))
            XCTAssertTrue(buffer.hasLoopReserve)
            XCTAssertEqual(buffer.retainedItemCount, 4)
            XCTAssertEqual(items.reduce(0) { $0 + $1.outputs.count }, 5)
            assertBound()
            // A rejected plan must not transiently attach a sixth output while
            // the four-slot window and a departed borrowed resource are full.
            let rejected = try makeItem()
            let rejectedPlan = try await ContinuousPictureInPicture.prepareVideoResource(for: rejected)
            XCTAssertFalse(buffer.stage(.init(mediaID: "rejected", item: rejected, isLocal: true), after: currentID,
                                        videoPreparation: rejectedPlan, ifEligible: { false }))
            XCTAssertTrue(rejected.outputs.isEmpty)
            XCTAssertNil(rejected.videoComposition)
            XCTAssertTrue(buffer.hasLoopReserve)
            XCTAssertEqual(buffer.retainedItemCount, 4)
            assertBound()
            XCTAssertNotNil(bridge.setCurrentItem(next, preparedVideo: nextResource))
            XCTAssertEqual(resources.filter { $0.isRetired && $0.isBorrowed }.count, 0)
            XCTAssertEqual(items.reduce(0) { $0 + $1.outputs.count }, 4)
            assertBound()
        }
    }

    private func makeItem(_ name: String = "test-video") throws -> AVPlayerItem {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp4"))
        return AVPlayerItem(url: url)
    }

    private func installResource(for item: AVPlayerItem) async throws -> Resource {
        let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
        return try XCTUnwrap(plan.install(ifEligible: { true }))
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while true {
            if condition() { return true }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 10_000_000) }
            catch { return false }
        }
    }

    private func exerciseInactiveFeed(_ bridge: ContinuousPictureInPicture) async throws {
        // updatePlayback synchronously attempts renderFrame, and playing also
        // exercises the existing timer across 80ms. Neither may pull until
        // activate owns an installed timeline. This is not a latency oracle.
        XCTAssertTrue(bridge.displayLayer.isReadyForMoreMediaData)
        for _ in 0..<4 {
            bridge.updatePlayback(positionSeconds: 0, durationSeconds: 1.2, isPlaying: true)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        bridge.updatePlayback(positionSeconds: 0, durationSeconds: 1.2, isPlaying: false)
        XCTAssertFalse(bridge.isFrameFeedRunning)
    }
}
