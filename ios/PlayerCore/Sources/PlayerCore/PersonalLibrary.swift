import Foundation
import Observation

/// Private lists of media IDs. Cloud catalog updates resolve these IDs without modifying the lists.
@MainActor @Observable
public final class PersonalLibrary {
    private enum Key {
        static let history = "personalHistory.v1"
        static let liked = "personalLiked.v1"
        static let playlists = "personalPlaylists.v1"
    }

    private let defaults: UserDefaults
    public private(set) var history: [String]
    public private(set) var liked: [String]
    public private(set) var playlists: [PlaylistRecord]
    public private(set) var likedIDs: Set<String>
    public private(set) var bookmarkedIDs: Set<String>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let liked = defaults.stringArray(forKey: Key.liked) ?? []
        let playlists = defaults.data(forKey: Key.playlists)
            .flatMap { try? JSONDecoder().decode([PlaylistRecord].self, from: $0) } ?? []
        history = defaults.stringArray(forKey: Key.history) ?? []
        self.liked = liked
        self.playlists = playlists
        likedIDs = Set(liked)
        bookmarkedIDs = Set(playlists.lazy.flatMap(\.itemIDs))
    }

    public func recordPlayed(_ mediaID: String) {
        guard !mediaID.isEmpty, history.first != mediaID else { return }
        history = [mediaID] + Array(history.lazy.filter { $0 != mediaID }.prefix(499))
        defaults.set(history, forKey: Key.history)
    }

    public func toggleLike(_ mediaID: String) {
        guard !mediaID.isEmpty else { return }
        if likedIDs.remove(mediaID) != nil { liked.removeAll { $0 == mediaID } }
        else {
            likedIDs.insert(mediaID)
            liked.insert(mediaID, at: 0)
        }
        defaults.set(liked, forKey: Key.liked)
    }

    @discardableResult
    public func createPlaylist(named name: String, adding mediaID: String? = nil) throws -> PlaylistRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CatalogError.invalid("Enter a playlist name.") }
        guard !playlists.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw CatalogError.invalid("You already have a playlist with that name.")
        }
        let itemIDs = mediaID.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        let playlist = PlaylistRecord(id: UUID().uuidString, name: trimmed, itemIDs: itemIDs)
        try save(playlists + [playlist])
        return playlist
    }

    public func toggleMembership(_ mediaID: String, in playlistID: String) throws {
        guard !mediaID.isEmpty, let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var updated = playlists
        if let existing = updated[index].itemIDs.firstIndex(of: mediaID) {
            updated[index].itemIDs.remove(at: existing)
        } else {
            updated[index].itemIDs.append(mediaID)
        }
        try save(updated)
    }

    private func save(_ playlists: [PlaylistRecord]) throws {
        defaults.set(try JSONEncoder().encode(playlists), forKey: Key.playlists)
        self.playlists = playlists
        bookmarkedIDs = Set(playlists.lazy.flatMap(\.itemIDs))
    }
}
