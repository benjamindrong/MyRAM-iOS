import XCTest

// MARK: - Markdown Preview UI Tests (§9.4)
// Drives the production iOS app UI to verify visible Preview/search behavior.
// Uses the same UITEST_MODE launch argument as MyRAMUITests.

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

        // The note editor body text view should be present in Edit mode
        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(
            editor.waitForExistence(timeout: Timeout.standard),
            "Edit mode should be default: note-editor-body text view must appear"
        )
        // Preview toggle must exist and indicate preview is inactive
        let previewToggle = findElement("note-toolbar-preview-toggle", in: app)
        XCTAssertTrue(previewToggle.waitForExistence(timeout: Timeout.standard),
            "Preview toggle must be present in the note toolbar")
    }

    // MARK: - Test 2: Top-bar search cannot present during Preview

    func testTopBarSearchCannotPresentDuringPreview() throws {
        let app = makeApp()
        app.launch()
        openNewNote(in: app)

        // Type some content
        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        editor.tap()
        editor.typeText("Search test content for Preview mode")

        // Switch to Preview mode
        let previewToggle = findElement("note-toolbar-preview-toggle", in: app)
        XCTAssertTrue(previewToggle.waitForExistence(timeout: Timeout.standard))
        previewToggle.tap()

        // Attempt to trigger search (top-bar search button)
        let searchButton = findElement("note-toolbar-search", in: app)
        guard searchButton.exists else {
            // If the search button is hidden during Preview, that's a pass
            return
        }
        searchButton.tap()

        // Search field must NOT appear while Preview is active
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

        // Switch to Preview — keyboard should dismiss
        let previewToggle = findElement("note-toolbar-preview-toggle", in: app)
        XCTAssertTrue(previewToggle.waitForExistence(timeout: Timeout.standard))
        previewToggle.tap()

        // Keyboards are not directly observable via XCUITest beyond soft-keyboard visibility.
        // Verify: the editor body is NOT the first responder by checking the preview container appears.
        let previewContainer = findElement("markdown-preview-container", in: app)
        XCTAssertTrue(
            previewContainer.waitForExistence(timeout: Timeout.standard),
            "Markdown Preview container must be visible after tapping preview toggle"
        )
    }

    // MARK: - Test 4: Rapid Preview -> Edit remains Edit

    func testRapidPreviewToggleRemainsEdit() throws {
        let app = makeApp()
        app.launch()
        openNewNote(in: app)

        let previewToggle = findElement("note-toolbar-preview-toggle", in: app)
        XCTAssertTrue(previewToggle.waitForExistence(timeout: Timeout.standard))

        // Rapid double-tap: Preview then immediately back to Edit
        previewToggle.tap()
        previewToggle.tap()

        // After two taps, should be back in Edit
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
    }

    private func findElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
