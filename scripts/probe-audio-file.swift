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

    static func attempt(label: String, url: URL, configured: Bool, expectedFrames: Int64,
                        exactControl: Bool) -> Bool {
        var stage = "open"
        var row: [String: Any] = ["schema": 1, "fixture": label, "platform": "macOS",
            "mode": configured ? "configured-interleaved-float32" : "default-deinterleaved",
            "completed": false, "iOSQualification": false, "fidelityCompared": exactControl]
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
                guard format.sampleRate == 48_000, format.channelCount == 2,
                      format.commonFormat == .pcmFormatFloat32 else {
                    throw NSError(domain: "ProbeFormat", code: 1)
                }
                stage = "buffer"
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
                    throw NSError(domain: "ProbeBuffer", code: 1)
                }
                var totalFrames: Int64 = 0, nonfinite = 0, changedControlSamples = 0
                var reads = 0, eof = false
                var peak: Float = 0
                for _ in 0..<400 {
                    stage = "read"
                    buffer.frameLength = 0
                    row["beforeReadPosition"] = file.framePosition
                    row["declaredFrames"] = file.length
                    row["successfullyCopiedFrames"] = totalFrames
                    row["successfulReads"] = reads
                    row["requestedFrames"] = 4_096
                    do {
                        try file.read(into: buffer, frameCount: 4_096)
                    } catch {
                        row["afterFailedReadPosition"] = file.framePosition
                        row["failedReadBufferFrames"] = buffer.frameLength
                        throw error
                    }
                    reads += 1
                    let frames = Int(buffer.frameLength)
                    if frames == 0 { eof = true; break }
                    guard totalFrames + Int64(frames) <= expectedFrames + 4_096,
                          let channels = buffer.floatChannelData else {
                        throw NSError(domain: "ProbeReadBound", code: 1)
                    }
                    for frame in 0..<frames {
                        for channel in 0..<2 {
                            let sample = format.isInterleaved ? channels[0][frame * 2 + channel] : channels[channel][frame]
                            if sample.isFinite { peak = max(peak, abs(sample)) } else { nonfinite += 1 }
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
                    "qualified": eof && file.length == expectedFrames && totalFrames == expectedFrames
                        && nonfinite == 0 && changedControlSamples == 0 && peak > 0]
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

    static func main() throws {
        let directory = URL(fileURLWithPath: "artifacts/native", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let control = directory.appendingPathComponent("audio-file-control-" + UUID().uuidString).appendingPathExtension("caf")
        try autoreleasepool {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
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
        let movie = URL(fileURLWithPath: "ios/OfflineTikTokPlayerTests/Fixtures/test-selection-a.mp4")
        var controls: [Bool] = [], movies: [Bool] = []
        for configured in [false, true] {
            controls.append(attempt(label: "generated-4800-frame-stereo-caf", url: control,
                configured: configured, expectedFrames: 4_800, exactControl: true))
            movies.append(attempt(label: "original-30s-native48k-stereo-mp4", url: movie,
                configured: configured, expectedFrames: 1_440_000, exactControl: false))
        }
        try report(["schema": 1, "summary": true, "controlsQualified": controls.allSatisfy { $0 },
            "movieModesQualified": movies, "scope": "macOS-file-open-read-length-only",
            "iOSQualification": false, "movieFidelityCompared": false, "playbackAcceptance": false])
        exit(controls.allSatisfy { $0 } && movies.allSatisfy { $0 } ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
