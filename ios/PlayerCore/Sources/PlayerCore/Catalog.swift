import Foundation

public enum CatalogError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): return reason }
    }
}

public struct AssetReference: Codable, Hashable, Sendable {
    public let driveID: String
    public let itemID: String
    public let fileName: String
    public let byteSize: Int64
    public let sha256: String
    public let contentType: String
    enum CodingKeys: String, CodingKey {
        case driveID = "driveId", itemID = "itemId", fileName, byteSize, sha256, contentType
    }

    public init(driveID: String, itemID: String, fileName: String, byteSize: Int64, sha256: String, contentType: String) {
        self.driveID = driveID; self.itemID = itemID; self.fileName = fileName
        self.byteSize = byteSize; self.sha256 = sha256; self.contentType = contentType
    }

    public func validate() throws {
        guard !driveID.isEmpty, !itemID.isEmpty, byteSize > 0, !fileName.isEmpty,
              !fileName.contains("/"), !fileName.contains("\\"), fileName != ".", fileName != "..",
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw CatalogError.invalid("Invalid asset identity, path, size or checksum.")
        }
    }
}

public struct MediaRecord: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case video, slideshow }
    public enum Status: String, Codable, Sendable { case ready, pending, unavailable }
    public let id: String
    public var title: String
    public var creator: String
    public var sourceURL: String
    public var duration: Double
    public var kind: Kind
    public var status: Status
    public var asset: AssetReference?
    public var original: AssetReference?
    public var artwork: AssetReference?

    public init(id: String, title: String, creator: String = "", sourceURL: String = "", duration: Double = 0,
                kind: Kind = .video, status: Status = .pending, asset: AssetReference? = nil,
                original: AssetReference? = nil, artwork: AssetReference? = nil) {
        self.id = id; self.title = title; self.creator = creator; self.sourceURL = sourceURL
        self.duration = duration; self.kind = kind; self.status = status
        self.asset = asset; self.original = original; self.artwork = artwork
    }
}

public struct PlaylistRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var itemIDs: [String]
    enum CodingKeys: String, CodingKey { case id, name, itemIDs = "itemIds" }
    public init(id: String, name: String, itemIDs: [String]) {
        self.id = id; self.name = name; self.itemIDs = itemIDs
    }
}

public struct LibraryCatalog: Codable, Sendable {
    public let schemaVersion: Int
    public let libraryID: String
    public let updatedAt: String
    public let media: [MediaRecord]
    public let playlists: [PlaylistRecord]
    public let mediaByID: [String: MediaRecord]
    private let searchTerms: [String: String]
    enum CodingKeys: String, CodingKey {
        case schemaVersion, libraryID = "libraryId", updatedAt, media, playlists
    }

    public init(libraryID: String, media: [MediaRecord], playlists: [PlaylistRecord],
                updatedAt: String = ISO8601DateFormatter().string(from: Date()), schemaVersion: Int = 1) throws {
        guard schemaVersion == 1 else { throw CatalogError.invalid("Unsupported library version.") }
        let ids = Set(media.map(\.id))
        guard !libraryID.isEmpty, !updatedAt.isEmpty, ids.count == media.count, !ids.contains(""),
              Set(playlists.map(\.id)).count == playlists.count else {
            throw CatalogError.invalid("Library contains missing or duplicate identities.")
        }
        for item in media {
            guard item.duration.isFinite, item.duration >= 0, item.status != .ready || item.asset != nil else {
                throw CatalogError.invalid("Ready media needs a complete asset and valid duration.")
            }
            try item.asset?.validate(); try item.original?.validate(); try item.artwork?.validate()
        }
        for playlist in playlists {
            guard !playlist.id.isEmpty, Set(playlist.itemIDs).count == playlist.itemIDs.count,
                  playlist.itemIDs.allSatisfy(ids.contains) else {
                throw CatalogError.invalid("Playlist contains duplicate or missing media.")
            }
        }
        self.schemaVersion = schemaVersion; self.libraryID = libraryID; self.updatedAt = updatedAt
        self.media = media; self.playlists = playlists
        mediaByID = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
        searchTerms = Dictionary(uniqueKeysWithValues: media.map { ($0.id, ($0.title + " " + $0.creator).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) })
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(libraryID: c.decode(String.self, forKey: .libraryID),
                      media: c.decode([MediaRecord].self, forKey: .media),
                      playlists: c.decode([PlaylistRecord].self, forKey: .playlists),
                      updatedAt: c.decode(String.self, forKey: .updatedAt),
                      schemaVersion: c.decode(Int.self, forKey: .schemaVersion))
    }

    public static func decode(_ data: Data) throws -> LibraryCatalog { try JSONDecoder().decode(Self.self, from: data) }

    public func queue(playlistIDs: [String], localIDs: Set<String> = [], offlineOnly: Bool = false) -> [String] {
        let selected = Set(playlistIDs)
        let ordered = selected.isEmpty ? media.map(\.id) : playlists.filter { selected.contains($0.id) }.flatMap(\.itemIDs)
        var seen = Set<String>()
        return ordered.filter { id in
            guard let item = mediaByID[id], seen.insert(id).inserted else { return false }
            return localIDs.contains(id) || (!offlineOnly && item.status == .ready && item.asset != nil)
        }
    }

    public func search(_ query: String, within ids: [String]? = nil) -> [MediaRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return (ids ?? media.map(\.id)).compactMap { id in
            guard needle.isEmpty || searchTerms[id]?.contains(needle) == true else { return nil }
            return mediaByID[id]
        }
    }
}
