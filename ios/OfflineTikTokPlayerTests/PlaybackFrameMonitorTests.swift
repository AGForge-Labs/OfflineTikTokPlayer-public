import XCTest
import AVFoundation
import UIKit
@testable import OfflineTikTokPlayer

/// Actual CPP enqueue proof and visible sample-buffer layer readiness; no decoded substitute,
/// screenshot, fabricated epoch or benchmark-latency allowance is used here.
@MainActor
final class PlaybackFrameMonitorTests: XCTestCase {
    func testPausedCurrentEpochQualifiesWithoutAnotherOutputAndCancelPreservesResource() async throws {
        #if DEBUG
        let presentation = try await makePresentation()
        defer { presentation.close() }
        let monitor = PlaybackFrameMonitor()
        monitor.debugAutomaticallyTicks = false
        defer { monitor.cancel() }
        let output = try XCTUnwrap(presentation.resource.output)
        let epoch = try XCTUnwrap(presentation.bridge.debugCurrentFrameEpoch(for: presentation.ticket))
        let submissions = presentation.bridge.submittedFrameCount
        XCTAssertGreaterThan(submissions, 0)
        XCTAssertNotNil(presentation.bridge.lastFramePositionSeconds)
        XCTAssertEqual(presentation.player.rate, 0)
        XCTAssertEqual(presentation.item.outputs.count, 1)
        var completions = 0
        monitor.start(item: presentation.item, layer: presentation.layer,
                      displayLayer: presentation.bridge.displayLayer, currentFrameReceipt: {
            presentation.bridge.currentFrameReceipt(for: presentation.ticket)
        }, onReady: { _ in completions += 1 })
        XCTAssertEqual(presentation.item.outputs.count, 1)
        monitor.debugTick(displayTime: 10)
        XCTAssertEqual(completions, 0)
        monitor.debugTick(displayTime: 10 + 1.0 / 60)
        XCTAssertEqual(completions, 1, "An already-enqueued paused image must not need a new output buffer")
        XCTAssertEqual(presentation.bridge.submittedFrameCount, submissions)
        XCTAssertEqual(presentation.bridge.debugCurrentFrameEpoch(for: presentation.ticket), epoch)
        monitor.cancel()
        XCTAssertTrue(presentation.resource.output === output)
        XCTAssertTrue(presentation.resource.isAttached)
        XCTAssertTrue(presentation.resource.isBorrowed)
        XCTAssertFalse(presentation.resource.isRetired)

        let staleTicket = presentation.ticket
        let current = try XCTUnwrap(presentation.bridge.setCurrentItem(presentation.item,
                                                                      preparedVideo: presentation.resource))
        XCTAssertNil(presentation.bridge.debugCurrentFrameEpoch(for: staleTicket))
        XCTAssertNil(presentation.bridge.debugCurrentFrameEpoch(for: current))
        XCTAssertFalse(presentation.bridge.activate(staleTicket))
        monitor.start(item: presentation.item, layer: presentation.layer,
                      displayLayer: presentation.bridge.displayLayer, currentFrameReceipt: {
            presentation.bridge.currentFrameReceipt(for: staleTicket)
        }, onReady: { _ in completions += 1 })
        monitor.debugTick(displayTime: 11)
        monitor.debugTick(displayTime: 11 + 1.0 / 60)
        XCTAssertEqual(completions, 1, "A stale ticket cannot supply an old image to the new presentation")
        monitor.cancel()
        XCTAssertEqual(presentation.item.outputs.count, 1)
        XCTAssertTrue(presentation.resource.output === output)
        XCTAssertFalse(presentation.resource.isRetired)
        #else
        XCTFail("Current custom-frame contracts require DEBUG controls")
        #endif
    }

    func testFlushBetweenManualDisplayTicksRequiresNewCurrentEpochAndTwoFreshTicks() async throws {
        #if DEBUG
        let presentation = try await makePresentation()
        defer { presentation.close() }
        let monitor = PlaybackFrameMonitor()
        monitor.debugAutomaticallyTicks = false
        defer { monitor.cancel() }
        let originalEpoch = try XCTUnwrap(presentation.bridge.debugCurrentFrameEpoch(for: presentation.ticket))
        let originalSubmissions = presentation.bridge.submittedFrameCount
        var completions = 0
        monitor.start(item: presentation.item, layer: presentation.layer,
                      displayLayer: presentation.bridge.displayLayer, currentFrameReceipt: {
            presentation.bridge.currentFrameReceipt(for: presentation.ticket)
        }, onReady: { _ in completions += 1 })
        monitor.debugTick(displayTime: 20)
        XCTAssertEqual(completions, 0)
        presentation.bridge.flushForSeek()
        XCTAssertNil(presentation.bridge.debugCurrentFrameEpoch(for: presentation.ticket))
        // Deliberately do not sample nil: the entire real flush/seek/enqueue
        // occurs between monitor ticks. Comparing only nil/non-nil is unsafe.

        let seek = SeekCompletion()
        presentation.item.seek(to: CMTime(seconds: 0.25, preferredTimescale: 60_000),
                               toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in seek.finished = finished }
        }
        let sought = await waitUntil { seek.finished != nil }
        XCTAssertTrue(sought); XCTAssertEqual(seek.finished, true)
        guard sought, seek.finished == true else { throw SetupFailure.notReady }
        let enqueued = await waitUntil {
            presentation.bridge.updatePlayback(positionSeconds: 0.25, durationSeconds: 1.2, isPlaying: false)
            return presentation.bridge.debugCurrentFrameEpoch(for: presentation.ticket) != nil
                && presentation.layer.isReadyForDisplay
                && presentation.bridge.displayLayer.isReadyForDisplay
        }
        XCTAssertTrue(enqueued)
        guard enqueued else { throw SetupFailure.notReady }
        let freshEpoch = try XCTUnwrap(presentation.bridge.debugCurrentFrameEpoch(for: presentation.ticket))
        XCTAssertNotEqual(freshEpoch, originalEpoch)
        XCTAssertGreaterThan(presentation.bridge.submittedFrameCount, originalSubmissions)
        monitor.debugTick(displayTime: 21)
        XCTAssertEqual(completions, 0, "The new epoch must not inherit the pre-flush display tick")
        monitor.debugTick(displayTime: 21 + 1.0 / 60)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(presentation.item.outputs.count, 1)
        XCTAssertTrue(presentation.resource.isAttached)
        XCTAssertFalse(presentation.resource.isRetired)

        // Also exercise nil with no replacement image: it cannot preserve a
        // prior decoded latch or complete the second tick after a flush.
        monitor.start(item: presentation.item, layer: presentation.layer,
                      displayLayer: presentation.bridge.displayLayer, currentFrameReceipt: {
            presentation.bridge.currentFrameReceipt(for: presentation.ticket)
        }, onReady: { _ in completions += 1 })
        monitor.debugTick(displayTime: 22)
        presentation.bridge.flushForSeek()
        XCTAssertNil(presentation.bridge.debugCurrentFrameEpoch(for: presentation.ticket))
        monitor.debugTick(displayTime: 22 + 1.0 / 60)
        XCTAssertEqual(completions, 1)
        #else
        XCTFail("Current custom-frame contracts require DEBUG controls")
        #endif
    }

    func testSupersededCurrentFrameMonitorCannotCompleteItsReplacement() async throws {
        #if DEBUG
        let presentation = try await makePresentation()
        defer { presentation.close() }
        let monitor = PlaybackFrameMonitor()
        monitor.debugAutomaticallyTicks = false
        defer { monitor.cancel() }
        let receipt = try XCTUnwrap(presentation.bridge.currentFrameReceipt(for: presentation.ticket))
        XCTAssertTrue(presentation.bridge.displayLayer.isReadyForDisplay)
        let submissions = presentation.bridge.submittedFrameCount
        var oldCompletions = 0, newCompletions = 0, replacements = 0
        // Replace the request from its real cached proof callback. The old tick
        // must not arm, cancel or complete the new request after this returns.
        monitor.start(item: presentation.item, layer: presentation.layer,
                      displayLayer: presentation.bridge.displayLayer, currentFrameReceipt: {
            if replacements == 0 {
                replacements += 1
                monitor.start(item: presentation.item, layer: presentation.layer,
                              displayLayer: presentation.bridge.displayLayer, currentFrameReceipt: {
                    presentation.bridge.currentFrameReceipt(for: presentation.ticket)
                }, onReady: { accepted in
                    XCTAssertEqual(accepted, receipt)
                    newCompletions += 1
                })
            }
            return presentation.bridge.currentFrameReceipt(for: presentation.ticket)
        }, onReady: { _ in oldCompletions += 1 })
        monitor.debugTick(displayTime: 30)
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(oldCompletions, 0); XCTAssertEqual(newCompletions, 0)
        monitor.debugTick(displayTime: 30 + 1.0 / 60)
        XCTAssertEqual(newCompletions, 0, "Replacement needs its own first display tick")
        monitor.debugTick(displayTime: 30 + 2.0 / 60)
        XCTAssertEqual(oldCompletions, 0); XCTAssertEqual(newCompletions, 1)
        XCTAssertEqual(presentation.item.outputs.count, 1)
        XCTAssertEqual(presentation.bridge.submittedFrameCount, submissions)
        XCTAssertEqual(presentation.bridge.currentFrameReceipt(for: presentation.ticket), receipt)

        var postCancelReplacements = 0, cancelledCompletions = 0, replacementCompletions = 0
        monitor.start(item: presentation.item, layer: presentation.layer,
                      displayLayer: presentation.bridge.displayLayer, currentFrameReceipt: {
            // Actual cancellation has happened. Starting and cancelling a newer
            // request leaves request=nil again, but must still revoke this completion.
            if !monitor.debugHasActiveRequest, postCancelReplacements == 0 {
                postCancelReplacements += 1
                monitor.start(item: presentation.item, layer: presentation.layer,
                              displayLayer: presentation.bridge.displayLayer, currentFrameReceipt: {
                    presentation.bridge.currentFrameReceipt(for: presentation.ticket)
                }, onReady: { _ in replacementCompletions += 1 })
                monitor.cancel()
            }
            return presentation.bridge.currentFrameReceipt(for: presentation.ticket)
        }, onReady: { _ in cancelledCompletions += 1 })
        monitor.debugTick(displayTime: 31)
        monitor.debugTick(displayTime: 31 + 1.0 / 60)
        XCTAssertEqual(postCancelReplacements, 1)
        XCTAssertEqual(cancelledCompletions, 0)
        XCTAssertEqual(replacementCompletions, 0)
        XCTAssertFalse(monitor.debugHasActiveRequest)
        XCTAssertEqual(presentation.item.outputs.count, 1)
        XCTAssertEqual(presentation.bridge.submittedFrameCount, submissions)
        XCTAssertEqual(presentation.bridge.currentFrameReceipt(for: presentation.ticket), receipt)
        #else
        XCTFail("Current custom-frame contracts require DEBUG controls")
        #endif
    }

    func testSuspendedPausedImageRequiresTwoFreshTicksAfterResume() async throws {
        #if DEBUG
        let presentation = try await makePresentation()
        defer { presentation.close() }
        let monitor = PlaybackFrameMonitor()
        monitor.debugAutomaticallyTicks = false
        defer { monitor.cancel() }
        let receipt = try XCTUnwrap(presentation.bridge.currentFrameReceipt(for: presentation.ticket))
        let submissions = presentation.bridge.submittedFrameCount
        var completions = 0
        monitor.start(item: presentation.item, layer: presentation.layer,
                      displayLayer: presentation.bridge.displayLayer, currentFrameReceipt: {
            presentation.bridge.currentFrameReceipt(for: presentation.ticket)
        }, onReady: { accepted in
            XCTAssertEqual(accepted, receipt)
            completions += 1
        })
        monitor.debugTick(displayTime: 40)
        XCTAssertEqual(completions, 0)
        presentation.bridge.suspendFrameFeed()
        XCTAssertNil(presentation.bridge.currentFrameReceipt(for: presentation.ticket))
        XCTAssertTrue(monitor.invalidateCurrentFrameReadiness())
        // Resume before the next tick: a transient ineligibility must still
        // discard the old display tick without discarding an unflushed image.
        presentation.bridge.resumeFrameFeed()
        XCTAssertEqual(presentation.bridge.currentFrameReceipt(for: presentation.ticket), receipt)
        XCTAssertTrue(presentation.bridge.displayLayer.isReadyForDisplay)
        monitor.debugTick(displayTime: 40 + 1.0 / 60)
        XCTAssertEqual(completions, 0)
        monitor.debugTick(displayTime: 40 + 2.0 / 60)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(presentation.player.rate, 0)
        XCTAssertEqual(presentation.item.outputs.count, 1)
        XCTAssertEqual(presentation.bridge.submittedFrameCount, submissions)
        #else
        XCTFail("Current custom-frame contracts require DEBUG controls")
        #endif
    }

    private enum SetupFailure: Error { case notReady }
    @MainActor private final class SeekCompletion { var finished: Bool? }

    @MainActor private final class Presentation {
        let item: AVPlayerItem
        let resource: ContinuousPictureInPicture.PreparedVideoResource
        let bridge: ContinuousPictureInPicture
        let ticket: ContinuousPictureInPicture.PresentationTicket
        let player: AVPlayer
        let layer: AVPlayerLayer
        let window: UIWindow
        weak var previousKeyWindow: UIWindow?
        init(item: AVPlayerItem, resource: ContinuousPictureInPicture.PreparedVideoResource,
             bridge: ContinuousPictureInPicture, ticket: ContinuousPictureInPicture.PresentationTicket,
             player: AVPlayer, layer: AVPlayerLayer, window: UIWindow, previous: UIWindow?) {
            self.item = item; self.resource = resource; self.bridge = bridge; self.ticket = ticket
            self.player = player; self.layer = layer; self.window = window; previousKeyWindow = previous
        }
        func close() {
            player.pause(); bridge.invalidate(); player.replaceCurrentItem(with: nil)
            bridge.displayLayer.removeFromSuperlayer(); layer.removeFromSuperlayer()
            resource.retire(); window.isHidden = true; window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
    }

    private func makePresentation() async throws -> Presentation {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let item = AVPlayerItem(url: url)
        let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
        let resource = try XCTUnwrap(plan.install(ifEligible: { true }))
        let bridge = ContinuousPictureInPicture()
        var completed = false
        defer { if !completed { bridge.invalidate(); resource.retire() } }
        let ticket = try XCTUnwrap(bridge.setCurrentItem(item, preparedVideo: resource))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.windowLevel = .alert + 1
        let controller = UIViewController()
        window.rootViewController = controller
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let layer = AVPlayerLayer(player: player)
        layer.frame = window.bounds
        controller.view.layer.addSublayer(layer)
        bridge.displayLayer.frame = layer.bounds
        layer.addSublayer(bridge.displayLayer)
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let result = Presentation(item: item, resource: resource, bridge: bridge, ticket: ticket,
                                  player: player, layer: layer, window: window, previous: previous)
        do {
            player.playImmediately(atRate: 1)
            let nativeReady = await waitUntil { item.status == .readyToPlay && layer.isReadyForDisplay }
            player.pause()
            XCTAssertTrue(nativeReady)
            guard nativeReady else { throw SetupFailure.notReady }
            XCTAssertTrue(bridge.installTimeline(ticket, positionSeconds: 0, durationSeconds: 1.2, isPlaying: false))
            XCTAssertTrue(bridge.activate(ticket))
            let actualImage = await waitUntil {
                bridge.updatePlayback(positionSeconds: 0, durationSeconds: 1.2, isPlaying: false)
                #if DEBUG
                return bridge.debugCurrentFrameEpoch(for: ticket) != nil && bridge.displayLayer.isReadyForDisplay
                #else
                return false
                #endif
            }
            XCTAssertTrue(actualImage)
            guard actualImage else { throw SetupFailure.notReady }
            completed = true
            return result
        } catch { result.close(); throw error }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while true {
            if condition() { return true }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return false }
        }
    }
}
