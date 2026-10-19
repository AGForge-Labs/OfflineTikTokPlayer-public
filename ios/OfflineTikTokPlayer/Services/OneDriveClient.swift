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

    private func graph(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0" + path)!
        components.queryItems = query.isEmpty ? nil : query
        for attempt in 0..<3 {
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 15
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
        enum CodingKeys: String, CodingKey { case id, name, downloadURL = "@microsoft.graph.downloadUrl" }
    }
}
