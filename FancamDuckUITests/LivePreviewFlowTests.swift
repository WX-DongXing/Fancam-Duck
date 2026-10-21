import XCTest

final class LivePreviewFlowTests:XCTestCase {
    @MainActor func testPreviewPlaysAdjustsScrubsAndOpensExportWithoutGenerationButton() {
        let app=XCUIApplication();app.launchArguments=["--demo-composition"];app.launch()
        let tools=app.segmentedControls["editorToolbar"]
        XCTAssertTrue(tools.waitForExistence(timeout:15))
        XCTAssertTrue(app.staticTexts["预览"].exists)
        XCTAssertFalse(app.buttons["生成预览"].exists)
        XCTAssertFalse(app.buttons["primaryAction"].exists)
        let play=app.buttons["editorPlayback"]
        play.tap();XCTAssertEqual(play.label,"暂停预览")
        app.buttons["previewForward"].tap();XCTAssertEqual(play.label,"暂停预览")
        tools.buttons["运镜"].tap()
        app.segmentedControls["motionSpeed"].buttons["灵敏"].tap()
        expectation(for:NSPredicate(format:"label == %@","暂停预览"),evaluatedWith:play)
        waitForExpectations(timeout:10)
        let timeline=app.descendants(matching:.any).matching(identifier:"trimTimeline").firstMatch
        timeline.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.3))
            .press(forDuration:0.1,thenDragTo:timeline.coordinate(withNormalizedOffset:CGVector(dx:0.6,dy:0.3)))
        expectation(for:NSPredicate(format:"label == %@","暂停预览"),evaluatedWith:play)
        waitForExpectations(timeout:10)
        XCTAssertEqual(app.scrollViews.count,0)
        play.tap()
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="live-preview";shot.lifetime = .keepAlways;add(shot)
        app.buttons["previewExport"].tap()
        XCTAssertTrue(app.staticTexts["exportTitle"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["exportBack"].exists)
    }
}
