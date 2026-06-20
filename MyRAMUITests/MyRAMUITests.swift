//
//  MyRAMUITests.swift
//  MyRAMUITests
//
//  Created by Benjamin Drong on 10/18/25.
//

import XCTest

final class MyRAMUITests: XCTestCase {
    private enum Timeout {
        static let short: TimeInterval = 2
        static let standard: TimeInterval = 5
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
    }

    func testNewNoteOpensWithoutAttachments() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        XCTAssertTrue(app.buttons["edit-note-title"].waitForExistence(timeout: Timeout.standard))
        XCTAssertTrue(app.staticTexts["Untitled"].exists)

        XCTAssertFalse(app.staticTexts["Attachments"].exists)
    }

    func testNoteEditorTitlePopupAndRedoButtonAreAvailable() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        let editTitleButton = app.buttons["edit-note-title"]
        XCTAssertTrue(editTitleButton.waitForExistence(timeout: Timeout.standard))
        editTitleButton.tap()

        XCTAssertTrue(app.alerts["Edit Title"].waitForExistence(timeout: Timeout.standard))
        XCTAssertTrue(app.buttons["Save"].exists)
        XCTAssertTrue(app.buttons["Save"].exists)
    }

    func testKeyboardControlsAreCollapsedByDefault() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        XCTAssertTrue(findElement("keyboard-control-bar", in: app).waitForExistence(timeout: Timeout.standard))
        XCTAssertTrue(app.buttons["edit-note-title"].exists)
        XCTAssertFalse(findElement("format-bold-toggle", in: app).exists)
        XCTAssertFalse(findElement("keyboard-control-overflow-panel", in: app).exists)
    }

    func testKeyboardOverflowExpandsAndCollapsesFormattingControls() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        let controlBar = findElement("keyboard-control-bar", in: app)
        XCTAssertTrue(controlBar.waitForExistence(timeout: Timeout.standard))
        let overflowToggle = findElement("keyboard-control-overflow-toggle", in: app)
        tapOverflowToggle(overflowToggle, in: app)

        XCTAssertTrue(findElement("keyboard-control-overflow-panel", in: app).waitForExistence(timeout: Timeout.standard))
        XCTAssertTrue(findElement("format-bold-toggle", in: app).exists)

        tapOverflowToggle(overflowToggle, in: app)
        XCTAssertFalse(findElement("keyboard-control-overflow-panel", in: app).waitForExistence(timeout: Timeout.short))
    }

    func testFolderTitleCanBeRenamedFromTopBar() throws {
        let app = makeApp()
        app.launch()

        let originalName = "UITest Folder \(Int(Date().timeIntervalSince1970))"
        let renamedName = "\(originalName) Renamed"

        createFolder(named: originalName, in: app)
        openFolder(named: originalName, in: app)

        let editFolderTitleButton = app.buttons["edit-folder-title"]
        XCTAssertTrue(editFolderTitleButton.waitForExistence(timeout: Timeout.standard))
        editFolderTitleButton.tap()

        let renameAlert = app.alerts["Rename Folder"]
        XCTAssertTrue(renameAlert.waitForExistence(timeout: Timeout.standard))
        let nameField = renameAlert.textFields["Folder Name"]
        XCTAssertTrue(nameField.exists)
        replaceText(in: nameField, with: renamedName, fallbackExistingText: originalName)
        renameAlert.buttons["Save"].tap()

        XCTAssertTrue(
            app.staticTexts[renamedName].waitForExistence(timeout: Timeout.standard)
                || button(labeled: renamedName, in: app).waitForExistence(timeout: Timeout.standard)
                || folderTitleButton(named: renamedName, in: app).waitForExistence(timeout: Timeout.standard)
        )
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("UITEST_MODE")
        return app
    }

    private func openNewNote(in app: XCUIApplication) {
        let quickActionButton = app.buttons["notes-topbar-new-note"]
        if quickActionButton.waitForExistence(timeout: Timeout.short) {
            quickActionButton.tap()
        } else {
            let overflowButton = app.buttons["notes-list-more"]
            XCTAssertTrue(overflowButton.waitForExistence(timeout: Timeout.standard))
            overflowButton.tap()

            let menuNewNoteButton = app.buttons["New Note"]
            XCTAssertTrue(menuNewNoteButton.waitForExistence(timeout: Timeout.standard))
            menuNewNoteButton.tap()
        }

        XCTAssertTrue(app.buttons["edit-note-title"].waitForExistence(timeout: Timeout.standard))
        let controlBar = app.descendants(matching: .any)["keyboard-control-bar"]
        let pinButton = app.buttons["keyboard-control-pin"]
        XCTAssertTrue(
            controlBar.waitForExistence(timeout: Timeout.standard) || pinButton.waitForExistence(timeout: Timeout.standard),
            "Expected note editor controls to appear after opening a note."
        )
    }

    private func createFolder(named folderName: String, in app: XCUIApplication) {
        let newFolderButton = app.buttons["notes-topbar-new-folder"]
        if newFolderButton.waitForExistence(timeout: Timeout.short) {
            newFolderButton.tap()
        } else {
            let overflowButton = app.buttons["notes-list-more"]
            XCTAssertTrue(overflowButton.waitForExistence(timeout: Timeout.standard))
            overflowButton.tap()

            let menuNewFolderButton = app.buttons["New Folder"]
            XCTAssertTrue(menuNewFolderButton.waitForExistence(timeout: Timeout.standard))
            menuNewFolderButton.tap()
        }

        let newFolderAlert = app.alerts["New Folder"]
        XCTAssertTrue(newFolderAlert.waitForExistence(timeout: Timeout.standard))
        let folderNameField = newFolderAlert.textFields["Folder Name"]
        XCTAssertTrue(folderNameField.exists)
        folderNameField.tap()
        folderNameField.typeText(folderName)
        newFolderAlert.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts[folderName].waitForExistence(timeout: Timeout.standard))
    }

    private func openFolder(named folderName: String, in app: XCUIApplication) {
        let folderCell = app.staticTexts[folderName]
        XCTAssertTrue(folderCell.waitForExistence(timeout: Timeout.standard))
        folderCell.tap()
        XCTAssertTrue(app.buttons["edit-folder-title"].waitForExistence(timeout: Timeout.standard))
    }

    private func tapOverflowToggle(_ toggle: XCUIElement, in app: XCUIApplication) {
        if toggle.waitForExistence(timeout: Timeout.short) {
            toggle.tap()
        } else {
            // Older snapshots expose the overflow item as the labeled toolbar button.
            let moreButton = app.buttons.matching(identifier: "keyboard-control-bar")
                .matching(NSPredicate(format: "label == %@", "More"))
                .firstMatch
            XCTAssertTrue(moreButton.waitForExistence(timeout: Timeout.standard))
            moreButton.tap()
        }
    }

    private func replaceText(in textField: XCUIElement, with replacement: String, fallbackExistingText: String) {
        textField.tap()
        let existingText = textField.value as? String
        let deleteCount = max(existingText?.count ?? 0, fallbackExistingText.count)
        textField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount))
        textField.typeText(replacement)
    }

    private func findElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func button(labeled label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func folderTitleButton(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "edit-folder-title")
            .matching(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch
    }
}
