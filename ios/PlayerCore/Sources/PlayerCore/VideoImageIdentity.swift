public enum VideoImageIdentity {
    public static func matches(sourceSurface: UInt32?, displayedSurface: UInt32?, sameRetainedBuffer: Bool) -> Bool {
        sameRetainedBuffer || (sourceSurface != nil && sourceSurface == displayedSurface)
    }
}
