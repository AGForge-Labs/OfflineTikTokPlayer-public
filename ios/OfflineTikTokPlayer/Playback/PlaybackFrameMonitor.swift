import AVFoundation
import UIKit
import PlayerCore

/// Observes the selected surface's first image, allowing two fresh display ticks.
@MainActor
final class PlaybackFrameMonitor {
    @MainActor private final class TickTarget: NSObject {
        weak var owner: PlaybackFrameMonitor?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
    private weak var item: AVPlayerItem?
    private weak var layer: AVPlayerLayer?
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var output: AVPlayerItemVideoOutput?
    private var link: CADisplayLink?
    private let target = TickTarget()
    private var readiness = PlaybackFrameReadiness()
    private var onReady: (() -> Void)?
    private final class Request {}
    private var request: Request?
    private var lifecycle: Request?
    private var receiptProvider: (() -> ContinuousPictureInPicture.CurrentFrameReceipt?)?
    private var currentReceipt: ContinuousPictureInPicture.CurrentFrameReceipt?
    private var readinessSerial: UInt64 = 0
    private var onCurrentFrameReady: ((ContinuousPictureInPicture.CurrentFrameReceipt) -> Void)?

    /// The output is owned by CPP. This monitor neither pulls it nor detaches it.
    func start(item: AVPlayerItem, layer: AVPlayerLayer, displayLayer: AVSampleBufferDisplayLayer,
               currentFrameReceipt: @escaping () -> ContinuousPictureInPicture.CurrentFrameReceipt?,
               onReady: @escaping (ContinuousPictureInPicture.CurrentFrameReceipt) -> Void) {
        let cancelled = cancelRequest()
        guard lifecycle === cancelled else { return }
        let request = Request()
        self.request = request; lifecycle = request
        self.item = item; self.layer = layer; self.displayLayer = displayLayer
        receiptProvider = currentFrameReceipt; onCurrentFrameReady = onReady
        readiness = PlaybackFrameReadiness()
        target.owner = self
        #if DEBUG
        if !debugAutomaticallyTicks { return }
        #endif
        let link = CADisplayLink(target: target, selector: #selector(TickTarget.tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }

    private func resetCurrentFrameReadiness() {
        readinessSerial &+= 1
        currentReceipt = nil
        readiness = PlaybackFrameReadiness()
    }
    /// Keep a pending monitor/output-free display link, but discard its ticks.
    /// A completed/legacy monitor needs a new start instead.
    @discardableResult
    func invalidateCurrentFrameReadiness() -> Bool {
        guard request != nil, receiptProvider != nil else { return false }
        resetCurrentFrameReadiness()
        return true
    }
    private func sampleCurrentFrame(displayTime: Double) {
        guard let request else { return }
        guard let item, let layer, let displayLayer, let receiptProvider else {
            if self.request === request { cancel() }
            return
        }
        let entryReadinessSerial = readinessSerial
        let selected = layer.player?.currentItem === item
        guard self.request === request, readinessSerial == entryReadinessSerial else { return }
        guard selected else { cancel(); return }
        let status = item.status
        guard self.request === request, readinessSerial == entryReadinessSerial else { return }
        guard status == .readyToPlay else { resetCurrentFrameReadiness(); return }
        guard let receipt = receiptProvider() else {
            if self.request === request { resetCurrentFrameReadiness() }
            return
        }
        guard self.request === request, readinessSerial == entryReadinessSerial else { return }
        if currentReceipt != receipt {
            resetCurrentFrameReadiness()
            currentReceipt = receipt
        }
        let sampledReadinessSerial = readinessSerial
        let layerReady = displayLayer.isReadyForDisplay
        // The SDK getter may reenter a seek, source change or replacement start.
        let receiptAfterRead = receiptProvider()
        guard self.request === request, readinessSerial == sampledReadinessSerial,
              receiptAfterRead == receipt else {
            if self.request === request { resetCurrentFrameReadiness() }
            return
        }
        guard readiness.sample(decodedFrame: true, layerReady: layerReady, displayTime: displayTime) else { return }
        let completion = onCurrentFrameReady
        let cancelled = cancelRequest()
        let receiptAfterCancel = receiptProvider()
        guard lifecycle === cancelled, self.request == nil, receiptAfterCancel == receipt else { return }
        completion?(receipt)
    }
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
    // Contract controls can replace display-link scheduling, never frame/layer proof.
    var debugAutomaticallyTicks = true
    var debugHasActiveRequest: Bool { request != nil }
    func debugTick(displayTime: Double) {
        guard !debugAutomaticallyTicks, receiptProvider != nil else { return }
        sampleCurrentFrame(displayTime: displayTime)
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
        let cancelled = cancelRequest()
        guard lifecycle === cancelled else { return }
        let request = Request()
        self.request = request; lifecycle = request
        if debugReadEpoch == .max { debugReadEpochOverflowed = true } else { debugReadEpoch += 1 }
        self.item = item; self.layer = layer; self.onReady = onReady
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        output.suppressesPlayerRendering = false
        self.output = output
        item.add(output)
        guard self.request === request else { return }
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
    @discardableResult
    private func debugCancel(_ state: DebugRequestState, reason: Int) -> Request? {
        guard debugOwnerIsCurrent(state) else { return nil }
        if state.lifecycle.cancelEntryNs != nil { state.lifecycle.overflow = true }
        state.lifecycle.cancelReason = reason
        state.lifecycle.cancelEntryNs = DispatchTime.now().uptimeNanoseconds
        let cancelled = cancelRequest()
        state.lifecycle.cancelReturnNs = DispatchTime.now().uptimeNanoseconds
        return cancelled
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
        guard debugOwnerIsCurrent(state) else {
            state.lifecycle.increment(\.ownerChanges)
            debugFinishTick(state, entry: tickEntry, native: nil)
            return
        }
        let accepted = readiness.sample(decodedFrame: decoded, layerReady: layerReady, displayTime: displayTimestamp)
        if accepted {
            if state.lifecycle.acceptedNs != nil { state.lifecycle.overflow = true }
            state.lifecycle.acceptedNs = DispatchTime.now().uptimeNanoseconds
            let completion = onReady
            let cancelled = debugCancel(state, reason: 2)
            state.lifecycle.completionPresent = completion != nil
            state.lifecycle.completionEntryNs = DispatchTime.now().uptimeNanoseconds
            if let cancelled, lifecycle === cancelled, request == nil { completion?() }
            state.lifecycle.completionReturnNs = DispatchTime.now().uptimeNanoseconds
        }
        let native = DebugNativeReads(displayTimestamp: displayTimestamp, targetTimestamp: targetTimestamp,
            mappedTime: time, chosenTime: chosenTime, decoded: decoded, layerReady: layerReady,
            readinessAccepted: accepted, ownerAfterReadiness: debugOwnerIsCurrent(state),
            mapping: mapping, fallback: fallback, availability: availability, layer: layerRead)
        debugFinishTick(state, entry: tickEntry, native: native)
    }

    #endif

    func start(item: AVPlayerItem, layer: AVPlayerLayer, onReady: @escaping () -> Void) {
        #if DEBUG
        if let observer = onDebugReadBatch {
            debugStart(item: item, layer: layer, onReady: onReady, observer: observer)
            return
        }
        #endif
        let cancelled = cancelRequest()
        guard lifecycle === cancelled else { return }
        let request = Request()
        self.request = request; lifecycle = request
        self.item = item; self.layer = layer; self.onReady = onReady
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        output.suppressesPlayerRendering = false
        self.output = output
        item.add(output)
        guard self.request === request else { return }
        readiness = PlaybackFrameReadiness()
        target.owner = self
        let link = CADisplayLink(target: target, selector: #selector(TickTarget.tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }

    func cancel() {
        _ = cancelRequest()
    }

    private func cancelRequest() -> Request {
        let cancelled = Request()
        lifecycle = cancelled
        let oldLink = link, oldItem = item, oldOutput = output
        request = nil
        link = nil; output = nil; item = nil; layer = nil; displayLayer = nil
        onReady = nil; onCurrentFrameReady = nil; receiptProvider = nil
        resetCurrentFrameReadiness()
        #if DEBUG
        debugRequestState = nil // Clear at entry; an executing traced tick retains its local owner.
        #endif
        // SDK cleanup uses captured old owners; reentrant start owns new fields.
        oldLink?.invalidate()
        if let oldItem, let oldOutput { oldItem.remove(oldOutput) }
        return cancelled
    }

    private func tick(_ link: CADisplayLink) {
        guard self.link === link else { return }
        if receiptProvider != nil {
            sampleCurrentFrame(displayTime: link.timestamp)
            return
        }
        #if DEBUG
        if onDebugReadBatch != nil, let state = debugRequestState {
            debugSampleNativeReads(link, state: state)
            return
        }
        #endif
        guard let request, let item, let layer, let output else { return }
        let selected = layer.player?.currentItem === item
        guard self.request === request else { return }
        guard selected else { cancel(); return }
        let status = item.status
        guard self.request === request, status == .readyToPlay else { return }
        let time = output.itemTime(forHostTime: link.targetTimestamp)
        guard self.request === request else { return }
        let decoded = output.hasNewPixelBuffer(forItemTime: time.isValid ? time : item.currentTime())
        guard self.request === request else { return }
        let layerReady = layer.isReadyForDisplay
        guard self.request === request else { return }
        if readiness.sample(decodedFrame: decoded, layerReady: layerReady, displayTime: link.timestamp) {
            let completion = onReady
            let cancelled = cancelRequest()
            guard lifecycle === cancelled, self.request == nil else { return }
            completion?()
        }
    }

    deinit { link?.invalidate() }
}
