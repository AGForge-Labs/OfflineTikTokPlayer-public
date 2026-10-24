import XCTest

final class PlayerShellTests: XCTestCase {
    func testLibraryAndPlaybackSettingsAreReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["tab.library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        // The native borderless List button exposes its rendered label; wrappers
        // can carry a different accessibility identifier from that actual button.
        let audioOnly = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Audio only'")).firstMatch
        XCTAssertTrue(audioOnly.waitForExistence(timeout: 5))
        if audioOnly.label == "Audio only, On" {
            audioOnly.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Audio only, Off'"), object: audioOnly)], timeout: 5), .completed)
        }
        audioOnly.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Audio only, On'"), object: audioOnly)], timeout: 5), .completed)
        let audioProof = XCTAttachment(screenshot: app.screenshot())
        audioProof.name = "Library Audio only switch"; audioProof.lifetime = .keepAlways
        add(audioProof)
        app.buttons["tab.player"].tap()
        app.buttons["tab.library"].tap()
        XCTAssertEqual(audioOnly.label, "Audio only, Off", "Opening Player explicitly restores video")
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.switches["Wi-Fi only"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Automatic Picture in Picture"].exists)
        app.buttons["Done"].tap()

        // The underlying tab exists while the sheet is dismissing, but cannot be tapped yet.
        let settingsDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["Settings"])
        XCTAssertEqual(XCTWaiter.wait(for: [settingsDismissed], timeout: 10), .completed,
                       "Settings must dismiss before navigating to Downloads")
        let downloadsTab = app.buttons["tab.downloads"]
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 10))
        // Require the real action and its destination. The failed run's movie
        // shows Settings already gone while a separate KVC predicate timed out.
        downloadsTab.tap()
        let reachedDownloads = app.navigationBars["Downloads"].waitForExistence(timeout: 10)
        if !reachedDownloads {
            print("DownloadsNavigationFailure " + app.debugDescription)
            let failure = XCTAttachment(screenshot: app.screenshot())
            failure.name = "After actual Downloads tap"; failure.lifetime = .keepAlways
            add(failure)
        }
        XCTAssertTrue(reachedDownloads, "A real Downloads tap must open its screen after Settings closes")
        XCTAssertTrue(app.buttons["Shuffle downloaded videos"].waitForExistence(timeout: 10))
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Native downloads screen"; proof.lifetime = .keepAlways
        add(proof)
    }
}
