import XCTest

final class AnalysisReviewFlowTests:XCTestCase {
    @MainActor func testLandscapeSelectionAndManualRecoveryRemainReachable() {
        let app=XCUIApplication();app.launchArguments=["--demo-review"];app.launch()
        defer {XCUIDevice.shared.orientation = .portrait}
        XCTAssertTrue(app.buttons["reviewManualSelection"].waitForExistence(timeout:10))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.otherElements["workspaceColumns"].waitForExistence(timeout:5))
        let surface=app.descendants(matching:.any)["sourceVideoSurface"].firstMatch
        XCTAssertGreaterThan(surface.frame.height,80)
        let manual=app.buttons["reviewManualSelection"]
        let controls=app.scrollViews.firstMatch
        if !manual.isHittable {controls.swipeUp()}
        XCTAssertTrue(manual.isHittable);manual.tap()
        let canvas=app.descendants(matching:.any)["manualBox"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout:5))
        XCTAssertGreaterThan(canvas.frame.height,60)
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.2)).press(forDuration:0.1,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.6,dy:0.8)))
        let confirm=app.buttons["确认人物区域"]
        if !confirm.isHittable {controls.swipeUp()}
        XCTAssertTrue(confirm.isHittable);confirm.tap()
        XCTAssertTrue(app.buttons["confirmReviewFrame"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["previewExport"].exists,"Pending identity must still block preview/export")
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="landscape-review-recovery";shot.lifetime = .keepAlways;add(shot)
    }
    @MainActor func testLandscapeInitialSelectionKeepsVideoAndAnalyzeAction() {
        let app=XCUIApplication();app.launchArguments=["--demo-editor"];app.launch()
        defer {XCUIDevice.shared.orientation = .portrait}
        XCTAssertTrue(app.buttons["dancer1"].waitForExistence(timeout:10))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.otherElements["workspaceColumns"].waitForExistence(timeout:5))
        XCTAssertGreaterThan(app.descendants(matching:.any)["sourceVideoSurface"].firstMatch.frame.height,80)
        app.buttons["dancer1"].tap()
        let action=app.buttons["primaryAction"]
        if !action.isHittable {app.scrollViews.firstMatch.swipeUp()}
        XCTAssertTrue(action.isHittable);XCTAssertTrue(action.isEnabled)
    }

    @MainActor func testTimelineReviewAndDirectManualConfirmation() {
        let app=XCUIApplication();app.launchArguments=["--demo-review"];app.launch()
        let first=app.buttons["reviewMarker-1667"],second=app.buttons["reviewMarker-5000"]
        XCTAssertTrue(first.waitForExistence(timeout:10))
        XCTAssertEqual(first.value as? String,"待确认")
        app.buttons["dancer1"].tap();app.buttons["confirmReviewFrame"].tap()
        XCTAssertEqual(first.value as? String,"已确认")
        XCTAssertEqual(second.value as? String,"待确认")
        app.buttons["下一个待确认"].tap()
        app.buttons["手动框选"].tap()
        let canvas=app.descendants(matching:.any).matching(identifier:"manualBox").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout:5))
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.1,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.6,dy:0.6)))
        app.buttons["确认人物区域"].tap()
        XCTAssertTrue(app.buttons["previewTool-构图"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["previewTool-构图"].isSelected)
        XCTAssertTrue(app.staticTexts["预览"].exists)
        XCTAssertFalse(app.staticTexts["视频工作台"].exists)
        XCTAssertFalse(app.buttons["confirmReviewFrame"].exists)
        XCTAssertEqual(app.scrollViews.count,0)
    }
}
