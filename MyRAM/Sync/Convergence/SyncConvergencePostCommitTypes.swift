import Foundation

@MainActor
protocol SyncConvergenceLocalBatchTransportAdapter: AnyObject {
    func acceptLocalBatch(_ batch: SyncBatch) async throws
}

enum SyncConvergenceLocalBatchTransportError: Error, Equatable {
    case unavailable
    case acceptanceNotDurable(batchID: UUID)
}

struct SyncConvergencePostCommitRequest: Equatable, Sendable {
    let sourceBatchID: UUID
    let affectedNoteIDs: Set<UUID>
    let cleanupPlan: SyncConvergenceCleanupPlan
    let presentationPlan: SyncConvergencePresentationPlan
    let persistedIncorporationIdentity: SyncConvergencePersistedIncorporationIdentity

    init(result: SyncConvergenceIncorporationResult) {
        self.sourceBatchID = result.batchID
        self.affectedNoteIDs = result.affectedNoteIDs
        self.cleanupPlan = result.cleanupPlan
        self.presentationPlan = result.presentationPlan
        self.persistedIncorporationIdentity = result.persistedIncorporationIdentity
    }

    init(
        sourceBatchID: UUID,
        affectedNoteIDs: Set<UUID>,
        cleanupPlan: SyncConvergenceCleanupPlan,
        presentationPlan: SyncConvergencePresentationPlan,
        persistedIncorporationIdentity: SyncConvergencePersistedIncorporationIdentity
    ) {
        self.sourceBatchID = sourceBatchID
        self.affectedNoteIDs = affectedNoteIDs
        self.cleanupPlan = cleanupPlan
        self.presentationPlan = presentationPlan
        self.persistedIncorporationIdentity = persistedIncorporationIdentity
    }
}

enum SyncConvergencePostCommitOutcome: Equatable, Sendable {
    case complete
    /// `blocking` identifies the gate that prevented this execution from finishing;
    /// `outstanding` retains every remaining gate for diagnostics and retries.
    case pending(
        blocking: SyncConvergencePostCommitPendingWork,
        outstanding: Set<SyncConvergencePostCommitPendingWork>
    )
    case failedBeforeWork(SyncConvergencePostCommitFailure)
}

enum SyncConvergencePostCommitPendingWork: Hashable, Sendable {
    case anchoredRecoveryPersistence
    case queueCleanup
    case legacyCleanup
    case presentationRefresh
    case postCommitStatePersistence
}

enum SyncConvergencePostCommitFailure: Error, Equatable, Sendable {
    case missingAuthoritativeIncorporation(batchID: UUID)
    case inconsistentIncorporationIdentity(batchID: UUID)
    case malformedPostCommitState(batchID: UUID)
    case contradictoryPostCommitIndex(batchID: UUID)
    case missingPostCommitWorkPayload(batchID: UUID)
    case malformedPostCommitWorkPayload(batchID: UUID)
    case contradictoryPostCommitWorkPayload(batchID: UUID)
    case missingLegacyCleanupAdapter(batchID: UUID)
    case persistence
    case unexpected
}

enum SyncConvergencePostCommitAdapterResult: Equatable, Sendable {
    case verifiedComplete
    case stillPending
    case failed
}

struct SyncConvergencePresentationRequest: Equatable, Sendable {
    let incorporationIdentity: SyncConvergencePersistedIncorporationIdentity
    let noteID: UUID
    let routing: SyncConvergencePresentationRouting
    let expectedPreBodyHash: String?
    let committedPostBodyHash: String
    let incrementalOperations: [SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload]
    let rewriteSafetyReceipt: SyncConvergenceRewriteSafetyReceipt?
    let committedNote: SyncConvergenceMutableNoteRecord
    let committedBodyHash: String
    let committedTitle: String

    init(
        incorporationIdentity: SyncConvergencePersistedIncorporationIdentity,
        noteID: UUID,
        routing: SyncConvergencePresentationRouting,
        expectedPreBodyHash: String?,
        committedPostBodyHash: String,
        incrementalOperations: [SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload],
        rewriteSafetyReceipt: SyncConvergenceRewriteSafetyReceipt? = nil,
        committedNote: SyncConvergenceMutableNoteRecord,
        committedBodyHash: String,
        committedTitle: String
    ) {
        self.incorporationIdentity = incorporationIdentity
        self.noteID = noteID
        self.routing = routing
        self.expectedPreBodyHash = expectedPreBodyHash
        self.committedPostBodyHash = committedPostBodyHash
        self.incrementalOperations = incrementalOperations
        self.rewriteSafetyReceipt = rewriteSafetyReceipt
        self.committedNote = committedNote
        self.committedBodyHash = committedBodyHash
        self.committedTitle = committedTitle
    }
}

enum SyncConvergencePostCommitLoadedState: Equatable {
    case fullRoot(SyncConvergencePostCommitFullRootState)
    case tombstone(SyncConvergenceIncorporatedTombstoneProjection)
    case missing
    case inconsistent
}

enum SyncConvergencePersistedPostCommitStatus: Equatable {
    case pending(SyncConvergencePostCommitRequest)
    case completed(SyncConvergencePersistedIncorporationIdentity)
    case tombstone(SyncConvergencePostCommitRequest)
    case missing
}

struct SyncConvergencePostCommitFullRootState: Equatable {
    let root: SyncConvergenceIncorporatedRootProjection
    let postCommitState: SyncConvergencePostCommitState
    let postCommitStatePayloadData: Data
    let postCommitWorkPayload: SyncConvergencePostCommitWorkPayloadV1?
    let postCommitWorkPayloadData: Data?
    let anchoredRecoveryTransitions: [SyncBatchAnchoredRecoveryStoreTransition]

    init(
        root: SyncConvergenceIncorporatedRootProjection,
        postCommitState: SyncConvergencePostCommitState,
        postCommitStatePayloadData: Data,
        postCommitWorkPayload: SyncConvergencePostCommitWorkPayloadV1?,
        postCommitWorkPayloadData: Data?,
        anchoredRecoveryTransitions: [SyncBatchAnchoredRecoveryStoreTransition] = []
    ) {
        self.root = root
        self.postCommitState = postCommitState
        self.postCommitStatePayloadData = postCommitStatePayloadData
        self.postCommitWorkPayload = postCommitWorkPayload
        self.postCommitWorkPayloadData = postCommitWorkPayloadData
        self.anchoredRecoveryTransitions = anchoredRecoveryTransitions
    }
}

protocol SyncConvergencePostCommitStateStore {
    func loadState(
        matching identity: SyncConvergencePersistedIncorporationIdentity
    ) throws -> SyncConvergencePostCommitLoadedState

    func loadCommittedNote(id: UUID) throws -> SyncConvergenceMutableNoteRecord?

    func compareAndSetPostCommitState(
        expectedRoot: SyncConvergencePostCommitRootSnapshot,
        expectedPayloadData: Data,
        newState: SyncConvergencePostCommitState
    ) throws -> SyncConvergencePostCommitFullRootState
}

protocol SyncConvergencePendingPostCommitSource {
    func loadPendingPostCommitRequests() throws -> [SyncConvergencePostCommitRequest]
    func loadPostCommitStatus(forBatchID batchID: UUID) throws -> SyncConvergencePersistedPostCommitStatus
}

protocol SyncConvergenceQueueCleanupAdapter {
    func removeBatches(withIDs ids: Set<SyncBatchID>) throws
    func containsBatch(withID id: SyncBatchID) throws -> Bool
}

protocol SyncConvergenceLegacyCleanupAdapter {
    func performLegacyCleanup(for request: SyncConvergencePostCommitRequest) async -> SyncConvergencePostCommitAdapterResult
}

protocol SyncConvergenceAnchoredRecoveryAdapter {
    func applyAnchoredRecoveryTransitions(
        _ transitions: [SyncBatchAnchoredRecoveryStoreTransition]
    ) -> SyncConvergencePostCommitAdapterResult
}

protocol SyncConvergencePresentationAdapter {
    func refreshPresentation(for request: SyncConvergencePresentationRequest) async -> SyncConvergencePostCommitAdapterResult
}

extension SyncConvergencePostCommitState {
    var hasPendingWork: Bool {
        self != .none
    }

    var pendingWork: Set<SyncConvergencePostCommitPendingWork> {
        var work: Set<SyncConvergencePostCommitPendingWork> = []
        if anchoredRecoveryPending {
            work.insert(.anchoredRecoveryPersistence)
        }
        if queueCleanupPending {
            work.insert(.queueCleanup)
        }
        if legacyCleanupPending {
            work.insert(.legacyCleanup)
        }
        if presentationRefreshPending {
            work.insert(.presentationRefresh)
        }
        return work
    }
}

struct SyncConvergencePostCommitRootSnapshot: Equatable, Sendable {
    let root: SyncConvergenceIncorporatedRootProjection
}

struct SyncConvergencePostCommitWorkPayloadV1: Codable, Equatable, Sendable {
    static let supportedFormatVersion = 1

    let formatVersion: Int
    let queueCleanupBatchIDs: [UUID]
    let legacyCleanupRequired: Bool
    let presentationEntries: [PresentationEntry]

    init(
        queueCleanupBatchIDs: Set<UUID>,
        legacyCleanupRequired: Bool,
        presentationEntries: [PresentationEntry]
    ) {
        self.formatVersion = Self.supportedFormatVersion
        self.queueCleanupBatchIDs = queueCleanupBatchIDs.sortedByUUIDString()
        self.legacyCleanupRequired = legacyCleanupRequired
        self.presentationEntries = presentationEntries.sorted { $0.noteID.uuidString < $1.noteID.uuidString }
    }

    func encodedPayloadData() throws -> Data {
        try validate()
        return try SyncConvergenceStableEncoding.encode(self)
    }

    static func decodePayloadData(_ data: Data) throws -> Self {
        let payload = try SyncConvergenceStableEncoding.decode(Self.self, from: data)
        try payload.validate()
        return payload
    }

    func derivedInitialState() -> SyncConvergencePostCommitState {
        SyncConvergencePostCommitState(
            queueCleanupPending: !queueCleanupBatchIDs.isEmpty,
            legacyCleanupPending: legacyCleanupRequired,
            presentationRefreshPending: !presentationEntries.isEmpty
        )
    }

    func validateCurrentState(_ state: SyncConvergencePostCommitState) throws {
        if state.queueCleanupPending && queueCleanupBatchIDs.isEmpty {
            throw SyncConvergencePostCommitWorkPayloadError.contradictoryState
        }
        if state.legacyCleanupPending && !legacyCleanupRequired {
            throw SyncConvergencePostCommitWorkPayloadError.contradictoryState
        }
        if state.presentationRefreshPending && presentationEntries.isEmpty {
            throw SyncConvergencePostCommitWorkPayloadError.contradictoryState
        }
    }

    func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw SyncConvergencePostCommitWorkPayloadError.unsupportedVersion
        }
        guard queueCleanupBatchIDs == Set(queueCleanupBatchIDs).sortedByUUIDString() else {
            throw SyncConvergencePostCommitWorkPayloadError.duplicateCleanupIDs
        }
        let noteIDs = presentationEntries.map(\.noteID)
        guard noteIDs == Set(noteIDs).sortedByUUIDString() else {
            throw SyncConvergencePostCommitWorkPayloadError.duplicatePresentationNoteIDs
        }
        for entry in presentationEntries {
            try entry.validate()
        }
    }

    struct PresentationEntry: Codable, Equatable, Sendable {
        let noteID: UUID
        let routing: SyncConvergencePostCommitPresentationRoutingPayload
        let expectedPreBodyHash: String?
        let committedPostBodyHash: String
        let incrementalOperations: [IncrementalOperationPayload]
        let rewriteSafetyReceipt: SyncConvergenceRewriteSafetyReceipt?

        init(
            noteID: UUID,
            routing: SyncConvergencePostCommitPresentationRoutingPayload,
            expectedPreBodyHash: String?,
            committedPostBodyHash: String,
            incrementalOperations: [IncrementalOperationPayload],
            rewriteSafetyReceipt: SyncConvergenceRewriteSafetyReceipt? = nil
        ) {
            self.noteID = noteID
            self.routing = routing
            self.expectedPreBodyHash = expectedPreBodyHash
            self.committedPostBodyHash = committedPostBodyHash
            self.incrementalOperations = incrementalOperations
            self.rewriteSafetyReceipt = rewriteSafetyReceipt
        }

        func validate() throws {
            try expectedPreBodyHash.map(validateBodyHash)
            try validateBodyHash(committedPostBodyHash)
            switch routing {
            case .incremental:
                guard !incrementalOperations.isEmpty else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
                }
            case .wholeNoteFallback:
                guard incrementalOperations.isEmpty,
                      let receipt = rewriteSafetyReceipt,
                      receipt.noteID == noteID,
                      receipt.priorBodyHash == expectedPreBodyHash,
                      receipt.candidateBodyHash == committedPostBodyHash else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
                }
            case .structuralRefresh:
                guard incrementalOperations.isEmpty,
                      rewriteSafetyReceipt == nil,
                      expectedPreBodyHash != nil else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
                }
            case .noteRemoved:
                guard incrementalOperations.isEmpty else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
                }
            case .none:
                guard incrementalOperations.isEmpty else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
                }
            }
            let operationIndices = incrementalOperations.map(\.operationIndex)
            guard operationIndices == Set(operationIndices).sorted() else {
                throw SyncConvergencePostCommitWorkPayloadError.duplicateOperationIndices
            }
            for operation in incrementalOperations {
                try operation.validate(noteID: noteID)
            }
            if !incrementalOperations.isEmpty,
               let expectedPreBodyHash {
                guard let firstBaseHash = incrementalOperations.first?.baseContentHash,
                      expectedPreBodyHash == firstBaseHash else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
                }
            }
            for (previous, current) in zip(incrementalOperations, incrementalOperations.dropFirst()) {
                guard let baseContentHash = current.baseContentHash,
                      baseContentHash == previous.resultContentHash else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
                }
            }
            if let finalResultHash = incrementalOperations.last?.resultContentHash,
               finalResultHash != committedPostBodyHash {
                throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
            }
        }
    }

    struct IncrementalOperationPayload: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Equatable, Sendable {
            case insert
            case delete
        }

        let noteID: UUID
        let operationIndex: Int
        let kind: Kind
        let utf16Offset: Int
        let utf16Length: Int?
        let text: String?
        let expectedText: String?
        let baseContentHash: String?
        let resultContentHash: String
        let operationIdentity: OperationIdentityPayload

        func validate(noteID entryNoteID: UUID) throws {
            do {
                try operationIdentity.validate()
            } catch {
                throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
            }
            guard noteID == entryNoteID,
                  operationIndex >= 0,
                  operationIdentity.operationIndex == operationIndex,
                  operationIdentity.batchIDLowercase == operationIdentity.canonicalReplayKey.batchIDLowercase,
                  operationIdentity.originDeviceIDLowercase == operationIdentity.canonicalReplayKey.originDeviceIDLowercase,
                  operationIdentity.operationIndex == operationIdentity.canonicalReplayKey.operationIndex,
                  operationIdentity.operationKind == kind.rawValue else {
                throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
            }
            try baseContentHash.map(validateBodyHash)
            try validateBodyHash(resultContentHash)
            switch kind {
            case .insert:
                guard operationIdentity.operationKind == Kind.insert.rawValue,
                      utf16Offset >= 0,
                      utf16Length == nil,
                      text != nil,
                      expectedText == nil else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
                }
            case .delete:
                guard operationIdentity.operationKind == Kind.delete.rawValue,
                      utf16Offset >= 0,
                      (utf16Length ?? -1) >= 0,
                      text == nil,
                      expectedText != nil else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
                }
            }
        }
    }
}


struct SyncConvergencePostCommitWorkPayloadV2: Codable, Equatable, Sendable {
    static let supportedFormatVersion = 2

    let formatVersion: Int
    let legacyWorkPayload: SyncConvergencePostCommitWorkPayloadV1
    let anchoredRecoveryTransitions: [AnchoredRecoveryTransitionPayload]

    init(
        legacyWorkPayload: SyncConvergencePostCommitWorkPayloadV1,
        anchoredRecoveryTransitions: [SyncBatchAnchoredRecoveryStoreTransition]
    ) throws {
        self.formatVersion = Self.supportedFormatVersion
        self.legacyWorkPayload = legacyWorkPayload
        self.anchoredRecoveryTransitions = try anchoredRecoveryTransitions
            .map(AnchoredRecoveryTransitionPayload.init)
            .sorted { try $0.validatedKey() < $1.validatedKey() }
        try validate()
    }

    func encodedPayloadData() throws -> Data {
        try validate()
        return try SyncConvergenceStableEncoding.encode(self)
    }

    static func decodePayloadData(_ data: Data) throws -> Self {
        let payload = try SyncConvergenceStableEncoding.decode(Self.self, from: data)
        try payload.validate()
        return payload
    }

    func decodedRecoveryTransitions() throws -> [SyncBatchAnchoredRecoveryStoreTransition] {
        try anchoredRecoveryTransitions.map { try $0.decodedTransition() }
    }

    func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw SyncConvergencePostCommitWorkPayloadError.unsupportedVersion
        }
        try legacyWorkPayload.validate()
        let keys = try anchoredRecoveryTransitions.map { try $0.validatedKey() }
        guard keys.count == Set(keys).count else {
            throw SyncConvergencePostCommitWorkPayloadError.duplicateAnchoredRecoveryTransitionKeys
        }
    }

    struct AnchoredRecoveryTransitionPayload: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Equatable, Sendable {
            case insertExpectedAbsent
            case replace
            case removeCommitted
        }

        let kind: Kind
        let expected: SyncBatchAnchoredRecoveryRecord?
        let replacement: SyncBatchAnchoredRecoveryRecord?

        init(_ transition: SyncBatchAnchoredRecoveryStoreTransition) throws {
            switch transition {
            case .insertExpectedAbsent(let proposed):
                kind = .insertExpectedAbsent
                expected = nil
                replacement = proposed
            case .replace(let expected, let replacement):
                kind = .replace
                self.expected = expected
                self.replacement = replacement
            case .removeCommitted(let expected):
                kind = .removeCommitted
                self.expected = expected
                replacement = nil
            }
            try validate()
        }

        func validatedKey() throws -> SyncBatchAnchoredRecoveryRecordKey {
            try validate()
            switch kind {
            case .insertExpectedAbsent:
                guard let replacement else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryAnchoredRecoveryTransition
                }
                return replacement.key
            case .replace, .removeCommitted:
                guard let expected else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryAnchoredRecoveryTransition
                }
                return expected.key
            }
        }

        func validate() throws {
            switch kind {
            case .insertExpectedAbsent:
                guard expected == nil, replacement != nil else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryAnchoredRecoveryTransition
                }
            case .replace:
                guard let expected, let replacement,
                      expected.key == replacement.key,
                      expected.change == replacement.change else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryAnchoredRecoveryTransition
                }
            case .removeCommitted:
                guard expected != nil, replacement == nil else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryAnchoredRecoveryTransition
                }
            }
        }

        func decodedTransition() throws -> SyncBatchAnchoredRecoveryStoreTransition {
            try validate()
            switch kind {
            case .insertExpectedAbsent:
                guard let replacement else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryAnchoredRecoveryTransition
                }
                return .insertExpectedAbsent(replacement)
            case .replace:
                guard let expected, let replacement else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryAnchoredRecoveryTransition
                }
                return .replace(expected: expected, replacement: replacement)
            case .removeCommitted:
                guard let expected else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryAnchoredRecoveryTransition
                }
                return .removeCommitted(expected: expected)
            }
        }
    }
}

enum SyncConvergenceVersionedPostCommitWorkPayload {
    struct Decoded: Equatable, Sendable {
        let legacyWorkPayload: SyncConvergencePostCommitWorkPayloadV1
        let anchoredRecoveryTransitions: [SyncBatchAnchoredRecoveryStoreTransition]

        func derivedInitialState() -> SyncConvergencePostCommitState {
            SyncConvergencePostCommitState(
                queueCleanupPending: !legacyWorkPayload.queueCleanupBatchIDs.isEmpty,
                legacyCleanupPending: legacyWorkPayload.legacyCleanupRequired,
                presentationRefreshPending: !legacyWorkPayload.presentationEntries.isEmpty,
                anchoredRecoveryPending: !anchoredRecoveryTransitions.isEmpty
            )
        }

        func validateCurrentState(_ state: SyncConvergencePostCommitState) throws {
            try legacyWorkPayload.validateCurrentState(state)
            if state.anchoredRecoveryPending && anchoredRecoveryTransitions.isEmpty {
                throw SyncConvergencePostCommitWorkPayloadError.contradictoryState
            }
        }
    }

    private struct VersionProbe: Decodable {
        let formatVersion: Int
    }

    static func encodedPayloadData(
        legacyWorkPayload: SyncConvergencePostCommitWorkPayloadV1,
        anchoredRecoveryTransitions: [SyncBatchAnchoredRecoveryStoreTransition]
    ) throws -> Data {
        guard !anchoredRecoveryTransitions.isEmpty else {
            return try legacyWorkPayload.encodedPayloadData()
        }
        return try SyncConvergencePostCommitWorkPayloadV2(
            legacyWorkPayload: legacyWorkPayload,
            anchoredRecoveryTransitions: anchoredRecoveryTransitions
        ).encodedPayloadData()
    }

    static func decodePayloadData(_ data: Data) throws -> Decoded {
        let probe = try SyncConvergenceStableEncoding.decode(VersionProbe.self, from: data)
        switch probe.formatVersion {
        case SyncConvergencePostCommitWorkPayloadV1.supportedFormatVersion:
            return Decoded(
                legacyWorkPayload: try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData(data),
                anchoredRecoveryTransitions: []
            )
        case SyncConvergencePostCommitWorkPayloadV2.supportedFormatVersion:
            let payload = try SyncConvergencePostCommitWorkPayloadV2.decodePayloadData(data)
            return Decoded(
                legacyWorkPayload: payload.legacyWorkPayload,
                anchoredRecoveryTransitions: try payload.decodedRecoveryTransitions()
            )
        default:
            throw SyncConvergencePostCommitWorkPayloadError.unsupportedVersion
        }
    }
}

enum SyncConvergencePostCommitPresentationRoutingPayload: String, Codable, Equatable, Sendable {
    case incremental
    case wholeNoteFallback
    case structuralRefresh
    case noteRemoved
    case none

    var routing: SyncConvergencePresentationRouting {
        switch self {
        case .incremental:
            return .incremental
        case .wholeNoteFallback:
            return .wholeNoteFallback
        case .structuralRefresh:
            return .structuralRefresh
        case .noteRemoved:
            return .noteRemoved
        case .none:
            return .none
        }
    }

    init?(_ routing: SyncConvergencePresentationRouting) {
        switch routing {
        case .incremental:
            self = .incremental
        case .wholeNoteFallback:
            self = .wholeNoteFallback
        case .structuralRefresh:
            self = .structuralRefresh
        case .noteRemoved:
            self = .noteRemoved
        case .none:
            self = .none
        }
    }
}

enum SyncConvergencePostCommitWorkPayloadError: Error, Equatable {
    case unsupportedVersion
    case duplicateCleanupIDs
    case duplicateAnchoredRecoveryTransitionKeys
    case contradictoryAnchoredRecoveryTransition
    case duplicatePresentationNoteIDs
    case duplicateOperationIndices
    case contradictoryState
    case contradictoryPresentationEntry
}

private func validateBodyHash(_ value: String) throws {
    guard value.count == 64,
          value.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
        throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
    }
}

private extension Set where Element == UUID {
    func sortedByUUIDString() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}