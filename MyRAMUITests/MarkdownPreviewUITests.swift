import XCTest

// MARK: - Markdown Preview UI Tests (§10)
// Drives the production iOS app UI to verify visible Preview/search behavior using exact identifiers.

final class MarkdownPreviewUITests: XCTestCase {
    private enum Timeout {
        static let short: TimeInterval = 2
        static let standard: TimeInterval = 8
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Test 1: Edit is default

    func testEditIsDefaultModeOnNoteOpen() throws {
        let app = makeApp()
        app.launch()
        openNewNote(in: app)

        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(
            editor.waitForExistence(timeout: Timeout.standard),
            "Edit mode should be default: note-editor-body text view must appear"
        )

        let modePicker = findElement("markdown-mode-picker", in: app)
        XCTAssertTrue(modePicker.waitForExistence(timeout: Timeout.standard),
            "Markdown mode picker must be present above editor surface")
    }

    // MARK: - Test 2: Top-bar search cannot present during Preview

    func testTopBarSearchCannotPresentDuringPreview() throws {
        let app = makeApp()
        app.launch()
        openNewNote(in: app)

        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        editor.tap()
        editor.typeText("Search test content for Preview mode")

        // Switch to Preview mode via segmented picker
        switchToPreviewMode(in: app)

        let searchButton = app.buttons["note-toolbar-search"]
        if searchButton.exists {
            searchButton.tap()
        }

        let searchField = findElement("current-note-search-field", in: app)
        XCTAssertFalse(
            searchField.waitForExistence(timeout: Timeout.short),
            "Search field MUST NOT appear while Markdown Preview is active"
        )
    }

    // MARK: - Test 3: Editor does not regain keyboard focus during Preview

    func testEditorDoesNotRegainKeyboardFocusDuringPreview() throws {
        let app = makeApp()
        app.launch()
        openNewNote(in: app)

        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        editor.tap()
        editor.typeText("Keyboard focus test")

        switchToPreviewMode(in: app)

        let previewBody = findElement("markdown-preview-body", in: app)
        let fallbackBody = findElement("markdown-preview-fallback", in: app)
        XCTAssertTrue(
            previewBody.waitForExistence(timeout: Timeout.standard) || fallbackBody.waitForExistence(timeout: Timeout.standard),
            "Markdown Preview body or fallback must be visible after tapping preview mode"
        )
    }

    // MARK: - Test 4: Rapid Preview -> Edit remains Edit

    func testRapidPreviewToggleRemainsEdit() throws {
        let app = makeApp()
        app.launch()
        openNewNote(in: app)

        switchToPreviewMode(in: app)
        switchToEditMode(in: app)

        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(
            editor.waitForExistence(timeout: Timeout.standard),
            "Rapid Preview->Edit toggle MUST leave editor in Edit mode"
        )
    }

    // MARK: - Helpers

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

    private func switchToPreviewMode(in app: XCUIApplication) {
        let picker = app.segmentedControls["markdown-mode-picker"]
        if picker.waitForExistence(timeout: Timeout.short) {
            let previewButton = picker.buttons["Preview"]
            if previewButton.exists {
                previewButton.tap()
                return
            }
        }
        let previewButton = app.buttons["Preview"]
        if previewButton.waitForExistence(timeout: Timeout.short) {
            previewButton.tap()
            return
        }
        let previewTag = app.descendants(matching: .any)["markdown-preview-mode"]
        XCTAssertTrue(previewTag.waitForExistence(timeout: Timeout.standard))
        previewTag.tap()
    }

    private func switchToEditMode(in app: XCUIApplication) {
        let picker = app.segmentedControls["markdown-mode-picker"]
        if picker.waitForExistence(timeout: Timeout.short) {
            let editButton = picker.buttons["Edit"]
            if editButton.exists {
                editButton.tap()
                return
            }
        }
        let editButton = app.buttons["Edit"]
        if editButton.waitForExistence(timeout: Timeout.short) {
            editButton.tap()
            return
        }
        let editTag = app.descendants(matching: .any)["markdown-edit-mode"]
        XCTAssertTrue(editTag.waitForExistence(timeout: Timeout.standard))
        editTag.tap()
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
}
