import Foundation

/// A seek position cannot migrate to the next video when a source fails.
public struct MediaResumePosition: Sendable {
    private let mediaID: String?
    private let position: Double

    public init(mediaID: String?, seconds: Double) {
        self.mediaID = mediaID
        position = seconds.isFinite ? max(0, seconds) : 0
    }

    public func seconds(for id: String) -> Double { id == mediaID ? position : 0 }
}

public struct TransferNetworkPolicy: Sendable {
    public let wifiOnly: Bool
    public init(wifiOnly: Bool) { self.wifiOnly = wifiOnly }
    public func canSchedule(isConnected: Bool, isWiFi: Bool) -> Bool { isConnected && (!wifiOnly || isWiFi) }
    public func needsRestart(taskAllowsCellular: Bool) -> Bool { taskAllowsCellular == wifiOnly }
    public func canReuseResumeData(savedWiFiOnly: Bool) -> Bool { savedWiFiOnly == wifiOnly }
}

/// Keep the background wake alive until verification and the next task submissions finish.
public struct BackgroundTransferGate: Sendable {
    private var verifications = Set<String>()
    private var scheduling = Set<String>()
    private var delivered = false
    public init() {}
    public mutating func beginVerification(_ id: String) { verifications.insert(id) }
    public mutating func endVerification(_ id: String) { verifications.remove(id) }
    public mutating func beginScheduling(_ id: String) { scheduling.insert(id) }
    public mutating func endScheduling(_ id: String) { scheduling.remove(id) }
    public mutating func eventsDelivered() { delivered = true }
    public mutating func takeCompletionPermission() -> Bool {
        guard delivered, verifications.isEmpty, scheduling.isEmpty else { return false }
        delivered = false
        return true
    }
}

public struct PlaybackStallTicket: Sendable {
    private let generation: Int
    private let mediaID: String
    private let position: Double
    private let deadline: Date
    public init(generation: Int, mediaID: String, position: Double, deadline: Date) {
        self.generation = generation; self.mediaID = mediaID
        self.position = position; self.deadline = deadline
    }
    public func shouldRecover(generation: Int, mediaID: String?, position: Double, wantsToPlay: Bool, now: Date) -> Bool {
        wantsToPlay && generation == self.generation && mediaID == self.mediaID && now >= deadline
            && position.isFinite && abs(position - self.position) < 0.5
    }
}

public enum CloudAccountSelection {
    public enum SelectionError: Error { case chooseAccount, selectedAccountMissing }
    public static func resolve(selectedID: String?, availableIDs: [String?]) throws -> String? {
        let availableIDs = availableIDs.compactMap { $0 }.filter { !$0.isEmpty }
        if let selectedID {
            guard availableIDs.contains(selectedID) else { throw SelectionError.selectedAccountMissing }
            return selectedID
        }
        guard availableIDs.count <= 1 else { throw SelectionError.chooseAccount }
        return availableIDs.first
    }
}
