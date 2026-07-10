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
            selectedNoteID: noteID,
            authoritativeBody: "Hello!"
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
            selectedNoteID: noteID,
            authoritativeBody: "Hlo"
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
            selectedNoteID: noteID,
            authoritativeBody: "Hlo"
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
            selectedNoteID: noteID,
            authoritativeBody: "Say Hello"
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
            selectedNoteID: selectedID,
            authoritativeBody: "Hello"
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
            selectedNoteID: noteID,
            authoritativeBody: "Hello!"
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
            selectedNoteID: noteID,
            authoritativeBody: "Hello"
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
            selectedNoteID: noteID,
            authoritativeBody: "Hello!"
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
        _ = bridge.applyBatch([], selectedNoteID: UUID(), authoritativeBody: "Hello")

        XCTAssertTrue(undoManager.canUndo)
    }

    func testLargeInsertionPreservesSelectionAndScrollOrigin() {
        let noteID = UUID()
        let body = String(repeating: "0123456789\n", count: 2_000)
        let textView = makeScrollableTextView(body)
        textView.setSelectedRange(NSRange(location: body.utf16.count - 20, length: 10))
        let originalOrigin = CGPoint(x: 0, y: 600)
        textView.enclosingScrollView?.contentView.setBoundsOrigin(originalOrigin)
        let bridge = MacEditorSyncBridge()
        bridge.textView = textView

        let result = bridge.applyBatch(
            [.applyBodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 5, text: "REMOTE", modifiedAt: Date()))],
            selectedNoteID: noteID,
            authoritativeBody: (body as NSString).replacingCharacters(in: NSRange(location: 5, length: 0), with: "REMOTE")
        )

        XCTAssertEqual(result.disposition, .applied)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: body.utf16.count - 14, length: 10))
        XCTAssertEqual(textView.enclosingScrollView?.contentView.bounds.origin, originalOrigin)
    }

    func testSustainedMutationBatchPublishesOnce() {
        let noteID = UUID()
        let textView = makeTextView("abcdef")
        let bridge = MacEditorSyncBridge()
        bridge.textView = textView
        let metrics = EditorRemoteFullDocumentMetrics()
        bridge.fullDocumentMetrics = metrics
        var publishCount = 0
        bridge.publishAttributedText = { _ in publishCount += 1 }

        let result = bridge.applyBatch(
            [
                .applyBodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 0, text: "1", modifiedAt: Date())),
                .applyBodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 7, text: "2", modifiedAt: Date())),
                .applyBodyDeletion(AppliedEditorBodyDeletion(noteID: noteID, range: NSRange(location: 2, length: 1), deletedText: "b", modifiedAt: Date()))
            ],
            selectedNoteID: noteID,
            authoritativeBody: "1acdef2"
        )

        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 3, disposition: .applied))
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(metrics.attributedStringCopyCount, 1)
        XCTAssertEqual(metrics.authoritativeBodyComparisonCount, 1)
        XCTAssertEqual(metrics.wholeNoteReloadCount, 0)
    }

    func testPostApplyAuthoritativeBodyMismatchRequiresFallback() {
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
        let metrics = EditorRemoteFullDocumentMetrics()
        bridge.fullDocumentMetrics = metrics
        var publishCount = 0
        bridge.publishAttributedText = { _ in publishCount += 1 }

        let result = bridge.applyBatch(
            [.applyBodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 5, text: "!", modifiedAt: Date()))],
            selectedNoteID: noteID,
            authoritativeBody: "different"
        )

        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .requiresReload(.postApplyBodyMismatch)))
        XCTAssertEqual(textView.string, "Hello!")
        XCTAssertEqual(publishCount, 0)
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertEqual(metrics.attributedStringCopyCount, 0)
        XCTAssertEqual(metrics.authoritativeBodyComparisonCount, 1)
    }

    func testPartialBatchApplicationSuppressesPublishAndClearsUndo() {
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
        var publishCount = 0
        bridge.publishAttributedText = { _ in publishCount += 1 }

        let result = bridge.applyBatch(
            [
                .applyBodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 5, text: "!", modifiedAt: Date())),
                .applyBodyDeletion(AppliedEditorBodyDeletion(noteID: noteID, range: NSRange(location: 20, length: 1), deletedText: "x", modifiedAt: Date()))
            ],
            selectedNoteID: noteID,
            authoritativeBody: "Hello!"
        )

        XCTAssertEqual(result, EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .requiresReload(.partialBatchApplication)))
        XCTAssertEqual(textView.string, "Hello!")
        XCTAssertEqual(publishCount, 0)
        XCTAssertFalse(undoManager.canUndo)
    }

    func testWholeNoteReloadMetricRecordsOnReloadPath() {
        let bridge = MacEditorSyncBridge()
        let metrics = EditorRemoteFullDocumentMetrics()
        bridge.fullDocumentMetrics = metrics

        MacSelectedEditorReloadMetrics.recordWholeNoteReload(on: bridge)

        XCTAssertEqual(metrics.wholeNoteReloadCount, 1)
    }

    private func makeTextView(_ string: String) -> NSTextView {
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(NSAttributedString(string: string))
        return textView
    }

    private func makeScrollableTextView(_ string: String) -> NSTextView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 4_000))
        scrollView.documentView = textView
        textView.textStorage?.setAttributedString(NSAttributedString(string: string))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
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
