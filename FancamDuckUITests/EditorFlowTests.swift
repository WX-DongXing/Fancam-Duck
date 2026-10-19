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
    @MainActor func testOutputPlaybackResetsAfterBackgrounding() throws {
        let app=launch();app.buttons["dancer1"].tap();app.buttons["primaryAction"].tap()
        let status=app.staticTexts["processingStatus"]
        expectation(for:NSPredicate(format:"label CONTAINS %@","阻塞"),evaluatedWith:status)
        waitForExpectations(timeout:15)
        app.buttons["dancer1"].tap();app.buttons["primaryAction"].tap()
        XCTAssertTrue(app.staticTexts["exportTitle"].waitForExistence(timeout:15))
        let play=app.buttons["播放成片"]
        XCTAssertTrue(play.waitForExistence(timeout:5));play.tap()
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
