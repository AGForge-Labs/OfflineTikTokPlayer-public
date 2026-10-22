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
    enum DebugReadStage: Int, CaseIterable { case mapping = 0, fallback = 1, availability = 2, layerReady = 3 }
    struct DebugReadStamp {
        let stage: DebugReadStage
        let entryNs: UInt64, returnNs: UInt64
        let ownerCoherent: Bool
    }
    struct DebugReadBatch {
        let epoch: UInt64
        let epochOverflowed: Bool
        let item: ObjectIdentifier, output: ObjectIdentifier
        let displayTimestamp: Double, targetTimestamp: Double
        let mappedTime: CMTime, chosenTime: CMTime
        let decoded: Bool, layerReady: Bool, readinessAccepted: Bool
        let ownerAfterReadiness: Bool
        let mapping: DebugReadStamp, fallback: DebugReadStamp?
        let availability: DebugReadStamp, layer: DebugReadStamp
    }
    var onDebugReadBatch: ((DebugReadBatch) -> Void)?
    private var debugReadEpoch: UInt64 = 0
    private var debugReadEpochOverflowed = false
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

    private func debugSampleNativeReads(_ link: CADisplayLink, item: AVPlayerItem,
        layer: AVPlayerLayer, output: AVPlayerItemVideoOutput,
        observer: (DebugReadBatch) -> Void) {
        let epoch = debugReadEpoch
        @MainActor func read<Value>(_ stage: DebugReadStage, _ operation: @MainActor () -> Value) -> (Value, DebugReadStamp) {
            let entry = DispatchTime.now().uptimeNanoseconds
            let value = operation()
            let returned = DispatchTime.now().uptimeNanoseconds
            // App-owned coherence only; do not add another SDK identity getter.
            let coherent = debugReadEpoch == epoch && self.item === item
                && self.layer === layer && self.output === output
            return (value, DebugReadStamp(stage: stage, entryNs: entry, returnNs: returned,
                                          ownerCoherent: coherent))
        }
        let targetTimestamp = link.targetTimestamp
        let (time, mapping) = read(.mapping) { output.itemTime(forHostTime: targetTimestamp) }
        var chosenTime = time
        var fallback: DebugReadStamp?
        if !time.isValid {
            let result = read(.fallback) { item.currentTime() }
            chosenTime = result.0; fallback = result.1
        }
        let (decoded, availability) = read(.availability) { output.hasNewPixelBuffer(forItemTime: chosenTime) }
        let (layerReady, layerRead) = read(.layerReady) { layer.isReadyForDisplay }
        let displayTimestamp = link.timestamp
        let accepted = readiness.sample(decodedFrame: decoded, layerReady: layerReady, displayTime: displayTimestamp)
        if accepted {
            let completion = onReady
            cancel()
            completion?()
        }
        // Operation-return coherence was captured BEFORE expected terminal cancel.
        // Deliver only after original readiness/cancel/completion ordering.
        observer(DebugReadBatch(epoch: epoch, epochOverflowed: debugReadEpochOverflowed,
            item: ObjectIdentifier(item), output: ObjectIdentifier(output),
            displayTimestamp: displayTimestamp, targetTimestamp: targetTimestamp,
            mappedTime: time, chosenTime: chosenTime, decoded: decoded, layerReady: layerReady,
            readinessAccepted: accepted, ownerAfterReadiness: debugReadEpoch == epoch
                && self.item === item && self.layer === layer && self.output === output,
            mapping: mapping, fallback: fallback, availability: availability, layer: layerRead))
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
        #if DEBUG
        if onDebugReadBatch != nil {
            if debugReadEpoch == UInt64.max { debugReadEpochOverflowed = true }
            else { debugReadEpoch += 1 }
        }
        #endif
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
        #if DEBUG
        if let observer = onDebugReadBatch {
            debugSampleNativeReads(link, item: item, layer: layer, output: output, observer: observer)
            return
        }
        #endif
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
