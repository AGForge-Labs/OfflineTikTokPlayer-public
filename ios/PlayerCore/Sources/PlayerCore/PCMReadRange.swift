/// A distant seek at the renderer's native rate does not need to rebuild a
/// sample-rate converter's history. Keep two seconds of decoder preroll and the
/// original presentation endpoint. Initial playback and retained two-second
/// heads still start at zero; resampled sources always retain full SRC history.
public enum PCMReadRange {
    public static func startFrame(requestedFrame: Int64, nativeSampleRate: Double) -> Int64 {
        guard nativeSampleRate == 48_000, requestedFrame > 96_000 else { return 0 }
        return requestedFrame - 96_000
    }
}
