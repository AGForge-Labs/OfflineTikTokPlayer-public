import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
import Observation
import PlayerCore

@MainActor @Observable
final class LibraryRepository {
    private(set) var catalog: LibraryCatalog
    private(set) var isRefreshing = false
    var message: String?
    private let fetchCatalog: @MainActor () async throws -> LibraryCatalog
    private let url: URL
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var reportRefreshErrors = false

    init(cloud: OneDriveClient, catalogURL: URL = AppFiles.root.appendingPathComponent("catalog.json"),
         fetchCatalog: (@MainActor () async throws -> LibraryCatalog)? = nil) {
        self.url = catalogURL
        self.fetchCatalog = fetchCatalog ?? { try await cloud.catalog() }
        if let data = try? Data(contentsOf: url), let saved = try? LibraryCatalog.decode(data) { catalog = saved }
        else { catalog = try! LibraryCatalog(libraryID: "local:" + UUID().uuidString, media: [], playlists: []) }
    }

    func refresh(silently: Bool = false) async {
        if !silently { reportRefreshErrors = true }
        if let refreshTask { await refreshTask.value; return }
        isRefreshing = true
        reportRefreshErrors = !silently
        // The operation belongs to the repository, so an inactive SwiftUI scene
        // cannot cancel it and discard the next foreground caller's refresh.
        let task = Task { [self] in
            defer { isRefreshing = false; refreshTask = nil; reportRefreshErrors = false }
            do { try install(await fetchCatalog()); message = nil }
            catch is CancellationError { }
            catch { if reportRefreshErrors { message = "Could not refresh: \(error.localizedDescription)" } }
        }
        refreshTask = task
        await task.value
    }

    func install(_ replacement: LibraryCatalog) throws {
        guard catalog.libraryID == replacement.libraryID || catalog.libraryID.hasPrefix("local:") || catalog.media.isEmpty else {
            throw AppError.message("This catalog belongs to a different library. Use the original Microsoft account.")
        }
        // Locally added videos remain available when the cloud catalog is refreshed.
        let remoteIDs = Set(replacement.media.map(\.id))
        let local = catalog.media.filter { $0.id.hasPrefix("local:") && !remoteIDs.contains($0.id) }
        let localLists = catalog.playlists.filter { $0.id.hasPrefix("local:") }
        let result = try LibraryCatalog(libraryID: replacement.libraryID, media: replacement.media + local,
            playlists: replacement.playlists + localLists.filter { list in !replacement.playlists.contains(where: { $0.id == list.id }) }, updatedAt: replacement.updatedAt)
        try AppFiles.save(result, to: url); catalog = result
    }

    #if canImport(AVFoundation)
    func importVideo(_ source: URL, downloads: OfflineDownloads) async throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isPlayable) else { throw AppError.message("This file cannot be played on your iPhone.") }
        let duration = try await asset.load(.duration).seconds
        let (id, _) = try await downloads.importLocal(source)
        guard catalog.mediaByID[id] == nil else { return }
        let item = MediaRecord(id: id, title: source.deletingPathExtension().lastPathComponent,
            creator: "On your iPhone", duration: duration.isFinite ? duration : 0)
        var lists = catalog.playlists
        if let index = lists.firstIndex(where: { $0.id == "local:videos" }) { lists[index].itemIDs.append(id) }
        else { lists.append(PlaylistRecord(id: "local:videos", name: "On your iPhone", itemIDs: [id])) }
        let next = try LibraryCatalog(libraryID: catalog.libraryID, media: catalog.media + [item], playlists: lists)
        try AppFiles.save(next, to: url); catalog = next
    }
    #endif

    func importCatalog(_ source: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try install(LibraryCatalog.decode(Data(contentsOf: source)))
    }
}
