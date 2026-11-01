public enum VideoImageIdentity {
    public static func isPresented(sourceSurface: UInt32?, displayedSurface: UInt32?, sameRetainedBuffer: Bool,
                                   framePosition: Double, presentationPosition: Double) -> Bool {
        guard framePosition.isFinite, presentationPosition.isFinite,
              framePosition <= presentationPosition + 1.0 / 48_000 else { return false }
        return matches(sourceSurface: sourceSurface, displayedSurface: displayedSurface,
            sameRetainedBuffer: sameRetainedBuffer)
    }

    public static func matches(sourceSurface: UInt32?, displayedSurface: UInt32?, sameRetainedBuffer: Bool) -> Bool {
        if let sourceSurface, let displayedSurface {
            return sourceSurface != 0 && sourceSurface == displayedSurface
        }
        guard sourceSurface == nil, displayedSurface == nil else { return false }
        return sameRetainedBuffer
    }
}
