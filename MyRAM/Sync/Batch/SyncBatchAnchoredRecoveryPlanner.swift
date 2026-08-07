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
    case .bootstrap:
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
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
    try planInitialDelivery(
      change: change,
      foundation: .established(sequenceState),
      recoverySnapshot: recoverySnapshot
    )
  }

  static func planInitialDelivery(
    change: SyncBatchAnchoredRecoveryChange,
    foundation: SyncBatchAnchoredStructuralFoundation,
    recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot
  ) throws -> SyncBatchAnchoredRecoveryCommitPlan {
    try requireFoundationIfNeeded(change: change, foundation: foundation)
    try requireUsable(recoverySnapshot)

    let key = change.recordKey
    let existing = recoverySnapshot.record(for: key)
    if let existing, existing.change != change {
      if existing.lifecycle.isWaiting {
        return try terminalIdentityCollisionPlan(
          existingRecord: existing,
          foundation: foundation
        )
      }
      throw SyncBatchAnchoredRecoveryPlannerError.identityCollision(key)
    }
    if let existing, existing.lifecycle.isTerminal {
      return emptyPlan(
        noteID: change.noteID,
        foundation: foundation
      )
    }

    let originalRecords = recordsByKey(
      recoverySnapshot.records.filter { $0.key.noteID == change.noteID }
    )
    var currentRecords = originalRecords
    var metrics = SyncBatchAnchoredRecoveryPlanningMetrics()
    var candidateFoundation = foundation
    var appliedRecordsByKey: [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord] =
      [:]
    var directlyExposedOperationIDs: Set<SyncOperationID> = []

    let outcome = try evaluate(
      change,
      against: foundation,
      allowsAppliedEquivalence: existing != nil,
      metrics: &metrics
    )

    switch outcome {
    case .applied(let finalFoundation, let exposesOperationID):
      candidateFoundation = finalFoundation
      if let existing {
        currentRecords.removeValue(forKey: key)
        appliedRecordsByKey[key] = existing
      }
      if exposesOperationID {
        directlyExposedOperationIDs.insert(change.operationID)
      }

    case .waiting(let dependency):
      let replacement = try SyncBatchAnchoredRecoveryRecord(
        change: change,
        lifecycle: .waiting(dependency)
      )
      currentRecords[key] = replacement

    case .terminal(let failure):
      let replacement = try SyncBatchAnchoredRecoveryRecord(
        change: change,
        lifecycle: .terminalStructuralFailure(failure)
      )
      currentRecords[key] = replacement

    case .bootstrapConflict(let conflict):
      let replacement = try SyncBatchAnchoredRecoveryRecord(
        change: change,
        lifecycle: .bootstrapContentConflict(conflict)
      )
      currentRecords[key] = replacement
    }

    let chainedExposedOperationIDs: Set<SyncOperationID>
    if directlyExposedOperationIDs.isEmpty {
      chainedExposedOperationIDs = []
    } else {
      guard case .established(let candidateState) = candidateFoundation else {
        preconditionFailure("An exposed structural operation requires an established foundation")
      }
      var mutableCandidateState = candidateState
      chainedExposedOperationIDs = try progressWaitingRecords(
        noteID: change.noteID,
        candidateState: &mutableCandidateState,
        currentRecords: &currentRecords,
        originalRecords: originalRecords,
        appliedRecordsByKey: &appliedRecordsByKey,
        seedOperationIDs: Array(directlyExposedOperationIDs),
        metrics: &metrics
      )
      candidateFoundation = .established(mutableCandidateState)
    }

    let transitions = collapsedTransitions(
      originalRecords: originalRecords,
      currentRecords: currentRecords
    )
    metrics.emittedTransitions = transitions.count

    let allExposed = directlyExposedOperationIDs.union(chainedExposedOperationIDs)
    return makePlan(
      noteID: change.noteID,
      initialFoundation: foundation,
      finalFoundation: candidateFoundation,
      appliedRecords: appliedRecordsByKey.values.sorted { $0.key < $1.key },
      recoveryStoreTransitions: transitions,
      structurallyAvailableOperationIDs: sortedOperationIDs(Array(allExposed)),
      metrics: metrics
    )
  }

  static func planRetry(
    noteID: SyncBatchNoteID,
    sequenceState: SyncTextSequenceState,
    recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot,
    trigger: SyncBatchAnchoredRecoveryRetryTrigger
  ) throws -> SyncBatchAnchoredRecoveryCommitPlan {
    try planRetry(
      noteID: noteID,
      foundation: .established(sequenceState),
      recoverySnapshot: recoverySnapshot,
      trigger: trigger
    )
  }

  static func planRetry(
    noteID: SyncBatchNoteID,
    foundation: SyncBatchAnchoredStructuralFoundation,
    recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot,
    trigger: SyncBatchAnchoredRecoveryRetryTrigger
  ) throws -> SyncBatchAnchoredRecoveryCommitPlan {
    guard case .established(let sequenceState) = foundation else {
      throw SyncBatchAnchoredDarkOrchestrationError.missingStructuralFoundation(noteID: noteID)
    }
    try requireUsable(recoverySnapshot)

    let originalRecords = recordsByKey(
      recoverySnapshot.records.filter { $0.key.noteID == noteID }
    )
    var currentRecords = originalRecords
    var candidateState = sequenceState
    var metrics = SyncBatchAnchoredRecoveryPlanningMetrics()
    var appliedRecordsByKey: [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord] =
      [:]
    let waitingIndex = makeWaitingIndex(records: currentRecords)
    let runOperationIDs = Set(sequenceState.runs.map(\.operationID))

    let seedOperationIDs: [SyncOperationID]
    switch trigger {
    case .newlyAvailable(let operationIDs):
      seedOperationIDs = sortedOperationIDs(
        operationIDs.filter { runOperationIDs.contains($0) }
      )
    case .restartRecovery:
      seedOperationIDs = sortedOperationIDs(
        waitingIndex.keys.filter { runOperationIDs.contains($0) }
      )
    }

    let exposedOperationIDs = try progressWaitingRecords(
      noteID: noteID,
      candidateState: &candidateState,
      currentRecords: &currentRecords,
      originalRecords: originalRecords,
      appliedRecordsByKey: &appliedRecordsByKey,
      seedOperationIDs: seedOperationIDs,
      metrics: &metrics
    )

    let finalFoundation = SyncBatchAnchoredStructuralFoundation.established(candidateState)
    let transitions = collapsedTransitions(
      originalRecords: originalRecords,
      currentRecords: currentRecords
    )
    metrics.emittedTransitions = transitions.count

    return makePlan(
      noteID: noteID,
      initialFoundation: foundation,
      finalFoundation: finalFoundation,
      appliedRecords: appliedRecordsByKey.values.sorted { $0.key < $1.key },
      recoveryStoreTransitions: transitions,
      structurallyAvailableOperationIDs: sortedOperationIDs(Array(exposedOperationIDs)),
      metrics: metrics
    )
  }

  private enum EvaluationOutcome {
    case applied(SyncBatchAnchoredStructuralFoundation, exposesOperationID: Bool)
    case waiting(SyncBatchAnchoredMissingDependency)
    case terminal(SyncBatchAnchoredStructuralFailure)
    case bootstrapConflict(SyncBatchAnchoredBootstrapConflict)
  }

  private static func evaluate(
    _ change: SyncBatchAnchoredRecoveryChange,
    against foundation: SyncBatchAnchoredStructuralFoundation,
    allowsAppliedEquivalence: Bool,
    metrics: inout SyncBatchAnchoredRecoveryPlanningMetrics
  ) throws -> EvaluationOutcome {
    switch change {
    case .bootstrap(let bootstrap):
      let descriptor = try bootstrap.makeDescriptor()
      switch foundation {
      case .absent:
        return .applied(
          .established(descriptor.state),
          exposesOperationID: !descriptor.state.runs.isEmpty
        )
      case .established(let state):
        guard state != descriptor.state else {
          return .applied(
            foundation,
            exposesOperationID: !descriptor.state.runs.isEmpty
          )
        }
        return .bootstrapConflict(
          SyncBatchAnchoredBootstrapConflict(establishedState: state)
        )
      }

    case .insertion, .deletion:
      guard case .established(let state) = foundation else {
        throw SyncBatchAnchoredDarkOrchestrationError.missingStructuralFoundation(
          noteID: change.noteID
        )
      }

      if allowsAppliedEquivalence {
        metrics.appliedEquivalentChecks += 1
        if case .insertion(let insertion) = change,
          let existingRun = state.runs.first(where: {
            $0.operationID == insertion.payload.operationID
          })
        {
          if insertionIsAppliedEquivalent(insertion, existingRun: existingRun) {
            return .applied(foundation, exposesOperationID: true)
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
        case .bootstrap:
          preconditionFailure("Bootstrap evaluation is handled before replay")
        case .insertion:
          exposesOperationID = true
        case .deletion:
          exposesOperationID = false
        }
        return .applied(
          .established(result),
          exposesOperationID: exposesOperationID
        )
      } catch let error as SyncTextSequenceStateError {
        switch SyncBatchAnchoredRecoveryErrorClassification(error) {
        case .waiting(let dependency):
          return .waiting(dependency)
        case .terminal(let failure):
          return .terminal(failure)
        }
      }
    }
  }

  private static func progressWaitingRecords(
    noteID: SyncBatchNoteID,
    candidateState: inout SyncTextSequenceState,
    currentRecords: inout [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord],
    originalRecords: [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord],
    appliedRecordsByKey: inout [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord],
    seedOperationIDs: [SyncOperationID],
    metrics: inout SyncBatchAnchoredRecoveryPlanningMetrics
  ) throws -> Set<SyncOperationID> {
    var waitingIndex = makeWaitingIndex(records: currentRecords)
    let representedRunIDs = Set(candidateState.runs.map(\.operationID))
    var worklist = sortedOperationIDs(
      seedOperationIDs.filter { representedRunIDs.contains($0) }
    )
    var enqueued = Set(worklist)
    var exposedOperationIDs: Set<SyncOperationID> = []
    var cursor = 0

    while cursor < worklist.count {
      let dependencyID = worklist[cursor]
      cursor += 1
      metrics.dequeuedDependencies += 1
      let selectedKeys = (waitingIndex[dependencyID] ?? []).sorted()
      metrics.selectedRecords += selectedKeys.count

      for key in selectedKeys {
        guard key.noteID == noteID,
          var record = currentRecords[key],
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
            against: .established(candidateState),
            allowsAppliedEquivalence: true,
            metrics: &metrics
          )
          switch outcome {
          case .applied(let finalFoundation, let exposesOperationID):
            guard case .established(let state) = finalFoundation else {
              preconditionFailure("Ordinary recovery cannot remove an established foundation")
            }
            candidateState = state
            currentRecords.removeValue(forKey: key)
            if let original = originalRecords[key] {
              appliedRecordsByKey[key] = original
            }
            if exposesOperationID {
              let operationID = record.change.operationID
              exposedOperationIDs.insert(operationID)
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

          case .bootstrapConflict:
            preconditionFailure("A waiting ordinary record cannot become a bootstrap conflict")
          }
          break
        }
      }
    }

    return exposedOperationIDs
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
    foundation: SyncBatchAnchoredStructuralFoundation
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
    return makePlan(
      noteID: existingRecord.key.noteID,
      initialFoundation: foundation,
      finalFoundation: foundation,
      appliedRecords: [],
      recoveryStoreTransitions: [
        .replace(expected: existingRecord, replacement: replacement)
      ],
      structurallyAvailableOperationIDs: [],
      metrics: metrics
    )
  }

  private static func requireFoundationIfNeeded(
    change: SyncBatchAnchoredRecoveryChange,
    foundation: SyncBatchAnchoredStructuralFoundation
  ) throws {
    guard case .bootstrap = change else {
      guard case .established = foundation else {
        throw SyncBatchAnchoredDarkOrchestrationError.missingStructuralFoundation(
          noteID: change.noteID
        )
      }
      return
    }
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
    foundation: SyncBatchAnchoredStructuralFoundation
  ) -> SyncBatchAnchoredRecoveryCommitPlan {
    makePlan(
      noteID: noteID,
      initialFoundation: foundation,
      finalFoundation: foundation,
      appliedRecords: [],
      recoveryStoreTransitions: [],
      structurallyAvailableOperationIDs: [],
      metrics: SyncBatchAnchoredRecoveryPlanningMetrics()
    )
  }

  private static func makePlan(
    noteID: SyncBatchNoteID,
    initialFoundation: SyncBatchAnchoredStructuralFoundation,
    finalFoundation: SyncBatchAnchoredStructuralFoundation,
    appliedRecords: [SyncBatchAnchoredRecoveryRecord],
    recoveryStoreTransitions: [SyncBatchAnchoredRecoveryStoreTransition],
    structurallyAvailableOperationIDs: [SyncOperationID],
    metrics: SyncBatchAnchoredRecoveryPlanningMetrics
  ) -> SyncBatchAnchoredRecoveryCommitPlan {
    SyncBatchAnchoredRecoveryCommitPlan(
      noteID: noteID,
      initialFoundation: initialFoundation,
      finalFoundation: finalFoundation,
      appliedRecords: appliedRecords,
      recoveryStoreTransitions: recoveryStoreTransitions,
      structurallyAvailableOperationIDs: structurallyAvailableOperationIDs,
      didChangeApplicationState: initialFoundation != finalFoundation,
      metrics: metrics
    )
  }

  private static func recordsByKey(
    _ records: [SyncBatchAnchoredRecoveryRecord]
  ) -> [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord] {
    Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
  }

  private static func makeWaitingIndex(
    records: [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord]
  ) -> [SyncOperationID: [SyncBatchAnchoredRecoveryRecordKey]] {
    var result: [SyncOperationID: [SyncBatchAnchoredRecoveryRecordKey]] = [:]
    for record in records.values {
      guard case .waiting(let dependency) = record.lifecycle else { continue }
      result[dependency.operationID, default: []].append(record.key)
    }
    for operationID in Array(result.keys) {
      result[operationID]?.sort()
    }
    return result
  }

  private static func collapsedTransitions(
    originalRecords: [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord],
    currentRecords: [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord]
  ) -> [SyncBatchAnchoredRecoveryStoreTransition] {
    let keys = Set(originalRecords.keys).union(currentRecords.keys).sorted()
    var transitions: [SyncBatchAnchoredRecoveryStoreTransition] = []
    for key in keys {
      switch (originalRecords[key], currentRecords[key]) {
      case (nil, let current?):
        transitions.append(.insertExpectedAbsent(current))
      case (let original?, nil):
        transitions.append(.removeCommitted(expected: original))
      case (let original?, let current?) where original != current:
        transitions.append(.replace(expected: original, replacement: current))
      default:
        break
      }
    }
    return transitions
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
