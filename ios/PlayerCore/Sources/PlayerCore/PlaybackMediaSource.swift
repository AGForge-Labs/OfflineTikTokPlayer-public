import Foundation

/// A ready local copy can feed the PCM reader. A cache miss must remain streamable;
/// optional whole-file warming is owned separately and never blocks this choice.
public enum PlaybackMediaSource: Equatable, Sendable {
    case verifiedFile(URL)
    case stream(URL)

    public var url: URL {
        switch self { case .verifiedFile(let url), .stream(let url): return url }
    }
    public var usesPCM: Bool {
        if case .verifiedFile = self { return true }
        return false
    }

    public static func resolve(saved: URL?, asset: AssetReference?, cache: PlaybackMediaCache?,
        allowRemote: Bool, forceRemote: Bool = false,
        remoteURL: (AssetReference) async throws -> URL) async throws -> Self {
        try Task.checkCancellation()
        if let saved { return .verifiedFile(saved) }
        if !forceRemote, let asset, let cached = await cache?.file(for: asset) {
            try Task.checkCancellation()
            return .verifiedFile(cached)
        }
        guard allowRemote, let asset else {
            throw CatalogError.invalid("This video is unavailable while offline.")
        }
        let url = try await remoteURL(asset)
        try Task.checkCancellation()
        return .stream(url)
    }
}
