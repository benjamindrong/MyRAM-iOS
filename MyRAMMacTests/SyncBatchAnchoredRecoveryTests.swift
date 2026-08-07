import AnchoredSequenceCore
import Foundation
import XCTest

@testable import MyRAMMac

final class SyncBatchAnchoredRecoveryTests: XCTestCase {
  private let noteID = UUID(
    uuidString: "17710000-0000-0000-0000-000000000001"
  )!
  private let deviceID = UUID(
    uuidString: "17710000-0000-0000-0000-000000000002"
  )!
  private let modifiedAt = Date(timeIntervalSince1970: 1_771)

  func testNativeMacPlansMissingInsertionAndRetry() throws {
    let parent = try insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      counter: 1
    )
    let parentState = try SyncBatchAnchoredRecoveryReplay.apply(parent, to: .empty)
    let child = try insertionChange(
      state: parentState,
      offset: 1,
      text: "B",
      counter: 2
    )
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: child,
      sequenceState: .empty,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [],
        health: .healthy
      )
    )
    guard case .insertExpectedAbsent(let waitingRecord) = initial.recoveryStoreTransitions.first
    else {
      return XCTFail("Expected waiting record")
    }

    let retry = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: noteID,
      sequenceState: parentState,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [waitingRecord],
        health: .healthy
      ),
      trigger: .newlyAvailable([parent.operationID])
    )

    XCTAssertEqual(retry.visibleText, "AB")
    XCTAssertEqual(
      retry.recoveryStoreTransitions,
      [.removeCommitted(expected: waitingRecord)]
    )
    XCTAssertFalse(SyncBatchAnchoredPayloadCapability.isEnabled)
  }

  func testNativeMacRecoveryStoreRoundTripsTemporaryFile() throws {
    let parent = try insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      counter: 1
    )
    let parentState = try SyncBatchAnchoredRecoveryReplay.apply(parent, to: .empty)
    let child = try insertionChange(
      state: parentState,
      offset: 1,
      text: "B",
      counter: 2
    )
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: child,
      sequenceState: .empty,
      recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [],
        health: .healthy
      )
    )
    guard case .insertExpectedAbsent(let waitingRecord) = initial.recoveryStoreTransitions.first
    else {
      return XCTFail("Expected waiting record")
    }
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("mac-recovery.json")
    let store = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    try store.apply([.insertExpectedAbsent(waitingRecord)])

    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
        .snapshot().records,
      [waitingRecord]
    )
  }

  func testNativeMacDeletionWaitsForTargetThenTombstonesExactRange() throws {
    let target = try insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      counter: 1
    )
    let targetState = try SyncBatchAnchoredRecoveryReplay.apply(target, to: .empty)
    let deletion = try deletionChange(
      state: targetState,
      offset: 0,
      length: 1,
      counter: 2
    )
    let initial = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
      change: deletion,
      sequenceState: .empty,
      recoverySnapshot: emptySnapshot()
    )
    guard case .insertExpectedAbsent(let waitingRecord) = initial.recoveryStoreTransitions.first,
      case .waiting(.deletionTarget(let missingOperationID)) = waitingRecord.lifecycle
    else {
      return XCTFail("Expected exact waiting deletion record")
    }
    XCTAssertEqual(missingOperationID, target.operationID)
    XCTAssertEqual(waitingRecord.change, deletion)

    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("myr177-native-mac-delete-\(UUID().uuidString).json")
    let store = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    XCTAssertTrue(try store.apply(initial.recoveryStoreTransitions))

    let retry = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: noteID,
      sequenceState: targetState,
      recoverySnapshot: store.snapshot(),
      trigger: .newlyAvailable([target.operationID])
    )
    let expectedState = try SyncBatchAnchoredRecoveryReplay.apply(
      deletion,
      to: targetState
    )

    XCTAssertEqual(retry.initialSequenceState, targetState)
    XCTAssertEqual(retry.finalSequenceState, expectedState)
    XCTAssertEqual(retry.visibleText, "")
    XCTAssertTrue(retry.structurallyAvailableOperationIDs.isEmpty)
    XCTAssertEqual(retry.appliedRecords, [waitingRecord])
    XCTAssertEqual(
      retry.recoveryStoreTransitions,
      [.removeCommitted(expected: waitingRecord)]
    )
    XCTAssertEqual(store.snapshot().records, [waitingRecord])

    XCTAssertTrue(try store.apply(retry.recoveryStoreTransitions))
    XCTAssertTrue(store.snapshot().records.isEmpty)
  }

  func testMirroredHostContractPlansIdenticalInsertionAndDeletionRetry() throws {
    let parent = try insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      counter: 1
    )
    let parentState = try SyncBatchAnchoredRecoveryReplay.apply(parent, to: .empty)
    let child = try insertionChange(
      state: parentState,
      offset: 1,
      text: "B",
      counter: 2
    )
    let deletion = try deletionChange(
      state: parentState,
      offset: 0,
      length: 1,
      counter: 3
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
    let stateWithChild = try SyncBatchAnchoredRecoveryReplay.apply(
      child,
      to: parentState
    )
    let expectedFinalState = try SyncBatchAnchoredRecoveryReplay.apply(
      deletion,
      to: stateWithChild
    )

    let plan = try SyncBatchAnchoredRecoveryPlanner.planRetry(
      noteID: noteID,
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

  private func operation(_ counter: UInt64) -> SyncOperationID {
    SyncOperationID(deviceID: deviceID, localCounter: counter)
  }

  private func insertionChange(
    state: SyncTextSequenceState,
    offset: Int,
    text: String,
    counter: UInt64
  ) throws -> SyncBatchAnchoredRecoveryChange {
    let batchChange = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
      noteID: noteID,
      utf16Offset: offset,
      text: text,
      modifiedAt: modifiedAt,
      baseContentHash: nil,
      operationID: operation(counter),
      state: state
    )
    guard case .noteBodyTextInsertedAnchored(let change) = batchChange else {
      throw TestError.unexpectedChange
    }
    return .insertion(change)
  }

  private func deletionChange(
    state: SyncTextSequenceState,
    offset: Int,
    length: Int,
    counter: UInt64
  ) throws -> SyncBatchAnchoredRecoveryChange {
    let batchChange = try SyncBatchAnchoredPayloadAdapter.makeDeletedChange(
      noteID: noteID,
      utf16Offset: offset,
      utf16Length: length,
      expectedText: nil,
      modifiedAt: modifiedAt,
      baseContentHash: nil,
      operationID: operation(counter),
      state: state
    )
    guard case .noteBodyTextDeletedAnchored(let change) = batchChange else {
      throw TestError.unexpectedChange
    }
    return .deletion(change)
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
    case unexpectedChange
    case missingInsertedRecord
  }
}
