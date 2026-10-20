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
        let downloadsHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: downloadsTab)
        XCTAssertEqual(XCTWaiter.wait(for: [downloadsHittable], timeout: 10), .completed,
                       "Downloads tab must be hittable after Settings dismisses")
        downloadsTab.tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Shuffle downloaded videos"].waitForExistence(timeout: 10))
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Native downloads screen"; proof.lifetime = .keepAlways
        add(proof)
    }
}
