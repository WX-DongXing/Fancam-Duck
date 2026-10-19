import XCTest

final class ReverseRecoveryTests:XCTestCase {
    @MainActor func testInterruptedDesktopProjectLeavesProcessingState() throws {
        let environment=ProcessInfo.processInfo.environment
        guard environment["FANCAM_DUCK_REVERSE_VALIDATION"]=="1",let projectID=environment["FANCAM_DUCK_REVERSE_PROJECT_ID"],UUID(uuidString:projectID) != nil else {throw XCTSkip("Requires an explicit local desktop project ID")}
        let app=XCUIApplication();app.launch()
        let completed=app.staticTexts["导出完成"]
        let project=app.buttons["projectRow-\(projectID)"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout:10));project.tap()
        let confirm=app.buttons["primaryAction"]
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:confirm)
        waitForExpectations(timeout:20)
        let began=Date();confirm.tap()
        let ready=app.staticTexts.matching(NSPredicate(format:"identifier == %@ AND label == %@","exportTitle","导出预览")).firstMatch
        let status=app.staticTexts["processingStatus"]
        expectation(for:NSPredicate {_,_ in
            ready.exists || completed.exists || (status.exists && status.label.contains("已阻塞")) || app.alerts.count>0
        },evaluatedWith:app)
        waitForExpectations(timeout:150)
        XCTAssertEqual(app.alerts.count,0)
        XCTAssertTrue(ready.exists || completed.exists || status.label.contains("已阻塞"),"Processing must finish or request a genuine identity correction")
        print("DESKTOP_REVERSE_RECOVERY seconds=\(Date().timeIntervalSince(began)) ready=\(ready.exists) status=\(status.exists ? status.label : "export preview")")
        if ready.exists {
            app.buttons["primaryAction"].tap()
            let exportStarted=Date()
            expectation(for:NSPredicate {_,_ in completed.exists || app.alerts.count>0},evaluatedWith:app)
            waitForExpectations(timeout:180)
            XCTAssertTrue(completed.exists,"The recovered reverse trajectory must export successfully")
            print("DESKTOP_REVERSE_EXPORT seconds=\(Date().timeIntervalSince(exportStarted))")
            XCTAssertEqual(app.alerts.count,0)
        }
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Recovered desktop reverse analysis";shot.lifetime = .keepAlways;add(shot)
    }
}
