import AVFoundation
import UIKit
import PlayerCore

/// Observes only the arriving item's first decoded frame, without replacing AVPlayerLayer rendering.
@MainActor
final class PlaybackFrameMonitor {
    @MainActor private final class TickTarget: NSObject {
        weak var owner: PlaybackFrameMonitor?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
    private weak var item: AVPlayerItem?
    private weak var layer: AVPlayerLayer?
    private var output: AVPlayerItemVideoOutput?
    private var link: CADisplayLink?
    private let target = TickTarget()
    private var readiness = PlaybackFrameReadiness()
    private var onReady: (() -> Void)?
    #if DEBUG
    private var decodedFrameEpoch: (() -> UInt64?)?
    private var currentFrameEpoch: UInt64?
    // Contract controls can replace display-link scheduling, never frame/layer proof.
    var debugAutomaticallyTicks = true
    func debugTick(displayTime: Double) {
        guard !debugAutomaticallyTicks, decodedFrameEpoch != nil else { return }
        sampleCurrentFrame(displayTime: displayTime)
    }

    /// Diagnostic alternative: consumes an actual custom enqueue without another output.
    func start(item: AVPlayerItem, layer: AVPlayerLayer,
               decodedFrameEpoch: @escaping () -> UInt64?, onReady: @escaping () -> Void) {
        cancel()
        self.item = item; self.layer = layer; self.onReady = onReady
        self.decodedFrameEpoch = decodedFrameEpoch
        readiness = PlaybackFrameReadiness()
        target.owner = self
        if debugAutomaticallyTicks {
            let link = CADisplayLink(target: target, selector: #selector(TickTarget.tick(_:)))
            link.add(to: .main, forMode: .common); self.link = link
        }
    }

    private func resetCurrentFrameReadiness() {
        currentFrameEpoch = nil
        readiness = PlaybackFrameReadiness()
    }
    private func sampleCurrentFrame(displayTime: Double) {
        guard let item, let layer, layer.player?.currentItem === item else { cancel(); return }
        guard item.status == .readyToPlay else { resetCurrentFrameReadiness(); return }
        guard let epoch = decodedFrameEpoch?() else { resetCurrentFrameReadiness(); return }
        if currentFrameEpoch != epoch {
            resetCurrentFrameReadiness()
            currentFrameEpoch = epoch
        }
        if readiness.sample(decodedFrame: true, layerReady: layer.isReadyForDisplay, displayTime: displayTime) {
            let completion = onReady
            cancel()
            completion?()
        }
    }
    #endif

    func start(item: AVPlayerItem, layer: AVPlayerLayer, onReady: @escaping () -> Void) {
        cancel()
        self.item = item; self.layer = layer; self.onReady = onReady
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        output.suppressesPlayerRendering = false
        item.add(output); self.output = output
        readiness = PlaybackFrameReadiness()
        target.owner = self
        let link = CADisplayLink(target: target, selector: #selector(TickTarget.tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }

    func cancel() {
        link?.invalidate(); link = nil
        if let item, let output { item.remove(output) }
        output = nil; item = nil; layer = nil; onReady = nil
        #if DEBUG
        decodedFrameEpoch = nil
        resetCurrentFrameReadiness()
        #endif
    }

    private func tick(_ link: CADisplayLink) {
        #if DEBUG
        if decodedFrameEpoch != nil {
            sampleCurrentFrame(displayTime: link.timestamp)
            return
        }
        #endif
        guard let item, let layer, let output, layer.player?.currentItem === item else { cancel(); return }
        guard item.status == .readyToPlay else { return }
        let time = output.itemTime(forHostTime: link.targetTimestamp)
        let decoded = output.hasNewPixelBuffer(forItemTime: time.isValid ? time : item.currentTime())
        if readiness.sample(decodedFrame: decoded, layerReady: layer.isReadyForDisplay, displayTime: link.timestamp) {
            let completion = onReady
            cancel()
            completion?()
        }
    }

    deinit { link?.invalidate() }
}
