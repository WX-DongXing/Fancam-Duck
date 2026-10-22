import XCTest

final class LivePreviewFlowTests:XCTestCase {
    @MainActor func testRedactionRegionCanChangeWhilePreviewIsPlaying() {
        let app=XCUIApplication();app.launchArguments=["--demo-composition"];app.launch()
        let play=app.buttons["editorPlayback"]
        XCTAssertTrue(play.waitForExistence(timeout:15))
        let compositionControlFrame=app.segmentedControls["compositionAspect"].frame
        app.buttons["previewTool-打码"].tap()
        let enabled=app.switches["redactionEnabled"]
        let region=app.segmentedControls["redactionRegion"]
        XCTAssertTrue(region.buttons["人脸"].isSelected)
        region.buttons["全身"].tap()
        XCTAssertTrue(region.buttons["全身"].isSelected)
        XCTAssertEqual(enabled.value as? String,"0","Presetting the range must not enable redaction")
        region.buttons["人脸"].tap()
        let sheet=app.otherElements["floatingPreviewControls"]
        let offFrame=sheet.frame,rangeFrame=region.frame
        if enabled.value as? String != "1" {enabled.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap()}
        XCTAssertEqual(enabled.value as? String,"1")
        XCTAssertEqual(sheet.frame,offFrame,"The switch must not change sheet size or position")
        XCTAssertEqual(region.frame,rangeFrame)
        let style=app.segmentedControls["redactionStyle"]
        let strength=app.sliders["redactionStrength"]
        XCTAssertGreaterThanOrEqual(region.frame.minY-enabled.frame.maxY,11)
        XCTAssertEqual(style.frame.minY-region.frame.maxY,12,accuracy:1)
        XCTAssertGreaterThanOrEqual(strength.frame.minY-style.frame.maxY,11)
        XCTAssertEqual(style.frame.minX,compositionControlFrame.minX,accuracy:1)
        XCTAssertEqual(style.frame.width,compositionControlFrame.width,accuracy:1)
        strength.adjust(toNormalizedSliderPosition:1)
        XCTAssertEqual(strength.value as? String,"100")
        strength.adjust(toNormalizedSliderPosition:0.45)
        XCTAssertTrue((1...99).contains(Int(strength.value as? String ?? "") ?? -1))
        XCTAssertTrue(app.buttons["previewPanelClose"].exists,"Adjusting strength must not dismiss the sheet")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="redaction-spaced-groups";shot.lifetime = .keepAlways;add(shot)
        play.tap()
        XCTAssertEqual(play.label,"暂停预览")
        region.buttons["全身"].tap()
        XCTAssertTrue(region.buttons["全身"].isSelected)
        XCTAssertTrue(app.segmentedControls["redactionStyle"].buttons["贴片"].waitForNonExistence(timeout:3))
        XCTAssertTrue(NSPredicate(format:"label == %@","暂停预览").evaluate(with:play))
        region.buttons["人脸"].tap()
        XCTAssertTrue(region.buttons["人脸"].isSelected)
        play.tap()
        style.buttons["贴片"].tap()
        XCTAssertTrue(app.buttons["redactionSticker-duck"].isHittable)
        app.buttons["redactionSticker-cat"].tap()
        XCTAssertTrue(app.buttons["redactionSticker-cat"].isSelected)
    }

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
        let toolbarY=composition.frame.midY
        composition.tap()
        XCTAssertTrue(close.waitForExistence(timeout:3))
        let panel=app.otherElements["floatingPreviewControls"]
        XCTAssertLessThan(panel.frame.minY,originalTimeline.maxY)
        XCTAssertGreaterThan(panel.frame.maxY,originalTimeline.minY)
        let toolbar=app.otherElements["editorToolbar"]
        let sheetGap=NSPredicate {_,_ in abs(toolbar.frame.minY-panel.frame.maxY-12)<1}
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:sheetGap,object:nil)],timeout:3) == .completed)
        let transportGap=NSPredicate {_,_ in abs(panel.frame.minY-app.buttons["editorPlayback"].frame.maxY-12)<1}
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:transportGap,object:nil)],timeout:3) == .completed)
        let compositionPlaybackY=app.buttons["editorPlayback"].frame.midY
        XCTAssertEqual(composition.frame.midY,toolbarY,accuracy:1)
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
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:sheetGap,object:nil)],timeout:3) == .completed)
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:transportGap,object:nil)],timeout:3) == .completed)
        XCTAssertGreaterThan(play.frame.midY,compositionPlaybackY,"The transport follows the shorter motion panel")
        XCTAssertEqual(app.buttons["previewBackward"].frame.midY,play.frame.midY,accuracy:1)
        XCTAssertEqual(app.buttons["previewForward"].frame.midY,play.frame.midY,accuracy:1)
        app.segmentedControls["motionSpeed"].buttons["灵敏"].tap()
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout:3))
        timeline.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.3))
            .press(forDuration:0.1,thenDragTo:timeline.coordinate(withNormalizedOffset:CGVector(dx:0.6,dy:0.3)))
        XCTAssertEqual(app.scrollViews.count,0)
        play.tap()
        composition.tap()
        let handle=app.buttons["previewPanelClose"]
        let handlePoint=handle.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        handlePoint.press(forDuration:0.1,thenDragTo:handlePoint.withOffset(CGVector(dx:0,dy:22)),
                          withVelocity:.slow,thenHoldForDuration:0.3)
        XCTAssertTrue(handle.exists,"A short drag must rebound instead of dismissing")
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:sheetGap,object:nil)],timeout:3) == .completed)
        handle.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.1,
            thenDragTo:handle.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).withOffset(CGVector(dx:0,dy:150)))
        XCTAssertTrue(handle.waitForNonExistence(timeout:3))
        composition.tap()
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:sheetGap,object:nil)],timeout:3) == .completed)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="floating-panel-covers-timeline";shot.lifetime = .keepAlways;add(shot)
        app.buttons["previewExport"].tap()
        XCTAssertTrue(app.staticTexts["exportTitle"].waitForExistence(timeout:10))
    }
}
