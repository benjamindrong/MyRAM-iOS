import SwiftUI
import UIKit
import XCTest
@testable import MyRAM

// MARK: - Test Recorder (§5 Sixth Remediation)
// Lives in MyRAMTests target to ensure test doubles do not leak into production binaries.

@MainActor
final class MarkdownPreviewUIKitTestRecorder {
    private(set) var events: [String] = []
    private(set) var publishedPlainText: String?
    private(set) var saveCount = 0
    private(set) var flushCount = 0

    func recordPublish(plainText: String) {
        events.append("publish")
        publishedPlainText = plainText
    }

    func recordComplete() {
        events.append("complete")
    }

    func recordAcknowledge() {
        events.append("acknowledge")
    }

    func recordSave() {
        saveCount += 1
    }

    func recordFlush() {
        flushCount += 1
    }
}

// MARK: - MarkdownPreviewUIKitHarnessTests (§5 Sixth Remediation)
// Tests drive the extracted production MarkdownPreviewUIKitSyncExecutor directly.

@MainActor
final class MarkdownPreviewUIKitHarnessTests: XCTestCase {

    // MARK: - Production Sync Executor Tests (§5)

    func testNoDifferenceSyncCompletesOnceWithoutPublishing() {
        let recorder = MarkdownPreviewUIKitTestRecorder()
        var boundPlainText = "Identical Content"
        var boundRichTextData: Data? = nil

        let deps = MarkdownPreviewUIKitSyncDependencies(
            getBoundPlainText: { boundPlainText },
            getBoundRichTextData: { boundRichTextData },
            publish: { plain, _ in recorder.recordPublish(plainText: plain) },
            setBoundPlainText: { plain in boundPlainText = plain },
            setBoundRichTextData: { data in boundRichTextData = data },
            clearAppliedContentIfSynced: {},
            setAppliedContentAwaitingBinding: { _, _ in }
        )

        MarkdownPreviewUIKitSyncExecutor.synchronize(
            nativePlainText: "Identical Content",
            encodedRichText: nil,
            richTextUpdate: .immediate(nil),
            serializesRichTextImmediately: true,
            isUpdatingUIView: false,
            dependencies: deps,
            completion: { recorder.recordComplete() }
        )

        XCTAssertEqual(recorder.events, ["complete"], "No-difference sync MUST invoke complete() without publishing")
        XCTAssertNil(recorder.publishedPlainText)
        XCTAssertEqual(recorder.saveCount, 0, "No-difference sync MUST NOT trigger save")
        XCTAssertEqual(recorder.flushCount, 0, "No-difference sync MUST NOT trigger flush")
    }

    func testSynchronousChangedSyncPublishesThenCompletes() {
        let recorder = MarkdownPreviewUIKitTestRecorder()
        var boundPlainText = "Old Content"
        var boundRichTextData: Data? = nil

        let deps = MarkdownPreviewUIKitSyncDependencies(
            getBoundPlainText: { boundPlainText },
            getBoundRichTextData: { boundRichTextData },
            publish: { plain, _ in recorder.recordPublish(plainText: plain) },
            setBoundPlainText: { plain in boundPlainText = plain },
            setBoundRichTextData: { data in boundRichTextData = data },
            clearAppliedContentIfSynced: {},
            setAppliedContentAwaitingBinding: { _, _ in }
        )

        MarkdownPreviewUIKitSyncExecutor.synchronize(
            nativePlainText: "New Content",
            encodedRichText: nil,
            richTextUpdate: .immediate(nil),
            serializesRichTextImmediately: true,
            isUpdatingUIView: false,
            dependencies: deps,
            completion: { recorder.recordComplete() }
        )

        XCTAssertEqual(recorder.events, ["publish", "complete"], "Synchronous changed sync MUST publish before complete()")
        XCTAssertEqual(recorder.publishedPlainText, "New Content")
        XCTAssertEqual(boundPlainText, "New Content", "State MUST be updated with new text")
        XCTAssertEqual(recorder.saveCount, 0)
        XCTAssertEqual(recorder.flushCount, 0)
    }

    func testDeferredChangedSyncPublishesThenCompletesAfterRunLoop() {
        let recorder = MarkdownPreviewUIKitTestRecorder()
        var boundPlainText = "Old Content"
        var boundRichTextData: Data? = nil

        let deps = MarkdownPreviewUIKitSyncDependencies(
            getBoundPlainText: { boundPlainText },
            getBoundRichTextData: { boundRichTextData },
            publish: { plain, _ in recorder.recordPublish(plainText: plain) },
            setBoundPlainText: { plain in boundPlainText = plain },
            setBoundRichTextData: { data in boundRichTextData = data },
            clearAppliedContentIfSynced: {},
            setAppliedContentAwaitingBinding: { _, _ in }
        )

        MarkdownPreviewUIKitSyncExecutor.synchronize(
            nativePlainText: "Deferred New Content",
            encodedRichText: nil,
            richTextUpdate: .immediate(nil),
            serializesRichTextImmediately: true,
            isUpdatingUIView: true,
            dependencies: deps,
            completion: {
                recorder.recordComplete()
                recorder.recordAcknowledge()
            }
        )

        // Before RunLoop runs, completion gate MUST NOT have fired prematurely
        XCTAssertTrue(recorder.events.isEmpty, "Deferred sync MUST NOT fire completion before RunLoop runs")

        // Drain the RunLoop tick
        let exp = expectation(description: "RunLoop drain")
        DispatchQueue.main.async {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(recorder.events, ["publish", "complete", "acknowledge"],
            "Deferred sync MUST publish then complete then acknowledge in exact sequence")
        XCTAssertEqual(recorder.saveCount, 0)
        XCTAssertEqual(recorder.flushCount, 0)
    }

    func testDeferredAlreadySynchronizedSyncCompletesWithoutPublishing() {
        let recorder = MarkdownPreviewUIKitTestRecorder()
        var boundPlainText = "Old Content"
        var boundRichTextData: Data? = nil

        let deps = MarkdownPreviewUIKitSyncDependencies(
            getBoundPlainText: { boundPlainText },
            getBoundRichTextData: { boundRichTextData },
            publish: { plain, _ in recorder.recordPublish(plainText: plain) },
            setBoundPlainText: { plain in boundPlainText = plain },
            setBoundRichTextData: { data in boundRichTextData = data },
            clearAppliedContentIfSynced: {},
            setAppliedContentAwaitingBinding: { _, _ in }
        )

        MarkdownPreviewUIKitSyncExecutor.synchronize(
            nativePlainText: "Already Synced Content",
            encodedRichText: nil,
            richTextUpdate: .immediate(nil),
            serializesRichTextImmediately: true,
            isUpdatingUIView: true,
            dependencies: deps,
            completion: { recorder.recordComplete() }
        )

        // Simulate binding sync occurring before RunLoop tick fires
        boundPlainText = "Already Synced Content"

        let exp = expectation(description: "RunLoop drain")
        DispatchQueue.main.async {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(recorder.events, ["complete"],
            "Deferred already-synchronized path MUST complete without publishing")
    }

    func testTeardownPathCompletesOnce() {
        let recorder = MarkdownPreviewUIKitTestRecorder()
        let gate = EditorContentSyncCompletionGate(completion: { recorder.recordComplete() })

        gate.complete()

        XCTAssertEqual(recorder.events, ["complete"], "Teardown path MUST invoke complete()")
    }

    func testRepeatedCompletionAttemptsRemainExactlyOnce() {
        let recorder = MarkdownPreviewUIKitTestRecorder()
        let gate = EditorContentSyncCompletionGate(completion: { recorder.recordComplete() })

        gate.complete()
        gate.complete()
        gate.complete()

        XCTAssertEqual(recorder.events, ["complete"], "Repeated completion attempts MUST fire callback exactly once")
    }

    func testIMEEventOrderIsPublishCompleteAcknowledge() {
        let recorder = MarkdownPreviewUIKitTestRecorder()
        var boundPlainText = "Before IME"
        var boundRichTextData: Data? = nil

        let deps = MarkdownPreviewUIKitSyncDependencies(
            getBoundPlainText: { boundPlainText },
            getBoundRichTextData: { boundRichTextData },
            publish: { plain, _ in recorder.recordPublish(plainText: plain) },
            setBoundPlainText: { plain in boundPlainText = plain },
            setBoundRichTextData: { data in boundRichTextData = data },
            clearAppliedContentIfSynced: {},
            setAppliedContentAwaitingBinding: { _, _ in }
        )

        MarkdownPreviewUIKitSyncExecutor.synchronize(
            nativePlainText: "Finalized IME Text",
            encodedRichText: nil,
            richTextUpdate: .immediate(nil),
            serializesRichTextImmediately: true,
            isUpdatingUIView: false,
            dependencies: deps,
            completion: {
                recorder.recordComplete()
                recorder.recordAcknowledge()
            }
        )

        XCTAssertEqual(recorder.events, ["publish", "complete", "acknowledge"],
            "IME event order MUST be publish -> complete -> acknowledge")
    }

    func testStalePreviewRequestSuppressesAcknowledgmentButPreservesPublication() {
        let recorder = MarkdownPreviewUIKitTestRecorder()
        var boundPlainText = "Initial"
        var boundRichTextData: Data? = nil

        let deps = MarkdownPreviewUIKitSyncDependencies(
            getBoundPlainText: { boundPlainText },
            getBoundRichTextData: { boundRichTextData },
            publish: { plain, _ in recorder.recordPublish(plainText: plain) },
            setBoundPlainText: { plain in boundPlainText = plain },
            setBoundRichTextData: { data in boundRichTextData = data },
            clearAppliedContentIfSynced: {},
            setAppliedContentAwaitingBinding: { _, _ in }
        )

        // Stale request: publish runs, completion runs, but acknowledgment is suppressed because request was cancelled
        let isStale = true
        MarkdownPreviewUIKitSyncExecutor.synchronize(
            nativePlainText: "Stale Edit",
            encodedRichText: nil,
            richTextUpdate: .immediate(nil),
            serializesRichTextImmediately: true,
            isUpdatingUIView: false,
            dependencies: deps,
            completion: {
                recorder.recordComplete()
                if !isStale {
                    recorder.recordAcknowledge()
                }
            }
        )

        XCTAssertEqual(recorder.events, ["publish", "complete"],
            "Stale Preview request MUST preserve publication and completion, but suppress acknowledgment")
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

    // MARK: - EditorContentSyncCompletionGate Unit Tests (§6.7)

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
        let _ = EditorContentSyncCompletionGate { count2 += 1 }
        gate1.complete()
        XCTAssertEqual(count1, 1)
        XCTAssertEqual(count2, 0, "Completing gate1 MUST NOT fire gate2")
    }

    // MARK: - Interaction State Command Consumption (§7)

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

    // MARK: - Resignation Disposition Policy (§8)

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

    // MARK: - Search Isolation Policy (§10)

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
