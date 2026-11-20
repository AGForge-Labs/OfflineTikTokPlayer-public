import Observation
import Foundation
import PlayerCore

enum AppTab: String, CaseIterable { case player = "Player", library = "Library", downloads = "Downloads" }
enum AppSheet: Hashable, Identifiable {
    case settings
    case newPlaylist
    case playlistsForVideo(String)

    var id: Self { self }
}

@MainActor @Observable
final class AppModel {
    let account: MicrosoftAccount
    let cloud: OneDriveClient
    let network: NetworkStatus
    let downloads: OfflineDownloads
    let library: LibraryRepository
    let personal = PersonalLibrary()
    let playback: PlaybackService
    let artwork: ArtworkStore
    var tab = AppTab.library
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
        playback.didPlayMedia = { [weak self] id in self?.personal.recordPlayed(id) }
        DownloadAppDelegate.attach(downloads)
        #if DEBUG && targetEnvironment(simulator)
        // A UI test imports its own short movie on the first of two real process launches.
        let environment = ProcessInfo.processInfo.environment
        if let rawID = environment["SESSION_TEST_MOVIE_ID"], let id = UUID(uuidString: rawID),
           let encoded = environment["SESSION_TEST_MOVIE_DATA"], let movie = Data(base64Encoded: encoded) {
            Task {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Session test \(id.uuidString).mp4")
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    try movie.write(to: url, options: .atomic)
                    try await library.importVideo(url, downloads: downloads)
                } catch { self.alert = error.localizedDescription }
            }
        }
        #endif
    }
}
