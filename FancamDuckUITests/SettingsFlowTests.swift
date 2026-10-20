import XCTest

final class SettingsFlowTests:XCTestCase {
    @MainActor func testSettingsShowsAboutAndRatingAndReturnsHome() {
        let app=XCUIApplication();app.launch()
        let entry=app.buttons["openSettings"]
        XCTAssertTrue(entry.waitForExistence(timeout:10))
        entry.tap()
        let about=app.buttons["aboutDuck"]
        XCTAssertTrue(about.waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["rateDuck"].isHittable)
        // The row's blank space must navigate, not only its text.
        about.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.5)).tap()
        XCTAssertTrue(app.staticTexts["appVersion"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Fancam Duck"].exists)
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"sourceRepository").firstMatch.isHittable)
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"sourceLicense").firstMatch.isHittable)
        XCTAssertTrue(app.staticTexts["AGPL-3.0-only"].exists)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="about-duck";shot.lifetime = .keepAlways;add(shot)
        app.navigationBars.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["rateDuck"].waitForExistence(timeout:5))
        app.buttons["closeSettings"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["rateDuck"].exists)
    }
}
