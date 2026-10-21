import XCTest

final class LivePreviewFlowTests:XCTestCase {
    @MainActor func testPreviewPlaysAdjustsScrubsAndOpensExportWithoutGenerationButton() {
        let app=XCUIApplication();app.launchArguments=["--demo-composition"];app.launch()
        let composition=app.buttons["previewTool-构图"]
        let motion=app.buttons["previewTool-运镜"]
        let close=app.buttons["previewPanelClose"]
        XCTAssertTrue(close.waitForExistence(timeout:15))
        XCTAssertEqual(composition.value as? String,"已打开")
        XCTAssertFalse(app.segmentedControls["editorToolbar"].exists)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout:3))
        XCTAssertEqual(composition.value as? String,"已关闭")
        let canvas=app.otherElements["analysisZoomCanvas"]
        let originalCanvas=canvas.frame
        let timeline=app.descendants(matching:.any).matching(identifier:"trimTimeline").firstMatch
        let originalTimeline=timeline.frame
        XCTAssertLessThanOrEqual(timeline.frame.maxY,composition.frame.minY)
        composition.tap()
        XCTAssertTrue(close.waitForExistence(timeout:3))
        let panel=app.otherElements["floatingPreviewControls"]
        XCTAssertLessThan(panel.frame.minY,originalTimeline.maxY)
        XCTAssertGreaterThan(panel.frame.maxY,originalTimeline.minY)
        composition.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout:3))
        XCTAssertEqual(canvas.frame.height,originalCanvas.height,accuracy:1)
        XCTAssertEqual(timeline.frame.minY,originalTimeline.minY,accuracy:1)
        let play=app.buttons["editorPlayback"]
        play.tap();XCTAssertEqual(play.label,"暂停预览")
        app.buttons["previewForward"].tap();XCTAssertEqual(play.label,"暂停预览")
        motion.tap()
        XCTAssertEqual(motion.value as? String,"已打开")
        XCTAssertEqual(composition.value as? String,"已关闭")
        app.segmentedControls["motionSpeed"].buttons["灵敏"].tap()
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout:3))
        timeline.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.3))
            .press(forDuration:0.1,thenDragTo:timeline.coordinate(withNormalizedOffset:CGVector(dx:0.6,dy:0.3)))
        XCTAssertEqual(app.scrollViews.count,0)
        play.tap()
        composition.tap()
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="floating-panel-covers-timeline";shot.lifetime = .keepAlways;add(shot)
        app.buttons["previewExport"].tap()
        XCTAssertTrue(app.staticTexts["exportTitle"].waitForExistence(timeout:10))
    }
}
