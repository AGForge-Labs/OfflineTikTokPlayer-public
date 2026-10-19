import Foundation

public enum DownloadState: String, Codable, Sendable {
    case queued, resolving, downloading, paused, verifying, complete, failed
}

public struct DownloadRecord: Codable, Sendable, Identifiable {
    public var id: String { mediaID }
    public let mediaID: String
    public let asset: AssetReference
    public var state: DownloadState = .queued
    public var receivedBytes: Int64 = 0
    public var error: String?
    public var isReady: Bool { state == .complete }
    public var progress: Double { min(1, max(0, Double(receivedBytes) / Double(max(1, asset.byteSize)))) }
    public var remainingBytes: Int64 { max(0, asset.byteSize - receivedBytes) }

    public init(mediaID: String, asset: AssetReference) { self.mediaID = mediaID; self.asset = asset }

    public mutating func prepareForRelaunch(hasBackgroundTask: Bool) {
        if [.resolving, .downloading, .verifying].contains(state), !hasBackgroundTask { state = .paused }
    }

    public mutating func finish(byteSize: Int64, sha256: String) throws {
        guard byteSize == asset.byteSize, sha256 == asset.sha256 else {
            throw CatalogError.invalid("Downloaded file failed its size or checksum check.")
        }
        state = .complete; receivedBytes = byteSize; error = nil
    }

    public static func estimatedBytes(_ assets: [AssetReference], verifiedHashes: Set<String>) -> Int64 {
        var seen = verifiedHashes
        return assets.reduce(0) { total, asset in seen.insert(asset.sha256).inserted ? total + asset.byteSize : total }
    }
}
