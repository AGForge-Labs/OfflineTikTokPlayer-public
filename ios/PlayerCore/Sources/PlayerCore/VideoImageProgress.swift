import Foundation

/// One bounded picture repair per absence of forward image progress.
/// The caller qualifies the exact audio/video owner and resets on user intent changes.
public struct VideoImageProgress {
    public init() {}
    public mutating func shouldRecover(now: Double, nativePosition: Double,
                                       displayedPosition: Double?) -> Bool { false }
}
