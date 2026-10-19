import SwiftUI
import MSAL

@main
struct OfflineTikTokPlayerApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView().environment(model).preferredColorScheme(.dark)
                .tint(.cyan)
                .task { model.playback.restore() }
                .task(id: scenePhase == .active && model.network.isConnected) {
                    guard scenePhase == .active, model.network.isConnected, model.account.hasSavedConnection else { return }
                    await model.library.refresh(silently: true)
                }
                .onOpenURL { url in _ = MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil) }
                .onChange(of: scenePhase) { _, phase in if phase != .active { model.playback.persist() } }
        }
    }
}

@MainActor
final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    private static weak var downloads: OfflineDownloads?
    private static var pendingCompletion: (() -> Void)?

    static func attach(_ manager: OfflineDownloads) {
        downloads = manager
        if let pendingCompletion { manager.backgroundCompletion = pendingCompletion; self.pendingCompletion = nil }
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == OfflineDownloads.sessionIdentifier else { completionHandler(); return }
        if let manager = Self.downloads { manager.backgroundCompletion = completionHandler }
        else { Self.pendingCompletion = completionHandler }
    }
}
