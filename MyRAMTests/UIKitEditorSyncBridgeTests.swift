import UIKit
import XCTest
@testable import MyRAM

@MainActor
final class UIKitEditorSyncBridgeTests: XCTestCase {
    func testValidInsertionMutatesTextStorageAndPublishesOnce() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        textView.selectedRange = NSRange(location: 5, length: 0)
        let bridge = UIKitEditorSyncBridge()
        bridge.textView = textView
        var published: [String] = []
        bridge.publishAttributedText = { published.append($0.string) }

        let result = bridge.apply(
            AppliedEditorMutationBatch(
                noteID: noteID,
                mutations: [.bodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 5, text: "!", modifiedAt: Date()))],
                authoritativeBody: "Hello!"
            ),
            selectedNoteID: noteID
        )

        XCTAssertEqual(textView.text, "Hello!")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 0))
        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .applied))
        XCTAssertEqual(published, ["Hello!"])
    }

    func testValidDeletionRequiresExactDeletedText() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let bridge = UIKitEditorSyncBridge()
        bridge.textView = textView

        let result = bridge.apply(
            AppliedEditorMutationBatch(
                noteID: noteID,
                mutations: [.bodyDeletion(AppliedEditorBodyDeletion(noteID: noteID, range: NSRange(location: 1, length: 2), deletedText: "el", modifiedAt: Date()))],
                authoritativeBody: "Hlo"
            ),
            selectedNoteID: noteID
        )

        XCTAssertEqual(textView.text, "Hlo")
        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .applied))
    }

    func testDeletionMismatchRequiresReloadWithoutMutating() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let bridge = UIKitEditorSyncBridge()
        bridge.textView = textView

        let result = bridge.apply(
            AppliedEditorMutationBatch(
                noteID: noteID,
                mutations: [.bodyDeletion(AppliedEditorBodyDeletion(noteID: noteID, range: NSRange(location: 1, length: 2), deletedText: "xx", modifiedAt: Date()))],
                authoritativeBody: "Hlo"
            ),
            selectedNoteID: noteID
        )

        XCTAssertEqual(textView.text, "Hello")
        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .requiresReload(.deletedTextMismatch)))
    }

    func testPartialApplicationRequiresRecovery() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let bridge = UIKitEditorSyncBridge()
        bridge.textView = textView

        let result = bridge.apply(
            AppliedEditorMutationBatch(
                noteID: noteID,
                mutations: [
                    .bodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 5, text: "!", modifiedAt: Date())),
                    .bodyDeletion(AppliedEditorBodyDeletion(noteID: noteID, range: NSRange(location: 20, length: 1), deletedText: "x", modifiedAt: Date()))
                ],
                authoritativeBody: "Hello!"
            ),
            selectedNoteID: noteID
        )

        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .requiresReload(.partialBatchApplication)))
    }

    func testNonSelectedBatchIsIgnored() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let bridge = UIKitEditorSyncBridge()
        bridge.textView = textView

        let result = bridge.apply(
            AppliedEditorMutationBatch(
                noteID: UUID(),
                mutations: [.bodyInsertion(AppliedEditorBodyInsertion(noteID: UUID(), utf16Offset: 0, text: "x", modifiedAt: Date()))],
                authoritativeBody: "xHello"
            ),
            selectedNoteID: noteID
        )

        XCTAssertEqual(textView.text, "Hello")
        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations))
    }

    func testBridgeSuppressesDelegateBoundaryDuringRemoteApply() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let bridge = UIKitEditorSyncBridge()
        bridge.textView = textView
        let delegate = CountingDelegate(bridge: bridge)
        textView.delegate = delegate

        _ = bridge.apply(
            AppliedEditorMutationBatch(
                noteID: noteID,
                mutations: [.bodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 5, text: "!", modifiedAt: Date()))],
                authoritativeBody: "Hello!"
            ),
            selectedNoteID: noteID
        )

        XCTAssertEqual(delegate.unsuppressedChangeCount, 0)
    }

    func testMarkedTextEndPublishesOnceWithoutContentChange() {
        let bridge = UIKitEditorSyncBridge()
        var callbackCount = 0
        bridge.onMarkedTextEnded = { callbackCount += 1 }

        bridge.observeMarkedTextState(true)
        bridge.observeMarkedTextState(true)
        bridge.observeMarkedTextState(false)
        bridge.observeMarkedTextState(false)

        XCTAssertEqual(callbackCount, 1)
    }

    private func makeTextView(_ string: String) -> UITextView {
        let textView = EditorTextViewFactory.makeEditorTextView(
            backgroundColor: .systemBackground,
            textColor: .label,
            tintColor: .systemBlue
        )
        textView.text = string
        return textView
    }

    private final class CountingDelegate: NSObject, UITextViewDelegate {
        let bridge: UIKitEditorSyncBridge
        var unsuppressedChangeCount = 0

        init(bridge: UIKitEditorSyncBridge) {
            self.bridge = bridge
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !bridge.isApplyingRemoteSync else { return }
            unsuppressedChangeCount += 1
        }
    }
}
