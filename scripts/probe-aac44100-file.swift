// Standalone macOS API experiment, never iOS playback or release acceptance.
import Foundation
import AVFoundation
import AudioToolbox
import Darwin

@main
struct AudioFileCapabilityProbe {
    static func report(_ row: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print("AudioFileProbe " + String(decoding: data, as: UTF8.self))
    }

    static func packetTable(url: URL) -> [String: Any] {
        var identifier: AudioFileID?
        let opened = AudioFileOpenURL(url as CFURL, .readPermission, 0, &identifier)
        guard opened == noErr, let identifier else { return ["openStatus": opened] }
        defer { AudioFileClose(identifier) }
        var table = AudioFilePacketTableInfo()
        var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        let status = AudioFileGetProperty(identifier, kAudioFilePropertyPacketTableInfo, &size, &table)
        return ["openStatus": opened, "packetTableStatus": status,
            "validFrames": table.mNumberValidFrames, "primingFrames": table.mPrimingFrames,
            "remainderFrames": table.mRemainderFrames, "tableBytes": size]
    }


    static func nativeLayout(url: URL) async throws -> AudioFilePresentation {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1, let track = tracks.first else { throw NSError(domain: "ProbeLayoutTrack", code: 1) }
        let segments = try await track.load(.segments)
        guard segments.count == 1, let segment = segments.first, !segment.isEmpty else {
            throw NSError(domain: "ProbeLayoutSegment", code: 1)
        }
        func exact(_ time: CMTime) throws -> Int64 {
            let native = CMTimeConvertScale(time, timescale: 44_100, method: .roundHalfAwayFromZero)
            guard time.isNumeric, CMTimeCompare(time, .zero) >= 0, native.isNumeric, CMTimeCompare(time, native) == 0 else {
                throw NSError(domain: "ProbeLayoutGrid", code: 1)
            }
            return native.value
        }
        let mapping = segment.timeMapping
        return try AudioFilePresentation(sourceStart: exact(mapping.source.start), sourceFrames: exact(mapping.source.duration),
            targetStart: exact(mapping.target.start), targetFrames: exact(mapping.target.duration))
    }

    /// Independent native-only reference for this unchanged 48 kHz fixture.
    /// Reject edits/trim/layout surprises rather than trimming samples to agree.
    static func nativeReference(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard try await asset.load(.providesPreciseDurationAndTiming) else {
            throw NSError(domain: "ProbeReferenceTiming", code: 1)
        }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1, let track = tracks.first else {
            throw NSError(domain: "ProbeReferenceTrack", code: 1)
        }
        let duration = try await asset.load(.duration)
        guard CMTimeConvertScale(duration, timescale: 44_100, method: .roundHalfAwayFromZero).value == 1_323_000 else {
            throw NSError(domain: "ProbeReferenceLength", code: 1)
        }
        let segments = try await track.load(.segments)
        let mappings: [[String: Any]] = segments.map { segment in
            ["empty": segment.isEmpty, "sourceStart": segment.timeMapping.source.start.seconds,
             "sourceDuration": segment.timeMapping.source.duration.seconds,
             "targetStart": segment.timeMapping.target.start.seconds,
             "targetDuration": segment.timeMapping.target.duration.seconds]
        }
        try report(["schema": 1, "metadata": true, "fixture": url.lastPathComponent,
            "audioTracks": tracks.count, "segments": mappings, "packetTable": packetTable(url: url),
            "iOSQualification": false, "playbackAcceptance": false])
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw NSError(domain: "ProbeReferenceOutput", code: 1) }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)
        guard reader.startReading() else { throw NSError(domain: "ProbeReferenceStart", code: 1) }
        defer { reader.cancelReading() }
        var samples: [Float] = []
        samples.reserveCapacity(1_323_000 * 2)
        while true {
            let packet: [Float]? = try autoreleasepool { () throws -> [Float]? in
                guard let sample = output.copyNextSampleBuffer() else { return nil }
                guard let format = CMSampleBufferGetFormatDescription(sample),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                      asbd.pointee.mSampleRate == 44_100, asbd.pointee.mChannelsPerFrame == 2,
                      asbd.pointee.mBytesPerFrame == 8, asbd.pointee.mFormatID == kAudioFormatLinearPCM,
                      asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      let block = CMSampleBufferGetDataBuffer(sample) else {
                    throw NSError(domain: "ProbeReferenceFormat", code: 1)
                }
                let bytes = CMBlockBufferGetDataLength(block)
                let start = CMTimeConvertScale(CMSampleBufferGetOutputPresentationTimeStamp(sample),
                    timescale: 44_100, method: .roundHalfAwayFromZero).value
                guard bytes > 0, bytes <= 1_048_576, bytes % 8 == 0,
                      start == Int64(samples.count / 2), samples.count + bytes / 4 <= 1_323_000 * 2 else {
                    throw NSError(domain: "ProbeReferencePacket", code: 1)
                }
                for key in [kCMSampleBufferAttachmentKey_TrimDurationAtStart, kCMSampleBufferAttachmentKey_TrimDurationAtEnd] {
                    if let value = CMGetAttachment(sample, key: key, attachmentModeOut: nil) as? [String: Any],
                       CMTimeMakeFromDictionary(value as CFDictionary).seconds != 0 {
                        throw NSError(domain: "ProbeReferenceUnexpectedTrim", code: 1)
                    }
                }
                var owned = [Float](repeating: 0, count: bytes / 4)
                let status = owned.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw NSError(domain: "ProbeReferenceCopy", code: 1) }
                return owned
            }
            guard let packet else { break }
            samples.append(contentsOf: packet)
        }
        guard reader.status == .completed, samples.count == 1_323_000 * 2,
              samples.allSatisfy({ $0.isFinite }) else { throw NSError(domain: "ProbeReferenceComplete", code: 1) }
        return samples
    }


    static func attempt(label: String, url: URL, configured: Bool, expectedFrames: Int64,
                        exactControl: Bool, reference: [Float]? = nil) -> Bool {
        var stage = "open"
        var row: [String: Any] = ["schema": 1, "fixture": label, "platform": "macOS",
            "mode": configured ? "configured-interleaved-float32" : "default-deinterleaved",
            "completed": false, "iOSQualification": false, "fidelityCompared": exactControl || reference != nil]
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let metrics: [String: Any] = try autoreleasepool { () throws -> [String: Any] in
                let file: AVAudioFile
                if configured {
                    file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
                } else {
                    file = try AVAudioFile(forReading: url)
                }
                stage = "format"
                let format = file.processingFormat
                guard format.sampleRate == 44_100, format.channelCount == 2,
                      format.commonFormat == .pcmFormatFloat32 else {
                    throw NSError(domain: "ProbeFormat", code: 1)
                }
                stage = "buffer"
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
                    throw NSError(domain: "ProbeBuffer", code: 1)
                }
                var totalFrames: Int64 = 0, nonfinite = 0, changedControlSamples = 0
                var firstMismatch: Int?
                var maximumDifference: Float = 0
                var reads = 0, eof = false
                var peak: Float = 0
                for _ in 0..<400 {
                    if file.framePosition == file.length { eof = true; break }
                    guard file.framePosition >= 0, file.framePosition < file.length else {
                        throw NSError(domain: "ProbePosition", code: 1)
                    }
                    let requestedFrames = AVAudioFrameCount(min(4_096, file.length - file.framePosition))
                    stage = "read"
                    buffer.frameLength = 0
                    row["beforeReadPosition"] = file.framePosition
                    row["declaredFrames"] = file.length
                    row["successfullyCopiedFrames"] = totalFrames
                    row["successfulReads"] = reads
                    row["requestedFrames"] = requestedFrames
                    do {
                        try file.read(into: buffer, frameCount: requestedFrames)
                    } catch {
                        row["afterFailedReadPosition"] = file.framePosition
                        row["failedReadBufferFrames"] = buffer.frameLength
                        throw error
                    }
                    reads += 1
                    let frames = Int(buffer.frameLength)
                    guard frames > 0 else { throw NSError(domain: "ProbeUnexpectedEmptyRead", code: 1) }
                    guard totalFrames + Int64(frames) <= expectedFrames + 4_096,
                          let channels = buffer.floatChannelData else {
                        throw NSError(domain: "ProbeReadBound", code: 1)
                    }
                    for frame in 0..<frames {
                        for channel in 0..<2 {
                            let sample = format.isInterleaved ? channels[0][frame * 2 + channel] : channels[channel][frame]
                            if sample.isFinite { peak = max(peak, abs(sample)) } else { nonfinite += 1 }
                            if let reference {
                                let index = Int(totalFrames) * 2 + frame * 2 + channel
                                guard index < reference.count else { throw NSError(domain: "ProbeReferenceIndex", code: 1) }
                                let difference: Float = sample.isFinite ? abs(sample - reference[index]) : .infinity
                                if difference.isFinite { maximumDifference = max(maximumDifference, difference) }
                                if difference > 0.000_001, firstMismatch == nil { firstMismatch = index }
                            }
                            if exactControl, sample != (channel == 0 ? Float(0.125) : Float(-0.25)) {
                                changedControlSamples += 1
                            }
                        }
                    }
                    totalFrames += Int64(frames)
                }
                stage = "complete"
                return ["completed": true, "eof": eof, "declaredFrames": file.length,
                    "decodedFrames": totalFrames, "expectedFrames": expectedFrames,
                    "sampleRate": format.sampleRate, "channels": format.channelCount,
                    "interleaved": format.isInterleaved, "reads": reads, "peak": peak,
                    "nonfiniteSamples": nonfinite, "changedControlSamples": changedControlSamples,
                    "firstMismatchSample": firstMismatch ?? -1, "maximumDifference": maximumDifference,
                    "referenceFrames": (reference?.count ?? 0) / 2, "tolerance": 0.000_001,
                    "qualified": eof && file.length == expectedFrames && totalFrames == expectedFrames
                        && nonfinite == 0 && changedControlSamples == 0 && firstMismatch == nil && peak > 0]
            }
            row.merge(metrics) { _, new in new }
        } catch {
            let error = error as NSError
            row["failureStage"] = stage
            row["errorDomain"] = error.domain
            row["errorCode"] = error.code
            row["errorDescription"] = error.localizedDescription
            row["qualified"] = false
        }
        row["elapsedMs"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        do { try report(row) } catch { fputs("Probe JSON serialization failed\n", stderr); return false }
        return row["qualified"] as? Bool == true
    }

    static func candidate(url: URL, reference: [Float], layout: AudioFilePresentation, start: Int64, target: Int64,
                          compareFrames: Int64) -> Bool {
        var row: [String: Any] = ["schema": 1, "candidate": true, "startFrame": start,
            "targetFrame": target, "compareFrames": compareFrames, "iOSQualification": false,
            "scope": "actual-native-aac-file-reader", "playbackAcceptance": false]
        do {
            let metrics: [String: Any] = try autoreleasepool { () throws -> [String: Any] in
                guard let reader = NativeAudioFileReader.open(url: url, sampleRate: 44_100, totalFrames: 1_323_000,
                    readStartFrame: start, matchesPacketTable: { priming, valid in
                        layout.matches(primingFrames: priming, validFrames: valid, presentationFrames: 1_323_000)
                    }),
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                        channels: 2, interleaved: true),
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
                    throw NSError(domain: "CandidateOpen", code: 1)
                }
                let end = target + compareFrames
                var cursor = start, compared: Int64 = 0, reads = 0, nonfinite = 0
                var firstMismatch = -1
                var maximumDifference: Float = 0
                while cursor < end {
                    let count = try reader.read(into: buffer, maximumFrames: Int(min(4_096, end - cursor)))
                    reads += 1
                    guard count > 0, let channels = buffer.floatChannelData else {
                        throw NSError(domain: "CandidateRead", code: 1)
                    }
                    let from = max(cursor, target)
                    let through = min(cursor + Int64(count), end)
                    if from < through {
                        for frame in from..<through {
                            for channel in 0..<2 {
                                let index = Int(frame) * 2 + channel
                                let actual = channels[0][Int(frame - cursor) * 2 + channel]
                                let expected = reference[index]
                                let difference: Float = actual.isFinite ? abs(actual - expected) : .infinity
                                if !actual.isFinite { nonfinite += 1 }
                                if difference.isFinite { maximumDifference = max(maximumDifference, difference) }
                                if difference > 0.000_001, firstMismatch < 0 { firstMismatch = index }
                            }
                        }
                        compared += through - from
                    }
                    cursor += Int64(count)
                }
                var eofRead = -1
                let shouldEnd = end == 1_323_000
                if shouldEnd { eofRead = try reader.read(into: buffer, maximumFrames: 4_096) }
                let qualified = cursor == end && compared == compareFrames && firstMismatch < 0
                    && nonfinite == 0 && reader.reachedEnd == shouldEnd && (!shouldEnd || eofRead == 0)
                    && (start == 0 || reads <= 192)
                return ["qualified": qualified, "cursor": cursor, "comparedFrames": compared,
                    "reads": reads, "firstMismatchSample": firstMismatch, "maximumDifference": maximumDifference,
                    "nonfiniteSamples": nonfinite, "eofRead": eofRead, "reachedEnd": reader.reachedEnd,
                    "referenceFrames": reference.count / 2, "tolerance": 0.000_001]
            }
            row.merge(metrics) { _, new in new }
        } catch {
            row["qualified"] = false
            row["error"] = String(describing: error)
        }
        do { try report(row) } catch { return false }
        return row["qualified"] as? Bool == true
    }

    static func main() async throws {
        let directory = URL(fileURLWithPath: "artifacts/native", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let control = directory.appendingPathComponent("audio-file-control-" + UUID().uuidString).appendingPathExtension("caf")
        try autoreleasepool {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                    channels: 2, interleaved: true),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800),
                  let channels = buffer.floatChannelData else {
                throw NSError(domain: "ProbeControl", code: 1)
            }
            let file = try AVAudioFile(forWriting: control, settings: format.settings,
                commonFormat: .pcmFormatFloat32, interleaved: true)
            for frame in 0..<4_800 {
                channels[0][frame * 2] = 0.125
                channels[0][frame * 2 + 1] = -0.25
            }
            buffer.frameLength = 4_800
            try file.write(from: buffer)
        }
        // Exercise both FFmpeg's1024-frame and Apple's native AAC priming layouts.
        let appleAAC = directory.appendingPathComponent("apple-native44100-" + UUID().uuidString).appendingPathExtension("m4a")
        try autoreleasepool {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                    channels: 2, interleaved: true),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096),
                  let channels = buffer.floatChannelData else { throw NSError(domain: "ProbeNativeAACBuffer", code: 1) }
            let output = try AVAudioFile(forWriting: appleAAC, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000],
                commonFormat: .pcmFormatFloat32, interleaved: true)
            var cursor = 0
            while cursor < 1_323_000 {
                let count = min(4_096, 1_323_000 - cursor)
                for frame in 0..<count {
                    let time = Double(cursor + frame) / 44_100
                    channels[0][frame * 2] = Float(0.125 * sin(2 * Double.pi * 440 * time))
                    channels[0][frame * 2 + 1] = Float(0.095 * sin(2 * Double.pi * 659.255 * time))
                }
                buffer.frameLength = AVAudioFrameCount(count); try output.write(from: buffer); cursor += count
            }
        }
        let movie = URL(fileURLWithPath: "ios/OfflineTikTokPlayerTests/Fixtures/test-aac44100-stereo.mp4")
        var controls: [Bool] = [], movies: [Bool] = [], candidates: [Bool] = []
        for url in [movie, appleAAC] {
            try report(["schema": 1, "fixture": url.lastPathComponent, "stage": "complete-native44.1k-stereo", "iOSQualification": false])
            let reference = try await nativeReference(url: url)
            let layout = try await nativeLayout(url: url)
            for configured in [false, true] {
                controls.append(attempt(label: "generated-4800-frame-stereo-caf", url: control,
                    configured: configured, expectedFrames: 4_800, exactControl: true))
                movies.append(attempt(label: url.lastPathComponent,
                    url: url, configured: configured, expectedFrames: 1_323_000,
                    exactControl: false, reference: reference))
            }
            // Resampled inputs must preserve complete native history from zero.
            candidates.append(candidate(url: url, reference: reference, layout: layout, start: 0,
                target: 0, compareFrames: 1_323_000))
        }
        try report(["schema": 1, "summary": true, "controlsQualified": controls.allSatisfy { $0 },
            "movieModesQualified": movies, "scope": "macOS-complete-native44100-stereo-reference",
            "iOSQualification": false, "movieFidelityCompared": true, "candidateQualified": candidates.allSatisfy { $0 }, "playbackAcceptance": false])
        exit(controls.allSatisfy { $0 } && movies.allSatisfy { $0 } && candidates.allSatisfy { $0 } ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
