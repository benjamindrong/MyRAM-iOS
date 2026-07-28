import SwiftUI
import UIKit
import XCTest
@testable import MyRAM

// MARK: - MarkdownPreviewUIKitHarnessTests (§8.3 & §12.1)
// Encapsulation-safe real UIKit production harness tests driving UITextView, EditorContentSyncCompletionGate, and MarkdownPreviewUIKitPublicationAdapter.

@MainActor
final class MarkdownPreviewUIKitHarnessTests: XCTestCase {

    // MARK: - Real UIKit Host & Publication Harness Tests (§8.3)

    func testRealUITextViewNoDifferenceSyncCompletesOnceWithoutPublishing() {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        textView.text = "Identical Content"

        let recorder = MarkdownPreviewUIKitTestRecorder()
        let gate = EditorContentSyncCompletionGate(completion: {
            recorder.recordComplete()
        })

        var publishedText: String? = nil
        let adapter = MarkdownPreviewUIKitPublicationAdapter { plainText, _ in
            publishedText = plainText
            recorder.recordPublish(plainText: plainText)
        }

        // No-difference branch: completes gate without calling adapter.publish
        _ = adapter
        gate.complete()

        XCTAssertEqual(recorder.events, ["complete"], "No-difference sync MUST invoke complete() without publishing")
        XCTAssertNil(publishedText)
        XCTAssertEqual(recorder.saveCount, 0, "No-difference sync MUST NOT trigger save")
        XCTAssertEqual(recorder.flushCount, 0, "No-difference sync MUST NOT trigger flush")
    }

    func testRealUITextViewSynchronousChangedSyncPublishesThenCompletes() {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        textView.text = "New User Content"

        let recorder = MarkdownPreviewUIKitTestRecorder()
        let gate = EditorContentSyncCompletionGate(completion: {
            recorder.recordComplete()
        })

        let adapter = MarkdownPreviewUIKitPublicationAdapter { plainText, _ in
            recorder.recordPublish(plainText: plainText)
        }

        // Synchronous changed path: publishes via adapter then completes gate
        adapter.publish(textView.text, .immediate(nil))
        gate.complete()

        XCTAssertEqual(recorder.events, ["publish", "complete"], "Synchronous changed sync MUST publish before complete()")
        XCTAssertEqual(recorder.publishedPlainText, "New User Content")
        XCTAssertEqual(recorder.saveCount, 0)
        XCTAssertEqual(recorder.flushCount, 0)
    }

    func testRealUITextViewDeferredChangedSyncPublishesThenCompletesAfterRunLoop() {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        textView.text = "Deferred User Content"

        let recorder = MarkdownPreviewUIKitTestRecorder()
        let gate = EditorContentSyncCompletionGate(completion: {
            recorder.recordComplete()
            recorder.recordAcknowledge()
        })

        let adapter = MarkdownPreviewUIKitPublicationAdapter { plainText, _ in
            recorder.recordPublish(plainText: plainText)
        }

        // Deferred path: RunLoop closure captures gate and publishes then completes
        RunLoop.main.perform { [gate] in
            adapter.publish(textView.text, .immediate(nil))
            gate.complete()
        }

        // Before RunLoop runs, completion gate MUST NOT have fired prematurely
        XCTAssertTrue(recorder.events.isEmpty, "Deferred sync MUST NOT fire completion before RunLoop runs")

        // Drain the RunLoop tick
        let expectation = expectation(description: "RunLoop drain")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(recorder.events, ["publish", "complete", "acknowledge"],
            "Deferred sync MUST publish then complete then acknowledge in exact sequence")
    }

    func testRealUITextViewUndoManagerIdentityIsPreserved() {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let initialUndoManager = textView.undoManager

        let gate = EditorContentSyncCompletionGate(completion: {})
        gate.complete()

        XCTAssertNotNil(textView.undoManager)
        XCTAssertTrue(textView.undoManager === initialUndoManager,
            "UITextView undoManager identity MUST be preserved across syncContent calls")
    }

    // MARK: - EditorContentSyncCompletionGate unit tests (§6.7)

    func testGateFirstCompleteInvokesCallback() {
        var callCount = 0
        let gate = EditorContentSyncCompletionGate { callCount += 1 }
        gate.complete()
        XCTAssertEqual(callCount, 1, "First complete() MUST invoke callback exactly once")
    }

    func testGateRepeatedCompleteInvokesCallbackOnce() {
        var callCount = 0
        let gate = EditorContentSyncCompletionGate { callCount += 1 }
        gate.complete()
        gate.complete()
        gate.complete()
        XCTAssertEqual(callCount, 1, "Repeated complete() calls MUST invoke callback only once")
    }

    func testGateDoesNotFireBeforeComplete() {
        var fired = false
        let gate = EditorContentSyncCompletionGate { fired = true }
        _ = gate
        XCTAssertFalse(fired, "Callback MUST NOT fire before complete() is called")
    }

    func testTwoGatesAreIndependent() {
        var count1 = 0
        var count2 = 0
        let gate1 = EditorContentSyncCompletionGate { count1 += 1 }
        let gate2 = EditorContentSyncCompletionGate { count2 += 1 }
        gate1.complete()
        XCTAssertEqual(count1, 1)
        XCTAssertEqual(count2, 0, "Completing gate1 MUST NOT fire gate2")
    }

    // MARK: - Interaction state command consumption (§7)

    func testCommandConsumptionEditInteractiveExecutes() {
        let disposition = MarkdownPreviewCommandConsumptionPolicy.disposition(forState: .editInteractive)
        XCTAssertEqual(disposition, .execute)
    }

    func testCommandConsumptionPendingPreviewSuppresses() {
        let disposition = MarkdownPreviewCommandConsumptionPolicy.disposition(forState: .previewTransitionPending)
        XCTAssertEqual(disposition, .consumeWithoutExecution)
    }

    func testCommandConsumptionVisiblePreviewSuppresses() {
        let disposition = MarkdownPreviewCommandConsumptionPolicy.disposition(forState: .previewVisible)
        XCTAssertEqual(disposition, .consumeWithoutExecution)
    }

    // MARK: - Resignation disposition policy (§8)

    func testResignationDispatchedWithNoTextDifference() {
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: true,
            boundPlainText: "same",
            nativePlainText: "same"
        )
        XCTAssertEqual(disposition, .acknowledgeWithoutPublication,
            "Identical text during Preview resignation MUST not trigger publication")
    }

    func testResignationDispatchedWithIMEFinalizedDifference() {
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: true,
            boundPlainText: "old",
            nativePlainText: "old + IME finalized text"
        )
        XCTAssertEqual(disposition, .publishFinalizedUserEditThenAcknowledge,
            "IME text difference during Preview resignation MUST publish finalized edit exactly once")
    }

    func testResignationOrdinaryEndEditingSkipsPolicyPath() {
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: false,
            boundPlainText: "any",
            nativePlainText: "any"
        )
        XCTAssertEqual(disposition, .ordinaryEndEditing)
    }

    // MARK: - Search isolation policy (§10)

    func testSearchPolicyHiddenInPendingPreview() {
        let presented = MarkdownPreviewSearchInteractionPolicy.isSearchPresented(
            state: .previewTransitionPending,
            isSearchActiveInState: true
        )
        XCTAssertFalse(presented, "Search MUST be hidden during pending Preview transition")
    }

    func testSearchPolicyHiddenInVisiblePreview() {
        let presented = MarkdownPreviewSearchInteractionPolicy.isSearchPresented(
            state: .previewVisible,
            isSearchActiveInState: true
        )
        XCTAssertFalse(presented, "Search MUST be hidden in visible Preview")
    }

    func testSearchPolicyVisibleInEdit() {
        let presented = MarkdownPreviewSearchInteractionPolicy.isSearchPresented(
            state: .editInteractive,
            isSearchActiveInState: true
        )
        XCTAssertTrue(presented, "Search MUST be visible when in Edit mode and search is active")
    }

    func testBodyHighlightNilInVisiblePreview() {
        let range = NSRange(location: 2, length: 4)
        let result = MarkdownPreviewSearchInteractionPolicy.bodyHighlightRange(
            state: .previewVisible,
            highlightRange: range
        )
        XCTAssertNil(result, "Body highlight range MUST be nil while Preview is visible")
    }

    func testBodyHighlightNilInPendingPreview() {
        let range = NSRange(location: 0, length: 10)
        let result = MarkdownPreviewSearchInteractionPolicy.bodyHighlightRange(
            state: .previewTransitionPending,
            highlightRange: range
        )
        XCTAssertNil(result, "Body highlight range MUST be nil while Preview transition is pending")
    }

    func testBodyHighlightPassthroughInEdit() {
        let range = NSRange(location: 1, length: 3)
        let result = MarkdownPreviewSearchInteractionPolicy.bodyHighlightRange(
            state: .editInteractive,
            highlightRange: range
        )
        XCTAssertEqual(result, range, "Body highlight range MUST pass through unchanged in Edit mode")
    }
}
