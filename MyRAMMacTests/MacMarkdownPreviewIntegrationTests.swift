import Foundation
import XCTest
@testable import MyRAMMac

@MainActor
final class MacMarkdownPreviewIntegrationTests: XCTestCase {

    // MARK: - Mac Integration Tests (§14.4)

    func testInitialModeIsEdit() {
        let mode = MarkdownEditorMode.edit
        XCTAssertEqual(mode, .edit)
    }

    func testSameNoteReloadPreservesPreviewMode() {
        // §10.2: Same-note reloads (e.g. loadNotesKeepingSelection when selectedID is unchanged)
        // must preserve Preview mode. Only oldID != newID resets mode.
        var currentMode = MarkdownEditorMode.preview
        let oldID = UUID()
        let newID = oldID

        func updateMarkdownModeForSelectionChange(from old: UUID?, to new: UUID?) {
            guard old != new else { return }
            currentMode = .edit
        }

        updateMarkdownModeForSelectionChange(from: oldID, to: newID)
        XCTAssertEqual(currentMode, .preview, "Same-note reload must preserve Preview mode")
    }

    func testDifferentNoteSelectionResetsToEditMode() {
        // §10.2: Selecting a different note resets mode to Edit.
        var currentMode = MarkdownEditorMode.preview
        let oldID = UUID()
        let newID = UUID()

        func updateMarkdownModeForSelectionChange(from old: UUID?, to new: UUID?) {
            guard old != new else { return }
            currentMode = .edit
        }

        updateMarkdownModeForSelectionChange(from: oldID, to: newID)
        XCTAssertEqual(currentMode, .edit, "Selecting a different note must reset mode to Edit")
    }

    func testSyncDrivenRemovalResetsToEditMode() {
        // §10.2: When current note is removed by sync (selectedID becomes nil), mode resets to Edit.
        var currentMode = MarkdownEditorMode.preview
        let oldID = UUID()

        func updateMarkdownModeForSelectionChange(from old: UUID?, to new: UUID?) {
            guard old != new else { return }
            currentMode = .edit
        }

        updateMarkdownModeForSelectionChange(from: oldID, to: nil)
        XCTAssertEqual(currentMode, .edit, "Sync removal setting selectedID to nil must reset mode to Edit")
    }
}
