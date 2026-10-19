import Network
import Observation

@MainActor @Observable
final class NetworkStatus {
    private(set) var isConnected = false
    private(set) var isWiFi = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    var didChange: (() -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConnected = path.status == .satisfied
                self?.isWiFi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                self?.didChange?()
            }
        }
        monitor.start(queue: DispatchQueue(label: "player.network"))
    }
    deinit { monitor.cancel() }
}
