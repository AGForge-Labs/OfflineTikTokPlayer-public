import XCTest
@testable import PlayerCore

private actor Counter {
    private(set) var value = 0
    func increment() -> Int { value += 1; return value }
}

final class AssetURLTests: XCTestCase {
    func testTemporaryURLsExpireAndCanBeForcedFreshWithoutChangingAssetIdentity() async throws {
        let cache = AssetURLCache()
        let count = Counter()
        let asset = AssetReference(driveID: "drive", itemID: "item", fileName: "v.mp4", byteSize: 100,
                                   sha256: String(repeating: "a", count: 64), contentType: "video/mp4")
        let start = Date(timeIntervalSince1970: 100)
        let loader: @Sendable (AssetReference) async throws -> URL = { _ in
            let n = await count.increment()
            return URL(string: "https://cdn.example.test/video?token=\(n)")!
        }
        let first = try await cache.resolve(asset, at: start, loader: loader)
        let reused = try await cache.resolve(asset, at: start.addingTimeInterval(1), loader: loader)
        XCTAssertEqual(first, reused)
        let expired = try await cache.resolve(asset, at: start.addingTimeInterval(121), loader: loader)
        XCTAssertNotEqual(first, expired)
        let forced = try await cache.resolve(asset, at: start.addingTimeInterval(122), forceRefresh: true, loader: loader)
        XCTAssertNotEqual(expired, forced)
        let requests = await count.value
        XCTAssertEqual(requests, 3)
    }

    func testCleartextAssetURLsAreRejected() async {
        let cache = AssetURLCache()
        let asset = AssetReference(driveID: "d", itemID: "i", fileName: "v.mp4", byteSize: 1,
                                   sha256: String(repeating: "a", count: 64), contentType: "video/mp4")
        do {
            _ = try await cache.resolve(asset) { _ in URL(string: "http://cdn.example.test/video")! }
            XCTFail("A private asset must use HTTPS")
        } catch {}
    }
}
