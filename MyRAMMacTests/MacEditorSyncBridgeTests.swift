import AppKit
import XCTest
@testable import MyRAMMac

@MainActor
final class MacEditorSyncBridgeTests: XCTestCase {
    func testSelectedInsertionMutatesTextStorageIncrementallyAndPublishesOnce() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        let bridge = MacEditorSyncBridge()
        bridge.textView = textView
        var published: [String] = []
        bridge.publishAttributedText = { published.append($0.string) }

        let result = bridge.applyBatch(
            [.applyBodyInsertion(MacAppliedBodyInsertion(noteID: noteID, utf16Offset: 5, text: "!", modifiedAt: Date()))],
            selectedNoteID: noteID
        )

        XCTAssertEqual(textView.string, "Hello!")
        XCTAssertEqual(result, MacEditorRemoteBatchApplyResult(appliedCount: 1, requiresFallbackReload: false))
        XCTAssertEqual(published, ["Hello!"])
    }

    func testSelectedDeletionMutatesTextStorageIncrementally() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let bridge = MacEditorSyncBridge()
        bridge.textView = textView

        let result = bridge.applyBatch(
            [
                .applyBodyDeletion(
                    MacAppliedBodyDeletion(
                        noteID: noteID,
                        range: NSRange(location: 1, length: 2),
                        deletedText: "el",
                        modifiedAt: Date()
                    )
                )
            ],
            selectedNoteID: noteID
        )

        XCTAssertEqual(textView.string, "Hlo")
        XCTAssertEqual(result, MacEditorRemoteBatchApplyResult(appliedCount: 1, requiresFallbackReload: false))
    }

    func testDeletionMismatchRequiresFallbackWithoutMutatingText() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let bridge = MacEditorSyncBridge()
        bridge.textView = textView

        let result = bridge.applyBatch(
            [
                .applyBodyDeletion(
                    MacAppliedBodyDeletion(
                        noteID: noteID,
                        range: NSRange(location: 1, length: 2),
                        deletedText: "xx",
                        modifiedAt: Date()
                    )
                )
            ],
            selectedNoteID: noteID
        )

        XCTAssertEqual(textView.string, "Hello")
        XCTAssertEqual(result, MacEditorRemoteBatchApplyResult(appliedCount: 0, requiresFallbackReload: true))
    }

    func testInsertionBeforeCaretShiftsSelectionForward() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        let bridge = MacEditorSyncBridge()
        bridge.textView = textView

        _ = bridge.applyBatch(
            [.applyBodyInsertion(MacAppliedBodyInsertion(noteID: noteID, utf16Offset: 0, text: "Say ", modifiedAt: Date()))],
            selectedNoteID: noteID
        )

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 9, length: 0))
    }

    func testNonSelectedActionIsIgnored() {
        let selectedID = UUID()
        let textView = makeTextView("Hello")
        let bridge = MacEditorSyncBridge()
        bridge.textView = textView

        let result = bridge.applyBatch(
            [.applyBodyInsertion(MacAppliedBodyInsertion(noteID: UUID(), utf16Offset: 0, text: "x", modifiedAt: Date()))],
            selectedNoteID: selectedID
        )

        XCTAssertEqual(textView.string, "Hello")
        XCTAssertEqual(result, MacEditorRemoteBatchApplyResult(appliedCount: 0, requiresFallbackReload: false))
    }

    private func makeTextView(_ string: String) -> NSTextView {
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(NSAttributedString(string: string))
        return textView
    }
}
