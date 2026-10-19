import Observation
import Foundation

enum AppTab: String, CaseIterable { case player = "Player", library = "Library", downloads = "Downloads" }
enum AppSheet: String, Identifiable { case settings; var id: String { rawValue } }

@MainActor @Observable
final class AppModel {
    let account: MicrosoftAccount
    let cloud: OneDriveClient
    let network: NetworkStatus
    let downloads: OfflineDownloads
    let library: LibraryRepository
    let playback: PlaybackService
    let artwork: ArtworkStore
    var tab = AppTab.player
    var sheet: AppSheet?
    var alert: String?

    init() {
        let account = MicrosoftAccount()
        let cloud = OneDriveClient(account: account)
        let network = NetworkStatus()
        let downloads = OfflineDownloads(cloud: cloud, network: network)
        let library = LibraryRepository(cloud: cloud)
        self.account = account; self.cloud = cloud; self.network = network
        self.downloads = downloads; self.library = library
        playback = PlaybackService(library: library, downloads: downloads, cloud: cloud)
        artwork = ArtworkStore(cloud: cloud)
        playback.requestPlayerUI = { [weak self] in self?.tab = .player }
        DownloadAppDelegate.attach(downloads)
    }
}
