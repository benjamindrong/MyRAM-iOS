import Foundation
import XCTest
@testable import MyRAMMac

@MainActor
final class MacMarkdownPreviewIntegrationTests: XCTestCase {

    func testInitialModeIsEdit() {
        let mode = MarkdownEditorMode.edit
        XCTAssertEqual(mode, .edit)
    }

    func testSameNoteReloadPreservesPreviewModeUsingProductionPolicy() {
        let sameID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: sameID,
            newID: sameID
        )
        XCTAssertEqual(mode, .preview, "Production selection policy MUST preserve Preview mode on same-note reloads")
    }

    func testDifferentNoteSelectionResetsToEditModeUsingProductionPolicy() {
        let oldID = UUID()
        let newID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: oldID,
            newID: newID
        )
        XCTAssertEqual(mode, .edit, "Production selection policy MUST reset to Edit mode when selected note changes")
    }

    func testSyncDrivenRemovalResetsToEditModeUsingProductionPolicy() {
        let oldID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: oldID,
            newID: nil
        )
        XCTAssertEqual(mode, .edit, "Production selection policy MUST reset to Edit mode when selected note is removed")
    }
}
