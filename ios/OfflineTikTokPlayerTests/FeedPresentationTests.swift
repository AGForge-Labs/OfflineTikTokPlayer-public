import XCTest
import SwiftUI
import Observation
import AVFoundation
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class FeedPresentationTests: XCTestCase {
    func testPosterAndVideoHostSurvivePreviewPlaybackAndHistory() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let state = SurfaceTestModel()
        window.rootViewController = UIHostingController(rootView: SurfaceHarness(model: state))
        window.frame = scene.coordinateSpace.bounds; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let root = try XCTUnwrap(window.rootViewController?.view)
        try await waitUntil { root.layoutIfNeeded(); return descendants(root).contains { $0 is PageMarkerView } }
        let poster = try XCTUnwrap(descendants(root).first { $0 is PageMarkerView })
        let host = try XCTUnwrap(descendants(root).compactMap { $0 as? PlayerSurfaceHost }.first)
        for (active, ready) in [(true, false), (true, true), (false, false), (true, false), (true, true)] {
            state.active = active; state.ready = ready
            try await Task.sleep(for: .milliseconds(30)); root.layoutIfNeeded()
            XCTAssertTrue(descendants(root).first { $0 is PageMarkerView } === poster)
            XCTAssertTrue(descendants(root).compactMap { $0 as? PlayerSurfaceHost }.first === host)
            if active { XCTAssertTrue(state.surface.superview === host) }
            else { XCTAssertNil(state.surface.superview) }
        }
    }

    func testFirstFrameMonitorHandlesPausedAndPreparedItemsAndDetachesItsOutput() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller
        window.frame = scene.coordinateSpace.bounds; window.isHidden = false
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let first = AVPlayerItem(url: url), second = AVPlayerItem(url: url)
        let player = AVQueuePlayer(items: [first, second])
        let surface = PlayerSurface(player: player)
        controller.view.addSubview(surface); surface.frame = controller.view.bounds
        let monitor = PlaybackFrameMonitor()
        defer { monitor.cancel(); player.pause(); player.removeAllItems(); window.isHidden = true; window.rootViewController = nil }
        var callbacks = 0
        monitor.start(item: first, layer: surface.playerLayer) { callbacks += 1 }
        // A restored queue starts paused; its poster still needs to uncover the actual paused frame.
        try await waitUntil { callbacks == 1 }
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(first.outputs.isEmpty)
        let seeked = await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: 0.4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(seeked)
        monitor.start(item: first, layer: surface.playerLayer) { callbacks += 1 }
        try await waitUntil { callbacks == 2 }
        XCTAssertEqual(player.currentTime().seconds, 0.4, accuracy: 0.05)
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(first.outputs.isEmpty)
        player.advanceToNextItem()
        monitor.start(item: second, layer: surface.playerLayer) { callbacks += 1 }
        player.play()
        try await waitUntil { callbacks == 3 }
        XCTAssertTrue(second.outputs.isEmpty)
        monitor.start(item: second, layer: surface.playerLayer) { XCTFail("Cancelled monitor called back") }
        monitor.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(second.outputs.isEmpty)
    }

    func testDismantlingThePreviousPageCannotRemoveTheVideoFromItsNewHost() {
        let player = AVPlayer()
        let surface = PlayerSurface(player: player)
        let layer = surface.playerLayer
        let previous = PlayerSurfaceHost(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let current = PlayerSurfaceHost(frame: CGRect(x: 0, y: 0, width: 430, height: 700))
        previous.attach(surface)
        current.attach(surface)
        previous.detach()
        current.layoutIfNeeded()
        XCTAssertTrue(surface.superview === current)
        XCTAssertEqual(surface.frame, current.bounds)
        XCTAssertTrue(surface.playerLayer === layer)
        XCTAssertTrue(surface.playerLayer.player === player)
        current.detach()
        XCTAssertNil(surface.superview)
    }

    func testPagingUsesTheActualViewportAndPreservesTheArrivingView() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let model = FeedTestModel()
        window.rootViewController = UIHostingController(rootView: FeedHarness(model: model))
        window.frame = scene.coordinateSpace.bounds
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let root = try XCTUnwrap(window.rootViewController?.view)
        try await waitUntil { root.layoutIfNeeded(); return model.markers["0:b"]?.window != nil }
        let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? UIScrollView }.first)
        let current = try XCTUnwrap(model.markers["0:b"])
        try await waitUntil {
            root.layoutIfNeeded()
            return abs(current.convert(current.bounds, to: scroll).midY - scroll.bounds.midY) < 1
        }
        let viewport = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
        XCTAssertEqual(current.bounds.height, viewport, accuracy: 1)
        let arriving = model.markers["1:c"]
        _ = model.queue.next()
        try await waitUntil {
            root.layoutIfNeeded()
            guard let next = model.markers["1:c"] else { return false }
            return abs(next.convert(next.bounds, to: scroll).midY - scroll.bounds.midY) < 1
        }
        XCTAssertTrue(model.markers["0:b"] === current)
        if let arriving { XCTAssertTrue(model.markers["1:c"] === arriving) }
        _ = model.queue.next()
        try await waitUntil {
            root.layoutIfNeeded()
            guard let next = model.markers["2:d"] else { return false }
            return abs(next.convert(next.bounds, to: scroll).midY - scroll.bounds.midY) < 1
        }
        _ = model.queue.previous()
        try await waitUntil {
            root.layoutIfNeeded()
            guard let previous = model.markers["1:c"] else { return false }
            return abs(previous.convert(previous.bounds, to: scroll).midY - scroll.bounds.midY) < 1
        }
        XCTAssertLessThanOrEqual(descendants(scroll).filter { $0 is PageMarkerView }.count, 3)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "Feed did not settle in its viewport")
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

@MainActor @Observable
private final class FeedTestModel {
    var queue = PlaybackQueue(ids: ["a", "b", "c", "d"], startAt: "b")
    @ObservationIgnored var markers: [String: PageMarkerView] = [:]
}

private struct FeedHarness: View {
    let model: FeedTestModel
    var body: some View {
        VStack(spacing: 0) {
            Color.black.frame(height: 40)
            FeedPager(window: model.queue.feedWindow, didSettle: { window, landedID in
                let direction = window.settledDirection(at: landedID, currentWindow: model.queue.feedWindow)
                if direction > 0 { _ = model.queue.next() }
                else if direction < 0 { _ = model.queue.previous() }
                return model.queue.feedWindow
            }, interactionChanged: { _ in }) { page in
                PageMarker(id: page.id, model: model)
            }
            Color.black.frame(height: 70)
        }.background(.black)
    }
}

private final class PageMarkerView: UIView {}

@MainActor @Observable
private final class SurfaceTestModel {
    var active = false
    var ready = false
    let surface = PlayerSurface(player: AVPlayer())
}
private struct SurfaceHarness: View {
    let model: SurfaceTestModel
    var body: some View {
        FeedVideoSurface(surface: model.surface, isActive: model.active, isReady: model.ready) {
            SimplePosterMarker()
        }
    }
}
private struct SimplePosterMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> PageMarkerView { let view = PageMarkerView(); view.backgroundColor = .green; return view }
    func updateUIView(_ uiView: PageMarkerView, context: Context) {}
}
private struct PageMarker: UIViewRepresentable {
    let id: String
    let model: FeedTestModel
    func makeUIView(context: Context) -> PageMarkerView {
        let view = PageMarkerView()
        view.backgroundColor = .green
        model.markers[id] = view
        return view
    }
    func updateUIView(_ uiView: PageMarkerView, context: Context) {}
}
