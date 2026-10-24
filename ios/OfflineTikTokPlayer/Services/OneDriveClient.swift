import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PlayerCore

actor OneDriveClient {
    private struct GraphFailure: LocalizedError {
        let statusCode: Int
        var errorDescription: String? {
            statusCode == 404 ? "This file is no longer available in OneDrive." : "OneDrive request failed (\(statusCode))."
        }
    }
    private let account: MicrosoftAccount
    private let session: URLSession
    private let cache = AssetURLCache()
    init(account: MicrosoftAccount, session: URLSession = .shared) { self.account = account; self.session = session }

    private func graph(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> Data {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0" + path)!
        components.queryItems = query.isEmpty ? nil : query
        for attempt in 0..<3 {
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 15
            request.httpMethod = method; request.httpBody = body
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            request.setValue("Bearer " + (try await account.token(forceRefresh: attempt > 0)), forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AppError.message("OneDrive returned no response.") }
            if http.statusCode == 401, attempt == 0 { continue }
            if [429, 503].contains(http.statusCode), attempt < 2 {
                let delay = min(10, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "2") ?? 2))
                try await Task.sleep(for: .seconds(delay)); continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw GraphFailure(statusCode: http.statusCode)
            }
            return data
        }
        throw AppError.message("OneDrive is busy. Try again shortly.")
    }

    private nonisolated func segment(_ text: String) throws -> String {
        guard !text.isEmpty, text != ".", text != "..",
              let value = text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))) else {
            throw AppError.message("Invalid OneDrive item identity.")
        }
        return value
    }

    func downloadURL(_ asset: AssetReference, forceRefresh: Bool = false) async throws -> URL {
        try await cache.resolve(asset, forceRefresh: forceRefresh) { [self] ref in
            let path = try "/drives/" + segment(ref.driveID) + "/items/" + segment(ref.itemID)
            // Personal OneDrive can omit the download annotation under a field filter.
            let data = try await graph(path)
            let item = try JSONDecoder().decode(DriveItem.self, from: data)
            guard let url = item.downloadURL, url.scheme == "https" else { throw AppError.message("OneDrive did not provide a playable download link.") }
            return url
        }
    }

    func catalog() async throws -> LibraryCatalog {
        let children = try JSONDecoder().decode(Children.self, from: await graph("/me/drive/special/approot/children"))
        guard let item = children.value.first(where: { $0.name == "catalog.json" }), let url = item.downloadURL, url.scheme == "https" else {
            throw AppError.message("Upload your selected playlist from the Windows helper first.")
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AppError.message("The catalog download was interrupted. Try Refresh again.") }
        return try LibraryCatalog.decode(data)
    }

    /// Ask the PC that owns the TikTok session; never move that session to the phone.
    func requestTikTokRefresh(libraryID: String, wait: Duration = .seconds(120), pollEvery: Duration = .seconds(3)) async throws -> String {
        guard !libraryID.isEmpty, !libraryID.hasPrefix("local:") else {
            throw AppError.message("Connect your private OneDrive library first.")
        }
        let request = ImportRequest(libraryId: libraryID, requestedAt: Date().timeIntervalSince1970)
        let content = try JSONEncoder().encode(request)
        struct WrittenFile: Decodable { let size: Int }
        let written = try JSONDecoder().decode(WrittenFile.self, from: await graph(
            "/me/drive/special/approot:/refresh-request.json:/content", method: "PUT", body: content))
        guard written.size == content.count else { throw AppError.message("OneDrive did not confirm the TikTok check request. Try again.") }
        let deadline = ContinuousClock.now.advanced(by: wait)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let data = try await refreshReply(), let reply = try? JSONDecoder().decode(ImportStatus.self, from: data),
               reply.version == 1, reply.requestId == request.requestId, reply.libraryId == libraryID,
               reply.requestedAt == request.requestedAt, reply.updatedAt.isFinite,
               reply.updatedAt >= request.requestedAt - 300, reply.updatedAt <= Date().timeIntervalSince1970 + 300 {
                if reply.phase == "completed", let count = reply.newItems, (0...1_000_000).contains(count) {
                    return count == 0 ? "TikTok checked. No new videos found." : "Imported \(count) new video\(count == 1 ? "" : "s") from TikTok."
                }
                if reply.phase == "failed" {
                    let reason = String((reply.error ?? "Retry in the Windows helper.").prefix(700))
                        .replacingOccurrences(of: "https?://\\S+", with: "[service URL]", options: .regularExpression)
                    throw AppError.message("TikTok check did not finish: " + reason)
                }
            }
            try await Task.sleep(for: max(.zero, min(pollEvery, ContinuousClock.now.duration(to: deadline))))
        }
        return "TikTok check queued for your PC. Keep the helper running and your PC awake; reopen the app after it finishes."
    }

    private func refreshReply() async throws -> Data? {
        let data: Data
        do { data = try await graph("/me/drive/special/approot:/refresh-status.json") }
        catch let error as GraphFailure where error.statusCode == 404 { return nil }
        let item = try JSONDecoder().decode(DriveItem.self, from: data)
        guard let size = item.size, (1...8192).contains(size), let url = item.downloadURL, url.scheme == "https" else {
            throw AppError.message("The helper's refresh reply is invalid. Retry in the Windows helper.")
        }
        var download = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        download.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (content, response) = try await session.data(for: download)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, content.count <= 8192 else {
            throw AppError.message("The helper's refresh reply could not be read. Try again shortly.")
        }
        return content
    }

    private struct ImportRequest: Encodable {
        let version = 1
        let requestId = UUID().uuidString
        let libraryId: String
        let requestedAt: Double
    }
    private struct ImportStatus: Decodable {
        let version: Int
        let requestId: String
        let libraryId: String
        let requestedAt: Double
        let updatedAt: Double
        let phase: String
        let newItems: Int?
        let error: String?
    }

    func quota() async throws -> String {
        struct Drive: Decodable { struct Quota: Decodable { let remaining: Int64? }; let quota: Quota? }
        do {
            let drive = try JSONDecoder().decode(Drive.self, from: await graph("/me/drive", query: [URLQueryItem(name: "$select", value: "quota")]))
            guard let remaining = drive.quota?.remaining else { return "Capacity is reported by OneDrive." }
            return ByteCountFormatter.string(fromByteCount: remaining, countStyle: .file) + " available in OneDrive"
        } catch let error as GraphFailure where error.statusCode == 403 {
            // The app-folder grant does not always expose drive-level capacity.
            return "Capacity is reported by OneDrive. Your private library is connected."
        }
    }

    private struct Children: Decodable { let value: [DriveItem] }
    private struct DriveItem: Decodable {
        let id: String
        let name: String?
        let downloadURL: URL?
        let size: Int?
        enum CodingKeys: String, CodingKey { case id, name, size, downloadURL = "@microsoft.graph.downloadUrl" }
    }
}
