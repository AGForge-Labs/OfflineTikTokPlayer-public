import Foundation
import CryptoKit
import PlayerCore

enum AppFiles {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineTikTokPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return base
    }()

    static func directory(_ name: String, excludeFromBackup: Bool = false) -> URL {
        var url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        if excludeFromBackup { var values = URLResourceValues(); values.isExcludedFromBackup = true; try? url.setResourceValues(values) }
        return url
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func hash(_ url: URL) throws -> (size: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(); var size: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data); size += Int64(data.count)
        }
        return (size, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
