import XCTest
import SwiftUI
import UIKit
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import PlayerCore
@testable import OfflineTikTokPlayer

/// Service/render integration regressions. The opaque magenta poster deliberately differs from
/// both generated movies, so a decoded asset or advancing audio clock cannot satisfy visibility.
@MainActor
final class PlaybackSelectionVideoRegressionTests: XCTestCase {
    func testRestoredOffsetRevealsTheSelectedPausedFrame() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        try JSONEncoder().encode(PlaybackBookmark(
            queue: PlaybackQueue(ids: fixture.ids, startAt: fixture.bID), position: 0.4))
            .write(to: fixture.bookmark)
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }

        service.restore()
        try await require({ !service.isLoading && abs(service.player.currentTime().seconds - 0.4) < 0.04 },
                          "The real Saved B item must finish restoring to 0.4 seconds")
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertVisibleFrame(service, screen: screen, identity: .b, label: "restored-B-at-0.4")
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.player.rate, 0)

        service.play()
        try await require({ service.audioSnapshot.token != 0 && service.audioSnapshot.frame > 2_400 },
                          "Restored B must enter the actual audio renderer after explicit Play")
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "restored-B-playing")
    }

    func testPreparedRewoundBUncoversItsOwnMovingVideo() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let buffer = PlaybackBuffer()
        let service = fixture.service(buffer: buffer)
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.bID)
        try await require({ service.audioSnapshot.frame > 2_400 && service.preparedAudioCount == 2 },
                          "Both generated Saved sources must be prepared")
        let bToken = service.audioSnapshot.token
        let preparedB = try XCTUnwrap(service.player.currentItem)

        service.previous()
        try await require({ service.queue.currentID == fixture.aID && service.audioSnapshot.token != bToken
            && service.audioSnapshot.frame > 2_400 }, "A must be the real rendered source before selecting B again")
        let seeked = await withCheckedContinuation { continuation in
            preparedB.seek(to: CMTime(seconds: 0.75, preferredTimescale: 48_000),
                           toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(seeked)
        // Force the real prepared-item branch with an unfinished rewind, rather than depending
        // on whether background previous-item seeking happened to win a simulator race.
        buffer.discardNext()
        buffer.discardPrevious()
        buffer.stagePrevious(.init(mediaID: fixture.bID, item: preparedB, isLocal: true, needsRewind: true))
        service.next()
        try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token == bToken
            && service.audioSnapshot.frame > 2_400 }, "Prepared B must replace A in the audio renderer")
        XCTAssertTrue(service.player.currentItem === preparedB, "The test must exercise the rewound prepared object")
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "rewound-prepared-B")
    }

    func testPreparedABAChangesActualAssetAudioTokenAndCompositePixels() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await require({ service.audioSnapshot.frame > 2_400 && service.preparedAudioCount == 2 },
                          "A and B must both be prepared before the reversal")
        let aToken = service.audioSnapshot.token
        XCTAssertNotEqual(aToken, 0)
        assertSelection(service, fixture: fixture, id: fixture.aID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "initial-A")

        service.next()
        try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token != aToken
            && service.audioSnapshot.token != 0 && service.audioSnapshot.frame > 2_400 },
                          "Selecting B must change the actual render token")
        let bToken = service.audioSnapshot.token
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "selected-B")

        service.previous()
        try await require({ service.queue.currentID == fixture.aID && service.audioSnapshot.token == aToken
            && service.audioSnapshot.frame > 2_400 }, "Previous must return to the prepared A source")
        XCTAssertNotEqual(service.audioSnapshot.token, bToken)
        assertSelection(service, fixture: fixture, id: fixture.aID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .a, label: "returned-A")
    }

    func testNaturalBoundaryAtPositiveIncomingOffsetRevealsB() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
        service.start(playlistIDs: [fixture.playlist], at: fixture.aID)
        try await require({ service.audioSnapshot.frame > 2_400 && service.preparedAudioCount == 2 },
                          "Both complete Saved sources must be ready")
        let aToken = service.audioSnapshot.token
        service.seek(SelectionVideoFixture.duration - 0.5)
        try await require({ service.audioSnapshot.token == aToken
            && service.audioSnapshot.frame > Int64((SelectionVideoFixture.duration - 0.25) * 48_000) },
                          "A must approach its natural boundary without an explicit Next")
        // The audio thread continues through the boundary while the main actor is briefly busy.
        // This deterministically exercises an arriving frame offset greater than zero.
        stallMainActorForBoundary()
        try await require({ service.queue.currentID == fixture.bID && service.audioSnapshot.token != aToken
            && service.clock.position > 0 }, "The service must adopt naturally rendered B at a positive offset")
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "natural-B-positive-offset")
    }

    func testAudioOnlyAndForegroundRestoreSelectedBWithoutOverridingPause() async throws {
        let fixture = try await SelectionVideoFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let screen = try SelectionVideoScreen(service: service)
        defer { service.pause(); screen.close() }
        service.isInteractingWithFeed = true
        service.start(playlistIDs: [fixture.playlist], at: fixture.bID)
        try await require({ service.audioSnapshot.frame > 2_400 }, "B must be rendered before hiding video")
        let bToken = service.audioSnapshot.token
        await assertMovingVisibleVideo(service, screen: screen, identity: .b, label: "B-before-audio-only")
        service.audioOnly = true
        XCTAssertTrue(service.surface.isHidden)
        let before = service.audioSnapshot.frame
        try await require({ service.audioSnapshot.frame > before + 2_400 }, "Audio only must leave B audio advancing")
        service.pause()
        try await require({ !service.audioEngineRunning }, "Explicit Pause must stop the actual audio engine")
        let pausedFrame = service.audioSnapshot.frame
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        service.enteredForeground()
        service.audioOnly = false
        assertSelection(service, fixture: fixture, id: fixture.bID)
        await assertVisibleFrame(service, screen: screen, identity: .b, label: "paused-B-restored-inline")
        XCTAssertFalse(service.surface.isHidden)
        XCTAssertFalse(service.wantsToPlay)
        XCTAssertEqual(service.audioSnapshot.token, bToken)
        XCTAssertEqual(service.audioSnapshot.frame, pausedFrame)
        XCTAssertEqual(service.player.rate, 0)
    }

    private func stallMainActorForBoundary() { Thread.sleep(forTimeInterval: 0.4) }

    private func assertSelection(_ service: PlaybackService, fixture: SelectionVideoFixture, id: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(service.queue.currentID, id, file: file, line: line)
        XCTAssertEqual(service.current?.id, id, file: file, line: line)
        let asset = service.player.currentItem?.asset as? AVURLAsset
        XCTAssertEqual(asset?.url.standardizedFileURL, fixture.savedURLs[id]?.standardizedFileURL,
                       "The selected metadata must identify the actual AVPlayerItem asset", file: file, line: line)
        XCTAssertTrue(service.surface.playerLayer.player === service.player, file: file, line: line)
    }

    private func assertVisibleFrame(_ service: PlaybackService, screen: SelectionVideoScreen,
                                    identity: SelectionVideoIdentity, label: String,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        let ready = await waitUntil {
            service.isVideoReady && (service.surface.playerLayer.isReadyForDisplay
                || screen.customVideoLayer?.isReadyForDisplay == true)
        }
        XCTAssertTrue(ready, "The selected real video must become ready; an audio clock is insufficient", file: file, line: line)
        do {
            let pixels = try screen.capture(label: label, test: self)
            XCTAssertGreaterThan(pixels.fraction(identity), 0.65,
                                 "The whole composite must show \(identity), not the opaque poster or another source", file: file, line: line)
            XCTAssertLessThan(pixels.magentaFraction, 0.02,
                              "The real readiness path must uncover video instead of leaving the poster opaque", file: file, line: line)
        } catch { XCTFail("Composite capture failed: \(error)", file: file, line: line) }
    }

    private func assertMovingVisibleVideo(_ service: PlaybackService, screen: SelectionVideoScreen,
                                          identity: SelectionVideoIdentity, label: String,
                                          file: StaticString = #filePath, line: UInt = #line) async {
        await assertVisibleFrame(service, screen: screen, identity: identity, label: label + "-first", file: file, line: line)
        do {
            let first = try screen.capture(label: label + "-motion-start", test: self)
            let firstTime = service.player.currentTime().seconds
            let advanced = await waitUntil(timeout: 1) { service.player.currentTime().seconds > firstTime + 0.18 }
            XCTAssertTrue(advanced, "The selected AVPlayerItem clock must actually advance", file: file, line: line)
            let second = try screen.capture(label: label + "-motion-end", test: self)
            XCTAssertGreaterThan(second.fraction(identity), 0.65, file: file, line: line)
            let firstBar = try XCTUnwrap(first.blueBarCenter, "The first composite must contain its decoded blue marker", file: file, line: line)
            let secondBar = try XCTUnwrap(second.blueBarCenter, "The second composite must contain its decoded blue marker", file: file, line: line)
            XCTAssertGreaterThan(abs(secondBar - firstBar), 3,
                                 "Advancing clocks must produce different visible video frames", file: file, line: line)
        } catch { XCTFail("Moving-frame proof failed: \(error)", file: file, line: line) }
    }

    private func require(_ condition: () -> Bool, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        guard await waitUntil(condition) else {
            XCTFail(message, file: file, line: line)
            throw SelectionVideoTestFailure.timeout
        }
    }

    private func waitUntil(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return condition()
    }
}

enum SelectionVideoIdentity: String { case a, b }
private enum SelectionVideoTestFailure: Error { case timeout, writer, sample, capture }

@MainActor
final class SelectionVideoFixture {
    static let duration = 6.0
    let temporary: URL
    let cloud: OneDriveClient
    let downloads: OfflineDownloads
    let library: LibraryRepository
    let ids: [String]
    let playlist = "local:selected-video-regression-" + UUID().uuidString
    var aID: String { ids[0] }
    var bID: String { ids[1] }
    var bookmark: URL { temporary.appendingPathComponent("playback.json") }
    private(set) var savedURLs: [String: URL] = [:]
    private let previousSpeakerSound = UserDefaults.standard.object(forKey: "speakerSound")
    private let previousAutomaticPiP = UserDefaults.standard.object(forKey: "automaticPiP")

    init() async throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        cloud = OneDriveClient(account: MicrosoftAccount())
        downloads = OfflineDownloads(cloud: cloud, network: NetworkStatus())
        library = LibraryRepository(cloud: cloud, catalogURL: temporary.appendingPathComponent("catalog.json"))
        ids = ["local:selected-A-" + UUID().uuidString, "local:selected-B-" + UUID().uuidString]
        do {
            for (index, identity) in [SelectionVideoIdentity.a, .b].enumerated() {
                let source = temporary.appendingPathComponent(identity.rawValue).appendingPathExtension("mp4")
                try await Self.writeMovie(to: source, identity: identity)
                _ = try await downloads.importLocal(source, mediaID: ids[index])
            }
            let records = ids.map { MediaRecord(id: $0, title: "Generated selection fixture", creator: "Test", duration: Self.duration) }
            try library.install(LibraryCatalog(libraryID: "local:selection-regression", media: records,
                                               playlists: [PlaylistRecord(id: playlist, name: "Generated", itemIDs: ids)]))
            for record in records {
                let saved = await downloads.localURL(for: record)
                savedURLs[record.id] = try XCTUnwrap(saved)
            }
        } catch { remove(); throw error }
    }

    func service(buffer: PlaybackBuffer? = nil) -> PlaybackService {
        let result = PlaybackService(library: library, downloads: downloads, cloud: cloud,
                                     bookmarkURL: bookmark, activateSession: {}, buffer: buffer)
        result.speakerSound = false
        result.automaticPiP = false
        return result
    }

    func remove() {
        for id in ids { downloads.remove(id) }
        try? FileManager.default.removeItem(at: temporary)
        if let previousSpeakerSound { UserDefaults.standard.set(previousSpeakerSound, forKey: "speakerSound") }
        else { UserDefaults.standard.removeObject(forKey: "speakerSound") }
        if let previousAutomaticPiP { UserDefaults.standard.set(previousAutomaticPiP, forKey: "automaticPiP") }
        else { UserDefaults.standard.removeObject(forKey: "automaticPiP") }
    }

    private static func writeMovie(to url: URL, identity: SelectionVideoIdentity) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var finished = false
        defer { if !finished { writer.cancelWriting(); try? FileManager.default.removeItem(at: url) } }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 200_000, AVVideoMaxKeyFrameIntervalKey: 24]
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ])
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(video), writer.canAdd(audio) else { throw SelectionVideoTestFailure.writer }
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? SelectionVideoTestFailure.writer }
        writer.startSession(atSourceTime: .zero)
        let audioDescription = try makeAudioDescription()
        for frame in 0..<144 {
            try await ready(video, writer: writer)
            let pixel = try makePixel(frame: frame, identity: identity, attributes: attributes)
            guard pixels.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else {
                throw writer.error ?? SelectionVideoTestFailure.writer
            }
            try await ready(audio, writer: writer)
            let sample = try makeAudioChunk(start: frame * 2_000, description: audioDescription,
                                            frequency: identity == .a ? 440 : 880)
            guard audio.append(sample) else { throw writer.error ?? SelectionVideoTestFailure.writer }
        }
        writer.endSession(atSourceTime: CMTime(value: 6, timescale: 1))
        video.markAsFinished(); audio.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? SelectionVideoTestFailure.writer }
        finished = true
    }

    private static func ready(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                throw writer.error ?? SelectionVideoTestFailure.timeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func makePixel(frame: Int, identity: SelectionVideoIdentity,
                                  attributes: [String: Any]) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 96, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &pixel) == kCVReturnSuccess,
              let pixel else { throw SelectionVideoTestFailure.sample }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { throw SelectionVideoTestFailure.sample }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixel)
        let marker = ((frame / 3) * 11) % 144
        for y in 0..<96 {
            for x in 0..<160 {
                let offset = y * row + x * 4
                let blue = x >= marker && x < marker + 16
                bytes[offset] = blue ? 240 : 24
                bytes[offset + 1] = !blue && identity == .b ? 240 : 24
                bytes[offset + 2] = !blue && identity == .a ? 240 : 24
                bytes[offset + 3] = 255
            }
        }
        return pixel
    }

    private static func makeAudioDescription() throws -> CMAudioFormatDescription {
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr, let description else { throw SelectionVideoTestFailure.sample }
        return description
    }

    private static func makeAudioChunk(start: Int, description: CMAudioFormatDescription,
                                       frequency: Double) throws -> CMSampleBuffer {
        var samples = [Float](repeating: 0, count: 4_000)
        for frame in 0..<2_000 {
            let value = Float(0.2 * sin(2 * .pi * frequency * Double(start + frame) / 48_000))
            samples[frame * 2] = value; samples[frame * 2 + 1] = value
        }
        var block: CMBlockBuffer?
        let bytes = samples.count * MemoryLayout<Float>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { throw SelectionVideoTestFailure.sample }
        let copied = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == kCMBlockBufferNoErr else { throw SelectionVideoTestFailure.sample }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: description, sampleCount: 2_000,
            presentationTimeStamp: CMTime(value: Int64(start), timescale: 48_000), packetDescriptions: nil,
            sampleBufferOut: &sample) == noErr, let sample else { throw SelectionVideoTestFailure.sample }
        return sample
    }
}

@MainActor
private final class SelectionVideoScreen {
    let window: UIWindow
    let service: PlaybackService
    private weak var previousKeyWindow: UIWindow?
    var customVideoLayer: AVSampleBufferDisplayLayer? {
        service.surface.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.last
    }

    init(service: PlaybackService) throws {
        self.service = service
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: SelectionVideoHarness(service: service))
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    func capture(label: String, test: XCTestCase) throws -> SelectionVideoPixels {
        window.rootViewController?.view.layoutIfNeeded()
        CATransaction.flush()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var drewHierarchy = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard drewHierarchy else { throw SelectionVideoTestFailure.capture }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Selected-video-composite-" + label
        attachment.lifetime = .keepAlways
        test.add(attachment)
        // This is the complete onscreen hierarchy cropped to the real surface, never an
        // AVAssetImageGenerator image substituted underneath the opaque poster.
        let rect = service.surface.convert(service.surface.bounds, to: window).integral
        guard rect.width > 0, rect.height > 0,
              let cropped = image.cgImage?.cropping(to: rect) else { throw SelectionVideoTestFailure.capture }
        return try SelectionVideoPixels(cropped)
    }
}

private struct SelectionVideoHarness: View {
    let service: PlaybackService
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FeedVideoSurface(surface: service.surface, isActive: true, isReady: service.isVideoReady) {
                Color(red: 1, green: 0, blue: 1)
            }.frame(width: 320, height: 192)
        }
    }
}

private struct SelectionVideoPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    init(_ image: CGImage) throws {
        width = image.width; height = image.height
        var storage = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = storage.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw SelectionVideoTestFailure.capture }
        bytes = storage
    }

    func fraction(_ identity: SelectionVideoIdentity) -> Double {
        fraction { r, g, b in identity == .a ? r > 150 && g < 100 && b < 100 : g > 150 && r < 100 && b < 100 }
    }
    var magentaFraction: Double { fraction { $0 > 150 && $1 < 100 && $2 > 150 } }
    var blueBarCenter: Double? {
        var sum = 0.0, count = 0
        let y = height / 2
        for x in 0..<width {
            let offset = (y * width + x) * 4
            if bytes[offset + 2] > 150 && bytes[offset] < 100 && bytes[offset + 1] < 100 {
                sum += Double(x); count += 1
            }
        }
        return count >= 4 ? sum / Double(count) : nil
    }
    private func fraction(_ predicate: (UInt8, UInt8, UInt8) -> Bool) -> Double {
        var count = 0
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            if predicate(bytes[offset], bytes[offset + 1], bytes[offset + 2]) { count += 1 }
        }
        return Double(count) / Double(max(1, width * height))
    }
}
