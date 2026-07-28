import UIKit
import XCTest
@testable import MyRAM

// MARK: - EditorContentSyncCompletionGate unit tests (§6.7)

@MainActor
final class MarkdownPreviewUIKitHarnessTests: XCTestCase {

    // MARK: Gate: first complete() fires callback

    func testGateFirstCompleteInvokesCallback() {
        var callCount = 0
        let gate = EditorContentSyncCompletionGate { callCount += 1 }
        gate.complete()
        XCTAssertEqual(callCount, 1, "First complete() MUST invoke callback exactly once")
    }

    // MARK: Gate: repeated complete() only fires once

    func testGateRepeatedCompleteInvokesCallbackOnce() {
        var callCount = 0
        let gate = EditorContentSyncCompletionGate { callCount += 1 }
        gate.complete()
        gate.complete()
        gate.complete()
        XCTAssertEqual(callCount, 1, "Repeated complete() calls MUST invoke callback only once")
    }

    // MARK: Gate: no premature fire before complete()

    func testGateDoesNotFireBeforeComplete() {
        var fired = false
        let gate = EditorContentSyncCompletionGate { fired = true }
        _ = gate
        XCTAssertFalse(fired, "Callback MUST NOT fire before complete() is called")
    }

    // MARK: Gate: independently instantiated gates do not share state

    func testTwoGatesAreIndependent() {
        var count1 = 0
        var count2 = 0
        let gate1 = EditorContentSyncCompletionGate { count1 += 1 }
        let gate2 = EditorContentSyncCompletionGate { count2 += 1 }
        gate1.complete()
        XCTAssertEqual(count1, 1)
        XCTAssertEqual(count2, 0, "Completing gate1 MUST NOT fire gate2")
    }

    // MARK: Interaction state command consumption (§7)

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

    // MARK: Resignation disposition policy (§8)

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

    // MARK: Search isolation policy (§10)

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

    // MARK: List ordinal policy (§8)

    func testListOrdinalUsesFoundationOrdinalWhenPositive() {
        var counters: [MarkdownOrderedListCounterKey: Int] = [:]
        let ordinal = MarkdownOrderedListOrdinalPolicy.ordinal(
            foundationOrdinal: 3,
            containerIdentity: 10,
            depth: 1,
            counters: &counters
        )
        XCTAssertEqual(ordinal, 3, "Positive Foundation ordinal MUST be preserved verbatim")
        XCTAssertTrue(counters.isEmpty, "Fallback counter MUST NOT be incremented when Foundation ordinal is available")
    }

    func testListOrdinalMissingFallbackCountsFromOne() {
        var counters: [MarkdownOrderedListCounterKey: Int] = [:]
        let o1 = MarkdownOrderedListOrdinalPolicy.ordinal(
            foundationOrdinal: nil,
            containerIdentity: 99,
            depth: 1,
            counters: &counters
        )
        let o2 = MarkdownOrderedListOrdinalPolicy.ordinal(
            foundationOrdinal: nil,
            containerIdentity: 99,
            depth: 1,
            counters: &counters
        )
        let o3 = MarkdownOrderedListOrdinalPolicy.ordinal(
            foundationOrdinal: nil,
            containerIdentity: 99,
            depth: 1,
            counters: &counters
        )
        XCTAssertEqual(o1, 1)
        XCTAssertEqual(o2, 2)
        XCTAssertEqual(o3, 3)
    }

    func testListOrdinalSeparateContainersRestartCounterAtOne() {
        var counters: [MarkdownOrderedListCounterKey: Int] = [:]
        let oA = MarkdownOrderedListOrdinalPolicy.ordinal(
            foundationOrdinal: nil,
            containerIdentity: 100,
            depth: 1,
            counters: &counters
        )
        let oB = MarkdownOrderedListOrdinalPolicy.ordinal(
            foundationOrdinal: nil,
            containerIdentity: 200,
            depth: 1,
            counters: &counters
        )
        XCTAssertEqual(oA, 1)
        XCTAssertEqual(oB, 1, "Separate ordered-list containers at same depth MUST each restart at 1")
    }

    func testListOrdinalNestedContainersAreIndependent() {
        var counters: [MarkdownOrderedListCounterKey: Int] = [:]
        let outerItem1 = MarkdownOrderedListOrdinalPolicy.ordinal(
            foundationOrdinal: nil, containerIdentity: 10, depth: 1, counters: &counters
        )
        let innerItem1 = MarkdownOrderedListOrdinalPolicy.ordinal(
            foundationOrdinal: nil, containerIdentity: 20, depth: 2, counters: &counters
        )
        let innerItem2 = MarkdownOrderedListOrdinalPolicy.ordinal(
            foundationOrdinal: nil, containerIdentity: 20, depth: 2, counters: &counters
        )
        let outerItem2 = MarkdownOrderedListOrdinalPolicy.ordinal(
            foundationOrdinal: nil, containerIdentity: 10, depth: 1, counters: &counters
        )
        XCTAssertEqual(outerItem1, 1)
        XCTAssertEqual(innerItem1, 1)
        XCTAssertEqual(innerItem2, 2)
        XCTAssertEqual(outerItem2, 2, "Outer list counter MUST resume after inner list items")
    }
}
