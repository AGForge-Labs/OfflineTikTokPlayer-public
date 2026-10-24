import XCTest
import PlayerCore
#if canImport(CloudAdapter)
@testable import CloudAdapter
#else
@testable import OfflineTikTokPlayer
#endif

@MainActor
final class LibraryRefreshTests: XCTestCase {
    func testManualTikTokCheckPublishesThenReloadsAndPreservesPhoneImports() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var imported = false
        var calls = 0
        let library = LibraryRepository(cloud: OneDriveClient(account: MicrosoftAccount()), catalogURL: url,
            fetchCatalog: {
                calls += 1
                return try LibraryCatalog(libraryID: "private", media: imported ? [MediaRecord(id: "new", title: "New")] : [], playlists: [])
            }, requestImport: { id in
                XCTAssertEqual(id, "private")
                imported = true
                return "Imported 1 new video."
            })
        try library.install(LibraryCatalog(libraryID: "private", media: [MediaRecord(id: "local:mine", title: "Mine")], playlists: []))
        await library.refresh(checkTikTok: true)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(library.catalog.media.map(\.id), ["new", "local:mine"])
        XCTAssertEqual(library.message, "Imported 1 new video.")
        XCTAssertFalse(library.isRefreshing)
        XCTAssertNil(library.refreshStatus)
    }

    func testManualTikTokRequestJoiningForegroundRefreshRunsOnce() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var first: CheckedContinuation<LibraryCatalog, Error>?
        var imported: CheckedContinuation<String, Error>?
        var fetches = 0
        var requests = 0
        let library = LibraryRepository(cloud: OneDriveClient(account: MicrosoftAccount()), catalogURL: url,
            fetchCatalog: {
                fetches += 1
                if fetches == 1 { return try await withCheckedThrowingContinuation { first = $0 } }
                return try LibraryCatalog(libraryID: "private", media: [], playlists: [])
            }, requestImport: { _ in
                requests += 1
                return try await withCheckedThrowingContinuation { imported = $0 }
            })
        let automatic = Task { await library.refresh(silently: true) }
        while first == nil { await Task.yield() }
        let manual = Task { await library.refresh(checkTikTok: true) }
        for _ in 0..<10 { await Task.yield() }
        first?.resume(returning: try LibraryCatalog(libraryID: "private", media: [], playlists: []))
        while imported == nil { await Task.yield() }
        let duplicate = Task { await library.refresh(checkTikTok: true) }
        for _ in 0..<10 { await Task.yield() }
        imported?.resume(returning: "No new videos found.")
        await automatic.value; await manual.value; await duplicate.value
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(library.message, "No new videos found.")
    }

    func testFailedTikTokImportStillReloadsPublishedCatalogAndKeepsLocalCopies() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var fetches = 0
        let library = LibraryRepository(cloud: OneDriveClient(account: MicrosoftAccount()), catalogURL: url,
            fetchCatalog: {
                fetches += 1
                return try LibraryCatalog(libraryID: "private", media: [MediaRecord(id: "cloud", title: "Archived")], playlists: [])
            }, requestImport: { _ in throw AppError.message("Sign in to TikTok in the Windows helper.") })
        try library.install(LibraryCatalog(libraryID: "private", media: [MediaRecord(id: "local:mine", title: "Mine")], playlists: []))
        await library.refresh(checkTikTok: true)
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(library.catalog.media.map(\.id), ["cloud", "local:mine"])
        XCTAssertTrue(library.message?.contains("Sign in to TikTok") == true)
    }

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
