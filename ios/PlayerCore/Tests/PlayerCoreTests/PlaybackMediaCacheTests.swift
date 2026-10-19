import XCTest
@testable import PlayerCore

final class PlaybackMediaCacheTests: XCTestCase {
    private func asset(_ digit: String, bytes: Int64 = 3) -> AssetReference {
        AssetReference(driveID: "drive", itemID: digit, fileName: digit + ".mp4", byteSize: bytes,
                       sha256: String(repeating: digit, count: 64), contentType: "video/mp4")
    }
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testWarmedVideoCanBeOpenedLocallyWithoutAnotherTransfer() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PlaybackMediaCache(directory: directory) { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("abc".utf8).write(to: file)
            return file
        }
        let video = asset("a")
        await cache.setWindow([video], revision: 1)
        let warmed = await cache.prefetch(video, revision: 1)
        XCTAssertNotNil(warmed, "The next clip must be available before the swipe, not loaded after it.")
        guard let warmed else { return }
        let local = await cache.file(for: video)
        XCTAssertEqual(local, warmed)
        XCTAssertEqual(try Data(contentsOf: warmed), Data("abc".utf8))
    }

    func testByteAndFileLimitsEvictTheLeastRecentlyUsedUnprotectedClip() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PlaybackMediaCache(directory: directory, byteLimit: 6, countLimit: 2) { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("abc".utf8).write(to: file); return file
        }
        let a = asset("a"), b = asset("b"), c = asset("c")
        await cache.setWindow([a], revision: 1)
        _ = await cache.prefetch(a, revision: 1)
        await cache.setWindow([b], revision: 2)
        _ = await cache.prefetch(b, revision: 2)
        _ = await cache.file(for: a) // A was used more recently than B.
        await cache.setWindow([c], revision: 3)
        _ = await cache.prefetch(c, revision: 3)
        let keptA = await cache.file(for: a), evictedB = await cache.file(for: b), keptC = await cache.file(for: c)
        XCTAssertNotNil(keptA); XCTAssertNil(evictedB); XCTAssertNotNil(keptC)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }, 6)
    }

    func testCurrentAndUpcomingFilesCannotBeEvictedToExceedTheBudget() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PlaybackMediaCache(directory: directory, byteLimit: 6) { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("abc".utf8).write(to: file); return file
        }
        let a = asset("a"), b = asset("b"), c = asset("c")
        await cache.setWindow([a, b, c], revision: 1)
        _ = await cache.prefetch(a, revision: 1); _ = await cache.prefetch(b, revision: 1)
        let tooMany = await cache.prefetch(c, revision: 1)
        XCTAssertNil(tooMany)
        let kept = await cache.file(for: a)
        XCTAssertNotNil(kept)
    }

    func testPartialFileAndOversizeVideoNeverBecomeReady() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PlaybackMediaCache(directory: directory, byteLimit: 6) { video in
            XCTAssertNotEqual(video.itemID, "b", "Oversize files must be rejected before starting a transfer.")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("bad".utf8).write(to: file); return file
        }
        let partial = asset("a", bytes: 4), oversize = asset("b", bytes: 7)
        await cache.setWindow([partial, oversize], revision: 1)
        let first = await cache.prefetch(partial, revision: 1), second = await cache.prefetch(oversize, revision: 1)
        XCTAssertNil(first); XCTAssertNil(second)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testConcurrentWarmRequestsShareOneTransfer() async throws {
        let directory = folder(), gate = CacheTransferGate()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PlaybackMediaCache(directory: directory) { try await gate.load($0) }
        let a = asset("a")
        await cache.setWindow([a], revision: 1)
        let first = Task { await cache.prefetch(a, revision: 1) }
        try await gate.waitForStart("a")
        let second = Task { await cache.prefetch(a, revision: 1) }
        await gate.complete("a")
        let firstURL = await first.value, secondURL = await second.value, starts = await gate.starts
        XCTAssertNotNil(firstURL); XCTAssertEqual(firstURL, secondURL); XCTAssertEqual(starts["a"], 1)
    }

    func testLateCancelledTransferAndOldWindowCannotReplaceNewSwipe() async throws {
        let directory = folder(), gate = CacheTransferGate()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PlaybackMediaCache(directory: directory) { try await gate.load($0) }
        let a = asset("a"), b = asset("b")
        await cache.setWindow([a], revision: 1)
        let first = Task { await cache.prefetch(a, revision: 1) }
        try await gate.waitForStart("a")
        await cache.setWindow([b], revision: 2)
        let second = Task { await cache.prefetch(b, revision: 2) }
        try await gate.waitForStart("b")
        await cache.setWindow([a], revision: 1) // A stale task must not change the active window.
        await gate.complete("a"); await gate.complete("b")
        let stale = await first.value, fresh = await second.value, notCached = await cache.file(for: a)
        XCTAssertNil(stale); XCTAssertNil(notCached); XCTAssertNotNil(fresh)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testCancellationKeepsItsStorageReservationUntilTheLoaderCleansUp() async throws {
        let directory = folder(), gate = CacheTransferGate()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PlaybackMediaCache(directory: directory, byteLimit: 3) { asset in
            if asset.itemID == "a" { return try await gate.load(asset) }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("abc".utf8).write(to: file); return file
        }
        let a = asset("a"), b = asset("b")
        await cache.setWindow([a], revision: 1)
        let old = Task { await cache.prefetch(a, revision: 1) }
        try await gate.waitForStart("a")
        await cache.setWindow([b], revision: 2)
        let admittedTooSoon = await cache.prefetch(b, revision: 2)
        await gate.complete("a") // This loader deliberately finishes after cancellation.
        _ = await old.value
        XCTAssertNil(admittedTooSoon, "Canceled work still owns disk space until its cleanup has finished.")
        let afterCleanup = await cache.prefetch(b, revision: 2)
        XCTAssertNotNil(afterCleanup)
    }
}

private actor CacheTransferGate {
    private var pending: [String: CheckedContinuation<URL, Error>] = [:]
    private(set) var starts: [String: Int] = [:]
    func load(_ asset: AssetReference) async throws -> URL {
        starts[asset.itemID, default: 0] += 1
        return try await withCheckedThrowingContinuation { pending[asset.itemID] = $0 }
    }
    func complete(_ id: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try Data("abc".utf8).write(to: file); pending.removeValue(forKey: id)?.resume(returning: file) }
        catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
    }
    func waitForStart(_ id: String) async throws {
        for _ in 0..<200 {
            if pending[id] != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CatalogError.invalid("The prefetch did not start.")
    }
}
