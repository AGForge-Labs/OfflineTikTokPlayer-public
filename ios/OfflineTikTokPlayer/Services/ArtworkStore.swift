import Foundation
import UIKit
import AVFoundation
import PlayerCore

actor ArtworkStore {
    private let cloud: OneDriveClient
    private let cache = NSCache<NSString, UIImage>()
    private let directory = AppFiles.directory("Artwork", excludeFromBackup: true)
    init(cloud: OneDriveClient) { self.cloud = cloud; cache.countLimit = 80; cache.totalCostLimit = 16_000_000 }

    func image(for item: MediaRecord) async -> UIImage? {
        guard let asset = item.artwork else { return nil }
        if let cached = cache.object(forKey: asset.sha256 as NSString) { return cached }
        let path = directory.appendingPathComponent(asset.sha256 + ".jpg")
        var bytes = try? Data(contentsOf: path)
        if bytes == nil {
            guard let url = try? await cloud.downloadURL(asset),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, Int64(data.count) == asset.byteSize else { return nil }
            do {
                try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                guard try AppFiles.hash(path).sha256 == asset.sha256 else { try? FileManager.default.removeItem(at: path); return nil }
                bytes = data
            } catch { return nil }
        }
        guard let bytes, let image = UIImage(data: bytes) else { return nil }
        cache.setObject(image, forKey: asset.sha256 as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}
