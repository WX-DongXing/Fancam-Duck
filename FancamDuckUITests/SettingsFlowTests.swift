import XCTest

final class SettingsFlowTests:XCTestCase {
    @MainActor func testSettingsShowsAboutAndRatingAndReturnsHome() {
        let app=XCUIApplication();app.launch()
        let entry=app.buttons["openSettings"]
        XCTAssertTrue(entry.waitForExistence(timeout:10))
        let settingsSize=entry.frame.size
        entry.tap()
        let about=app.buttons["aboutDuck"]
        XCTAssertTrue(about.waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["rateDuck"].isHittable)
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"privacyPolicy").firstMatch.isHittable)
        // The row's blank space must navigate, not only its text.
        about.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.5)).tap()
        XCTAssertTrue(app.staticTexts["appVersion"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Fancam Duck"].exists)
        XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"sourceRepository").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"sourceLicense").firstMatch.exists)
        XCTAssertTrue(app.staticTexts["将群舞变成你的个人直拍"].waitForExistence(timeout:5))
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="about-duck";shot.lifetime = .keepAlways;add(shot)
        let back=app.navigationBars.buttons["设置"]
        XCTAssertEqual(settingsSize.width,back.frame.width,accuracy:1)
        XCTAssertEqual(settingsSize.height,back.frame.height,accuracy:1)
        back.tap()
        XCTAssertTrue(app.buttons["rateDuck"].waitForExistence(timeout:5))
        app.buttons["closeSettings"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["rateDuck"].exists)
    }
    @MainActor func testOfflineLicenses() {
        let app=XCUIApplication();app.launch()
        let settings=app.buttons["openSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout:10));settings.tap()
        app.buttons["openSourceLicenses"].tap()
        XCTAssertFalse(app.descendants(matching:.any)["versionSource"].exists)
        for (file,notice) in [("AGPL-3.0","GNU AFFERO GENERAL PUBLIC LICENSE"),
                              ("Ultralytics-AGPL","GNU AFFERO GENERAL PUBLIC LICENSE"),
                              ("OSNet-MIT","Copyright (c) 2018 Kaiyang Zhou"),
                              ("TrackTrack-MIT","Copyright (c) 2024 Kyujin Shim")] {
            let row=app.buttons["license-\(file)"]
            for _ in 0..<4 {
                if row.exists && row.isHittable {break}
                app.swipeUp()
            }
            XCTAssertTrue(row.waitForExistence(timeout:5));row.tap()
            let text=app.staticTexts["offlineLicenseText"]
            XCTAssertTrue(text.waitForExistence(timeout:5))
            XCTAssertTrue(text.label.contains(notice))
            app.navigationBars.buttons["开源许可"].tap()
        }
    }

}
