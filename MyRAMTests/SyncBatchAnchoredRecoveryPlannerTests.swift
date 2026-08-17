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

  func testFreshInsertionDuplicateUsesCoreDuplicateRun() throws {
    let operationID = SyncBatchAnchoredRecoveryTestFactory.operation(2)
    let incoming = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: operationID
    )
    let existingState = try SyncBatchAnchoredRecoveryTestFactory.applying(
      incoming,
      to: .empty
    )

    let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: incoming,
      sequenceState: existingState,
      recoverySnapshot: emptySnapshot()
    )

    XCTAssertEqual(plan.finalSequenceState, existingState)
    XCTAssertFalse(plan.didChangeApplicationState)
    XCTAssertEqual(plan.metrics.appliedEquivalentChecks, 0)
    XCTAssertEqual(plan.metrics.replayAttempts, 1)
    guard case .insertExpectedAbsent(let record) = plan.recoveryStoreTransitions.first,
      case .terminalStructuralFailure(let failure) = record.lifecycle
    else {
      return XCTFail("Expected terminal duplicate-run recovery record")
    }
    XCTAssertEqual(record.change, incoming)
    XCTAssertEqual(failure.code, .duplicateRun)
    XCTAssertEqual(failure.evidence.operationID, operationID)
  }

  func testPersistedRecoveryInsertionWithNonEquivalentStateBecomesTerminalIdentityCollision() throws {
    let fixture = try insertionDependencyFixture()
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: fixture.child,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    let waitingRecord = try insertedRecord(from: initial)
    let conflicting = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: fixture.parentState,
      offset: 1,
      text: "C",
      operationID: fixture.child.operationID
    )
    let conflictingState = try SyncBatchAnchoredRecoveryTestFactory.applying(
      conflicting,
      to: fixture.parentState
    )

    let plan = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      sequenceState: conflictingState,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [waitingRecord],
        health: .healthy
      ),
      trigger: .restartRecovery
    )

    XCTAssertEqual(plan.finalSequenceState, conflictingState)
    XCTAssertFalse(plan.didChangeApplicationState)
    guard case .replace(let expected, let replacement) = plan.recoveryStoreTransitions.first,
      case .terminalStructuralFailure(let failure) = replacement.lifecycle
    else {
      return XCTFail("Expected persisted recovery record to become terminal")
    }
    XCTAssertEqual(expected, waitingRecord)
    XCTAssertEqual(replacement.change, waitingRecord.change)
    XCTAssertEqual(failure.code, .identityCollision)
    XCTAssertEqual(failure.evidence.operationID, fixture.child.operationID)
  }

  func testConflictingWaitingRedeliveryTerminalizesOriginalRecordAndPersists() throws {
    let fixture = try insertionDependencyFixture()
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: fixture.child,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    let waitingRecord = try insertedRecord(from: initial)
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("myr177-collision-\(UUID().uuidString).json")
    let store = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    XCTAssertTrue(try store.apply(initial.recoveryStoreTransitions))

    let conflicting = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: fixture.parentState,
      offset: 1,
      text: "C",
      operationID: fixture.child.operationID
    )
    let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: conflicting,
      sequenceState: .empty,
      recoverySnapshot: store.snapshot()
    )

    XCTAssertEqual(plan.finalSequenceState, .empty)
    XCTAssertFalse(plan.didChangeApplicationState)
    XCTAssertEqual(plan.recoveryStoreTransitions.count, 1)
    guard case .replace(let expected, let replacement) = plan.recoveryStoreTransitions[0],
      case .terminalStructuralFailure(let failure) = replacement.lifecycle
    else {
      return XCTFail("Expected waiting record to terminalize on conflicting redelivery")
    }
    XCTAssertEqual(expected, waitingRecord)
    XCTAssertEqual(replacement.change, waitingRecord.change)
    XCTAssertNotEqual(replacement.change, conflicting)
    XCTAssertEqual(failure.code, .identityCollision)
    XCTAssertEqual(failure.evidence.operationID, fixture.child.operationID)

    XCTAssertTrue(try store.apply(plan.recoveryStoreTransitions))
    let reopened = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    XCTAssertEqual(reopened.snapshot().records, [replacement])
  }

  func testConflictingRedeliveryCannotRewriteExistingTerminalRecord() throws {
    let fixture = try insertionDependencyFixture()
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: fixture.child,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    let waitingRecord = try insertedRecord(from: initial)
    let terminalRecord = try SyncBatchAnchoredRecoveryRecord(
      key: waitingRecord.key,
      change: waitingRecord.change,
      lifecycle: .terminalStructuralFailure(
        .identityCollision(operationID: waitingRecord.key.operationID)
      )
    )
    let conflicting = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: fixture.parentState,
      offset: 1,
      text: "C",
      operationID: fixture.child.operationID
    )
    let snapshot = SyncBatchAnchoredRecoveryStoreSnapshot(
      records: [terminalRecord],
      health: .healthy
    )

    XCTAssertThrowsError(
      try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
        change: conflicting,
        sequenceState: .empty,
        recoverySnapshot: snapshot
      )
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryPlannerError,
        .identityCollision(waitingRecord.key)
      )
    }
    XCTAssertEqual(snapshot.records, [terminalRecord])
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

  func testPlanningRejectsUnhealthyStoreWithoutChangingProductionActivation() throws {
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
    XCTAssertTrue(SyncBatchAnchoredPayloadCapability.isEnabled)
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

extension SyncBatchAnchoredRecoveryPlannerTests {
  func testAbsentNonemptyBootstrapIsAdmissibleAndEstablishesFoundation() throws {
    let bootstrap = try bootstrapChange(body: "A")
    guard case .bootstrap(let value) = bootstrap else {
      return XCTFail("Expected bootstrap change")
    }
    let descriptor = try value.makeDescriptor()

    let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: bootstrap,
      foundation: .absent,
      recoverySnapshot: emptySnapshot()
    )

    XCTAssertEqual(plan.initialFoundation, .absent)
    XCTAssertEqual(plan.finalFoundation, .established(descriptor.state))
    XCTAssertTrue(plan.didChangeApplicationState)
    XCTAssertEqual(plan.structurallyAvailableOperationIDs, [value.operationID])
    XCTAssertTrue(plan.recoveryStoreTransitions.isEmpty)
  }

  func testAbsentEmptyBootstrapEstablishesEmptyFoundationWithoutOperation() throws {
    let bootstrap = try bootstrapChange(body: "")

    let first = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: bootstrap,
      foundation: .absent,
      recoverySnapshot: emptySnapshot()
    )
    XCTAssertEqual(first.initialFoundation, .absent)
    XCTAssertEqual(first.finalFoundation, .established(.empty))
    XCTAssertTrue(first.didChangeApplicationState)
    XCTAssertTrue(first.structurallyAvailableOperationIDs.isEmpty)

    let second = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: bootstrap,
      foundation: .established(.empty),
      recoverySnapshot: emptySnapshot()
    )
    XCTAssertEqual(second.initialFoundation, .established(.empty))
    XCTAssertEqual(second.finalFoundation, .established(.empty))
    XCTAssertFalse(second.didChangeApplicationState)
    XCTAssertTrue(second.structurallyAvailableOperationIDs.isEmpty)
  }

  func testEquivalentNonemptyBootstrapIsIdempotentAndExposesRepresentedOperation() throws {
    let bootstrap = try bootstrapChange(body: "A")
    guard case .bootstrap(let value) = bootstrap else {
      return XCTFail("Expected bootstrap change")
    }
    let descriptor = try value.makeDescriptor()

    let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: bootstrap,
      foundation: .established(descriptor.state),
      recoverySnapshot: emptySnapshot()
    )

    XCTAssertEqual(plan.initialFoundation, .established(descriptor.state))
    XCTAssertEqual(plan.finalFoundation, .established(descriptor.state))
    XCTAssertFalse(plan.didChangeApplicationState)
    XCTAssertEqual(plan.structurallyAvailableOperationIDs, [value.operationID])
    XCTAssertTrue(plan.recoveryStoreTransitions.isEmpty)
  }

  func testNonemptyBootstrapUnblocksWaitingDependentInSameInitialPlan() throws {
    let bootstrap = try bootstrapChange(body: "A")
    guard case .bootstrap(let value) = bootstrap else {
      return XCTFail("Expected bootstrap change")
    }
    let descriptor = try value.makeDescriptor()
    let child = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: descriptor.state,
      offset: 1,
      text: "B",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(60)
    )
    let waiting = try insertedRecord(
      from: SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
        change: child,
        sequenceState: .empty,
        recoverySnapshot: emptySnapshot()
      )
    )

    let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: bootstrap,
      foundation: .absent,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [waiting],
        health: .healthy
      )
    )

    XCTAssertEqual(plan.visibleText, "AB")
    XCTAssertEqual(plan.appliedRecords, [waiting])
    XCTAssertEqual(
      plan.recoveryStoreTransitions,
      [.removeCommitted(expected: waiting)]
    )
    XCTAssertEqual(
      Set(plan.structurallyAvailableOperationIDs),
      Set([value.operationID, child.operationID])
    )
  }

  func testSameVisibleTextWithDifferentStructureCreatesBootstrapConflict() throws {
    let bootstrap = try bootstrapChange(body: "A")
    let alternate = try SyncBatchAnchoredRecoveryTestFactory.state(
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(70)
    )

    let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: bootstrap,
      foundation: .established(alternate),
      recoverySnapshot: emptySnapshot()
    )

    XCTAssertEqual(plan.finalFoundation, .established(alternate))
    XCTAssertFalse(plan.didChangeApplicationState)
    XCTAssertTrue(plan.structurallyAvailableOperationIDs.isEmpty)
    guard case .insertExpectedAbsent(let record) = plan.recoveryStoreTransitions.first,
      case .bootstrapContentConflict(let conflict) = record.lifecycle
    else {
      return XCTFail("Expected bootstrap conflict")
    }
    XCTAssertEqual(record.change, bootstrap)
    XCTAssertEqual(conflict.reason, .nonEquivalentEstablishedState)
    XCTAssertFalse(conflict.establishedState.containsTombstones)
    XCTAssertEqual(
      try conflict.establishedState.makeValidatedSequenceState(),
      alternate
    )
    XCTAssertTrue(record.lifecycle.isTerminal)
    XCTAssertFalse(record.lifecycle.isWaiting)
  }

  func testTombstoneHistoryConflictsAndLateBootstrapCannotResurrectContent() throws {
    let bootstrap = try bootstrapChange(body: "A")
    guard case .bootstrap(let value) = bootstrap else {
      return XCTFail("Expected bootstrap change")
    }
    let descriptor = try value.makeDescriptor()
    let deletion = try SyncBatchAnchoredRecoveryTestFactory.deletionChange(
      state: descriptor.state,
      offset: 0,
      length: 1,
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(71)
    )
    let tombstoned = try SyncBatchAnchoredRecoveryTestFactory.applying(
      deletion,
      to: descriptor.state
    )
    XCTAssertEqual(tombstoned.visibleText, "")

    let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: bootstrap,
      foundation: .established(tombstoned),
      recoverySnapshot: emptySnapshot()
    )

    XCTAssertEqual(plan.finalFoundation, .established(tombstoned))
    XCTAssertFalse(plan.didChangeApplicationState)
    XCTAssertTrue(plan.structurallyAvailableOperationIDs.isEmpty)
    guard case .insertExpectedAbsent(let record) = plan.recoveryStoreTransitions.first,
      case .bootstrapContentConflict(let conflict) = record.lifecycle
    else {
      return XCTFail("Expected tombstone bootstrap conflict")
    }
    XCTAssertEqual(conflict.reason, .tombstoneHistory)
    XCTAssertTrue(conflict.establishedState.containsTombstones)
    XCTAssertEqual(
      try conflict.establishedState.makeValidatedSequenceState(),
      tombstoned
    )
  }

  func testStructuralEvidenceRoundTripsExactlyAndRejectsMalformedState() throws {
    let insertion = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "AB",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(80)
    )
    let inserted = try SyncBatchAnchoredRecoveryTestFactory.applying(insertion, to: .empty)
    let deletion = try SyncBatchAnchoredRecoveryTestFactory.deletionChange(
      state: inserted,
      offset: 0,
      length: 1,
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(81)
    )
    let state = try SyncBatchAnchoredRecoveryTestFactory.applying(deletion, to: inserted)
    let evidence = SyncBatchAnchoredStructuralStateEvidence(validating: state)
    let encoded = try JSONEncoder().encode(evidence)
    let decoded = try JSONDecoder().decode(
      SyncBatchAnchoredStructuralStateEvidence.self,
      from: encoded
    )

    XCTAssertEqual(decoded, evidence)
    XCTAssertEqual(try decoded.makeValidatedSequenceState(), state)
    let encodedText = String(decoding: encoded, as: UTF8.self)
    XCTAssertFalse(encodedText.contains("revision"))
    XCTAssertFalse(encodedText.contains("payload"))
    XCTAssertFalse(encodedText.contains("NoteSequenceStateRecord"))

    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
      var runs = object["runs"] as? [[String: Any]],
      !runs.isEmpty
    else {
      return XCTFail("Unable to inspect structural evidence")
    }
    runs[0]["text"] = ""
    object["runs"] = runs
    let malformed = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        SyncBatchAnchoredStructuralStateEvidence.self,
        from: malformed
      )
    )
  }

  func testBootstrapChangeDecodingRejectsUnsupportedVersionAndTamperedIdentity() throws {
    let bootstrap = try SyncBatchAnchoredBootstrapChange(
      noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
      body: "A",
      formatVersion: .v1
    )
    let encoded = try JSONEncoder().encode(bootstrap)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
      return XCTFail("Unable to inspect bootstrap encoding")
    }

    object["formatVersion"] = 99
    let unsupported = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(
      try JSONDecoder().decode(SyncBatchAnchoredBootstrapChange.self, from: unsupported)
    )

    object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["operationID"] = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(SyncBatchAnchoredRecoveryTestFactory.operation(999))
    )
    let tampered = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(
      try JSONDecoder().decode(SyncBatchAnchoredBootstrapChange.self, from: tampered)
    )
  }

  func testBootstrapConflictWriteFailurePreservesPriorMemoryAndDisk() throws {
    let fixture = try insertionDependencyFixture()
    let waiting = try insertedRecord(
      from: SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
        change: fixture.child,
        sequenceState: .empty,
        recoverySnapshot: emptySnapshot()
      )
    )
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("myr177-bootstrap-conflict-\(UUID().uuidString).json")
    var failWrites = false
    let store = FileBackedSyncBatchAnchoredRecoveryStore(
      fileURL: fileURL,
      atomicWriter: { data, url in
        if failWrites { throw TestError.injectedWriteFailure }
        try data.write(to: url, options: .atomic)
      }
    )
    XCTAssertTrue(try store.apply([.insertExpectedAbsent(waiting)]))
    let priorData = try Data(contentsOf: fileURL)

    let bootstrap = try bootstrapChange(body: "A")
    let alternate = try SyncBatchAnchoredRecoveryTestFactory.state(
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(90)
    )
    let conflictPlan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: bootstrap,
      foundation: .established(alternate),
      recoverySnapshot: store.snapshot()
    )
    failWrites = true

    XCTAssertThrowsError(try store.apply(conflictPlan.recoveryStoreTransitions)) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .persistenceFailed
      )
    }
    XCTAssertEqual(store.snapshot().records, [waiting])
    XCTAssertEqual(try Data(contentsOf: fileURL), priorData)
    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL).snapshot().records,
      [waiting]
    )
  }

  func testBootstrapConflictPersistsAndSurvivesRestartExactly() throws {
    let bootstrap = try bootstrapChange(body: "A")
    let alternate = try SyncBatchAnchoredRecoveryTestFactory.state(
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(91)
    )
    let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: bootstrap,
      foundation: .established(alternate),
      recoverySnapshot: emptySnapshot()
    )
    let conflictRecord = try insertedRecord(from: plan)
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("myr177-bootstrap-restart-\(UUID().uuidString).json")
    let store = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    XCTAssertTrue(try store.apply(plan.recoveryStoreTransitions))

    let reopened = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    XCTAssertEqual(reopened.snapshot().records, [conflictRecord])
    guard case .bootstrapContentConflict(let conflict) = conflictRecord.lifecycle else {
      return XCTFail("Expected bootstrap conflict")
    }
    XCTAssertEqual(
      try conflict.establishedState.makeValidatedSequenceState(),
      alternate
    )
  }

  func testBootstrapCannotWaitAndOrdinaryChangesCannotHoldBootstrapConflict() throws {
    let bootstrap = try bootstrapChange(body: "A")
    XCTAssertThrowsError(
      try SyncBatchAnchoredRecoveryRecord(
        change: bootstrap,
        lifecycle: .waiting(
          .deletionTarget(SyncBatchAnchoredRecoveryTestFactory.operation(1))
        )
      )
    )

    let insertion = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(92)
    )
    let conflict = SyncBatchAnchoredBootstrapConflict(establishedState: .empty)
    XCTAssertThrowsError(
      try SyncBatchAnchoredRecoveryRecord(
        change: insertion,
        lifecycle: .bootstrapContentConflict(conflict)
      )
    )
  }

  func testMissingFoundationRejectsInitialInsertionAndDeletionWithoutMutation() throws {
    let insertion = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(100)
    )
    let insertionState = try SyncBatchAnchoredRecoveryTestFactory.applying(insertion, to: .empty)
    let deletion = try SyncBatchAnchoredRecoveryTestFactory.deletionChange(
      state: insertionState,
      offset: 0,
      length: 1,
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(101)
    )
    let snapshot = emptySnapshot()

    for change in [insertion, deletion] {
      XCTAssertThrowsError(
        try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
          change: change,
          foundation: .absent,
          recoverySnapshot: snapshot
        )
      ) { error in
        XCTAssertEqual(
          error as? SyncBatchAnchoredDarkOrchestrationError,
          .missingStructuralFoundation(noteID: SyncBatchAnchoredRecoveryTestFactory.noteID)
        )
      }
    }
    XCTAssertEqual(snapshot.records, [])
    XCTAssertEqual(insertion.operationID, SyncBatchAnchoredRecoveryTestFactory.operation(100))
    XCTAssertEqual(deletion.operationID, SyncBatchAnchoredRecoveryTestFactory.operation(101))
  }

  func testMissingFoundationRejectsDependencyAndRestartRetry() throws {
    let fixture = try insertionDependencyFixture()
    let waiting = try insertedRecord(
      from: SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
        change: fixture.child,
        sequenceState: .empty,
        recoverySnapshot: emptySnapshot()
      )
    )
    let snapshot = SyncBatchAnchoredRecoveryStoreSnapshot(
      records: [waiting],
      health: .healthy
    )

    for trigger in [
      SyncBatchAnchoredRecoveryRetryTrigger.newlyAvailable([fixture.parent.operationID]),
      .restartRecovery,
    ] {
      XCTAssertThrowsError(
        try SyncBatchAnchoredRecoveryPlanner.planRetry(
          noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
          foundation: .absent,
          recoverySnapshot: snapshot,
          trigger: trigger
        )
      ) { error in
        XCTAssertEqual(
          error as? SyncBatchAnchoredDarkOrchestrationError,
          .missingStructuralFoundation(noteID: SyncBatchAnchoredRecoveryTestFactory.noteID)
        )
      }
    }
    XCTAssertEqual(snapshot.records, [waiting])
  }

  private func bootstrapChange(body: String) throws -> SyncBatchAnchoredRecoveryChange {
    .bootstrap(
      try SyncBatchAnchoredBootstrapChange(
        noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
        body: body,
        formatVersion: .v1
      )
    )
  }
}

extension SyncBatchAnchoredRecoveryPlannerTests {
  func testConvergenceBatchPlannerKeepsWaitingRecoveryOwnedBySourceBatch() throws {
    let fixture = try insertionDependencyFixture()
    guard case .insertion(let parentChange) = fixture.parent,
          case .insertion(let childChange) = fixture.child else {
      return XCTFail("Expected insertion fixture")
    }
    let waitingPlan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: fixture.child,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    let waitingRecord = try insertedRecord(from: waitingPlan)
    let recoverySnapshot = SyncBatchAnchoredRecoveryStoreSnapshot(
      records: [waitingRecord],
      health: .healthy
    )
    let noteID = SyncBatchAnchoredRecoveryTestFactory.noteID
    let originID = UUID(uuidString: "00000000-0000-0000-0000-000000179401")!
    let parentBatch = SyncBatch(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000179402")!,
      originDeviceID: originID,
      createdAt: Date(timeIntervalSince1970: 1_794),
      batchSequence: 1,
      changes: [.noteBodyTextInsertedAnchored(parentChange)]
    )
    let emptySnapshot = NoteSequenceStateMutationSnapshot(
      noteID: noteID,
      body: "",
      revision: 0,
      state: .empty
    )

    let parentOutcome = try SyncConvergenceAnchoredBatchPlanner().plan(
      indexedChanges: [(0, .noteBodyTextInsertedAnchored(parentChange))],
      batch: parentBatch,
      expectedSnapshot: emptySnapshot,
      recoverySnapshot: recoverySnapshot
    )
    guard case .success(let parentPlan) = parentOutcome else {
      return XCTFail("Expected parent source batch to succeed")
    }
    XCTAssertEqual(parentPlan.finalBody, "A")
    XCTAssertTrue(parentPlan.recoveryTransitions.isEmpty)

    let childBatch = SyncBatch(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000179403")!,
      originDeviceID: originID,
      createdAt: Date(timeIntervalSince1970: 1_795),
      batchSequence: 2,
      changes: [.noteBodyTextInsertedAnchored(childChange)]
    )
    let parentSnapshot = NoteSequenceStateMutationSnapshot(
      noteID: noteID,
      body: parentPlan.finalBody,
      revision: 1,
      state: parentPlan.finalState
    )

    let childOutcome = try SyncConvergenceAnchoredBatchPlanner().plan(
      indexedChanges: [(0, .noteBodyTextInsertedAnchored(childChange))],
      batch: childBatch,
      expectedSnapshot: parentSnapshot,
      recoverySnapshot: recoverySnapshot
    )
    guard case .success(let childPlan) = childOutcome else {
      return XCTFail("Expected retained child source batch retry to succeed")
    }
    XCTAssertEqual(childPlan.finalBody, "AB")
    XCTAssertTrue(childPlan.didChangeApplicationState)
    XCTAssertEqual(
      childPlan.recoveryTransitions,
      [.removeCommitted(expected: waitingRecord)]
    )
  }
}
