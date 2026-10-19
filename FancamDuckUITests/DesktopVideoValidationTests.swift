import XCTest

/// Opt-in; the original desktop clip is imported through the system Photos picker.
final class DesktopVideoValidationTests: XCTestCase {
    @MainActor func testDuoLayoutWithOriginalVideo() throws {
        guard ProcessInfo.processInfo.environment["FANCAM_DUCK_DUO_LAYOUT_VALIDATION"] == "1" else {throw XCTSkip("Requires original desktop clip in Duo Photos")}
        let app=XCUIApplication();app.launch()
        let importButton=app.buttons.matching(NSPredicate(format:"label CONTAINS %@","导入舞蹈视频")).firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout:10));importButton.tap()
        let video=app.images.matching(NSPredicate(format:"label BEGINSWITH %@","视频, 三十八秒钟")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout:30),app.debugDescription)
        video.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        let target=app.buttons["person2"]
        XCTAssertTrue(target.waitForExistence(timeout:90),app.debugDescription);target.tap()
        let stage=app.descendants(matching:.any)["editorStage"]
        let timeline=app.descendants(matching:.any)["trimTimeline"]
        let toolbar=app.descendants(matching:.any)["editorToolbar"]
        XCTAssertLessThan(timeline.frame.maxX,toolbar.frame.minX)
        XCTAssertGreaterThan(timeline.frame.minY,stage.frame.minY)
        XCTAssertTrue(app.buttons["primaryAction"].isHittable)
        XCTAssertEqual(app.scrollViews.count,0);capture(app,"duo-real-overview")
        app.buttons["tool-构图"].tap();ready(app.buttons["commitTool"])
        app.buttons["aspect-1:1"].tap();ready(app.buttons["commitTool"])
        app.buttons["构图放大"].tap();ready(app.buttons["commitTool"])
        XCTAssertTrue(app.buttons["commitTool"].isHittable)
        XCTAssertTrue(app.buttons["primaryAction"].isHittable)
        XCTAssertEqual(app.scrollViews.count,0);capture(app,"duo-real-composition")
        app.buttons["cancelTool"].tap()
        app.buttons["tool-打码"].tap()
        XCTAssertTrue(app.buttons["redaction-人脸"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["commitTool"].isHittable)
        XCTAssertEqual(app.scrollViews.count,0);capture(app,"duo-real-redaction")
        app.buttons["cancelTool"].tap()
    }
    @MainActor func testDesktopRedactionFromPhotos() throws {
        guard ProcessInfo.processInfo.environment["FANCAM_DUCK_REDACTION_UI"] == "1" else {throw XCTSkip("Opt-in desktop redaction validation")}
        let app=XCUIApplication();app.launch()
        let importButton=app.buttons.matching(NSPredicate(format:"label CONTAINS %@","导入舞蹈视频")).firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout:10));importButton.tap()
        let original=app.images.matching(NSPredicate(format:"label BEGINSWITH %@ AND label CONTAINS %@","视频, 三十八秒钟","3月21日")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout:60));original.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        let candidates=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","person"))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout:60))
        XCTAssertGreaterThanOrEqual(candidates.count,4)
        app.buttons["person2"].tap()
        let end=app.otherElements["裁剪终点"],start=app.otherElements["裁剪起点"]
        XCTAssertTrue(end.exists);XCTAssertTrue(start.exists)
        let from=end.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        let to=start.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).withOffset(CGVector(dx:24,dy:0))
        from.press(forDuration:0.15,thenDragTo:to)
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout:20))
        // Return to the first frame before choosing identities.
        let timeline=app.descendants(matching:.any)["trimTimeline"]
        timeline.coordinate(withNormalizedOffset:CGVector(dx:0.055,dy:0.5)).tap()
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout:20))
        app.buttons["tool-打码"].tap()
        XCTAssertTrue(app.buttons["redaction-人脸"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["自动遮挡所有其他人物 · 主角保持清晰"].exists)
        XCTAssertFalse(app.buttons["person3"].exists)
        capture(app,"redaction-face-settings")
        app.buttons["redaction-整个人物"].tap();capture(app,"redaction-person-settings")
        app.buttons["redaction-人脸"].tap()
        app.buttons["redaction-style-马赛克"].tap();capture(app,"redaction-mosaic-settings")
        app.buttons["redaction-style-图片"].tap()
        let photo=app.images.matching(NSPredicate(format:"label BEGINSWITH %@","照片,")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout:20),app.debugDescription)
        photo.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        XCTAssertTrue(app.buttons["更换图片"].waitForExistence(timeout:15),app.debugDescription)
        capture(app,"redaction-image-settings")
        app.buttons["commitTool"].tap()
        let action=app.buttons["primaryAction"];ready(action);action.tap()
        let title=app.staticTexts["exportTitle"]
        XCTAssertTrue(title.waitForExistence(timeout:90),app.debugDescription)
        XCTAssertEqual(app.alerts.count,0);capture(app,"redaction-output-preview")
        action.tap()
        expectation(for:NSPredicate(format:"label == %@","导出完成"),evaluatedWith:title);waitForExpectations(timeout:90)
        XCTAssertEqual(app.alerts.count,0);XCTAssertEqual(app.scrollViews.count,0)
        capture(app,"redaction-output-complete")
        if ProcessInfo.processInfo.environment["FANCAM_DUCK_REGENERATION_UI"] == "1" {
            app.buttons["返回调整"].tap()
            XCTAssertTrue(app.buttons["person2"].waitForExistence(timeout:20))
            XCTAssertEqual(app.descendants(matching:.any)["selectedTargetFrame"].label,"主角")
            app.buttons["tool-构图"].tap();ready(app.buttons["commitTool"])
            app.buttons["aspect-1:1"].tap();ready(app.buttons["commitTool"])
            app.buttons["commitTool"].tap();ready(action)
            XCTAssertEqual(action.label,"重新生成")
            capture(app,"regeneration-edited")
            action.tap()
            XCTAssertTrue(title.waitForExistence(timeout:90),app.debugDescription)
            XCTAssertEqual(title.label,"导出完成")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","1:1 ·")).firstMatch.exists)
            capture(app,"regeneration-output-complete")
            app.buttons["返回调整"].tap();XCTAssertTrue(app.buttons["person2"].waitForExistence(timeout:20))
            ready(action);XCTAssertEqual(action.label,"预览成片");action.tap()
            XCTAssertTrue(title.waitForExistence(timeout:10));XCTAssertEqual(title.label,"导出完成")
        }
    }
    @MainActor func testDesktopVideoFromPhotos() throws {
        guard ProcessInfo.processInfo.environment["FANCAM_DUCK_DESKTOP_VALIDATION"] == "1" else { throw XCTSkip("Requires desktop clip in simulator Photos") }
        let app = XCUIApplication(); app.launch()
        let importButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "导入舞蹈视频")).firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 10)); importButton.tap()
        let videos = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "视频, 三十八秒钟"))
        XCTAssertTrue(videos.firstMatch.waitForExistence(timeout: 60), app.debugDescription)
        print("DESKTOP_PHOTO_CHOICES=\(videos.allElementsBoundByIndex.map { $0.label })")
        let stamp = ProcessInfo.processInfo.environment["FANCAM_DUCK_DESKTOP_PHOTO_CONTAINS"]
        let video = stamp.map { videos.matching(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch } ?? videos.firstMatch
        XCTAssertTrue(video.exists, app.debugDescription)
        capture(app, "01-photos"); video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let candidates = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "选择人物 "))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 90), app.debugDescription)
        let metadata = app.descendants(matching: .any)["sourceVideoMetadata"]
        XCTAssertEqual((metadata.value as? String)?.filter { $0.isNumber }, "38402160")
        XCTAssertGreaterThanOrEqual(candidates.count, 5)
        let source = app.descendants(matching: .any)["sourceVideoSurface"]
        XCTAssertEqual(source.frame.width / source.frame.height, 16.0 / 9, accuracy: 0.01)
        let target = try XCTUnwrap(candidates.allElementsBoundByIndex.min { abs($0.frame.midX - app.frame.width * 0.455) < abs($1.frame.midX - app.frame.width * 0.455) })
        target.tap(); capture(app, "02-real-selection")
        let action = app.buttons["primaryAction"], fixed = action.frame
        app.buttons["tool-构图"].tap()
        let canvas = app.otherElements["compositionCanvas"], commit = app.buttons["commitTool"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10)); ready(commit)
        XCTAssertFalse(app.switches["compositionProtection"].exists)
        if ProcessInfo.processInfo.environment["FANCAM_DUCK_DESKTOP_SWITCH_REVIEW"] == "1" {
            print("SWITCH_REVIEW_START=\(Date().timeIntervalSince1970)")
            for cycle in 0..<2 {
                for (label,ratio) in [("1:1",1.0),("4:3",3.0/4),("16:9",9.0/16)] {
                    app.buttons["aspect-"+label].tap();ready(commit)
                    XCTAssertEqual(canvas.frame.width/canvas.frame.height,ratio,accuracy:0.01)
                    print("SWITCH_VIEWPORT=\(canvas.frame)")
                    XCTAssertEqual(app.scrollViews.count,0)
                    capture(app,"switch-\(cycle)-"+label.replacingOccurrences(of:":",with:"-"))
                }
                commit.tap();XCTAssertTrue(source.exists)
                app.buttons["tool-构图"].tap();ready(commit)
                XCTAssertTrue(canvas.exists)
            }
            print("SWITCH_REVIEW_END=\(Date().timeIntervalSince1970)")
            return
        }
        let original = canvas.value as? String
        canvas.pinch(withScale: 1.2, velocity: 1); ready(commit)
        XCTAssertNotEqual(canvas.value as? String, original)
        let zoomed = canvas.value as? String
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 18, dy: 14))); ready(commit)
        XCTAssertNotEqual(canvas.value as? String, zoomed)
        XCTAssertEqual(action.frame, fixed); XCTAssertEqual(app.scrollViews.count, 0)
        let committed = canvas.value as? String
        capture(app, "04-real-composition")
        if ProcessInfo.processInfo.environment["FANCAM_DUCK_DESKTOP_LAYOUT_ONLY"] == "1" { return }
        commit.tap(); ready(action)
        let started = Date(); action.tap()
        let title = app.staticTexts["exportTitle"], status = app.staticTexts["processingStatus"]
        for index in 0..<240 {
            if title.exists { break }
            if status.exists && status.label.contains("阻塞") {
                capture(app, "identity-needs-review")
                print("BLOCKED_SOURCE_TIME=\(status.value ?? "unknown")")
                XCTFail("Inspect captured original frame before identifying a dancer: \(app.debugDescription)"); return
            }
            if index == 1 {
                action.tap()
                XCTAssertTrue(status.label.contains("已暂停")); capture(app, "05a-paused")
                action.tap()
            }
            if index == 2 {
                XCTAssertTrue(app.descendants(matching: .any)["selectedTargetFrame"].exists)
                XCTAssertFalse(app.buttons["调整"].exists); XCTAssertTrue(app.descendants(matching: .any)["trimTimeline"].exists)
                capture(app, "05-real-tracking")
                if ProcessInfo.processInfo.environment["FANCAM_DUCK_DESKTOP_PROCESSING_ONLY"] == "1" {
                    XCTAssertTrue(action.label.contains("处理中"))
                    XCTAssertTrue((action.value as? String)?.contains("%") == true)
                    XCTAssertFalse(app.buttons["tool-构图"].exists)
                    XCTAssertFalse(app.otherElements["adjustmentPanel"].exists)
                    action.tap();XCTAssertTrue(status.label.contains("已暂停"))
                    capture(app,"05b-real-inline-paused")
                    return
                }
            }
            if index % 20 == 0 { print("IMMERSIVE_ANALYSIS elapsed=\(Date().timeIntervalSince(started)) status=\(status.exists ? status.label : "transition")") }
            _ = title.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(title.exists, app.debugDescription); XCTAssertEqual(app.alerts.count, 0)
        print("IMMERSIVE_ANALYSIS_SECONDS=\(Date().timeIntervalSince(started))")
        XCTAssertTrue(app.buttons["播放成片"].isHittable); app.buttons["播放成片"].tap(); app.buttons["暂停成片"].tap()
        capture(app, "06-real-export-preview")
        let exportStarted = Date(); app.buttons["primaryAction"].tap()
        expectation(for: NSPredicate(format: "label == %@", "导出完成"), evaluatedWith: title); waitForExpectations(timeout: 180)
        XCTAssertEqual(app.alerts.count, 0); XCTAssertEqual(app.scrollViews.count, 0)
        print("IMMERSIVE_EXPORT_SECONDS=\(Date().timeIntervalSince(exportStarted))"); capture(app, "07-real-export-complete")
        if ProcessInfo.processInfo.environment["FANCAM_DUCK_VALIDATE_PHOTO_SAVE"] == "1" {
            app.buttons["primaryAction"].tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 3) {
                let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "允许", "Allow")).firstMatch
                XCTAssertTrue(allow.exists); allow.tap()
            }
            expectation(for: NSPredicate(format: "label CONTAINS %@", "已保存到相册"), evaluatedWith: app.buttons["primaryAction"])
            waitForExpectations(timeout: 30); capture(app, "08-saved-to-photos")
        }
        app.buttons["返回调整"].tap(); XCTAssertTrue(app.buttons["tool-构图"].waitForExistence(timeout: 10)); ready(app.buttons["primaryAction"])
        XCTAssertTrue(app.buttons["primaryAction"].label.contains("预览成片"))
        app.buttons["tool-构图"].tap(); ready(commit)
        XCTAssertEqual(canvas.value as? String, committed, "Export round trip must retain the selected composition")
        capture(app, "09-returned-composition")
    }
    @MainActor private func ready(_ button: XCUIElement) {
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button); waitForExpectations(timeout: 20)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("immersive-" + name + ".png")
        try? screenshot.pngRepresentation.write(to: url)
        print("UI_SCREENSHOT=\(url.path)")
        let shot = XCTAttachment(screenshot: screenshot); shot.name = "immersive-" + name; shot.lifetime = .keepAlways; add(shot)
    }
}
