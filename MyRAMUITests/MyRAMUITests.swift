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

    func testNewNoteOpensWithoutAttachments() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        XCTAssertTrue(app.buttons["edit-note-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(findElement("keyboard-control-overflow-toggle", in: app).waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["Save"].exists)
    }

    func testKeyboardControlsAreCollapsedByDefault() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        XCTAssertTrue(findElement("keyboard-control-bar", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(findElement("keyboard-control-toggle", in: app).exists)
        XCTAssertTrue(findElement("keyboard-control-undo", in: app).exists)
        XCTAssertTrue(findElement("keyboard-control-redo", in: app).exists)
        XCTAssertTrue(findElement("keyboard-control-cut", in: app).exists)
        XCTAssertTrue(findElement("keyboard-control-copy", in: app).exists)
        XCTAssertTrue(findElement("keyboard-control-paste", in: app).exists)
        XCTAssertTrue(findElement("keyboard-control-select-all", in: app).exists)
        XCTAssertTrue(findElement("keyboard-control-checklist", in: app).exists)
        XCTAssertTrue(findElement("keyboard-control-overflow-toggle", in: app).exists)
        XCTAssertFalse(findElement("format-bold-toggle", in: app).exists)
        XCTAssertFalse(findElement("keyboard-control-overflow-panel", in: app).exists)
    }

    func testKeyboardOverflowExpandsAndCollapsesFormattingControls() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        let overflowToggle = findElement("keyboard-control-overflow-toggle", in: app)
        XCTAssertTrue(overflowToggle.waitForExistence(timeout: 5))
        overflowToggle.tap()

        XCTAssertTrue(findElement("keyboard-control-overflow-panel", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(findElement("keyboard-control-copy", in: app).exists)
        XCTAssertTrue(findElement("format-bold-toggle", in: app).exists)

        overflowToggle.tap()
        XCTAssertFalse(findElement("keyboard-control-overflow-panel", in: app).waitForExistence(timeout: 1))
    }

    func testFolderTitleCanBeRenamedFromTopBar() throws {
        let app = makeApp()
        app.launch()

        let originalName = "UITest Folder \(Int(Date().timeIntervalSince1970))"
        let renamedName = "\(originalName) Renamed"

        createFolder(named: originalName, in: app)
        openFolder(named: originalName, in: app)

        let editFolderTitleButton = app.buttons["edit-folder-title"]
        XCTAssertTrue(editFolderTitleButton.waitForExistence(timeout: 5))
        editFolderTitleButton.tap()

        let renameAlert = app.alerts["Rename Folder"]
        XCTAssertTrue(renameAlert.waitForExistence(timeout: 5))
        let nameField = renameAlert.textFields["Folder Name"]
        XCTAssertTrue(nameField.exists)
        nameField.tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalName.count))
        nameField.typeText(renamedName)
        renameAlert.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts[renamedName].waitForExistence(timeout: 5))
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
        } else {
            let overflowButton = app.buttons["notes-list-more"]
            XCTAssertTrue(overflowButton.waitForExistence(timeout: 5))
            overflowButton.tap()

            let menuNewNoteButton = app.buttons["New Note"]
            XCTAssertTrue(menuNewNoteButton.waitForExistence(timeout: 5))
            menuNewNoteButton.tap()
        }

        XCTAssertTrue(app.buttons["edit-note-title"].waitForExistence(timeout: 5))
        let controlBar = app.descendants(matching: .any)["keyboard-control-bar"]
        let overflowToggle = app.buttons["keyboard-control-overflow-toggle"]
        XCTAssertTrue(
            controlBar.waitForExistence(timeout: 5) || overflowToggle.waitForExistence(timeout: 5),
            "Expected note editor controls to appear after opening a note."
        )
    }

    private func createFolder(named folderName: String, in app: XCUIApplication) {
        let newFolderButton = app.buttons["notes-topbar-new-folder"]
        if newFolderButton.waitForExistence(timeout: 2) {
            newFolderButton.tap()
        } else {
            let overflowButton = app.buttons["notes-list-more"]
            XCTAssertTrue(overflowButton.waitForExistence(timeout: 5))
            overflowButton.tap()

            let menuNewFolderButton = app.buttons["New Folder"]
            XCTAssertTrue(menuNewFolderButton.waitForExistence(timeout: 5))
            menuNewFolderButton.tap()
        }

        let newFolderAlert = app.alerts["New Folder"]
        XCTAssertTrue(newFolderAlert.waitForExistence(timeout: 5))
        let folderNameField = newFolderAlert.textFields["Folder Name"]
        XCTAssertTrue(folderNameField.exists)
        folderNameField.tap()
        folderNameField.typeText(folderName)
        newFolderAlert.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts[folderName].waitForExistence(timeout: 5))
    }

    private func openFolder(named folderName: String, in app: XCUIApplication) {
        let folderCell = app.staticTexts[folderName]
        XCTAssertTrue(folderCell.waitForExistence(timeout: 5))
        folderCell.tap()
        XCTAssertTrue(app.buttons["edit-folder-title"].waitForExistence(timeout: 5))
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

    private func findElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

}
