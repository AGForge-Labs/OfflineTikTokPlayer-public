import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// A queue-level frame source for the active streaming item. The native player
/// continues playing its audio and owns the timestamps delivered by this output.
@MainActor
final class StreamingVideoFrames {
    private weak var player: AVPlayer?
    private let output: AVPlayerVideoOutput

    init(player: AVPlayer) {
        self.player = player
        let specification = AVVideoOutputSpecification(tagCollections: [.monoscopicForVideoOutput()])
        // Leave size, pixel format, transfer function and color space up to AVFoundation.
        output = AVPlayerVideoOutput(specification: specification)
        if player.videoOutput == nil { player.videoOutput = output }
    }

    func frame(for item: AVPlayerItem, atHostTime hostTime: CFTimeInterval) -> (pixel: CVPixelBuffer, position: CMTime)? {
        guard hostTime.isFinite, hostTime >= 0, let player, player.currentItem === item,
              player.videoOutput === output else { return nil }
        let time = CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000)
        // This API vends the original Core Video reference needed by the existing
        // sample-buffer renderer, alongside the native item's actual display time.
        guard time.isNumeric, let sample = output.taggedBuffers(forHostTime: time),
              sample.activeConfiguration.sourcePlayerItem === item,
              sample.activeConfiguration.preferredTransform == .identity,
              sample.presentationTime.isNumeric && sample.presentationTime.seconds >= 0,
              sample.taggedBufferGroup.count == 1, let image = sample.taggedBufferGroup.first else { return nil }
        let mediaType = image.tags.firstValue(matchingCategory: .mediaType)
        let stereo = image.tags.firstValue(matchingCategory: .stereoView)
        // A monoscopic channel may label the image with just the no-stereo-view
        // tag. In either case the payload itself must also be a decoded image.
        guard mediaType == nil || mediaType == .video, stereo?.isEmpty != false,
              mediaType == .video || stereo?.isEmpty == true else { return nil }

        let pixel: CVPixelBuffer
        switch image.buffer {
        case .pixelBuffer(let decoded):
            pixel = decoded
        case .sampleBuffer(let decoded):
            guard CMSampleBufferIsValid(decoded), CMSampleBufferDataIsReady(decoded),
                  CMSampleBufferGetNumSamples(decoded) == 1,
                  let decodedImage = CMSampleBufferGetImageBuffer(decoded) else { return nil }
            pixel = decodedImage
        @unknown default:
            return nil
        }
        guard player.currentItem === item, player.videoOutput === output else { return nil }
        return (pixel, sample.presentationTime)
    }

    func cancel() {
        if let player, player.videoOutput === output { player.videoOutput = nil }
        player = nil
    }
}
