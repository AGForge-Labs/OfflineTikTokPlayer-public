import Foundation

/// Only an in-memory convenience cache. Catalogs persist asset identities, never signed URLs.
public actor AssetURLCache {
    private struct Entry { let url: URL; let validUntil: Date }
    private var entries: [AssetReference: Entry] = [:]
    public init() {}

    public func resolve(_ asset: AssetReference, at now: Date = Date(), forceRefresh: Bool = false,
                        loader: @Sendable (AssetReference) async throws -> URL) async throws -> URL {
        if !forceRefresh, let entry = entries[asset], entry.validUntil > now { return entry.url }
        let url = try await loader(asset)
        guard url.scheme == "https", url.host != nil else { throw CatalogError.invalid("The media service returned an insecure URL.") }
        entries[asset] = Entry(url: url, validUntil: now.addingTimeInterval(120))
        return url
    }

    public func invalidate(_ asset: AssetReference) { entries.removeValue(forKey: asset) }
    public func clear() { entries.removeAll() }
}
