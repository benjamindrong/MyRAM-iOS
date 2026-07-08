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
            [.applyBodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 5, text: "!", modifiedAt: Date()))],
            selectedNoteID: noteID
        )

        XCTAssertEqual(textView.string, "Hello!")
        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .applied))
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
                    AppliedEditorBodyDeletion(
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
        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .applied))
    }

    func testDeletionMismatchRequiresFallbackWithoutMutatingText() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let bridge = MacEditorSyncBridge()
        bridge.textView = textView

        let result = bridge.applyBatch(
            [
                .applyBodyDeletion(
                    AppliedEditorBodyDeletion(
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
        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .requiresReload(.deletedTextMismatch)))
    }

    func testInsertionBeforeCaretShiftsSelectionForward() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        let bridge = MacEditorSyncBridge()
        bridge.textView = textView

        _ = bridge.applyBatch(
            [.applyBodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 0, text: "Say ", modifiedAt: Date()))],
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
            [.applyBodyInsertion(AppliedEditorBodyInsertion(noteID: UUID(), utf16Offset: 0, text: "x", modifiedAt: Date()))],
            selectedNoteID: selectedID
        )

        XCTAssertEqual(textView.string, "Hello")
        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations))
    }

    func testRemoteBridgeMutationsDoNotNotifyOutgoingCaptureButLocalEditsDo() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let bridge = MacEditorSyncBridge()
        var changeCount = 0
        let coordinator = MacTextViewRepresentable.Coordinator(
            attributedText: .constant(NSAttributedString(string: "Hello")),
            syncBridge: bridge,
            onTextChanged: { changeCount += 1 }
        )
        coordinator.textView = textView
        textView.textStorage?.delegate = coordinator
        coordinator.register(textView)

        _ = bridge.applyBatch(
            [.applyBodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 5, text: "!", modifiedAt: Date()))],
            selectedNoteID: noteID
        )
        _ = bridge.applyBatch(
            [
                .applyBodyDeletion(
                    AppliedEditorBodyDeletion(
                        noteID: noteID,
                        range: NSRange(location: 5, length: 1),
                        deletedText: "!",
                        modifiedAt: Date()
                    )
                )
            ],
            selectedNoteID: noteID
        )
        XCTAssertEqual(changeCount, 0)

        textView.textStorage?.replaceCharacters(in: NSRange(location: 5, length: 0), with: "?")

        XCTAssertEqual(changeCount, 1)
    }

    func testRemoteMutationClearsUndoManager() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let undoManager = UndoManager()
        let delegate = UndoProvidingTextViewDelegate(undoManager: undoManager)
        textView.delegate = delegate
        let target = UndoTarget()
        undoManager.registerUndo(withTarget: target) { $0.didUndo = true }
        XCTAssertTrue(undoManager.canUndo)

        let bridge = MacEditorSyncBridge()
        bridge.textView = textView
        _ = bridge.applyBatch(
            [.applyBodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 5, text: "!", modifiedAt: Date()))],
            selectedNoteID: noteID
        )

        XCTAssertFalse(undoManager.canUndo)
    }

    func testZeroActionApplyDoesNotClearUndoManager() {
        let textView = makeTextView("Hello")
        let undoManager = UndoManager()
        let delegate = UndoProvidingTextViewDelegate(undoManager: undoManager)
        textView.delegate = delegate
        let target = UndoTarget()
        undoManager.registerUndo(withTarget: target) { $0.didUndo = true }
        XCTAssertTrue(undoManager.canUndo)

        let bridge = MacEditorSyncBridge()
        bridge.textView = textView
        _ = bridge.applyBatch([], selectedNoteID: UUID())

        XCTAssertTrue(undoManager.canUndo)
    }

    private func makeTextView(_ string: String) -> NSTextView {
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(NSAttributedString(string: string))
        return textView
    }

    private final class UndoProvidingTextViewDelegate: NSObject, NSTextViewDelegate {
        let undoManager: UndoManager

        init(undoManager: UndoManager) {
            self.undoManager = undoManager
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }
    }

    private final class UndoTarget: NSObject {
        var didUndo = false
    }
}
