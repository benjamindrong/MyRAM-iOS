import AnchoredSequenceCore
import Foundation
import XCTest

@testable import MyRAMMac

final class SyncBatchAnchoredRecoveryTests: XCTestCase {
  private let noteID = UUID(
    uuidString: "17720000-0000-0000-0000-000000000001"
  )!
  private let deviceID = UUID(
    uuidString: "17720000-0000-0000-0000-000000000002"
  )!
  private let modifiedAt = Date(timeIntervalSince1970: 1_772)

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

  private enum TestError: Error {
    case unexpectedChange
  }
}
