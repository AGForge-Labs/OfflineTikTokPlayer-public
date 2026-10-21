import XCTest
import Foundation
import PlayerCore
@testable import OfflineTikTokPlayer

@MainActor
final class OfflineDownloadsIsolationTests: XCTestCase {
    func testDeferredLocalRemovalPreservesTheOriginalThrownError() async throws {
        let manager = FileManager.default
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-video", withExtension: "mp4"))
        for control in DeferredRemovalControl.allCases {
            let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
            let root = temporary.appendingPathComponent("Downloads", isDirectory: true)
            let cloud = OneDriveClient(account: MicrosoftAccount())
            let downloads = OfflineDownloads(cloud: cloud, network: NetworkStatus(),
                storageRoot: root, usesBackgroundSession: false)
            let id = "local:cleanup-error-identity-" + UUID().uuidString
            defer {
                downloads.shutdownLocalSession()
                downloads.remove(id)
                do { try manager.removeItem(at: temporary) }
                catch { XCTFail("Could not remove the owned cleanup fixture for \(control.rawValue): \(error)") }
            }

            let (_, asset) = try await downloads.importLocal(source, mediaID: id)
            let saved = root.appendingPathComponent("Offline", isDirectory: true)
                .appendingPathComponent(asset.sha256 + ".mp4")
            let checkpoint = root.appendingPathComponent("Transfers", isDirectory: true)
                .appendingPathComponent(asset.sha256 + ".resume")
            XCTAssertTrue(downloads.records[id]?.isReady == true)
            XCTAssertTrue(manager.fileExists(atPath: saved.path))
            XCTAssertFalse(manager.fileExists(atPath: checkpoint.path))
            if control == .existingCheckpoint {
                // Only removal is exercised; these synthetic bytes are never
                // submitted to URLSession as resume data.
                try Data("synthetic checkpoint".utf8).write(to: checkpoint, options: .withoutOverwriting)
                XCTAssertTrue(manager.fileExists(atPath: checkpoint.path))
            }

            let original = DeferredRemovalSentinel()
            var deferredCleanupRan = false
            do {
                try await throwOriginalError(original) {
                    deferredCleanupRan = true
                    if control != .noCleanup {
                        downloads.shutdownLocalSession()
                        downloads.remove(id)
                    }
                }
                XCTFail("The original sentinel must be thrown for \(control.rawValue)")
            } catch {
                if let caught = error as? DeferredRemovalSentinel {
                    XCTAssertTrue(caught === original, "Cleanup must preserve the exact error object for \(control.rawValue)")
                    XCTAssertEqual(caught.identity, original.identity)
                } else {
                    XCTFail("Cleanup replaced the original typed error for \(control.rawValue) with \(String(reflecting: type(of: error)))")
                }
            }
            XCTAssertTrue(deferredCleanupRan, "The throwing helper must run its defer for \(control.rawValue)")
            if control == .noCleanup {
                XCTAssertTrue(downloads.records[id]?.isReady == true)
                XCTAssertTrue(manager.fileExists(atPath: saved.path))
            } else {
                XCTAssertNil(downloads.records[id])
                XCTAssertFalse(manager.fileExists(atPath: saved.path))
            }
            XCTAssertFalse(manager.fileExists(atPath: checkpoint.path))
        }
    }

    private func throwOriginalError(_ original: DeferredRemovalSentinel, cleanup: () -> Void) async throws {
        defer { cleanup() }
        throw original
    }

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

private enum DeferredRemovalControl: String, CaseIterable {
    case noCleanup, missingCheckpoint, existingCheckpoint
}

private final class DeferredRemovalSentinel: Error, Sendable {
    let identity = UUID()
}
