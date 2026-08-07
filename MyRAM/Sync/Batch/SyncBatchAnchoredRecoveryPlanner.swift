import AnchoredSequenceCore
import Foundation

enum SyncBatchAnchoredRecoveryPlannerError: Error, Equatable {
  case unhealthyRecoveryStore
  case identityCollision(SyncBatchAnchoredRecoveryRecordKey)
  case cyclicReindex(SyncBatchAnchoredRecoveryRecordKey)
}

enum SyncBatchAnchoredRecoveryRetryTrigger: Equatable, Sendable {
  case newlyAvailable([SyncOperationID])
  case restartRecovery
}

enum SyncBatchAnchoredRecoveryReplay {
  static func apply(
    _ change: SyncBatchAnchoredRecoveryChange,
    to state: SyncTextSequenceState
  ) throws -> SyncTextSequenceState {
    switch change {
    case .insertion(let change):
      try SyncBatchAnchoredInsertReplay.applying(
        change,
        to: state
      ).sequenceState
    case .deletion(let change):
      try SyncBatchAnchoredDeleteReplay.applying(
        change,
        to: state
      ).sequenceState
    }
  }
}

enum SyncBatchAnchoredRecoveryPlanner {
  static func planInitialDelivery(
    change: SyncBatchAnchoredRecoveryChange,
    sequenceState: SyncTextSequenceState,
    recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot
  ) throws -> SyncBatchAnchoredRecoveryCommitPlan {
    try requireUsable(recoverySnapshot)
    let key = change.recordKey
    let existing = recoverySnapshot.record(for: key)
    if let existing, existing.change != change {
      if existing.lifecycle.isWaiting {
        return try terminalIdentityCollisionPlan(
          existingRecord: existing,
          sequenceState: sequenceState
        )
      }
      throw SyncBatchAnchoredRecoveryPlannerError.identityCollision(key)
    }
    if let existing, existing.lifecycle.isTerminal {
      return emptyPlan(
        noteID: change.noteID,
        sequenceState: sequenceState
      )
    }

    var metrics = SyncBatchAnchoredRecoveryPlanningMetrics()
    let outcome = try evaluate(
      change,
      against: sequenceState,
      allowsAppliedEquivalence: existing != nil,
      metrics: &metrics
    )
    let transition: SyncBatchAnchoredRecoveryStoreTransition?
    let finalState: SyncTextSequenceState
    var appliedRecords: [SyncBatchAnchoredRecoveryRecord] = []
    var available: [SyncOperationID] = []

    switch outcome {
    case .applied(let state, let exposesOperationID):
      finalState = state
      if let existing {
        transition = .removeCommitted(expected: existing)
        appliedRecords = [existing]
      } else {
        transition = nil
      }
      if exposesOperationID {
        available = [change.operationID]
      }

    case .waiting(let dependency):
      finalState = sequenceState
      let replacement = try SyncBatchAnchoredRecoveryRecord(
        change: change,
        lifecycle: .waiting(dependency)
      )
      if let existing {
        transition =
          existing == replacement
          ? nil
          : .replace(expected: existing, replacement: replacement)
      } else {
        transition = .insertExpectedAbsent(replacement)
      }

    case .terminal(let failure):
      finalState = sequenceState
      let replacement = try SyncBatchAnchoredRecoveryRecord(
        change: change,
        lifecycle: .terminalStructuralFailure(failure)
      )
      if let existing {
        transition =
          existing == replacement
          ? nil
          : .replace(expected: existing, replacement: replacement)
      } else {
        transition = .insertExpectedAbsent(replacement)
      }
    }

    let transitions = transition.map { [$0] } ?? []
    metrics.emittedTransitions = transitions.count
    return SyncBatchAnchoredRecoveryCommitPlan(
      noteID: change.noteID,
      initialSequenceState: sequenceState,
      finalSequenceState: finalState,
      appliedRecords: appliedRecords,
      recoveryStoreTransitions: transitions,
      structurallyAvailableOperationIDs: sortedOperationIDs(available),
      didChangeApplicationState: finalState != sequenceState,
      metrics: metrics
    )
  }

  static func planRetry(
    noteID: SyncBatchNoteID,
    sequenceState: SyncTextSequenceState,
    recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot,
    trigger: SyncBatchAnchoredRecoveryRetryTrigger
  ) throws -> SyncBatchAnchoredRecoveryCommitPlan {
    try requireUsable(recoverySnapshot)
    let originalRecords = Dictionary(
      uniqueKeysWithValues: recoverySnapshot.records
        .filter { $0.key.noteID == noteID }
        .map { ($0.key, $0) }
    )
    var currentRecords = originalRecords
    var waitingIndex = recoverySnapshot.waitingIndex(noteID: noteID)
    var candidateState = sequenceState
    var metrics = SyncBatchAnchoredRecoveryPlanningMetrics()
    var appliedRecordsByKey: [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord] =
      [:]
    var availableOperationIDs: Set<SyncOperationID> = []

    let runOperationIDs = Set(sequenceState.runs.map(\.operationID))
    var worklist: [SyncOperationID]
    switch trigger {
    case .newlyAvailable(let operationIDs):
      worklist = sortedOperationIDs(
        operationIDs.filter { runOperationIDs.contains($0) }
      )
    case .restartRecovery:
      worklist = sortedOperationIDs(
        waitingIndex.keys.filter { runOperationIDs.contains($0) }
      )
    }
    var enqueued = Set(worklist)
    var cursor = 0

    while cursor < worklist.count {
      let dependencyID = worklist[cursor]
      cursor += 1
      metrics.dequeuedDependencies += 1
      let selectedKeys = (waitingIndex[dependencyID] ?? []).sorted()
      metrics.selectedRecords += selectedKeys.count

      for key in selectedKeys {
        guard var record = currentRecords[key],
          case .waiting(let currentDependency) = record.lifecycle,
          currentDependency.operationID == dependencyID
        else {
          continue
        }

        remove(key, waitingOn: currentDependency, from: &waitingIndex)
        var visitedDependencies: Set<SyncOperationID> = []

        while true {
          let outcome = try evaluate(
            record.change,
            against: candidateState,
            allowsAppliedEquivalence: true,
            metrics: &metrics
          )
          switch outcome {
          case .applied(let state, let exposesOperationID):
            candidateState = state
            currentRecords.removeValue(forKey: key)
            appliedRecordsByKey[key] = originalRecords[key]
            if exposesOperationID {
              let operationID = record.change.operationID
              availableOperationIDs.insert(operationID)
              if enqueued.insert(operationID).inserted {
                insertSorted(operationID, into: &worklist, after: cursor)
              }
            }

          case .terminal(let failure):
            record = try SyncBatchAnchoredRecoveryRecord(
              key: record.key,
              change: record.change,
              lifecycle: .terminalStructuralFailure(failure)
            )
            currentRecords[key] = record

          case .waiting(let dependency):
            guard visitedDependencies.insert(dependency.operationID).inserted else {
              throw SyncBatchAnchoredRecoveryPlannerError.cyclicReindex(key)
            }
            record = try SyncBatchAnchoredRecoveryRecord(
              key: record.key,
              change: record.change,
              lifecycle: .waiting(dependency)
            )
            currentRecords[key] = record
            if candidateState.runs.contains(where: {
              $0.operationID == dependency.operationID
            }) {
              continue
            }
            waitingIndex[dependency.operationID, default: []].append(key)
            waitingIndex[dependency.operationID]?.sort()
          }
          break
        }
      }
    }

    var transitions: [SyncBatchAnchoredRecoveryStoreTransition] = []
    for key in originalRecords.keys.sorted() {
      guard let original = originalRecords[key] else { continue }
      if let current = currentRecords[key] {
        if current != original {
          transitions.append(
            .replace(expected: original, replacement: current)
          )
        }
      } else {
        transitions.append(.removeCommitted(expected: original))
      }
    }
    metrics.emittedTransitions = transitions.count

    return SyncBatchAnchoredRecoveryCommitPlan(
      noteID: noteID,
      initialSequenceState: sequenceState,
      finalSequenceState: candidateState,
      appliedRecords: appliedRecordsByKey.values.sorted { $0.key < $1.key },
      recoveryStoreTransitions: transitions,
      structurallyAvailableOperationIDs: sortedOperationIDs(
        Array(availableOperationIDs)
      ),
      didChangeApplicationState: candidateState != sequenceState,
      metrics: metrics
    )
  }

  private enum EvaluationOutcome {
    case applied(SyncTextSequenceState, exposesOperationID: Bool)
    case waiting(SyncBatchAnchoredMissingDependency)
    case terminal(SyncBatchAnchoredStructuralFailure)
  }

  private static func evaluate(
    _ change: SyncBatchAnchoredRecoveryChange,
    against state: SyncTextSequenceState,
    allowsAppliedEquivalence: Bool,
    metrics: inout SyncBatchAnchoredRecoveryPlanningMetrics
  ) throws -> EvaluationOutcome {
    if allowsAppliedEquivalence {
      metrics.appliedEquivalentChecks += 1
      if case .insertion(let insertion) = change,
        let existingRun = state.runs.first(where: {
          $0.operationID == insertion.payload.operationID
        })
      {
        if insertionIsAppliedEquivalent(insertion, existingRun: existingRun) {
          return .applied(state, exposesOperationID: true)
        }
        return .terminal(
          .identityCollision(operationID: insertion.payload.operationID)
        )
      }
    }

    do {
      metrics.replayAttempts += 1
      let result = try SyncBatchAnchoredRecoveryReplay.apply(change, to: state)
      let exposesOperationID: Bool
      switch change {
      case .insertion:
        exposesOperationID = true
      case .deletion:
        exposesOperationID = false
      }
      return .applied(result, exposesOperationID: exposesOperationID)
    } catch let error as SyncTextSequenceStateError {
      switch SyncBatchAnchoredRecoveryErrorClassification(error) {
      case .waiting(let dependency):
        return .waiting(dependency)
      case .terminal(let failure):
        return .terminal(failure)
      }
    }
  }

  private static func insertionIsAppliedEquivalent(
    _ change: SyncBatchNoteBodyTextInsertedAnchoredChange,
    existingRun: SyncTextSequenceRun
  ) -> Bool {
    let expectedEndpoints:
      (
        left: SyncTextElementID?,
        right: SyncTextElementID?
      )
    switch change.payload.anchor.kind {
    case .empty:
      expectedEndpoints = (nil, nil)
    case .before:
      expectedEndpoints = (nil, change.payload.anchor.rightElementID)
    case .between:
      expectedEndpoints = (
        change.payload.anchor.leftElementID,
        change.payload.anchor.rightElementID
      )
    case .after:
      expectedEndpoints = (change.payload.anchor.leftElementID, nil)
    }
    return existingRun.origin.leftElementID == expectedEndpoints.left
      && existingRun.origin.rightElementID == expectedEndpoints.right
      && existingRun.text == change.text
  }

  private static func terminalIdentityCollisionPlan(
    existingRecord: SyncBatchAnchoredRecoveryRecord,
    sequenceState: SyncTextSequenceState
  ) throws -> SyncBatchAnchoredRecoveryCommitPlan {
    let replacement = try SyncBatchAnchoredRecoveryRecord(
      key: existingRecord.key,
      change: existingRecord.change,
      lifecycle: .terminalStructuralFailure(
        .identityCollision(operationID: existingRecord.key.operationID)
      )
    )
    var metrics = SyncBatchAnchoredRecoveryPlanningMetrics()
    metrics.emittedTransitions = 1
    return SyncBatchAnchoredRecoveryCommitPlan(
      noteID: existingRecord.key.noteID,
      initialSequenceState: sequenceState,
      finalSequenceState: sequenceState,
      appliedRecords: [],
      recoveryStoreTransitions: [
        .replace(expected: existingRecord, replacement: replacement)
      ],
      structurallyAvailableOperationIDs: [],
      didChangeApplicationState: false,
      metrics: metrics
    )
  }

  private static func requireUsable(
    _ snapshot: SyncBatchAnchoredRecoveryStoreSnapshot
  ) throws {
    guard snapshot.health.permitsOrdinaryMutation else {
      throw SyncBatchAnchoredRecoveryPlannerError.unhealthyRecoveryStore
    }
    var keys: Set<SyncBatchAnchoredRecoveryRecordKey> = []
    for record in snapshot.records {
      guard keys.insert(record.key).inserted else {
        throw SyncBatchAnchoredRecoveryPlannerError.identityCollision(record.key)
      }
    }
  }

  private static func emptyPlan(
    noteID: SyncBatchNoteID,
    sequenceState: SyncTextSequenceState
  ) -> SyncBatchAnchoredRecoveryCommitPlan {
    SyncBatchAnchoredRecoveryCommitPlan(
      noteID: noteID,
      initialSequenceState: sequenceState,
      finalSequenceState: sequenceState,
      appliedRecords: [],
      recoveryStoreTransitions: [],
      structurallyAvailableOperationIDs: [],
      didChangeApplicationState: false,
      metrics: SyncBatchAnchoredRecoveryPlanningMetrics()
    )
  }

  private static func remove(
    _ key: SyncBatchAnchoredRecoveryRecordKey,
    waitingOn dependency: SyncBatchAnchoredMissingDependency,
    from index: inout [SyncOperationID: [SyncBatchAnchoredRecoveryRecordKey]]
  ) {
    let operationID = dependency.operationID
    index[operationID]?.removeAll { $0 == key }
    if index[operationID]?.isEmpty == true {
      index.removeValue(forKey: operationID)
    }
  }

  private static func sortedOperationIDs(
    _ operationIDs: [SyncOperationID]
  ) -> [SyncOperationID] {
    Array(Set(operationIDs)).sorted {
      if $0 == $1 { return false }
      return SyncOperationIDCanonicalOrder.isOrderedBefore($0, $1)
    }
  }

  private static func insertSorted(
    _ operationID: SyncOperationID,
    into worklist: inout [SyncOperationID],
    after minimumIndex: Int
  ) {
    var insertionIndex = minimumIndex
    while insertionIndex < worklist.count,
      SyncOperationIDCanonicalOrder.isOrderedBefore(
        worklist[insertionIndex],
        operationID
      )
    {
      insertionIndex += 1
    }
    worklist.insert(operationID, at: insertionIndex)
  }
}
