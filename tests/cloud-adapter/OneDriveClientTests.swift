import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PlayerCore
@testable import CloudAdapter

private final class FixtureProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var handler: Handler?
    static func use(_ value: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handler = value
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            let handler = Self.handler!
            Self.lock.unlock()
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class OneDriveClientTests: XCTestCase {
    private func client(_ handler: @escaping FixtureProtocol.Handler) -> OneDriveClient {
        FixtureProtocol.use(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        return OneDriveClient(account: MicrosoftAccount(), session: URLSession(configuration: configuration))
    }

    private nonisolated static let catalog = Data(#"{"schemaVersion":1,"libraryId":"cloud-library","updatedAt":"2026-10-17T00:00:00Z","media":[],"playlists":[]}"#.utf8)

    private nonisolated static func catalogResponse(_ request: URLRequest) throws -> (Int, Data) {
        if request.url!.host == "graph.microsoft.com" {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            let filtered = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "$select" }) == true
            if filtered { return (200, Data(#"{"value":[{"id":"catalog","name":"catalog.json"}]}"#.utf8)) }
            return (200, Data(#"{"value":[{"id":"catalog","name":"catalog.json","@microsoft.graph.downloadUrl":"https://content.example.test/catalog"}]}"#.utf8))
        }
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "Bearer credentials must never reach the content host")
        return (200, catalog)
    }

    func testPersonalDrivePlaybackURLIsNotLostToFieldFiltering() async throws {
        let drive = client { request in
            let filtered = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "$select" }) == true
            if filtered { return (200, Data(#"{"id":"asset"}"#.utf8)) }
            return (200, Data(#"{"id":"asset","@microsoft.graph.downloadUrl":"https://content.example.test/video"}"#.utf8))
        }
        let asset = AssetReference(driveID: "drive", itemID: "asset", fileName: "video.mp4", byteSize: 100,
                                   sha256: String(repeating: "a", count: 64), contentType: "video/mp4")
        let url = try await drive.downloadURL(asset)
        XCTAssertEqual(url.absoluteString, "https://content.example.test/video")
    }

    func testPersonalDriveCatalogLoadsAndKeepsCredentialsOffContentHost() async throws {
        let drive = client { try Self.catalogResponse($0) }
        let catalog = try await drive.catalog()
        XCTAssertEqual(catalog.libraryID, "cloud-library")
    }

    func testOptionalQuotaDenialDoesNotPreventCatalogRefresh() async throws {
        let drive = client { request in
            if request.url!.path == "/v1.0/me/drive" { return (403, Data(#"{"error":{"code":"accessDenied"}}"#.utf8)) }
            return try Self.catalogResponse(request)
        }
        let capacity = try await drive.quota()
        XCTAssertFalse(capacity.isEmpty)
        let catalog = try await drive.catalog()
        XCTAssertEqual(catalog.libraryID, "cloud-library")
    }

    func testQuotaAuthenticationFailureIsNotHiddenAsUnavailableCapacity() async {
        let drive = client { _ in (401, Data()) }
        do {
            _ = try await drive.quota()
            XCTFail("Expired or revoked authentication must still require reconnecting")
        } catch { XCTAssertTrue(error.localizedDescription.contains("401")) }
    }
}
