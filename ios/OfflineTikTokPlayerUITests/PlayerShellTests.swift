import XCTest

final class PlayerShellTests: XCTestCase {
    func testLibraryAndPlaybackSettingsAreReachable() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["tab.library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.switches["Wi-Fi only"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Automatic Picture in Picture"].exists)
        app.buttons["Done"].tap()
        app.buttons["tab.downloads"].tap()
        XCTAssertTrue(app.buttons["Shuffle downloaded videos"].exists)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Native downloads screen"; proof.lifetime = .keepAlways
        add(proof)
    }
}
