import XCTest

// MARK: - Markdown Preview UI Tests (§10 & §8 Sixth Remediation)
// Drives the production iOS app UI to verify visible Preview/search behavior using exact identifiers.
// All tests contain non-vacuous assertions and no silent missing-control success paths.

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
        XCTAssertTrue(
            modePicker.waitForExistence(timeout: Timeout.standard),
            "Markdown mode picker must be present above editor surface"
        )
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

        assertSearchAvailableInEdit(in: app)
        switchToPreviewMode(in: app)
        assertSearchUnavailableInPreview(in: app)

        let searchField = findElement("current-note-search-field", in: app)
        XCTAssertFalse(
            searchField.waitForExistence(timeout: Timeout.short),
            "Search field MUST NOT appear while Markdown Preview is active"
        )
    }

    // MARK: - Test 3: Keyboard dismissal and non-reappearance in Preview

    func testEditorDismissesKeyboardAndDoesNotRegainFocusInPreview() throws {
        let app = makeApp()
        app.launch()
        openNewNote(in: app)

        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        editor.tap()
        editor.typeText("Keyboard focus test content")

        // Assert keyboard is active while editing
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: Timeout.short),
            "Keyboard MUST appear when text view is focused and typed into"
        )

        switchToPreviewMode(in: app)

        let reminder = findElement("markdown-preview-reminder", in: app)
        XCTAssertTrue(
            reminder.waitForExistence(timeout: Timeout.standard),
            "The shared iPhone Preview container must expose markdown-preview-reminder"
        )
        let previewBody = findElement("markdown-preview-body", in: app)
        let fallbackBody = findElement("markdown-preview-fallback", in: app)
        XCTAssertTrue(
            previewBody.waitForExistence(timeout: Timeout.standard),
            "Valid plain text MUST use the rendered Markdown document path"
        )
        XCTAssertFalse(fallbackBody.exists, "Valid plain text MUST NOT use parser-failure fallback")

        // Assert keyboard is dismissed upon entering Preview
        XCTAssertFalse(
            app.keyboards.element.exists,
            "Keyboard MUST be dismissed when entering Markdown Preview"
        )

        // Wait beyond acknowledgment window to verify keyboard does not reappear
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertFalse(
            app.keyboards.element.exists,
            "Keyboard MUST NOT reappear unexpectedly while Preview remains active"
        )
    }

    // MARK: - Test 4: Pending-transition race immediately cancelled to Edit

    func testRapidPreviewToggleRemainsEdit() throws {
        let app = makeApp()
        app.launch()
        openNewNote(in: app)

        let picker = app.segmentedControls["markdown-mode-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: Timeout.standard), "Mode picker MUST exist")

        let previewButton = picker.buttons["Preview"]
        let editButton = picker.buttons["Edit"]

        XCTAssertTrue(previewButton.waitForExistence(timeout: Timeout.short))
        XCTAssertTrue(editButton.waitForExistence(timeout: Timeout.short))

        // Tap Preview, then immediately tap Edit WITHOUT waiting for Preview body
        previewButton.tap()
        editButton.tap()

        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(
            editor.waitForExistence(timeout: Timeout.standard),
            "Rapid Preview->Edit toggle MUST leave editor in Edit mode"
        )

        // Wait beyond acknowledgment interval and confirm Preview body never appeared
        Thread.sleep(forTimeInterval: 1.0)
        let previewBody = findElement("markdown-preview-body", in: app)
        XCTAssertFalse(
            previewBody.exists,
            "Preview body MUST NEVER appear after rapid cancellation back to Edit"
        )
    }

    // MARK: - Test 5: Unsaved Markdown renders in Preview

    func testUnsavedMarkdownAppearsInPreview() throws {
        let app = makeApp()
        app.launch()
        openNewNote(in: app)

        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        editor.tap()
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: Timeout.standard),
            "The note editor must acquire keyboard focus before entering Markdown"
        )
        editor.typeText("# Header Title\n1. First item\n2. Second item")

        switchToPreviewMode(in: app)

        let previewBody = findElement("markdown-preview-body", in: app)
        let fallbackBody = findElement("markdown-preview-fallback", in: app)
        XCTAssertTrue(
            previewBody.waitForExistence(timeout: Timeout.standard),
            "Unsaved valid Markdown MUST render through the document path"
        )
        XCTAssertFalse(fallbackBody.exists, "Valid Markdown MUST NOT use plain-text fallback")

        let heading = findElement("markdown-preview-heading", in: app)
        XCTAssertTrue(heading.waitForExistence(timeout: Timeout.standard))
        XCTAssertTrue(heading.label.contains("Header Title"))

        let orderedRows = app.descendants(matching: .any)
            .matching(identifier: "markdown-preview-ordered-list-item")
        XCTAssertTrue(waitForElementCount(orderedRows, count: 2, timeout: Timeout.standard))
        let orderedLabels = orderedRows.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(orderedLabels.contains { $0.contains("1.") && $0.contains("First item") })
        XCTAssertTrue(orderedLabels.contains { $0.contains("2.") && $0.contains("Second item") })
    }

    // MARK: - Test 6: Mixed nested Markdown renders with stable semantics

    func testMixedNestedListRendersWithoutFallback() throws {
        let app = makeApp()
        app.launch()
        openNewNote(in: app)

        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        editor.tap()
        editor.typeText("1. Ordered parent\n   - Nested bullet")

        switchToPreviewMode(in: app)

        XCTAssertTrue(findElement("markdown-preview-body", in: app).waitForExistence(timeout: Timeout.standard))
        XCTAssertFalse(findElement("markdown-preview-fallback", in: app).exists)

        let orderedRows = app.descendants(matching: .any)
            .matching(identifier: "markdown-preview-ordered-list-item")
        let unorderedRows = app.descendants(matching: .any)
            .matching(identifier: "markdown-preview-unordered-list-item")
        XCTAssertTrue(waitForElementCount(orderedRows, count: 1, timeout: Timeout.standard))
        XCTAssertTrue(waitForElementCount(unorderedRows, count: 1, timeout: Timeout.standard))
        XCTAssertTrue(orderedRows.element(boundBy: 0).label.contains("Ordered parent"))
        XCTAssertTrue(unorderedRows.element(boundBy: 0).label.contains("Nested bullet"))
    }

    // MARK: - Test 7: Different note selection resets to Edit mode

    func testDifferentNoteSelectionResetsToEditMode() throws {
        let app = makeApp()
        app.launch()
        openNewNote(in: app)

        switchToPreviewMode(in: app)
        let previewBody = findElement("markdown-preview-body", in: app)
        let fallbackBody = findElement("markdown-preview-fallback", in: app)
        XCTAssertTrue(
            previewBody.waitForExistence(timeout: Timeout.standard)
        )
        XCTAssertFalse(fallbackBody.exists)

        createAnotherNoteFromEditor(in: app)

        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(
            editor.waitForExistence(timeout: Timeout.standard),
            "Creating or selecting a different note MUST reset mode to Edit"
        )
    }

    // MARK: - Helpers

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("UITEST_MODE")
        return app
    }

    private func openNewNote(in app: XCUIApplication) {
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.waitForExistence(timeout: Timeout.short) && backButton.isHittable {
            backButton.tap()
        }

        let quickActionButton = app.buttons["notes-topbar-new-note"]
        if quickActionButton.waitForExistence(timeout: Timeout.short) {
            quickActionButton.tap()
        } else {
            let overflowButton = app.buttons["notes-list-more"]
            XCTAssertTrue(overflowButton.waitForExistence(timeout: Timeout.standard), "New Note or overflow button MUST be present")
            overflowButton.tap()

            let menuNewNoteButton = app.buttons["New Note"]
            XCTAssertTrue(menuNewNoteButton.waitForExistence(timeout: Timeout.standard), "'New Note' menu item MUST be present")
            menuNewNoteButton.tap()
        }

        XCTAssertTrue(app.buttons["edit-note-title"].waitForExistence(timeout: Timeout.standard), "Note title editor MUST appear")
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
            XCTAssertTrue(previewButton.waitForExistence(timeout: Timeout.short), "'Preview' button MUST exist on mode picker")
            previewButton.tap()
            return
        }
        let previewButton = app.buttons["Preview"]
        if previewButton.waitForExistence(timeout: Timeout.short) {
            previewButton.tap()
            return
        }
        let previewTag = app.descendants(matching: .any)["markdown-preview-mode"]
        XCTAssertTrue(previewTag.waitForExistence(timeout: Timeout.standard), "Preview mode element MUST exist")
        previewTag.tap()
    }

    private func switchToEditMode(in app: XCUIApplication) {
        let picker = app.segmentedControls["markdown-mode-picker"]
        if picker.waitForExistence(timeout: Timeout.short) {
            let editButton = picker.buttons["Edit"]
            XCTAssertTrue(editButton.waitForExistence(timeout: Timeout.short), "'Edit' button MUST exist on mode picker")
            editButton.tap()
            return
        }
        let editButton = app.buttons["Edit"]
        if editButton.waitForExistence(timeout: Timeout.short) {
            editButton.tap()
            return
        }
        let editTag = app.descendants(matching: .any)["markdown-edit-mode"]
        XCTAssertTrue(editTag.waitForExistence(timeout: Timeout.standard), "Edit mode element MUST exist")
        editTag.tap()
    }

    private func assertSearchAvailableInEdit(in app: XCUIApplication) {
        let visibleSearch = app.buttons["topbar-search-note"]
        if visibleSearch.waitForExistence(timeout: Timeout.short) {
            XCTAssertTrue(visibleSearch.isEnabled, "Visible Edit search action MUST be enabled")
            return
        }

        let overflow = app.buttons["note-editor-more"]
        XCTAssertTrue(
            overflow.waitForExistence(timeout: Timeout.standard),
            "Edit MUST expose search directly or through the note-editor overflow"
        )
        overflow.tap()
        let menuSearch = app.buttons["Search Note"]
        XCTAssertTrue(menuSearch.waitForExistence(timeout: Timeout.standard), "Edit overflow MUST contain Search Note")
        XCTAssertTrue(menuSearch.isEnabled, "Edit overflow Search Note action MUST be enabled")
        app.tap()
    }

    private func assertSearchUnavailableInPreview(in app: XCUIApplication) {
        let visibleSearch = app.buttons["topbar-search-note"]
        if visibleSearch.waitForExistence(timeout: Timeout.short) {
            XCTAssertFalse(visibleSearch.isEnabled, "Visible Preview search action MUST be disabled")
            return
        }

        let overflow = app.buttons["note-editor-more"]
        XCTAssertTrue(
            overflow.waitForExistence(timeout: Timeout.standard),
            "Preview note-editor overflow MUST remain discoverable when search is not visible"
        )
        overflow.tap()
        let menuSearch = app.buttons["Search Note"]
        XCTAssertTrue(
            menuSearch.waitForExistence(timeout: Timeout.standard),
            "Preview overflow MUST expose a disabled Search Note action rather than silently skipping the assertion"
        )
        XCTAssertFalse(menuSearch.isEnabled, "Preview overflow Search Note action MUST be disabled")
        app.tap()
    }

    private func createAnotherNoteFromEditor(in app: XCUIApplication) {
        let visibleNewNote = app.buttons["topbar-new-note"]
        if visibleNewNote.waitForExistence(timeout: Timeout.short) {
            XCTAssertTrue(visibleNewNote.isEnabled)
            visibleNewNote.tap()
            return
        }

        let overflow = app.buttons["note-editor-more"]
        XCTAssertTrue(
            overflow.waitForExistence(timeout: Timeout.standard),
            "The editor MUST expose New Note directly or through its overflow"
        )
        overflow.tap()
        let menuNewNote = app.buttons["New Note"]
        XCTAssertTrue(menuNewNote.waitForExistence(timeout: Timeout.standard))
        XCTAssertTrue(menuNewNote.isEnabled)
        menuNewNote.tap()
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

    private func waitForElementCount(
        _ query: XCUIElementQuery,
        count: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if query.count == count {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return query.count == count
    }

}
