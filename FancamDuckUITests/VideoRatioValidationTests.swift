import XCTest

/// Real square/portrait clips derived from the desktop original, imported using Photos.
final class VideoRatioValidationTests: XCTestCase {
    @MainActor func testRealSquareAndPortraitFlow() throws {
        guard ProcessInfo.processInfo.environment["FANCAM_DUCK_REAL_RATIOS"] == "1" else { throw XCTSkip("Requires square 5s and portrait 6s clips in simulator Photos") }
        for (duration, ratio, name, outputTitle, outputRatio) in [("五秒钟", 1.0, "square", "16:9", 9.0/16), ("六秒钟", 9.0 / 16, "portrait", "4:3", 3.0/4)] {
            let app = XCUIApplication(); app.launch()
            let button = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "导入舞蹈视频")).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
            let video = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "视频, " + duration)).firstMatch
            XCTAssertTrue(video.waitForExistence(timeout: 30), app.debugDescription); video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let candidates = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "选择人物 "))
            XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 60), app.debugDescription)
            let source = app.descendants(matching: .any)["sourceVideoSurface"]
            XCTAssertEqual(source.frame.width / source.frame.height, ratio, accuracy: 0.01)
            let target = try XCTUnwrap(candidates.allElementsBoundByIndex.min { abs($0.frame.midX - app.frame.midX) < abs($1.frame.midX - app.frame.midX) })
            target.tap(); capture(app, name + "-source")
            app.buttons["tool-构图"].tap(); let action = app.buttons["primaryAction"]
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["commitTool"]); waitForExpectations(timeout: 15)
            let canvas = app.otherElements["compositionCanvas"]
            XCTAssertEqual(canvas.frame.width / canvas.frame.height, 9.0 / 16, accuracy: 0.01)
            app.buttons["aspect-"+outputTitle].tap()
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["commitTool"]); waitForExpectations(timeout: 15)
            XCTAssertEqual(canvas.frame.width/canvas.frame.height, outputRatio, accuracy:0.01)
            XCTAssertEqual(app.scrollViews.count, 0); XCTAssertTrue(action.isEnabled); capture(app, name + "-composition")
            app.buttons["commitTool"].tap(); action.tap()
            let title = app.staticTexts["exportTitle"], status = app.staticTexts["processingStatus"]
            expectation(for: NSPredicate { _, _ in title.exists || (status.exists && status.label.contains("阻塞")) || app.alerts.count > 0 }, evaluatedWith: app)
            waitForExpectations(timeout: 90)
            XCTAssertTrue(title.exists, "Inspect any genuine identity uncertainty: \(app.debugDescription)")
            guard title.exists else { return }
            let viewport=app.descendants(matching:.any)["exportViewport"]
            XCTAssertEqual(viewport.frame.width/viewport.frame.height,outputRatio,accuracy:0.01)
            app.buttons["primaryAction"].tap()
            expectation(for: NSPredicate(format: "label == %@", "导出完成"), evaluatedWith: title); waitForExpectations(timeout: 90)
            let save=app.buttons["primaryAction"],back=app.buttons["exportBack"],share=app.buttons["exportShare"]
            XCTAssertTrue(save.isHittable);XCTAssertTrue(back.isHittable);XCTAssertTrue(share.isHittable)
            XCTAssertEqual(back.frame.width,share.frame.width,accuracy:1)
            XCTAssertEqual(back.frame.midY,share.frame.midY,accuracy:1)
            XCTAssertGreaterThan(save.frame.width,back.frame.width*1.9)
            XCTAssertLessThanOrEqual(back.frame.maxY,save.frame.minY)
            XCTAssertGreaterThanOrEqual(back.frame.height,44)
            let metadata=app.staticTexts["exportMetadata"]
            XCTAssertGreaterThanOrEqual(metadata.frame.minY,viewport.frame.maxY)
            XCTAssertLessThan(metadata.frame.minY-viewport.frame.maxY,32)
            XCTAssertEqual(app.alerts.count, 0); XCTAssertEqual(app.scrollViews.count, 0); capture(app, name + "-export")
            app.buttons["完成"].tap(); app.terminate()
        }
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("real-ratio-" + name + ".png")
        try? screenshot.pngRepresentation.write(to: url)
        print("UI_SCREENSHOT=\(url.path)")
        let shot = XCTAttachment(screenshot: screenshot); shot.name = "real-ratio-" + name; shot.lifetime = .keepAlways; add(shot)
    }
}
