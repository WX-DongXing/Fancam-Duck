import XCTest

final class HistoryDeletionTests:XCTestCase {
    @MainActor func testSwipeRevealCancelAndConfirmDelete() throws {
        let app=XCUIApplication();app.launchArguments=["--ui-test-history"];app.launch()
        let row=app.buttons.matching(NSPredicate(format:"label CONTAINS %@","侧滑删除测试项目")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10))
        row.swipeLeft()
        let delete=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","deleteProject-")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout:3));XCTAssertTrue(delete.isHittable)
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="B home history swipe delete";screenshot.lifetime = .keepAlways;add(screenshot)
        delete.tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout:3));app.buttons["取消"].tap()
        XCTAssertTrue(row.exists,"Cancelling must retain the project")
        row.swipeLeft()
        delete.tap()
        app.buttons["删除项目"].tap()
        expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:row)
        waitForExpectations(timeout:5)
        XCTAssertTrue(app.staticTexts["保留的测试项目"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@","导入舞蹈视频")).firstMatch.isHittable)
    }
}
