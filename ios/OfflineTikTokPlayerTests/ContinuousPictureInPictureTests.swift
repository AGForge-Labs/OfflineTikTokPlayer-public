import XCTest
import AVFoundation
import CoreVideo
import CryptoKit
#if DEBUG
import CoreFoundation
#endif
import UIKit
@testable import OfflineTikTokPlayer

@MainActor
final class ContinuousPictureInPictureTests: XCTestCase {
    func testOnlyExplicitPiPCommandsReachAudioIntent() {
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        var commands: [Bool] = []
        bridge.onSetPlaying = { commands.append($0) }
        bridge.updatePlayback(positionSeconds: 1, durationSeconds: 10, isPlaying: true)
        bridge.suspendFrameFeed()
        bridge.updatePlayback(positionSeconds: 2, durationSeconds: 10, isPlaying: true)
        XCTAssertTrue(bridge.isFrameFeedSuspended)
        XCTAssertTrue(commands.isEmpty)
        bridge.resumeFrameFeed()
        XCTAssertTrue(commands.isEmpty)
        bridge.handleSetPlayingRequest(false)
        bridge.handleSetPlayingRequest(true)
        XCTAssertEqual(commands, [false, true])
        bridge.invalidate()
        bridge.handleSetPlayingRequest(true)
        XCTAssertEqual(commands, [false, true])
    }

    func testSkipAlwaysCompletesAndRejectsInvalidInterval() {
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        var completions = 0
        bridge.handleSkipRequest(15) { completions += 1 }
        XCTAssertEqual(completions, 1)
        var intervals: [Double] = []
        bridge.onSkip = { interval, done in intervals.append(interval); done(); done() }
        bridge.handleSkipRequest(.nan) { completions += 1 }
        bridge.handleSkipRequest(-15) { completions += 1 }
        XCTAssertEqual(intervals, [-15])
        XCTAssertEqual(completions, 3)
    }

    func testRestorationNeverClaimsSuccessWithoutAnActualUICompletion() {
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        var results: [Bool] = []
        bridge.handleRestoreUIRequest { results.append($0) }
        XCTAssertEqual(results, [false])
        var restoreCompletion: ((Bool) -> Void)?
        bridge.onRestoreUI = { restoreCompletion = $0 }
        bridge.handleRestoreUIRequest { results.append($0) }
        XCTAssertEqual(results, [false])
        restoreCompletion?(true)
        restoreCompletion?(false)
        XCTAssertEqual(results, [false, true])
    }

    func testIdentitySourceNeedsNoCompositionAndPreservesEveryDecodedVideoFrame() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-a", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let bridge = ContinuousPictureInPicture()
        var owned: ContinuousPictureInPicture.PreparedVideoResource?
        // No player/window or temporary asset. Cleanup precedes every resource unwrap.
        defer {
            bridge.invalidate(); owned?.retire()
            XCTAssertTrue(item.outputs.isEmpty)
        }
        XCTAssertNil(item.videoComposition)
        let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
        owned = plan.install()
        let resource = try XCTUnwrap(owned), output = try XCTUnwrap(resource.output)
        // Primary RED on the current implementation: it always assigns a composition.
        XCTAssertNil(item.videoComposition, "The uncomposed public identity source must retain its native geometry path")
        XCTAssertTrue(resource.item === item); XCTAssertTrue(resource.output === output)
        XCTAssertTrue(resource.isAttached); XCTAssertFalse(resource.isRetired)
        XCTAssertEqual(item.outputs.count, 1); XCTAssertTrue(item.outputs.first === output)
        _ = try XCTUnwrap(bridge.setCurrentItem(item, preparedVideo: resource))
        XCTAssertTrue(resource.isBorrowed)
        XCTAssertTrue(resource.isAttached); XCTAssertFalse(resource.isRetired)

        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration), range = try await track.load(.timeRange)
        let formats = try await track.load(.formatDescriptions)
        XCTAssertEqual(formats.count, 1)
        let format = try XCTUnwrap(formats.first)
        let encoded = CMVideoFormatDescriptionGetDimensions(format)
        let clean = CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true)
        let par = CMFormatDescriptionGetExtension(format,
            extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? NSDictionary
        let parH = par?[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? NSNumber
        let parV = par?[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber
        let parHLabel = parH.map { String($0.doubleValue) } ?? "absent"
        let parVLabel = parV.map { String($0.doubleValue) } ?? "absent"
        print("NativeGeometryFixture schema=1 naturalWidth=\(natural.width) naturalHeight=\(natural.height) transformA=\(transform.a) transformB=\(transform.b) transformC=\(transform.c) transformD=\(transform.d) transformTX=\(transform.tx) transformTY=\(transform.ty) encodedWidth=\(encoded.width) encodedHeight=\(encoded.height) cleanX=\(clean.minX) cleanY=\(clean.minY) cleanWidth=\(clean.width) cleanHeight=\(clean.height) parH=\(parHLabel) parV=\(parVLabel) nativeEligibilityFromTransformAlone=false latencyEvidence=false")
        XCTAssertEqual(natural, CGSize(width: 160, height: 96)); XCTAssertTrue(transform.isIdentity)
        XCTAssertEqual(encoded.width, 160); XCTAssertEqual(encoded.height, 96)
        XCTAssertEqual(CMTimeCompare(duration, CMTime(seconds: 30, preferredTimescale: 24)), 0)
        XCTAssertEqual(CMTimeCompare(range.start, .zero), 0)
        XCTAssertEqual(CMTimeCompare(CMTimeRangeGetEnd(range), duration), 0)
        let baseline = try await ContinuousPictureInPicture.makeVideoComposition(for: asset)
        XCTAssertEqual(baseline.sourceTrackIDForFrameTiming, track.trackID)
        XCTAssertEqual(baseline.renderSize, CGSize(width: 160, height: 96))

        struct Summary {
            let count: Int, bytes: Int64
            let first: CMTime, last: CMTime
            let ptsHash: String, pixelHash: String, firstFrameHash: String, lastFrameHash: String
        }
        enum DecodeFailure: Error { case contract }
        func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
        @MainActor func decode(_ composition: AVVideoComposition?) throws -> Summary {
            let readerMode = composition == nil ? "native" : "composed"
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            let decoded: AVAssetReaderOutput
            if let composition {
                let composed = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings)
                composed.videoComposition = composition; decoded = composed
            } else {
                decoded = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            }
            decoded.alwaysCopiesSampleData = false
            defer { reader.cancelReading() }
            guard reader.canAdd(decoded) else { XCTFail("The complete video reader must accept its output"); throw DecodeFailure.contract }
            reader.add(decoded) // Intentionally no reader.timeRange: consume the complete source.
            guard reader.startReading() else { throw reader.error ?? DecodeFailure.contract }
            var count = 0, bytes: Int64 = 0
            var first = CMTime.invalid, last = CMTime.invalid
            var ptsHash = SHA256(), pixelHash = SHA256()
            var firstFrameHash = "", lastFrameHash = ""
            while true {
                try Task.checkCancellation()
                let ended = try autoreleasepool { () throws -> Bool in
                    guard let sample = decoded.copyNextSampleBuffer() else { return true }
                    guard count < 720, CMSampleBufferGetNumSamples(sample) == 1 else {
                        XCTFail("The public source must contain exactly 720 individual video frames"); throw DecodeFailure.contract
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let tick = CMTimeConvertScale(pts, timescale: 24, method: .default)
                    guard pts.isNumeric, tick.isNumeric, pts.epoch == 0, tick.epoch == 0,
                          CMTimeCompare(pts, tick) == 0, tick.value == Int64(count) else {
                        print("NativeGeometryVideoPTSFailure schema=1 readerMode=\(readerMode) acceptedFrames=\(count) expectedPTSValue=\(count) expectedPTSTimescale=24 ptsValue=\(pts.value) ptsTimescale=\(pts.timescale) ptsFlags=\(pts.flags.rawValue) ptsEpoch=\(pts.epoch) ptsNumeric=\(pts.isNumeric) tickValue=\(tick.value) tickTimescale=\(tick.timescale) tickFlags=\(tick.flags.rawValue) tickEpoch=\(tick.epoch) tickNumeric=\(tick.isNumeric) firstAcceptedValue=\(first.value) firstAcceptedTimescale=\(first.timescale) firstAcceptedFlags=\(first.flags.rawValue) firstAcceptedEpoch=\(first.epoch) lastAcceptedValue=\(last.value) lastAcceptedTimescale=\(last.timescale) lastAcceptedFlags=\(last.flags.rawValue) lastAcceptedEpoch=\(last.epoch) frameCap=720 fullComparison=unavailable latencyEvidence=false")
                        XCTFail("Every actual PTS must cover the complete ordered 24fps source"); throw DecodeFailure.contract
                    }
                    let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
                    let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
                    let rowBytes = CVPixelBufferGetBytesPerRow(pixel), storage = CVPixelBufferGetDataSize(pixel)
                    guard !CVPixelBufferIsPlanar(pixel), CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA,
                          width == 160, height == 96, rowBytes >= 640, rowBytes <= 4_096,
                          storage >= rowBytes * height, storage <= 1_048_576 else {
                        XCTFail("Every actual frame must retain the bounded full native geometry"); throw DecodeFailure.contract
                    }
                    guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
                        XCTFail("The complete frame's pixels must be readable"); throw DecodeFailure.contract
                    }
                    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
                    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
                    var frameHash = SHA256()
                    for row in 0..<height {
                        // Hash every BGRA pixel; stride padding is not image content.
                        let active = Data(bytes: base.advanced(by: row * rowBytes), count: width * 4)
                        frameHash.update(data: active); pixelHash.update(data: active)
                    }
                    let frameDigest = hex(frameHash.finalize())
                    if count == 0 { first = pts; firstFrameHash = frameDigest }
                    last = pts; lastFrameHash = frameDigest
                    ptsHash.update(data: Data("\(tick.value);".utf8))
                    count += 1; bytes += Int64(width * height * 4)
                    return false
                }
                if ended { break }
            }
            guard reader.status == .completed, count == 720 else {
                XCTFail("The entire source, including its last frame, must reach completed EOF")
                throw reader.error ?? DecodeFailure.contract
            }
            print("NativeGeometryVideoReaderCompleted schema=1 readerMode=\(readerMode) acceptedFrames=\(count) activeBytes=\(bytes) firstPTSValue=\(first.value) firstPTSTimescale=\(first.timescale) firstPTSFlags=\(first.flags.rawValue) firstPTSEpoch=\(first.epoch) lastPTSValue=\(last.value) lastPTSTimescale=\(last.timescale) lastPTSFlags=\(last.flags.rawValue) lastPTSEpoch=\(last.epoch) completeEOF=true fullComparison=pending xctestOutcome=external latencyEvidence=false")
            return Summary(count: count, bytes: bytes, first: first, last: last,
                ptsHash: hex(ptsHash.finalize()), pixelHash: hex(pixelHash.finalize()),
                firstFrameHash: firstFrameHash, lastFrameHash: lastFrameHash)
        }
        // Each helper's cancelReading defer runs before the next reader is created.
        // One prepared output + one reader output: at most two output owners.
        let native = try decode(nil)
        let composed = try decode(baseline)
        XCTAssertEqual(native.count, 720); XCTAssertEqual(composed.count, native.count)
        XCTAssertEqual(native.bytes, 44_236_800); XCTAssertEqual(composed.bytes, native.bytes)
        XCTAssertEqual(CMTimeCompare(native.first, .zero), 0)
        XCTAssertEqual(CMTimeCompare(native.last, CMTime(value: 719, timescale: 24)), 0)
        XCTAssertEqual(CMTimeCompare(composed.first, native.first), 0)
        XCTAssertEqual(CMTimeCompare(composed.last, native.last), 0)
        XCTAssertEqual(composed.ptsHash, native.ptsHash)
        XCTAssertEqual(composed.pixelHash, native.pixelHash)
        XCTAssertEqual(composed.firstFrameHash, native.firstFrameHash)
        XCTAssertEqual(composed.lastFrameHash, native.lastFrameHash)
        XCTAssertNotEqual(native.firstFrameHash, native.lastFrameHash)
        XCTAssertEqual(item.outputs.count, 1); XCTAssertTrue(resource.isBorrowed)
        XCTAssertTrue(resource.isAttached); XCTAssertFalse(resource.isRetired)
        print("NativeGeometryVideoDecode schema=1 nativeFrames=\(native.count) composedFrames=\(composed.count) activeBytesPerReader=\(native.bytes) nativePTSHash=\(native.ptsHash) composedPTSHash=\(composed.ptsHash) nativePixelHash=\(native.pixelHash) composedPixelHash=\(composed.pixelHash) nativeLastFrameHash=\(native.lastFrameHash) composedLastFrameHash=\(composed.lastFrameHash) completeEOF=true scope=full-source-video-decode playbackEvidence=false latencyEvidence=false")
    }

    func testZeroBasedVFRNativeComparisonPreservesEveryImportedFrameAndTimestamp() async throws {
        #if DEBUG
        let times = [0, 1, 3, 6, 7].map { CMTime(value: Int64($0), timescale: 24) }
        let end = CMTime(value: 8, timescale: 24)
        let url = try await makeAsymmetricVideo(transform: .identity, frameCount: times.count,
            presentationTimes: times, endTime: end)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let (track, native, _) = try await qualifyTinyImportedVideo(asset, expectedTimes: times, end: end, fixtureID: "vfr")
        let item = AVPlayerItem(asset: asset), bridge = ContinuousPictureInPicture()
        var owned: ContinuousPictureInPicture.PreparedVideoResource?
        defer { bridge.invalidate(); owned?.retire(); XCTAssertTrue(item.outputs.isEmpty); XCTAssertNil(item.videoComposition) }
        let plan = try await ContinuousPictureInPicture.debugPrepareVideoResource(for: item, nativeGeometry: true)
        owned = plan.install()
        let resource = try XCTUnwrap(owned), output = try XCTUnwrap(resource.output)
        XCTAssertNil(item.videoComposition)
        XCTAssertTrue(resource.debugNativeGeometryValidated); XCTAssertTrue(resource.debugUsesNativeGeometry)
        XCTAssertEqual(item.outputs.count, 1); XCTAssertTrue(item.outputs.first === output)
        _ = try XCTUnwrap(bridge.setCurrentItem(item, preparedVideo: resource))
        XCTAssertTrue(resource.isBorrowed); XCTAssertTrue(resource.isAttached); XCTAssertFalse(resource.isRetired)
        let composition = try await ContinuousPictureInPicture.makeVideoComposition(for: asset)
        let composed = try readTinyVideoFrames(asset, track: track, composition: composition, mode: "composed")
        guard composed.count == native.count else {
            XCTFail("The composition must preserve the complete actual VFR frame count"); throw TinyVideoFailure.comparison
        }
        for index in native.indices {
            XCTAssertEqual(CMTimeCompare(composed[index].pts, native[index].pts), 0, "VFR actual PTS index \(index)")
            XCTAssertEqual(CMTimeCompare(composed[index].duration, native[index].duration), 0, "VFR duration index \(index)")
            XCTAssertEqual(composed[index].pixels, native[index].pixels, "VFR actual pixels index \(index)")
        }
        XCTAssertTrue(resource.isBorrowed); XCTAssertEqual(item.outputs.count, 1)
        #else
        XCTFail("VFR comparison requires the separate DEBUG native preparation API")
        #endif
    }

    func testImportedPositiveOffsetAndCompositionAssetsKeepConservativeFallback() async throws {
        #if DEBUG
        let times = [6, 7, 9, 12, 13].map { CMTime(value: Int64($0), timescale: 24) }
        let end = CMTime(value: 14, timescale: 24)
        let url = try await makeAsymmetricVideo(transform: .identity, frameCount: times.count,
            presentationTimes: times, endTime: end)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let (track, native, range) = try await qualifyTinyImportedVideo(asset, expectedTimes: times, end: end, fixtureID: "offset")
        guard CMTimeCompare(try XCTUnwrap(native.first).pts, .zero) > 0 else {
            XCTFail("The offset must survive actual import and complete native decode"); throw TinyVideoFailure.fixture
        }
        try await assertTinyConservativeFallback(asset)
        let mutable = AVMutableComposition()
        let target = try XCTUnwrap(mutable.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid))
        try target.insertTimeRange(range, of: track, at: .zero)
        try await assertTinyConservativeFallback(mutable)
        let immutable = try XCTUnwrap(mutable.copy() as? AVComposition)
        XCTAssertFalse(immutable is AVMutableComposition)
        try await assertTinyConservativeFallback(immutable)
        #else
        XCTFail("Offset/composition refusal requires the separate DEBUG native preparation API")
        #endif
    }

    #if DEBUG
    private enum TinyVideoFailure: Error { case fixture, comparison, policy }
    private struct TinyVideoFrame { let pts: CMTime, duration: CMTime, pixels: String }

    private func qualifyTinyImportedVideo(_ asset: AVURLAsset, expectedTimes: [CMTime], end: CMTime, fixtureID: String)
        async throws -> (AVAssetTrack, [TinyVideoFrame], CMTimeRange) {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            XCTFail("The tiny imported fixture needs exactly one actual video track"); throw TinyVideoFailure.fixture
        }
        let range = try await track.load(.timeRange), duration = try await asset.load(.duration)
        print("TinyVideoImportObserved schema=1 rangeStartValue=\(range.start.value) rangeStartScale=\(range.start.timescale) rangeStartFlags=\(range.start.flags.rawValue) rangeStartEpoch=\(range.start.epoch) rangeDurationValue=\(range.duration.value) rangeDurationScale=\(range.duration.timescale) rangeDurationFlags=\(range.duration.flags.rawValue) assetDurationValue=\(duration.value) assetDurationScale=\(duration.timescale) assetDurationFlags=\(duration.flags.rawValue) fixtureQualification=pending latencyEvidence=false")
        let segments = try await track.load(.segments)
        func raw(_ time: CMTime) -> String {
            "\(time.value)/\(time.timescale)/\(time.flags.rawValue)/\(time.epoch)"
        }
        print("TinyVideoSegmentsObserved schema=1 count=\(segments.count) emitted=\(min(segments.count, 8)) truncated=\(segments.count > 8) expectedFirst=\(raw(expectedTimes[0])) rawTimeFields=value/scale/flags/epoch fixtureQualification=pending latencyEvidence=false")
        for (index, segment) in segments.prefix(8).enumerated() {
            let mapping = segment.timeMapping
            print("TinyVideoSegmentObserved schema=1 index=\(index) isEmpty=\(segment.isEmpty) sourceStart=\(raw(mapping.source.start)) sourceDuration=\(raw(mapping.source.duration)) targetStart=\(raw(mapping.target.start)) targetDuration=\(raw(mapping.target.duration)) rawTimeFields=value/scale/flags/epoch fixtureQualification=pending latencyEvidence=false")
        }
        observeTinyVideoBufferTiming(asset, track: track, fixtureID: fixtureID)
        let frames = try readTinyVideoFrames(asset, track: track, composition: nil, mode: "native")
        guard frames.count == expectedTimes.count, frames.count >= 3, frames.count <= 8,
              range.start.isNumeric, range.duration.isNumeric, duration.isNumeric,
              (CMTimeCompare(range.start, expectedTimes[0]) == 0 || CMTimeCompare(range.start, .zero) == 0),
              CMTimeCompare(duration, end) == 0,
              CMTimeCompare(CMTimeRangeGetEnd(range), end) == 0,
              Set(frames.map { $0.pixels }).count == frames.count else {
            XCTFail("Actual imported range, all distinguishable native frames and endpoint must qualify"); throw TinyVideoFailure.fixture
        }
        for index in frames.indices {
            guard CMTimeCompare(frames[index].pts, expectedTimes[index]) == 0 else {
                XCTFail("Writer inputs are not proof: actual imported PTS index \(index) must match"); throw TinyVideoFailure.fixture
            }
            let next = index + 1 < frames.count ? frames[index + 1].pts : end
            guard CMTimeCompare(CMTimeAdd(frames[index].pts, frames[index].duration), next) == 0 else {
                XCTFail("Every actual native sample duration must preserve full coverage"); throw TinyVideoFailure.fixture
            }
        }
        let intervals = zip(frames, frames.dropFirst()).map { CMTimeSubtract($1.pts, $0.pts) }
        guard intervals.dropFirst().contains(where: { CMTimeCompare($0, intervals[0]) != 0 }) else {
            XCTFail("The imported native sequence must remain nonuniform"); throw TinyVideoFailure.fixture
        }
        print("TinyVideoImported schema=1 frames=\(frames.count) rangeStartValue=\(range.start.value) rangeStartScale=\(range.start.timescale) rangeDurationValue=\(range.duration.value) rangeDurationScale=\(range.duration.timescale) assetDurationValue=\(duration.value) assetDurationScale=\(duration.timescale) nonuniform=true allPixelsDistinct=true source=actual-import-and-native-EOF latencyEvidence=false")
        return (track, frames, range)
    }

    private func observeTinyVideoBufferTiming(_ asset: AVAsset, track: AVAssetTrack, fixtureID: String) {
        func raw(_ time: CMTime) -> String {
            "\(time.value)/\(time.timescale)/\(time.flags.rawValue)/\(time.epoch)"
        }
        for mode in ["compressed", "decoded"] {
            if Task.isCancelled {
                print("TinyVideoTimingScanTerminal schema=1 fixture=\(fixtureID) mode=\(mode) terminal=task-cancelled returned=0 observedNil=false completedEOF=false diagnosticsOnly=true")
                break
            }
            do {
                let reader = try AVAssetReader(asset: asset)
                defer { reader.cancelReading() }
                let settings: [String: Any]? = mode == "decoded"
                    ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] : nil
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    print("TinyVideoTimingScanTerminal schema=1 fixture=\(fixtureID) mode=\(mode) terminal=output-rejected returned=0 observedNil=false completedEOF=false diagnosticsOnly=true")
                    continue
                }
                reader.add(output) // Full asset; no timeRange, sample filtering or timing inference.
                guard reader.startReading() else {
                    print("TinyVideoTimingScanTerminal schema=1 fixture=\(fixtureID) mode=\(mode) terminal=reader-start-failed status=\(reader.status.rawValue) errorPresent=\(reader.error != nil) errorCode=\((reader.error as NSError?)?.code ?? 0) returned=0 observedNil=false completedEOF=false diagnosticsOnly=true")
                    continue
                }
                var returned = 0, observedNil = false
                while returned < 32 && !Task.isCancelled {
                    let found = autoreleasepool { () -> Bool in
                        guard let sample = output.copyNextSampleBuffer() else { return false }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let duration = CMSampleBufferGetDuration(sample)
                        let outputPTS = CMSampleBufferGetOutputPresentationTimeStamp(sample)
                        let outputDuration = CMSampleBufferGetOutputDuration(sample)
                        var timing = CMSampleTimingInfo(duration: .invalid,
                            presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
                        let timingStatus = CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
                        let emptyMedia: String
                        if let value = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_EmptyMedia,
                            attachmentModeOut: nil) {
                            emptyMedia = CFGetTypeID(value) == CFBooleanGetTypeID()
                                ? (CFBooleanGetValue(value as! CFBoolean) ? "true" : "false") : "invalid-type"
                        } else { emptyMedia = "absent-default-false" }
                        let data = CMSampleBufferGetDataBuffer(sample)
                        let dataBytes = data.map { CMBlockBufferGetDataLength($0) } ?? 0
                        print("TinyVideoTimingBufferObserved schema=1 fixture=\(fixtureID) mode=\(mode) index=\(returned) numSamples=\(CMSampleBufferGetNumSamples(sample)) pts=\(raw(pts)) duration=\(raw(duration)) outputPTS=\(raw(outputPTS)) outputDuration=\(raw(outputDuration)) timingStatus=\(timingStatus) samplePTS=\(raw(timing.presentationTimeStamp)) sampleDTS=\(raw(timing.decodeTimeStamp)) sampleDuration=\(raw(timing.duration)) valid=\(CMSampleBufferIsValid(sample)) dataReady=\(CMSampleBufferDataIsReady(sample)) imagePresent=\(CMSampleBufferGetImageBuffer(sample) != nil) dataPresent=\(data != nil) dataBytes=\(dataBytes) totalSampleBytes=\(CMSampleBufferGetTotalSampleSize(sample)) emptyMedia=\(emptyMedia) rawTimeFields=value/scale/flags/epoch qualification=unavailable diagnosticsOnly=true")
                        returned += 1
                        return true
                    }
                    if !found { observedNil = true; break }
                }
                let status = reader.status
                let completedEOF = observedNil && status == .completed
                let capped = returned == 32 && !observedNil
                let terminal = Task.isCancelled ? "task-cancelled" : capped ? "buffer-cap-no-EOF"
                    : completedEOF ? "completed-EOF"
                    : status == .failed ? "reader-error" : status == .cancelled ? "reader-cancelled"
                    : observedNil ? "nil-without-completed" : "stopped-without-EOF"
                print("TinyVideoTimingScanTerminal schema=1 fixture=\(fixtureID) mode=\(mode) terminal=\(terminal) status=\(status.rawValue) errorPresent=\(reader.error != nil) errorCode=\((reader.error as NSError?)?.code ?? 0) returned=\(returned) observedNil=\(observedNil) completedEOF=\(completedEOF) bufferCap=32 qualification=unavailable diagnosticsOnly=true")
                if capped { XCTFail("Metadata-only tiny timing scan reached its 32-buffer bound before EOF") }
            } catch {
                print("TinyVideoTimingScanTerminal schema=1 fixture=\(fixtureID) mode=\(mode) terminal=reader-init-error errorCode=\((error as NSError).code) returned=0 observedNil=false completedEOF=false qualification=unavailable diagnosticsOnly=true")
            }
        }
    }

    private func readTinyVideoFrames(_ asset: AVAsset, track: AVAssetTrack,
        composition: AVVideoComposition?, mode: String) throws -> [TinyVideoFrame] {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output: AVAssetReaderOutput
        if let composition {
            let composed = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings)
            composed.videoComposition = composition; output = composed
        } else { output = AVAssetReaderTrackOutput(track: track, outputSettings: settings) }
        output.alwaysCopiesSampleData = false
        defer { reader.cancelReading() }
        guard reader.canAdd(output) else { throw TinyVideoFailure.fixture }
        reader.add(output) // Entire asset; no timeRange, offset subtraction or cadence conversion.
        guard reader.startReading() else { throw reader.error ?? TinyVideoFailure.fixture }
        var frames: [TinyVideoFrame] = []; frames.reserveCapacity(32)
        while true {
            try Task.checkCancellation()
            let frame = try autoreleasepool { () throws -> TinyVideoFrame? in
                guard let sample = output.copyNextSampleBuffer() else { return nil }
                guard frames.count < 32, CMSampleBufferGetNumSamples(sample) == 1 else {
                    XCTFail("The complete tiny decode exceeded its fixed frame bound"); throw TinyVideoFailure.fixture
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample), duration = CMSampleBufferGetDuration(sample)
                print("TinyVideoFrameObserved schema=1 mode=\(mode) index=\(frames.count) ptsValue=\(pts.value) ptsScale=\(pts.timescale) ptsFlags=\(pts.flags.rawValue) ptsEpoch=\(pts.epoch) durationValue=\(duration.value) durationScale=\(duration.timescale) durationFlags=\(duration.flags.rawValue) durationEpoch=\(duration.epoch) timingQualification=pending latencyEvidence=false")
                guard pts.isNumeric, duration.isNumeric, pts.epoch == 0, duration.epoch == 0,
                      CMTimeCompare(duration, .zero) > 0,
                      frames.last.map({ CMTimeCompare(pts, $0.pts) > 0 }) ?? true else {
                    XCTFail("Actual decoded timestamps/durations must be numeric and ordered"); throw TinyVideoFailure.fixture
                }
                let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
                let stride = CVPixelBufferGetBytesPerRow(pixel)
                guard CVPixelBufferGetWidth(pixel) == 32, CVPixelBufferGetHeight(pixel) == 16,
                      !CVPixelBufferIsPlanar(pixel), CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA,
                      stride >= 128, stride <= 4_096, CVPixelBufferGetDataSize(pixel) >= stride * 16,
                      CVPixelBufferGetDataSize(pixel) <= 1_048_576,
                      CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
                    XCTFail("Every actual tiny frame needs bounded full BGRA pixels"); throw TinyVideoFailure.fixture
                }
                defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
                var hash = SHA256()
                for row in 0..<16 { hash.update(data: Data(bytes: base.advanced(by: row * stride), count: 128)) }
                let pixels = hash.finalize().map { String(format: "%02x", $0) }.joined()
                return TinyVideoFrame(pts: pts, duration: duration, pixels: pixels)
            }
            guard let frame else { break }
            frames.append(frame)
        }
        guard reader.status == .completed, !frames.isEmpty else {
            XCTFail("The complete tiny reader must reach actual EOF"); throw reader.error ?? TinyVideoFailure.fixture
        }
        for (index, frame) in frames.enumerated() {
            print("TinyVideoDecoded schema=1 mode=\(mode) index=\(index) count=\(frames.count) ptsValue=\(frame.pts.value) ptsScale=\(frame.pts.timescale) durationValue=\(frame.duration.value) durationScale=\(frame.duration.timescale) pixelHash=\(frame.pixels) completedEOF=true latencyEvidence=false")
        }
        return frames
    }

    private func assertTinyConservativeFallback(_ asset: AVAsset) async throws {
        let item = AVPlayerItem(asset: asset), bridge = ContinuousPictureInPicture()
        var owned: ContinuousPictureInPicture.PreparedVideoResource?
        defer { bridge.invalidate(); owned?.retire(); XCTAssertTrue(item.outputs.isEmpty); XCTAssertNil(item.videoComposition) }
        for enabled in [false, true] {
            var refused = false
            do {
                _ = try await ContinuousPictureInPicture.debugPrepareVideoResource(for: item, nativeGeometry: enabled)
            } catch ContinuousPictureInPicture.DebugNativeGeometryFailure.unqualified { refused = true }
            XCTAssertTrue(refused, "Both explicit comparison arms must refuse this unqualified asset")
            guard refused else { throw TinyVideoFailure.policy }
            XCTAssertTrue(item.outputs.isEmpty); XCTAssertNil(item.videoComposition)
        }
        let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
        owned = plan.install()
        let resource = try XCTUnwrap(owned), installed = try XCTUnwrap(item.videoComposition)
        let output = try XCTUnwrap(resource.output)
        XCTAssertEqual(item.outputs.count, 1); XCTAssertTrue(item.outputs.first === output)
        _ = try XCTUnwrap(bridge.setCurrentItem(item, preparedVideo: resource))
        XCTAssertTrue(resource.isBorrowed); XCTAssertTrue(resource.isAttached); XCTAssertFalse(resource.isRetired)
        XCTAssertTrue(item.videoComposition === installed)
    }
    #endif

    func testNativeVideoGeometryRequiresSquareFullIntegralIdentityDescriptions() throws {
        #if DEBUG
        typealias Geometry = ContinuousPictureInPicture.VideoResourcePreparation.NativeVideoGeometry
        let size = CGSize(width: 160, height: 96)
        func description(width: Int32 = 160, height: Int32 = 96,
                         extensions: [String: Any] = [:]) throws -> CMFormatDescription {
            var result: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                codecType: kCVPixelFormatType_32BGRA, width: width, height: height,
                extensions: extensions.isEmpty ? nil : (extensions as CFDictionary), formatDescriptionOut: &result)
            XCTAssertEqual(status, 0, "CoreMedia must create the actual geometry description")
            return try XCTUnwrap(result)
        }
        let aperture: [String: Any] = [
            kCMFormatDescriptionKey_CleanApertureWidth as String: 160,
            kCMFormatDescriptionKey_CleanApertureHeight as String: 96,
            kCMFormatDescriptionKey_CleanApertureHorizontalOffset as String: 0,
            kCMFormatDescriptionKey_CleanApertureVerticalOffset as String: 0
        ]
        let square: [String: Any] = [
            kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String: 1,
            kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String: 1
        ]
        let plain = try description()
        let full = try description(extensions: [
            kCMFormatDescriptionExtension_CleanAperture as String: aperture,
            kCMFormatDescriptionExtension_PixelAspectRatio as String: square
        ])
        for formats in [[plain], [full], [plain, full]] {
            let proof = try XCTUnwrap(Geometry.validate(naturalSize: size, preferredTransform: .identity,
                formatDescriptions: formats))
            XCTAssertEqual(proof.width, 160); XCTAssertEqual(proof.height, 96)
        }
        var cropped = aperture, nonSquare = square, compensated = aperture
        cropped[kCMFormatDescriptionKey_CleanApertureWidth as String] = 144
        nonSquare[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] = 2
        compensated[kCMFormatDescriptionKey_CleanApertureWidth as String] = 80
        let crop = try description(extensions: [kCMFormatDescriptionExtension_CleanAperture as String: cropped])
        let aspect = try description(extensions: [kCMFormatDescriptionExtension_PixelAspectRatio as String: nonSquare])
        let cropAspect = try description(extensions: [
            kCMFormatDescriptionExtension_CleanAperture as String: compensated,
            kCMFormatDescriptionExtension_PixelAspectRatio as String: nonSquare
        ])
        let wide = try description(width: 320)
        let refusals: [(String, CGSize, CGAffineTransform, [CMFormatDescription])] = [
            ("rotated", size, CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 96, ty: 0), [plain]),
            ("mirrored", size, CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 160, ty: 0), [plain]),
            ("translated", size, CGAffineTransform(translationX: 1, y: 0), [plain]),
            ("fractional-size", CGSize(width: 160.5, height: 96), .identity, [plain]),
            ("empty-size", .zero, .identity, [plain]),
            ("empty-descriptions", size, .identity, []),
            ("mixed-coded-dimensions", size, .identity, [plain, wide]),
            ("crop", size, .identity, [crop]),
            ("non-square-PAR", size, .identity, [aspect]),
            ("crop-aspect-compensation", size, .identity, [cropAspect])
        ]
        for (label, natural, transform, formats) in refusals {
            XCTAssertNil(Geometry.validate(naturalSize: natural, preferredTransform: transform,
                formatDescriptions: formats), label)
        }
        #else
        XCTFail("Native geometry proof validation requires the DEBUG comparison API")
        #endif
    }

    func testPreparedExistingVideoCompositionSurvivesPreparationBorrowAndRetirement() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-a", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let external = try await ContinuousPictureInPicture.makeVideoComposition(for: asset)
        item.videoComposition = external
        let installedExternal = try XCTUnwrap(item.videoComposition)
        let bridge = ContinuousPictureInPicture()
        var owned: ContinuousPictureInPicture.PreparedVideoResource?
        defer {
            bridge.invalidate(); owned?.retire()
            XCTAssertTrue(item.outputs.isEmpty)
            XCTAssertTrue(item.videoComposition === installedExternal)
        }
        let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
        XCTAssertTrue(item.videoComposition === installedExternal)
        owned = plan.install()
        let resource = try XCTUnwrap(owned), output = try XCTUnwrap(resource.output)
        XCTAssertTrue(item.videoComposition === installedExternal)
        XCTAssertEqual(item.outputs.count, 1); XCTAssertTrue(item.outputs.first === output)
        _ = try XCTUnwrap(bridge.setCurrentItem(item, preparedVideo: resource))
        XCTAssertTrue(resource.isAttached); XCTAssertTrue(resource.isBorrowed); XCTAssertFalse(resource.isRetired)
        resource.retire()
        XCTAssertTrue(resource.isRetired); XCTAssertTrue(resource.isBorrowed); XCTAssertTrue(resource.isAttached)
        XCTAssertTrue(resource.output === output); XCTAssertEqual(item.outputs.count, 1)
        XCTAssertTrue(item.videoComposition === installedExternal)
        bridge.setCurrentItem(nil)
        XCTAssertFalse(resource.isBorrowed); XCTAssertFalse(resource.isAttached); XCTAssertNil(resource.output)
        XCTAssertTrue(item.outputs.isEmpty); XCTAssertTrue(item.videoComposition === installedExternal)
    }

    func testPortraitAndMirrorCompositionProducesOrientedPixelsAndPreservesSourceTiming() async throws {
        let cases: [(CGAffineTransform, CGSize, Bool)] = [
            (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 16, ty: 0), CGSize(width: 16, height: 32), false),
            (CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0), CGSize(width: 32, height: 16), true)
        ]
        for (transform, expectedSize, mirrored) in cases {
            let url = try await makeAsymmetricVideo(transform: transform)
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let duration = try await asset.load(.duration)
            let composition = try await ContinuousPictureInPicture.makeVideoComposition(for: asset)
            XCTAssertEqual(composition.renderSize, expectedSize)
            XCTAssertEqual(composition.sourceTrackIDForFrameTiming, track.trackID)
            XCTAssertEqual(CMTimeCompare(try XCTUnwrap(composition.instructions.first).timeRange.duration, duration), 0)
            let item = AVPlayerItem(asset: asset)
            var owned: ContinuousPictureInPicture.PreparedVideoResource?
            defer {
                owned?.retire()
                XCTAssertTrue(item.outputs.isEmpty); XCTAssertNil(item.videoComposition)
            }
            let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
            owned = plan.install()
            let resource = try XCTUnwrap(owned), preparedOutput = try XCTUnwrap(resource.output)
            let routed = try XCTUnwrap(item.videoComposition, "Non-native geometry must route through preparation's composition")
            XCTAssertTrue(resource.isAttached); XCTAssertFalse(resource.isRetired); XCTAssertFalse(resource.isBorrowed)
            XCTAssertEqual(item.outputs.count, 1); XCTAssertTrue(item.outputs.first === preparedOutput)
            XCTAssertEqual(routed.renderSize, expectedSize)
            XCTAssertEqual(routed.sourceTrackIDForFrameTiming, track.trackID)
            XCTAssertEqual(CMTimeCompare(try XCTUnwrap(routed.instructions.first).timeRange.duration, duration), 0)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks,
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = routed
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            defer { reader.cancelReading() }
            let first = try XCTUnwrap(output.copyNextSampleBuffer())
            let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(first))
            XCTAssertEqual(CVPixelBufferGetWidth(pixel), Int(expectedSize.width))
            XCTAssertEqual(CVPixelBufferGetHeight(pixel), Int(expectedSize.height))
            if mirrored {
                XCTAssertTrue(isBlue(pixel, x: 8, y: 8))
                XCTAssertFalse(isBlue(pixel, x: 24, y: 8))
            } else {
                // Rotation moves the original left/right split onto the vertical axis.
                XCTAssertNotEqual(isBlue(pixel, x: 8, y: 8), isBlue(pixel, x: 8, y: 24))
            }
            let second = try XCTUnwrap(output.copyNextSampleBuffer())
            XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(second)), 1.0 / 24, accuracy: 0.000_01)
            XCTAssertNil(output.copyNextSampleBuffer())
            XCTAssertEqual(reader.status, .completed)
        }
    }

    func testChangingItemCancelsOrientationPreparationAndCannotAttachOldOutput() async throws {
        let url = try await makeAsymmetricVideo(transform: .identity)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = AVPlayerItem(url: url)
        let bridge = ContinuousPictureInPicture()
        defer { bridge.invalidate() }
        bridge.setCurrentItem(item)
        bridge.setCurrentItem(nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(bridge.orientationPrepared)
        XCTAssertTrue(item.outputs.isEmpty)
        XCTAssertNil(item.videoComposition)
    }

    func testAdoptionCannotAcquireTheDepartingTimelineBeforeActivation() async throws {
        #if DEBUG
        // Two seconds of real 24fps video leaves room for distinct nonzero
        // timelines. This test observes acquisition/submission, not scanout.
        let urlA = try await makeAsymmetricVideo(transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0), frameCount: 48)
        defer { try? FileManager.default.removeItem(at: urlA) }
        let urlB = try await makeAsymmetricVideo(transform: .identity, frameCount: 48)
        defer { try? FileManager.default.removeItem(at: urlB) }
        let itemA = AVPlayerItem(url: urlA), itemB = AVPlayerItem(url: urlB)
        let player = AVPlayer(playerItem: itemB)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        let bridge = ContinuousPictureInPicture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        host.view.backgroundColor = .black
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = host.view.bounds
        host.view.layer.addSublayer(playerLayer)
        bridge.displayLayer.frame = host.view.bounds
        host.view.layer.addSublayer(bridge.displayLayer)
        var requests: [(item: AVPlayerItem, time: CMTime)] = []
        requests.reserveCapacity(1024)
        var requestOverflow = false
        var reportedTargetMask: UInt8 = 0
        bridge.onFrameAcquisition = { item, time in
            if requests.count < 1024 { requests.append((item, time)) }
            else { requestOverflow = true }
        }
        defer {
            bridge.onFrameAcquisition = nil
            bridge.invalidate()
            player.pause(); player.replaceCurrentItem(with: nil)
            playerLayer.player = nil
            bridge.displayLayer.removeFromSuperlayer(); playerLayer.removeFromSuperlayer()
            window.isHidden = true; window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        @MainActor func exerciseGenericUpdates(at position: Double, playing: Bool = false) async {
            for _ in 0..<3 {
                bridge.updatePlayback(positionSeconds: position, durationSeconds: 2, isPlaying: playing)
                bridge.suspendFrameFeed(); bridge.resumeFrameFeed()
                await Task.yield()
            }
        }
        @MainActor func assertClosed(requestCount: Int, submitted: UInt64, _ stage: String) {
            let first: (item: AVPlayerItem, time: CMTime)? = requestCount < requests.count ? requests[requestCount] : nil
            let firstTarget = first.map { $0.time.isNumeric ? $0.time.seconds : -1 } ?? -1
            let stageCode = stage.replacingOccurrences(of: " ", with: "_")
            print("PresentationAdoptionClosed stage=\(stageCode) requestDelta=\(requests.count - requestCount) firstTarget=\(firstTarget) firstIsA=\(first?.item === itemA) firstIsB=\(first?.item === itemB) copied=\(bridge.lastCopiedFramePositionSeconds ?? -1) frame=\(bridge.lastFramePositionSeconds ?? -1) submittedCount=\(bridge.submittedFrameCount) submittedBaseline=\(submitted)")
            XCTAssertEqual(requests.count, requestCount, stage + " must not reach the real output acquisition guard")
            XCTAssertEqual(bridge.submittedFrameCount, submitted, stage + " must not submit a frame")
            XCTAssertNil(bridge.lastCopiedFramePositionSeconds, stage + " must not consume an output frame")
            XCTAssertNil(bridge.lastFramePositionSeconds, stage + " must not enqueue an output frame")
            XCTAssertFalse(requestOverflow)
        }
        @MainActor func hasSubmittedTarget(_ item: AVPlayerItem, target: Double, after submitted: UInt64) -> Bool {
            bridge.updatePlayback(positionSeconds: target, durationSeconds: 2, isPlaying: false)
            guard bridge.submittedFrameCount > submitted,
                  let copied = bridge.lastCopiedFramePositionSeconds,
                  let presented = bridge.lastFramePositionSeconds else { return false }
            let valid = copied <= target + 0.000_01 && presented <= target + 0.000_01
                && abs(copied - target) <= 1.0 / 24 + 0.000_01
                && abs(presented - target) <= 1.0 / 24 + 0.000_01
                && requests.contains { $0.item === item && $0.time.isNumeric && abs($0.time.seconds - target) < 0.000_01 }
            guard valid else { return false }
            let targetBit: UInt8 = target == 0.75 ? 1 : target == 0.25 ? 2 : target == 0.5 ? 4 : target == 0.125 ? 8 : 16
            if reportedTargetMask & targetBit == 0 {
                reportedTargetMask |= targetBit
                print("PresentationAdoptionTarget target=\(target) isA=\(item === itemA) isB=\(item === itemB) copied=\(copied) frame=\(presented) submittedCount=\(bridge.submittedFrameCount) submittedBaseline=\(submitted) acquisitionCount=\(requests.count)")
            }
            return true
        }

        let ticketB = try XCTUnwrap(bridge.setCurrentItem(itemB))
        guard await waitForPresentation({ bridge.orientationPrepared && !itemB.outputs.isEmpty && itemB.status == .readyToPlay }) else {
            XCTFail("B's real video output must attach within the bounded setup window"); return
        }
        guard await seekPresentationPlayer(player, to: 0.75) else { XCTFail("B's real nonzero seek must complete"); return }
        XCTAssertTrue(bridge.installTimeline(ticketB, positionSeconds: 0.75, durationSeconds: 2, isPlaying: false))
        XCTAssertTrue(bridge.activate(ticketB))
        guard await waitForPresentation({ hasSubmittedTarget(itemB, target: 0.75, after: 0) }) else {
            XCTFail("The departing B timeline must first copy and submit an actual nonzero frame"); return
        }
        XCTAssertGreaterThan(try XCTUnwrap(bridge.lastFramePositionSeconds), 0.5)

        let requestsBeforeA = requests.count, submittedBeforeA = bridge.submittedFrameCount
        let ticketA = try XCTUnwrap(bridge.setCurrentItem(itemA))
        player.replaceCurrentItem(with: itemA)
        await exerciseGenericUpdates(at: 0.75, playing: true)
        guard await waitForPresentation({ bridge.orientationPrepared && !itemA.outputs.isEmpty && itemA.status == .readyToPlay }) else {
            XCTFail("A's asynchronous output attachment must finish while its timeline gate remains closed"); return
        }
        await exerciseGenericUpdates(at: 0.75, playing: true)
        XCTAssertTrue(itemB.outputs.isEmpty)
        assertClosed(requestCount: requestsBeforeA, submitted: submittedBeforeA, "A adoption and asynchronous attachment")
        guard await seekPresentationPlayer(player, to: 0.25) else { XCTFail("A's paused target must be decoded by a real seek"); return }
        assertClosed(requestCount: requestsBeforeA, submitted: submittedBeforeA, "A's native seek before timeline installation")
        XCTAssertTrue(bridge.installTimeline(ticketA, positionSeconds: 0.25, durationSeconds: 2, isPlaying: false))
        XCTAssertFalse(bridge.installTimeline(ticketB, positionSeconds: 0.75, durationSeconds: 2, isPlaying: true))
        XCTAssertFalse(bridge.activate(ticketB), "The departing item's ticket cannot open A's gate")
        await exerciseGenericUpdates(at: 0.25)
        assertClosed(requestCount: requestsBeforeA, submitted: submittedBeforeA, "Installing A's timeline without activation")
        XCTAssertTrue(bridge.activate(ticketA))
        guard await waitForPresentation({ hasSubmittedTarget(itemA, target: 0.25, after: submittedBeforeA) }) else {
            XCTFail("Activating A's matching ticket must submit a real paused-target frame"); return
        }

        let heldSeek = bridge.beginSeek()
        let heldRequests = requests.count, heldSubmitted = bridge.submittedFrameCount
        let blockedBefore = bridge.blockedFrameAcquisitionCount
        guard await seekPresentationPlayer(player, to: 0.5) else { XCTFail("Held A seek must actually complete in AVPlayer"); return }
        await exerciseGenericUpdates(at: 0.5)
        assertClosed(requestCount: heldRequests, submitted: heldSubmitted, "A's held seek completion")
        XCTAssertGreaterThan(bridge.blockedFrameAcquisitionCount, blockedBefore)
        XCTAssertFalse(bridge.activate(ticketA), "Activation must not bypass a held native seek completion")
        bridge.completeSeek(heldSeek &+ 1)
        await exerciseGenericUpdates(at: 0.5)
        assertClosed(requestCount: heldRequests, submitted: heldSubmitted, "An unrelated seek completion")
        XCTAssertTrue(bridge.installTimeline(ticketA, positionSeconds: 0.5, durationSeconds: 2, isPlaying: false))
        bridge.completeSeek(heldSeek)
        XCTAssertTrue(bridge.activate(ticketA))
        guard await waitForPresentation({ hasSubmittedTarget(itemA, target: 0.5, after: heldSubmitted) }) else {
            XCTFail("The matching seek completion must allow A's actual paused target"); return
        }

        let abaRequests = requests.count, abaSubmitted = bridge.submittedFrameCount
        let interveningB = try XCTUnwrap(bridge.setCurrentItem(itemB))
        let returnedA = try XCTUnwrap(bridge.setCurrentItem(itemA))
        XCTAssertFalse(bridge.installTimeline(ticketA, positionSeconds: 0.5, durationSeconds: 2, isPlaying: false))
        XCTAssertFalse(bridge.activate(ticketA), "An old A ticket must remain stale after A-B-A")
        XCTAssertFalse(bridge.activate(interveningB))
        guard await waitForPresentation({ bridge.orientationPrepared && !itemA.outputs.isEmpty }) else {
            XCTFail("Returned A must attach a real output"); return
        }
        guard await seekPresentationPlayer(player, to: 0.125) else { XCTFail("Returned A's target seek must complete"); return }
        await exerciseGenericUpdates(at: 0.125)
        assertClosed(requestCount: abaRequests, submitted: abaSubmitted, "A-B-A before the current ticket")
        XCTAssertTrue(bridge.installTimeline(returnedA, positionSeconds: 0.125, durationSeconds: 2, isPlaying: false))
        await exerciseGenericUpdates(at: 0.125)
        assertClosed(requestCount: abaRequests, submitted: abaSubmitted, "Returned A's installed, inactive ticket")
        XCTAssertTrue(bridge.activate(returnedA))
        guard await waitForPresentation({ hasSubmittedTarget(itemA, target: 0.125, after: abaSubmitted) }) else {
            XCTFail("Only returned A's current ticket may submit its actual target frame"); return
        }

        let sameItemRequests = requests.count, sameItemSubmitted = bridge.submittedFrameCount
        let adoptedAgain = try XCTUnwrap(bridge.setCurrentItem(itemA))
        XCTAssertFalse(bridge.installTimeline(returnedA, positionSeconds: 0.5, durationSeconds: 2, isPlaying: false))
        XCTAssertFalse(bridge.activate(returnedA), "Same-item re-adoption must also invalidate the previous presentation ticket")
        await exerciseGenericUpdates(at: 0.125)
        assertClosed(requestCount: sameItemRequests, submitted: sameItemSubmitted, "Same-item re-adoption before a fresh timeline")
        guard await seekPresentationPlayer(player, to: 0.375) else { XCTFail("Same-item re-adoption's distinct target must actually seek"); return }
        XCTAssertTrue(bridge.installTimeline(adoptedAgain, positionSeconds: 0.375, durationSeconds: 2, isPlaying: false))
        assertClosed(requestCount: sameItemRequests, submitted: sameItemSubmitted, "Same-item timeline installed before activation")
        XCTAssertTrue(bridge.activate(adoptedAgain))
        guard await waitForPresentation({ hasSubmittedTarget(itemA, target: 0.375, after: sameItemSubmitted) }) else {
            XCTFail("Same-item re-adoption must still submit its distinct actual target"); return
        }
        XCTAssertFalse(requestOverflow)
        #else
        throw XCTSkip("The real acquisition observer is available in DEBUG native tests")
        #endif
    }

    func testAbandonTimelineRequiresMatchingOwnerAndPreservesReentrantPresentation() async throws {
        #if DEBUG
        typealias Resource = ContinuousPictureInPicture.PreparedVideoResource
        typealias Ticket = ContinuousPictureInPicture.PresentationTicket
        let urlA = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-a", withExtension: "mp4"))
        let urlB = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-b", withExtension: "mp4"))
        let itemA = AVPlayerItem(url: urlA), itemB = AVPlayerItem(url: urlB)
        let bridge = ContinuousPictureInPicture()
        var ownedA: Resource?, ownedB: Resource?
        // Register before preparing/installing or unwrapping either real resource.
        defer {
            bridge.onCurrentFrameInvalidated = nil
            bridge.invalidate()
            ownedA?.retire(); ownedB?.retire()
            XCTAssertTrue(itemA.outputs.isEmpty); XCTAssertTrue(itemB.outputs.isEmpty)
        }
        let planA = try await ContinuousPictureInPicture.prepareVideoResource(for: itemA)
        ownedA = planA.install()
        let resourceA = try XCTUnwrap(ownedA), outputA = try XCTUnwrap(resourceA.output)
        let planB = try await ContinuousPictureInPicture.prepareVideoResource(for: itemB)
        ownedB = planB.install()
        let resourceB = try XCTUnwrap(ownedB), outputB = try XCTUnwrap(resourceB.output)
        @MainActor func assertResources(selected: AVPlayerItem, feedSuspended: Bool = false) {
            XCTAssertTrue(resourceA.item === itemA); XCTAssertTrue(resourceB.item === itemB)
            XCTAssertTrue(resourceA.output === outputA); XCTAssertTrue(resourceB.output === outputB)
            XCTAssertEqual(itemA.outputs.count, 1); XCTAssertEqual(itemB.outputs.count, 1)
            XCTAssertTrue(itemA.outputs.first === outputA); XCTAssertTrue(itemB.outputs.first === outputB)
            XCTAssertLessThanOrEqual(itemA.outputs.count + itemB.outputs.count, 3)
            XCTAssertTrue(resourceA.isAttached); XCTAssertTrue(resourceB.isAttached)
            XCTAssertFalse(resourceA.isRetired); XCTAssertFalse(resourceB.isRetired)
            XCTAssertEqual(resourceA.isBorrowed, selected === itemA)
            XCTAssertEqual(resourceB.isBorrowed, selected === itemB)
            XCTAssertEqual(bridge.isFrameFeedSuspended, feedSuspended, "Abandonment must preserve the existing feed policy")
        }
        @MainActor func install(_ ticket: Ticket) {
            XCTAssertTrue(bridge.installTimeline(ticket, positionSeconds: 0.5, durationSeconds: 30, isPlaying: false))
        }
        @MainActor func assertEligible(_ ticket: Ticket, output: AVPlayerItemVideoOutput) {
            XCTAssertTrue(bridge.activate(ticket))
            let state = bridge.debugAlignedPollState
            XCTAssertEqual(state.ticket, ticket); XCTAssertEqual(state.output, ObjectIdentifier(output))
            XCTAssertNil(state.activeSeekTicket); XCTAssertTrue(state.coherent)
        }
        // Coherent/activate below describe app-owned timeline eligibility only.
        // No AVPlayer/window, fabricated receipt, frame or audibility proof is used.
        let original = try XCTUnwrap(bridge.setCurrentItem(itemA, preparedVideo: resourceA))
        install(original); assertEligible(original, output: outputA); assertResources(selected: itemA)
        let oldSeek = bridge.beginSeek(), newerSeek = bridge.beginSeek()
        install(original)
        let active = bridge.debugAlignedPollState
        bridge.abandonTimeline(original, for: itemA, afterSeek: oldSeek)
        XCTAssertEqual(bridge.debugNativeSeekState.activeTicket, newerSeek)
        XCTAssertEqual(bridge.debugAlignedPollState.imageEpoch, active.imageEpoch)
        XCTAssertFalse(bridge.activate(original), "The newer seek barrier must remain active")
        bridge.completeSeek(newerSeek)
        assertEligible(original, output: outputA)
        let completed = bridge.debugAlignedPollState
        bridge.abandonTimeline(original, for: itemA, afterSeek: oldSeek)
        XCTAssertEqual(bridge.debugNativeSeekState.serial, newerSeek)
        XCTAssertNil(bridge.debugNativeSeekState.activeTicket)
        XCTAssertEqual(bridge.debugAlignedPollState.imageEpoch, completed.imageEpoch)
        assertEligible(original, output: outputA)
        bridge.abandonTimeline(original, for: itemB, afterSeek: newerSeek)
        XCTAssertEqual(bridge.debugAlignedPollState.imageEpoch, completed.imageEpoch)
        assertEligible(original, output: outputA); assertResources(selected: itemA)

        // Same-item re-adoption isolates the presentation revision from item identity.
        let current = try XCTUnwrap(bridge.setCurrentItem(itemA, preparedVideo: resourceA))
        XCTAssertNotEqual(current, original)
        install(current); assertEligible(current, output: outputA)
        let readopted = bridge.debugAlignedPollState
        bridge.abandonTimeline(original, for: itemA, afterSeek: newerSeek)
        XCTAssertEqual(bridge.debugAlignedPollState.imageEpoch, readopted.imageEpoch)
        assertEligible(current, output: outputA); assertResources(selected: itemA)

        // Both legal matching states (issued and already completed) must close.
        for completeFirst in [false, true] {
            let seek = bridge.beginSeek()
            install(current)
            if completeFirst { bridge.completeSeek(seek); assertEligible(current, output: outputA) }
            if completeFirst { bridge.suspendFrameFeed() }
            let before = bridge.debugAlignedPollState
            bridge.abandonTimeline(current, for: itemA, afterSeek: seek)
            XCTAssertEqual(bridge.debugNativeSeekState.serial, seek)
            XCTAssertEqual(bridge.debugNativeSeekState.activeTicket, completeFirst ? nil : seek)
            XCTAssertGreaterThan(bridge.debugAlignedPollState.imageEpoch, before.imageEpoch)
            XCTAssertFalse(bridge.activate(current), "Exact abandonment must remove timeline eligibility")
            bridge.completeSeek(seek)
            XCTAssertNil(bridge.debugNativeSeekState.activeTicket)
            XCTAssertFalse(bridge.activate(current), "The original completion cannot reopen an abandoned timeline")
            XCTAssertFalse(bridge.debugAlignedPollState.coherent)
            assertResources(selected: itemA, feedSuspended: completeFirst)
            if completeFirst { bridge.resumeFrameFeed() }
        }

        // One synchronous invalidation callback replaces A with the real prepared B.
        let reentrantSeek = bridge.beginSeek()
        install(current)
        var callbacks = 0, callbackOverflow = false
        var replacement: Ticket?, replacementState: ContinuousPictureInPicture.DebugAlignedPollState?
        bridge.onCurrentFrameInvalidated = { [weak bridge] in
            guard let bridge else { return }
            guard callbacks == 0 else { callbackOverflow = true; return }
            callbacks = 1
            bridge.onCurrentFrameInvalidated = nil
            replacement = bridge.setCurrentItem(itemB, preparedVideo: resourceB)
            if let replacement {
                XCTAssertTrue(bridge.installTimeline(replacement, positionSeconds: 0.5, durationSeconds: 30, isPlaying: false))
                XCTAssertTrue(bridge.activate(replacement))
                replacementState = bridge.debugAlignedPollState
            }
        }
        bridge.abandonTimeline(current, for: itemA, afterSeek: reentrantSeek)
        bridge.onCurrentFrameInvalidated = nil
        let replacementTicket = try XCTUnwrap(replacement), established = try XCTUnwrap(replacementState)
        XCTAssertEqual(callbacks, 1); XCTAssertFalse(callbackOverflow)
        XCTAssertTrue(established.coherent)
        bridge.completeSeek(reentrantSeek)
        XCTAssertEqual(bridge.debugAlignedPollState.imageEpoch, established.imageEpoch)
        assertEligible(replacementTicket, output: outputB); assertResources(selected: itemB)
        XCTAssertFalse(bridge.activate(current), "The replaced A presentation cannot reopen")
        #else
        XCTFail("The abandonment ownership contract requires DEBUG cached-state observations")
        #endif
    }

    func testSameItemSeekAfterSuccessfulCopyCannotEnqueueOrCreditTheOldFrame() async throws {
        #if DEBUG
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-selection-a", withExtension: "mp4"))
        let item = AVPlayerItem(url: url)
        let plan = try await ContinuousPictureInPicture.prepareVideoResource(for: item)
        let resource = try XCTUnwrap(plan.install())
        let bridge = ContinuousPictureInPicture()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true; player.automaticallyWaitsToMinimizeStalling = false
        var ownedWindow: UIWindow?, ownedPlayerLayer: AVPlayerLayer?
        weak var previousKeyWindow: UIWindow?
        var heldSeek: UInt64?
        // Cleanup is registered before any optional scene/window/ticket unwrap.
        // The fixture is bundled public synthetic media, so no file is deleted.
        defer {
            bridge.onDebugRenderStamp = nil
            if let heldSeek { bridge.completeSeek(heldSeek) }
            bridge.invalidate()
            item.cancelPendingSeeks(); player.pause(); player.replaceCurrentItem(with: nil)
            resource.retire(); ownedPlayerLayer?.player = nil
            bridge.displayLayer.removeFromSuperlayer(); ownedPlayerLayer?.removeFromSuperlayer()
            ownedWindow?.isHidden = true; ownedWindow?.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        let ticket = try XCTUnwrap(bridge.setCurrentItem(item, preparedVideo: resource))
        let output = try XCTUnwrap(resource.output)
        let outputID = ObjectIdentifier(output), itemID = ObjectIdentifier(item)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        ownedWindow = window
        window.frame = scene.coordinateSpace.bounds; window.windowLevel = .alert + 1
        window.rootViewController = host; host.view.backgroundColor = .black
        window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        let playerLayer = AVPlayerLayer(player: player)
        ownedPlayerLayer = playerLayer
        playerLayer.frame = host.view.bounds; host.view.layer.addSublayer(playerLayer)
        bridge.displayLayer.frame = host.view.bounds; host.view.layer.addSublayer(bridge.displayLayer)
        XCTAssertEqual(item.outputs.count, 1)
        XCTAssertTrue(resource.isBorrowed); XCTAssertTrue(resource.isAttached); XCTAssertFalse(resource.isRetired)

        // Establish actual native readiness and an actually enqueued/display-ready
        // paused CPP image before arming the intervention. No test-side hasNew or
        // copy call is used; all output pulls remain inside the real bridge.
        player.playImmediately(atRate: 1)
        let nativeReady = await waitForPresentation {
            item.status == .readyToPlay && playerLayer.isReadyForDisplay
        }
        player.pause()
        XCTAssertTrue(nativeReady)
        guard nativeReady, await seekPresentationPlayer(player, to: 0.25) else {
            XCTFail("The public fixture must complete a real paused baseline seek"); return
        }
        XCTAssertTrue(bridge.installTimeline(ticket, positionSeconds: 0.25, durationSeconds: 30, isPlaying: false))
        XCTAssertTrue(bridge.activate(ticket))
        let baselineReady = await waitForPresentation {
            bridge.updatePlayback(positionSeconds: 0.25, durationSeconds: 30, isPlaying: false)
            guard let copied = bridge.lastCopiedFramePositionSeconds,
                  let submitted = bridge.lastFramePositionSeconds else { return false }
            return bridge.debugCurrentFrameEpoch(for: ticket) != nil && bridge.displayLayer.isReadyForDisplay
                && copied <= 0.25 + 0.000_01 && submitted <= 0.25 + 0.000_01
                && abs(copied - 0.25) <= 1.0 / 24 + 0.000_01
                && abs(submitted - 0.25) <= 1.0 / 24 + 0.000_01
        }
        XCTAssertTrue(baselineReady)
        guard baselineReady else { XCTFail("An actual displayed paused CPP baseline is required"); return }
        let baselineEpoch = try XCTUnwrap(bridge.debugCurrentFrameEpoch(for: ticket))
        let baselineSubmitted = bridge.submittedFrameCount
        XCTAssertGreaterThan(baselineSubmitted, 0)

        // Prepare a distinct real copy while CPP is inactive. Installing the
        // timeline flushes the baseline image; activation below is the only pull.
        bridge.flushForSeek()
        guard await seekPresentationPlayer(player, to: 0.5) else {
            XCTFail("The distinct pre-intervention native seek must finish"); return
        }
        XCTAssertTrue(bridge.installTimeline(ticket, positionSeconds: 0.5, durationSeconds: 30, isPlaying: false))
        XCTAssertNil(bridge.debugCurrentFrameEpoch(for: ticket))
        let beforeActivation = bridge.debugAlignedPollState
        let originalSeek = bridge.debugNativeSeekState
        XCTAssertEqual(beforeActivation.ticket, ticket); XCTAssertEqual(beforeActivation.output, outputID)
        XCTAssertGreaterThan(beforeActivation.imageEpoch, baselineEpoch)
        XCTAssertNil(originalSeek.activeTicket)
        XCTAssertEqual(bridge.submittedFrameCount, baselineSubmitted)

        var copiedCallbacks = 0, callbackOverflow = false
        var copiedObserved = false, copiedQualified = false
        var copiedStamp: ContinuousPictureInPicture.DebugRenderStamp?
        var copyState: ContinuousPictureInPicture.DebugAlignedPollState?
        var heldState: ContinuousPictureInPicture.DebugAlignedPollState?
        var creditClearedAtBegin = false, nativeSeekIssued = false
        var enqueuedWhileHeld = 0
        let nativeCompletion = PresentationSeekCompletion()
        bridge.onDebugRenderStamp = { [weak bridge, weak player] stamp in
            guard let bridge, let player else { return }
            if stamp.stage == .enqueued {
                if let heldSeek, bridge.debugNativeSeekState.activeTicket == heldSeek {
                    if enqueuedWhileHeld == 0 { enqueuedWhileHeld = 1 }
                    else { callbackOverflow = true }
                }
                return
            }
            guard stamp.stage == .copied else { return }
            guard copiedCallbacks == 0 else { callbackOverflow = true; return }
            copiedCallbacks = 1; copiedObserved = true; copiedStamp = stamp
            let state = bridge.debugAlignedPollState
            copyState = state
            guard let requested = stamp.requestedSeconds, let sample = stamp.sampleSeconds,
                  let copied = stamp.copiedPTS else { return }
            copiedQualified = stamp.ticket == ticket && stamp.ownershipUnchanged && stamp.region == 0
                && stamp.nativeSeekTicket == nil && stamp.resourceOwnership == 2
                && state.ticket == ticket && ticket.debugItemIdentity == itemID && state.output == outputID
                && state.coherent && state.activeSeekTicket == nil && state.seekSerial == originalSeek.serial
                && state.imageEpoch == beforeActivation.imageEpoch
                && resource.item === item && resource.output === output
                && resource.isAttached && resource.isBorrowed && !resource.isRetired
                && requested.isFinite && abs(requested - 0.5) < 0.000_01
                && sample.isFinite && copied.isFinite && abs(copied - sample) < 0.000_01
                && sample <= requested + 0.000_01 && abs(sample - requested) <= 1.0 / 24 + 0.000_01
                && stamp.submittedPTS == nil && stamp.submittedCount == baselineSubmitted
                && bridge.submittedFrameCount == baselineSubmitted
            guard copiedQualified else { return }
            // This event follows a successful real copy and precedes enqueue.
            // It is NOT reentry inside the SDK copy call. Only cached app fields
            // above/below are read; this is the one intentional native seek command.
            let seek = bridge.beginSeek()
            heldSeek = seek
            heldState = bridge.debugAlignedPollState
            creditClearedAtBegin = bridge.debugCurrentFrameEpoch(for: ticket) == nil
            nativeSeekIssued = true
            player.seek(to: CMTime(seconds: 0.75, preferredTimescale: 24),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak nativeCompletion] finished in
                Task { @MainActor [weak nativeCompletion] in nativeCompletion?.result = finished }
            }
            // Deliberately withhold CPP completeSeek even when native completes.
        }
        XCTAssertTrue(bridge.activate(ticket))
        let intercepted = await waitForPresentation {
            if copiedObserved { return true } // Never start a second pull after interception.
            bridge.updatePlayback(positionSeconds: 0.5, durationSeconds: 30, isPlaying: false)
            return copiedObserved
        }
        let after = bridge.debugAlignedPollState
        let currentCredit = bridge.debugCurrentFrameEpoch(for: ticket)
        let afterSubmitted = bridge.submittedFrameCount, afterFrame = bridge.lastFramePositionSeconds
        let requestedLabel = copiedStamp.flatMap { $0.requestedSeconds }.map { String($0) } ?? "unavailable"
        let copiedLabel = copiedStamp.flatMap { $0.sampleSeconds }.map { String($0) } ?? "unavailable"
        print("CPPAfterCopySeekBoundary schema=1 copiedObserved=\(copiedObserved) copiedQualified=\(copiedQualified) copiedCallbacks=\(copiedCallbacks) callbackOverflow=\(callbackOverflow) ticketMatches=\(copyState?.ticket == ticket && heldState?.ticket == ticket && after.ticket == ticket) outputMatches=\(copyState?.output == outputID && heldState?.output == outputID && after.output == outputID) entryEpoch=\(copyState.map { String($0.imageEpoch) } ?? "unavailable") heldEpoch=\(heldState.map { String($0.imageEpoch) } ?? "unavailable") afterEpoch=\(after.imageEpoch) heldSeek=\(heldSeek.map { String($0) } ?? "unavailable") heldActive=\(heldState?.activeSeekTicket == heldSeek && heldSeek != nil) afterActive=\(after.activeSeekTicket == heldSeek && heldSeek != nil) creditClearedAtBegin=\(creditClearedAtBegin) currentCreditPresent=\(currentCredit != nil) nativeSeekIssued=\(nativeSeekIssued) enqueuedWhileHeld=\(enqueuedWhileHeld) submittedBefore=\(baselineSubmitted) submittedAfter=\(afterSubmitted) submittedPTSPresent=\(afterFrame != nil) requested=\(requestedLabel) copied=\(copiedLabel) testDirectOutputQueries=0 testDirectCopies=0 scope=after-real-copy-before-enqueue latencyAcceptance=false physicalPixels=unmeasured")
        XCTAssertTrue(intercepted); XCTAssertTrue(copiedObserved); XCTAssertTrue(copiedQualified)
        XCTAssertEqual(copiedCallbacks, 1); XCTAssertFalse(callbackOverflow)
        guard intercepted, copiedQualified, let heldSeek, let copiedState = copyState,
              let heldState = heldState else {
            XCTFail("The first actual copied event must qualify the exact original owner"); return
        }
        XCTAssertEqual(copiedState.ticket, ticket); XCTAssertEqual(copiedState.output, outputID)
        XCTAssertTrue(copiedState.coherent); XCTAssertNil(copiedState.activeSeekTicket)
        XCTAssertEqual(heldState.ticket, ticket); XCTAssertEqual(heldState.output, outputID)
        XCTAssertEqual(heldState.activeSeekTicket, heldSeek); XCTAssertEqual(heldState.seekSerial, heldSeek)
        XCTAssertGreaterThan(heldState.imageEpoch, copiedState.imageEpoch)
        XCTAssertEqual(after.ticket, ticket); XCTAssertEqual(after.output, outputID)
        XCTAssertEqual(after.activeSeekTicket, heldSeek); XCTAssertEqual(after.seekSerial, heldSeek)
        XCTAssertTrue(nativeSeekIssued); XCTAssertTrue(creditClearedAtBegin)
        // RED: the copy belongs to the pre-seek epoch. A matching item/ticket
        // alone must not let the interrupted render publish into this new epoch.
        XCTAssertEqual(enqueuedWhileHeld, 0, "A copied pre-seek image must not reach enqueue while its seek is active")
        XCTAssertEqual(afterSubmitted, baselineSubmitted)
        XCTAssertNil(afterFrame)
        XCTAssertNil(currentCredit, "A late epoch snapshot must not credit a copied pre-seek image to the new epoch")

        // Positive recovery is deliberately retained after the RED assertions.
        bridge.onDebugRenderStamp = nil
        let nativeFinished = await waitForPresentation { nativeCompletion.result != nil }
        XCTAssertTrue(nativeFinished); XCTAssertEqual(nativeCompletion.result, true)
        guard nativeFinished, nativeCompletion.result == true else {
            XCTFail("The real same-item 0.75 seek must complete before releasing CPP"); return
        }
        let beforeRecovery = bridge.submittedFrameCount
        XCTAssertTrue(bridge.installTimeline(ticket, positionSeconds: 0.75, durationSeconds: 30, isPlaying: false))
        bridge.completeSeek(heldSeek)
        XCTAssertTrue(bridge.activate(ticket))
        let recovered = await waitForPresentation {
            bridge.updatePlayback(positionSeconds: 0.75, durationSeconds: 30, isPlaying: false)
            guard let copied = bridge.lastCopiedFramePositionSeconds,
                  let submitted = bridge.lastFramePositionSeconds else { return false }
            return bridge.submittedFrameCount > beforeRecovery && bridge.debugCurrentFrameEpoch(for: ticket) != nil
                && bridge.displayLayer.isReadyForDisplay && copied <= 0.75 + 0.000_01 && submitted <= 0.75 + 0.000_01
                && abs(copied - 0.75) <= 1.0 / 24 + 0.000_01
                && abs(submitted - 0.75) <= 1.0 / 24 + 0.000_01
        }
        XCTAssertTrue(recovered, "Matching completion must still submit a real paused target in the current epoch")
        XCTAssertTrue(resource.item === item); XCTAssertTrue(resource.output === output)
        XCTAssertTrue(resource.isAttached); XCTAssertTrue(resource.isBorrowed); XCTAssertFalse(resource.isRetired)
        XCTAssertEqual(item.outputs.count, 1)
        #else
        XCTFail("After-copy seek contracts require existing DEBUG render stamps")
        #endif
    }

    private func waitForPresentation(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return condition()
    }

    @MainActor
    private final class PresentationSeekCompletion { var result: Bool? }

    private func seekPresentationPlayer(_ player: AVPlayer, to seconds: Double) async -> Bool {
        let completion = PresentationSeekCompletion()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 24), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in completion.result = finished }
        }
        let returned = await waitForPresentation { completion.result != nil }
        return returned && completion.result == true
    }

    private func makeAsymmetricVideo(transform: CGAffineTransform, frameCount: Int = 2,
        presentationTimes: [CMTime]? = nil, endTime: CMTime? = nil) async throws -> URL {
        if let presentationTimes {
            guard frameCount >= 3, frameCount <= 8, presentationTimes.count == frameCount,
                  let endTime, endTime.isNumeric, endTime.epoch == 0,
                  presentationTimes.allSatisfy({ $0.isNumeric && $0.epoch == 0 }),
                  CMTimeCompare(presentationTimes[0], .zero) >= 0,
                  CMTimeCompare(endTime, presentationTimes[frameCount - 1]) > 0 else {
                throw NSError(domain: "TimedAsymmetricFixture", code: -1)
            }
            for index in 1..<frameCount {
                guard CMTimeCompare(presentationTimes[index], presentationTimes[index - 1]) > 0 else {
                    throw NSError(domain: "TimedAsymmetricFixture", code: -2)
                }
            }
        } else if endTime != nil { throw NSError(domain: "TimedAsymmetricFixture", code: -3) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var completed = false
        defer {
            if !completed {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
            }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 16
        ])
        input.transform = transform
        if presentationTimes != nil { input.mediaTimeScale = 600 }
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 16,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: AVFoundationErrorDomain, code: -3) }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, kCVPixelFormatType_32BGRA,
                                           attributes as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<16 {
            for x in 0..<32 {
                let offset = y * rowBytes + x * 4
                bytes[offset] = x < 16 ? 0 : 255
                bytes[offset + 1] = 0
                bytes[offset + 2] = x < 16 ? 255 : 0
                bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for index in 0..<frameCount {
            var attempts = 0
            while !input.isReadyForMoreMediaData && attempts < 200 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            let frameBuffer: CVPixelBuffer
            if presentationTimes != nil {
                // Separate real buffers prevent the encoder observing later mutations.
                var generated: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, kCVPixelFormatType_32BGRA,
                    attributes as CFDictionary, &generated) == kCVReturnSuccess, let generated else {
                    throw NSError(domain: "TimedAsymmetricFixture", code: -4)
                }
                frameBuffer = generated
                guard CVPixelBufferLockBaseAddress(frameBuffer, []) == kCVReturnSuccess else {
                    throw NSError(domain: "TimedAsymmetricFixture", code: -5)
                }
                defer { CVPixelBufferUnlockBaseAddress(frameBuffer, []) }
                let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(frameBuffer)).assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(frameBuffer)
                for row in 0..<16 {
                    for column in 0..<32 {
                        let offset = row * stride + column * 4
                        pixels[offset] = column < 16 ? UInt8(index * 16) : 255
                        pixels[offset + 1] = UInt8(index * 24)
                        pixels[offset + 2] = column < 16 ? 255 : UInt8(index * 8)
                        pixels[offset + 3] = 255
                    }
                }
            } else { frameBuffer = buffer }
            if let presentationTimes {
                XCTAssertTrue(adaptor.append(frameBuffer, withPresentationTime: presentationTimes[index]))
            } else {
                XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
            }
        }
        if let endTime { writer.endSession(atSourceTime: endTime) }
        else { writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 24)) }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: AVFoundationErrorDomain, code: -4) }
        completed = true
        return url
    }

    private func isBlue(_ pixel: CVPixelBuffer, x: Int, y: Int) -> Bool {
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { XCTFail("Missing decoded pixels"); return false }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
        return Int(bytes[offset]) > Int(bytes[offset + 2]) + 80
    }
}
