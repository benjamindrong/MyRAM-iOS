import Foundation
import XCTest
@testable import MyRAM

@MainActor
final class MarkdownPreviewIntegrationTests: XCTestCase {

    // MARK: - Mode Selection Policy Tests

    func testModeAfterSelectionChangeDifferentIDResetsToEdit() {
        let oldID = UUID()
        let newID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: oldID,
            newID: newID
        )
        XCTAssertEqual(mode, .edit, "Selecting a different note MUST reset mode to Edit")
    }

    func testModeAfterSelectionChangeSameIDPreservesPreview() {
        let sameID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: sameID,
            newID: sameID
        )
        XCTAssertEqual(mode, .preview, "Same-note selection MUST preserve current Preview mode")
    }

    func testModeAfterSelectionChangeNilToIDResetsToEdit() {
        let newID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: nil,
            newID: newID
        )
        XCTAssertEqual(mode, .edit, "Nil to new note selection MUST reset mode to Edit")
    }

    func testModeAfterSelectionChangeIDToNilResetsToEdit() {
        let oldID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: oldID,
            newID: nil
        )
        XCTAssertEqual(mode, .edit, "Note removal (ID to nil) MUST reset mode to Edit")
    }

    func testFocusRequestEquality() {
        let uuid = UUID()
        let req1 = MarkdownPreviewFocusRequest(id: uuid)
        let req2 = MarkdownPreviewFocusRequest(id: uuid)
        let req3 = MarkdownPreviewFocusRequest(id: UUID())

        XCTAssertEqual(req1, req2)
        XCTAssertNotEqual(req1, req3)
    }
}
