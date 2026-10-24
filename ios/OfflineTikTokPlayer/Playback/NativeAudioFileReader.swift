import Foundation
import AVFoundation
import AudioToolbox

/// Implementations and their SDK objects stay on their owning native-reader lane.
protocol NativePCMReading: AnyObject {
    var totalFrames: Int64 { get }
    var reachedEnd: Bool { get }
    func read(into destination: AVAudioPCMBuffer, maximumFrames: Int) throws -> Int
}

/// Restricted to a complete, unedited native 48 kHz stereo AAC presentation.
/// The caller validates the asset's mapping against the codec packet table.
final class NativeAudioFileReader: NativePCMReading {
    enum Failure: Error { case invalidFormat, invalidPosition, emptyRead }
    private let file: AVAudioFile
    let totalFrames: Int64
    var reachedEnd: Bool { file.framePosition == totalFrames }

    #if DEBUG
    var beforeRead: (() -> Void)?
    var afterRead: (() -> Void)?
    #endif

    static func open(url: URL, totalFrames: Int64, readStartFrame: Int64,
                     matchesPacketTable: (Int64, Int64) -> Bool) -> NativeAudioFileReader? {
        guard url.isFileURL, totalFrames > 0, readStartFrame >= 0, readStartFrame <= totalFrames else { return nil }
        var identifier: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &identifier) == noErr,
              let identifier else { return nil }
        defer { AudioFileClose(identifier) }
        var table = AudioFilePacketTableInfo()
        var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        guard AudioFileGetProperty(identifier, kAudioFilePropertyPacketTableInfo, &size, &table) == noErr,
              size == UInt32(MemoryLayout<AudioFilePacketTableInfo>.size),
              table.mPrimingFrames >= 0, table.mRemainderFrames >= 0,
              table.mNumberValidFrames == totalFrames,
              matchesPacketTable(Int64(table.mPrimingFrames), table.mNumberValidFrames),
              let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true),
              file.length == totalFrames,
              file.fileFormat.sampleRate == 48_000, file.fileFormat.channelCount == 2,
              file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              let expected = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                  channels: 2, interleaved: true),
              file.processingFormat.isEqual(expected) else { return nil }
        file.framePosition = readStartFrame
        guard file.framePosition == readStartFrame else { return nil }
        return NativeAudioFileReader(file: file, totalFrames: totalFrames)
    }

    private init(file: AVAudioFile, totalFrames: Int64) {
        self.file = file
        self.totalFrames = totalFrames
    }

    func read(into destination: AVAudioPCMBuffer, maximumFrames: Int) throws -> Int {
        let before = file.framePosition
        guard before >= 0, before <= totalFrames else { throw Failure.invalidPosition }
        destination.frameLength = 0
        if before == totalFrames { return 0 }
        guard destination.format.isEqual(file.processingFormat) else { throw Failure.invalidFormat }
        let count = min(4_096, maximumFrames, Int(destination.frameCapacity), Int(totalFrames - before))
        guard count > 0 else { throw Failure.emptyRead }
        #if DEBUG
        beforeRead?()
        defer { afterRead?() }
        #endif
        try file.read(into: destination, frameCount: AVAudioFrameCount(count))
        let returned = Int(destination.frameLength)
        guard returned > 0, returned <= count else { throw Failure.emptyRead }
        guard file.framePosition == before + Int64(returned) else { throw Failure.invalidPosition }
        return returned
    }
}
