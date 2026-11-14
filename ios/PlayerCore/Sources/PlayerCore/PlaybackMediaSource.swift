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

    /// Preserve explicit saved files, use a verified cached copy when possible,
    /// and fall back to the archive if the optional derivative is unavailable.
    public static func resolve(saved: URL?, media: MediaRecord, cache: PlaybackMediaCache?,
        allowRemote: Bool, forceRemote: Bool = false, useOriginal: Bool = false,
        remoteURL: (AssetReference) async throws -> URL) async throws -> (source: Self, mastered: Bool, enhanced: Bool) {
        try Task.checkCancellation()
        let original = media.asset
        let preferred = useOriginal ? original : media.preferredStream
        if let saved { return (.verifiedFile(saved), false, false) }
        if !forceRemote, let preferred, let cached = await cache?.file(for: preferred) {
            try Task.checkCancellation()
            return (.verifiedFile(cached), media.hasMasteredAudio(for: preferred), preferred != original)
        }
        if !forceRemote, original != preferred, let original, let cached = await cache?.file(for: original) {
            try Task.checkCancellation()
            return (.verifiedFile(cached), false, false)
        }
        if let preferred, preferred != original, allowRemote {
            do {
                return (try await resolve(saved: nil, asset: preferred, cache: nil, allowRemote: true,
                                          forceRemote: forceRemote, remoteURL: remoteURL), media.hasMasteredAudio(for: preferred), true)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
            }
        }
        return (try await resolve(saved: nil, asset: original, cache: nil, allowRemote: allowRemote,
                                  forceRemote: forceRemote, remoteURL: remoteURL), false, false)
    }
}
