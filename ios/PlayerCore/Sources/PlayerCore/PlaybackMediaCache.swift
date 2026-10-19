import Foundation

/// Temporary, verified playback files. Explicit offline downloads have a separate owner.
public actor PlaybackMediaCache {
    /// The loader returns an owned temporary file after checking the catalog checksum.
    public typealias Loader = @Sendable (AssetReference) async throws -> URL
    private struct Entry { let url: URL; let size: Int64; var access: UInt64 }
    private struct Flight { let id: UUID; let size: Int64; let task: Task<URL?, Never> }
    private let directory: URL
    private let byteLimit: Int64
    private let countLimit: Int
    private let loader: Loader
    private var entries: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    private var protected = Set<String>()
    private var revision = -1
    private var access: UInt64 = 0

    public init(directory: URL, byteLimit: Int64 = 256 * 1_024 * 1_024, countLimit: Int = 8,
                loader: @escaping Loader) throws {
        guard byteLimit > 0, countLimit > 0 else { throw CatalogError.invalid("Invalid playback cache size.") }
        self.directory = directory; self.byteLimit = byteLimit; self.countLimit = countLimit; self.loader = loader
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Files from an earlier process are disposable; saved offline videos live elsewhere.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            let name = url.lastPathComponent
            if name.count == 73, name.hasSuffix(".warm.mp4"),
               name.prefix(64).allSatisfy({ "0123456789abcdef".contains($0) }),
               (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    public func setWindow(_ assets: [AssetReference], revision: Int) {
        guard revision >= self.revision else { return }
        self.revision = revision
        protected = Set(assets.map(\.sha256))
        for (hash, flight) in flights where !protected.contains(hash) {
            flight.task.cancel()
            // Cancellation is cooperative. Keep its byte/slot reservation until cleanup ends.
        }
    }

    public func file(for asset: AssetReference) -> URL? {
        guard var entry = entries[asset.sha256], entry.size == asset.byteSize else { return nil }
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            entries.removeValue(forKey: asset.sha256); return nil
        }
        access &+= 1; entry.access = access; entries[asset.sha256] = entry
        return entry.url
    }

    public func prefetch(_ asset: AssetReference, revision: Int) async -> URL? {
        guard revision == self.revision, protected.contains(asset.sha256) else { return nil }
        if let url = file(for: asset) { return url }
        if let flight = flights[asset.sha256] { return await flight.task.value }
        guard (try? asset.validate()) != nil, asset.byteSize <= byteLimit,
              flights.count < 2, makeRoom(for: asset.byteSize) else { return nil }
        let id = UUID(), hash = asset.sha256
        let task = Task { [weak self, loader] () -> URL? in
            let result: URL?
            do {
                let temporary = try await loader(asset)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                result = await self?.install(temporary, asset: asset, id: id)
            } catch { result = nil }
            await self?.finished(hash: hash, id: id)
            return result
        }
        flights[hash] = Flight(id: id, size: asset.byteSize, task: task)
        return await task.value
    }

    private func makeRoom(for size: Int64) -> Bool {
        while entries.values.reduce(0, { $0 + $1.size }) + flights.values.reduce(0, { $0 + $1.size }) > byteLimit - size
                || entries.count + flights.count >= countLimit {
            guard let victim = entries.filter({ !protected.contains($0.key) }).min(by: { $0.value.access < $1.value.access }) else { return false }
            do { try FileManager.default.removeItem(at: victim.value.url) }
            catch { if FileManager.default.fileExists(atPath: victim.value.url.path) { return false } }
            entries.removeValue(forKey: victim.key)
        }
        return true
    }

    private func install(_ temporary: URL, asset: AssetReference, id: UUID) -> URL? {
        guard let flight = flights[asset.sha256], flight.id == id, !flight.task.isCancelled, protected.contains(asset.sha256),
              let size = try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == asset.byteSize else { return nil }
        let url = directory.appendingPathComponent(asset.sha256 + ".warm.mp4")
        do {
            try FileManager.default.moveItem(at: temporary, to: url)
            access &+= 1
            entries[asset.sha256] = Entry(url: url, size: asset.byteSize, access: access)
            return url
        } catch { return nil }
    }
    private func finished(hash: String, id: UUID) {
        if flights[hash]?.id == id { flights.removeValue(forKey: hash) }
    }
}
