import UIKit
import XCTest
@testable import MyRAM

@MainActor
final class UIKitEditorSyncBridgeTests: XCTestCase {
    func testNativeUndoCompletionClearsUnsafeStateBeforeResumingOnce() {
        var isApplyingUndo = true
        var resumeCount = 0
        var applyingUndoWhenResumed: Bool?

        NativeUndoCompletionResume.perform {
            isApplyingUndo = false
        } resumePendingPresentation: {
            resumeCount += 1
            applyingUndoWhenResumed = isApplyingUndo
        }

        XCTAssertFalse(isApplyingUndo)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(applyingUndoWhenResumed, false)
    }

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
        var publishCount = 0
        bridge.publishAttributedText = { _ in publishCount += 1 }
        registerUndoIfAvailable(in: textView)

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
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(textView.text, "Hello!")
        XCTAssertEqual(textView.undoManager?.canUndo, false)
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

    func testLargeTopInsertionPreservesSelectionAndScroll() {
        let noteID = UUID()
        let body = String(repeating: "0123456789\n", count: 2_000)
        let textView = makeTextView(body)
        textView.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        textView.layoutIfNeeded()
        textView.selectedRange = NSRange(location: body.utf16.count - 20, length: 10)
        textView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        let originalOffset = textView.contentOffset
        let bridge = UIKitEditorSyncBridge()
        bridge.textView = textView
        var publishCount = 0
        bridge.publishAttributedText = { _ in publishCount += 1 }

        let result = bridge.apply(
            AppliedEditorMutationBatch(
                noteID: noteID,
                mutations: [.bodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 5, text: "REMOTE", modifiedAt: Date()))],
                authoritativeBody: (body as NSString).replacingCharacters(in: NSRange(location: 5, length: 0), with: "REMOTE")
            ),
            selectedNoteID: noteID
        )

        XCTAssertEqual(result.disposition, .applied)
        XCTAssertEqual(textView.selectedRange, NSRange(location: body.utf16.count - 14, length: 10))
        XCTAssertEqual(textView.contentOffset, originalOffset)
        XCTAssertEqual(publishCount, 1)
    }

    func testSustainedRemoteTypingBatchPublishesOnce() {
        let noteID = UUID()
        let textView = makeTextView("base")
        let bridge = UIKitEditorSyncBridge()
        bridge.textView = textView
        let metrics = EditorRemoteFullDocumentMetrics()
        bridge.fullDocumentMetrics = metrics
        var publishCount = 0
        bridge.publishAttributedText = { _ in publishCount += 1 }
        let insertions = (0..<100).map { index in
            AppliedEditorMutation.bodyInsertion(
                AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 4 + index, text: "x", modifiedAt: Date())
            )
        }

        let result = bridge.apply(
            AppliedEditorMutationBatch(
                noteID: noteID,
                mutations: insertions,
                authoritativeBody: "base" + String(repeating: "x", count: 100)
            ),
            selectedNoteID: noteID
        )

        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 100, disposition: .applied))
        XCTAssertEqual(textView.text, "base" + String(repeating: "x", count: 100))
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(metrics.attributedStringCopyCount, 1)
        XCTAssertEqual(metrics.authoritativeBodyComparisonCount, 1)
        XCTAssertEqual(metrics.wholeNoteReloadCount, 0)
    }

    func testPostApplyAuthoritativeBodyMismatchSuppressesPublishAndClearsUndo() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let bridge = UIKitEditorSyncBridge()
        bridge.textView = textView
        let metrics = EditorRemoteFullDocumentMetrics()
        bridge.fullDocumentMetrics = metrics
        var publishCount = 0
        bridge.publishAttributedText = { _ in publishCount += 1 }
        registerUndoIfAvailable(in: textView)

        let result = bridge.apply(
            AppliedEditorMutationBatch(
                noteID: noteID,
                mutations: [.bodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 5, text: "!", modifiedAt: Date()))],
                authoritativeBody: "different"
            ),
            selectedNoteID: noteID
        )

        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .requiresReload(.postApplyBodyMismatch)))
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(textView.text, "Hello!")
        XCTAssertEqual(textView.undoManager?.canUndo, false)
        XCTAssertEqual(metrics.attributedStringCopyCount, 0)
        XCTAssertEqual(metrics.authoritativeBodyComparisonCount, 1)
    }

    func testEmptyMutationBatchComparesAuthoritativeBodyOnce() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let bridge = UIKitEditorSyncBridge()
        bridge.textView = textView
        let metrics = EditorRemoteFullDocumentMetrics()
        bridge.fullDocumentMetrics = metrics

        let result = bridge.apply(
            AppliedEditorMutationBatch(noteID: noteID, mutations: [], authoritativeBody: "Hello"),
            selectedNoteID: noteID
        )

        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations))
        XCTAssertEqual(metrics.authoritativeBodyComparisonCount, 1)
    }

    func testEmptyMutationAuthoritativeBodyMismatchRequiresReload() {
        let noteID = UUID()
        let textView = makeTextView("Hello")
        let bridge = UIKitEditorSyncBridge()
        bridge.textView = textView
        let metrics = EditorRemoteFullDocumentMetrics()
        bridge.fullDocumentMetrics = metrics

        let result = bridge.apply(
            AppliedEditorMutationBatch(noteID: noteID, mutations: [], authoritativeBody: "Different"),
            selectedNoteID: noteID
        )

        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .requiresReload(.preApplyBodyMismatch)))
        XCTAssertEqual(metrics.authoritativeBodyComparisonCount, 1)
    }

    func testDeletionBeforeSelectionMapsBackwardWithoutReload() {
        let noteID = UUID()
        let textView = makeTextView("0123456789")
        textView.selectedRange = NSRange(location: 7, length: 2)
        let bridge = UIKitEditorSyncBridge()
        bridge.textView = textView

        let result = bridge.apply(
            AppliedEditorMutationBatch(
                noteID: noteID,
                mutations: [.bodyDeletion(AppliedEditorBodyDeletion(noteID: noteID, range: NSRange(location: 2, length: 2), deletedText: "23", modifiedAt: Date()))],
                authoritativeBody: "01456789"
            ),
            selectedNoteID: noteID
        )

        XCTAssertEqual(result.disposition, .applied)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 2))
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

    private func registerUndoIfAvailable(in textView: UITextView) {
        guard let undoManager = textView.undoManager else { return }
        let target = UndoTarget()
        undoManager.registerUndo(withTarget: target) { $0.didUndo = true }
        XCTAssertTrue(undoManager.canUndo)
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

    private final class UndoTarget: NSObject {
        var didUndo = false
    }
}
