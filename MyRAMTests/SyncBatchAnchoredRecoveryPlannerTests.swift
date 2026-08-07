import AnchoredSequenceCore
import Foundation
import XCTest

@testable import MyRAM

final class SyncBatchAnchoredRecoveryPlannerTests: XCTestCase {
  func testInitialMissingInsertionCreatesExactWaitingRecord() throws {
    let parent = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    let parentState = try SyncBatchAnchoredRecoveryTestFactory.applying(
      parent,
      to: .empty
    )
    let child = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: parentState,
      offset: 1,
      text: "B",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )

    let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: child,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )

    XCTAssertEqual(plan.finalSequenceState, .empty)
    XCTAssertFalse(plan.didChangeApplicationState)
    XCTAssertEqual(plan.recoveryStoreTransitions.count, 1)
    guard case .insertExpectedAbsent(let record) = plan.recoveryStoreTransitions[0],
      case .waiting(.insertionAnchor(let elementID)) = record.lifecycle
    else {
      return XCTFail("Expected exact missing insertion anchor")
    }
    XCTAssertEqual(elementID.operationID, parent.operationID)
    XCTAssertEqual(elementID.elementOffset, 0)
    XCTAssertEqual(record.change, child)
  }

  func testInsertionRetriesAfterParentArrivalAndProducesRemovalPlan() throws {
    let fixture = try insertionDependencyFixture()
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: fixture.child,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    let waitingRecord = try insertedRecord(from: initial)
    let snapshot = SyncBatchAnchoredRecoveryStoreSnapshot(
      records: [waitingRecord],
      health: .healthy
    )

    let retry = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: fixture.parentState,
      recoverySnapshot: snapshot,
      trigger: .newlyAvailable([fixture.parent.operationID])
    )

    XCTAssertEqual(retry.visibleText, "AB")
    XCTAssertTrue(retry.didChangeApplicationState)
    XCTAssertEqual(retry.appliedRecords, [waitingRecord])
    XCTAssertEqual(
      retry.structurallyAvailableOperationIDs,
      [fixture.child.operationID]
    )
    XCTAssertEqual(
      retry.recoveryStoreTransitions,
      [.removeCommitted(expected: waitingRecord)]
    )
  }

  func testDeletionWaitsForTargetThenTombstonesIt() throws {
    let target = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    let targetState = try SyncBatchAnchoredRecoveryTestFactory.applying(
      target,
      to: .empty
    )
    let deletion = try SyncBatchAnchoredRecoveryTestFactory.deletionChange(
      state: targetState,
      offset: 0,
      length: 1,
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: deletion,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    let waitingRecord = try insertedRecord(from: initial)
    guard case .waiting(.deletionTarget(let dependency)) = waitingRecord.lifecycle else {
      return XCTFail("Expected missing delete target")
    }
    XCTAssertEqual(dependency, target.operationID)

    let retry = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: targetState,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [waitingRecord],
        health: .healthy
      ),
      trigger: .newlyAvailable([target.operationID])
    )

    XCTAssertEqual(retry.visibleText, "")
    XCTAssertTrue(retry.didChangeApplicationState)
    XCTAssertTrue(retry.structurallyAvailableOperationIDs.isEmpty)
    XCTAssertEqual(
      retry.recoveryStoreTransitions,
      [.removeCommitted(expected: waitingRecord)]
    )
  }

  func testRetryReindexesFromOneMissingAnchorToAnother() throws {
    let left = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "L",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    let leftState = try SyncBatchAnchoredRecoveryTestFactory.applying(left, to: .empty)
    let right = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: leftState,
      offset: 1,
      text: "R",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let completeState = try SyncBatchAnchoredRecoveryTestFactory.applying(
      right,
      to: leftState
    )
    let child = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: completeState,
      offset: 1,
      text: "X",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(3)
    )
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: child,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    let original = try insertedRecord(from: initial)

    let reindex = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: leftState,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [original],
        health: .healthy
      ),
      trigger: .newlyAvailable([left.operationID])
    )

    XCTAssertFalse(reindex.didChangeApplicationState)
    XCTAssertEqual(reindex.recoveryStoreTransitions.count, 1)
    guard case .replace(let expected, let replacement) = reindex.recoveryStoreTransitions[0],
      case .waiting(.insertionAnchor(let missingRight)) = replacement.lifecycle
    else {
      return XCTFail("Expected exact reindex transition")
    }
    XCTAssertEqual(expected, original)
    XCTAssertEqual(replacement.change, original.change)
    XCTAssertEqual(missingRight.operationID, right.operationID)
    XCTAssertEqual(missingRight.elementOffset, 0)

    let final = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: completeState,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [replacement],
        health: .healthy
      ),
      trigger: .newlyAvailable([right.operationID])
    )
    XCTAssertEqual(final.visibleText, "LXR")
    XCTAssertTrue(final.didChangeApplicationState)
  }

  func testInterruptedInsertionCleanupUsesExactAppliedEquivalence() throws {
    let fixture = try insertionDependencyFixture()
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: fixture.child,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    let waitingRecord = try insertedRecord(from: initial)
    let committedState = try SyncBatchAnchoredRecoveryTestFactory.applying(
      fixture.child,
      to: fixture.parentState
    )

    let retry = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: committedState,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [waitingRecord],
        health: .healthy
      ),
      trigger: .restartRecovery
    )

    XCTAssertEqual(retry.finalSequenceState, committedState)
    XCTAssertFalse(retry.didChangeApplicationState)
    XCTAssertEqual(
      retry.recoveryStoreTransitions,
      [.removeCommitted(expected: waitingRecord)]
    )
    XCTAssertEqual(retry.appliedRecords, [waitingRecord])
  }

  func testFileBackedInterruptedCleanupSurvivesRestartAndCleansUpExactly() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("myr177-interrupted-\(UUID().uuidString).json")
    var failWrites = false
    let fixture = try insertionDependencyFixture()
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: fixture.child,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    let waitingRecord = try insertedRecord(from: initial)
    let store = FileBackedSyncBatchAnchoredRecoveryStore(
      fileURL: fileURL,
      atomicWriter: { data, url in
        if failWrites { throw TestError.injectedWriteFailure }
        try data.write(to: url, options: .atomic)
      }
    )
    XCTAssertTrue(try store.apply(initial.recoveryStoreTransitions))
    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
        .snapshot().records,
      [waitingRecord]
    )

    let committedState = try SyncBatchAnchoredRecoveryTestFactory.applying(
      fixture.child,
      to: fixture.parentState
    )
    let expectedMetrics = SyncBatchAnchoredRecoveryPlanningMetrics(
      dequeuedDependencies: 2,
      selectedRecords: 1,
      replayAttempts: 0,
      appliedEquivalentChecks: 1,
      emittedTransitions: 1
    )
    let firstCleanup = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: committedState,
      recoverySnapshot: store.snapshot(),
      trigger: .restartRecovery
    )

    XCTAssertEqual(firstCleanup.initialSequenceState, committedState)
    XCTAssertEqual(firstCleanup.finalSequenceState, committedState)
    XCTAssertEqual(firstCleanup.visibleText, committedState.visibleText)
    XCTAssertEqual(firstCleanup.appliedRecords, [waitingRecord])
    XCTAssertEqual(
      firstCleanup.recoveryStoreTransitions,
      [.removeCommitted(expected: waitingRecord)]
    )
    XCTAssertEqual(
      firstCleanup.structurallyAvailableOperationIDs,
      [fixture.child.operationID]
    )
    XCTAssertFalse(firstCleanup.didChangeApplicationState)
    XCTAssertEqual(firstCleanup.metrics, expectedMetrics)

    failWrites = true
    XCTAssertThrowsError(
      try store.apply(firstCleanup.recoveryStoreTransitions)
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .persistenceFailed
      )
    }
    XCTAssertEqual(store.snapshot().records, [waitingRecord])
    guard case .writeFailed = store.snapshot().health else {
      return XCTFail("Expected writeFailed health")
    }
    XCTAssertThrowsError(
      try store.apply(firstCleanup.recoveryStoreTransitions)
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .unhealthyPersistence
      )
    }

    let reopened = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    XCTAssertEqual(reopened.snapshot().health, .healthy)
    XCTAssertEqual(reopened.snapshot().records, [waitingRecord])

    let secondCleanup = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: committedState,
      recoverySnapshot: reopened.snapshot(),
      trigger: .restartRecovery
    )
    XCTAssertEqual(secondCleanup, firstCleanup)
    XCTAssertEqual(secondCleanup.finalSequenceState, committedState)
    XCTAssertFalse(secondCleanup.didChangeApplicationState)

    XCTAssertTrue(try reopened.apply(secondCleanup.recoveryStoreTransitions))
    let finalStore = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    XCTAssertEqual(finalStore.snapshot().health, .healthy)
    XCTAssertTrue(finalStore.snapshot().records.isEmpty)
  }

  func testMirroredHostContractPlansIdenticalInsertionAndDeletionRetry() throws {
    let parent = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    let parentState = try SyncBatchAnchoredRecoveryTestFactory.applying(parent, to: .empty)
    let child = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: parentState,
      offset: 1,
      text: "B",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let deletion = try SyncBatchAnchoredRecoveryTestFactory.deletionChange(
      state: parentState,
      offset: 0,
      length: 1,
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(3)
    )
    let childRecord = try insertedRecord(
      from: SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
        change: child,
        sequenceState: .empty,
        recoverySnapshot: emptySnapshot()
      )
    )
    let deletionRecord = try insertedRecord(
      from: SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
        change: deletion,
        sequenceState: .empty,
        recoverySnapshot: emptySnapshot()
      )
    )
    let stateWithChild = try SyncBatchAnchoredRecoveryTestFactory.applying(
      child,
      to: parentState
    )
    let expectedFinalState = try SyncBatchAnchoredRecoveryTestFactory.applying(
      deletion,
      to: stateWithChild
    )

    let plan = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: parentState,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [deletionRecord, childRecord],
        health: .healthy
      ),
      trigger: .newlyAvailable([parent.operationID])
    )

    XCTAssertEqual(plan.initialSequenceState, parentState)
    XCTAssertEqual(plan.finalSequenceState, expectedFinalState)
    XCTAssertEqual(plan.visibleText, "B")
    XCTAssertEqual(plan.appliedRecords, [childRecord, deletionRecord])
    XCTAssertEqual(
      plan.recoveryStoreTransitions,
      [
        .removeCommitted(expected: childRecord),
        .removeCommitted(expected: deletionRecord),
      ]
    )
    XCTAssertEqual(plan.structurallyAvailableOperationIDs, [child.operationID])
    XCTAssertTrue(plan.didChangeApplicationState)
    XCTAssertEqual(
      plan.metrics,
      SyncBatchAnchoredRecoveryPlanningMetrics(
        dequeuedDependencies: 2,
        selectedRecords: 2,
        replayAttempts: 2,
        appliedEquivalentChecks: 2,
        emittedTransitions: 2
      )
    )
  }

  func testSameInsertionIdentityWithDifferentTextBecomesTerminal() throws {
    let operationID = SyncBatchAnchoredRecoveryTestFactory.operation(2)
    let incoming = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: operationID
    )
    let conflicting = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "B",
      operationID: operationID
    )
    let conflictState = try SyncBatchAnchoredRecoveryTestFactory.applying(
      conflicting,
      to: .empty
    )

    let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: incoming,
      sequenceState: conflictState,
      recoverySnapshot: emptySnapshot()
    )

    XCTAssertEqual(plan.finalSequenceState, conflictState)
    XCTAssertFalse(plan.didChangeApplicationState)
    guard case .insertExpectedAbsent(let record) = plan.recoveryStoreTransitions.first,
      case .terminalStructuralFailure(let failure) = record.lifecycle
    else {
      return XCTFail("Expected terminal identity collision")
    }
    XCTAssertEqual(failure.code, .identityCollision)
    XCTAssertEqual(failure.evidence.operationID, operationID)
  }

  func testInitialSuccessfulInsertionAndDeletionNeedNoRecoveryRecord() throws {
    let insertion = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    let insertionPlan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: insertion,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    XCTAssertEqual(insertionPlan.visibleText, "A")
    XCTAssertTrue(insertionPlan.didChangeApplicationState)
    XCTAssertTrue(insertionPlan.recoveryStoreTransitions.isEmpty)
    XCTAssertEqual(
      insertionPlan.structurallyAvailableOperationIDs,
      [insertion.operationID]
    )

    let deletion = try SyncBatchAnchoredRecoveryTestFactory.deletionChange(
      state: insertionPlan.finalSequenceState,
      offset: 0,
      length: 1,
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let deletionPlan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: deletion,
      sequenceState: insertionPlan.finalSequenceState,
      recoverySnapshot: emptySnapshot()
    )
    XCTAssertEqual(deletionPlan.visibleText, "")
    XCTAssertTrue(deletionPlan.didChangeApplicationState)
    XCTAssertTrue(deletionPlan.recoveryStoreTransitions.isEmpty)
    XCTAssertTrue(deletionPlan.structurallyAvailableOperationIDs.isEmpty)
  }

  func testEquivalentWaitingRedeliveryIsARecoveryStoreNoOp() throws {
    let fixture = try insertionDependencyFixture()
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: fixture.child,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    let waitingRecord = try insertedRecord(from: initial)

    let redelivery = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: fixture.child,
      sequenceState: .empty,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [waitingRecord],
        health: .healthy
      )
    )

    XCTAssertEqual(redelivery.finalSequenceState, .empty)
    XCTAssertFalse(redelivery.didChangeApplicationState)
    XCTAssertTrue(redelivery.recoveryStoreTransitions.isEmpty)
  }

  func testOutOfBoundsInsertionAnchorBecomesTerminalWithoutFallback() throws {
    let parent = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    let parentState = try SyncBatchAnchoredRecoveryTestFactory.applying(
      parent,
      to: .empty
    )
    let valid = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: parentState,
      offset: 1,
      text: "B",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let invalidElement = try SyncBatchAnchoredRecoveryTestFactory.element(
      parent.operationID,
      offset: 99
    )
    let invalid = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      replacingAnchorIn: valid,
      kind: "after",
      leftElementID: invalidElement,
      rightElementID: nil
    )

    let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: invalid,
      sequenceState: parentState,
      recoverySnapshot: emptySnapshot()
    )

    XCTAssertEqual(plan.finalSequenceState, parentState)
    XCTAssertFalse(plan.didChangeApplicationState)
    guard case .insertExpectedAbsent(let record) = plan.recoveryStoreTransitions.first,
      case .terminalStructuralFailure(let failure) = record.lifecycle
    else {
      return XCTFail("Expected terminal structural failure")
    }
    XCTAssertEqual(failure.code, .anchorElementOutOfBounds)
    XCTAssertEqual(failure.evidence.elementID, invalidElement)
  }

  func testWaitingDeletionTransitionsToTerminalWhenTargetArrivesInvalid() throws {
    let target = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    let targetState = try SyncBatchAnchoredRecoveryTestFactory.applying(
      target,
      to: .empty
    )
    let validDeletion = try SyncBatchAnchoredRecoveryTestFactory.deletionChange(
      state: targetState,
      offset: 0,
      length: 1,
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let invalidDeletion = try SyncBatchAnchoredRecoveryTestFactory.deletionChange(
      replacingFirstSpanLengthIn: validDeletion,
      utf16Length: 2
    )
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: invalidDeletion,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    let waitingRecord = try insertedRecord(from: initial)

    let retry = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: targetState,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [waitingRecord],
        health: .healthy
      ),
      trigger: .newlyAvailable([target.operationID])
    )

    XCTAssertEqual(retry.finalSequenceState, targetState)
    XCTAssertFalse(retry.didChangeApplicationState)
    guard case .replace(let expected, let replacement) = retry.recoveryStoreTransitions.first,
      case .terminalStructuralFailure(let failure) = replacement.lifecycle
    else {
      return XCTFail("Expected waiting-to-terminal replacement")
    }
    XCTAssertEqual(expected, waitingRecord)
    XCTAssertEqual(replacement.change, waitingRecord.change)
    XCTAssertEqual(failure.code, .deleteTargetRangeExceedsRun)
  }

  func testMultiLevelInsertionChainProgressesInOneDeterministicPlan() throws {
    let parent = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    let parentState = try SyncBatchAnchoredRecoveryTestFactory.applying(parent, to: .empty)
    let child = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: parentState,
      offset: 1,
      text: "B",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let childState = try SyncBatchAnchoredRecoveryTestFactory.applying(child, to: parentState)
    let grandchild = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: childState,
      offset: 2,
      text: "C",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(3)
    )
    let childRecord = try insertedRecord(
      from: SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
        change: child,
        sequenceState: .empty,
        recoverySnapshot: emptySnapshot()
      )
    )
    let grandchildRecord = try insertedRecord(
      from: SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
        change: grandchild,
        sequenceState: .empty,
        recoverySnapshot: emptySnapshot()
      )
    )

    let plan = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: parentState,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [grandchildRecord, childRecord],
        health: .healthy
      ),
      trigger: .newlyAvailable([parent.operationID])
    )

    XCTAssertEqual(plan.visibleText, "ABC")
    XCTAssertEqual(plan.appliedRecords, [childRecord, grandchildRecord])
    XCTAssertEqual(
      plan.recoveryStoreTransitions,
      [
        .removeCommitted(expected: childRecord),
        .removeCommitted(expected: grandchildRecord),
      ]
    )
    XCTAssertEqual(
      plan.structurallyAvailableOperationIDs,
      [child.operationID, grandchild.operationID]
    )
    XCTAssertEqual(plan.metrics.dequeuedDependencies, 3)
    XCTAssertEqual(plan.metrics.selectedRecords, 2)
  }

  func testSameAnchorSnapshotOrderDoesNotChangePlan() throws {
    let parent = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    let parentState = try SyncBatchAnchoredRecoveryTestFactory.applying(parent, to: .empty)
    let first = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: parentState,
      offset: 1,
      text: "X",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let second = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: parentState,
      offset: 1,
      text: "Y",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(3)
    )
    let firstRecord = try insertedRecord(
      from: SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
        change: first,
        sequenceState: .empty,
        recoverySnapshot: emptySnapshot()
      )
    )
    let secondRecord = try insertedRecord(
      from: SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
        change: second,
        sequenceState: .empty,
        recoverySnapshot: emptySnapshot()
      )
    )

    func plan(_ records: [SyncBatchAnchoredRecoveryRecord]) throws
      -> SyncBatchAnchoredRecoveryCommitPlan
    {
      try SyncBatchAnchoredRecoveryPlanner.planRetry(
        noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
        sequenceState: parentState,
        recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
          records: records,
          health: .healthy
        ),
        trigger: .newlyAvailable([parent.operationID])
      )
    }

    XCTAssertEqual(
      try plan([firstRecord, secondRecord]),
      try plan([secondRecord, firstRecord])
    )
  }

  func testRetryMetricsSelectOnlyTriggeredDependencyChain() throws {
    let fixture = try insertionDependencyFixture()
    let triggeredRecord = try insertedRecord(
      from: SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
        change: fixture.child,
        sequenceState: .empty,
        recoverySnapshot: emptySnapshot()
      )
    )
    var records = [triggeredRecord]
    for index in UInt64(0)..<20 {
      let dependency = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
        state: .empty,
        offset: 0,
        text: "D",
        operationID: SyncBatchAnchoredRecoveryTestFactory.operation(100 + index)
      )
      let dependencyState = try SyncBatchAnchoredRecoveryTestFactory.applying(
        dependency,
        to: .empty
      )
      let unrelated = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
        state: dependencyState,
        offset: 1,
        text: "U",
        operationID: SyncBatchAnchoredRecoveryTestFactory.operation(200 + index)
      )
      records.append(
        try insertedRecord(
          from: SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
            change: unrelated,
            sequenceState: .empty,
            recoverySnapshot: emptySnapshot()
          )
        )
      )
    }

    let plan = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: fixture.parentState,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: records.reversed(),
        health: .healthy
      ),
      trigger: .newlyAvailable([fixture.parent.operationID])
    )

    XCTAssertEqual(plan.visibleText, "AB")
    XCTAssertEqual(plan.metrics.selectedRecords, 1)
    XCTAssertEqual(plan.metrics.replayAttempts, 1)
    XCTAssertEqual(plan.recoveryStoreTransitions.count, 1)
  }

  func testInterruptedDeletionCleanupAndPartialReplayRemainIdempotent() throws {
    let target = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "AB",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    let targetState = try SyncBatchAnchoredRecoveryTestFactory.applying(target, to: .empty)
    let fullDeletion = try SyncBatchAnchoredRecoveryTestFactory.deletionChange(
      state: targetState,
      offset: 0,
      length: 2,
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let firstDeletion = try SyncBatchAnchoredRecoveryTestFactory.deletionChange(
      state: targetState,
      offset: 0,
      length: 1,
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(3)
    )
    let waitingRecord = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: fullDeletion,
      dependency: .deletionTarget(target.operationID)
    )
    let fullyCommitted = try SyncBatchAnchoredRecoveryTestFactory.applying(
      fullDeletion,
      to: targetState
    )
    let cleanup = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: fullyCommitted,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [waitingRecord],
        health: .healthy
      ),
      trigger: .restartRecovery
    )
    XCTAssertEqual(cleanup.finalSequenceState, fullyCommitted)
    XCTAssertFalse(cleanup.didChangeApplicationState)
    XCTAssertEqual(
      cleanup.recoveryStoreTransitions,
      [.removeCommitted(expected: waitingRecord)]
    )

    let partiallyCommitted = try SyncBatchAnchoredRecoveryTestFactory.applying(
      firstDeletion,
      to: targetState
    )
    let remaining = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: partiallyCommitted,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [waitingRecord],
        health: .healthy
      ),
      trigger: .restartRecovery
    )
    XCTAssertEqual(remaining.visibleText, "")
    XCTAssertTrue(remaining.didChangeApplicationState)
    XCTAssertEqual(
      remaining.recoveryStoreTransitions,
      [.removeCommitted(expected: waitingRecord)]
    )
  }

  func testPlanningRejectsUnhealthyStoreAndKeepsCapabilityDisabled() throws {
    let change = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    XCTAssertThrowsError(
      try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
        change: change,
        sequenceState: .empty,
        recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
          records: [],
          health: .corrupt
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryPlannerError,
        .unhealthyRecoveryStore
      )
    }
    XCTAssertFalse(SyncBatchAnchoredPayloadCapability.isEnabled)
  }

  private func insertionDependencyFixture() throws -> (
    parent: SyncBatchAnchoredRecoveryChange,
    parentState: SyncTextSequenceState,
    child: SyncBatchAnchoredRecoveryChange
  ) {
    let parent = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    let parentState = try SyncBatchAnchoredRecoveryTestFactory.applying(
      parent,
      to: .empty
    )
    let child = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: parentState,
      offset: 1,
      text: "B",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    return (parent, parentState, child)
  }

  private func emptySnapshot() -> SyncBatchAnchoredRecoveryStoreSnapshot {
    SyncBatchAnchoredRecoveryStoreSnapshot(records: [], health: .healthy)
  }

  private func insertedRecord(
    from plan: SyncBatchAnchoredRecoveryCommitPlan
  ) throws -> SyncBatchAnchoredRecoveryRecord {
    guard case .insertExpectedAbsent(let record) = plan.recoveryStoreTransitions.first else {
      throw TestError.missingInsertedRecord
    }
    return record
  }

  private enum TestError: Error {
    case missingInsertedRecord
    case injectedWriteFailure
  }
}
