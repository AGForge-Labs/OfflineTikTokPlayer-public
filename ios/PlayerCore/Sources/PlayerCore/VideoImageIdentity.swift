public enum VideoImageIdentity {
    public static func isPresented(sourceSurface: UInt32?, displayedSurface: UInt32?, sameRetainedBuffer: Bool,
                                   framePosition: Double, presentationPosition: Double) -> Bool {
        matches(sourceSurface: sourceSurface, displayedSurface: displayedSurface, sameRetainedBuffer: sameRetainedBuffer)
    }

    public static func matches(sourceSurface: UInt32?, displayedSurface: UInt32?, sameRetainedBuffer: Bool) -> Bool {
        if let sourceSurface, let displayedSurface {
            return sourceSurface != 0 && sourceSurface == displayedSurface
        }
        guard sourceSurface == nil, displayedSurface == nil else { return false }
        return sameRetainedBuffer
    }
}
