import XCTest
@testable import PlayerCore

final class PersonalLibraryTests: XCTestCase {
    @MainActor
    func testRecentVideosAreUniqueAndRestoreInLastPlayedOrder() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let library = PersonalLibrary(defaults: defaults)
        library.recordPlayed("a")
        library.recordPlayed("b")
        library.recordPlayed("a")
        library.recordPlayed("a")
        XCTAssertEqual(PersonalLibrary(defaults: defaults).history, ["a", "b"])
    }

    @MainActor
    func testLikesAndBookmarksAreIndependentAndPersistWithoutDuplicateMembership() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let library = PersonalLibrary(defaults: defaults)
        let playlist = try library.createPlaylist(named: "  Fav 1\n", adding: "a")
        library.toggleLike("a")
        library.toggleLike("b")
        library.toggleLike("a")
        library.toggleMembership("b", in: playlist.id)
        let reopened = PersonalLibrary(defaults: defaults)
        XCTAssertEqual(reopened.liked, ["b"])
        XCTAssertEqual(reopened.playlists, [PlaylistRecord(id: playlist.id, name: "Fav 1", itemIDs: ["a", "b"])])
        reopened.toggleMembership("a", in: playlist.id)
        XCTAssertEqual(PersonalLibrary(defaults: defaults).playlists.first?.itemIDs, ["b"])
        XCTAssertEqual(reopened.liked, ["b"])
    }

    @MainActor
    func testEmptyAndDuplicateNamesDoNotCreatePlaylists() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let library = PersonalLibrary(defaults: defaults)
        let empty = try library.createPlaylist(named: "Useful Advice")
        XCTAssertThrowsError(try library.createPlaylist(named: " useful advice ", adding: "a"))
        XCTAssertThrowsError(try library.createPlaylist(named: " \n"))
        XCTAssertEqual(library.playlists, [empty])
        XCTAssertTrue(empty.itemIDs.isEmpty)
    }

    func testPersonalQueueResolvesAgainstCurrentCatalogWithoutMixingImportedMembership() throws {
        let catalog = try LibraryCatalog.decode(Data(CatalogTests.fixture.utf8))
        let personal = ["2", "gone", "2", "3", "1"]
        XCTAssertEqual(catalog.queue(playlistIDs: [], within: personal), ["2", "1"])
        XCTAssertEqual(catalog.queue(playlistIDs: [], localIDs: ["3", "1"], offlineOnly: true, within: personal), ["3", "1"])
        XCTAssertTrue(catalog.queue(playlistIDs: [], within: []).isEmpty)
        XCTAssertEqual(catalog.queue(playlistIDs: ["music"]), ["1", "2"])
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "personal-library-tests-\(UUID())"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }
}
