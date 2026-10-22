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
    struct DebugNativeReads {
        let displayTimestamp: Double, targetTimestamp: Double
        let mappedTime: CMTime, chosenTime: CMTime
        let decoded: Bool, layerReady: Bool, readinessAccepted: Bool
        let ownerAfterReadiness: Bool
        let mapping: DebugReadStamp, fallback: DebugReadStamp?
        let availability: DebugReadStamp, layer: DebugReadStamp
    }
    struct DebugInterval {
        let entryNs: UInt64, returnNs: UInt64
        var span: UInt64 { returnNs >= entryNs ? returnNs - entryNs : 0 }
    }
    struct DebugSpan {
        var count: UInt64 = 0
        var first: DebugInterval?, maximum: DebugInterval?
        var overflow = false
        mutating func append(_ entry: UInt64, _ returned: UInt64) {
            if count == .max { overflow = true } else { count += 1 }
            if returned < entry { overflow = true }
            let value = DebugInterval(entryNs: entry, returnNs: returned)
            if first == nil { first = value }
            if maximum == nil || value.span > maximum!.span { maximum = value }
        }
    }
    struct DebugLifecycle {
        let startEntryNs: UInt64
        var startBodyExitNs: UInt64?
        var startOwnerCoherent = false
        var firstTickEntryNs: UInt64?, lastTickBodyExitNs: UInt64?
        var ticks: UInt64 = 0, missingOwners: UInt64 = 0
        var identityRejected: UInt64 = 0, statusNotReady: UInt64 = 0, ownerChanges: UInt64 = 0
        var identity = DebugSpan(), status = DebugSpan(), tickBody = DebugSpan()
        var firstDecodedNs: UInt64?, firstLayerReadyNs: UInt64?
        var acceptedNs: UInt64?, cancelEntryNs: UInt64?, cancelReturnNs: UInt64?
        var completionEntryNs: UInt64?, completionReturnNs: UInt64?
        var completionPresent: Bool?
        // 0 missing app owners, 1 SDK identity rejected, 2 readiness accepted.
        var cancelReason: Int?
        var overflow = false
        mutating func increment(_ key: WritableKeyPath<DebugLifecycle, UInt64>) {
            if self[keyPath: key] == .max { overflow = true }
            else { self[keyPath: key] += 1 }
        }
    }
    struct DebugReadBatch {
        let epoch: UInt64
        let epochOverflowed: Bool
        let item: ObjectIdentifier, output: ObjectIdentifier
        let isStartBodyExit: Bool
        let lifecycle: DebugLifecycle
        let native: DebugNativeReads? // Nil means no native read set was performed.
    }
    @MainActor private final class DebugRequestState {
        let epoch: UInt64, epochOverflowed: Bool
        let item: ObjectIdentifier, layer: ObjectIdentifier, output: ObjectIdentifier
        let observer: (DebugReadBatch) -> Void
        var lifecycle: DebugLifecycle
        init(epoch: UInt64, epochOverflowed: Bool, item: AVPlayerItem, layer: AVPlayerLayer,
             output: AVPlayerItemVideoOutput, entry: UInt64, observer: @escaping (DebugReadBatch) -> Void) {
            self.epoch = epoch; self.epochOverflowed = epochOverflowed
            self.item = ObjectIdentifier(item); self.layer = ObjectIdentifier(layer)
            self.output = ObjectIdentifier(output); self.observer = observer
            lifecycle = DebugLifecycle(startEntryNs: entry)
        }
    }
    var onDebugReadBatch: ((DebugReadBatch) -> Void)? {
        didSet { if onDebugReadBatch == nil { debugRequestState = nil } }
    }
    private var debugRequestState: DebugRequestState?
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

    private func debugOwnerIsCurrent(_ state: DebugRequestState) -> Bool {
        debugRequestState === state && debugReadEpoch == state.epoch
            && item.map(ObjectIdentifier.init) == state.item
            && layer.map(ObjectIdentifier.init) == state.layer
            && output.map(ObjectIdentifier.init) == state.output
    }
    private func debugPublish(_ state: DebugRequestState, native: DebugNativeReads?, start: Bool = false) {
        state.observer(DebugReadBatch(epoch: state.epoch, epochOverflowed: state.epochOverflowed,
            item: state.item, output: state.output, isStartBodyExit: start,
            lifecycle: state.lifecycle, native: native))
    }
    private func debugStart(item: AVPlayerItem, layer: AVPlayerLayer, onReady: @escaping () -> Void,
                            observer: @escaping (DebugReadBatch) -> Void) {
        let entry = DispatchTime.now().uptimeNanoseconds
        // This cancels the previous owner. Never stamp its cancellation as the new epoch's.
        cancel()
        if debugReadEpoch == .max { debugReadEpochOverflowed = true } else { debugReadEpoch += 1 }
        self.item = item; self.layer = layer; self.onReady = onReady
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        output.suppressesPlayerRendering = false
        item.add(output); self.output = output
        let state = DebugRequestState(epoch: debugReadEpoch, epochOverflowed: debugReadEpochOverflowed,
            item: item, layer: layer, output: output, entry: entry, observer: observer)
        debugRequestState = state
        readiness = PlaybackFrameReadiness()
        target.owner = self
        let link = CADisplayLink(target: target, selector: #selector(TickTarget.tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
        state.lifecycle.startBodyExitNs = DispatchTime.now().uptimeNanoseconds
        state.lifecycle.startOwnerCoherent = debugOwnerIsCurrent(state)
        debugPublish(state, native: nil, start: true)
    }
    private func debugCancel(_ state: DebugRequestState, reason: Int) {
        if state.lifecycle.cancelEntryNs != nil { state.lifecycle.overflow = true }
        state.lifecycle.cancelReason = reason
        state.lifecycle.cancelEntryNs = DispatchTime.now().uptimeNanoseconds
        cancel()
        state.lifecycle.cancelReturnNs = DispatchTime.now().uptimeNanoseconds
    }
    private func debugFinishTick(_ state: DebugRequestState, entry: UInt64, native: DebugNativeReads?) {
        let exited = DispatchTime.now().uptimeNanoseconds
        state.lifecycle.lastTickBodyExitNs = exited
        state.lifecycle.tickBody.append(entry, exited)
        // Body exit excludes this observer's work and the eventual Swift function return.
        debugPublish(state, native: native)
    }
    private func debugSampleNativeReads(_ link: CADisplayLink, state: DebugRequestState) {
        let tickEntry = DispatchTime.now().uptimeNanoseconds // Before SDK guard getters.
        state.lifecycle.increment(\.ticks)
        if state.lifecycle.firstTickEntryNs == nil { state.lifecycle.firstTickEntryNs = tickEntry }
        guard let item, let layer, let output else {
            state.lifecycle.increment(\.missingOwners)
            state.lifecycle.increment(\.ownerChanges)
            debugCancel(state, reason: 0)
            debugFinishTick(state, entry: tickEntry, native: nil)
            return
        }
        let identityEntry = DispatchTime.now().uptimeNanoseconds
        let identityMatches = layer.player?.currentItem === item
        let identityReturn = DispatchTime.now().uptimeNanoseconds
        state.lifecycle.identity.append(identityEntry, identityReturn)
        if !debugOwnerIsCurrent(state) { state.lifecycle.increment(\.ownerChanges) }
        guard identityMatches else {
            state.lifecycle.increment(\.identityRejected)
            debugCancel(state, reason: 1)
            debugFinishTick(state, entry: tickEntry, native: nil)
            return
        }
        let statusEntry = DispatchTime.now().uptimeNanoseconds
        let status = item.status
        let statusReturn = DispatchTime.now().uptimeNanoseconds
        state.lifecycle.status.append(statusEntry, statusReturn)
        if !debugOwnerIsCurrent(state) { state.lifecycle.increment(\.ownerChanges) }
        guard status == .readyToPlay else {
            state.lifecycle.increment(\.statusNotReady)
            debugFinishTick(state, entry: tickEntry, native: nil)
            return
        }
        @MainActor func read<Value>(_ stage: DebugReadStage, _ operation: @MainActor () -> Value) -> (Value, DebugReadStamp) {
            let entry = DispatchTime.now().uptimeNanoseconds
            let value = operation()
            let returned = DispatchTime.now().uptimeNanoseconds
            return (value, DebugReadStamp(stage: stage, entryNs: entry, returnNs: returned,
                                          ownerCoherent: debugOwnerIsCurrent(state)))
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
        if decoded, state.lifecycle.firstDecodedNs == nil { state.lifecycle.firstDecodedNs = availability.returnNs }
        if layerReady, state.lifecycle.firstLayerReadyNs == nil { state.lifecycle.firstLayerReadyNs = layerRead.returnNs }
        let displayTimestamp = link.timestamp
        let accepted = readiness.sample(decodedFrame: decoded, layerReady: layerReady, displayTime: displayTimestamp)
        if accepted {
            if state.lifecycle.acceptedNs != nil { state.lifecycle.overflow = true }
            state.lifecycle.acceptedNs = DispatchTime.now().uptimeNanoseconds
            let completion = onReady
            debugCancel(state, reason: 2)
            state.lifecycle.completionPresent = completion != nil
            state.lifecycle.completionEntryNs = DispatchTime.now().uptimeNanoseconds
            completion?()
            state.lifecycle.completionReturnNs = DispatchTime.now().uptimeNanoseconds
        }
        let native = DebugNativeReads(displayTimestamp: displayTimestamp, targetTimestamp: targetTimestamp,
            mappedTime: time, chosenTime: chosenTime, decoded: decoded, layerReady: layerReady,
            readinessAccepted: accepted, ownerAfterReadiness: debugOwnerIsCurrent(state),
            mapping: mapping, fallback: fallback, availability: availability, layer: layerRead)
        debugFinishTick(state, entry: tickEntry, native: native)
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
        #if DEBUG
        if let observer = onDebugReadBatch {
            debugStart(item: item, layer: layer, onReady: onReady, observer: observer)
            return
        }
        #endif
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
        #if DEBUG
        debugRequestState = nil // Clear at entry; an executing traced tick retains its local owner.
        #endif
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
        if onDebugReadBatch != nil, let state = debugRequestState {
            debugSampleNativeReads(link, state: state)
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
