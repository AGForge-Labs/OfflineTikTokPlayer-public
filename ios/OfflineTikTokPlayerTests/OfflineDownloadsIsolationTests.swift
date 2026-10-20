import XCTest
import Foundation
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class OfflineDownloadsIsolationTests: XCTestCase {
    func testRemovingTheSameImportedHashInOneRootPreservesTheOtherRootAndLedger() async throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        let firstRoot = temporary.appendingPathComponent("First", isDirectory: true)
        let secondRoot = temporary.appendingPathComponent("Second", isDirectory: true)
        let cloud = OneDriveClient(account: MicrosoftAccount())
        let first = OfflineDownloads(cloud: cloud, network: NetworkStatus(),
            storageRoot: firstRoot, usesBackgroundSession: false)
        let second = OfflineDownloads(cloud: cloud, network: NetworkStatus(),
            storageRoot: secondRoot, usesBackgroundSession: false)
        var restored: OfflineDownloads?
        defer {
            restored?.shutdownLocalSession()
            first.shutdownLocalSession(); second.shutdownLocalSession()
            try? manager.removeItem(at: temporary)
        }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        let id = "local:isolated-synthetic"
        let importedFirst = try await first.importLocal(source, mediaID: id)
        let importedSecond = try await second.importLocal(source, mediaID: id)
        XCTAssertEqual(importedFirst.1, importedSecond.1, "The fixture must exercise identical bytes and hash names")
        let item = MediaRecord(id: id, title: "Synthetic isolation fixture", status: .ready, asset: importedSecond.1)
        let firstLocal = await first.localURL(for: item)
        let secondLocal = await second.localURL(for: item)
        let firstURL = try XCTUnwrap(firstLocal), secondURL = try XCTUnwrap(secondLocal)
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(firstURL.deletingLastPathComponent(), firstRoot.appendingPathComponent("Offline", isDirectory: true))
        XCTAssertEqual(secondURL.deletingLastPathComponent(), secondRoot.appendingPathComponent("Offline", isDirectory: true))
        XCTAssertEqual(firstURL.lastPathComponent, secondURL.lastPathComponent)

        first.shutdownLocalSession()
        first.shutdownLocalSession() // Local teardown is idempotent and does not delete Saved media.
        first.remove(id)
        XCTAssertTrue(first.readyIDs.isEmpty)
        XCTAssertFalse(manager.fileExists(atPath: firstURL.path))
        XCTAssertTrue(manager.fileExists(atPath: secondURL.path))
        XCTAssertTrue(second.readyIDs.contains(id))
        XCTAssertEqual(try Data(contentsOf: secondURL), try Data(contentsOf: source), "Removing one fixture must preserve every byte in the other")
        let firstLedger = try JSONDecoder().decode([String: DownloadRecord].self,
            from: Data(contentsOf: firstRoot.appendingPathComponent("downloads.json")))
        let secondLedger = try JSONDecoder().decode([String: DownloadRecord].self,
            from: Data(contentsOf: secondRoot.appendingPathComponent("downloads.json")))
        XCTAssertTrue(firstLedger.isEmpty)
        XCTAssertEqual(secondLedger[id]?.asset, importedSecond.1)
        XCTAssertEqual(secondLedger[id]?.state, .complete)

        // A fresh instance has an empty in-memory verification set. Reload the
        // surviving ledger and verify its Saved file rather than reimporting it.
        second.shutdownLocalSession()
        let reloaded = OfflineDownloads(cloud: cloud, network: NetworkStatus(),
            storageRoot: secondRoot, usesBackgroundSession: false)
        restored = reloaded
        XCTAssertTrue(reloaded.readyIDs.contains(id))
        let reloadedLocal = await reloaded.localURL(for: item)
        XCTAssertEqual(try XCTUnwrap(reloadedLocal), secondURL)
        let digest = try AppFiles.hash(secondURL)
        XCTAssertEqual(digest.size, importedSecond.1.byteSize)
        XCTAssertEqual(digest.sha256, importedSecond.1.sha256)
    }
}
