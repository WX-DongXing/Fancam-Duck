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
        let reselect=app.buttons["reselectAnalysis"]
        XCTAssertTrue(reselect.waitForExistence(timeout:3))
        XCTAssertEqual(reselect.frame.height,app.buttons["primaryAction"].frame.height,accuracy:1)
        XCTAssertEqual(reselect.frame.midY,app.buttons["primaryAction"].frame.midY,accuracy:1)
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
        let enabled=app.switches["redactionEnabled"]
        let region=app.buttons["redactionRegionMenu"]
        let style=app.descendants(matching:.any).matching(identifier:"redactionStyle").firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout:5))
        XCTAssertEqual(enabled.value as? String,"0")
        XCTAssertFalse(region.isHittable)
        XCTAssertFalse(app.buttons["开启打码"].exists)
        XCTAssertFalse(app.buttons["打码强度设置"].exists)
        let offSwitchFrame=enabled.frame
        enabled.click()
        XCTAssertEqual(enabled.value as? String,"1")
        XCTAssertTrue(region.waitForExistence(timeout:3))
        XCTAssertTrue(region.isHittable)
        XCTAssertLessThan(enabled.frame.maxX,offSwitchFrame.maxX)
        XCTAssertTrue(app.sliders["redactionStrength"].isHittable)
        app.buttons["redactionHelp"].click()
        XCTAssertTrue(app.staticTexts["对主角外人物进行打码"].waitForExistence(timeout:3))
        app.typeKey(.escape,modifierFlags:[])
        option(style,"贴片").click()
        XCTAssertFalse(app.sliders["redactionStrength"].exists)
        let sticker=app.buttons["redactionSticker-star"]
        XCTAssertTrue(sticker.waitForExistence(timeout:3))
        XCTAssertTrue(sticker.isHittable)
        sticker.click()
        XCTAssertTrue(sticker.isSelected)
        region.click();option(app,"全身").click()
        XCTAssertEqual(region.value as? String,"全身")
        XCTAssertFalse(option(style,"贴片").exists)
        XCTAssertTrue(app.sliders["redactionStrength"].isHittable)
        option(style,"马赛克").click()
        XCTAssertTrue(option(style,"马赛克").isSelected)
        enabled.click()
        XCTAssertFalse(region.isHittable)
        XCTAssertEqual(enabled.frame.maxX,offSwitchFrame.maxX,accuracy:1)
        let shot=XCTAttachment(screenshot:app.screenshot())
        shot.name="mac-native-redaction-controls";shot.lifetime = .keepAlways;add(shot)
        option(tools,"构图").click()
        XCTAssertTrue(option(aspect,"1:1").isSelected)
    }
}
#endif
