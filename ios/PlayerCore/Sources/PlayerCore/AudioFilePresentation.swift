/// Native sample-grid layout of one complete AAC segment.
/// Codec/rate/channel/single-track eligibility is checked by the AVFoundation owner.
public struct AudioFilePresentation: Equatable, Sendable {
    public let sourceStart: Int64
    public let sourceFrames: Int64
    public let targetStart: Int64
    public let targetFrames: Int64

    public init(sourceStart: Int64, sourceFrames: Int64, targetStart: Int64, targetFrames: Int64) {
        self.sourceStart = sourceStart
        self.sourceFrames = sourceFrames
        self.targetStart = targetStart
        self.targetFrames = targetFrames
    }

    public func matches(primingFrames: Int64, validFrames: Int64, presentationFrames: Int64) -> Bool {
        presentationFrames > 0
            && primingFrames >= 0
            && validFrames == presentationFrames
            && sourceStart == primingFrames
            && sourceFrames == validFrames
            && targetStart == 0
            && targetFrames == validFrames
    }
}
