#if !targetEnvironment(macCatalyst) && !os(macOS)
import XCTest

final class EditorFlowTests: XCTestCase {
    @MainActor private func launch(ratio: String? = nil) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--demo-editor"]
        if let ratio { app.launchEnvironment["FANCAM_DUCK_UI_RATIO"] = ratio }
        app.launch(); XCTAssertTrue(app.buttons["dancer1"].waitForExistence(timeout: 10)); return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func ready(_ button: XCUIElement) {
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button); waitForExpectations(timeout: 12)
    }
    @MainActor func testOverlappingPeopleAutomaticallyOfferSelectableThumbnails() throws {
        let app=XCUIApplication()
        app.launchArguments=["--demo-editor"]
        app.launchEnvironment["FANCAM_DUCK_UI_OVERLAP"]="1"
        app.launch()
        let first=app.buttons["overlapPerson-1"],second=app.buttons["overlapPerson-2"]
        XCTAssertTrue(first.waitForExistence(timeout:8))
        XCTAssertTrue(second.isHittable)
        XCTAssertLessThanOrEqual(first.frame.width,48)
        XCTAssertLessThanOrEqual(first.frame.height,58)
        XCTAssertFalse(app.staticTexts["人物重叠，点选缩略图"].exists)
        second.tap()
        XCTAssertTrue(second.isSelected)
        XCTAssertFalse(first.isSelected)
        XCTAssertTrue(app.buttons["primaryAction"].isEnabled)
        let selected=app.descendants(matching:.any).matching(identifier:"selectedTargetFrame").firstMatch
        XCTAssertEqual(selected.frame.midX,app.buttons["dancer2"].frame.midX,accuracy:2)
        first.tap()
        XCTAssertTrue(first.isSelected)
        XCTAssertFalse(second.isSelected)
        XCTAssertEqual(selected.frame.midX,app.buttons["dancer1"].frame.midX,accuracy:2)
        capture(app,"automatic-overlap-thumbnails")
    }
    @MainActor func testAnalysisZoomKeepsSelectionAlignedAndResets() throws {
        let app=launch()
        let person=app.buttons["dancer1"]
        let initial=person.frame
        let canvas=app.descendants(matching:.any).matching(identifier:"analysisZoomCanvas").firstMatch
        XCTAssertTrue(canvas.exists)
        XCTAssertFalse(app.buttons["resetAnalysisZoom"].exists)
        canvas.pinch(withScale:2,velocity:1)
        let reset=app.buttons["resetAnalysisZoom"]
        XCTAssertTrue(reset.waitForExistence(timeout:3))
        XCTAssertGreaterThan(person.frame.width,initial.width*1.4)
        person.tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"selectedTargetFrame").firstMatch.exists)
        let play=app.buttons["editorPlayback"]
        XCTAssertEqual(reset.frame.midY,play.frame.midY,accuracy:1)
        XCTAssertGreaterThan(reset.frame.minX,play.frame.maxX)
        reset.tap()
        XCTAssertTrue(person.waitForExistence(timeout:3))
        XCTAssertEqual(person.frame.width,initial.width,accuracy:2)
        XCTAssertFalse(reset.exists)
        XCTAssertTrue(app.buttons["primaryAction"].isEnabled)
        capture(app,"analysis-zoom-reset")
    }
    @MainActor func testReselectAnalysisRequiresNewPersonSelection() throws {
        let app=launch();app.buttons["dancer1"].tap();app.buttons["primaryAction"].tap()
        let reselect=app.buttons["重新选择"]
        XCTAssertTrue(reselect.waitForExistence(timeout:3))
        reselect.coordinate(withNormalizedOffset:CGVector(dx:0.08,dy:0.5)).tap()
        XCTAssertTrue(app.buttons["dancer2"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["primaryAction"].isEnabled)
        XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"selectedTargetFrame").firstMatch.exists)
        app.buttons["dancer2"].tap();XCTAssertTrue(app.buttons["primaryAction"].isEnabled)
        capture(app,"analysis-reselect-new-target")
    }
    @MainActor func testManualBoxNudgesAndJoystickStopsOnRelease() throws {
        let app=launch();app.buttons["dancer1"].tap();app.buttons["primaryAction"].tap()
        XCTAssertTrue(app.buttons["dancer0"].waitForExistence(timeout:15))
        app.buttons["手动框选人物"].tap()
        let box=app.descendants(matching:.any).matching(identifier:"manualBox").firstMatch
        let right=app.buttons["manualNudge-right"]
        guard right.waitForExistence(timeout:3) else {return XCTFail("Missing manual positioning controls")}
        let initial=box.frame
        right.tap();XCTAssertGreaterThan(box.frame.midX,initial.midX)
        app.buttons["manualNudge-left"].tap()
        XCTAssertEqual(box.frame.midX,initial.midX,accuracy:1)
        app.buttons["manualNudge-up"].tap();XCTAssertLessThan(box.frame.midY,initial.midY)
        app.buttons["manualNudge-down"].tap()
        XCTAssertEqual(box.frame.midY,initial.midY,accuracy:1)
        let joystick=app.descendants(matching:.any).matching(identifier:"manualJoystick").firstMatch
        XCTAssertGreaterThanOrEqual(right.frame.minX-joystick.frame.maxX,11)
        XCTAssertGreaterThanOrEqual(joystick.frame.minX-app.buttons["manualNudge-left"].frame.maxX,11)
        XCTAssertGreaterThanOrEqual(joystick.frame.minY-app.buttons["manualNudge-up"].frame.maxY,11)
        XCTAssertGreaterThanOrEqual(app.buttons["manualNudge-down"].frame.minY-joystick.frame.maxY,11)
        let center=joystick.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        center.press(forDuration:0.1,thenDragTo:center.withOffset(CGVector(dx:16,dy:0)),withVelocity:.slow,thenHoldForDuration:0.5)
        XCTAssertGreaterThan(box.frame.midX,initial.midX+2)
        XCTAssertEqual(box.frame.width,initial.width,accuracy:1)
        XCTAssertEqual(box.frame.height,initial.height,accuracy:1)
        let stopped=box.frame
        Thread.sleep(forTimeInterval:0.25)
        XCTAssertEqual(box.frame.midX,stopped.midX,accuracy:1)
        XCTAssertTrue(app.buttons["primaryAction"].isHittable)
        capture(app,"manual-position-controls")
    }
    @MainActor func testManualSelectionUsesFourRectangularEdgeHandles() throws {
        let app=launch();app.buttons["dancer1"].tap();app.buttons["primaryAction"].tap()
        XCTAssertTrue(app.buttons["dancer0"].waitForExistence(timeout:15))
        app.buttons["手动框选人物"].tap()
        for edge in ["top","bottom","left","right"] {
            XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"manualEdge-"+edge).firstMatch.isHittable)
        }
        XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"manualCorner0").firstMatch.exists)
        let right=app.descendants(matching:.any).matching(identifier:"manualEdge-right").firstMatch
        let before=right.frame.midX
        let point=right.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        point.press(forDuration:0.1,thenDragTo:point.withOffset(CGVector(dx:20,dy:0)))
        XCTAssertEqual(right.frame.midX-before,20,accuracy:2)
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"manualBox").count,1)
        let box=app.descendants(matching:.any).matching(identifier:"manualBox").firstMatch
        let beforeMove=box.frame
        let center=box.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        center.press(forDuration:0.1,thenDragTo:center.withOffset(CGVector(dx:15,dy:10)))
        XCTAssertEqual(box.frame.midX-beforeMove.midX,15,accuracy:2)
        XCTAssertEqual(box.frame.midY-beforeMove.midY,10,accuracy:2)
        XCTAssertEqual(box.frame.width,beforeMove.width,accuracy:1)
        XCTAssertEqual(box.frame.height,beforeMove.height,accuracy:1)
        capture(app,"manual-selection-rectangular-edge-handles")
        let confirm=app.buttons["primaryAction"]
        confirm.coordinate(withNormalizedOffset:CGVector(dx:0.1,dy:0.5)).tap()
        XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"manualBox").firstMatch.exists)
        XCTAssertTrue(app.buttons["确认并继续"].exists)
    }
    @MainActor func testRedactionPanelMultiSelectionCancelAndSmallVideoLayouts() throws {
        for ratio in ["portrait","ultrawide"] {
            let app=launch(ratio:ratio);app.buttons["dancer1"].tap()
            let main=app.buttons["primaryAction"],bottom=main.frame.maxY
            app.buttons["tool-打码"].tap()
            XCTAssertTrue(app.buttons["redaction-人脸"].isHittable)
            XCTAssertFalse(app.buttons["dancer0"].exists)
            XCTAssertTrue(app.staticTexts["自动遮挡所有其他人物 · 主角保持清晰"].exists)
            app.buttons["redaction-整个人物"].tap()
            app.buttons["打码强度设置"].tap()
            XCTAssertTrue(app.sliders["redactionStrength"].isHittable)
            XCTAssertTrue(main.isHittable);XCTAssertEqual(main.frame.maxY,bottom,accuracy:1)
            XCTAssertEqual(app.scrollViews.count,0)
            capture(app,"redaction-"+ratio)
            app.buttons["cancelTool"].tap()
            app.buttons["tool-打码"].tap()
            XCTAssertTrue(app.staticTexts["自动遮挡所有其他人物 · 主角保持清晰"].exists)
            app.buttons["commitTool"].tap()
            app.buttons["tool-打码"].tap();app.buttons["关闭打码"].tap()
            XCTAssertTrue(app.staticTexts["打码已关闭"].exists)

        }
    }
    @MainActor func testAdaptiveWorkspaceKeepsSelectionAndCompositionAcrossRotation() throws {
        let app=launch();app.buttons["dancer1"].tap()
        app.buttons["tool-构图"].tap();ready(app.buttons["commitTool"])
        app.buttons["aspect-1:1"].tap();ready(app.buttons["commitTool"])
        XCTAssertTrue(app.buttons["aspect-1:1"].isSelected)
        for orientation in [UIDeviceOrientation.landscapeLeft,.portrait] {
            XCUIDevice.shared.orientation=orientation
            XCTAssertTrue(app.buttons["commitTool"].waitForExistence(timeout:5))
            XCTAssertTrue(app.buttons["aspect-1:1"].isSelected)
            XCTAssertTrue(app.buttons["commitTool"].isHittable)
            XCTAssertEqual(app.scrollViews.count,0)
            for element in [app.buttons["primaryAction"],app.buttons["commitTool"],app.descendants(matching:.any)["compositionCanvas"]] {
                XCTAssertTrue(element.exists)
                XCTAssertGreaterThan(element.frame.width,0);XCTAssertGreaterThan(element.frame.height,0)
                XCTAssertLessThanOrEqual(element.frame.maxY,app.frame.maxY+1)
            }
            capture(app,"adaptive-composition-"+String(orientation.rawValue))
        }
        app.buttons["commitTool"].tap()
        XCTAssertTrue(app.descendants(matching:.any)["selectedTargetFrame"].exists)
        XCTAssertTrue(app.buttons["primaryAction"].isHittable)
    }
    @MainActor func testBackOffersVisibleCancelAndSaveAndReturn() throws {
        let app=launch();app.buttons["dancer1"].tap()
        app.buttons["返回项目首页"].tap()
        let alert=app.alerts["保存并返回首页？"]
        XCTAssertTrue(alert.waitForExistence(timeout:5))
        XCTAssertEqual(alert.buttons.count,2)
        XCTAssertTrue(alert.buttons["取消"].isHittable)
        XCTAssertTrue(alert.buttons["保存并返回"].isHittable)
        capture(app,"back-confirmation")
        alert.buttons["取消"].tap()
        XCTAssertFalse(alert.exists)
        XCTAssertTrue(app.descendants(matching:.any)["selectedTargetFrame"].exists)
        XCTAssertTrue(app.buttons["primaryAction"].isEnabled)
        app.buttons["返回项目首页"].tap();alert.buttons["保存并返回"].tap()
        let importButton=app.buttons.matching(NSPredicate(format:"label CONTAINS %@","导入舞蹈视频")).firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout:5))
    }
    @MainActor func testHomeImportStaysInThumbReach() throws {
        let app = XCUIApplication(); app.launch()
        let button = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "导入舞蹈视频")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10)); XCTAssertTrue(button.isHittable)
        XCTAssertGreaterThan(button.frame.minY, app.frame.height * 0.65); XCTAssertGreaterThanOrEqual(button.frame.height, 56)
        capture(app, "00-glass-home")
        app.buttons["查看操作指引，视频待补充"].tap()
        XCTAssertTrue(app.staticTexts["一个镜头，跟上动作。"].waitForExistence(timeout: 5))
        capture(app, "00-glass-guide"); app.buttons["primaryAction"].tap()
        XCTAssertTrue(button.isHittable)
    }
    @MainActor func testProcessingStaysInEditorWithInlineProgressAndPause() throws {
        let app=launch();app.buttons["dancer1"].tap()
        let action=app.buttons["primaryAction"],bottom=action.frame.maxY
        XCTAssertEqual(app.descendants(matching:.any)["selectedTargetFrame"].label,"主角")
        action.tap()
        XCTAssertTrue(action.label.contains("处理中"))
        XCTAssertTrue(app.descendants(matching:.any)["trimTimeline"].exists)
        XCTAssertFalse(app.buttons["tool-构图"].exists)
        XCTAssertFalse(app.otherElements["adjustmentPanel"].exists)
        XCTAssertFalse(app.buttons["editorPlayback"].isEnabled)
        XCTAssertEqual(action.frame.maxY,bottom,accuracy:1)
        XCTAssertTrue((action.value as? String)?.contains("%") == true)
        capture(app,"editor-processing-inline")
        action.tap()
        XCTAssertTrue(action.label.contains("已暂停"))
        let paused=action.value as? String
        XCTAssertTrue(paused?.contains("%") == true)
        XCTAssertTrue(app.descendants(matching:.any)["sourceVideoSurface"].exists)
        XCTAssertEqual(app.scrollViews.count,0)
        capture(app,"editor-processing-paused")
        XCTAssertEqual(action.value as? String,paused)
        let adjust=app.buttons["returnToEditingFromPause"]
        XCTAssertTrue(adjust.isHittable)
        XCTAssertEqual(action.frame.maxY,bottom,accuracy:1)
        XCTAssertEqual(adjust.frame.maxY,action.frame.maxY,accuracy:1)
        adjust.tap()
        XCTAssertTrue(app.buttons["tool-构图"].waitForExistence(timeout:5))
        XCTAssertFalse(adjust.exists);XCTAssertTrue(action.isEnabled)
        XCTAssertTrue(app.buttons["dancer1"].isHittable)
        XCTAssertEqual(app.scrollViews.count,0)
        capture(app,"editor-returned-from-pause")
        action.tap()
        let status=app.staticTexts["processingStatus"]
        expectation(for:NSPredicate(format:"label CONTAINS %@","阻塞"),evaluatedWith:status);waitForExpectations(timeout:15)
        XCTAssertTrue(app.buttons["dancer1"].isHittable)
        XCTAssertFalse(action.isEnabled)
    }
    @MainActor func testSingleScreenDemoAndBlockingRecovery() throws {
        let app = launch(), action = app.buttons["primaryAction"]
        XCTAssertFalse(action.isEnabled); app.buttons["dancer1"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["selectedTargetFrame"].exists)
        XCTAssertTrue(action.isEnabled); capture(app, "01-source-selection")
        app.buttons["tool-构图"].tap(); ready(app.buttons["commitTool"])
        XCTAssertEqual(action.label, "确认并处理"); action.tap()
        let status = app.staticTexts["processingStatus"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "阻塞"), evaluatedWith: status); waitForExpectations(timeout: 15)
        XCTAssertFalse(action.isEnabled); XCTAssertFalse(app.buttons["调整"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["trimTimeline"].exists)
        XCTAssertTrue(app.buttons["手动框选人物"].isHittable)
        capture(app, "04-blocking-recovery"); app.buttons["dancer0"].tap(); XCTAssertTrue(action.isEnabled); action.tap()
        XCTAssertTrue(app.staticTexts["exportTitle"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews.count, 0); XCTAssertTrue(app.buttons["primaryAction"].isHittable)
        capture(app, "05-export-preview")
        app.buttons["exportResolution"].tap()
        XCTAssertTrue(app.buttons["360 × 640"].waitForExistence(timeout: 3)); app.buttons["360 × 640"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "360 × 640")).firstMatch.exists)
        app.buttons["primaryAction"].tap()
        XCTAssertEqual(app.staticTexts["exportTitle"].label, "导出完成"); capture(app, "06-glass-export-complete")
    }
    @MainActor func testGeneratedPreviewTimelineCanScrubAndPlayAgain() throws {
        let app=launch()
        app.buttons["dancer1"].tap();app.buttons["primaryAction"].tap()
        XCTAssertTrue(app.buttons["dancer0"].waitForExistence(timeout:15))
        app.buttons["dancer0"].tap();app.buttons["primaryAction"].tap()
        XCTAssertTrue(app.segmentedControls["editorToolbar"].waitForExistence(timeout:15))
        XCTAssertFalse(app.buttons["primaryAction"].exists)
        let play=app.buttons["editorPlayback"]
        let timeline=app.descendants(matching:.any).matching(identifier:"trimTimeline").firstMatch
        let range=app.staticTexts["选中片段"]
        let before=range.value as? String
        play.tap()
        XCTAssertEqual(play.label,"暂停预览")
        timeline.coordinate(withNormalizedOffset:CGVector(dx:0.75,dy:0.3))
            .press(forDuration:0.1,thenDragTo:timeline.coordinate(withNormalizedOffset:CGVector(dx:0.35,dy:0.3)))
        XCTAssertNotEqual(range.value as? String,before)
        XCTAssertEqual(play.label,"暂停预览")
        XCTAssertTrue(play.isEnabled)
        play.tap();XCTAssertEqual(play.label,"播放预览")
        play.tap();XCTAssertEqual(play.label,"暂停预览")
        capture(app,"generated-preview-timeline-scrub")
    }
    @MainActor func testOutputPlaybackResetsAfterBackgrounding() throws {
        let app=launch();app.buttons["dancer1"].tap();app.buttons["primaryAction"].tap()
        let status=app.staticTexts["processingStatus"]
        expectation(for:NSPredicate(format:"label CONTAINS %@","阻塞"),evaluatedWith:status)
        waitForExpectations(timeout:15)
        app.buttons["dancer1"].tap();app.buttons["primaryAction"].tap()
        XCTAssertTrue(app.staticTexts["exportTitle"].waitForExistence(timeout:15))
        let play=app.buttons["播放成片"]
        XCTAssertTrue(play.waitForExistence(timeout:5))
        // Tap inside the circular control but outside the small play/pause glyph.
        for offset in [CGVector(dx:0.15,dy:0.5),CGVector(dx:0.85,dy:0.5)] {
            play.coordinate(withNormalizedOffset:offset).tap()
            XCTAssertTrue(app.buttons["暂停成片"].exists,"The full circular control must accept a single click")
            app.buttons["暂停成片"].coordinate(withNormalizedOffset:offset).tap()
            XCTAssertTrue(play.exists)
        }
        play.tap()
        XCTAssertTrue(app.buttons["暂停成片"].exists)
        XCUIDevice.shared.press(.home);app.activate()
        XCTAssertTrue(play.waitForExistence(timeout:5),"Backgrounding pauses the player and must reset its control")
        capture(app,"output-playback-after-background")
    }
    @MainActor func testTimelineTrimsDirectlyAndCompositionCancelKeepsRange() throws {
        let app = launch(), action = app.buttons["primaryAction"]
        XCTAssertFalse(app.buttons["tool-片段"].exists); XCTAssertFalse(app.buttons["tool-运镜"].exists)
        XCTAssertEqual(action.label, "开始处理")
        XCTAssertGreaterThan(action.frame.width, action.frame.height * 2)
        app.buttons["dancer1"].tap()
        let fixed = action.frame, end = app.otherElements["裁剪终点"]
        let originalEnd = end.value as? String
        let first = end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        first.press(forDuration: 0.1, thenDragTo: first.withOffset(CGVector(dx: -36, dy: 0)))
        XCTAssertNotEqual(end.value as? String, originalEnd)
        XCTAssertEqual(action.frame, fixed); XCTAssertTrue(action.isEnabled)
        capture(app, "timeline-direct-trim")
        app.buttons["tool-构图"].tap(); ready(app.buttons["commitTool"])
        let second = end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        second.press(forDuration: 0.1, thenDragTo: second.withOffset(CGVector(dx: -36, dy: 0)))
        ready(app.buttons["commitTool"])
        let committedEnd = end.value as? String
        XCTAssertTrue(app.otherElements["compositionCanvas"].exists)
        app.buttons["cancelTool"].tap()
        XCTAssertEqual(end.value as? String, committedEnd, "Cancelling composition must retain a committed timeline trim")
        XCTAssertEqual(action.frame, fixed); XCTAssertEqual(app.scrollViews.count, 0)
        capture(app, "timeline-three-actions")
    }
    @MainActor func testManualBoxWaitsForConfirmationAndCanResize() throws {
        let app = launch(); app.buttons["tool-选人"].tap(); app.buttons["手动框选人物"].tap()
        let handle = app.descendants(matching: .any)["manualCorner3"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5)); let before = handle.frame
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 20, dy: 10)))
        XCTAssertGreaterThan(handle.frame.midX, before.midX + 8)
        XCTAssertTrue(app.buttons["primaryAction"].label.contains("确认区域")); capture(app, "manual-selection")
        app.buttons["primaryAction"].tap(); XCTAssertEqual(app.buttons["primaryAction"].label, "开始处理")
        XCTAssertTrue(app.buttons["primaryAction"].isEnabled)
    }
    @MainActor func testCompositionPinchDragCommitAndCancelWithoutScrolling() throws {
        let app = launch(); app.buttons["dancer1"].tap()
        let action = app.buttons["primaryAction"], fixed = action.frame
        app.buttons["tool-构图"].tap()
        let canvas = app.otherElements["compositionCanvas"], commit = app.buttons["commitTool"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5)); ready(commit)
        XCTAssertFalse(app.switches["compositionProtection"].exists)
        let before = canvas.value as? String
        canvas.pinch(withScale: 1.3, velocity: 1); ready(commit)
        XCTAssertNotEqual(canvas.value as? String, before)
        let zoomed = canvas.value as? String
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 22, dy: -16))); ready(commit)
        XCTAssertNotEqual(canvas.value as? String, zoomed)
        XCTAssertEqual(action.frame, fixed); XCTAssertTrue(action.isEnabled); XCTAssertEqual(app.scrollViews.count, 0)
        XCTAssertEqual(canvas.frame.width / canvas.frame.height, 9.0 / 16, accuracy: 0.01)
        capture(app, "04-composition-gesture")
        let committed = canvas.value as? String
        commit.tap(); XCTAssertTrue(action.isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["sourceVideoSurface"].exists)
        app.buttons["tool-构图"].tap(); ready(commit)
        XCTAssertEqual(canvas.value as? String, committed)
        canvas.pinch(withScale: 1.2, velocity: 1); ready(commit)
        XCTAssertNotEqual(canvas.value as? String, committed)
        app.buttons["cancelTool"].tap(); app.buttons["tool-构图"].tap(); ready(commit)
        XCTAssertEqual(canvas.value as? String, committed, "Cancel restores the committed crop")
        commit.tap(); XCTAssertEqual(action.frame, fixed)
    }
    @MainActor func testFirstAspectTapCommitsWithoutRetry() throws {
        let app=launch();app.buttons["dancer1"].tap();app.buttons["primaryAction"].tap()
        XCTAssertTrue(app.buttons["dancer0"].waitForExistence(timeout:15))
        app.buttons["dancer0"].tap();app.buttons["primaryAction"].tap()
        let picker=app.segmentedControls["compositionAspect"]
        XCTAssertTrue(picker.waitForExistence(timeout:15))
        picker.buttons["1:1"].tap()
        XCTAssertTrue(picker.buttons["1:1"].isSelected)
    }
    @MainActor func testNativeAspectSegmentsSupportDraggingWithoutDisablingPanel() throws {
        let app=launch()
        app.buttons["dancer1"].tap()
        app.buttons["primaryAction"].tap()
        let recovery=app.buttons["dancer0"]
        XCTAssertTrue(recovery.waitForExistence(timeout:15))
        recovery.tap()
        app.buttons["primaryAction"].tap()
        let tools=app.segmentedControls["editorToolbar"]
        let tool=tools.buttons["构图"]
        XCTAssertTrue(tool.waitForExistence(timeout:15))
        XCTAssertFalse(app.buttons["primaryAction"].exists)
        XCTAssertTrue(app.buttons["previewExport"].exists)
        tool.tap()
        let picker=app.segmentedControls["compositionAspect"]
        XCTAssertTrue(picker.waitForExistence(timeout:5))
        XCTAssertEqual(tools.frame.height,56,accuracy:1)
        XCTAssertGreaterThan(tools.frame.width,app.frame.width*0.8)
        let first=picker.buttons.element(boundBy:0),last=picker.buttons.element(boundBy:2)
        XCTAssertEqual(picker.buttons.count,3)
        XCTAssertGreaterThanOrEqual(picker.frame.height,47)
        last.tap()
        XCTAssertTrue(last.isSelected)
        XCTAssertTrue(picker.isEnabled)
        XCTAssertTrue(app.buttons["构图放大"].isEnabled)
        last.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
            .press(forDuration:0.1,thenDragTo:first.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)))
        XCTAssertTrue(first.isSelected)
        XCTAssertTrue(app.buttons["构图水平居中"].isEnabled)
        XCTAssertEqual(app.scrollViews.count,0)
        capture(app,"native-aspect-segments")
        let broadCanvas=app.descendants(matching:.any).matching(identifier:"compositionCanvas").firstMatch
        XCTAssertTrue(broadCanvas.exists)
        XCTAssertGreaterThan(broadCanvas.frame.width,app.frame.width*0.9)
        app.buttons["构图放大"].tap()
        let beforeOutsideDrag=broadCanvas.value as? String
        broadCanvas.coordinate(withNormalizedOffset:CGVector(dx:0.04,dy:0.45))
            .press(forDuration:0.15,thenDragTo:broadCanvas.coordinate(withNormalizedOffset:CGVector(dx:0.17,dy:0.50)))
        XCTAssertNotEqual(broadCanvas.value as? String,beforeOutsideDrag)
        capture(app,"composition-frosted-outside-drag")
        tools.buttons["运镜"].tap()
        let motion=app.segmentedControls["motionSpeed"]
        XCTAssertTrue(motion.waitForExistence(timeout:5))
        XCTAssertEqual(motion.frame.height,48,accuracy:1)
        for speed in ["标准","灵敏","舒缓"] {
            motion.buttons[speed].tap()
            XCTAssertTrue(motion.buttons[speed].isSelected)
        }
        XCTAssertTrue(tools.buttons["运镜"].isSelected)
        XCTAssertEqual(app.scrollViews.count,0)
        tools.buttons["打码"].tap()
        let panel=app.descendants(matching:.any).matching(identifier:"adjustmentPanel").firstMatch
        let region=app.segmentedControls["redactionRegion"],style=app.segmentedControls["redactionStyle"]
        XCTAssertTrue(panel.waitForExistence(timeout:5))
        XCTAssertLessThanOrEqual(panel.frame.height,300)
        let styleFrame=style.frame,actionFrame=tools.frame
        XCTAssertTrue(region.isHittable)
        XCTAssertFalse(app.buttons["redactionHelp"].exists)
        XCTAssertFalse(app.staticTexts["对主角外人物进行打码"].exists)
        XCTAssertFalse(app.staticTexts["主角不打码"].exists)
        XCTAssertEqual(style.buttons.count,3)
        XCTAssertFalse(app.switches["redactionEnabled"].exists)
        XCTAssertTrue(region.buttons["关闭"].isSelected)
        let disabledRangeFrame=region.frame
        region.buttons["人脸"].tap()
        XCTAssertTrue(region.buttons["人脸"].isSelected)
        XCTAssertEqual(region.frame,disabledRangeFrame)
        XCTAssertTrue(region.buttons["人脸"].isHittable)
        XCTAssertTrue(region.buttons["全身"].isHittable)
        XCTAssertFalse(app.buttons["回到选人帧"].exists)
        region.buttons["全身"].tap()
        XCTAssertTrue(region.buttons["全身"].isSelected)
        XCTAssertEqual(style.buttons.count,2)
        XCTAssertFalse(style.buttons["贴片"].exists)
        let strength=app.sliders["redactionStrength"]
        XCTAssertTrue(strength.isHittable)
        XCTAssertEqual(strength.value as? String,"30")
        strength.adjust(toNormalizedSliderPosition:0)
        XCTAssertEqual(strength.value as? String,"0")
        strength.adjust(toNormalizedSliderPosition:1)
        XCTAssertEqual(strength.value as? String,"100")
        strength.adjust(toNormalizedSliderPosition:0.1)
        // Intermediate touch positions can round by a few steps; defaults and endpoints are exact.
        XCTAssertEqual(try XCTUnwrap(Double(strength.value as? String ?? "")),10,accuracy:3)
        strength.adjust(toNormalizedSliderPosition:0.8)
        style.buttons.element(boundBy:1).tap()
        XCTAssertTrue(style.buttons.element(boundBy:1).isSelected)
        capture(app,"phone-redaction-inline-strength")
        style.buttons.element(boundBy:1).coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
            .press(forDuration:0.1,thenDragTo:style.buttons.element(boundBy:0).coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)))
        XCTAssertTrue(style.buttons.element(boundBy:0).isSelected)
        region.buttons["人脸"].tap()
        style.buttons["贴片"].tap()
        XCTAssertFalse(strength.exists)
        XCTAssertTrue(app.buttons["redactionSticker-duck"].isSelected)
        app.buttons["redactionSticker-cat"].tap()
        XCTAssertTrue(app.buttons["redactionSticker-cat"].isSelected)
        XCTAssertFalse(app.staticTexts["直拍鸭 Logo"].exists)
        XCTAssertEqual(style.frame.minX,styleFrame.minX,accuracy:1)
        XCTAssertEqual(style.frame.width,styleFrame.width,accuracy:1)
        XCTAssertLessThanOrEqual(panel.frame.height,300)
        XCTAssertEqual(tools.frame,actionFrame)
        XCTAssertEqual(app.scrollViews.count,0)
        capture(app,"phone-redaction-inline-logo")
        region.buttons["全身"].tap()
        XCTAssertEqual(style.buttons.count,2)
        XCTAssertTrue(style.buttons["毛玻璃"].isSelected)
        XCTAssertTrue(strength.exists)
        region.buttons["关闭"].tap()
        XCTAssertTrue(region.buttons["关闭"].isSelected)
        XCTAssertEqual(region.frame,disabledRangeFrame)
        tools.buttons["构图"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout:5))
        XCTAssertTrue(first.isSelected)
        capture(app,"native-tool-and-redaction-segments")
        let endHandle=app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","裁剪终点")).firstMatch
        XCTAssertTrue(endHandle.isHittable)
        let previousEnd=endHandle.value as? String
        let handlePoint=endHandle.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        handlePoint.press(forDuration:0.1,thenDragTo:handlePoint.withOffset(CGVector(dx:-60,dy:0)))
        XCTAssertNotEqual(endHandle.value as? String,previousEnd)
        XCTAssertTrue(tools.exists,"Trimming within analyzed footage keeps settings available")
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"compositionCanvas").firstMatch.exists,"Trimming must retain the composition viewport")
        capture(app,"settings-selected-time-range")
        app.buttons["previewExport"].tap()
        XCTAssertTrue(app.staticTexts["exportTitle"].waitForExistence(timeout:8))
        capture(app,"preview-export-options")
    }
    @MainActor func testOutputAspectsAndIndependentCentering() throws {
        let app=launch();app.buttons["dancer1"].tap();app.buttons["tool-构图"].tap()
        let commit=app.buttons["commitTool"],canvas=app.otherElements["compositionCanvas"]
        ready(commit)
        XCTAssertFalse(app.buttons["aspect-9:16"].exists)
        for (title,ratio) in [("16:9",9.0/16),("4:3",3.0/4),("1:1",1.0)] {
            app.buttons["aspect-"+title].tap();ready(commit)
            XCTAssertEqual(canvas.frame.width/canvas.frame.height,ratio,accuracy:0.01)
            XCTAssertTrue(app.buttons["构图水平居中"].isHittable)
            XCTAssertTrue(app.buttons["构图垂直居中"].isHittable)
            XCTAssertEqual(app.scrollViews.count,0)
            capture(app,"composition-aspect-"+title.replacingOccurrences(of:":",with:"-"))
        }
        app.buttons["构图水平居中"].tap();ready(commit)
        app.buttons["构图垂直居中"].tap();ready(commit)
        app.buttons["aspect-1:1"].tap();ready(commit)
        app.buttons["cancelTool"].tap()
        app.buttons["tool-构图"].tap();ready(commit)
        XCTAssertEqual(canvas.frame.width/canvas.frame.height,9.0/16,accuracy:0.01)
    }
    @MainActor func testAccessibilityTextKeepsInlineToolsAndVideoVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-editor", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); XCTAssertTrue(app.buttons["dancer1"].waitForExistence(timeout: 10)); app.buttons["dancer1"].tap()
        app.buttons["tool-构图"].tap(); ready(app.buttons["commitTool"])
        let canvas = app.otherElements["compositionCanvas"]
        XCTAssertGreaterThan(canvas.frame.height, 80)
        XCTAssertTrue(app.buttons["commitTool"].isHittable); XCTAssertTrue(app.buttons["cancelTool"].isHittable)
        XCTAssertTrue(app.buttons["aspect-16:9"].isHittable)
        XCTAssertTrue(app.buttons["tool-选人"].isHittable)
        XCTAssertLessThan(app.buttons["primaryAction"].frame.maxY, app.frame.height - 15)
        XCTAssertEqual(app.scrollViews.count, 0); capture(app, "accessibility-inline-composition")
    }
    @MainActor func testMultipleSourceRatiosKeepWholeVideoAndFixedControls() throws {
        var fixed: CGRect?
        for (ratio, expected) in [("landscape", 16.0 / 9), ("square", 1.0), ("portrait", 9.0 / 16), ("ultrawide", 2560.0 / 1080), ("narrow", 1080.0 / 2560)] {
            let app = launch(ratio: ratio), source = app.descendants(matching: .any)["sourceVideoSurface"]
            XCTAssertTrue(source.exists); XCTAssertEqual(source.frame.width / source.frame.height, expected, accuracy: 0.01)
            XCTAssertGreaterThan(source.frame.minY, 45); XCTAssertLessThan(source.frame.maxY, app.buttons["primaryAction"].frame.minY)
            if let fixed { XCTAssertEqual(app.buttons["primaryAction"].frame, fixed) } else { fixed = app.buttons["primaryAction"].frame }
            XCTAssertEqual(app.scrollViews.count, 0); XCTAssertTrue(app.buttons["tool-选人"].isHittable)
            capture(app, "ratio-" + ratio); app.terminate()
        }
    }
}

#endif
