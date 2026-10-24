import XCTest

final class PlayerShellTests: XCTestCase {
    func testLibraryAndPlaybackSettingsAreReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["tab.library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
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
