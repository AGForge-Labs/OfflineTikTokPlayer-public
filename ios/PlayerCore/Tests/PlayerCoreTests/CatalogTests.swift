import XCTest
@testable import PlayerCore

final class CatalogTests: XCTestCase {
    func testPythonContractDecodesAndCombinesPlaylistsWithoutDuplicates() throws {
        let catalog = try LibraryCatalog.decode(Data(Self.fixture.utf8))
        XCTAssertEqual(catalog.queue(playlistIDs: ["music", "other"]), ["1", "2"])
        XCTAssertEqual(catalog.queue(playlistIDs: ["music"], localIDs: ["2"], offlineOnly: true), ["2"])
        XCTAssertEqual(catalog.queue(playlistIDs: ["music"], localIDs: ["3"]), ["1", "2", "3"])
        XCTAssertEqual(catalog.search("CREATOR").count, 2)
        XCTAssertEqual(catalog.mediaByID["1"]?.asset?.itemID, "asset")
    }

    func testMalformedCatalogCannotReplaceLibrary() {
        for raw in [Self.fixture.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99"),
                    Self.fixture.replacingOccurrences(of: "\"itemIds\":[\"1\",\"2\",\"3\"]", with: "\"itemIds\":[\"missing\"]"),
                    Self.fixture.replacingOccurrences(of: "\"byteSize\":10", with: "\"byteSize\":0"),
                    Self.fixture.replacingOccurrences(of: "video.mp4", with: "../video.mp4")] {
            XCTAssertThrowsError(try LibraryCatalog.decode(Data(raw.utf8)))
        }
    }

    func testScaleCatalogContainsMetadataWithoutInstantiatingPlayers() throws {
        let media = (0..<6212).map { MediaRecord(id: String($0), title: "Music \($0)", creator: "creator",
                                                sourceURL: "", duration: 30, kind: .video, status: .pending) }
        let playlist = PlaylistRecord(id: "large", name: "Large", itemIDs: Array(media.prefix(2753).map(\.id)))
        let catalog = try LibraryCatalog(libraryID: "scale", media: media, playlists: [playlist])
        let data = try JSONEncoder().encode(catalog)
        let decoded = try LibraryCatalog.decode(data)
        XCTAssertEqual(decoded.media.count, 6212)
        XCTAssertEqual(decoded.queue(playlistIDs: ["large"], localIDs: Set(media.map(\.id)), offlineOnly: true).count, 2753)
        XCTAssertEqual(decoded.search("music 6211").first?.id, "6211")
    }

    static let fixture = #"""
    {"schemaVersion":1,"libraryId":"test","updatedAt":"2026-10-14T00:00:00Z","media":[
    {"id":"1","title":"First","creator":"Creator","sourceURL":"https://www.tiktok.com/@fixture_creator_4/video/1","duration":30,"kind":"video","status":"ready","asset":{"driveId":"drive","itemId":"asset","fileName":"video.mp4","byteSize":10,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","contentType":"video/mp4"},"original":null,"artwork":null},
    {"id":"2","title":"Second","creator":"Creator","sourceURL":"https://www.tiktok.com/@fixture_creator_4/video/2","duration":20,"kind":"slideshow","status":"ready","asset":{"driveId":"drive","itemId":"asset2","fileName":"video.mp4","byteSize":10,"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","contentType":"video/mp4"},"original":null,"artwork":null},
    {"id":"3","title":"Unavailable","creator":"","sourceURL":"","duration":0,"kind":"video","status":"unavailable","asset":null,"original":null,"artwork":null}],
    "playlists":[{"id":"music","name":"Music","itemIds":["1","2","3"]},{"id":"other","name":"Other","itemIds":["2","1"]}]}
    """#
}
