import XCTest

final class LivePreviewFlowTests:XCTestCase {
    @MainActor func testDuoPlaybackAndSettingsSurviveClosingAndOpening() throws {
        guard ProcessInfo.processInfo.environment["FANCAM_DUCK_VALIDATE_FOLD_TRANSITION"] == "1" else {
            throw XCTSkip("Requires Device Hub to close and open a Duo during this test")
        }
        let app=XCUIApplication();app.launchArguments=["--demo-composition"];app.launch()
        XCTAssertTrue(app.buttons["previewTool-运镜"].waitForExistence(timeout:15))
        app.buttons["previewTool-运镜"].tap()
        app.segmentedControls["motionSpeed"].buttons["灵敏"].tap()
        let play=app.buttons["editorPlayback"]
        play.tap();XCTAssertEqual(play.label,"暂停预览")
        print("DUO_TRANSITION_READY_TO_CLOSE")
        let closed=NSPredicate {_,_ in app.otherElements["previewWorkspace-outer"].exists}
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:closed,object:nil)],timeout:45) == .completed)
        XCTAssertTrue(app.buttons["previewTool-运镜"].value as? String == "已打开" || app.buttons["previewTool-运镜"].isSelected)
        XCTAssertTrue(app.segmentedControls["motionSpeed"].buttons["灵敏"].isSelected)
        XCTAssertEqual(play.label,"暂停预览")
        print("DUO_TRANSITION_READY_TO_OPEN")
        let opened=NSPredicate {_,_ in app.otherElements["previewWorkspace-wide"].exists}
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:opened,object:nil)],timeout:45) == .completed)
        XCTAssertTrue(app.buttons["previewTool-运镜"].value as? String == "已打开" || app.buttons["previewTool-运镜"].isSelected)
        XCTAssertTrue(app.segmentedControls["motionSpeed"].buttons["灵敏"].isSelected)
        XCTAssertEqual(play.label,"暂停预览")
        play.tap()
    }

    @MainActor func testCurrentPosePreviewPanelsKeepTimelineAndPlaybackReachable() {
        let app=XCUIApplication();app.launchArguments=["--demo-composition"];app.launch()
        XCTAssertTrue(app.buttons["previewTool-构图"].waitForExistence(timeout:15))
        let stage=app.descendants(matching:.any)["editorStage"].firstMatch
        let timeline=app.descendants(matching:.any)["trimTimeline"].firstMatch
        // Duo can report app.frame in the outer display orientation while its scene is on the inner display.
        let workspace=app.otherElements.matching(NSPredicate(format:"identifier BEGINSWITH %@","previewWorkspace-")).firstMatch
        XCTAssertTrue(workspace.exists)
        let originalStage=stage.frame
        for name in ["构图","运镜","打码"] {
            let tool=app.buttons["previewTool-"+name]
            if tool.value as? String != "已打开" && !tool.isSelected {tool.tap()}
            let panel=app.otherElements["floatingPreviewControls"]
            XCTAssertTrue(panel.waitForExistence(timeout:5))
            let timelineOverlay=workspace.identifier != "previewWorkspace-wide"
            let wide=workspace.identifier == "previewWorkspace-wide"
            let toolbar=app.otherElements["editorToolbar"]
            let settled=NSPredicate {_,_ in
                let bounds=workspace.frame.insetBy(dx:-1,dy:-1)
                let aligned = !wide || (abs(panel.frame.minX-toolbar.frame.minX)<1 && abs(panel.frame.maxX-toolbar.frame.maxX)<1 && abs(toolbar.frame.minY-panel.frame.maxY-12)<1)
                return bounds.contains(panel.frame) && aligned &&
                    (timelineOverlay || !panel.frame.insetBy(dx:1,dy:1).intersects(timeline.frame)) &&
                    !panel.frame.insetBy(dx:1,dy:1).intersects(app.buttons["editorPlayback"].frame)
            }
            if workspace.identifier == "previewWorkspace-outer",!toolbar.exists {
                XCTAssertGreaterThanOrEqual(tool.frame.minX,workspace.frame.maxX-1,"System toolbar items belong in the shared side navigation region")
            }
            let frameDetails="workspace=\(workspace.frame) app=\(app.frame) panel=\(panel.frame) tool=\(tool.frame) timeline=\(timeline.frame) play=\(app.buttons["editorPlayback"].frame) stage=\(stage.frame)"
            XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:settled,object:nil)],timeout:5) == .completed,frameDetails)
            if timelineOverlay {
                XCTAssertTrue(panel.frame.intersects(timeline.frame))
                if workspace.identifier != "previewWorkspace-outer" {
                    XCTAssertEqual(toolbar.frame.minY-panel.frame.maxY,12,accuracy:1)
                    XCTAssertEqual(panel.frame.minX,toolbar.frame.minX,accuracy:1)
                    XCTAssertEqual(panel.frame.maxX,toolbar.frame.maxX,accuracy:1)
                }
            } else {XCTAssertTrue(timeline.isHittable)}
            XCTAssertTrue(app.buttons["editorPlayback"].isHittable)
            if ProcessInfo.processInfo.environment["FANCAM_DUCK_EXPECT_HORIZONTAL_FOLD"] == "1" {
                XCTAssertLessThan(app.buttons["editorPlayback"].frame.maxY,workspace.frame.midY)
                XCTAssertGreaterThan(panel.frame.minY,workspace.frame.midY)
            }
            XCTAssertTrue(tool.value as? String == "已打开" || tool.isSelected,"tool=\(name) value=\(String(describing:tool.value)) selected=\(tool.isSelected)")
            XCTAssertEqual(stage.frame,originalStage)
            for (index,screen) in XCUIScreen.screens.enumerated() {
                let shot=XCTAttachment(screenshot:screen.screenshot())
                shot.name="current-pose-"+name+"-screen-"+String(index);shot.lifetime = .keepAlways;add(shot)
            }
            tool.tap()
            XCTAssertTrue(panel.waitForNonExistence(timeout:3))
            XCTAssertTrue(timeline.isHittable)
            XCTAssertEqual(stage.frame,originalStage)
            if wide {
                let centered=NSPredicate {_,_ in abs(app.buttons["editorPlayback"].frame.midX-workspace.frame.midX)<1}
                XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:centered,object:nil)],timeout:3) == .completed)
            }
        }
        app.buttons["previewTool-构图"].tap()
        app.buttons["previewExport"].tap()
        XCTAssertTrue(app.staticTexts["exportTitle"].waitForExistence(timeout:10))
        let export=app.descendants(matching:.any)["exportViewport"].firstMatch
        XCTAssertGreaterThan(export.frame.height,80)
        for (index,screen) in XCUIScreen.screens.enumerated() {
            let shot=XCTAttachment(screenshot:screen.screenshot())
            shot.name="current-pose-export-screen-"+String(index);shot.lifetime = .keepAlways;add(shot)
        }
        app.buttons["返回编辑"].tap()
        XCTAssertTrue(app.buttons["previewTool-构图"].waitForExistence(timeout:5))
    }

    @MainActor func testShortLandscapeSettingsAndExportStayReachable() {
        let app=XCUIApplication();app.launchArguments=["--demo-composition"];app.launch()
        defer {XCUIDevice.shared.orientation = .portrait}
        XCTAssertTrue(app.buttons["previewTool-打码"].waitForExistence(timeout:10))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeReady=NSPredicate {_,_ in app.otherElements["previewWorkspace-outer"].exists || app.otherElements["previewWorkspace-wide"].exists}
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:landscapeReady,object:nil)],timeout:5) == .completed)
        app.buttons["previewTool-打码"].tap()
        let panel=app.otherElements["floatingPreviewControls"]
        XCTAssertTrue(panel.waitForExistence(timeout:5))
        let scroll=app.scrollViews.firstMatch
        if scroll.exists {
            scroll.swipeUp();scroll.swipeDown()
        } else {
            for control in [app.segmentedControls["redactionRegion"],app.segmentedControls["redactionStyle"],app.sliders["redactionStrength"]] {
                XCTAssertTrue(control.isHittable)
                XCTAssertTrue(panel.frame.insetBy(dx:-1,dy:-1).contains(control.frame),"Settings must fit completely when no scroll view is needed")
            }
        }
        XCTAssertTrue(app.buttons["previewPanelClose"].exists,"Scrolling settings must not dismiss the panel")
        XCTAssertTrue(app.frame.insetBy(dx:-1,dy:-1).contains(app.otherElements["floatingPreviewControls"].frame))
        XCTAssertEqual(app.buttons["previewTool-打码"].value as? String,"已打开")
        app.buttons["previewPanelClose"].tap()
        XCTAssertTrue(app.buttons["previewPanelClose"].waitForNonExistence(timeout:3))
        app.buttons["previewExport"].tap()
        XCTAssertTrue(app.staticTexts["exportTitle"].waitForExistence(timeout:10))
        let viewport=app.descendants(matching:.any)["exportViewport"].firstMatch
        XCTAssertGreaterThan(viewport.frame.height,80)
        XCTAssertTrue(app.otherElements["workspaceColumns"].exists)
        let action=app.buttons["primaryAction"]
        if !action.isHittable {app.scrollViews.firstMatch.swipeUp()}
        XCTAssertTrue(action.isHittable)
        XCTAssertTrue(app.frame.insetBy(dx:-1,dy:-1).contains(action.frame))
        action.tap()
        XCTAssertEqual(app.staticTexts["exportTitle"].label,"导出完成")
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="landscape-export-complete";shot.lifetime = .keepAlways;add(shot)
    }

    @MainActor func testAdaptivePreviewKeepsTimelineAndSettingsAcrossRotation() {
        let app=XCUIApplication();app.launchArguments=["--demo-composition"];app.launch()
        defer {XCUIDevice.shared.orientation = .portrait}
        let composition=app.buttons["previewTool-构图"]
        XCTAssertTrue(composition.waitForExistence(timeout:15))
        let aspect=app.segmentedControls["compositionAspect"]
        aspect.buttons["1:1"].tap()
        for orientation in [UIDeviceOrientation.portrait,.landscapeLeft,.portrait] {
            XCUIDevice.shared.orientation=orientation
            let expected=orientation == .landscapeLeft ? ["wide","outer"] : ["phone","portrait"]
            let layoutReady=NSPredicate {_,_ in expected.contains {app.otherElements["previewWorkspace-"+$0].exists}}
            XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:layoutReady,object:nil)],timeout:5) == .completed)
            let timeline=app.descendants(matching:.any)["trimTimeline"].firstMatch
            XCTAssertTrue(timeline.waitForExistence(timeout:5))
            let timelineOverlay = !app.otherElements["previewWorkspace-wide"].exists
            if !timelineOverlay {XCTAssertTrue(timeline.isHittable)}
            XCTAssertTrue(aspect.buttons["1:1"].isSelected)
            let stage=app.descendants(matching:.any)["editorStage"].firstMatch
            let stageFrame=stage.frame
            let visible=NSPredicate {_,_ in
                let bounds=app.frame.insetBy(dx:-1,dy:-1)
                return ["构图","运镜","打码"].allSatisfy {bounds.contains(app.buttons["previewTool-"+$0].frame)}
            }
            XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:visible,object:nil)],timeout:5) == .completed)
            let panel=app.otherElements["floatingPreviewControls"]
            XCTAssertTrue(panel.exists)
            if !timelineOverlay {
                XCTAssertFalse(panel.frame.insetBy(dx:1,dy:1).intersects(timeline.frame),"Settings must leave the timeline accessible")
            }
            XCTAssertFalse(panel.frame.insetBy(dx:1,dy:1).intersects(app.buttons["editorPlayback"].frame),"Playback must stay outside the panel")
            XCTAssertTrue(composition.isHittable)
            composition.tap()
            XCTAssertTrue(panel.waitForNonExistence(timeout:3))
            XCTAssertTrue(timeline.isHittable)
            XCTAssertEqual(stage.frame,stageFrame)
            composition.tap()
            XCTAssertTrue(panel.waitForExistence(timeout:3))
            XCTAssertTrue(aspect.buttons["1:1"].isSelected)
            XCTAssertEqual(stage.frame,stageFrame)
            let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
            shot.name="adaptive-preview-"+String(orientation.rawValue);shot.lifetime = .keepAlways;add(shot)
        }
    }

    @MainActor func testRedactionRegionCanChangeWhilePreviewIsPlaying() {
        let app=XCUIApplication();app.launchArguments=["--demo-composition"];app.launch()
        let play=app.buttons["editorPlayback"]
        XCTAssertTrue(play.waitForExistence(timeout:15))
        let compositionControlFrame=app.segmentedControls["compositionAspect"].frame
        app.buttons["previewTool-打码"].tap()
        let region=app.segmentedControls["redactionRegion"]
        XCTAssertFalse(app.switches["redactionEnabled"].exists)
        XCTAssertEqual(region.buttons.count,3)
        XCTAssertTrue(region.buttons["关闭"].isSelected)
        let sheet=app.otherElements["floatingPreviewControls"]
        let settled=NSPredicate {_,_ in abs(sheet.frame.height-204)<0.01 && abs(region.frame.minY-sheet.frame.minY-28)<0.01}
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:settled,object:nil)],timeout:3) == .completed)
        let offFrame=sheet.frame,rangeFrame=region.frame
        region.buttons["人脸"].tap()
        XCTAssertTrue(region.buttons["人脸"].isSelected)
        XCTAssertEqual(sheet.frame,offFrame)
        XCTAssertEqual(region.frame,rangeFrame)
        let style=app.segmentedControls["redactionStyle"]
        let strength=app.sliders["redactionStrength"]
        XCTAssertEqual(style.frame.minY-region.frame.maxY,12,accuracy:1)
        XCTAssertGreaterThanOrEqual(strength.frame.minY-style.frame.maxY,11)
        XCTAssertEqual(style.frame.minX,compositionControlFrame.minX,accuracy:1)
        XCTAssertEqual(style.frame.width,compositionControlFrame.width,accuracy:1)
        strength.adjust(toNormalizedSliderPosition:1)
        XCTAssertEqual(strength.value as? String,"100")
        strength.adjust(toNormalizedSliderPosition:0.45)
        XCTAssertTrue((1...99).contains(Int(strength.value as? String ?? "") ?? -1))
        XCTAssertTrue(app.buttons["previewPanelClose"].exists,"Adjusting strength must not dismiss the sheet")
        let retainedStrength=strength.value as? String
        region.buttons["关闭"].tap()
        XCTAssertTrue(region.buttons["关闭"].isSelected)
        XCTAssertEqual(sheet.frame,offFrame)
        region.buttons["人脸"].tap()
        XCTAssertEqual(strength.value as? String,retainedStrength)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="redaction-spaced-groups";shot.lifetime = .keepAlways;add(shot)
        play.tap()
        XCTAssertEqual(play.label,"暂停预览")
        region.buttons["关闭"].tap()
        XCTAssertTrue(region.buttons["关闭"].isSelected)
        XCTAssertEqual(play.label,"暂停预览")
        XCTAssertEqual(sheet.frame,offFrame)
        region.buttons["全身"].tap()
        XCTAssertTrue(region.buttons["全身"].isSelected)
        XCTAssertEqual(sheet.frame,offFrame)
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
        let canvas=app.otherElements["editorStage"]
        let originalCanvas=canvas.frame
        let timeline=app.descendants(matching:.any).matching(identifier:"trimTimeline").firstMatch
        let originalTimeline=timeline.frame
        XCTAssertLessThanOrEqual(timeline.frame.maxY,composition.frame.minY)
        let toolbarY=composition.frame.midY
        composition.tap()
        XCTAssertTrue(close.waitForExistence(timeout:3))
        let panel=app.otherElements["floatingPreviewControls"]
        XCTAssertTrue(panel.frame.intersects(originalTimeline))
        let sheetGap=NSPredicate {_,_ in
            abs(app.otherElements["editorToolbar"].frame.minY-panel.frame.maxY-12)<1 && panel.frame.intersects(timeline.frame)
        }
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
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="floating-panel-overlays-timeline";shot.lifetime = .keepAlways;add(shot)
        app.buttons["previewExport"].tap()
        XCTAssertTrue(app.staticTexts["exportTitle"].waitForExistence(timeout:10))
    }
}
