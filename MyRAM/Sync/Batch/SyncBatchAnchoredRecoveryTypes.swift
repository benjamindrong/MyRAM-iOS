import AnchoredSequenceCore
import Foundation

enum SyncBatchAnchoredRecoveryCodingError: Error, Equatable {
  case unsupportedRecordShape
}

enum SyncBatchAnchoredDarkOrchestrationError: Error, Equatable {
  case missingStructuralFoundation(noteID: SyncBatchNoteID)
}

enum SyncBatchAnchoredStructuralFoundation: Equatable, Sendable {
  case absent
  case established(SyncTextSequenceState)

  var sequenceState: SyncTextSequenceState? {
    guard case .established(let state) = self else { return nil }
    return state
  }
}

struct SyncBatchAnchoredBootstrapChange: Equatable, Sendable {
  let noteID: SyncBatchNoteID
  let body: String
  let formatVersion: SyncTextLegacyBootstrapFormatVersion
  let operationID: SyncOperationID

  init(
    noteID: SyncBatchNoteID,
    body: String,
    formatVersion: SyncTextLegacyBootstrapFormatVersion = .v1
  ) throws {
    let descriptor = try SyncTextLegacyBootstrap.makeDescriptor(
      noteID: noteID,
      body: body,
      formatVersion: formatVersion
    )
    self.noteID = noteID
    self.body = body
    self.formatVersion = formatVersion
    self.operationID = descriptor.operationID
  }

  fileprivate init(
    validatingNoteID noteID: SyncBatchNoteID,
    body: String,
    formatVersion: SyncTextLegacyBootstrapFormatVersion,
    operationID: SyncOperationID
  ) throws {
    let descriptor = try SyncTextLegacyBootstrap.makeDescriptor(
      noteID: noteID,
      body: body,
      formatVersion: formatVersion
    )
    guard descriptor.operationID == operationID else {
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
    }
    self.noteID = noteID
    self.body = body
    self.formatVersion = formatVersion
    self.operationID = operationID
  }

  func makeDescriptor() throws -> SyncTextLegacyBootstrapDescriptor {
    let descriptor = try SyncTextLegacyBootstrap.makeDescriptor(
      noteID: noteID,
      body: body,
      formatVersion: formatVersion
    )
    guard descriptor.operationID == operationID else {
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
    }
    return descriptor
  }
}

extension SyncBatchAnchoredBootstrapChange: Codable {
  private enum CodingKeys: String, CodingKey {
    case noteID
    case body
    case formatVersion
    case operationID
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(noteID, forKey: .noteID)
    try container.encode(body, forKey: .body)
    try container.encode(formatVersion.rawValue, forKey: .formatVersion)
    try container.encode(operationID, forKey: .operationID)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawVersion = try container.decode(UInt32.self, forKey: .formatVersion)
    guard let formatVersion = SyncTextLegacyBootstrapFormatVersion(rawValue: rawVersion) else {
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
    }
    try self.init(
      validatingNoteID: container.decode(SyncBatchNoteID.self, forKey: .noteID),
      body: container.decode(String.self, forKey: .body),
      formatVersion: formatVersion,
      operationID: container.decode(SyncOperationID.self, forKey: .operationID)
    )
  }
}

struct SyncBatchAnchoredStructuralStateEvidence: Equatable, Sendable {
  struct Run: Codable, Equatable, Sendable {
    let operationID: SyncOperationID
    let leftElementID: SyncTextElementID?
    let rightElementID: SyncTextElementID?
    let text: String
  }

  enum FragmentVisibility: String, Codable, Equatable, Sendable {
    case visible
    case tombstone
  }

  struct Fragment: Codable, Equatable, Sendable {
    let operationID: SyncOperationID
    let startOffset: Int
    let utf16Length: Int
    let visibility: FragmentVisibility
  }

  let runs: [Run]
  let fragments: [Fragment]

  init(validating state: SyncTextSequenceState) {
    runs = state.runs.map {
      Run(
        operationID: $0.operationID,
        leftElementID: $0.origin.leftElementID,
        rightElementID: $0.origin.rightElementID,
        text: $0.text
      )
    }
    fragments = state.fragments.map {
      Fragment(
        operationID: $0.operationID,
        startOffset: $0.startOffset,
        utf16Length: $0.utf16Length,
        visibility: $0.visibility == .visible ? .visible : .tombstone
      )
    }
  }

  fileprivate init(runs: [Run], fragments: [Fragment]) {
    self.runs = runs
    self.fragments = fragments
  }

  var containsTombstones: Bool {
    fragments.contains { $0.visibility == .tombstone }
  }

  func makeValidatedSequenceState() throws -> SyncTextSequenceState {
    let reconstructedRuns = try runs.map { run in
      try SyncTextSequenceRun(
        operationID: run.operationID,
        origin: SyncTextInsertionOrigin(
          leftElementID: run.leftElementID,
          rightElementID: run.rightElementID
        ),
        text: run.text
      )
    }
    let reconstructedFragments = try fragments.map { fragment in
      try SyncTextSequenceFragment(
        operationID: fragment.operationID,
        startOffset: fragment.startOffset,
        utf16Length: fragment.utf16Length,
        visibility: fragment.visibility == .visible ? .visible : .tombstone
      )
    }
    return try SyncTextSequenceState(
      runs: reconstructedRuns,
      fragments: reconstructedFragments
    )
  }
}

extension SyncBatchAnchoredStructuralStateEvidence: Codable {
  private enum CodingKeys: String, CodingKey {
    case runs
    case fragments
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(runs, forKey: .runs)
    try container.encode(fragments, forKey: .fragments)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      runs: try container.decode([Run].self, forKey: .runs),
      fragments: try container.decode([Fragment].self, forKey: .fragments)
    )
    do {
      _ = try makeValidatedSequenceState()
    } catch {
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
    }
  }
}

enum SyncBatchAnchoredBootstrapConflictReason: String, Codable, Equatable, Sendable {
  case nonEquivalentEstablishedState
  case tombstoneHistory
}

struct SyncBatchAnchoredBootstrapConflict: Equatable, Sendable {
  let establishedState: SyncBatchAnchoredStructuralStateEvidence
  let reason: SyncBatchAnchoredBootstrapConflictReason

  init(establishedState: SyncTextSequenceState) {
    let evidence = SyncBatchAnchoredStructuralStateEvidence(validating: establishedState)
    self.establishedState = evidence
    self.reason = Self.reason(for: evidence)
  }

  fileprivate init(
    validating establishedState: SyncBatchAnchoredStructuralStateEvidence,
    reason: SyncBatchAnchoredBootstrapConflictReason
  ) throws {
    guard Self.reason(for: establishedState) == reason else {
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
    }
    self.establishedState = establishedState
    self.reason = reason
  }

  private static func reason(
    for evidence: SyncBatchAnchoredStructuralStateEvidence
  ) -> SyncBatchAnchoredBootstrapConflictReason {
    evidence.containsTombstones
      ? .tombstoneHistory
      : .nonEquivalentEstablishedState
  }
}

extension SyncBatchAnchoredBootstrapConflict: Codable {
  private enum CodingKeys: String, CodingKey {
    case establishedState
    case reason
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(establishedState, forKey: .establishedState)
    try container.encode(reason, forKey: .reason)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      validating: container.decode(
        SyncBatchAnchoredStructuralStateEvidence.self,
        forKey: .establishedState
      ),
      reason: container.decode(
        SyncBatchAnchoredBootstrapConflictReason.self,
        forKey: .reason
      )
    )
  }
}

struct SyncBatchAnchoredRecoveryRecordKey:
  Codable,
  Equatable,
  Hashable,
  Comparable,
  Sendable
{
  let noteID: SyncBatchNoteID
  let operationID: SyncOperationID

  static func < (
    lhs: SyncBatchAnchoredRecoveryRecordKey,
    rhs: SyncBatchAnchoredRecoveryRecordKey
  ) -> Bool {
    let lhsNoteBytes = rawUUIDBytes(lhs.noteID)
    let rhsNoteBytes = rawUUIDBytes(rhs.noteID)
    if lhsNoteBytes != rhsNoteBytes {
      return lhsNoteBytes.lexicographicallyPrecedes(rhsNoteBytes)
    }
    if lhs.operationID == rhs.operationID {
      return false
    }
    return SyncOperationIDCanonicalOrder.isOrderedBefore(
      lhs.operationID,
      rhs.operationID
    )
  }

  private static func rawUUIDBytes(_ uuid: UUID) -> [UInt8] {
    var value = uuid.uuid
    return withUnsafeBytes(of: &value) { Array($0) }
  }
}

enum SyncBatchAnchoredRecoveryChange: Equatable, Sendable {
  case bootstrap(SyncBatchAnchoredBootstrapChange)
  case insertion(SyncBatchNoteBodyTextInsertedAnchoredChange)
  case deletion(SyncBatchNoteBodyTextDeletedAnchoredChange)

  var noteID: SyncBatchNoteID {
    switch self {
    case .bootstrap(let change): change.noteID
    case .insertion(let change): change.noteID
    case .deletion(let change): change.noteID
    }
  }

  var operationID: SyncOperationID {
    switch self {
    case .bootstrap(let change): change.operationID
    case .insertion(let change): change.payload.operationID
    case .deletion(let change): change.payload.operationID
    }
  }

  var recordKey: SyncBatchAnchoredRecoveryRecordKey {
    SyncBatchAnchoredRecoveryRecordKey(
      noteID: noteID,
      operationID: operationID
    )
  }
}

extension SyncBatchAnchoredRecoveryChange: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case bootstrap
    case insertion
    case deletion
  }

  private enum Kind: String, Codable {
    case bootstrap
    case insertion
    case deletion
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .bootstrap(let change):
      try container.encode(Kind.bootstrap, forKey: .kind)
      try container.encode(change, forKey: .bootstrap)
    case .insertion(let change):
      try container.encode(Kind.insertion, forKey: .kind)
      try container.encode(change, forKey: .insertion)
    case .deletion(let change):
      try container.encode(Kind.deletion, forKey: .kind)
      try container.encode(change, forKey: .deletion)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawKind = try container.decode(String.self, forKey: .kind)
    guard let kind = Kind(rawValue: rawKind) else {
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
    }
    switch kind {
    case .bootstrap:
      guard container.contains(.bootstrap),
        !container.contains(.insertion),
        !container.contains(.deletion)
      else {
        throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
      }
      self = .bootstrap(
        try container.decode(SyncBatchAnchoredBootstrapChange.self, forKey: .bootstrap)
      )
    case .insertion:
      guard container.contains(.insertion),
        !container.contains(.bootstrap),
        !container.contains(.deletion)
      else {
        throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
      }
      self = .insertion(
        try container.decode(
          SyncBatchNoteBodyTextInsertedAnchoredChange.self,
          forKey: .insertion
        )
      )
    case .deletion:
      guard container.contains(.deletion),
        !container.contains(.bootstrap),
        !container.contains(.insertion)
      else {
        throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
      }
      self = .deletion(
        try container.decode(
          SyncBatchNoteBodyTextDeletedAnchoredChange.self,
          forKey: .deletion
        )
      )
    }
  }
}

enum SyncBatchAnchoredMissingDependency: Equatable, Hashable, Sendable {
  case insertionAnchor(SyncTextElementID)
  case deletionTarget(SyncOperationID)

  var operationID: SyncOperationID {
    switch self {
    case .insertionAnchor(let elementID): elementID.operationID
    case .deletionTarget(let operationID): operationID
    }
  }
}

extension SyncBatchAnchoredMissingDependency: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case elementID
    case operationID
  }

  private enum Kind: String {
    case insertionAnchor
    case deletionTarget
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .insertionAnchor(let elementID):
      try container.encode(Kind.insertionAnchor.rawValue, forKey: .kind)
      try container.encode(elementID, forKey: .elementID)
    case .deletionTarget(let operationID):
      try container.encode(Kind.deletionTarget.rawValue, forKey: .kind)
      try container.encode(operationID, forKey: .operationID)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawKind = try container.decode(String.self, forKey: .kind)
    guard let kind = Kind(rawValue: rawKind) else {
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
    }
    switch kind {
    case .insertionAnchor:
      guard container.contains(.elementID), !container.contains(.operationID) else {
        throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
      }
      self = .insertionAnchor(
        try container.decode(SyncTextElementID.self, forKey: .elementID)
      )
    case .deletionTarget:
      guard container.contains(.operationID), !container.contains(.elementID) else {
        throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
      }
      self = .deletionTarget(
        try container.decode(SyncOperationID.self, forKey: .operationID)
      )
    }
  }
}

struct SyncBatchAnchoredStructuralFailure: Codable, Equatable, Sendable {
  enum Code: String, Equatable, Sendable {
    case identityCollision
    case identicalOriginEndpoints
    case emptyRunText
    case negativeRangeOffset
    case nonpositiveRangeLength
    case rangeOverflow
    case duplicateRun
    case anchorElementOutOfBounds
    case betweenAnchorEndpointsReversed
    case anchorGapNotDurable
    case deleteTargetRangeExceedsRun
    case deleteTargetSplitsSurrogatePair
    case noncanonicalRunOrder
    case noncanonicalSiblingOrder
    case unknownOrigin
    case selfOrigin
    case originSplitsSurrogatePair
    case cyclicOriginDependency
    case unreachableOriginGap
    case duplicateStructuralReachability
    case fragmentReferencesUnknownRun
    case fragmentRangeExceedsRun
    case fragmentSplitsSurrogatePair
    case fragmentOrderNotMatchingOrigins
    case mergeableAdjacentFragments
    case countOverflow
    case visibleOffsetOutOfBounds
    case visibleOffsetSplitsSurrogatePair
    case invalidVisibleRange
    case visibleRangeSplitsSurrogatePair
  }

  struct Evidence: Codable, Equatable, Sendable {
    let elementID: SyncTextElementID?
    let operationID: SyncOperationID?
    let span: SyncTextElementIDSpan?
    let offset: Int?
    let startOffset: Int?
    let utf16Length: Int?
    let previousOperationID: SyncOperationID?
    let currentOperationID: SyncOperationID?
    let leftElementID: SyncTextElementID?
    let rightElementID: SyncTextElementID?
    let range: Range<Int>?

    init(
      elementID: SyncTextElementID? = nil,
      operationID: SyncOperationID? = nil,
      span: SyncTextElementIDSpan? = nil,
      offset: Int? = nil,
      startOffset: Int? = nil,
      utf16Length: Int? = nil,
      previousOperationID: SyncOperationID? = nil,
      currentOperationID: SyncOperationID? = nil,
      leftElementID: SyncTextElementID? = nil,
      rightElementID: SyncTextElementID? = nil,
      range: Range<Int>? = nil
    ) {
      self.elementID = elementID
      self.operationID = operationID
      self.span = span
      self.offset = offset
      self.startOffset = startOffset
      self.utf16Length = utf16Length
      self.previousOperationID = previousOperationID
      self.currentOperationID = currentOperationID
      self.leftElementID = leftElementID
      self.rightElementID = rightElementID
      self.range = range
    }
  }

  let code: Code
  let evidence: Evidence

  init(code: Code, evidence: Evidence = Evidence()) throws {
    guard Self.hasRequiredEvidence(code: code, evidence: evidence) else {
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
    }
    self.init(validatedCode: code, evidence: evidence)
  }

  fileprivate init(validatedCode code: Code, evidence: Evidence = Evidence()) {
    self.code = code
    self.evidence = evidence
  }

  private enum CodingKeys: String, CodingKey {
    case code
    case evidence
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(code.rawValue, forKey: .code)
    try container.encode(evidence, forKey: .evidence)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawCode = try container.decode(String.self, forKey: .code)
    guard let code = Code(rawValue: rawCode) else {
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
    }
    let evidence = try container.decode(Evidence.self, forKey: .evidence)
    try self.init(code: code, evidence: evidence)
  }

  static func identityCollision(
    operationID: SyncOperationID
  ) -> SyncBatchAnchoredStructuralFailure {
    SyncBatchAnchoredStructuralFailure(
      validatedCode: .identityCollision,
      evidence: Evidence(operationID: operationID)
    )
  }

  private enum EvidenceField: Hashable {
    case elementID
    case operationID
    case span
    case offset
    case startOffset
    case utf16Length
    case previousOperationID
    case currentOperationID
    case leftElementID
    case rightElementID
    case range
  }

  private static func hasRequiredEvidence(
    code: Code,
    evidence: Evidence
  ) -> Bool {
    let populated = populatedFields(in: evidence)
    let allowed: Set<EvidenceField>
    let required: Set<EvidenceField>

    switch code {
    case .identityCollision, .emptyRunText, .duplicateRun, .selfOrigin,
      .unreachableOriginGap, .duplicateStructuralReachability,
      .fragmentReferencesUnknownRun, .fragmentRangeExceedsRun,
      .mergeableAdjacentFragments:
      allowed = [.operationID]
      required = [.operationID]
    case .identicalOriginEndpoints, .anchorElementOutOfBounds,
      .unknownOrigin, .originSplitsSurrogatePair:
      allowed = [.elementID]
      required = [.elementID]
    case .negativeRangeOffset, .visibleOffsetOutOfBounds,
      .visibleOffsetSplitsSurrogatePair, .visibleRangeSplitsSurrogatePair:
      allowed = [.offset]
      required = [.offset]
    case .nonpositiveRangeLength:
      allowed = [.utf16Length]
      required = [.utf16Length]
    case .rangeOverflow:
      allowed = [.startOffset, .utf16Length]
      required = allowed
    case .betweenAnchorEndpointsReversed:
      allowed = [.leftElementID, .rightElementID]
      required = allowed
    case .anchorGapNotDurable:
      allowed = [.leftElementID, .rightElementID]
      required = []
    case .deleteTargetRangeExceedsRun:
      allowed = [.span]
      required = [.span]
    case .deleteTargetSplitsSurrogatePair:
      allowed = [.span, .offset]
      required = allowed
    case .noncanonicalRunOrder, .noncanonicalSiblingOrder:
      allowed = [.previousOperationID, .currentOperationID]
      required = allowed
    case .fragmentSplitsSurrogatePair:
      allowed = [.operationID, .offset]
      required = allowed
    case .invalidVisibleRange:
      allowed = [.range]
      required = [.range]
    case .cyclicOriginDependency, .fragmentOrderNotMatchingOrigins,
      .countOverflow:
      allowed = []
      required = []
    }

    return populated.isSubset(of: allowed) && required.isSubset(of: populated)
  }

  private static func populatedFields(
    in evidence: Evidence
  ) -> Set<EvidenceField> {
    var result: Set<EvidenceField> = []
    if evidence.elementID != nil { result.insert(.elementID) }
    if evidence.operationID != nil { result.insert(.operationID) }
    if evidence.span != nil { result.insert(.span) }
    if evidence.offset != nil { result.insert(.offset) }
    if evidence.startOffset != nil { result.insert(.startOffset) }
    if evidence.utf16Length != nil { result.insert(.utf16Length) }
    if evidence.previousOperationID != nil { result.insert(.previousOperationID) }
    if evidence.currentOperationID != nil { result.insert(.currentOperationID) }
    if evidence.leftElementID != nil { result.insert(.leftElementID) }
    if evidence.rightElementID != nil { result.insert(.rightElementID) }
    if evidence.range != nil { result.insert(.range) }
    return result
  }
}

enum SyncBatchAnchoredRecoveryErrorClassification: Equatable, Sendable {
  case waiting(SyncBatchAnchoredMissingDependency)
  case terminal(SyncBatchAnchoredStructuralFailure)

  init(_ error: SyncTextSequenceStateError) {
    switch error {
    case .missingAnchorDependency(let elementID):
      self = .waiting(.insertionAnchor(elementID))
    case .missingDeleteDependency(let operationID):
      self = .waiting(.deletionTarget(operationID))
    case .identicalOriginEndpoints(let elementID):
      self = .terminal(
        .init(validatedCode: .identicalOriginEndpoints, evidence: .init(elementID: elementID)))
    case .emptyRunText(let operationID):
      self = .terminal(
        .init(validatedCode: .emptyRunText, evidence: .init(operationID: operationID)))
    case .negativeRangeOffset(let offset):
      self = .terminal(.init(validatedCode: .negativeRangeOffset, evidence: .init(offset: offset)))
    case .nonpositiveRangeLength(let length):
      self = .terminal(
        .init(validatedCode: .nonpositiveRangeLength, evidence: .init(utf16Length: length)))
    case .rangeOverflow(let startOffset, let utf16Length):
      self = .terminal(
        .init(
          validatedCode: .rangeOverflow,
          evidence: .init(startOffset: startOffset, utf16Length: utf16Length)))
    case .duplicateRun(let operationID):
      self = .terminal(
        .init(validatedCode: .duplicateRun, evidence: .init(operationID: operationID)))
    case .anchorElementOutOfBounds(let elementID):
      self = .terminal(
        .init(validatedCode: .anchorElementOutOfBounds, evidence: .init(elementID: elementID)))
    case .betweenAnchorEndpointsReversed(let left, let right):
      self = .terminal(
        .init(
          validatedCode: .betweenAnchorEndpointsReversed,
          evidence: .init(leftElementID: left, rightElementID: right)))
    case .anchorGapNotDurable(let left, let right):
      self = .terminal(
        .init(
          validatedCode: .anchorGapNotDurable,
          evidence: .init(leftElementID: left, rightElementID: right)))
    case .deleteTargetRangeExceedsRun(let span):
      self = .terminal(
        .init(validatedCode: .deleteTargetRangeExceedsRun, evidence: .init(span: span)))
    case .deleteTargetSplitsSurrogatePair(let span, let offset):
      self = .terminal(
        .init(
          validatedCode: .deleteTargetSplitsSurrogatePair,
          evidence: .init(span: span, offset: offset)))
    case .noncanonicalRunOrder(let previous, let current):
      self = .terminal(
        .init(
          validatedCode: .noncanonicalRunOrder,
          evidence: .init(previousOperationID: previous, currentOperationID: current)))
    case .noncanonicalSiblingOrder(let previous, let current):
      self = .terminal(
        .init(
          validatedCode: .noncanonicalSiblingOrder,
          evidence: .init(previousOperationID: previous, currentOperationID: current)))
    case .unknownOrigin(let elementID):
      self = .terminal(.init(validatedCode: .unknownOrigin, evidence: .init(elementID: elementID)))
    case .selfOrigin(let operationID):
      self = .terminal(.init(validatedCode: .selfOrigin, evidence: .init(operationID: operationID)))
    case .originSplitsSurrogatePair(let elementID):
      self = .terminal(
        .init(validatedCode: .originSplitsSurrogatePair, evidence: .init(elementID: elementID)))
    case .cyclicOriginDependency:
      self = .terminal(.init(validatedCode: .cyclicOriginDependency))
    case .unreachableOriginGap(let operationID):
      self = .terminal(
        .init(validatedCode: .unreachableOriginGap, evidence: .init(operationID: operationID)))
    case .duplicateStructuralReachability(let operationID):
      self = .terminal(
        .init(
          validatedCode: .duplicateStructuralReachability,
          evidence: .init(operationID: operationID)
        ))
    case .fragmentReferencesUnknownRun(let operationID):
      self = .terminal(
        .init(
          validatedCode: .fragmentReferencesUnknownRun,
          evidence: .init(operationID: operationID)))
    case .fragmentRangeExceedsRun(let operationID):
      self = .terminal(
        .init(validatedCode: .fragmentRangeExceedsRun, evidence: .init(operationID: operationID)))
    case .fragmentSplitsSurrogatePair(let operationID, let offset):
      self = .terminal(
        .init(
          validatedCode: .fragmentSplitsSurrogatePair,
          evidence: .init(operationID: operationID, offset: offset)))
    case .fragmentOrderNotMatchingOrigins:
      self = .terminal(.init(validatedCode: .fragmentOrderNotMatchingOrigins))
    case .mergeableAdjacentFragments(let operationID):
      self = .terminal(
        .init(validatedCode: .mergeableAdjacentFragments, evidence: .init(operationID: operationID))
      )
    case .countOverflow:
      self = .terminal(.init(validatedCode: .countOverflow))
    case .visibleOffsetOutOfBounds(let offset):
      self = .terminal(
        .init(validatedCode: .visibleOffsetOutOfBounds, evidence: .init(offset: offset)))
    case .visibleOffsetSplitsSurrogatePair(let offset):
      self = .terminal(
        .init(validatedCode: .visibleOffsetSplitsSurrogatePair, evidence: .init(offset: offset)))
    case .invalidVisibleRange(let range):
      self = .terminal(.init(validatedCode: .invalidVisibleRange, evidence: .init(range: range)))
    case .visibleRangeSplitsSurrogatePair(let offset):
      self = .terminal(
        .init(validatedCode: .visibleRangeSplitsSurrogatePair, evidence: .init(offset: offset)))
    }
  }
}

enum SyncBatchAnchoredRecoveryLifecycle: Equatable, Sendable {
  case waiting(SyncBatchAnchoredMissingDependency)
  case terminalStructuralFailure(SyncBatchAnchoredStructuralFailure)
  case bootstrapContentConflict(SyncBatchAnchoredBootstrapConflict)

  var isWaiting: Bool {
    if case .waiting = self { return true }
    return false
  }

  var isTerminal: Bool {
    switch self {
    case .terminalStructuralFailure, .bootstrapContentConflict:
      true
    case .waiting:
      false
    }
  }
}

extension SyncBatchAnchoredRecoveryLifecycle: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case waiting
    case terminalStructuralFailure
    case bootstrapContentConflict
  }

  private enum Kind: String {
    case waiting
    case terminalStructuralFailure
    case bootstrapContentConflict
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .waiting(let dependency):
      try container.encode(Kind.waiting.rawValue, forKey: .kind)
      try container.encode(dependency, forKey: .waiting)
    case .terminalStructuralFailure(let failure):
      try container.encode(Kind.terminalStructuralFailure.rawValue, forKey: .kind)
      try container.encode(failure, forKey: .terminalStructuralFailure)
    case .bootstrapContentConflict(let conflict):
      try container.encode(Kind.bootstrapContentConflict.rawValue, forKey: .kind)
      try container.encode(conflict, forKey: .bootstrapContentConflict)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawKind = try container.decode(String.self, forKey: .kind)
    guard let kind = Kind(rawValue: rawKind) else {
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
    }
    switch kind {
    case .waiting:
      guard container.contains(.waiting),
        !container.contains(.terminalStructuralFailure),
        !container.contains(.bootstrapContentConflict)
      else {
        throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
      }
      self = .waiting(
        try container.decode(
          SyncBatchAnchoredMissingDependency.self,
          forKey: .waiting
        )
      )
    case .terminalStructuralFailure:
      guard container.contains(.terminalStructuralFailure),
        !container.contains(.waiting),
        !container.contains(.bootstrapContentConflict)
      else {
        throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
      }
      self = .terminalStructuralFailure(
        try container.decode(
          SyncBatchAnchoredStructuralFailure.self,
          forKey: .terminalStructuralFailure
        )
      )
    case .bootstrapContentConflict:
      guard container.contains(.bootstrapContentConflict),
        !container.contains(.waiting),
        !container.contains(.terminalStructuralFailure)
      else {
        throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
      }
      self = .bootstrapContentConflict(
        try container.decode(
          SyncBatchAnchoredBootstrapConflict.self,
          forKey: .bootstrapContentConflict
        )
      )
    }
  }
}

struct SyncBatchAnchoredRecoveryRecord: Codable, Equatable, Sendable {
  let key: SyncBatchAnchoredRecoveryRecordKey
  let change: SyncBatchAnchoredRecoveryChange
  let lifecycle: SyncBatchAnchoredRecoveryLifecycle

  init(
    key: SyncBatchAnchoredRecoveryRecordKey,
    change: SyncBatchAnchoredRecoveryChange,
    lifecycle: SyncBatchAnchoredRecoveryLifecycle
  ) throws {
    guard key == change.recordKey else {
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
    }
    switch (change, lifecycle) {
    case (.bootstrap, .bootstrapContentConflict),
      (.insertion, .waiting(.insertionAnchor)),
      (.deletion, .waiting(.deletionTarget)),
      (.insertion, .terminalStructuralFailure),
      (.deletion, .terminalStructuralFailure):
      break
    case (.bootstrap, .waiting),
      (.bootstrap, .terminalStructuralFailure),
      (.insertion, .waiting(.deletionTarget)),
      (.deletion, .waiting(.insertionAnchor)),
      (.insertion, .bootstrapContentConflict),
      (.deletion, .bootstrapContentConflict):
      throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
    }
    self.key = key
    self.change = change
    self.lifecycle = lifecycle
  }

  init(
    change: SyncBatchAnchoredRecoveryChange,
    lifecycle: SyncBatchAnchoredRecoveryLifecycle
  ) throws {
    try self.init(
      key: change.recordKey,
      change: change,
      lifecycle: lifecycle
    )
  }

  private enum CodingKeys: String, CodingKey {
    case key
    case change
    case lifecycle
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      key: container.decode(
        SyncBatchAnchoredRecoveryRecordKey.self,
        forKey: .key
      ),
      change: container.decode(
        SyncBatchAnchoredRecoveryChange.self,
        forKey: .change
      ),
      lifecycle: container.decode(
        SyncBatchAnchoredRecoveryLifecycle.self,
        forKey: .lifecycle
      )
    )
  }
}

enum SyncBatchAnchoredRecoveryStoreTransition: Equatable, Sendable {
  case insertExpectedAbsent(SyncBatchAnchoredRecoveryRecord)
  case replace(
    expected: SyncBatchAnchoredRecoveryRecord,
    replacement: SyncBatchAnchoredRecoveryRecord
  )
  case removeCommitted(expected: SyncBatchAnchoredRecoveryRecord)

  var key: SyncBatchAnchoredRecoveryRecordKey {
    switch self {
    case .insertExpectedAbsent(let record): record.key
    case .replace(let expected, _): expected.key
    case .removeCommitted(let expected): expected.key
    }
  }
}

struct SyncBatchAnchoredRecoveryPlanningMetrics: Equatable, Sendable {
  var dequeuedDependencies = 0
  var selectedRecords = 0
  var replayAttempts = 0
  var appliedEquivalentChecks = 0
  var emittedTransitions = 0
}

struct SyncBatchAnchoredRecoveryCommitPlan: Equatable, Sendable {
  let noteID: SyncBatchNoteID
  let initialFoundation: SyncBatchAnchoredStructuralFoundation
  let finalFoundation: SyncBatchAnchoredStructuralFoundation
  let appliedRecords: [SyncBatchAnchoredRecoveryRecord]
  let recoveryStoreTransitions: [SyncBatchAnchoredRecoveryStoreTransition]
  let structurallyAvailableOperationIDs: [SyncOperationID]
  let didChangeApplicationState: Bool
  let metrics: SyncBatchAnchoredRecoveryPlanningMetrics

  var initialSequenceState: SyncTextSequenceState {
    guard case .established(let state) = initialFoundation else {
      preconditionFailure("An absent structural foundation has no initial sequence state")
    }
    return state
  }

  var finalSequenceState: SyncTextSequenceState {
    guard case .established(let state) = finalFoundation else {
      preconditionFailure("An absent structural foundation has no final sequence state")
    }
    return state
  }

  var visibleText: String {
    finalSequenceState.visibleText
  }
}
