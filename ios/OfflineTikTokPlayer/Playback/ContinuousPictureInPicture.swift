import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation
import UIKit
import CoreFoundation
import IOSurface
import PlayerCore

/// A video-only PiP surface. Its supported sample-buffer delegate forwards user commands to
/// the service that owns continuous audio; muted AVPlayer rate changes are never user commands.
/// The caller must add displayLayer to its visible inline surface and keep its bounds current.
@MainActor
final class ContinuousPictureInPicture: NSObject {
    /// The renderer returns another CVPixelBuffer wrapper around the submitted
    /// IOSurface and drops custom attachments. Keep only a bounded identity/PTS
    /// table for this epoch, never a decoded-frame queue or pixel copies.
    @MainActor fileprivate final class FrameSurfaces {
        private struct Entry {
            // Only a non-IOSurface fallback needs a retained wrapper identity.
            let buffer: CVPixelBuffer?
            let surface: UInt32?
            let position: Double
        }
        private var entries: [Entry?] = Array(repeating: nil, count: 8)
        private var next = 0
        private func surfaceID(_ pixel: CVPixelBuffer) -> UInt32? {
            CVPixelBufferGetIOSurface(pixel).map { IOSurfaceGetID($0.takeUnretainedValue()) }
        }
        func record(_ pixel: CVPixelBuffer, position: Double) {
            let surface = surfaceID(pixel)
            let entry = Entry(buffer: surface == nil ? pixel : nil, surface: surface, position: position)
            if let index = entries.firstIndex(where: { old in
                old.map { VideoImageIdentity.matches(sourceSurface: $0.surface, displayedSurface: surface,
                    sameRetainedBuffer: $0.buffer === pixel) } ?? false
            }) { entries[index] = entry }
            else { entries[next] = entry; next = (next + 1) % entries.count }
        }
        func position(for pixel: CVPixelBuffer?, presentationPosition: Double) -> Double? {
            guard let pixel else { return nil }
            let surface = surfaceID(pixel)
            for entry in entries {
                if let entry, VideoImageIdentity.isPresented(sourceSurface: entry.surface, displayedSurface: surface,
                    sameRetainedBuffer: entry.buffer === pixel, framePosition: entry.position,
                    presentationPosition: presentationPosition) { return entry.position }
            }
            return nil
        }
    }
    struct PresentationTicket: Equatable, Sendable {
        fileprivate let generation: Int
        fileprivate let item: ObjectIdentifier
        #if DEBUG
        var debugItemIdentity: ObjectIdentifier { item }
        var debugGeneration: Int { generation }
        #endif
    }
    /// Cached credit for one accepted image, bound to the pull's original owner.
    /// Reading this value never asks AVFoundation for another frame.
    struct CurrentFrameReceipt: Equatable, Sendable {
        let ticket: PresentationTicket
        let output: ObjectIdentifier
        let imageEpoch: UInt64
        let seekSerial: UInt64
        fileprivate let surfaces: FrameSurfaces

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.ticket == rhs.ticket && lhs.output == rhs.output && lhs.imageEpoch == rhs.imageEpoch
                && lhs.seekSerial == rhs.seekSerial && lhs.surfaces === rhs.surfaces
        }

        @MainActor func matchesDisplayedImage(in layer: AVSampleBufferDisplayLayer) -> Bool {
            displayedPosition(in: layer) != nil
        }
        @MainActor fileprivate func displayedPosition(in layer: AVSampleBufferDisplayLayer) -> Double? {
            guard let clock = layer.controlTimebase else { return nil }
            let pixel = layer.sampleBufferRenderer.displayedPixelBuffer()
            return surfaces.position(for: pixel, presentationPosition: CMTimebaseGetTime(clock).seconds)
        }
    }
    /// Ownership of an installed, active timeline. This never credits an image.
    struct ActiveTimelineReceipt: Equatable, Sendable {
        let ticket: PresentationTicket
        let output: ObjectIdentifier
        let imageEpoch: UInt64
        let seekSerial: UInt64
    }
    private var imageEpoch: UInt64 = 0
    private var surfaceProof = FrameSurfaces()
    private var imageEpochSaturated = false
    private var submittedReceipt: CurrentFrameReceipt?
    private var readinessMutationDepth = 0
    private var readinessUpdatePending = false
    /// Invalidation is immediate. Stable delivery is coalesced across nested CPP
    /// and service mutations, so a callback cannot adopt a half-installed source.
    var onCurrentFrameInvalidated: (() -> Void)?
    var onCurrentFrameStateChanged: (() -> Void)?
    var onClockAlignmentRequired: ((PresentationTicket) -> Void)?

    func beginReadinessUpdates() { readinessMutationDepth += 1 }
    func endReadinessUpdates() {
        precondition(readinessMutationDepth > 0)
        readinessMutationDepth -= 1
        guard readinessMutationDepth == 0, readinessUpdatePending else { return }
        readinessUpdatePending = false
        onCurrentFrameStateChanged?()
    }
    @discardableResult
    private func invalidateCurrentFrameProof() -> UInt64 {
        submittedReceipt = nil
        surfaceProof = FrameSurfaces()
        if imageEpoch == .max { imageEpochSaturated = true }
        else { imageEpoch += 1 }
        lastEnqueuedTime = .invalid
        lastFramePositionSeconds = nil
        lastCopiedFramePositionSeconds = nil
        readinessUpdatePending = true
        let invalidatedEpoch = imageEpoch
        onCurrentFrameInvalidated?()
        return invalidatedEpoch
    }
    private func invalidateFrameEligibility() {
        readinessUpdatePending = true
        onCurrentFrameInvalidated?()
    }
    func frameReadinessEpoch(for ticket: PresentationTicket) -> UInt64? {
        guard owns(ticket), !imageEpochSaturated else { return nil }
        return imageEpoch
    }
    func currentFrameReceipt(for ticket: PresentationTicket) -> CurrentFrameReceipt? {
        guard let receipt = submittedReceipt, receipt.ticket == ticket,
              ownsFramePull(receipt) else { return nil }
        return receipt
    }
    private(set) var hasDisplayedImage = false
    func acknowledgeDisplayedFrame(_ receipt: CurrentFrameReceipt) {
        guard currentFrameReceipt(for: receipt.ticket) == receipt else { return }
        hasDisplayedImage = true
    }
    /// Read actual renderer output, not enqueue activity or the muted player's clock.
    func displayedFramePosition(for ticket: PresentationTicket) -> Double? {
        guard let receipt = currentFrameReceipt(for: ticket),
              let position = receipt.displayedPosition(in: displayLayer),
              position.isFinite, currentFrameReceipt(for: ticket) == receipt else { return nil }
        return position
    }
    /// Cached proof only. A completed paused seek may still await its first image.
    func activeTimelineReceipt(for ticket: PresentationTicket) -> ActiveTimelineReceipt? {
        guard owns(ticket), presentationActive, frameFeedEnabled,
              installedTimeline == ticket, activeSeekTicket == nil,
              !imageEpochSaturated, let videoOutput else { return nil }
        let receipt = ActiveTimelineReceipt(ticket: ticket, output: ObjectIdentifier(videoOutput),
            imageEpoch: imageEpoch, seekSerial: seekTicket)
        // A missing current-frame receipt must not launder stale submitted credit.
        if let submittedReceipt {
            guard submittedReceipt.ticket == receipt.ticket, submittedReceipt.output == receipt.output,
                  submittedReceipt.imageEpoch == receipt.imageEpoch,
                  submittedReceipt.seekSerial == receipt.seekSerial else { return nil }
        }
        return receipt
    }
    private func ownsFramePull(_ receipt: CurrentFrameReceipt) -> Bool {
        owns(receipt.ticket) && presentationActive && frameFeedEnabled
            && installedTimeline == receipt.ticket && activeSeekTicket == nil
            && !imageEpochSaturated && imageEpoch == receipt.imageEpoch
            && seekTicket == receipt.seekSerial
            && videoOutput.map(ObjectIdentifier.init) == receipt.output
    }
    /// One output per retained item. Retirement is explicit; no SDK work runs in deinit.
    @MainActor final class PreparedVideoResource {
        #if DEBUG
        fileprivate(set) var debugSuppressesPlayerRendering = false
        fileprivate(set) var debugNativeGeometry: VideoResourcePreparation.NativeVideoGeometry?
        var debugNativeGeometryValidated: Bool { debugNativeGeometry != nil }
        fileprivate(set) var debugUsesNativeGeometry = false
        var debugInstalledComposition: AVVideoComposition? { installedComposition }
        #endif
        private(set) weak var item: AVPlayerItem?
        fileprivate(set) var output: AVPlayerItemVideoOutput?
        fileprivate(set) var isAttached = false
        fileprivate var preferredFrameRate: Float = 60
        fileprivate var sourceFrameRate: Float = 30
        private(set) var isRetired = false
        private(set) var isBorrowed = false
        fileprivate var originalComposition: AVVideoComposition?
        fileprivate var installedComposition: AVVideoComposition?
        fileprivate init(item: AVPlayerItem) { self.item = item }
        func borrow(for item: AVPlayerItem) -> Bool {
            guard self.item === item, isAttached, !isRetired, !isBorrowed, let output else { return false }
            let attached = item.outputs.contains(where: { $0 === output })
            guard attached, self.item === item, isAttached, !isRetired, !isBorrowed,
                  self.output === output else { return false }
            isBorrowed = true
            return true
        }
        func releaseBorrow() {
            guard isBorrowed else { return }
            isBorrowed = false
            if isRetired { detach() }
        }
        func retire() {
            isRetired = true
            if !isBorrowed { detach() }
        }
        /// Replace only the picture tap. The item, native clock and audio tracks
        /// remain installed. Publish the new owner before SDK removal can reenter.
        fileprivate func rebuildOutput(ifEligible: () -> Bool,
                                       publish: (AVPlayerItemVideoOutput) -> Void) -> Bool {
            guard let item, let old = output, isAttached, isBorrowed, ifEligible() else { return false }
            let replacement = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
            replacement.suppressesPlayerRendering = old.suppressesPlayerRendering
            guard ifEligible(), output === old, isAttached, isBorrowed else { return false }
            item.add(replacement)
            guard ifEligible(), output === old, isAttached, isBorrowed else {
                item.remove(replacement); return false
            }
            output = replacement
            publish(replacement)
            let oldStillAttached = item.outputs.contains(where: { $0 === old })
            if oldStillAttached { item.remove(old) }
            return ifEligible() && output === replacement && isAttached && isBorrowed
        }
        private func detach() {
            let wasAttached = isAttached, output = self.output
            let installed = installedComposition, original = originalComposition
            isAttached = false; self.output = nil
            installedComposition = nil; originalComposition = nil
            guard let item else { return }
            if wasAttached, let output { item.remove(output) }
            if let installed, item.videoComposition === installed { item.videoComposition = original }
        }
    }
    /// Metadata only until install. Stale tasks cannot leave an attached output across an await.
    @MainActor final class VideoResourcePreparation {
        /// Geometry permission only, not proof of arbitrary source/edit stability.
        struct NativeVideoGeometry: Equatable {
            let width: Int32
            let height: Int32
            private init(width: Int32, height: Int32) { self.width = width; self.height = height }
            static func validate(naturalSize: CGSize, preferredTransform: CGAffineTransform,
                                 formatDescriptions: [CMFormatDescription]) -> NativeVideoGeometry? {
                guard preferredTransform == .identity,
                      naturalSize.width.isFinite, naturalSize.height.isFinite,
                      naturalSize.width > 0, naturalSize.height > 0,
                      naturalSize.width.rounded() == naturalSize.width,
                      naturalSize.height.rounded() == naturalSize.height,
                      naturalSize.width <= CGFloat(Int32.max), naturalSize.height <= CGFloat(Int32.max),
                      !formatDescriptions.isEmpty else { return nil }
                let width = Int32(naturalSize.width), height = Int32(naturalSize.height)
                let fullAperture = CGRect(origin: .zero, size: naturalSize)
                for description in formatDescriptions {
                    guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video else { return nil }
                    let coded = CMVideoFormatDescriptionGetDimensions(description)
                    guard coded.width == width, coded.height == height else { return nil }
                    if let value = CMFormatDescriptionGetExtension(description,
                        extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) {
                        guard let fields = value as? [String: Any],
                              let horizontal = scalar(fields[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String]),
                              let vertical = scalar(fields[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String]),
                              horizontal > 0, horizontal <= Double(Int32.max), horizontal.rounded() == horizontal,
                              vertical == horizontal else { return nil }
                    }
                    if let value = CMFormatDescriptionGetExtension(description,
                        extensionKey: kCMFormatDescriptionExtension_CleanAperture) {
                        guard let fields = value as? [String: Any],
                              scalar(fields[kCMFormatDescriptionKey_CleanApertureWidth as String]) == Double(width),
                              scalar(fields[kCMFormatDescriptionKey_CleanApertureHeight as String]) == Double(height),
                              scalar(fields[kCMFormatDescriptionKey_CleanApertureHorizontalOffset as String]) == 0,
                              scalar(fields[kCMFormatDescriptionKey_CleanApertureVerticalOffset as String]) == 0 else { return nil }
                    }
                    guard CMVideoFormatDescriptionGetCleanAperture(description, originIsAtTopLeft: true) == fullAperture,
                          CMVideoFormatDescriptionGetPresentationDimensions(description,
                            usePixelAspectRatio: true, useCleanAperture: false) == naturalSize,
                          CMVideoFormatDescriptionGetPresentationDimensions(description,
                            usePixelAspectRatio: true, useCleanAperture: true) == naturalSize else { return nil }
                }
                return NativeVideoGeometry(width: width, height: height)
            }
            private static func scalar(_ value: Any?) -> Double? {
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
                return number.doubleValue
            }
        }
        private weak var item: AVPlayerItem?
        private var original: AVVideoComposition?
        private var composition: AVVideoComposition?
        private var consumed = false
        #if DEBUG
        fileprivate weak var debugTraceOwner: ContinuousPictureInPicture?
        private var debugSuppressesPlayerRendering = false
        /// Select only before this one-shot plan attaches its output.
        func install(debugSuppressesPlayerRendering: Bool,
                     ifEligible: () -> Bool = { true }) -> PreparedVideoResource? {
            guard !consumed else { return nil }
            self.debugSuppressesPlayerRendering = debugSuppressesPlayerRendering
            return install(ifEligible: ifEligible)
        }
        #endif
        fileprivate weak var nativeAsset: AVURLAsset?
        fileprivate var nativeGeometry: NativeVideoGeometry?
        private var usesNativeGeometry = false
        private var nativeFrameRate: Float = 60
        private var sourceFrameRate: Float = 30
        fileprivate init(item: AVPlayerItem, original: AVVideoComposition?, composition: AVVideoComposition) {
            self.item = item; self.original = original; self.composition = composition
        }
        fileprivate init(item: AVPlayerItem, asset: AVURLAsset, nativeGeometry: NativeVideoGeometry, frameRate: Float = 60) {
            self.item = item; nativeAsset = asset; self.nativeGeometry = nativeGeometry
            usesNativeGeometry = true
            sourceFrameRate = frameRate.isFinite && frameRate > 0 ? frameRate : 30
            nativeFrameRate = min(120, max(60, sourceFrameRate))
        }
        private func installNative(ifEligible: () -> Bool) -> PreparedVideoResource? {
            guard !consumed else { return nil }
            consumed = true
            defer { composition = nil; original = nil }
            guard let item, let asset = nativeAsset, nativeGeometry != nil,
                  ifEligible(), item.asset === asset, item.videoComposition == nil else { return nil }
            let resource = PreparedVideoResource(item: item)
            resource.preferredFrameRate = nativeFrameRate
            resource.sourceFrameRate = sourceFrameRate
            #if DEBUG
            resource.debugNativeGeometry = nativeGeometry; resource.debugUsesNativeGeometry = true
            #endif
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
            #if DEBUG
            output.suppressesPlayerRendering = debugSuppressesPlayerRendering
            resource.debugSuppressesPlayerRendering = debugSuppressesPlayerRendering
            #else
            output.suppressesPlayerRendering = false
            #endif
            guard ifEligible(), item.asset === asset, item.videoComposition == nil else { resource.retire(); return nil }
            #if DEBUG
            if let owner = debugTraceOwner {
                owner.debugTraceRender(.outputAttached) { item.add(output) }
            } else { item.add(output) }
            #else
            item.add(output)
            #endif
            resource.output = output; resource.isAttached = true
            guard ifEligible(), item.asset === asset, item.videoComposition == nil else { resource.retire(); return nil }
            return resource
        }
        func install(ifEligible: () -> Bool = { true }) -> PreparedVideoResource? {
            if usesNativeGeometry { return installNative(ifEligible: ifEligible) }
            guard !consumed else { return nil }
            consumed = true
            defer { composition = nil; original = nil }
            #if DEBUG
            if nativeGeometry != nil {
                guard let item, let asset = nativeAsset, item.asset === asset else { return nil }
            }
            #endif
            guard let item, let composition, ifEligible(),
                  item.videoComposition === original else { return nil }
            let resource = PreparedVideoResource(item: item)
            let cadence = composition.frameDuration.seconds
            guard ifEligible() else { resource.retire(); return nil }
            if cadence.isFinite, cadence > 0 {
                resource.preferredFrameRate = Float(min(120, max(60, 1 / cadence)))
                resource.sourceFrameRate = Float(1 / cadence)
            }
            #if DEBUG
            resource.debugNativeGeometry = nativeGeometry
            #endif
            if original == nil {
                resource.originalComposition = original
                #if DEBUG
                if let owner = debugTraceOwner {
                    owner.debugTraceRender(.compositionAssigned) {
                        item.videoComposition = composition
                        resource.installedComposition = item.videoComposition
                    }
                } else {
                    item.videoComposition = composition
                    resource.installedComposition = item.videoComposition
                }
                #else
                item.videoComposition = composition
                resource.installedComposition = item.videoComposition
                #endif
            }
            guard ifEligible() else { resource.retire(); return nil }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
            #if DEBUG
            output.suppressesPlayerRendering = debugSuppressesPlayerRendering
            resource.debugSuppressesPlayerRendering = debugSuppressesPlayerRendering
            #else
            output.suppressesPlayerRendering = false
            #endif
            guard ifEligible() else { resource.retire(); return nil }
            #if DEBUG
            if let owner = debugTraceOwner {
                owner.debugTraceRender(.outputAttached) { item.add(output) }
            } else { item.add(output) }
            #else
            item.add(output)
            #endif
            resource.output = output; resource.isAttached = true
            guard ifEligible() else { resource.retire(); return nil }
            return resource
        }
    }
    static func prepareVideoResource(for item: AVPlayerItem) async throws -> VideoResourcePreparation {
        let original = item.videoComposition
        if original == nil {
            do {
                if let native = try await prepareNativeVideoResource(for: item) { return native }
            } catch {
                try Task.checkCancellation()
                // Unqualified or unavailable native metadata keeps the existing
                // transform/edit composition path, rather than rejecting playback.
            }
        }
        let composition: AVVideoComposition
        if let original { composition = original }
        else { composition = try await makeVideoComposition(for: item.asset) }
        try Task.checkCancellation()
        return VideoResourcePreparation(item: item, original: original, composition: composition)
    }
    private static func prepareNativeVideoResource(for item: AVPlayerItem) async throws -> VideoResourcePreparation? {
        guard item.videoComposition == nil, let asset = item.asset as? AVURLAsset,
              asset.url.isFileURL || asset.url.scheme == "https" else { return nil }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first, try await track.load(.isEnabled) else {
            return nil
        }
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let descriptions = try await track.load(.formatDescriptions)
        let duration = try await asset.load(.duration), range = try await track.load(.timeRange)
        let segments = try await track.load(.segments)
        let minimumFrameDuration = try await track.load(.minFrameDuration)
        try Task.checkCancellation()
        guard duration.isNumeric, CMTimeCompare(duration, .zero) > 0, range.start.isNumeric,
              range.duration.isNumeric, CMTimeCompare(range.start, .zero) == 0,
              NativeVideoCoverage.allowsNativePresentation(start: range.start.seconds,
                end: CMTimeRangeGetEnd(range).seconds, assetDuration: duration.seconds,
                frameDuration: minimumFrameDuration.seconds),
              segments.count == 1, let segment = segments.first, !segment.isEmpty else {
            return nil
        }
        let mapping = segment.timeMapping
        guard mapping.source.start.isNumeric, mapping.target.start.isNumeric,
              mapping.source.duration.isNumeric, mapping.target.duration.isNumeric,
              CMTimeCompare(mapping.source.start, .zero) >= 0,
              CMTimeCompare(mapping.target.start, .zero) == 0,
              CMTimeCompare(mapping.source.duration, range.duration) == 0,
              CMTimeCompare(mapping.target.duration, range.duration) == 0,
              CMTimeCompare(CMTimeRangeGetEnd(mapping.target), CMTimeRangeGetEnd(range)) == 0,
              item.asset === asset, item.videoComposition == nil,
              let geometry = VideoResourcePreparation.NativeVideoGeometry.validate(naturalSize: natural,
                preferredTransform: transform, formatDescriptions: descriptions) else {
            return nil
        }
        let fps = try await track.load(.nominalFrameRate)
        try Task.checkCancellation()
        return VideoResourcePreparation(item: item, asset: asset, nativeGeometry: geometry, frameRate: fps)
    }
    #if DEBUG
    enum DebugNativeGeometryFailure: Error { case unqualified }
    /// Keep an explicit composed control for the same qualified local source.
    static func debugPrepareVideoResource(for item: AVPlayerItem, nativeGeometry enabled: Bool) async throws -> VideoResourcePreparation {
        guard let asset = item.asset as? AVURLAsset, asset.url.isFileURL,
              let native = try await prepareNativeVideoResource(for: item) else {
            throw DebugNativeGeometryFailure.unqualified
        }
        if enabled { return native }
        let composition = try await makeVideoComposition(for: asset)
        try Task.checkCancellation()
        guard item.asset === asset, item.videoComposition == nil else { throw DebugNativeGeometryFailure.unqualified }
        let plan = VideoResourcePreparation(item: item, original: nil, composition: composition)
        plan.nativeAsset = native.nativeAsset; plan.nativeGeometry = native.nativeGeometry
        return plan
    }
    #endif
    #if DEBUG
    struct DebugNativeSeekState: Equatable, Sendable {
        let serial: UInt64
        let activeTicket: UInt64?
    }
    // App-owned scalars only: no player, item, output or timebase query.
    var debugNativeSeekState: DebugNativeSeekState {
        DebugNativeSeekState(serial: seekTicket, activeTicket: activeSeekTicket)
    }
    /// Observes the actual SDK request without replacing its result.
    var onFrameAcquisition: ((AVPlayerItem, CMTime) -> Void)?
    // Timing-only test gate. A refusal leaves the same active timeline/epoch intact.
    // Nil adds no SDK read, clock, task, counter or Release behavior.
    var shouldDebugAcquireFrame: (@MainActor (CurrentFrameReceipt) -> Bool)?
    enum DebugNativePullStage: Int, CaseIterable, Sendable {
        case availability = 0, copy = 1, enqueue = 2
    }
    struct DebugNativePullStamp: Sendable {
        let stage: DebugNativePullStage
        // Source captured at renderFrame entry, before callbacks, not relabeled at call time.
        let ticket: PresentationTicket?
        let item: ObjectIdentifier?, output: ObjectIdentifier
        let entryRevision: Int, returnRevision: Int
        let sourceNativeSeekTicket: UInt64?
        let nativeSeekTicket: UInt64, activeSeekTicket: UInt64?
        let entryNs: UInt64, returnNs: UInt64
        let entryOwnerCoherent: Bool, ownerUnchanged: Bool
    }
    // Separate from legacy point stamps and their capacity/masks.
    var onDebugNativePullStamp: (@MainActor (DebugNativePullStamp) -> Void)?
    enum DebugWholeFrameStage: Int, Sendable {
        case resourceGuard, seekGuard, activeGuard, itemGuard, ownerGuard, acquisitionGuard
        case layerStatus, ownerAfterStatus, failedLayerRecovery, backpressure, ownerAfterBackpressure
        case timebase, numericTimeGuard, acquisitionObserver, ownerAfterAcquisitionObserver
        case availability, availabilityGuard, ownerBeforeCopy, copy, copyGuard, ownerAfterCopy
        case copiedPixelObserver, ownerAfterCopiedPixelObserver, timestampCredit, pausedFutureGuard
        case increasingTimeGuard, leadGuard, formatCreation, formatGuard, sampleCreation
        case sampleGuard, ownerBeforeEnqueue, enqueue, ownerAfterEnqueue, imageCredit, enqueued
    }
    struct DebugWholeFrameInterval: Sendable {
        let entryNs: UInt64, returnNs: UInt64
    }
    struct DebugWholeFrameEntry: Sendable {
        let ordinal: UInt64, entryNs: UInt64
        let state: DebugAlignedPollState
        let ordinalSaturated: Bool
    }
    struct DebugWholeFrameSpan: Sendable {
        let entry: DebugWholeFrameEntry
        let returnNs: UInt64, returnedState: DebugAlignedPollState
        let stage: DebugWholeFrameStage
        let layerStatus: DebugWholeFrameInterval?, backpressure: DebugWholeFrameInterval?
        let timebase: DebugWholeFrameInterval?, acquisitionObserver: DebugWholeFrameInterval?
        let readinessCommit: DebugWholeFrameInterval?, entryObserverDelivery: DebugWholeFrameInterval?
        let layerFailed: Bool?, readyForMore: Bool?, requestedNumeric: Bool?
        let availability: Bool?, copied: Bool?, enqueueCalled: Bool
    }
    enum DebugWholeFrameEvent: Sendable {
        case entered(DebugWholeFrameEntry), returned(DebugWholeFrameSpan)
    }
    // Optional scalar observations only. No history, task, output or SDK query.
    var onDebugWholeFrame: (@MainActor (DebugWholeFrameEvent) -> Void)?
    private var debugWholeFrameOrdinal: UInt64 = 0
    private func debugNativePull<T>(_ stage: DebugNativePullStage,
        sourceTicket: PresentationTicket?, sourceNativeSeekTicket: UInt64?, output: AVPlayerItemVideoOutput,
        _ operation: @MainActor () -> T) -> T {
        guard let observer = onDebugNativePullStamp else { return operation() }
        let revision = presentationRevision, nativeSeek = seekTicket, activeSeek = activeSeekTicket
        let enteredOwner = (sourceTicket.map { owns($0) } ?? false)
            && videoOutput === output && activeSeek == nil && sourceNativeSeekTicket == nativeSeek
        let entered = DispatchTime.now().uptimeNanoseconds
        let result = operation()
        let returned = DispatchTime.now().uptimeNanoseconds
        let unchanged = enteredOwner && (sourceTicket.map { owns($0) } ?? false)
            && videoOutput === output && revision == presentationRevision
            && nativeSeek == seekTicket && activeSeek == activeSeekTicket
        observer(DebugNativePullStamp(stage: stage, ticket: sourceTicket,
            item: sourceTicket?.item, output: ObjectIdentifier(output),
            entryRevision: revision, returnRevision: presentationRevision,
            sourceNativeSeekTicket: sourceNativeSeekTicket,
            nativeSeekTicket: nativeSeek, activeSeekTicket: activeSeek,
            entryNs: entered, returnNs: returned,
            entryOwnerCoherent: enteredOwner, ownerUnchanged: unchanged))
        return result
    }
    // Cached proof only: no output pull or SDK query is performed by its getter.
    private var debugImageEpoch: UInt64 { imageEpoch }
    private var debugImageEpochSaturated: Bool { imageEpochSaturated }
    func debugCurrentFrameEpoch(for ticket: PresentationTicket) -> UInt64? {
        currentFrameReceipt(for: ticket)?.imageEpoch
    }
    struct DebugAlignedPollState: Sendable {
        let ticket: PresentationTicket?, output: ObjectIdentifier?
        let seekSerial: UInt64, activeSeekTicket: UInt64?, imageEpoch: UInt64
        let coherent: Bool
    }
    var debugAlignedPollState: DebugAlignedPollState {
        let ticket = currentItem.map { PresentationTicket(generation: presentationRevision, item: ObjectIdentifier($0)) }
        return DebugAlignedPollState(ticket: ticket, output: videoOutput.map { ObjectIdentifier($0) },
            seekSerial: seekTicket, activeSeekTicket: activeSeekTicket, imageEpoch: debugImageEpoch,
            coherent: !invalidated && presentationActive && frameFeedEnabled && !debugImageEpochSaturated
                && ticket.map { owns($0) } == true && installedTimeline == ticket && activeSeekTicket == nil)
    }
    struct DebugAlignedEnqueueStamp: Sendable {
        let ticket: PresentationTicket?, output: ObjectIdentifier
        let seekSerial: UInt64, imageEpoch: UInt64
        let renderEntryNs: UInt64, enqueuedNs: UInt64
        let entryCoherent: Bool, afterCopyCoherent: Bool
        let beforeEnqueueCoherent: Bool, afterEnqueueCoherent: Bool
        let requestedSeconds: Double, sampleSeconds: Double, submittedCount: UInt64
        var coherent: Bool { entryCoherent && afterCopyCoherent && beforeEnqueueCoherent && afterEnqueueCoherent }
    }
    var onDebugAlignedEnqueue: ((DebugAlignedEnqueueStamp) -> Void)? {
        didSet { debugAlignedCreditedRevision = nil }
    }
    private var debugAlignedCreditedRevision: Int?
    private struct DebugAlignedPullContext {
        let ticket: PresentationTicket?, output: ObjectIdentifier
        let seekSerial: UInt64, imageEpoch: UInt64, entryNs: UInt64
        var coherent: Bool = false
    }
    private func debugAlignedOwnerMatches(_ value: DebugAlignedPullContext) -> Bool {
        !invalidated && presentationActive && frameFeedEnabled && !debugImageEpochSaturated
            && value.ticket.map { owns($0) } == true
            && installedTimeline == value.ticket
            && videoOutput.map { ObjectIdentifier($0) } == value.output
            && activeSeekTicket == nil && seekTicket == value.seekSerial && debugImageEpoch == value.imageEpoch
    }
    private func debugAlignedPullContext(_ ticket: PresentationTicket?, output: AVPlayerItemVideoOutput) -> DebugAlignedPullContext? {
        guard onDebugAlignedEnqueue != nil, debugAlignedCreditedRevision != presentationRevision else { return nil }
        var result = DebugAlignedPullContext(ticket: ticket, output: ObjectIdentifier(output),
            seekSerial: seekTicket, imageEpoch: debugImageEpoch, entryNs: DispatchTime.now().uptimeNanoseconds)
        result.coherent = debugAlignedOwnerMatches(result)
        return result
    }
    private func debugObserveAlignedEnqueue(_ value: DebugAlignedPullContext?, afterCopy: Bool,
        beforeEnqueue: Bool, afterEnqueue: Bool, enqueuedNs: UInt64?, requested: CMTime, sample: CMTime) {
        guard let value, let enqueuedNs, let observer = onDebugAlignedEnqueue else { return }
        let requestedSeconds = CMTimeGetSeconds(requested), sampleSeconds = CMTimeGetSeconds(sample)
        guard requestedSeconds.isFinite, sampleSeconds.isFinite, requestedSeconds >= 0, sampleSeconds >= 0,
              abs(sampleSeconds - requestedSeconds) <= 0.080 else { return }
        let coherent = value.coherent && afterCopy && beforeEnqueue && afterEnqueue
        if coherent { debugAlignedCreditedRevision = value.ticket?.generation }
        observer(DebugAlignedEnqueueStamp(ticket: value.ticket, output: value.output,
            seekSerial: value.seekSerial, imageEpoch: value.imageEpoch,
            renderEntryNs: value.entryNs, enqueuedNs: enqueuedNs,
            entryCoherent: value.coherent, afterCopyCoherent: afterCopy,
            beforeEnqueueCoherent: beforeEnqueue, afterEnqueueCoherent: afterEnqueue,
            requestedSeconds: requestedSeconds, sampleSeconds: sampleSeconds, submittedCount: submittedFrameCount))
    }
    enum DebugRenderStage: Int, Sendable {
        case attempt = 0, hasNewFalse = 1, hasNewTrue = 2, copied = 3, enqueued = 4
        case seekBegin = 5, compositionAssigned = 6, outputAttached = 7, seekBlocked = 8
    }
    struct DebugRenderStamp: Sendable {
        let stage: DebugRenderStage
        // 0 before any seek, 1 while a seek is active, 2 after that first seek.
        let region: Int
        let ticket: PresentationTicket?
        let presentationRevision: Int
        let ownershipUnchanged: Bool
        let nativeSeekTicket: UInt64?
        let entryNs: UInt64, returnNs: UInt64
        let requestedSeconds: Double?, sampleSeconds: Double?
        // Cached values at entry; seekBegin therefore preserves the pre-flush proof.
        let copiedPTS: Double?, submittedPTS: Double?, submittedCount: UInt64
        // 0 setup/no current resource, 1 CPP-owned fallback, 2 borrowed buffer preparation.
        let resourceOwnership: Int
    }
    var onDebugRenderStamp: ((DebugRenderStamp) -> Void)?
    struct DebugCopiedPixelContext {
        let pull: CurrentFrameReceipt
        let requestedTime: CMTime, rawDisplayTime: CMTime
    }
    // Synchronous borrowed pixel only. Observers retain scalar audit results;
    // the actual buffer is never put in a cross-thread or retained receipt.
    var onDebugCopiedPixel: ((CVPixelBuffer, DebugCopiedPixelContext) -> Void)?
    private var debugRenderRevision: Int?
    private var debugBeforeMask: UInt16 = 0, debugDuringMask: UInt16 = 0, debugAfterMask: UInt16 = 0
    private var debugRenderSawSeek = false
    private func debugTraceRender(_ stage: DebugRenderStage, requested: CMTime? = nil,
                                  sample: CMTime? = nil, sourceTicket: PresentationTicket? = nil,
                                  _ operation: () -> Void = {}) {
        guard let observer = onDebugRenderStamp else { operation(); return }
        let revision = sourceTicket?.generation ?? presentationRevision
        if debugRenderRevision != revision {
            debugRenderRevision = revision
            debugBeforeMask = 0; debugDuringMask = 0; debugAfterMask = 0; debugRenderSawSeek = false
        }
        if activeSeekTicket != nil { debugRenderSawSeek = true }
        let region = activeSeekTicket != nil ? 1 : (debugRenderSawSeek ? 2 : 0)
        let bit = UInt16(1) << stage.rawValue
        let mask = region == 0 ? debugBeforeMask : (region == 1 ? debugDuringMask : debugAfterMask)
        guard mask & bit == 0 else { operation(); return }
        if region == 0 { debugBeforeMask |= bit }
        else if region == 1 { debugDuringMask |= bit }
        else { debugAfterMask |= bit }
        let ticket = sourceTicket ?? currentItem.map { PresentationTicket(generation: revision, item: ObjectIdentifier($0)) }
        let activeSeek = activeSeekTicket
        let seek = activeSeekTicket ?? (debugRenderSawSeek ? seekTicket : nil)
        let copied = lastCopiedFramePositionSeconds, submitted = lastFramePositionSeconds
        let count = submittedFrameCount
        let entered = DispatchTime.now().uptimeNanoseconds
        operation()
        let returned = DispatchTime.now().uptimeNanoseconds
        observer(DebugRenderStamp(stage: stage, region: region, ticket: ticket, presentationRevision: revision,
            ownershipUnchanged: revision == presentationRevision
                && ticket?.item == currentItem.map { ObjectIdentifier($0) } && activeSeek == activeSeekTicket,
            nativeSeekTicket: seek, entryNs: entered, returnNs: returned,
            requestedSeconds: requested.flatMap { $0.isNumeric ? CMTimeGetSeconds($0) : nil },
            sampleSeconds: sample.flatMap { $0.isNumeric ? CMTimeGetSeconds($0) : nil },
            copiedPTS: copied, submittedPTS: submitted, submittedCount: count,
            resourceOwnership: currentResource == nil ? 0 : (currentResourceOwned ? 1 : 2)))
    }
    #endif
    enum Event: Int {
        case willStart = 0
        case didStart = 1
        case willStop = 2
        case didStop = 3
        case startFailed = 4
        case frameFailed = 5
        case restoreRequested = 6
        case restoreCompleted = 7
        case restoreUnavailable = 8
        case userPlayRequested = 9
        case userPauseRequested = 10
        case userSkipRequested = 11
        case sourcePrepared = 12
        case sourcePreparationFailed = 13
    }

    let displayLayer = AVSampleBufferDisplayLayer()
    private(set) var controller: AVPictureInPictureController?
    private(set) var submittedFrameCount: UInt64 = 0
    private(set) var lastFramePositionSeconds: Double?
    private(set) var lastCopiedFramePositionSeconds: Double?
    private(set) var pausedFutureFrameRejectionCount: UInt64 = 0
    private(set) var blockedFrameAcquisitionCount: UInt64 = 0
    private(set) var orientationPrepared = false
    var onSetPlaying: ((Bool) -> Void)?
    /// Complete after the service has applied or rejected the seek, including cancellation.
    var onSkip: ((Double, @escaping () -> Void) -> Void)?
    /// Complete true only after the inline UI has actually been restored.
    var onRestoreUI: ((@escaping (Bool) -> Void) -> Void)?
    var onStateChanged: ((Bool, Bool, Bool) -> Void)?
    var onEvent: ((Event, Int?) -> Void)?

    nonisolated private let playbackState = ContinuousPiPPlaybackState()
    private weak var currentItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var observations: [NSKeyValueObservation] = []
    private var frameTimer: Timer?
    private var displayLink: CADisplayLink?
    @MainActor private final class DisplayTarget: NSObject {
        weak var owner: ContinuousPictureInPicture?
        @objc func tick(_ link: CADisplayLink) { owner?.renderFrame(targetHostTime: link.targetTimestamp) }
    }
    private let displayTarget = DisplayTarget()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var timebase: CMTimebase?
    private var format: CMVideoFormatDescription?
    private var formatWidth = 0
    private var formatHeight = 0
    private var formatPixelType: OSType = 0
    private var lastEnqueuedTime = CMTime.invalid
    private var hasReportedFrameFailure = false
    private var invalidated = false
    private var frameFeedEnabled = true
    private var preparationTask: Task<Void, Never>?
    private var itemGeneration = 0
    private var presentationRevision = 0
    private var installedTimeline: PresentationTicket?
    private var presentationActive = false
    private var seekTicket: UInt64 = 0
    private var activeSeekTicket: UInt64?
    private var currentResource: PreparedVideoResource?
    private var currentResourceOwned = false
    // currentItem/ticket identify the audible selection. Only hard native-audio
    // recovery gives its picture output a distinct, permanently muted decoder.
    private var isolatedVideo: IsolatedVideoRecovery?
    private final class IsolatedRequest {}
    private var isolatedRequest: IsolatedRequest?
    private var isolatedPreparation: Task<Void, Never>?
    private var pendingIsolatedPreparations: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var pendingRecoveryDrains: [UUID: Task<Void, Never>] = [:]
    private var dormantAudioResource: (resource: PreparedVideoResource, owned: Bool)?
    #if DEBUG
    var debugPresentationItem: AVPlayerItem? { currentResource?.item }
    var debugUsesIsolatedVideo: Bool { isolatedVideo != nil }
    #endif

    var isReady: Bool { !invalidated && controller != nil && timebase != nil }
    var isFrameFeedSuspended: Bool { !frameFeedEnabled }
    var isFrameFeedRunning: Bool { frameTimer != nil || displayLink != nil }
    var isVideoReadyForDisplay: Bool { displayLayer.isReadyForDisplay }
    var imageRecoveryGraceSeconds: Double {
        let rate = Double(currentResource?.sourceFrameRate ?? 30)
        return rate.isFinite && rate > 0 ? min(30, max(1.5, 3 / rate)) : 3
    }
    var requestedPositionSeconds: Double { playbackState.read().position }
    var timebasePositionSeconds: Double? {
        guard let timebase else { return nil }
        let seconds = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
        return seconds.isFinite ? seconds : nil
    }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        var createdTimebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                          sourceClock: CMClockGetHostTimeClock(),
                                          timebaseOut: &createdTimebase) == noErr {
            timebase = createdTimebase
            displayLayer.controlTimebase = createdTimebase
            if let createdTimebase {
                CMTimebaseSetTime(createdTimebase, time: .zero)
                CMTimebaseSetRate(createdTimebase, rate: 0)
            }
        }
        displayTarget.owner = self
        for event in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.invalidated else { return }
                    self.stopFrameTimer()
                    if self.frameFeedEnabled && self.playbackState.read().isPlaying { self.startFrameTimer() }
                }
            })
        }
        guard timebase != nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                playbackDelegate: self)
        let createdController: AVPictureInPictureController? = AVPictureInPictureController(contentSource: source)
        guard let pip = createdController else { return }
        pip.delegate = self
        controller = pip
        observations = [
            pip.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.reportState() }
            },
            pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.reportState() }
            },
            pip.observe(\.isPictureInPictureSuspended, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.reportState() }
            }
        ]
    }

    /// One active output is borrowed here; the buffer can retain prepared outputs for its bounded window.
    @discardableResult
    func setCurrentItem(_ item: AVPlayerItem?, preparedVideo: PreparedVideoResource? = nil) -> PresentationTicket? {
        guard !invalidated else { return nil }
        beginReadinessUpdates()
        defer { endReadinessUpdates() }
        presentationRevision &+= 1
        installedTimeline = nil
        presentationActive = false
        activeSeekTicket = nil
        stopFrameTimer()
        let adoptionRevision = presentationRevision
        cancelIsolatedPreparation()
        let ticket = item.map { PresentationTicket(generation: presentationRevision, item: ObjectIdentifier($0)) }
        invalidateCurrentFrameProof()
        guard !invalidated, presentationRevision == adoptionRevision else { return nil }
        if currentItem === item, currentResource?.isRetired != true,
           isolatedVideo != nil || preparedVideo == nil || preparedVideo === currentResource {
            // A new service request for the same item needs its own timeline,
            // while its output and in-flight geometry preparation stay reusable.
            flushForSeek(removingImage: item == nil)
            return ticket
        }
        preparationTask?.cancel()
        preparationTask = nil
        stopFrameTimer()
        itemGeneration &+= 1
        activeSeekTicket = nil
        let generation = itemGeneration
        releaseCurrentResource()
        guard !invalidated, presentationRevision == adoptionRevision else { return nil }
        currentItem = item
        videoOutput = nil
        orientationPrepared = false
        format = nil
        hasReportedFrameFailure = false
        flushForSeek(removingImage: item == nil)
        guard !invalidated, presentationRevision == adoptionRevision else { return nil }
        guard let item else { stopFrameTimer(); return nil }
        if let preparedVideo, preparedVideo.borrow(for: item), let output = preparedVideo.output {
            guard !invalidated, presentationRevision == adoptionRevision, currentItem === item else {
                preparedVideo.releaseBorrow(); return nil
            }
            currentResource = preparedVideo; currentResourceOwned = false; videoOutput = output
            orientationPrepared = true
            // No late preparation occurred. The existing ready/rewind/restore path
            // owns first activation, including paused and nonzero selections.
            return ticket
        }
        preparationTask = Task { [weak self, weak item] in
            guard let item else { return }
            do {
                let plan = try await Self.prepareVideoResource(for: item)
                try Task.checkCancellation()
                guard let self, !self.invalidated, self.itemGeneration == generation,
                      self.currentItem === item else { return }
                #if DEBUG
                plan.debugTraceOwner = self
                #endif
                guard let resource = plan.install(ifEligible: {
                    !Task.isCancelled && !self.invalidated && self.itemGeneration == generation && self.currentItem === item
                }) else { return }
                guard !Task.isCancelled, !self.invalidated, self.itemGeneration == generation,
                      self.currentItem === item, resource.borrow(for: item) else {
                    resource.retire(); return
                }
                guard !Task.isCancelled, !self.invalidated, self.itemGeneration == generation,
                      self.currentItem === item, let output = resource.output else {
                    resource.retire(); resource.releaseBorrow(); return
                }
                self.currentResource = resource; self.currentResourceOwned = true; self.videoOutput = output
                self.orientationPrepared = true
                self.renderFrame()
                if self.presentationActive && self.frameFeedEnabled && self.playbackState.read().isPlaying { self.startFrameTimer() }
                self.onEvent?(.sourcePrepared, nil)
            } catch {
                guard !Task.isCancelled, let self, !self.invalidated, self.itemGeneration == generation,
                      self.currentItem === item else { return }
                self.onEvent?(.sourcePreparationFailed, (error as NSError).code)
            }
        }
        return ticket
    }

    /// Bind the selected audio timeline before any output pull. Ordinary polling
    /// can update this state, but cannot authorize a newly adopted presentation.
    @discardableResult
    func installTimeline(_ ticket: PresentationTicket, positionSeconds: Double,
                         durationSeconds: Double, isPlaying: Bool) -> Bool {
        guard owns(ticket) else { return false }
        beginReadinessUpdates()
        defer { endReadinessUpdates() }
        let seek = seekTicket, activeSeek = activeSeekTicket
        presentationActive = false
        installedTimeline = nil
        stopFrameTimer()
        applyPlayback(positionSeconds: positionSeconds, durationSeconds: durationSeconds,
                      isPlaying: isPlaying, forceAnchor: true)
        guard owns(ticket), seekTicket == seek, activeSeekTicket == activeSeek else { return false }
        installedTimeline = ticket
        return true
    }

    @discardableResult
    func activate(_ ticket: PresentationTicket) -> Bool {
        guard owns(ticket), installedTimeline == ticket, activeSeekTicket == nil else { return false }
        beginReadinessUpdates()
        defer { endReadinessUpdates() }
        presentationActive = true
        readinessUpdatePending = true
        renderFrame()
        guard owns(ticket), installedTimeline == ticket, presentationActive else { return false }
        if frameFeedEnabled && playbackState.read().isPlaying { startFrameTimer() }
        return true
    }

    /// Cached ownership only, for a completed offscreen rewind's initial start.
    /// Any native seek in this presentation session keeps the numeric fallback.
    func permitsRetainedZeroStart(_ ticket: PresentationTicket) -> Bool {
        owns(ticket) && installedTimeline == ticket && !imageEpochSaturated
            && seekTicket == 0 && activeSeekTicket == nil
    }

    private func owns(_ ticket: PresentationTicket) -> Bool {
        !invalidated && ticket.generation == presentationRevision
            && currentItem.map { ObjectIdentifier($0) == ticket.item } == true
    }

    private func releaseCurrentResource() {
        cancelIsolatedPreparation()
        let isolated = isolatedVideo
        let resource = currentResource, owned = currentResourceOwned
        let dormant = dormantAudioResource
        isolatedVideo = nil
        currentResource = nil; currentResourceOwned = false; videoOutput = nil
        dormantAudioResource = nil
        retainRecoveryDrain(isolated?.close())
        if owned { resource?.retire() }
        resource?.releaseBorrow()
        if let dormant {
            if dormant.owned { dormant.resource.retire() }
            dormant.resource.releaseBorrow()
        }
    }

    private func cancelIsolatedPreparation() {
        isolatedRequest = nil
        isolatedPreparation?.cancel()
        isolatedPreparation = nil
    }

    private func retainRecoveryDrain(_ pending: Task<Void, Never>?) {
        guard let pending else { return }
        let identity = UUID()
        pendingRecoveryDrains[identity] = Task { [weak self] in
            await pending.value
            self?.pendingRecoveryDrains[identity] = nil
        }
    }

    private func synchronizeIsolatedVideo(force: Bool = false) {
        guard let isolated = isolatedVideo, let timebase, let item = currentItem else { return }
        let ticket = PresentationTicket(generation: presentationRevision, item: ObjectIdentifier(item))
        isolated.synchronize(to: timebase, playing: playbackState.read().isPlaying && frameFeedEnabled,
            force: force, context: seekTicket) { [weak self, weak isolated] in
                guard let self, let isolated, self.isolatedVideo === isolated, self.owns(ticket),
                      self.frameFeedEnabled else { return }
                self.renderFrame()
            }
    }

    /// Creating a new video output on an audible item can stop AVFoundation's
    /// audio clock. Keep its original tap attached, and recover on a muted item.
    @discardableResult
    func recoverFrameFeedIsolatingNativeAudio(for ticket: PresentationTicket,
        ifEligible: @escaping @MainActor () -> Bool, completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard owns(ticket), frameFeedEnabled, activeSeekTicket == nil, playbackState.read().isPlaying,
              let item = currentItem, let previous = currentResource, ifEligible() else { return false }
        if isolatedVideo != nil {
            let repaired = rebuildFrameOutput(for: ticket)
            completion(repaired)
            return repaired
        }
        guard isolatedPreparation == nil else { return false }
        let request = IsolatedRequest()
        isolatedRequest = request
        isolatedPreparation = Task { [weak self, weak item] in
            guard let self, let item else { return }
            var prepared: IsolatedVideoRecovery?
            var adopted = false
            defer {
                if !adopted { self.retainRecoveryDrain(prepared?.close()) }
                self.pendingIsolatedPreparations[ObjectIdentifier(request)] = nil
                if self.isolatedRequest === request {
                    self.isolatedRequest = nil; self.isolatedPreparation = nil
                }
            }
            @MainActor func eligible() -> Bool {
                !Task.isCancelled && self.isolatedRequest === request && self.owns(ticket)
                    && self.currentItem === item && self.currentResource === previous
                    && self.frameFeedEnabled && self.activeSeekTicket == nil
                    && self.playbackState.read().isPlaying && ifEligible()
            }
            do {
                let decoder = try await IsolatedVideoRecovery.prepare(from: item)
                prepared = decoder
                guard eligible(), decoder.resource.borrow(for: decoder.item) else { return }
                guard eligible(), let output = decoder.resource.output else {
                    decoder.resource.releaseBorrow(); return
                }
                let barrier = self.beginSeek()
                guard !Task.isCancelled, self.isolatedRequest === request, self.owns(ticket),
                      self.currentResource === previous, self.activeSeekTicket == barrier,
                      self.frameFeedEnabled, self.playbackState.read().isPlaying, ifEligible() else {
                    self.completeSeek(barrier); decoder.resource.releaseBorrow(); return
                }
                // Do not call releaseCurrentResource here: it could detach the
                // still-audible item's output and reproduce the measured gap.
                self.dormantAudioResource = (previous, self.currentResourceOwned)
                self.currentResource = decoder.resource; self.currentResourceOwned = true
                self.videoOutput = output; self.isolatedVideo = decoder
                self.orientationPrepared = true
                adopted = true
                self.completeSeek(barrier)
                guard self.owns(ticket), self.isolatedVideo === decoder, self.frameFeedEnabled,
                      ifEligible() else { return }
                self.synchronizeIsolatedVideo(force: true)
                if self.playbackState.read().isPlaying { self.startFrameTimer() }
                if self.owns(ticket), self.isolatedVideo === decoder, self.frameFeedEnabled, ifEligible() {
                    completion(true)
                }
            } catch {
                if eligible() { completion(false) }
            }
        }
        pendingIsolatedPreparations[ObjectIdentifier(request)] = isolatedPreparation
        return true
    }

    /// A narrow leading-empty cadence choice, never permission to bypass composition or source timing.
    static func frameDurationForLeadingEmptyEdit(nativeMinimum: CMTime, assetDuration: CMTime,
        emptyTarget: CMTimeRange, media: CMTimeMapping) -> CMTime? {
        let emptyEnd = CMTimeRangeGetEnd(emptyTarget), mediaEnd = CMTimeRangeGetEnd(media.target)
        let times = [nativeMinimum, assetDuration, emptyTarget.start, emptyTarget.duration, emptyEnd,
            media.source.start, media.source.duration, media.target.start, media.target.duration, mediaEnd]
        guard times.allSatisfy({ $0.isNumeric && $0.timescale > 0 && $0.epoch == 0 && !$0.flags.contains(.hasBeenRounded) }),
              nativeMinimum.value > 0, nativeMinimum.timescale > 0,
              CMTimeCompare(emptyTarget.start, .zero) == 0, CMTimeCompare(emptyTarget.duration, .zero) > 0,
              CMTimeCompare(media.source.start, .zero) == 0, CMTimeCompare(media.source.duration, .zero) > 0,
              CMTimeCompare(media.source.duration, media.target.duration) == 0,
              CMTimeCompare(emptyEnd, media.target.start) == 0, CMTimeCompare(mediaEnd, assetDuration) == 0 else { return nil }
        for boundary in [emptyTarget.start, emptyEnd, mediaEnd] {
            let scaled = CMTimeConvertScale(boundary, timescale: nativeMinimum.timescale, method: .roundTowardZero)
            guard scaled.isNumeric, scaled.epoch == 0, !scaled.flags.contains(.hasBeenRounded),
                  CMTimeCompare(scaled, boundary) == 0, scaled.value >= 0, scaled.value % nativeMinimum.value == 0 else { return nil }
        }
        return nativeMinimum
    }

    /// Normalize the preferred source transform into actual output pixels. A layer-only transform
    /// would leave PiP free to display the unrotated pixels.
    static func makeVideoComposition(for asset: AVAsset) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: AVFoundationErrorDomain, code: -1)
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        var leadingEmptyCadence: CMTime?
        if let localAsset = asset as? AVURLAsset, localAsset.url.isFileURL,
           let segments = try? await track.load(.segments), segments.count == 2,
           segments[0].isEmpty, !segments[1].isEmpty,
           let minimum = try? await track.load(.minFrameDuration) {
            leadingEmptyCadence = frameDurationForLeadingEmptyEdit(nativeMinimum: minimum, assetDuration: duration,
                emptyTarget: segments[0].timeMapping.target, media: segments[1].timeMapping)
        }
        try Task.checkCancellation()
        let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width > 0, bounds.height > 0, duration.isNumeric, CMTimeCompare(duration, .zero) > 0 else {
            throw NSError(domain: AVFoundationErrorDomain, code: -2)
        }
        // Source timing drives media; empty edits use frameDuration. Override only a proved local
        // leading-empty mapping whose full boundaries lie exactly on the native minimum cadence.
        // The synchronous factory can load further asset properties on the UI
        // actor. Suspend that work while preserving Apple's composition defaults.
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        try Task.checkCancellation()
        if let leadingEmptyCadence { composition.frameDuration = leadingEmptyCadence }
        composition.sourceTrackIDForFrameTiming = track.trackID
        composition.renderSize = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let normalized = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        layer.setTransform(normalized, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    /// Position must come from the audio renderer, not the independently muted video player.
    func updatePlayback(positionSeconds: Double, durationSeconds: Double, isPlaying: Bool) {
        applyPlayback(positionSeconds: positionSeconds, durationSeconds: durationSeconds,
                      isPlaying: isPlaying, forceAnchor: false)
    }

    private func applyPlayback(positionSeconds: Double, durationSeconds: Double, isPlaying: Bool,
                               forceAnchor: Bool) {
        guard !invalidated else { return }
        beginReadinessUpdates()
        defer { endReadinessUpdates() }
        let revision = presentationRevision
        let seek = seekTicket, activeSeek = activeSeekTicket
        let position = positionSeconds.isFinite ? max(0, positionSeconds) : 0
        let duration = durationSeconds.isFinite ? max(0, durationSeconds) : 0
        let previous = playbackState.read()
        playbackState.update(position: position, duration: duration, isPlaying: isPlaying)
        if let timebase {
            // The audio cursor and native video seek use a 48 kHz sample grid.
            // A 60 kHz Double conversion can land one tick behind a paused seek,
            // making its valid image fail the strict future-frame guard.
            let frame = (position * 48_000).rounded()
            let anchorTime = frame.isFinite && frame < Double(Int64.max)
                ? CMTime(value: Int64(frame), timescale: 48_000)
                : CMTime(seconds: position, preferredTimescale: 48_000)
            let current = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            if forceAnchor || !current.isFinite || abs(current - position) > 0.08 {
                flushForSeek()
                guard !invalidated, presentationRevision == revision,
                      seekTicket == seek, activeSeekTicket == activeSeek else { return }
                CMTimebaseSetTime(timebase, time: anchorTime)
            } else if previous.isPlaying != isPlaying || !isPlaying {
                CMTimebaseSetTime(timebase, time: anchorTime)
            }
            CMTimebaseSetRate(timebase, rate: isPlaying ? 1 : 0)
        }
        if previous.isPlaying != isPlaying || previous.duration != duration {
            controller?.invalidatePlaybackState()
        }
        if !isPlaying { cancelIsolatedPreparation() }
        synchronizeIsolatedVideo(force: forceAnchor)
        if frameFeedEnabled && isPlaying && currentItem != nil { startFrameTimer() }
        else { stopFrameTimer() }
        renderFrame()
    }

    /// A seek starts a new frame epoch, including the image held by a paused timebase.
    func flushForSeek(removingImage: Bool = false) {
        beginReadinessUpdates()
        defer { endReadinessUpdates() }
        let revision = presentationRevision
        let epoch = invalidateCurrentFrameProof()
        guard !invalidated, imageEpoch == epoch, presentationRevision == revision else { return }
        // Invalidate old readiness immediately, but retain the displayed picture
        // until the replacement arrives. Clearing it here causes a black PiP/inline flash.
        if removingImage { displayLayer.flushAndRemoveImage(); hasDisplayedImage = false }
        else { displayLayer.flush() }
        guard !invalidated, imageEpoch == epoch, presentationRevision == revision else { return }
        hasReportedFrameFailure = false
    }

    /// Stop pulls before native seeking can make its target available. Acquiring it
    /// before completion and then flushing would consume a paused one-shot frame.
    func beginSeek() -> UInt64 {
        beginReadinessUpdates()
        defer { endReadinessUpdates() }
        seekTicket &+= 1
        let ticket = seekTicket
        activeSeekTicket = ticket
        #if DEBUG
        debugTraceRender(.seekBegin) { flushForSeek() }
        #else
        flushForSeek()
        #endif
        return ticket
    }

    /// A refused correction cannot leave its previous timeline eligible when
    /// the matching seek barrier is released. Never withdraw a newer owner.
    func abandonTimeline(_ ticket: PresentationTicket, for item: AVPlayerItem, afterSeek seek: UInt64) {
        guard owns(ticket), currentItem === item, seekTicket == seek,
              activeSeekTicket == nil || activeSeekTicket == seek else { return }
        beginReadinessUpdates()
        defer { endReadinessUpdates() }
        presentationActive = false
        installedTimeline = nil
        stopFrameTimer()
        // All state changes precede the invalidation callback, which may install
        // another owner. flushForSeek revalidates its epoch before SDK flushing.
        flushForSeek()
    }

    func completeSeek(_ ticket: UInt64) {
        guard activeSeekTicket == ticket else { return }
        beginReadinessUpdates()
        defer { endReadinessUpdates() }
        activeSeekTicket = nil
        readinessUpdatePending = true
    }

    /// Restore a starved output in either audio mode without seeking AVPlayer.
    @discardableResult
    func rebuildFrameOutput(for ticket: PresentationTicket) -> Bool {
        guard owns(ticket), presentationActive, frameFeedEnabled, activeSeekTicket == nil,
              let resource = currentResource else { return false }
        let barrier = beginSeek()
        defer { completeSeek(barrier) }
        func eligible() -> Bool {
            owns(ticket) && frameFeedEnabled && currentResource === resource
                && activeSeekTicket == barrier && seekTicket == barrier
        }
        guard eligible() else { return false }
        let rebuilt = resource.rebuildOutput(ifEligible: eligible) { self.videoOutput = $0 }
        guard rebuilt, eligible() else { return false }
        completeSeek(barrier)
        guard owns(ticket), currentResource === resource, activeSeekTicket == nil else { return false }
        synchronizeIsolatedVideo(force: true)
        renderFrame()
        if playbackState.read().isPlaying { startFrameTimer() }
        return true
    }

    /// Call when video is intentionally disabled, even if audio remains active.
    func suspendFrameFeed() {
        guard frameFeedEnabled else { return }
        beginReadinessUpdates()
        defer { endReadinessUpdates() }
        frameFeedEnabled = false
        cancelIsolatedPreparation()
        isolatedVideo?.suspend()
        stopFrameTimer()
        invalidateFrameEligibility()
    }

    func resumeFrameFeed() {
        guard !invalidated else { return }
        beginReadinessUpdates()
        defer { endReadinessUpdates() }
        let wasSuspended = !frameFeedEnabled
        frameFeedEnabled = true
        if wasSuspended { readinessUpdatePending = true }
        synchronizeIsolatedVideo(force: wasSuspended)
        renderFrame()
        if playbackState.read().isPlaying && currentItem != nil { startFrameTimer() }
    }

    #if DEBUG
    /// Test teardown must await the cancelled metadata/composition owner as well.
    func debugInvalidateAndCapturePreparation() -> Task<Void, Never>? {
        let owned = preparationTask
        invalidate()
        let preparations = Array(pendingIsolatedPreparations.values)
        let drains = Array(pendingRecoveryDrains.values)
        return Task { [self] in
            await owned?.value
            for task in preparations { await task.value }
            for task in drains { await task.value }
            // A cancelled preparation may have closed its decoder while being joined.
            for task in Array(pendingRecoveryDrains.values) { await task.value }
        }
    }
    #endif

    /// Release on the control thread. No audio session or audio renderer is touched.
    func invalidate() {
        guard !invalidated else { return }
        beginReadinessUpdates()
        defer { endReadinessUpdates() }
        invalidated = true
        presentationActive = false
        installedTimeline = nil
        invalidateCurrentFrameProof()
        #if DEBUG
        shouldDebugAcquireFrame = nil
        onFrameAcquisition = nil
        onDebugRenderStamp = nil
        onDebugNativePullStamp = nil
        onDebugCopiedPixel = nil
        #endif
        activeSeekTicket = nil
        preparationTask?.cancel()
        preparationTask = nil
        stopFrameTimer()
        observations.removeAll()
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers.removeAll()
        controller?.stopPictureInPicture()
        controller?.delegate = nil
        controller = nil
        releaseCurrentResource()
        videoOutput = nil
        currentItem = nil
        displayLayer.flushAndRemoveImage()
        hasDisplayedImage = false
        displayLayer.controlTimebase = nil
        timebase = nil
        format = nil
        onSetPlaying = nil
        onSkip = nil
        onRestoreUI = nil
        onStateChanged = nil
        onEvent = nil
        onCurrentFrameInvalidated = nil
        onCurrentFrameStateChanged = nil
        onClockAlignmentRequired = nil
    }

    private func startFrameTimer() {
        guard presentationActive, activeSeekTicket == nil, frameTimer == nil, displayLink == nil else { return }
        let rate = currentResource?.preferredFrameRate ?? 60
        if UIApplication.shared.applicationState != .background {
            let link = CADisplayLink(target: displayTarget, selector: #selector(DisplayTarget.tick(_:)))
            // Keep the lower hint at the source cadence: a 60 fps clip must not
            // invite 30 Hz pulls. Lower-rate content can still adapt accordingly.
            let sourceRate = currentResource?.sourceFrameRate ?? 30
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(rate, max(1, sourceRate)), maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common)
            displayLink = link
            return
        }
        // Display links stop while background PiP is active. Keep its pulls at
        // the same source cadence using a single main-runloop timer.
        let timer = Timer(timeInterval: 1.0 / Double(rate), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderFrame() }
        }
        timer.tolerance = 1.0 / (Double(rate) * 4)
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopFrameTimer() {
        displayLink?.invalidate()
        displayLink = nil
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func renderFrame(targetHostTime: CFTimeInterval? = nil) {
        #if DEBUG
        let debugWholeObserver = onDebugWholeFrame
        var debugWholeEntry: DebugWholeFrameEntry?
        var debugWholeEntryDelivery: DebugWholeFrameInterval?
        if let debugWholeObserver {
            if debugWholeFrameOrdinal < .max { debugWholeFrameOrdinal += 1 }
            let entry = DebugWholeFrameEntry(ordinal: debugWholeFrameOrdinal,
                entryNs: DispatchTime.now().uptimeNanoseconds, state: debugAlignedPollState,
                ordinalSaturated: debugWholeFrameOrdinal == .max)
            debugWholeEntry = entry
            let deliveryEntry = DispatchTime.now().uptimeNanoseconds
            debugWholeObserver(.entered(entry))
            debugWholeEntryDelivery = .init(entryNs: deliveryEntry, returnNs: DispatchTime.now().uptimeNanoseconds)
        }
        var debugWholeStage = DebugWholeFrameStage.resourceGuard
        var debugWholeReadEntry: UInt64 = 0
        var debugWholeStatus: DebugWholeFrameInterval?, debugWholeBackpressure: DebugWholeFrameInterval?
        var debugWholeTimebase: DebugWholeFrameInterval?, debugWholeAcquisition: DebugWholeFrameInterval?
        var debugWholeCommit: DebugWholeFrameInterval?
        var debugWholeLayerFailed: Bool?, debugWholeReadyForMore: Bool?, debugWholeRequestedNumeric: Bool?
        var debugWholeAvailability: Bool?, debugWholeCopied: Bool?, debugWholeEnqueueCalled = false
        defer {
            if let debugWholeEntry, let debugWholeObserver {
                let returnedState = debugAlignedPollState
                let returned = DispatchTime.now().uptimeNanoseconds
                debugWholeObserver(.returned(DebugWholeFrameSpan(entry: debugWholeEntry,
                    returnNs: returned, returnedState: returnedState, stage: debugWholeStage,
                    layerStatus: debugWholeStatus, backpressure: debugWholeBackpressure,
                    timebase: debugWholeTimebase, acquisitionObserver: debugWholeAcquisition,
                    readinessCommit: debugWholeCommit, entryObserverDelivery: debugWholeEntryDelivery,
                    layerFailed: debugWholeLayerFailed,
                    readyForMore: debugWholeReadyForMore, requestedNumeric: debugWholeRequestedNumeric,
                    availability: debugWholeAvailability, copied: debugWholeCopied,
                    enqueueCalled: debugWholeEnqueueCalled)))
            }
        }
        #endif
        guard !invalidated, frameFeedEnabled, isolatedVideo?.isAligning != true,
              let videoOutput, let timebase else { return }
        beginReadinessUpdates()
        defer {
            #if DEBUG
            let commitEntry = debugWholeEntry == nil ? 0 : DispatchTime.now().uptimeNanoseconds
            #endif
            endReadinessUpdates()
            #if DEBUG
            if debugWholeEntry != nil {
                debugWholeCommit = .init(entryNs: commitEntry, returnNs: DispatchTime.now().uptimeNanoseconds)
            }
            #endif
        }
        #if DEBUG
        debugWholeStage = .seekGuard
        let debugEnqueueTicket = currentItem.map {
            PresentationTicket(generation: presentationRevision, item: ObjectIdentifier($0))
        }
        let debugAlignedContext = debugAlignedPullContext(debugEnqueueTicket, output: videoOutput)
        let debugPullSeekTicket = onDebugNativePullStamp == nil ? nil : seekTicket
        let debugSourceTicket = onDebugRenderStamp == nil ? nil : debugEnqueueTicket
        #endif
        guard activeSeekTicket == nil else {
            #if DEBUG
            debugTraceRender(.seekBlocked, sourceTicket: debugSourceTicket)
            #endif
            blockedFrameAcquisitionCount &+= 1
            return
        }
        #if DEBUG
        debugWholeStage = .activeGuard
        #endif
        guard presentationActive else { return }
        #if DEBUG
        debugWholeStage = .itemGuard
        #endif
        guard let item = currentItem, !imageEpochSaturated else { return }
        let pullReceipt = CurrentFrameReceipt(
            ticket: PresentationTicket(generation: presentationRevision, item: ObjectIdentifier(item)),
            output: ObjectIdentifier(videoOutput), imageEpoch: imageEpoch, seekSerial: seekTicket,
            surfaces: surfaceProof)
        #if DEBUG
        debugWholeStage = .ownerGuard
        #endif
        guard ownsFramePull(pullReceipt) else { return }
        #if DEBUG
        debugWholeStage = .acquisitionGuard
        if let shouldAcquire = shouldDebugAcquireFrame {
            guard shouldAcquire(pullReceipt) else { return }
            guard ownsFramePull(pullReceipt) else { return }
        }
        debugTraceRender(.attempt, sourceTicket: debugSourceTicket)
        #endif
        guard ownsFramePull(pullReceipt) else { return }
        #if DEBUG
        debugWholeStage = .layerStatus
        debugWholeReadEntry = debugWholeEntry == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        #endif
        let layerFailed = displayLayer.status == .failed
        #if DEBUG
        if debugWholeEntry != nil {
            debugWholeStatus = .init(entryNs: debugWholeReadEntry, returnNs: DispatchTime.now().uptimeNanoseconds)
            debugWholeLayerFailed = layerFailed
        }
        debugWholeStage = .ownerAfterStatus
        #endif
        guard ownsFramePull(pullReceipt) else { return }
        if layerFailed {
            #if DEBUG
            debugWholeStage = .failedLayerRecovery
            #endif
            // Discard credit before any observer or SDK flush can reenter.
            let shouldReport = !hasReportedFrameFailure
            let errorCode = shouldReport ? (displayLayer.error as NSError?)?.code : nil
            guard ownsFramePull(pullReceipt) else { return }
            let recoveryEpoch = pullReceipt.imageEpoch.addingReportingOverflow(1)
            flushForSeek()
            guard !recoveryEpoch.overflow, !imageEpochSaturated,
                  imageEpoch == recoveryEpoch.partialValue, seekTicket == pullReceipt.seekSerial,
                  activeSeekTicket == nil, owns(pullReceipt.ticket),
                  videoOutput === self.videoOutput else { return }
            // This recovery flush must not rearm the already-reported failure
            // on every other pull. A later explicit seek/source flush may retry.
            hasReportedFrameFailure = true
            if shouldReport {
                onEvent?(.frameFailed, errorCode)
            }
            return // The next pull must capture the new image epoch.
        }
        // Respect platform backpressure. No app-owned pixel-buffer queue or decoded-frame history.
        #if DEBUG
        debugWholeStage = .backpressure
        debugWholeReadEntry = debugWholeEntry == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        let readyForMore = displayLayer.isReadyForMoreMediaData
        if debugWholeEntry != nil {
            debugWholeBackpressure = .init(entryNs: debugWholeReadEntry, returnNs: DispatchTime.now().uptimeNanoseconds)
            debugWholeReadyForMore = readyForMore
        }
        guard readyForMore else { return }
        debugWholeStage = .ownerAfterBackpressure
        #else
        guard displayLayer.isReadyForMoreMediaData else { return }
        #endif
        guard ownsFramePull(pullReceipt) else { return }
        #if DEBUG
        debugWholeStage = .timebase
        debugWholeReadEntry = debugWholeEntry == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        #endif
        let presentationTime = CMTimebaseGetTime(timebase)
        var requestedTime = presentationTime
        if playbackState.read().isPlaying, let targetHostTime {
            // Ask the native decoder for its next display deadline. Pulling from
            // the independently anchored audio clock can repeatedly miss the
            // decoder's frame boundary even with 60 display callbacks per second.
            let mapped = videoOutput.itemTime(forHostTime: targetHostTime)
            guard ownsFramePull(pullReceipt) else { return }
            if mapped.isNumeric, presentationTime.isNumeric {
                if VideoFrameRequest.usesNativeDeadline(presentation: presentationTime.seconds, mapped: mapped.seconds) {
                    requestedTime = mapped
                } else if mapped.seconds - presentationTime.seconds > 1.0 / 30 {
                    let nativeNow = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
                    guard ownsFramePull(pullReceipt) else { return }
                    if nativeNow.isNumeric,
                       VideoFrameRequest.usesNativeDeadline(presentation: presentationTime.seconds, mapped: nativeNow.seconds) {
                        // Vsync prediction can cross the lead budget even while
                        // the native clock itself is valid. Clamp that prediction.
                        requestedTime = CMTimeMinimum(mapped, CMTimeAdd(presentationTime, CMTime(value: 1, timescale: 30)))
                    } else if nativeNow.isNumeric && nativeNow.seconds - presentationTime.seconds > 1.0 / 30 {
                        // The output cannot supply indefinitely old images.
                        // Align through the audible owner before consuming them.
                        onClockAlignmentRequired?(pullReceipt.ticket)
                        return
                    }
                }
                // A stopped/starting native clock keeps the existing grace and
                // recovery policy rather than starting repeated startup seeks.
            }
        }
        #if DEBUG
        if debugWholeEntry != nil {
            debugWholeTimebase = .init(entryNs: debugWholeReadEntry, returnNs: DispatchTime.now().uptimeNanoseconds)
            debugWholeRequestedNumeric = requestedTime.isNumeric
        }
        debugWholeStage = .numericTimeGuard
        #endif
        guard requestedTime.isNumeric else { return }
        #if DEBUG
        debugWholeStage = .acquisitionObserver
        debugWholeReadEntry = debugWholeEntry == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        if let item = currentItem { onFrameAcquisition?(item, requestedTime) }
        if debugWholeEntry != nil {
            debugWholeAcquisition = .init(entryNs: debugWholeReadEntry, returnNs: DispatchTime.now().uptimeNanoseconds)
        }
        debugWholeStage = .ownerAfterAcquisitionObserver
        #endif
        guard ownsFramePull(pullReceipt) else { return }
        #if DEBUG
        debugWholeStage = .availability
        let hasNew = debugNativePull(.availability, sourceTicket: debugEnqueueTicket,
            sourceNativeSeekTicket: debugPullSeekTicket, output: videoOutput) {
            videoOutput.hasNewPixelBuffer(forItemTime: requestedTime)
        }
        debugWholeAvailability = hasNew
        debugWholeStage = .availabilityGuard
        debugTraceRender(hasNew ? .hasNewTrue : .hasNewFalse, requested: requestedTime, sourceTicket: debugSourceTicket)
        guard hasNew else { return }
        #else
        guard videoOutput.hasNewPixelBuffer(forItemTime: requestedTime) else { return }
        #endif
        #if DEBUG
        debugWholeStage = .ownerBeforeCopy
        #endif
        guard ownsFramePull(pullReceipt) else { return }
        var displayTime = CMTime.invalid
        #if DEBUG
        debugWholeStage = .copy
        let copied = debugNativePull(.copy, sourceTicket: debugEnqueueTicket,
            sourceNativeSeekTicket: debugPullSeekTicket, output: videoOutput) {
            videoOutput.copyPixelBuffer(forItemTime: requestedTime, itemTimeForDisplay: &displayTime)
        }
        debugWholeCopied = copied != nil
        debugWholeStage = .copyGuard
        guard let pixel = copied else { return }
        let debugAlignedAfterCopy = debugAlignedContext.map { debugAlignedOwnerMatches($0) } ?? false
        #else
        guard let pixel = videoOutput.copyPixelBuffer(forItemTime: requestedTime,
                                                      itemTimeForDisplay: &displayTime) else { return }
        #endif
        #if DEBUG
        debugWholeStage = .ownerAfterCopy
        #endif
        guard ownsFramePull(pullReceipt) else { return }
        #if DEBUG
        debugWholeStage = .copiedPixelObserver
        if let observer = onDebugCopiedPixel {
            observer(pixel, DebugCopiedPixelContext(pull: pullReceipt,
                requestedTime: requestedTime, rawDisplayTime: displayTime))
            guard ownsFramePull(pullReceipt) else { return }
        }
        debugWholeStage = .ownerAfterCopiedPixelObserver
        #endif
        if !displayTime.isNumeric { displayTime = requestedTime }
        lastCopiedFramePositionSeconds = CMTimeGetSeconds(displayTime)
        #if DEBUG
        debugWholeStage = .timestampCredit
        debugTraceRender(.copied, requested: requestedTime, sample: displayTime, sourceTicket: debugSourceTicket)
        #endif
        guard ownsFramePull(pullReceipt) else { return }
        // A stopped clock cannot advance to a future sample. Do not let an output
        // replay from before a backwards seek pin this epoch ahead of its target.
        // Past samples remain valid for sources with long or variable frame durations.
        #if DEBUG
        debugWholeStage = .pausedFutureGuard
        #endif
        if !playbackState.read().isPlaying && CMTimeCompare(displayTime, requestedTime) > 0 {
            pausedFutureFrameRejectionCount &+= 1
            return
        }
        #if DEBUG
        debugWholeStage = .increasingTimeGuard
        #endif
        guard !lastEnqueuedTime.isNumeric || CMTimeCompare(displayTime, lastEnqueuedTime) > 0 else { return }
        // Never build a future presentation backlog if the video decoder runs ahead of audio.
        let lead = CMTimeGetSeconds(CMTimeSubtract(displayTime, presentationTime))
        #if DEBUG
        debugWholeStage = .leadGuard
        #endif
        guard lead.isFinite, lead <= 1.0 / 30 else { return }
        #if DEBUG
        debugWholeStage = .formatCreation
        #endif
        let width = CVPixelBufferGetWidth(pixel)
        let height = CVPixelBufferGetHeight(pixel)
        let pixelType = CVPixelBufferGetPixelFormatType(pixel)
        if format == nil || width != formatWidth || height != formatHeight || pixelType != formatPixelType {
            var createdFormat: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                      imageBuffer: pixel,
                                                                      formatDescriptionOut: &createdFormat)
            guard ownsFramePull(pullReceipt) else { return }
            guard status == noErr, let createdFormat else { reportFrameFailure(status); return }
            format = createdFormat
            formatWidth = width
            formatHeight = height
            formatPixelType = pixelType
        }
        #if DEBUG
        debugWholeStage = .formatGuard
        #endif
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: displayTime,
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #if DEBUG
        debugWholeStage = .sampleCreation
        #endif
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                              imageBuffer: pixel,
                                                              formatDescription: format,
                                                              sampleTiming: &timing,
                                                              sampleBufferOut: &sample)
        guard ownsFramePull(pullReceipt) else { return }
        #if DEBUG
        debugWholeStage = .sampleGuard
        #endif
        guard status == noErr, let sample else { reportFrameFailure(status); return }
        #if DEBUG
        let debugAlignedBeforeEnqueue = debugAlignedContext.map { debugAlignedOwnerMatches($0) } ?? false
        #endif
        #if DEBUG
        debugWholeStage = .ownerBeforeEnqueue
        #endif
        guard ownsFramePull(pullReceipt) else { return }
        #if DEBUG
        debugWholeStage = .enqueue
        debugNativePull(.enqueue, sourceTicket: debugEnqueueTicket,
            sourceNativeSeekTicket: debugPullSeekTicket, output: videoOutput) {
            displayLayer.enqueue(sample)
        }
        let debugAlignedAfterEnqueue = debugAlignedContext.map { debugAlignedOwnerMatches($0) } ?? false
        let debugAlignedEnqueuedNs = debugAlignedContext == nil ? nil : DispatchTime.now().uptimeNanoseconds
        #else
        displayLayer.enqueue(sample)
        #endif
        #if DEBUG
        debugWholeEnqueueCalled = true
        debugWholeStage = .ownerAfterEnqueue
        #endif
        guard ownsFramePull(pullReceipt) else { return }
        #if DEBUG
        debugWholeStage = .imageCredit
        #endif
        pullReceipt.surfaces.record(pixel, position: displayTime.seconds)
        lastEnqueuedTime = displayTime
        lastFramePositionSeconds = CMTimeGetSeconds(displayTime)
        submittedFrameCount &+= 1
        if submittedReceipt != pullReceipt {
            submittedReceipt = pullReceipt
            readinessUpdatePending = true
        }
        #if DEBUG
        debugObserveAlignedEnqueue(debugAlignedContext, afterCopy: debugAlignedAfterCopy,
            beforeEnqueue: debugAlignedBeforeEnqueue, afterEnqueue: debugAlignedAfterEnqueue,
            enqueuedNs: debugAlignedEnqueuedNs, requested: requestedTime, sample: displayTime)
        debugTraceRender(.enqueued, requested: requestedTime, sample: displayTime, sourceTicket: debugSourceTicket)
        debugWholeStage = .enqueued
        #endif
    }

    private func reportFrameFailure(_ status: OSStatus) {
        guard !hasReportedFrameFailure else { return }
        hasReportedFrameFailure = true
        onEvent?(.frameFailed, Int(status))
    }

    private func reportState() {
        guard !invalidated, let controller else { return }
        onStateChanged?(controller.isPictureInPictureActive, controller.isPictureInPicturePossible,
                        controller.isPictureInPictureSuspended)
    }

    // Kept separate from the Objective-C delegate entry points for deterministic native tests.
    func handleSetPlayingRequest(_ playing: Bool) {
        guard !invalidated else { return }
        onEvent?(playing ? .userPlayRequested : .userPauseRequested, nil)
        onSetPlaying?(playing)
    }

    func handleSkipRequest(_ seconds: Double, completion completionHandler: @escaping () -> Void) {
        let completion = ContinuousPiPVoidCompletion(completionHandler)
        guard !invalidated, seconds.isFinite, let skip = onSkip else { completion.call(); return }
        onEvent?(.userSkipRequested, nil)
        skip(seconds) { completion.call() }
    }

    func handleRestoreUIRequest(completion completionHandler: @escaping (Bool) -> Void) {
        let completion = ContinuousPiPBoolCompletion(completionHandler)
        guard !invalidated, let restore = onRestoreUI else {
            onEvent?(.restoreUnavailable, nil)
            completion.call(false)
            return
        }
        onEvent?(.restoreRequested, nil)
        restore { [weak self] restored in
            guard completion.call(restored) else { return }
            self?.onEvent?(restored ? .restoreCompleted : .restoreUnavailable, nil)
        }
    }
}

extension ContinuousPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                setPlaying playing: Bool) {
        Task { @MainActor [weak self] in
            self?.handleSetPlayingRequest(playing)
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        let completion = ContinuousPiPVoidCompletion(completionHandler)
        let seconds = CMTimeGetSeconds(skipInterval)
        Task { @MainActor [weak self] in
            guard let self else { completion.call(); return }
            self.handleSkipRequest(seconds) { completion.call() }
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !playbackState.read().isPlaying
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let state = playbackState.read()
        let duration = max(state.duration, state.position + 1.0 / 600)
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60_000))
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }
}

extension ContinuousPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.onEvent?(.willStart, nil); self?.reportState() }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.onEvent?(.didStart, nil); self?.reportState() }
    }
    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.onEvent?(.willStop, nil); self?.reportState() }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.onEvent?(.didStop, nil); self?.reportState() }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        let code = (error as NSError).code
        Task { @MainActor [weak self] in self?.onEvent?(.startFailed, code); self?.reportState() }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        let completion = ContinuousPiPBoolCompletion(completionHandler)
        Task { @MainActor [weak self] in
            guard let self else { completion.call(false); return }
            self.handleRestoreUIRequest { completion.call($0) }
        }
    }
}

// AVKit's synchronous state queries never block on the main queue. This is a control-thread
// lock, wholly outside the audio render path; it protects only three scalar values.
private final class ContinuousPiPPlaybackState: @unchecked Sendable {
    struct State { var position = 0.0; var duration = 0.0; var isPlaying = false }
    private let lock = NSLock()
    private var state = State()
    func update(position: Double, duration: Double, isPlaying: Bool) {
        lock.lock(); defer { lock.unlock() }
        state = State(position: position, duration: duration, isPlaying: isPlaying)
    }
    func read() -> State { lock.lock(); defer { lock.unlock() }; return state }
}

private final class ContinuousPiPVoidCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func call() {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?()
    }
}

private final class ContinuousPiPBoolCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Bool) -> Void)?
    init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
    @discardableResult func call(_ value: Bool) -> Bool {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?(value)
        return callback != nil
    }
}
