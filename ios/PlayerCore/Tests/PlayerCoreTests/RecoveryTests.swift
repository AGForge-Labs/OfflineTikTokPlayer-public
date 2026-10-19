import XCTest
@testable import PlayerCore

final class RecoveryTests: XCTestCase {
    func testNullableSDKAccountIdentifiersCannotSelectAnUnidentifiedAccount() throws {
        let sdkIDs: [String?] = [nil, "", "chosen"]
        XCTAssertEqual(try CloudAccountSelection.resolve(selectedID: nil, availableIDs: sdkIDs), "chosen")
        XCTAssertNil(try CloudAccountSelection.resolve(selectedID: nil, availableIDs: [nil, ""]))
        XCTAssertThrowsError(try CloudAccountSelection.resolve(selectedID: "", availableIDs: sdkIDs))
    }

    func testSilentAuthenticationUsesTheAccountChosenAtSignIn() throws {
        XCTAssertEqual(try CloudAccountSelection.resolve(selectedID: "chosen", availableIDs: ["other", "chosen"]), "chosen")
        XCTAssertThrowsError(try CloudAccountSelection.resolve(selectedID: "removed", availableIDs: ["other"]))
        XCTAssertThrowsError(try CloudAccountSelection.resolve(selectedID: nil, availableIDs: ["other", "chosen"]))
        XCTAssertEqual(try CloudAccountSelection.resolve(selectedID: nil, availableIDs: ["only"]), "only")
        XCTAssertNil(try CloudAccountSelection.resolve(selectedID: nil, availableIDs: []))
    }

    func testRecoveryPositionBelongsToItsOriginalVideo() {
        let position = MediaResumePosition(mediaID: "cloud", seconds: 90)
        XCTAssertEqual(position.seconds(for: "cloud"), 90)
        // A 30-second local fallback must begin at zero, not seek to the previous video's 90 seconds.
        XCTAssertEqual(position.seconds(for: "local"), 0)
        XCTAssertEqual(MediaResumePosition(mediaID: "cloud", seconds: .nan).seconds(for: "cloud"), 0)
    }

    func testChangingWiFiPolicyRebuildsAnExistingRequestEvenWhileOnWiFi() {
        let restricted = TransferNetworkPolicy(wifiOnly: true)
        XCTAssertTrue(restricted.canSchedule(isConnected: true, isWiFi: true))
        XCTAssertTrue(restricted.needsRestart(taskAllowsCellular: true))
        XCTAssertFalse(restricted.needsRestart(taskAllowsCellular: false))
        XCTAssertFalse(restricted.canReuseResumeData(savedWiFiOnly: false))
        XCTAssertFalse(restricted.canSchedule(isConnected: true, isWiFi: false))
        XCTAssertTrue(TransferNetworkPolicy(wifiOnly: false).needsRestart(taskAllowsCellular: false))
    }

    func testBackgroundWakeRemainsOwnedUntilNextDownloadsHaveBeenScheduled() {
        var gate = BackgroundTransferGate()
        gate.beginVerification("completed")
        gate.eventsDelivered()
        XCTAssertFalse(gate.takeCompletionPermission())
        gate.beginScheduling("next-one")
        gate.beginScheduling("next-two")
        gate.endVerification("completed")
        XCTAssertFalse(gate.takeCompletionPermission())
        gate.endScheduling("next-one")
        XCTAssertFalse(gate.takeCompletionPermission())
        gate.endScheduling("next-two")
        XCTAssertTrue(gate.takeCompletionPermission())
        XCTAssertFalse(gate.takeCompletionPermission())
    }

    func testStaleOrCancelledStallWatchdogCannotSkipAnotherVideo() {
        let now = Date(timeIntervalSince1970: 100)
        let ticket = PlaybackStallTicket(generation: 7, mediaID: "cloud", position: 20, deadline: now.addingTimeInterval(12))
        XCTAssertFalse(ticket.shouldRecover(generation: 7, mediaID: "cloud", position: 20, wantsToPlay: true, now: now.addingTimeInterval(11)))
        XCTAssertTrue(ticket.shouldRecover(generation: 7, mediaID: "cloud", position: 20, wantsToPlay: true, now: now.addingTimeInterval(12)))
        XCTAssertFalse(ticket.shouldRecover(generation: 8, mediaID: "local", position: 0, wantsToPlay: true, now: now.addingTimeInterval(13)))
        XCTAssertFalse(ticket.shouldRecover(generation: 7, mediaID: "cloud", position: 20, wantsToPlay: false, now: now.addingTimeInterval(13)))
        XCTAssertFalse(ticket.shouldRecover(generation: 7, mediaID: "cloud", position: 23, wantsToPlay: true, now: now.addingTimeInterval(13)))
    }
}
