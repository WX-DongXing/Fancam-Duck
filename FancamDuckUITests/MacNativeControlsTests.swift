import XCTest

#if targetEnvironment(macCatalyst) || os(macOS)
final class MacNativeControlsTests:XCTestCase {
    @MainActor func testDesktopSharesPhoneControlsAndSizing() throws {
        let app=XCUIApplication()
        app.launchArguments=["--demo-editor"]
        app.launch()
        XCTAssertTrue(app.buttons["dancer1"].waitForExistence(timeout:10))
        app.buttons["dancer1"].click()
        app.buttons["primaryAction"].click()
        XCTAssertTrue(app.buttons["dancer0"].waitForExistence(timeout:15))
        app.buttons["dancer0"].click()
        app.buttons["primaryAction"].click()
        let tools=app.descendants(matching:.any).matching(identifier:"editorToolbar").firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout:15))
        let primary=app.buttons["primaryAction"]
        XCTAssertEqual(tools.frame.height,primary.frame.height,accuracy:1)
        XCTAssertEqual(tools.frame.midY,primary.frame.midY,accuracy:1)
        func option(_ control:XCUIElement,_ title:String) -> XCUIElement {
            control.descendants(matching:.any).matching(NSPredicate(format:"label == %@",title)).firstMatch
        }
        option(tools,"构图").click()
        let aspect=app.descendants(matching:.any).matching(identifier:"compositionAspect").firstMatch
        XCTAssertTrue(aspect.waitForExistence(timeout:5))
        XCTAssertEqual(aspect.frame.height,48,accuracy:1)
        option(aspect,"1:1").click()
        XCTAssertTrue(option(aspect,"1:1").isSelected)
        option(tools,"打码").click()
        let region=app.descendants(matching:.any).matching(identifier:"redactionRegion").firstMatch
        let style=app.descendants(matching:.any).matching(identifier:"redactionStyle").firstMatch
        XCTAssertTrue(region.waitForExistence(timeout:5))
        XCTAssertGreaterThanOrEqual(style.frame.minY-region.frame.maxY,7)
        option(region,"整个人物").click()
        option(style,"马赛克").click()
        XCTAssertTrue(option(region,"整个人物").isSelected)
        XCTAssertTrue(option(style,"马赛克").isSelected)
        let shot=XCTAttachment(screenshot:app.screenshot())
        shot.name="mac-native-redaction-controls";shot.lifetime = .keepAlways;add(shot)
        option(tools,"构图").click()
        XCTAssertTrue(option(aspect,"1:1").isSelected)
    }
}
#endif
