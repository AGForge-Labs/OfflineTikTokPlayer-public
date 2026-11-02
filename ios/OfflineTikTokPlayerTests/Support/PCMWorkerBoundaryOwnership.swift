import Foundation
import Synchronization
import PlayerCore
@testable import OfflineTikTokPlayer

#if DEBUG
enum PCMWorkerBoundaryOwnership {
    struct Retained: @unchecked Sendable {
        let decoder: ContinuousPCMDecoder, renderer: ContinuousPCMRenderer
        let gate: ContinuousPCMDecoder.DebugNativeReadGate, directory: URL
    }
    static let unresolved = Mutex<Retained?>(nil)
    static var blocksFixtures: Bool { unresolved.withLock { $0 != nil } }
}
#endif
