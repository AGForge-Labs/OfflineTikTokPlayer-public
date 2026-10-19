import Foundation
import MSAL
import UIKit
import Observation
import PlayerCore

@MainActor @Observable
final class MicrosoftAccount {
    var clientID: String {
        didSet {
            guard clientID != oldValue else { return }
            UserDefaults.standard.set(clientID, forKey: "microsoftClientID")
            UserDefaults.standard.removeObject(forKey: "microsoftAccountID")
            application = nil; username = nil
        }
    }
    private(set) var username: String?
    private var application: MSALPublicClientApplication?
    private let scopes = ["Files.ReadWrite.AppFolder"]
    var hasSavedConnection: Bool { UserDefaults.standard.string(forKey: "microsoftAccountID") != nil }

    init() {
        let bundledID = Bundle.main.object(forInfoDictionaryKey: "MicrosoftClientID") as? String
        clientID = UserDefaults.standard.string(forKey: "microsoftClientID") ?? bundledID ?? ""
    }

    private func app() throws -> MSALPublicClientApplication {
        if let application { return application }
        guard UUID(uuidString: clientID) != nil else { throw AppError.message("Enter the Microsoft application ID from your private app registration.") }
        let authority = try MSALAADAuthority(url: URL(string: "https://login.microsoftonline.com/consumers")!)
        let config = MSALPublicClientApplicationConfig(clientId: clientID,
            redirectUri: "msauth.dev.galaxybigbird.OfflineTikTokPlayer://auth", authority: authority)
        config.cacheConfig.keychainSharingGroup = "com.microsoft.adalcache"
        let result = try MSALPublicClientApplication(configuration: config)
        application = result
        return result
    }

    func connect() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            throw AppError.message("Open the app before signing in.")
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        let web = MSALWebviewParameters(authPresentationViewController: presenter)
        let params = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: web)
        params.promptType = .selectAccount
        let result: MSALResult = try await withCheckedThrowingContinuation { continuation in
            do {
                try app().acquireToken(with: params) { result, error in
                    if let result { continuation.resume(returning: result) }
                    else { continuation.resume(throwing: error ?? AppError.message("Microsoft sign-in did not finish.")) }
                }
            } catch { continuation.resume(throwing: error) }
        }
        guard let identifier = result.account.identifier, !identifier.isEmpty else {
            throw AppError.message("Microsoft did not provide an account identity. Try signing in again.")
        }
        username = result.account.username
        UserDefaults.standard.set(identifier, forKey: "microsoftAccountID")
    }

    func token(forceRefresh: Bool = false) async throws -> String {
        let client = try app()
        let accounts = try client.allAccounts()
        let selected: String?
        do {
            selected = try CloudAccountSelection.resolve(selectedID: UserDefaults.standard.string(forKey: "microsoftAccountID"),
                                                          availableIDs: accounts.map(\.identifier))
        } catch { throw AppError.message("Choose your Microsoft account again in Settings before connecting to your cloud library.") }
        guard let selected, let account = accounts.first(where: { $0.identifier == selected }) else {
            throw AppError.message("Connect your Microsoft account in Settings. Offline copies are still available.")
        }
        let params = MSALSilentTokenParameters(scopes: scopes, account: account)
        params.forceRefresh = forceRefresh
        let result: MSALResult = try await withCheckedThrowingContinuation { continuation in
            client.acquireTokenSilent(with: params) { result, error in
                if let result { continuation.resume(returning: result) }
                else { continuation.resume(throwing: error ?? AppError.message("Sign in to Microsoft again to refresh your cloud library.")) }
            }
        }
        username = result.account.username
        UserDefaults.standard.set(selected, forKey: "microsoftAccountID")
        return result.accessToken
    }
}

enum AppError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
