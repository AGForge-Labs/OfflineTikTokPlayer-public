// Only the platform-specific authentication boundary is replaced. The tested
// OneDriveClient.swift and LibraryRepository.swift are copied verbatim from the
// iPhone app. AppFiles substitutes only platform-specific file protection.
import Foundation

@MainActor
final class MicrosoftAccount {
    func token(forceRefresh: Bool = false) async throws -> String { "fixture-token" }
}

enum AppError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

enum AppFiles {
    static let root = FileManager.default.temporaryDirectory
    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

#if os(Linux)
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}
#endif
