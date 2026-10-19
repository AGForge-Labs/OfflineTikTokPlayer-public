import XCTest
@testable import PlayerCore

final class TransferTests: XCTestCase {
    func testPausedAndFailedTransfersRestoreAsResumableWithoutBecomingReady() throws {
        var transfer = DownloadRecord(mediaID: "one", asset: asset)
        transfer.state = .downloading
        transfer.receivedBytes = 30
        let data = try JSONEncoder().encode(transfer)
        var restored = try JSONDecoder().decode(DownloadRecord.self, from: data)
        restored.prepareForRelaunch(hasBackgroundTask: false)
        XCTAssertEqual(restored.state, .paused)
        XCTAssertFalse(restored.isReady)
        XCTAssertEqual(restored.progress, 0.3, accuracy: 0.001)
        XCTAssertEqual(restored.remainingBytes, 70)
    }

    func testOnlyVerifiedSizeAndChecksumCanFinish() {
        var transfer = DownloadRecord(mediaID: "one", asset: asset)
        XCTAssertThrowsError(try transfer.finish(byteSize: 100, sha256: String(repeating: "b", count: 64)))
        XCTAssertFalse(transfer.isReady)
        XCTAssertThrowsError(try transfer.finish(byteSize: 99, sha256: asset.sha256))
        XCTAssertNoThrow(try transfer.finish(byteSize: 100, sha256: asset.sha256))
        XCTAssertTrue(transfer.isReady)
        XCTAssertEqual(transfer.progress, 1)
        XCTAssertEqual(transfer.remainingBytes, 0)
    }

    func testEstimatesCountSharedAssetsOnlyOnceAndExcludeVerifiedCopies() {
        let other = AssetReference(driveID: "d", itemID: "j", fileName: "other.mp4", byteSize: 200,
                                   sha256: String(repeating: "b", count: 64), contentType: "video/mp4")
        XCTAssertEqual(DownloadRecord.estimatedBytes([asset, asset, other], verifiedHashes: []), 300)
        XCTAssertEqual(DownloadRecord.estimatedBytes([asset, other], verifiedHashes: [asset.sha256]), 200)
    }

    private var asset: AssetReference {
        AssetReference(driveID: "d", itemID: "i", fileName: "video.mp4", byteSize: 100,
                       sha256: String(repeating: "a", count: 64), contentType: "video/mp4")
    }
}
