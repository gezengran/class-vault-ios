import XCTest

final class TeacherWorkbenchUITests: XCTestCase {
    func testLockedLaunchDoesNotRevealStudentData() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-demo-data", "--ui-testing-lock"]
        app.launch()

        XCTAssertTrue(app.otherElements["lock-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["班匣"].exists)
        XCTAssertFalse(app.staticTexts["Synthetic Student"].exists)
        XCTAssertFalse(app.staticTexts["Synthetic Parent"].exists)
    }

    func testCallFlowShowsConfirmationBeforePhoneInterface() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-demo-data", "--ui-testing-unlocked"]
        app.launch()

        let student = app.staticTexts["Synthetic Student"]
        XCTAssertTrue(student.waitForExistence(timeout: 5))
        student.tap()

        let callButton = app.buttons.matching(identifier: "call-contact-par_ui_demo").firstMatch
        XCTAssertTrue(callButton.waitForExistence(timeout: 5))
        callButton.tap()

        XCTAssertTrue(app.alerts["确认拨打电话？"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.alerts["确认拨打电话？"].buttons["取消"].exists)
        XCTAssertTrue(app.alerts["确认拨打电话？"].buttons["拨打"].exists)
        app.alerts["确认拨打电话？"].buttons["取消"].tap()
        XCTAssertFalse(app.alerts["确认拨打电话？"].exists)
    }

    func testManualStudentAddSheetIsAvailable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-demo-data", "--ui-testing-unlocked"]
        app.launch()

        let addButton = app.buttons["add-student-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        XCTAssertTrue(app.otherElements["student-editor"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["新增学生"].exists)
        app.buttons["取消"].tap()
        XCTAssertFalse(app.otherElements["student-editor"].exists)
    }
}
