import XCTest

final class AnalysisReviewFlowTests:XCTestCase {
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
        XCTAssertTrue(app.segmentedControls["editorToolbar"].waitForExistence(timeout:10))
        XCTAssertTrue(app.segmentedControls["editorToolbar"].buttons["构图"].isSelected)
        XCTAssertFalse(app.buttons["confirmReviewFrame"].exists)
        XCTAssertEqual(app.scrollViews.count,0)
    }
}
