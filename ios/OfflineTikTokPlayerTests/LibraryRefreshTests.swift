import XCTest
import PlayerCore
#if canImport(CloudAdapter)
@testable import CloudAdapter
#else
@testable import OfflineTikTokPlayer
#endif

@MainActor
final class LibraryRefreshTests: XCTestCase {
    func testSilentFailureKeepsTheCachedLibraryAndManualErrorStillAppears() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cloud = OneDriveClient(account: MicrosoftAccount())
        let library = LibraryRepository(cloud: cloud, catalogURL: url, fetchCatalog: {
            throw AppError.message("No network")
        })
        try library.install(LibraryCatalog(libraryID: "private", media: [MediaRecord(id: "saved", title: "Saved")], playlists: []))
        await library.refresh(silently: true)
        XCTAssertEqual(library.catalog.media.map(\.id), ["saved"])
        XCTAssertNil(library.message)
        await library.refresh()
        XCTAssertTrue(library.message?.contains("No network") == true)
    }

    func testForegroundRefreshCoalescesAndMergesLocalChangesMadeDuringTheRequest() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var continuation: CheckedContinuation<LibraryCatalog, Error>?
        var calls = 0
        let cloud = OneDriveClient(account: MicrosoftAccount())
        let library = LibraryRepository(cloud: cloud, catalogURL: url, fetchCatalog: {
            calls += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let request = Task { await library.refresh(silently: true) }
        while continuation == nil { await Task.yield() }
        let duplicate = Task { await library.refresh(silently: true) }
        await Task.yield()
        XCTAssertEqual(calls, 1)
        let local = MediaRecord(id: "local:mine", title: "On my phone")
        try library.install(LibraryCatalog(libraryID: "private", media: [local],
            playlists: [PlaylistRecord(id: "local:videos", name: "On your iPhone", itemIDs: [local.id])]))
        continuation?.resume(returning: try LibraryCatalog(libraryID: "private",
            media: [MediaRecord(id: "new", title: "New addition")],
            playlists: [PlaylistRecord(id: "music", name: "Music", itemIDs: ["new"])]))
        await request.value
        await duplicate.value
        XCTAssertEqual(library.catalog.media.map(\.id), ["new", "local:mine"])
        XCTAssertEqual(library.catalog.playlists.map(\.id), ["music", "local:videos"])
        XCTAssertFalse(library.isRefreshing)
        XCTAssertEqual(try LibraryCatalog.decode(Data(contentsOf: url)).media.map(\.id), ["new", "local:mine"])
    }

    func testQuickBackgroundAndForegroundDoesNotLoseTheRefresh() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var continuation: CheckedContinuation<LibraryCatalog, Error>?
        var calls = 0
        let library = LibraryRepository(cloud: OneDriveClient(account: MicrosoftAccount()), catalogURL: url, fetchCatalog: {
            calls += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let oldForeground = Task { await library.refresh(silently: true) }
        while continuation == nil { await Task.yield() }
        oldForeground.cancel()
        let newForeground = Task { await library.refresh(silently: true) }
        await Task.yield()
        continuation?.resume(returning: try LibraryCatalog(libraryID: "private", media: [MediaRecord(id: "new", title: "New")], playlists: []))
        await oldForeground.value
        await newForeground.value
        XCTAssertEqual(library.catalog.media.map(\.id), ["new"])
        XCTAssertEqual(calls, 1)
    }

    func testManualRefreshJoiningASilentRequestReportsItsFailure() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        var continuation: CheckedContinuation<LibraryCatalog, Error>?
        let library = LibraryRepository(cloud: OneDriveClient(account: MicrosoftAccount()), catalogURL: url, fetchCatalog: {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let automatic = Task { await library.refresh(silently: true) }
        while continuation == nil { await Task.yield() }
        let manual = Task { await library.refresh() }
        // Wait until the manual task has had a chance to join the in-flight request.
        for _ in 0..<10 { await Task.yield() }
        continuation?.resume(throwing: AppError.message("Network unavailable"))
        await automatic.value
        await manual.value
        XCTAssertTrue(library.message?.contains("Network unavailable") == true)
    }
}
