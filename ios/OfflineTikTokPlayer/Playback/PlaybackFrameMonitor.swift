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
    private var decodedFrameEpoch: (() -> UInt64?)?
    private var link: CADisplayLink?
    private let target = TickTarget()
    private var readiness = PlaybackFrameReadiness()
    private var onReady: (() -> Void)?

    func start(item: AVPlayerItem, layer: AVPlayerLayer, decodedFrameEpoch: (() -> UInt64?)? = nil,
               onReady: @escaping () -> Void) {
        cancel()
        self.item = item; self.layer = layer; self.onReady = onReady
        self.decodedFrameEpoch = decodedFrameEpoch
        if decodedFrameEpoch == nil {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            output.suppressesPlayerRendering = false
            item.add(output); self.output = output
        }
        readiness = PlaybackFrameReadiness()
        target.owner = self
        let link = CADisplayLink(target: target, selector: #selector(TickTarget.tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }

    func cancel() {
        link?.invalidate(); link = nil
        if let item, let output { item.remove(output) }
        output = nil; item = nil; layer = nil; onReady = nil; decodedFrameEpoch = nil
        readiness = PlaybackFrameReadiness()
    }

    private func tick(_ link: CADisplayLink) {
        guard let item, let layer, layer.player?.currentItem === item else { cancel(); return }
        guard item.status == .readyToPlay else { return }
        let ready: Bool
        if let decodedFrameEpoch {
            ready = readiness.sampleCurrentFrame(epoch: decodedFrameEpoch(),
                layerReady: layer.isReadyForDisplay, displayTime: link.timestamp)
        }
        else if let output {
            let time = output.itemTime(forHostTime: link.targetTimestamp)
            let decoded = output.hasNewPixelBuffer(forItemTime: time.isValid ? time : item.currentTime())
            ready = readiness.sample(decodedFrame: decoded, layerReady: layer.isReadyForDisplay, displayTime: link.timestamp)
        } else { return }
        if ready {
            let completion = onReady
            cancel()
            completion?()
        }
    }

    deinit { link?.invalidate() }
}
