import UIKit
import XCTest
@testable import MyRAM

@MainActor
private final class DeferredOperationQueue {
    typealias Operation = @MainActor () -> Void

    private(set) var operations: [Operation] = []

    func schedule(_ operation: @escaping Operation) {
        operations.append(operation)
    }

    func run(at index: Int) {
        let operation = operations.remove(at: index)
        operation()
    }
}

@MainActor
private final class MarkdownPreviewUIKitSyncHarness {
    let generationOwner = MarkdownPreviewUIKitSyncGenerationOwner()
    var appliedState = MarkdownPreviewUIKitAppliedContentState()
    var boundPlainText: String
    var boundRichTextData: Data?
    var isAvailable = true
    var scheduledOperations: [@MainActor () -> Void] = []
    var plainWrites: [String] = []
    var richTextWrites: [Data?] = []
    var publications: [String] = []
    var events: [String] = []
    var completionCounts: [String: Int] = [:]
    var recordedGenerations: [MarkdownPreviewUIKitSyncGeneration] = []
    var clearedGenerations: [MarkdownPreviewUIKitSyncGeneration] = []
    var discardedGenerations: [MarkdownPreviewUIKitSyncGeneration] = []
    var afterPlainWrite: (() -> Void)?
    var afterRichTextWrite: (() -> Void)?
    var afterPublication: (() -> Void)?

    init(boundPlainText: String = "Initial", boundRichTextData: Data? = nil) {
        self.boundPlainText = boundPlainText
        self.boundRichTextData = boundRichTextData
    }

    func synchronize(
        label: String,
        nativePlainText: String,
        richTextDisposition: MarkdownPreviewUIKitRichTextBindingDisposition = .replace(nil),
        isUpdatingUIView: Bool,
        completionAction: (() -> Void)? = nil
    ) {
        MarkdownPreviewUIKitSyncExecutor.synchronize(
            nativePlainText: nativePlainText,
            richTextBindingDisposition: richTextDisposition,
            richTextUpdate: richTextUpdate(for: richTextDisposition),
            isUpdatingUIView: isUpdatingUIView,
            generationOwner: generationOwner,
            dependencies: dependencies(),
            completion: { [weak self] in
                guard let self else { return }
                completionCounts[label, default: 0] += 1
                events.append("complete:\(label)")
                completionAction?()
            }
        )
    }

    func runScheduled(at index: Int) {
        let operation = scheduledOperations.remove(at: index)
        operation()
    }

    private func dependencies() -> MarkdownPreviewUIKitSyncDependencies {
        MarkdownPreviewUIKitSyncDependencies(
            isAvailable: { [weak self] in self?.isAvailable == true },
            getBoundPlainText: { [weak self] in self?.boundPlainText ?? "" },
            getBoundRichTextData: { [weak self] in self?.boundRichTextData },
            setBoundPlainText: { [weak self] plainText in
                guard let self else { return }
                boundPlainText = plainText
                plainWrites.append(plainText)
                afterPlainWrite?()
            },
            setBoundRichTextData: { [weak self] richTextData in
                guard let self else { return }
                boundRichTextData = richTextData
                richTextWrites.append(richTextData)
                afterRichTextWrite?()
            },
            publish: { [weak self] plainText, _ in
                guard let self else { return }
                publications.append(plainText)
                events.append("publish:\(plainText)")
                afterPublication?()
            },
            recordAppliedContentIfCurrent: { [weak self] generation, owner, plainText, richTextWrite in
                guard let self else { return false }
                let didRecord = appliedState.recordAppliedContentIfCurrent(
                    generation: generation,
                    generationOwner: owner,
                    plainText: plainText,
                    richTextWrite: richTextWrite
                )
                if didRecord {
                    recordedGenerations.append(generation)
                }
                return didRecord
            },
            clearAppliedContentIfOwned: { [weak self] generation, plainText, richTextData in
                guard let self else { return false }
                let didClear = appliedState.clearAppliedContentIfOwned(
                    by: generation,
                    boundPlainText: plainText,
                    boundRichTextData: richTextData
                )
                if didClear {
                    clearedGenerations.append(generation)
                }
                return didClear
            },
            discardAppliedContentSuperseded: { [weak self] generation, owner in
                guard let self else { return false }
                let didDiscard = appliedState.discardAppliedContentSuperseded(
                    by: generation,
                    generationOwner: owner
                )
                if didDiscard {
                    discardedGenerations.append(generation)
                }
                return didDiscard
            },
            scheduleDeferred: { [weak self] operation in
                self?.scheduledOperations.append(operation)
            }
        )
    }

    private func richTextUpdate(
        for disposition: MarkdownPreviewUIKitRichTextBindingDisposition
    ) -> EditorRichTextContentUpdate {
        switch disposition {
        case .preserveExisting:
            return .deferred(DeferredRichTextContentEncoder { nil })
        case .replace(let data):
            return .immediate(data)
        }
    }
}

@MainActor
final class MarkdownPreviewUIKitHarnessTests: XCTestCase {
    func testDeferredBPublishesBeforeAAndRemainsAuthoritative() {
        let harness = MarkdownPreviewUIKitSyncHarness()
        harness.synchronize(label: "A", nativePlainText: "A", isUpdatingUIView: true)
        harness.synchronize(label: "B", nativePlainText: "B", isUpdatingUIView: true)

        XCTAssertEqual(harness.scheduledOperations.count, 2)
        harness.runScheduled(at: 1)
        harness.runScheduled(at: 0)

        XCTAssertEqual(harness.boundPlainText, "B")
        XCTAssertEqual(harness.publications, ["B"])
        XCTAssertEqual(harness.plainWrites, ["B"])
        XCTAssertEqual(harness.completionCounts, ["A": 1, "B": 1])
    }

    func testSynchronousBSupersedesDeferredA() {
        let harness = MarkdownPreviewUIKitSyncHarness()
        harness.synchronize(label: "A", nativePlainText: "A", isUpdatingUIView: true)
        harness.synchronize(label: "B", nativePlainText: "B", isUpdatingUIView: false)
        harness.runScheduled(at: 0)

        XCTAssertEqual(harness.boundPlainText, "B")
        XCTAssertEqual(harness.publications, ["B"])
        XCTAssertEqual(harness.completionCounts, ["A": 1, "B": 1])
    }

    func testNoDifferenceBSupersedesDeferredAAndDiscardsItsState() {
        let harness = MarkdownPreviewUIKitSyncHarness()
        harness.synchronize(label: "A", nativePlainText: "A", isUpdatingUIView: true)
        _ = try! XCTUnwrap(harness.appliedState.generation)

        harness.synchronize(label: "B", nativePlainText: "Initial", isUpdatingUIView: false)
        XCTAssertNil(harness.appliedState.generation)
        XCTAssertEqual(
            harness.discardedGenerations,
            [MarkdownPreviewUIKitSyncGeneration(rawValue: 2)]
        )

        harness.runScheduled(at: 0)
        XCTAssertEqual(harness.boundPlainText, "Initial")
        XCTAssertTrue(harness.publications.isEmpty)
        XCTAssertEqual(harness.completionCounts, ["A": 1, "B": 1])
    }

    func testStaleGenerationCannotRecordAfterNewerGenerationBegins() {
        let owner = MarkdownPreviewUIKitSyncGenerationOwner()
        let generationA = owner.begin()
        _ = owner.begin()
        var state = MarkdownPreviewUIKitAppliedContentState()

        XCTAssertFalse(
            state.recordAppliedContentIfCurrent(
                generation: generationA,
                generationOwner: owner,
                plainText: "A",
                richTextWrite: .none
            )
        )
        XCTAssertNil(state.generation)
    }

    func testStaleGenerationCannotClearOrDiscardNewerBookkeeping() {
        let owner = MarkdownPreviewUIKitSyncGenerationOwner()
        let generationA = owner.begin()
        let generationB = owner.begin()
        var state = MarkdownPreviewUIKitAppliedContentState()
        XCTAssertTrue(
            state.recordAppliedContentIfCurrent(
                generation: generationB,
                generationOwner: owner,
                plainText: "B",
                richTextWrite: .replace(nil)
            )
        )

        XCTAssertFalse(
            state.clearAppliedContentIfOwned(
                by: generationA,
                boundPlainText: "B",
                boundRichTextData: nil
            )
        )
        XCTAssertFalse(
            state.discardAppliedContentSuperseded(
                by: generationA,
                generationOwner: owner
            )
        )
        XCTAssertEqual(state.generation, generationB)
    }

    func testClearRequiresOwnerPlainTextAndSatisfiedRichTextWrite() {
        let owner = MarkdownPreviewUIKitSyncGenerationOwner()
        let generation = owner.begin()
        let replacement = Data("rich".utf8)
        var state = MarkdownPreviewUIKitAppliedContentState()
        XCTAssertTrue(
            state.recordAppliedContentIfCurrent(
                generation: generation,
                generationOwner: owner,
                plainText: "Plain",
                richTextWrite: .replace(replacement)
            )
        )

        XCTAssertFalse(
            state.clearAppliedContentIfOwned(
                by: generation,
                boundPlainText: "Other",
                boundRichTextData: replacement
            )
        )
        XCTAssertFalse(
            state.clearAppliedContentIfOwned(
                by: generation,
                boundPlainText: "Plain",
                boundRichTextData: nil
            )
        )
        XCTAssertTrue(
            state.clearAppliedContentIfOwned(
                by: generation,
                boundPlainText: "Plain",
                boundRichTextData: replacement
            )
        )
        XCTAssertEqual(state, MarkdownPreviewUIKitAppliedContentState())
    }

    func testDiscardRequiresCurrentGenerationAndPreservesCurrentState() {
        let owner = MarkdownPreviewUIKitSyncGenerationOwner()
        let generationA = owner.begin()
        var state = MarkdownPreviewUIKitAppliedContentState()
        XCTAssertTrue(
            state.recordAppliedContentIfCurrent(
                generation: generationA,
                generationOwner: owner,
                plainText: "A",
                richTextWrite: .none
            )
        )
        XCTAssertFalse(
            state.discardAppliedContentSuperseded(
                by: generationA,
                generationOwner: owner
            )
        )

        let generationB = owner.begin()
        XCTAssertFalse(
            state.discardAppliedContentSuperseded(
                by: generationA,
                generationOwner: owner
            )
        )
        XCTAssertTrue(
            state.discardAppliedContentSuperseded(
                by: generationB,
                generationOwner: owner
            )
        )
        XCTAssertNil(state.generation)
    }

    func testCoordinatorScopedGenerationOwnersAreIndependent() {
        let ownerA = MarkdownPreviewUIKitSyncGenerationOwner()
        let ownerB = MarkdownPreviewUIKitSyncGenerationOwner()

        XCTAssertEqual(ownerA.begin().rawValue, 1)
        XCTAssertEqual(ownerA.begin().rawValue, 2)
        XCTAssertEqual(ownerB.begin().rawValue, 1)
    }

    func testSupersessionDuringPlainSetterStopsLaterSideEffects() {
        let harness = MarkdownPreviewUIKitSyncHarness()
        harness.afterPlainWrite = {
            harness.afterPlainWrite = nil
            harness.synchronize(
                label: "B",
                nativePlainText: "B",
                richTextDisposition: .preserveExisting,
                isUpdatingUIView: false
            )
        }

        harness.synchronize(
            label: "A",
            nativePlainText: "A",
            richTextDisposition: .replace(Data("A-rich".utf8)),
            isUpdatingUIView: false
        )

        XCTAssertEqual(harness.plainWrites, ["A", "B"])
        XCTAssertTrue(harness.richTextWrites.isEmpty)
        XCTAssertEqual(harness.publications, ["B"])
        XCTAssertEqual(harness.completionCounts, ["A": 1, "B": 1])
    }

    func testSupersessionDuringRichTextSetterStopsPublicationAndClear() {
        let harness = MarkdownPreviewUIKitSyncHarness()
        harness.afterRichTextWrite = {
            harness.afterRichTextWrite = nil
            harness.synchronize(
                label: "B",
                nativePlainText: "B",
                richTextDisposition: .preserveExisting,
                isUpdatingUIView: false
            )
        }

        harness.synchronize(
            label: "A",
            nativePlainText: "A",
            richTextDisposition: .replace(Data("A-rich".utf8)),
            isUpdatingUIView: false
        )

        XCTAssertEqual(harness.richTextWrites.count, 1)
        XCTAssertEqual(harness.publications, ["B"])
        XCTAssertEqual(harness.clearedGenerations.count, 1)
        XCTAssertEqual(harness.completionCounts, ["A": 1, "B": 1])
    }

    func testSupersessionDuringPublicationStopsOlderClear() {
        let harness = MarkdownPreviewUIKitSyncHarness()
        harness.afterPublication = {
            harness.afterPublication = nil
            harness.synchronize(
                label: "B",
                nativePlainText: "B",
                richTextDisposition: .preserveExisting,
                isUpdatingUIView: false
            )
        }

        harness.synchronize(
            label: "A",
            nativePlainText: "A",
            richTextDisposition: .preserveExisting,
            isUpdatingUIView: false
        )

        XCTAssertEqual(harness.publications, ["A", "B"])
        XCTAssertEqual(harness.clearedGenerations.count, 1)
        XCTAssertEqual(harness.completionCounts, ["A": 1, "B": 1])
    }

    func testStaleRichTextReplacementCannotClearNewerRichText() {
        let harness = MarkdownPreviewUIKitSyncHarness(boundRichTextData: Data("initial".utf8))
        harness.synchronize(
            label: "A",
            nativePlainText: "A",
            richTextDisposition: .replace(Data("A-rich".utf8)),
            isUpdatingUIView: true
        )
        harness.synchronize(
            label: "B",
            nativePlainText: "B",
            richTextDisposition: .replace(Data("B-rich".utf8)),
            isUpdatingUIView: true
        )
        harness.runScheduled(at: 1)
        harness.runScheduled(at: 0)

        XCTAssertEqual(harness.boundRichTextData, Data("B-rich".utf8))
        XCTAssertEqual(harness.richTextWrites, [Data("B-rich".utf8)])
    }

    func testStalePreserveExistingOperationCannotOverwriteNewerPlainText() {
        let harness = MarkdownPreviewUIKitSyncHarness(boundRichTextData: Data("existing".utf8))
        harness.synchronize(
            label: "A",
            nativePlainText: "A",
            richTextDisposition: .preserveExisting,
            isUpdatingUIView: true
        )
        harness.synchronize(
            label: "B",
            nativePlainText: "B",
            richTextDisposition: .preserveExisting,
            isUpdatingUIView: true
        )
        harness.runScheduled(at: 1)
        harness.runScheduled(at: 0)

        XCTAssertEqual(harness.boundPlainText, "B")
        XCTAssertEqual(harness.boundRichTextData, Data("existing".utf8))
        XCTAssertEqual(harness.plainWrites, ["B"])
    }

    func testCurrentDeferredOperationPublishesAndCompletesNormally() {
        let harness = MarkdownPreviewUIKitSyncHarness()
        harness.synchronize(label: "A", nativePlainText: "A", isUpdatingUIView: true)
        harness.runScheduled(at: 0)

        XCTAssertEqual(harness.boundPlainText, "A")
        XCTAssertEqual(harness.publications, ["A"])
        XCTAssertEqual(harness.completionCounts, ["A": 1])
        XCTAssertEqual(harness.events, ["publish:A", "complete:A"])
        XCTAssertNil(harness.appliedState.generation)
    }

    func testDeferredOperationAlreadySynchronizedCompletesWithoutPublishing() {
        let harness = MarkdownPreviewUIKitSyncHarness()
        harness.synchronize(label: "A", nativePlainText: "A", isUpdatingUIView: true)
        harness.boundPlainText = "A"
        harness.boundRichTextData = nil

        harness.runScheduled(at: 0)

        XCTAssertTrue(harness.publications.isEmpty)
        XCTAssertEqual(harness.completionCounts, ["A": 1])
        XCTAssertEqual(harness.events, ["complete:A"])
    }

    func testPreserveExistingNeverWritesRichTextBinding() {
        let existing = Data("existing-rich".utf8)
        let harness = MarkdownPreviewUIKitSyncHarness(boundRichTextData: existing)

        harness.synchronize(
            label: "A",
            nativePlainText: "A",
            richTextDisposition: .preserveExisting,
            isUpdatingUIView: false
        )

        XCTAssertEqual(harness.boundPlainText, "A")
        XCTAssertEqual(harness.boundRichTextData, existing)
        XCTAssertTrue(harness.richTextWrites.isEmpty)
        XCTAssertEqual(harness.events, ["publish:A", "complete:A"])
    }

    func testImmediateReplacementWritesDataAndReplaceNilClearsIt() {
        let replacement = Data("replacement-rich".utf8)
        let harness = MarkdownPreviewUIKitSyncHarness(
            boundRichTextData: Data("existing-rich".utf8)
        )
        harness.synchronize(
            label: "A",
            nativePlainText: "A",
            richTextDisposition: .replace(replacement),
            isUpdatingUIView: false
        )
        harness.synchronize(
            label: "B",
            nativePlainText: "B",
            richTextDisposition: .replace(nil),
            isUpdatingUIView: false
        )

        XCTAssertEqual(harness.richTextWrites.count, 2)
        XCTAssertEqual(harness.richTextWrites[0], replacement)
        XCTAssertNil(harness.richTextWrites[1])
        XCTAssertNil(harness.boundRichTextData)
    }

    func testNoDifferencePreserveIgnoresUnrelatedRichTextBinding() {
        let harness = MarkdownPreviewUIKitSyncHarness(
            boundPlainText: "Same",
            boundRichTextData: Data("existing-rich".utf8)
        )
        harness.synchronize(
            label: "A",
            nativePlainText: "Same",
            richTextDisposition: .preserveExisting,
            isUpdatingUIView: false
        )

        XCTAssertTrue(harness.publications.isEmpty)
        XCTAssertTrue(harness.plainWrites.isEmpty)
        XCTAssertTrue(harness.richTextWrites.isEmpty)
        XCTAssertEqual(harness.completionCounts, ["A": 1])
    }

    func testPreviewAcknowledgmentRemainsIndependentFromPublicationGeneration() {
        let harness = MarkdownPreviewUIKitSyncHarness()
        var acknowledgmentCount = 0
        let previewRequestIsCurrent = false

        harness.synchronize(
            label: "A",
            nativePlainText: "Finalized IME",
            isUpdatingUIView: false,
            completionAction: {
                if previewRequestIsCurrent {
                    acknowledgmentCount += 1
                }
            }
        )

        XCTAssertEqual(harness.publications, ["Finalized IME"])
        XCTAssertEqual(harness.completionCounts, ["A": 1])
        XCTAssertEqual(acknowledgmentCount, 0)
    }

    func testWeakDependencyTeardownCompletesWithoutDeferredSideEffects() {
        let harness = MarkdownPreviewUIKitSyncHarness()
        harness.synchronize(label: "A", nativePlainText: "A", isUpdatingUIView: true)
        let recordedCount = harness.recordedGenerations.count
        let clearedCount = harness.clearedGenerations.count
        let discardedCount = harness.discardedGenerations.count
        harness.isAvailable = false

        harness.runScheduled(at: 0)

        XCTAssertTrue(harness.plainWrites.isEmpty)
        XCTAssertTrue(harness.richTextWrites.isEmpty)
        XCTAssertTrue(harness.publications.isEmpty)
        XCTAssertEqual(harness.recordedGenerations.count, recordedCount)
        XCTAssertEqual(harness.clearedGenerations.count, clearedCount)
        XCTAssertEqual(harness.discardedGenerations.count, discardedCount)
        XCTAssertEqual(harness.completionCounts, ["A": 1])
    }

    func testEveryStaleOperationCompletesExactlyOnce() {
        let harness = MarkdownPreviewUIKitSyncHarness()
        harness.synchronize(label: "A", nativePlainText: "A", isUpdatingUIView: true)
        harness.synchronize(label: "B", nativePlainText: "B", isUpdatingUIView: true)
        harness.synchronize(label: "C", nativePlainText: "C", isUpdatingUIView: true)

        harness.runScheduled(at: 2)
        harness.runScheduled(at: 1)
        harness.runScheduled(at: 0)

        XCTAssertEqual(harness.completionCounts, ["A": 1, "B": 1, "C": 1])
        XCTAssertEqual(harness.publications, ["C"])
    }

    func testProductionDeferredSchedulerEnqueuesExactlyOnce() async {
        var invocationCount = 0

        MarkdownPreviewUIKitDeferredScheduler.enqueue {
            invocationCount += 1
        }
        XCTAssertEqual(invocationCount, 0)

        await Task.yield()
        XCTAssertEqual(invocationCount, 1)
        await Task.yield()
        XCTAssertEqual(invocationCount, 1)
    }

    func testNativeUndoSurvivesProductionResignationAndBothReconciliationPasses() throws {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 280, height: 160))
        let viewController = UIViewController()
        viewController.view.addSubview(textView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        XCTAssertTrue(textView.becomeFirstResponder())

        let textViewIdentity = ObjectIdentifier(textView)
        let undoManager = try XCTUnwrap(textView.undoManager)
        textView.insertText("Native Undo Preview Proof")
        XCTAssertTrue(undoManager.canUndo)

        let owner = MarkdownPreviewUIKitSyncGenerationOwner()
        let generation = owner.begin()
        var appliedState = MarkdownPreviewUIKitAppliedContentState()
        XCTAssertTrue(
            appliedState.recordAppliedContentIfCurrent(
                generation: generation,
                generationOwner: owner,
                plainText: textView.text,
                richTextWrite: .none
            )
        )

        MarkdownPreviewUIKitEditorResignation.resignIfOwned(textView)
        XCTAssertFalse(textView.isFirstResponder)

        let differingBoundAttributedText = NSAttributedString(
            string: textView.text,
            attributes: [.foregroundColor: UIColor.systemRed]
        )
        var replacementCount = 0
        let dependencies = reconciliationDependencies(
            willApplyReplacement: { replacementCount += 1 },
            clearAppliedContent: { generation, plainText, richTextData in
                _ = appliedState.clearAppliedContentIfOwned(
                    by: generation,
                    boundPlainText: plainText,
                    boundRichTextData: richTextData
                )
            }
        )
        let previewInput = reconciliationInput(
            textView: textView,
            generation: generation,
            isCurrent: true,
            appliedState: appliedState,
            boundPlainText: textView.text,
            boundAttributedText: differingBoundAttributedText,
            nativeMatchesLatestPublication: true,
            isResigningForPreview: true,
            isPreviewPending: true
        )
        MarkdownPreviewUIKitPostResignationReconciliation.reconcile(
            textView: textView,
            input: previewInput,
            dependencies: dependencies
        )
        let editInput = reconciliationInput(
            textView: textView,
            generation: generation,
            isCurrent: true,
            appliedState: appliedState,
            boundPlainText: textView.text,
            boundAttributedText: differingBoundAttributedText,
            nativeMatchesLatestPublication: false
        )
        MarkdownPreviewUIKitPostResignationReconciliation.reconcile(
            textView: textView,
            input: editInput,
            dependencies: dependencies
        )

        XCTAssertEqual(ObjectIdentifier(textView), textViewIdentity)
        XCTAssertTrue(textView.undoManager === undoManager)
        XCTAssertEqual(replacementCount, 0)
        XCTAssertTrue(textView.becomeFirstResponder())
        undoManager.undo()
        XCTAssertEqual(textView.text, "")
        XCTAssertTrue(textView.undoManager === undoManager)
        _ = window
    }

    func testReconciliationAppliesAndMarksExplicitRestoreOwnership() {
        let textView = UITextView()
        textView.attributedText = NSAttributedString(string: "Native")
        let restoreOwner = MarkdownPreviewUIKitRestoreGenerationOwner()
        let restoreGeneration = restoreOwner.begin()
        let requested = NSAttributedString(
            string: "Native",
            attributes: [.foregroundColor: UIColor.systemBlue]
        )
        let synchronizationOwner = MarkdownPreviewUIKitSyncGenerationOwner()
        var appliedState = MarkdownPreviewUIKitAppliedContentState()
        var supersessionCount = 0
        var handled: (MarkdownPreviewUIKitRestoreToken, MarkdownPreviewUIKitRestoreGeneration)?

        let input = reconciliationInput(
            textView: textView,
            boundPlainText: "Bound",
            boundAttributedText: NSAttributedString(string: "Bound"),
            restoreRequest: .init(
                token: .init(rawValue: 2),
                lastHandledToken: .init(rawValue: 1),
                generation: restoreGeneration,
                lastAppliedGeneration: nil,
                requestedAttributedText: requested
            )
        )
        MarkdownPreviewUIKitPostResignationReconciliation.reconcile(
            textView: textView,
            input: input,
            dependencies: reconciliationDependencies(
                supersedeAcceptedRestore: {
                    supersessionCount += 1
                    return MarkdownPreviewUIKitAcceptedRestoreSupersession.perform(
                        generationOwner: synchronizationOwner,
                        appliedContentState: &appliedState
                    )
                },
                markRestoreHandled: { token, generation in
                    handled = (token, generation)
                }
            )
        )

        XCTAssertTrue(textView.attributedText.isEqual(to: requested))
        XCTAssertEqual(supersessionCount, 1)
        XCTAssertEqual(
            synchronizationOwner.current,
            MarkdownPreviewUIKitSyncGeneration(rawValue: 1)
        )
        XCTAssertEqual(handled?.0, MarkdownPreviewUIKitRestoreToken(rawValue: 2))
        XCTAssertEqual(handled?.1, restoreGeneration)
    }

    func testAcceptedNewerRestoreSupersedesQueuedEditorSynchronization() {
        let richTextA = Data("rich-A".utf8)
        let richTextB = Data("rich-B".utf8)
        let harness = MarkdownPreviewUIKitSyncHarness(
            boundPlainText: "Before A",
            boundRichTextData: nil
        )
        let textView = UITextView()
        textView.attributedText = NSAttributedString(string: "A")

        harness.synchronize(
            label: "A",
            nativePlainText: "A",
            richTextDisposition: .replace(richTextA),
            isUpdatingUIView: true
        )
        let queuedGeneration = harness.generationOwner.current
        XCTAssertEqual(harness.scheduledOperations.count, 1)
        XCTAssertEqual(harness.appliedState.generation, queuedGeneration)

        harness.boundPlainText = "B"
        harness.boundRichTextData = richTextB
        let requestedB = NSAttributedString(
            string: "B",
            attributes: [.foregroundColor: UIColor.systemPurple]
        )
        let restoreOwner = MarkdownPreviewUIKitRestoreGenerationOwner()
        let lastRestoreGeneration = restoreOwner.begin()
        let restoreGeneration = restoreOwner.begin()
        var supersessionCount = 0
        var replacementCount = 0
        var completionCount = 0
        var handledCount = 0

        MarkdownPreviewUIKitPostResignationReconciliation.reconcile(
            textView: textView,
            input: reconciliationInput(
                textView: textView,
                generation: queuedGeneration,
                isCurrent: false,
                appliedState: harness.appliedState,
                boundPlainText: "B",
                boundRichTextData: richTextB,
                boundAttributedText: requestedB,
                restoreRequest: .init(
                    token: .init(rawValue: 2),
                    lastHandledToken: .init(rawValue: 1),
                    generation: restoreGeneration,
                    lastAppliedGeneration: lastRestoreGeneration,
                    requestedAttributedText: requestedB
                )
            ),
            dependencies: reconciliationDependencies(
                willApplyReplacement: { replacementCount += 1 },
                didApplyReplacement: { _ in completionCount += 1 },
                supersedeAcceptedRestore: {
                    supersessionCount += 1
                    return MarkdownPreviewUIKitAcceptedRestoreSupersession.perform(
                        generationOwner: harness.generationOwner,
                        appliedContentState: &harness.appliedState
                    )
                },
                markRestoreHandled: { _, _ in handledCount += 1 }
            )
        )

        let restoreSyncGeneration = harness.generationOwner.current
        XCTAssertEqual(supersessionCount, 1)
        XCTAssertEqual(
            restoreSyncGeneration?.rawValue,
            (queuedGeneration?.rawValue ?? 0) + 1
        )
        XCTAssertFalse(
            queuedGeneration.map {
                harness.generationOwner.isCurrent($0)
            } ?? true
        )
        XCTAssertNil(harness.appliedState.generation)
        XCTAssertEqual(replacementCount, 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(handledCount, 1)
        XCTAssertTrue(textView.attributedText.isEqual(to: requestedB))
        XCTAssertEqual(harness.boundPlainText, "B")
        XCTAssertEqual(harness.boundRichTextData, richTextB)

        harness.runScheduled(at: 0)

        XCTAssertTrue(harness.plainWrites.isEmpty)
        XCTAssertTrue(harness.richTextWrites.isEmpty)
        XCTAssertTrue(harness.publications.isEmpty)
        XCTAssertEqual(harness.completionCounts, ["A": 1])
        XCTAssertTrue(textView.attributedText.isEqual(to: requestedB))
        XCTAssertEqual(harness.boundPlainText, "B")
        XCTAssertEqual(harness.boundRichTextData, richTextB)
        XCTAssertNil(harness.appliedState.generation)
    }

    func testAcceptedFirstRestoreAlreadyMatchingStillSupersedesQueuedSynchronization() {
        let richTextA = Data("rich-A".utf8)
        let richTextB = Data("rich-B".utf8)
        let harness = MarkdownPreviewUIKitSyncHarness(
            boundPlainText: "Before A",
            boundRichTextData: nil
        )
        let textView = UITextView()
        textView.attributedText = NSAttributedString(string: "A")
        harness.synchronize(
            label: "A",
            nativePlainText: "A",
            richTextDisposition: .replace(richTextA),
            isUpdatingUIView: true
        )
        let queuedGeneration = harness.generationOwner.current
        XCTAssertEqual(harness.scheduledOperations.count, 1)

        let requestedB = NSAttributedString(
            string: "B",
            attributes: [.foregroundColor: UIColor.systemOrange]
        )
        textView.attributedText = requestedB
        harness.boundPlainText = "B"
        harness.boundRichTextData = richTextB
        let restoreGeneration = MarkdownPreviewUIKitRestoreGenerationOwner().begin()
        var supersessionCount = 0
        var replacementStartCount = 0
        var replacementFinishCount = 0
        var handledCount = 0

        MarkdownPreviewUIKitPostResignationReconciliation.reconcile(
            textView: textView,
            input: reconciliationInput(
                textView: textView,
                generation: queuedGeneration,
                appliedState: harness.appliedState,
                boundPlainText: "B",
                boundRichTextData: richTextB,
                boundAttributedText: requestedB,
                restoreRequest: .init(
                    token: .init(rawValue: 1),
                    lastHandledToken: .init(rawValue: 0),
                    generation: restoreGeneration,
                    lastAppliedGeneration: nil,
                    requestedAttributedText: requestedB
                )
            ),
            dependencies: reconciliationDependencies(
                willApplyReplacement: { replacementStartCount += 1 },
                didApplyReplacement: { _ in replacementFinishCount += 1 },
                supersedeAcceptedRestore: {
                    supersessionCount += 1
                    return MarkdownPreviewUIKitAcceptedRestoreSupersession.perform(
                        generationOwner: harness.generationOwner,
                        appliedContentState: &harness.appliedState
                    )
                },
                markRestoreHandled: { _, _ in handledCount += 1 }
            )
        )

        XCTAssertEqual(supersessionCount, 1)
        XCTAssertEqual(
            harness.generationOwner.current?.rawValue,
            (queuedGeneration?.rawValue ?? 0) + 1
        )
        XCTAssertNil(harness.appliedState.generation)
        XCTAssertEqual(replacementStartCount, 0)
        XCTAssertEqual(replacementFinishCount, 0)
        XCTAssertEqual(handledCount, 1)
        XCTAssertTrue(textView.attributedText.isEqual(to: requestedB))

        harness.runScheduled(at: 0)

        XCTAssertTrue(harness.plainWrites.isEmpty)
        XCTAssertTrue(harness.richTextWrites.isEmpty)
        XCTAssertTrue(harness.publications.isEmpty)
        XCTAssertEqual(harness.completionCounts, ["A": 1])
        XCTAssertTrue(textView.attributedText.isEqual(to: requestedB))
        XCTAssertEqual(harness.boundPlainText, "B")
        XCTAssertEqual(harness.boundRichTextData, richTextB)
    }

    func testRejectedNonNilRestoresAreTerminalWithoutOrdinaryReplacement() {
        let requested = NSAttributedString(string: "Restore")
        let scenarios: [(
            name: String,
            token: MarkdownPreviewUIKitRestoreToken,
            lastHandledToken: MarkdownPreviewUIKitRestoreToken,
            generation: MarkdownPreviewUIKitRestoreGeneration,
            lastAppliedGeneration: MarkdownPreviewUIKitRestoreGeneration?
        )] = [
            (
                "already handled token",
                .init(rawValue: 2),
                .init(rawValue: 2),
                .init(rawValue: 3),
                .init(rawValue: 2)
            ),
            (
                "invalid generation",
                .init(rawValue: 3),
                .init(rawValue: 2),
                .init(rawValue: 0),
                .init(rawValue: 2)
            ),
            (
                "duplicate generation",
                .init(rawValue: 3),
                .init(rawValue: 2),
                .init(rawValue: 2),
                .init(rawValue: 2)
            ),
            (
                "stale generation",
                .init(rawValue: 3),
                .init(rawValue: 2),
                .init(rawValue: 1),
                .init(rawValue: 2)
            )
        ]

        for scenario in scenarios {
            let textView = UITextView()
            textView.attributedText = NSAttributedString(string: "Native")
            let synchronizationOwner = MarkdownPreviewUIKitSyncGenerationOwner()
            let synchronizationGeneration = synchronizationOwner.begin()
            var appliedState = MarkdownPreviewUIKitAppliedContentState()
            XCTAssertTrue(
                appliedState.recordAppliedContentIfCurrent(
                    generation: synchronizationGeneration,
                    generationOwner: synchronizationOwner,
                    plainText: "Native",
                    richTextWrite: .none
                ),
                scenario.name
            )
            let originalAppliedState = appliedState
            var supersessionCount = 0
            var replacementStartCount = 0
            var replacementFinishCount = 0
            var handledCount = 0
            var clearCount = 0

            MarkdownPreviewUIKitPostResignationReconciliation.reconcile(
                textView: textView,
                input: reconciliationInput(
                    textView: textView,
                    generation: synchronizationGeneration,
                    appliedState: appliedState,
                    boundPlainText: "External",
                    boundAttributedText: NSAttributedString(string: "External"),
                    restoreRequest: .init(
                        token: scenario.token,
                        lastHandledToken: scenario.lastHandledToken,
                        generation: scenario.generation,
                        lastAppliedGeneration: scenario.lastAppliedGeneration,
                        requestedAttributedText: requested
                    )
                ),
                dependencies: reconciliationDependencies(
                    willApplyReplacement: { replacementStartCount += 1 },
                    didApplyReplacement: { _ in replacementFinishCount += 1 },
                    supersedeAcceptedRestore: {
                        supersessionCount += 1
                        return MarkdownPreviewUIKitAcceptedRestoreSupersession.perform(
                            generationOwner: synchronizationOwner,
                            appliedContentState: &appliedState
                        )
                    },
                    markRestoreHandled: { _, _ in handledCount += 1 },
                    clearAppliedContent: { _, _, _ in clearCount += 1 }
                )
            )

            XCTAssertEqual(textView.text, "Native", scenario.name)
            XCTAssertEqual(synchronizationOwner.current, synchronizationGeneration, scenario.name)
            XCTAssertEqual(appliedState, originalAppliedState, scenario.name)
            XCTAssertEqual(supersessionCount, 0, scenario.name)
            XCTAssertEqual(replacementStartCount, 0, scenario.name)
            XCTAssertEqual(replacementFinishCount, 0, scenario.name)
            XCTAssertEqual(handledCount, 0, scenario.name)
            XCTAssertEqual(clearCount, 0, scenario.name)
        }
    }

    func testReconciliationDerivesAuthoritativeBoundReplacementFromRawInputs() {
        let textView = UITextView()
        textView.attributedText = NSAttributedString(string: "Native")

        MarkdownPreviewUIKitPostResignationReconciliation.reconcile(
            textView: textView,
            input: reconciliationInput(
                textView: textView,
                boundPlainText: "External",
                boundAttributedText: NSAttributedString(string: "External")
            ),
            dependencies: reconciliationDependencies()
        )

        XCTAssertEqual(textView.text, "External")
    }

    func testReconciliationPreservesMarkedTextAndPendingFormatting() {
        for (hasMarkedText, hasPendingFormatting) in [(true, false), (false, true)] {
            let textView = UITextView()
            textView.attributedText = NSAttributedString(string: "Native")
            let input = reconciliationInput(
                textView: textView,
                boundPlainText: "External",
                boundAttributedText: NSAttributedString(string: "External"),
                hasMarkedText: hasMarkedText,
                hasPendingFormatting: hasPendingFormatting
            )

            MarkdownPreviewUIKitPostResignationReconciliation.reconcile(
                textView: textView,
                input: input,
                dependencies: reconciliationDependencies()
            )
            XCTAssertEqual(textView.text, "Native")
        }
    }

    func testStaleNonRestoreReconciliationPerformsNoReplacementMarkOrClear() {
        let textView = UITextView()
        textView.attributedText = NSAttributedString(string: "Native")
        var markCount = 0
        var clearCount = 0
        let input = reconciliationInput(
            textView: textView,
            generation: MarkdownPreviewUIKitSyncGeneration(rawValue: 1),
            isCurrent: false,
            boundPlainText: "External",
            boundAttributedText: NSAttributedString(string: "External")
        )

        MarkdownPreviewUIKitPostResignationReconciliation.reconcile(
            textView: textView,
            input: input,
            dependencies: reconciliationDependencies(
                markRestoreHandled: { _, _ in markCount += 1 },
                clearAppliedContent: { _, _, _ in clearCount += 1 }
            )
        )

        XCTAssertEqual(textView.text, "Native")
        XCTAssertEqual(markCount, 0)
        XCTAssertEqual(clearCount, 0)
    }

    func testGateRepeatedCompletionAttemptsInvokeCallbackOnce() {
        var callCount = 0
        let gate = EditorContentSyncCompletionGate { callCount += 1 }
        gate.complete()
        gate.complete()
        gate.complete()
        XCTAssertEqual(callCount, 1)
    }

    func testCommandConsumptionEditInteractiveExecutes() {
        XCTAssertEqual(
            MarkdownPreviewCommandConsumptionPolicy.disposition(forState: .editInteractive),
            .execute
        )
    }

    func testCommandConsumptionPendingAndVisiblePreviewSuppress() {
        XCTAssertEqual(
            MarkdownPreviewCommandConsumptionPolicy.disposition(forState: .previewTransitionPending),
            .consumeWithoutExecution
        )
        XCTAssertEqual(
            MarkdownPreviewCommandConsumptionPolicy.disposition(forState: .previewVisible),
            .consumeWithoutExecution
        )
    }

    func testResignationPolicyDistinguishesNoDifferenceAndFinalizedIME() {
        XCTAssertEqual(
            MarkdownPreviewResignationPolicy.disposition(
                isPreviewResignation: true,
                boundPlainText: "same",
                nativePlainText: "same"
            ),
            .acknowledgeWithoutPublication
        )
        XCTAssertEqual(
            MarkdownPreviewResignationPolicy.disposition(
                isPreviewResignation: true,
                boundPlainText: "old",
                nativePlainText: "old + IME"
            ),
            .publishFinalizedUserEditThenAcknowledge
        )
    }

    func testSearchPolicyIsolatesPendingAndVisiblePreview() {
        XCTAssertFalse(
            MarkdownPreviewSearchInteractionPolicy.isSearchPresented(
                state: .previewTransitionPending,
                isSearchActiveInState: true
            )
        )
        XCTAssertFalse(
            MarkdownPreviewSearchInteractionPolicy.isSearchPresented(
                state: .previewVisible,
                isSearchActiveInState: true
            )
        )
        XCTAssertTrue(
            MarkdownPreviewSearchInteractionPolicy.isSearchPresented(
                state: .editInteractive,
                isSearchActiveInState: true
            )
        )
        XCTAssertNil(
            MarkdownPreviewSearchInteractionPolicy.bodyHighlightRange(
                state: .previewVisible,
                highlightRange: NSRange(location: 1, length: 2)
            )
        )
    }

    private func reconciliationInput(
        textView: UITextView,
        generation: MarkdownPreviewUIKitSyncGeneration? = nil,
        isCurrent: Bool = true,
        appliedState: MarkdownPreviewUIKitAppliedContentState? = nil,
        boundPlainText: String,
        boundRichTextData: Data? = nil,
        boundAttributedText: NSAttributedString,
        nativeMatchesLatestPublication: Bool = false,
        restoreRequest: MarkdownPreviewUIKitPostResignationReconciliation.RestoreRequest? = nil,
        hasMarkedText: Bool = false,
        hasPendingFormatting: Bool = false,
        isResigningForPreview: Bool = false,
        isPreviewPending: Bool = false
    ) -> MarkdownPreviewUIKitPostResignationReconciliation.Input {
        .init(
            synchronizationGeneration: generation,
            isSynchronizationGenerationCurrent: isCurrent,
            nativePlainText: textView.text,
            nativeAttributedText: NSAttributedString(attributedString: textView.attributedText),
            boundPlainText: boundPlainText,
            boundRichTextData: boundRichTextData,
            boundAttributedText: boundAttributedText,
            appliedContentState: appliedState ?? MarkdownPreviewUIKitAppliedContentState(),
            nativeMatchesLatestEditorPublication: nativeMatchesLatestPublication,
            restoreRequest: restoreRequest,
            formattingState: .init(
                hasPendingNativeFormattingMutation: hasPendingFormatting,
                pendingFormattingToken: hasPendingFormatting ? 1 : nil
            ),
            focusState: .init(
                isFirstResponder: false,
                isHandlingUserFocusChange: false,
                isResigningForPreview: isResigningForPreview,
                hasMarkedText: hasMarkedText
            ),
            isPreviewTransitionPending: isPreviewPending,
            isPreviewVisible: false
        )
    }

    private func reconciliationDependencies(
        willApplyReplacement: @escaping () -> Void = {},
        didApplyReplacement: @escaping (NSRange) -> Void = { _ in },
        supersedeAcceptedRestore: @escaping () -> MarkdownPreviewUIKitSyncGeneration = {
            XCTFail("Accepted restore must supply the production supersession operation")
            return MarkdownPreviewUIKitSyncGeneration(rawValue: 0)
        },
        markRestoreHandled: @escaping (
            MarkdownPreviewUIKitRestoreToken,
            MarkdownPreviewUIKitRestoreGeneration
        ) -> Void = { _, _ in },
        clearAppliedContent: @escaping (
            MarkdownPreviewUIKitSyncGeneration,
            String,
            Data?
        ) -> Void = { _, _, _ in }
    ) -> MarkdownPreviewUIKitPostResignationReconciliation.Dependencies {
        .init(
            willApplyReplacement: willApplyReplacement,
            didApplyReplacement: didApplyReplacement,
            markRestoreHandled: markRestoreHandled,
            supersedeEditorSynchronizationForAcceptedRestore: supersedeAcceptedRestore,
            clearAppliedContentIfOwned: clearAppliedContent
        )
    }
}
