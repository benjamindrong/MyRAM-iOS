//
//  MyRAMUITests.swift
//  MyRAMUITests
//
//  Created by Benjamin Drong on 10/18/25.
//

import XCTest

final class MyRAMUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }

    func testNewNoteOpensWithoutAttachments() throws {
        let app = XCUIApplication()
        app.launch()

        let overflowButton = app.buttons["More"]
        XCTAssertTrue(overflowButton.waitForExistence(timeout: 5))
        overflowButton.tap()

        let newNoteButton = app.buttons["New Note"]
        XCTAssertTrue(newNoteButton.waitForExistence(timeout: 5))
        newNoteButton.tap()

        XCTAssertTrue(app.navigationBars["Note"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))

        XCTAssertFalse(app.staticTexts["Attachments"].exists)
    }
}
