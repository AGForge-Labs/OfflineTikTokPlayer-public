import Foundation
import PlayerCore

enum PlaybackCacheLoader {
    static func make(cloud: OneDriveClient) -> PlaybackMediaCache? {
        let directory = AppFiles.directory("PlaybackCache", excludeFromBackup: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        return try? PlaybackMediaCache(directory: directory) { asset in
            let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard available > asset.byteSize + 100_000_000 else { throw AppError.message("Not enough temporary playback storage.") }
            let url = try await cloud.downloadURL(asset)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.networkServiceType = .background
            let (temporary, response) = try await session.download(for: request)
            do {
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("Could not prepare the next video.") }
                let digest = try await Task.detached(priority: .utility) { try AppFiles.hash(temporary) }.value
                guard digest.size == asset.byteSize, digest.sha256 == asset.sha256 else { throw AppError.message("Incomplete playback cache file.") }
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
                return temporary
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
    }
}
