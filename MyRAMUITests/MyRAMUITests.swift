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

    /// Opt-in physical acceptance against the preserved Verification fixture.
    /// Uses the installed app and its ordinary restoration flow, without a test store or reset.
    func testMYR233PhysicalRetainedNoteRestoration() throws {
        guard ProcessInfo.processInfo.environment["MYR233_PHYSICAL_RESTORATION"] == "1" else {
            throw XCTSkip("Requires explicitly bound physical Verification acceptance")
        }
        let app = XCUIApplication(bundleIdentifier: "com.northsignalstudio.myram.verification")
        app.activate()
        let more = app.buttons["notes-list-more"]
        XCTAssertTrue(more.waitForExistence(timeout: Timeout.standard))
        more.tap()
        let deleted = app.buttons["Recently Deleted"]
        XCTAssertTrue(deleted.waitForExistence(timeout: Timeout.standard))
        deleted.tap()
        let includeExpired = app.descendants(matching: .any)["verification-retained-deleted-notes"].firstMatch
        XCTAssertTrue(includeExpired.waitForExistence(timeout: Timeout.standard),
                      "Restoration requires the app's immutable Verification identity and service gate")
        includeExpired.tap()
        let ids = ["4F390252-1147-4575-B855-BCE319D88B0D", "DBC72F2B-EA8B-4309-980D-428FFF0A10D0"]
        // Both retained parents must exist before either is restored.
        for id in ids {
            XCTAssertTrue(app.descendants(matching: .any)["deleted-note-\(id)"].firstMatch
                .waitForExistence(timeout: Timeout.standard))
        }
        for id in ids {
            let row = app.descendants(matching: .any)["deleted-note-\(id)"].firstMatch
            row.swipeRight()
            let restore = app.buttons["Restore"].firstMatch
            XCTAssertTrue(restore.waitForExistence(timeout: Timeout.standard))
            restore.tap()
            let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: Timeout.standard), .completed)
        }
        app.buttons["Done"].tap()
    }

    /// Runs only against an explicitly prepared, synthetic Verification container.
    func testMYR238VerificationOfflineEditingAndRelaunch() throws {
        guard ProcessInfo.processInfo.environment["MYR238_VERIFICATION_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires the isolated MYR-238 synthetic journal fixture")
        }
        let app = XCUIApplication(bundleIdentifier: "com.northsignalstudio.myram.verification")
        app.launch()
        XCTAssertTrue(app.buttons["Retry Sync"].waitForExistence(timeout: Timeout.standard))
        openNewNote(in: app)
        app.buttons["edit-note-title"].tap()
        let titleAlert = app.alerts["Edit Title"]
        XCTAssertTrue(titleAlert.waitForExistence(timeout: Timeout.standard))
        replaceText(in: titleAlert.textFields.firstMatch, with: "MYR238 Synthetic Offline", fallbackExistingText: "Untitled")
        titleAlert.buttons["Save"].tap()
        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        editor.tap()
        editor.typeText("MYR238 synthetic durable offline text")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Retry Sync"].waitForExistence(timeout: Timeout.standard))
        // Repeated recovery failure must leave the locally saved note available.
        app.buttons["Retry Sync"].tap()
        let row = app.staticTexts["MYR238 Synthetic Offline"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.standard))
        row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        XCTAssertEqual(editor.value as? String, "MYR238 synthetic durable offline text")
    }

    func testMYR238VerificationRecoveryPreservesOfflineText() throws {
        guard ProcessInfo.processInfo.environment["MYR238_VERIFICATION_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires the isolated MYR-238 synthetic recovery fixture")
        }
        let app = XCUIApplication(bundleIdentifier: "com.northsignalstudio.myram.verification")
        app.launch()
        let row = app.staticTexts["MYR238 Synthetic Offline"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.standard))
        row.tap()
        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        XCTAssertFalse(app.buttons["Retry Sync"].exists)
        XCTAssertEqual(editor.value as? String, "MYR238 synthetic durable offline text")
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
        tapOverflowToggle(overflowToggle)

        XCTAssertTrue(findElement("keyboard-control-overflow-panel", in: app).waitForExistence(timeout: Timeout.standard))
        XCTAssertTrue(findElement("format-bold-toggle", in: app).exists)

        tapOverflowToggle(overflowToggle)
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

        // After a rename we're still on the folder-detail screen, where the title
        // is the "edit-folder-title" button (confirmed by openFolder's own check
        // above) — not a static text, so only this locator can ever match here.
        XCTAssertTrue(folderTitleButton(named: renamedName, in: app).waitForExistence(timeout: Timeout.standard))
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
            waitForAnyElement([controlBar, pinButton], timeout: Timeout.standard),
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

    private func tapOverflowToggle(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.waitForExistence(timeout: Timeout.short), "keyboard-control-overflow-toggle not found")
        toggle.tap()
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

    private func waitForAnyElement(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: \.exists) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return elements.contains(where: \.exists)
    }

    private func folderTitleButton(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "edit-folder-title")
            .matching(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch
    }
}
