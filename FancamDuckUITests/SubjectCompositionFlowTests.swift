import XCTest

final class SubjectCompositionFlowTests:XCTestCase {
    @MainActor func testSubjectControlsAndTimelineStayConsistent() throws {
        let app=XCUIApplication();app.launchArguments=["--demo-composition"];app.launch()
        let status=app.descendants(matching:.any).matching(identifier:"compositionStatus").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout:15))
        let horizontal=app.buttons["构图水平居中"],vertical=app.buttons["构图垂直居中"]
        expectation(for:NSPredicate(format:"selected == true"),evaluatedWith:horizontal)
        waitForExpectations(timeout:10)
        // The drawn person fills 65% of the source: fill-first cannot reach 60%.
        XCTAssertFalse(vertical.isSelected)
        XCTAssertTrue(status.label.contains("65%"))
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"selectedTargetFrame").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["拖动位置 · 双指缩放"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format:"label BEGINSWITH '原片边缘限制'")).firstMatch.exists)
        XCTAssertEqual(app.scrollViews.count,0)
        func activate(_ element:XCUIElement) {
            #if targetEnvironment(macCatalyst) || os(macOS)
            element.click()
            #else
            element.tap()
            #endif
        }
        func capture(_ name:String) {
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name=name;shot.lifetime = .keepAlways;add(shot)
        }
        capture("subject-composition-default")
        for _ in 0..<3 {activate(app.buttons["构图放大"])}
        activate(app.buttons["构图放大"])
        expectation(for:NSPredicate(format:"label CONTAINS '88%'"),evaluatedWith:status)
        waitForExpectations(timeout:10)
        XCTAssertTrue(horizontal.isSelected);XCTAssertTrue(vertical.isSelected)
        let canvas=app.descendants(matching:.any).matching(identifier:"compositionCanvas").firstMatch
        let point=canvas.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        point.press(forDuration:0.1,thenDragTo:point.withOffset(CGVector(dx:18,dy:12)))
        XCTAssertFalse(horizontal.isSelected);XCTAssertFalse(vertical.isSelected)
        activate(horizontal)
        expectation(for:NSPredicate(format:"selected == true"),evaluatedWith:horizontal)
        waitForExpectations(timeout:10)
        XCTAssertFalse(vertical.isSelected)
        activate(vertical)
        expectation(for:NSPredicate(format:"selected == true"),evaluatedWith:vertical)
        waitForExpectations(timeout:10)
        capture("subject-composition-adjusted")
        let timeline=app.descendants(matching:.any).matching(identifier:"trimTimeline").firstMatch
        let readout=status.label
        timeline.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.3)).tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"selectedTargetFrame").firstMatch.exists)
        XCTAssertTrue(status.label.contains("88%"))
        activate(app.buttons["构图缩小"])
        expectation(for:NSPredicate(format:"label CONTAINS '80%'"),evaluatedWith:status)
        waitForExpectations(timeout:10)
        timeline.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.3)).tap()
        XCTAssertNotEqual(status.label,readout)
        XCTAssertTrue(status.label.contains("80%"))
        capture("subject-composition-timeline")
        #if !targetEnvironment(macCatalyst) && !os(macOS)
        let beforePinch=status.label
        canvas.pinch(withScale:1.2,velocity:1)
        XCTAssertNotEqual(status.label,beforePinch)
        capture("subject-composition-pinch")
        #endif
        let tools=app.segmentedControls["editorToolbar"]
        #if !targetEnvironment(macCatalyst) && !os(macOS)
        if app.windows.firstMatch.frame.width<600 {
            var motionTopGap:CGFloat?
            for tool in ["运镜","构图","打码"] {
                activate(tools.buttons[tool])
                let card=app.descendants(matching:.any).matching(identifier:"adjustmentPanel").firstMatch
                XCTAssertTrue(card.waitForExistence(timeout:5))
                // The native AX frame can exclude the glass panel's 12pt inset.
                let bottomGap=tools.frame.minY-card.frame.maxY
                XCTAssertGreaterThanOrEqual(bottomGap,12)
                XCTAssertLessThanOrEqual(bottomGap,28)
                let topGap=card.frame.minY-timeline.frame.maxY
                if let motionTopGap {XCTAssertEqual(topGap,motionTopGap,accuracy:3)} else {motionTopGap=topGap}
                capture("subject-panel-"+tool)
            }
        }
        #endif
        activate(tools.buttons["打码"])
        capture("subject-redaction-padding")
        let redaction=app.segmentedControls["redactionRegion"]
        activate(redaction.buttons["人脸"])
        XCTAssertTrue(redaction.buttons["人脸"].isSelected)
        capture("subject-redaction-theme")
        XCTAssertTrue(app.buttons["previewExport"].isHittable)
        activate(tools.buttons["构图"])
        for button in [horizontal,vertical,app.buttons["构图放大"],app.buttons["previewExport"]] {
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height,44)
        }
    }
}
