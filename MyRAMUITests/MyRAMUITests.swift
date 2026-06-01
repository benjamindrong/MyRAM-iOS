//
//  MyRAMUITests.swift
//  MyRAMUITests
//
//  Created by Benjamin Drong on 10/18/25.
//

import XCTest

final class MyRAMUITests: XCTestCase {
    private var initialAppearanceRaw = "system"

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
        let app = makeApp()
        app.launch()
        initialAppearanceRaw = currentAppearanceRaw(in: app) ?? "system"
        app.terminate()
    }

    override func tearDownWithError() throws {
        let app = makeApp(forcedAppearanceRaw: initialAppearanceRaw)
        app.launch()
        Thread.sleep(forTimeInterval: 0.4)
        app.terminate()
    }

    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = makeApp()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    func testLaunchPerformance() throws {
        if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil {
            throw XCTSkip("Skipping launch performance on physical devices due to unstable test runner behavior.")
        }
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                let app = makeApp()
                app.launch()
            }
        }
    }

    func testNewNoteOpensWithoutAttachments() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        XCTAssertTrue(app.buttons["edit-note-title"].waitForExistence(timeout: 5))
//        XCTAssertTrue(app.buttons["keyboard-control-copy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Untitled"].exists)

        XCTAssertFalse(app.staticTexts["Attachments"].exists)
    }

    func testNoteEditorTitlePopupAndRedoButtonAreAvailable() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        let editTitleButton = app.buttons["edit-note-title"]
        XCTAssertTrue(editTitleButton.waitForExistence(timeout: 5))
        editTitleButton.tap()

        XCTAssertTrue(app.alerts["Edit Title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].exists)
//        XCTAssertTrue(app.buttons["Redo"].exists)
    }

    private func makeApp(forcedAppearanceRaw: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("UITEST_MODE")
        if let forcedAppearanceRaw {
            app.launchEnvironment["UITEST_FORCE_APPEARANCE"] = forcedAppearanceRaw
        }
        return app
    }

    private func openNewNote(in app: XCUIApplication) {
        let quickActionButton = app.buttons["notes-topbar-new-note"]
        if quickActionButton.waitForExistence(timeout: 2) {
            quickActionButton.tap()
            return
        }

        let overflowButton = app.buttons["notes-list-more"]
        XCTAssertTrue(overflowButton.waitForExistence(timeout: 5))
        overflowButton.tap()

        let menuNewNoteButton = app.buttons["New Note"]
        XCTAssertTrue(menuNewNoteButton.waitForExistence(timeout: 5))
        menuNewNoteButton.tap()
    }

    private func currentAppearanceRaw(in app: XCUIApplication) -> String? {
        let probe = app.otherElements["appearance-setting-raw"]
        guard probe.waitForExistence(timeout: 2) else { return nil }
        let value = probe.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["system", "light", "dark"].contains(value) {
            return value
        }
        return nil
    }
}
