import XCTest
import SwiftData
import CryptoKit
#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

enum PostCommitTestFixtureError: Error {
    case unexpectedPlanningOutcome
}

func request(
    identity: SyncConvergencePersistedIncorporationIdentity,
    state: SyncConvergencePostCommitState = SyncConvergencePostCommitState(
        queueCleanupPending: true,
        legacyCleanupPending: false,
        presentationRefreshPending: true
    ),
    presentationPlan: SyncConvergencePresentationPlan = SyncConvergencePresentationPlan(noteRoutings: [
        TestIDs.noteA: .wholeNoteFallback
    ])
) -> SyncConvergencePostCommitRequest {
    SyncConvergencePostCommitRequest(
        sourceBatchID: identity.batchID,
        affectedNoteIDs: [TestIDs.noteA],
        cleanupPlan: SyncConvergenceCleanupPlan(
            batchIDs: [identity.batchID, TestIDs.extraBatch],
            retryQueueCleanup: state.queueCleanupPending,
            retryLegacyCleanup: state.legacyCleanupPending,
            retryPresentationRefresh: state.presentationRefreshPending
        ),
        presentationPlan: presentationPlan,
        persistedIncorporationIdentity: identity
    )
}

func testIdentity() -> SyncConvergencePersistedIncorporationIdentity {
    SyncConvergencePersistedIncorporationIdentity(
        batchID: TestIDs.batch,
        canonicalPayloadDigest: "canonical",
        canonicalPayloadDigestFormatVersion: 1,
        committedResultDigest: "committed",
        committedResultDigestFormatVersion: 1
    )
}

struct MYR135PersistedIdentityFixture {
    let container: ModelContainer
    let noteID: UUID
    let request: SyncConvergencePostCommitRequest
    let workPayload: SyncConvergencePostCommitWorkPayloadV1

    func workOperation(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload {
        try XCTUnwrap(workPayload.presentationEntries.first?.incrementalOperations.first, file: file, line: line)
    }

    func authoritativeRow(
        context: ModelContext? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> IncorporatedBatchOperationIdentity {
        let fetchContext = context ?? ModelContext(container)
        let operation = try workOperation(file: file, line: line)
        let batchID = request.sourceBatchID
        let operationIndex = operation.operationIndex
        let rows = try fetchContext.fetch(FetchDescriptor<IncorporatedBatchOperationIdentity>(
            predicate: #Predicate {
                $0.batchID == batchID && $0.operationIndex == operationIndex
            }
        ))
        return try XCTUnwrap(rows.first, file: file, line: line)
    }

    func reloadedNoteBody() throws -> String? {
        let noteID = self.noteID
        return try ModelContext(container)
            .fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID }))
            .first?
            .content
    }

    func rootSnapshot(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> MYR135PostCommitRootSnapshot {
        let batchID = request.sourceBatchID
        let root = try XCTUnwrap(
            ModelContext(container)
                .fetch(FetchDescriptor<IncorporatedSyncBatch>(predicate: #Predicate { $0.batchID == batchID }))
                .first,
            file: file,
            line: line
        )
        return MYR135PostCommitRootSnapshot(
            postCommitStatePayloadData: Data(root.postCommitStatePayloadData),
            postCommitWorkPayloadData: root.postCommitWorkPayloadData.map { Data($0) },
            committedResultDigest: root.committedResultDigest,
            committedResultDigestFormatVersion: root.committedResultDigestFormatVersion
        )
    }
}

struct MYR135PostCommitRootSnapshot: Equatable {
    let postCommitStatePayloadData: Data
    let postCommitWorkPayloadData: Data?
    let committedResultDigest: String
    let committedResultDigestFormatVersion: Int
}

struct MYR136Fixture {
    let base: MYR135PersistedIdentityFixture
    let loaded: SyncConvergencePostCommitFullRootState
    let rootModelID: UUID

    var container: ModelContainer {
        base.container
    }

    var request: SyncConvergencePostCommitRequest {
        base.request
    }

    func store(context: ModelContext? = nil) -> SwiftDataSyncConvergencePostCommitStore {
        SwiftDataSyncConvergencePostCommitStore(context: context ?? ModelContext(container))
    }

    func rawRoot(
        context: ModelContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> IncorporatedSyncBatch {
        let rootModelID = self.rootModelID
        return try XCTUnwrap(
            context.fetch(FetchDescriptor<IncorporatedSyncBatch>(
                predicate: #Predicate { $0.id == rootModelID }
            )).first,
            file: file,
            line: line
        )
    }

    func rawRootSnapshot(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> MYR136RawRootSnapshot {
        try MYR136RawRootSnapshot(root: rawRoot(context: ModelContext(container), file: file, line: line))
    }
}

struct MYR136RawRootSnapshot: Equatable {
    let batchKey: String
    let id: UUID
    let batchID: UUID
    let originDeviceID: UUID
    let createdAt: Date
    let createdAtBitPattern: UInt64
    let batchSequence: UInt64?
    let schemaVersion: Int
    let committedAt: Date
    let committedAtBitPattern: UInt64
    let canonicalPayloadDigest: String
    let canonicalPayloadDigestFormatVersion: Int
    let committedResultDigest: String
    let committedResultDigestFormatVersion: Int
    let affectedNotesPayloadData: Data
    let authoritativeChildCount: Int
    let authoritativeChildBytes: Int
    let authoritativeChildrenDigest: String
    let postCommitWorkPayloadData: Data?
    let postCommitStatePayloadData: Data

    init(
        batchKey: String,
        id: UUID,
        batchID: UUID,
        originDeviceID: UUID,
        createdAt: Date,
        createdAtBitPattern: UInt64,
        batchSequence: UInt64?,
        schemaVersion: Int,
        committedAt: Date,
        committedAtBitPattern: UInt64,
        canonicalPayloadDigest: String,
        canonicalPayloadDigestFormatVersion: Int,
        committedResultDigest: String,
        committedResultDigestFormatVersion: Int,
        affectedNotesPayloadData: Data,
        authoritativeChildCount: Int,
        authoritativeChildBytes: Int,
        authoritativeChildrenDigest: String,
        postCommitWorkPayloadData: Data?,
        postCommitStatePayloadData: Data
    ) {
        self.batchKey = batchKey
        self.id = id
        self.batchID = batchID
        self.originDeviceID = originDeviceID
        self.createdAt = createdAt
        self.createdAtBitPattern = createdAtBitPattern
        self.batchSequence = batchSequence
        self.schemaVersion = schemaVersion
        self.committedAt = committedAt
        self.committedAtBitPattern = committedAtBitPattern
        self.canonicalPayloadDigest = canonicalPayloadDigest
        self.canonicalPayloadDigestFormatVersion = canonicalPayloadDigestFormatVersion
        self.committedResultDigest = committedResultDigest
        self.committedResultDigestFormatVersion = committedResultDigestFormatVersion
        self.affectedNotesPayloadData = affectedNotesPayloadData
        self.authoritativeChildCount = authoritativeChildCount
        self.authoritativeChildBytes = authoritativeChildBytes
        self.authoritativeChildrenDigest = authoritativeChildrenDigest
        self.postCommitWorkPayloadData = postCommitWorkPayloadData
        self.postCommitStatePayloadData = postCommitStatePayloadData
    }

    init(root: IncorporatedSyncBatch) throws {
        try root.validateDateAuthority()
        batchKey = root.batchKey
        id = root.id
        batchID = root.batchID
        originDeviceID = root.originDeviceID
        createdAt = root.createdAt
        createdAtBitPattern = root.createdAtBitPattern
        batchSequence = root.batchSequence
        schemaVersion = root.schemaVersion
        committedAt = root.committedAt
        committedAtBitPattern = root.committedAtBitPattern
        canonicalPayloadDigest = root.canonicalPayloadDigest
        canonicalPayloadDigestFormatVersion = root.canonicalPayloadDigestFormatVersion
        committedResultDigest = root.committedResultDigest
        committedResultDigestFormatVersion = root.committedResultDigestFormatVersion
        affectedNotesPayloadData = Data(root.affectedNotesPayloadData)
        authoritativeChildCount = root.authoritativeChildCount
        authoritativeChildBytes = root.authoritativeChildBytes
        authoritativeChildrenDigest = root.authoritativeChildrenDigest
        postCommitWorkPayloadData = root.postCommitWorkPayloadData.map { Data($0) }
        postCommitStatePayloadData = Data(root.postCommitStatePayloadData)
    }

    func replacingPostCommitStatePayloadData(_ data: Data) -> Self {
        MYR136RawRootSnapshot(
            batchKey: batchKey,
            id: id,
            batchID: batchID,
            originDeviceID: originDeviceID,
            createdAt: createdAt,
            createdAtBitPattern: createdAtBitPattern,
            batchSequence: batchSequence,
            schemaVersion: schemaVersion,
            committedAt: committedAt,
            committedAtBitPattern: committedAtBitPattern,
            canonicalPayloadDigest: canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: canonicalPayloadDigestFormatVersion,
            committedResultDigest: committedResultDigest,
            committedResultDigestFormatVersion: committedResultDigestFormatVersion,
            affectedNotesPayloadData: affectedNotesPayloadData,
            authoritativeChildCount: authoritativeChildCount,
            authoritativeChildBytes: authoritativeChildBytes,
            authoritativeChildrenDigest: authoritativeChildrenDigest,
            postCommitWorkPayloadData: postCommitWorkPayloadData,
            postCommitStatePayloadData: data
        )
    }
}

func makeMYR135PersistedIdentityFixture() throws -> MYR135PersistedIdentityFixture {
    let noteID = postCommitUUID("00000000-0000-0000-0000-000000135701")
    let batch = SyncBatch(
        id: postCommitUUID("00000000-0000-0000-0000-000000135702"),
        originDeviceID: postCommitUUID("00000000-0000-0000-0000-000000135703"),
        createdAt: Date(timeIntervalSince1970: 10),
        batchSequence: 135701,
        changes: [
            .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                noteID: noteID,
                utf16Offset: 1,
                text: "B",
                modifiedAt: Date(timeIntervalSince1970: 11),
                baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
            ))
        ]
    )
    let initialNote = SyncConvergenceProjectedNote(
        noteID: noteID,
        folderID: nil,
        title: "Persisted",
        body: "A",
        createdAt: Date(timeIntervalSince1970: 1),
        modifiedAt: Date(timeIntervalSince1970: 2)
    )
    let planned = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
        incomingBatch: batch,
        currentNotes: [initialNote]
    ))
    guard case .planned(let input) = planned else {
        throw PostCommitTestFixtureError.unexpectedPlanningOutcome
    }

    let container = try ModelContainer(
        for: Schema(MyRAMModelRegistry.models),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
    let context = ModelContext(container)
    let note = Note(title: "Persisted", content: "A")
    note.id = noteID
    note.createdAt = initialNote.createdAt
    note.modifiedAt = initialNote.modifiedAt
    context.insert(note)
    try context.save()

    let outcome = SyncConvergenceIncorporationExecutor().incorporate(
        input: input,
        transaction: SwiftDataSyncConvergencePersistenceTransaction(context: context),
        committedAt: Date(timeIntervalSince1970: 12)
    )
    guard case .incorporated(let result) = outcome else {
        throw PostCommitTestFixtureError.unexpectedPlanningOutcome
    }
    let pendingState = SyncConvergencePostCommitState(
        queueCleanupPending: true,
        legacyCleanupPending: true,
        presentationRefreshPending: true
    )
    guard case .fullRoot(let initiallyLoaded) = try SwiftDataSyncConvergencePostCommitStore(
        context: ModelContext(container)
    ).loadState(matching: result.persistedIncorporationIdentity),
          let initialWorkPayload = initiallyLoaded.postCommitWorkPayload else {
        throw PostCommitTestFixtureError.unexpectedPlanningOutcome
    }
    let pendingWorkPayload = SyncConvergencePostCommitWorkPayloadV1(
        queueCleanupBatchIDs: Set(initialWorkPayload.queueCleanupBatchIDs),
        legacyCleanupRequired: true,
        presentationEntries: initialWorkPayload.presentationEntries
    )
    let rootContext = ModelContext(container)
    let rootBatchID = result.batchID
    guard let root = try rootContext.fetch(FetchDescriptor<IncorporatedSyncBatch>(
        predicate: #Predicate { $0.batchID == rootBatchID }
    )).first else {
        throw PostCommitTestFixtureError.unexpectedPlanningOutcome
    }
    root.postCommitStatePayloadData = try SyncConvergenceStableEncoding.encode(pendingState)
    root.postCommitWorkPayloadData = try pendingWorkPayload.encodedPayloadData()
    try rootContext.save()

    guard case .fullRoot(let loaded) = try SwiftDataSyncConvergencePostCommitStore(
        context: ModelContext(container)
    ).loadState(matching: result.persistedIncorporationIdentity),
          let workPayload = loaded.postCommitWorkPayload else {
        throw PostCommitTestFixtureError.unexpectedPlanningOutcome
    }

    return MYR135PersistedIdentityFixture(
        container: container,
        noteID: noteID,
        request: SyncConvergencePostCommitRequest(
            sourceBatchID: result.batchID,
            affectedNoteIDs: result.affectedNoteIDs,
            cleanupPlan: SyncConvergenceCleanupPlan(
                batchIDs: result.cleanupPlan.batchIDs,
                retryQueueCleanup: true,
                retryLegacyCleanup: true,
                retryPresentationRefresh: true
            ),
            presentationPlan: result.presentationPlan,
            persistedIncorporationIdentity: result.persistedIncorporationIdentity
        ),
        workPayload: workPayload
    )
}

func makeMYR136Fixture(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> MYR136Fixture {
    let base = try makeMYR135PersistedIdentityFixture()
    let store = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(base.container))
    guard case .fullRoot(let loaded) = try store.loadState(matching: base.request.persistedIncorporationIdentity) else {
        throw PostCommitTestFixtureError.unexpectedPlanningOutcome
    }
    let root = try base.rootSnapshot(file: file, line: line)
    let rootBatchID = base.request.sourceBatchID
    let rootModel = try XCTUnwrap(
        ModelContext(base.container).fetch(FetchDescriptor<IncorporatedSyncBatch>(
            predicate: #Predicate { $0.batchID == rootBatchID }
        )).first,
        file: file,
        line: line
    )
    XCTAssertEqual(root.postCommitStatePayloadData, loaded.postCommitStatePayloadData, file: file, line: line)
    XCTAssertEqual(root.postCommitWorkPayloadData, loaded.postCommitWorkPayloadData, file: file, line: line)
    return MYR136Fixture(base: base, loaded: loaded, rootModelID: rootModel.id)
}

func makeMYR137Fixture(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> MYR136Fixture {
    let fixture = try makeMYR136Fixture(file: file, line: line)
    let expectedSourceBatchID = postCommitUUID("00000000-0000-0000-0000-000000135702")
    XCTAssertEqual(
        fixture.request.sourceBatchID,
        expectedSourceBatchID,
        "MYR-137 failure fixtures must track the wrapped MYR-135 source batch",
        file: file,
        line: line
    )
    return fixture
}

func myr136StateB() -> SyncConvergencePostCommitState {
    SyncConvergencePostCommitState(
        queueCleanupPending: true,
        legacyCleanupPending: true,
        presentationRefreshPending: false
    )
}

func myr136StateC() -> SyncConvergencePostCommitState {
    SyncConvergencePostCommitState(
        queueCleanupPending: false,
        legacyCleanupPending: true,
        presentationRefreshPending: false
    )
}

func copyRootProjection(
    _ root: SyncConvergenceIncorporatedRootProjection,
    batchID: UUID? = nil,
    originDeviceID: UUID? = nil,
    createdAt: Date? = nil,
    batchSequence: UInt64?? = nil,
    schemaVersion: Int? = nil,
    committedAt: Date? = nil,
    canonicalPayloadDigest: String? = nil,
    canonicalPayloadDigestFormatVersion: Int? = nil,
    committedResultDigest: String? = nil,
    committedResultDigestFormatVersion: Int? = nil,
    committedAtOrderingPayloadData: Data? = nil,
    affectedNotesPayloadData: Data? = nil,
    authoritativeChildCount: Int? = nil,
    authoritativeChildBytes: Int? = nil,
    authoritativeChildrenDigest: String? = nil,
    postCommitWorkPayloadData: Data?? = nil,
    postCommitStatePayloadData: Data? = nil
) -> SyncConvergenceIncorporatedRootProjection {
    SyncConvergenceIncorporatedRootProjection(
        batchID: batchID ?? root.batchID,
        originDeviceID: originDeviceID ?? root.originDeviceID,
        createdAt: createdAt ?? root.createdAt,
        batchSequence: batchSequence ?? root.batchSequence,
        schemaVersion: schemaVersion ?? root.schemaVersion,
        committedAt: committedAt ?? root.committedAt,
        canonicalPayloadDigest: canonicalPayloadDigest ?? root.canonicalPayloadDigest,
        canonicalPayloadDigestFormatVersion: canonicalPayloadDigestFormatVersion ?? root.canonicalPayloadDigestFormatVersion,
        committedResultDigest: committedResultDigest ?? root.committedResultDigest,
        committedResultDigestFormatVersion: committedResultDigestFormatVersion ?? root.committedResultDigestFormatVersion,
        committedAtOrderingPayloadData: committedAtOrderingPayloadData ?? root.committedAtOrderingPayloadData,
        affectedNotesPayloadData: affectedNotesPayloadData ?? root.affectedNotesPayloadData,
        authoritativeChildCount: authoritativeChildCount ?? root.authoritativeChildCount,
        authoritativeChildBytes: authoritativeChildBytes ?? root.authoritativeChildBytes,
        authoritativeChildrenDigest: authoritativeChildrenDigest ?? root.authoritativeChildrenDigest,
        postCommitWorkPayloadData: postCommitWorkPayloadData ?? root.postCommitWorkPayloadData,
        postCommitStatePayloadData: postCommitStatePayloadData ?? root.postCommitStatePayloadData
    )
}

func assertRootProjection(
    _ actual: SyncConvergenceIncorporatedRootProjection,
    equals expected: SyncConvergenceIncorporatedRootProjection,
    replacingStatePayloadData statePayloadData: Data,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        actual,
        copyRootProjection(expected, postCommitStatePayloadData: statePayloadData),
        file: file,
        line: line
    )
}

func fullRootState(
    identity: SyncConvergencePersistedIncorporationIdentity,
    state: SyncConvergencePostCommitState,
    presentationEntries: [SyncConvergencePostCommitWorkPayloadV1.PresentationEntry]? = nil,
    includeWorkPayload: Bool = true
) -> SyncConvergencePostCommitFullRootState {
    let payload = try! SyncConvergenceStableEncoding.encode(state)
    let workPayload = includeWorkPayload ? SyncConvergencePostCommitWorkPayloadV1(
        queueCleanupBatchIDs: state.queueCleanupPending ? [identity.batchID, TestIDs.extraBatch] : [],
        legacyCleanupRequired: state.legacyCleanupPending,
        presentationEntries: presentationEntries ?? (state.presentationRefreshPending ? [workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)] : [])
    ) : nil
    let workPayloadData = try! workPayload?.encodedPayloadData()
    return SyncConvergencePostCommitFullRootState(
        root: SyncConvergenceIncorporatedRootProjection(
            batchID: identity.batchID,
            originDeviceID: TestIDs.device,
            createdAt: Date(timeIntervalSince1970: 1),
            batchSequence: 1,
            schemaVersion: 1,
            committedAt: Date(timeIntervalSince1970: 2),
            canonicalPayloadDigest: identity.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: identity.canonicalPayloadDigestFormatVersion,
            committedResultDigest: identity.committedResultDigest,
            committedResultDigestFormatVersion: identity.committedResultDigestFormatVersion,
            committedAtOrderingPayloadData: Data(),
            affectedNotesPayloadData: Data(),
            authoritativeChildCount: 0,
            authoritativeChildBytes: 0,
            authoritativeChildrenDigest: "children",
            postCommitWorkPayloadData: workPayloadData,
            postCommitStatePayloadData: payload
        ),
        postCommitState: state,
        postCommitStatePayloadData: payload,
        postCommitWorkPayload: workPayload,
        postCommitWorkPayloadData: workPayloadData
    )
}

func workEntry(
    noteID: UUID,
    routing: SyncConvergencePostCommitPresentationRoutingPayload,
    postHash: String = SyncBatchContentHash.sha256Hex(for: "post")
) -> SyncConvergencePostCommitWorkPayloadV1.PresentationEntry {
    SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
        noteID: noteID,
        routing: routing,
        expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: "pre"),
        committedPostBodyHash: postHash,
        incrementalOperations: routing == .incremental ? [incrementalOperation(noteID: noteID, resultHash: postHash)] : []
    )
}

func payload(
    entryNoteID: UUID,
    expectedPreBodyHash: String? = nil,
    committedPostBodyHash: String,
    operations: [SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload]
) -> SyncConvergencePostCommitWorkPayloadV1 {
    SyncConvergencePostCommitWorkPayloadV1(
        queueCleanupBatchIDs: [],
        legacyCleanupRequired: false,
        presentationEntries: [
            SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                noteID: entryNoteID,
                routing: .incremental,
                expectedPreBodyHash: expectedPreBodyHash,
                committedPostBodyHash: committedPostBodyHash,
                incrementalOperations: operations
            )
        ]
    )
}

func expectedPresentationRequest(
    identity: SyncConvergencePersistedIncorporationIdentity,
    entry: SyncConvergencePostCommitWorkPayloadV1.PresentationEntry,
    committedNote: SyncConvergenceMutableNoteRecord
) -> SyncConvergencePresentationRequest {
    SyncConvergencePresentationRequest(
        incorporationIdentity: identity,
        noteID: entry.noteID,
        routing: entry.routing.routing,
        expectedPreBodyHash: entry.expectedPreBodyHash,
        committedPostBodyHash: entry.committedPostBodyHash,
        incrementalOperations: entry.incrementalOperations,
        committedNote: committedNote,
        committedBodyHash: SyncBatchContentHash.sha256Hex(for: committedNote.body),
        committedTitle: committedNote.title
    )
}

func incrementalOperation(
    noteID: UUID,
    resultHash: String
) -> SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload {
    incrementalOperation(
        noteID: noteID,
        operationIndex: 0,
        utf16Offset: 0,
        text: "x",
        baseHash: SyncBatchContentHash.sha256Hex(for: "pre"),
        resultHash: resultHash
    )
}

func incrementalOperation(
    noteID: UUID,
    operationIndex: Int,
    utf16Offset: Int,
    text: String,
    baseHash: String?,
    resultHash: String
) -> SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload {
    SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
        noteID: noteID,
        operationIndex: operationIndex,
        kind: .insert,
        utf16Offset: utf16Offset,
        utf16Length: nil,
        text: text,
        expectedText: nil,
        baseContentHash: baseHash,
        resultContentHash: resultHash,
        operationIdentity: OperationIdentityPayload(
            batchID: TestIDs.batch,
            originDeviceID: TestIDs.device,
            operationIndex: operationIndex,
            operationKind: "insert",
            canonicalReplayKey: CanonicalReplayKeyPayload(
                modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSince1970: 3)),
                originDeviceIDLowercase: TestIDs.device.uuidString.lowercased(),
                batchOrderKind: .legacy,
                legacyCreatedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSince1970: 1)),
                sequence: nil,
                batchIDLowercase: TestIDs.batch.uuidString.lowercased(),
                operationIndex: operationIndex
            )
        )
    )
}

func postCommitSHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func tombstone(
    identity: SyncConvergencePersistedIncorporationIdentity
) -> SyncConvergenceIncorporatedTombstoneProjection {
    SyncConvergenceIncorporatedTombstoneProjection(
        batchID: identity.batchID,
        originDeviceID: TestIDs.device,
        canonicalPayloadDigest: identity.canonicalPayloadDigest,
        canonicalPayloadDigestFormatVersion: identity.canonicalPayloadDigestFormatVersion,
        schemaVersion: 1,
        committedResultDigest: identity.committedResultDigest,
        committedResultDigestFormatVersion: identity.committedResultDigestFormatVersion,
        committedAtOrderingPayloadData: Data(),
        tombstoneFormatVersion: 1
    )
}

func note(id: UUID, title: String, body: String) -> SyncConvergenceMutableNoteRecord {
    SyncConvergenceMutableNoteRecord(
        noteID: id,
        folderID: nil,
        title: title,
        body: body,
        createdAt: Date(timeIntervalSince1970: 3),
        modifiedAt: Date(timeIntervalSince1970: 4)
    )
}

func batch(id: UUID) -> SyncBatch {
    SyncBatch(
        id: id,
        originDeviceID: TestIDs.device,
        createdAt: Date(timeIntervalSince1970: 5),
        batchSequence: nil,
        changes: []
    )
}

func temporaryQueueURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("queue.json")
}

func postCommitUUID(_ value: String) -> UUID {
    UUID(uuidString: value)!
}
enum TestIDs {
static let batch = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
static let extraBatch = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
static let device = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
static let noteA = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
static let noteB = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
}

enum PostCommitInvocationEvent: Equatable {
case queueCleanup([UUID])
case legacyCleanup(batchID: UUID)
case presentation(noteID: UUID)
}

final class PostCommitInvocationRecorder {
let lock = NSLock()
var recordedEvents: [PostCommitInvocationEvent] = []

var events: [PostCommitInvocationEvent] {
    lock.withLock { recordedEvents }
}

func record(_ event: PostCommitInvocationEvent) {
    lock.withLock {
        recordedEvents.append(event)
    }
}
}

final class FakePostCommitStore: SyncConvergencePostCommitStateStore {
enum LoadBehavior {
    case current
    case returnState(SyncConvergencePostCommitLoadedState)
    case fail(SyncConvergencePostCommitFailure)
    case failUnexpectedly
}

enum CASBehavior {
    case succeed
    case failPersistence
    case replaceCurrentBeforeCompare(SyncConvergencePostCommitFullRootState)
}

enum CommittedNoteLoadBehavior {
    case currentNotes
    case returnMissing
    case fail
}

struct UnexpectedLoadError: Error {}
struct CommittedNoteLoadError: Error {}

var state: SyncConvergencePostCommitLoadedState
var notes: [UUID: SyncConvergenceMutableNoteRecord] = [:]
var persistedState: SyncConvergencePostCommitState?
var writeCount = 0
var loadBehavior: LoadBehavior = .current
var casBehavior: CASBehavior = .succeed
var committedNoteLoadBehavior: CommittedNoteLoadBehavior = .currentNotes
var loadCallCount = 0
var committedNoteLoadRequests: [UUID] = []
var casAttemptCount = 0
var expectedRootRequests: [SyncConvergencePostCommitRootSnapshot] = []
var expectedPayloadDataRequests: [Data] = []
var attemptedNewStates: [SyncConvergencePostCommitState] = []
let originalWorkPayloadData: Data?

init(state: SyncConvergencePostCommitLoadedState) {
    self.state = state
    if case .fullRoot(let root) = state {
        originalWorkPayloadData = root.postCommitWorkPayloadData
    } else {
        originalWorkPayloadData = nil
    }
    notes[TestIDs.noteA] = SyncConvergenceMutableNoteRecord(
        noteID: TestIDs.noteA,
        folderID: nil,
        title: "Title",
        body: "Body",
        createdAt: Date(timeIntervalSince1970: 1),
        modifiedAt: Date(timeIntervalSince1970: 2)
    )
}

convenience init(
    reloading root: SyncConvergenceIncorporatedRootProjection,
    notes: [UUID: SyncConvergenceMutableNoteRecord]
) throws {
    let statePayloadData = Data(root.postCommitStatePayloadData)
    let workPayloadData = root.postCommitWorkPayloadData.map { Data($0) }
    let state = try SyncConvergenceStableEncoding.decode(
        SyncConvergencePostCommitState.self,
        from: statePayloadData
    )
    let work = try workPayloadData.map {
        try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData($0)
    }
    let loaded = SyncConvergencePostCommitFullRootState(
        root: root,
        postCommitState: state,
        postCommitStatePayloadData: statePayloadData,
        postCommitWorkPayload: work,
        postCommitWorkPayloadData: workPayloadData
    )

    self.init(state: .fullRoot(loaded))
    self.notes = notes
}

func loadState(
    matching identity: SyncConvergencePersistedIncorporationIdentity
) throws -> SyncConvergencePostCommitLoadedState {
    loadCallCount += 1
    switch loadBehavior {
    case .current:
        return state
    case .returnState(let loaded):
        return loaded
    case .fail(let failure):
        throw failure
    case .failUnexpectedly:
        throw UnexpectedLoadError()
    }
}

func loadCommittedNote(id: UUID) throws -> SyncConvergenceMutableNoteRecord? {
    committedNoteLoadRequests.append(id)
    switch committedNoteLoadBehavior {
    case .currentNotes:
        return notes[id]
    case .returnMissing:
        return nil
    case .fail:
        throw CommittedNoteLoadError()
    }
}

func compareAndSetPostCommitState(
    expectedRoot: SyncConvergencePostCommitRootSnapshot,
    expectedPayloadData: Data,
    newState: SyncConvergencePostCommitState
) throws -> SyncConvergencePostCommitFullRootState {
    writeCount += 1
    casAttemptCount += 1
    expectedRootRequests.append(expectedRoot)
    expectedPayloadDataRequests.append(expectedPayloadData)
    attemptedNewStates.append(newState)
    switch casBehavior {
    case .succeed:
        break
    case .failPersistence:
        throw SyncConvergencePostCommitFailure.persistence
    case .replaceCurrentBeforeCompare(let replacement):
        state = .fullRoot(replacement)
    }
    guard case .fullRoot(let current) = state,
          current.root == expectedRoot.root,
          current.postCommitStatePayloadData == expectedPayloadData else {
        throw SyncConvergencePostCommitFailure.inconsistentIncorporationIdentity(batchID: expectedRoot.root.batchID)
    }
    persistedState = newState
    let payload = try SyncConvergenceStableEncoding.encode(newState)
    let root = SyncConvergenceIncorporatedRootProjection(
        batchID: current.root.batchID,
        originDeviceID: current.root.originDeviceID,
        createdAt: current.root.createdAt,
        batchSequence: current.root.batchSequence,
        schemaVersion: current.root.schemaVersion,
        committedAt: current.root.committedAt,
        canonicalPayloadDigest: current.root.canonicalPayloadDigest,
        canonicalPayloadDigestFormatVersion: current.root.canonicalPayloadDigestFormatVersion,
        committedResultDigest: current.root.committedResultDigest,
        committedResultDigestFormatVersion: current.root.committedResultDigestFormatVersion,
        committedAtOrderingPayloadData: current.root.committedAtOrderingPayloadData,
        affectedNotesPayloadData: current.root.affectedNotesPayloadData,
        authoritativeChildCount: current.root.authoritativeChildCount,
        authoritativeChildBytes: current.root.authoritativeChildBytes,
        authoritativeChildrenDigest: current.root.authoritativeChildrenDigest,
        postCommitWorkPayloadData: current.root.postCommitWorkPayloadData,
        postCommitStatePayloadData: payload
    )
    let loaded = SyncConvergencePostCommitFullRootState(
        root: root,
        postCommitState: newState,
        postCommitStatePayloadData: payload,
        postCommitWorkPayload: current.postCommitWorkPayload,
        postCommitWorkPayloadData: current.postCommitWorkPayloadData
    )
    state = .fullRoot(loaded)
    return loaded
}

var currentPostCommitState: SyncConvergencePostCommitState? {
    guard case .fullRoot(let current) = state else { return nil }
    return current.postCommitState
}

var currentWorkPayloadData: Data? {
    guard case .fullRoot(let current) = state else { return nil }
    return current.postCommitWorkPayloadData
}

func makeFullRootState(
    identity: SyncConvergencePersistedIncorporationIdentity,
    state: SyncConvergencePostCommitState
) -> SyncConvergencePostCommitFullRootState {
    let payload = try! SyncConvergenceStableEncoding.encode(state)
    let workPayload = SyncConvergencePostCommitWorkPayloadV1(
        queueCleanupBatchIDs: state.queueCleanupPending ? [identity.batchID, TestIDs.extraBatch] : [],
        legacyCleanupRequired: state.legacyCleanupPending,
        presentationEntries: state.presentationRefreshPending ? [
            SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                noteID: TestIDs.noteA,
                routing: .wholeNoteFallback,
                expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: "pre"),
                committedPostBodyHash: SyncBatchContentHash.sha256Hex(for: "post"),
                incrementalOperations: []
            )
        ] : []
    )
    let workPayloadData = try! workPayload.encodedPayloadData()
    return SyncConvergencePostCommitFullRootState(
        root: SyncConvergenceIncorporatedRootProjection(
            batchID: identity.batchID,
            originDeviceID: TestIDs.device,
            createdAt: Date(timeIntervalSince1970: 1),
            batchSequence: 1,
            schemaVersion: 1,
            committedAt: Date(timeIntervalSince1970: 2),
            canonicalPayloadDigest: identity.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: identity.canonicalPayloadDigestFormatVersion,
            committedResultDigest: identity.committedResultDigest,
            committedResultDigestFormatVersion: identity.committedResultDigestFormatVersion,
            committedAtOrderingPayloadData: Data(),
            affectedNotesPayloadData: Data(),
            authoritativeChildCount: 0,
            authoritativeChildBytes: 0,
            authoritativeChildrenDigest: "children",
            postCommitWorkPayloadData: workPayloadData,
            postCommitStatePayloadData: payload
        ),
        postCommitState: state,
        postCommitStatePayloadData: payload,
        postCommitWorkPayload: workPayload,
        postCommitWorkPayloadData: workPayloadData
    )
}
}

extension SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload {
func replacingForTest(
    noteID: UUID? = nil,
    operationIndex: Int? = nil,
    kind: Kind? = nil,
    utf16Length: Int? = nil,
    text: String?? = nil,
    expectedText: String?? = nil,
    baseContentHash: String?? = nil,
    resultContentHash: String? = nil,
    operationIdentity: OperationIdentityPayload? = nil
) -> Self {
    Self(
        noteID: noteID ?? self.noteID,
        operationIndex: operationIndex ?? self.operationIndex,
        kind: kind ?? self.kind,
        utf16Offset: utf16Offset,
        utf16Length: utf16Length ?? self.utf16Length,
        text: text ?? self.text,
        expectedText: expectedText ?? self.expectedText,
        baseContentHash: baseContentHash ?? self.baseContentHash,
        resultContentHash: resultContentHash ?? self.resultContentHash,
        operationIdentity: operationIdentity ?? self.operationIdentity
    )
}
}

final class FakeQueueCleanupAdapter: SyncConvergenceQueueCleanupAdapter {
enum Behavior {
    case verifiedComplete
    case failBeforeRemoval
    case incompleteRemoval(remaining: Set<SyncBatchID>)
    case failVerificationAfterRemoval
}

var removals: [Set<SyncBatchID>] = []
var remaining: Set<SyncBatchID> = []
var behavior: Behavior = .verifiedComplete
var removalAttempts = 0
var verificationChecks: [SyncBatchID] = []
var externalRemovalEffectOccurred = false
let recorder: PostCommitInvocationRecorder?

init(recorder: PostCommitInvocationRecorder? = nil) {
    self.recorder = recorder
}

func removeBatches(withIDs ids: Set<SyncBatchID>) throws {
    removalAttempts += 1
    if case .failBeforeRemoval = behavior {
        throw FileBackedSyncBatchQueue.QueueError.persistenceFailed
    }
    removals.append(ids)
    recorder?.record(.queueCleanup(ids.sorted { $0.uuidString < $1.uuidString }))
    externalRemovalEffectOccurred = true
    switch behavior {
    case .verifiedComplete, .failVerificationAfterRemoval, .failBeforeRemoval:
        remaining.subtract(ids)
    case .incompleteRemoval(let stillPresent):
        remaining = stillPresent
    }
}

func containsBatch(withID id: SyncBatchID) throws -> Bool {
    verificationChecks.append(id)
    if case .failVerificationAfterRemoval = behavior {
        throw FileBackedSyncBatchQueue.QueueError.persistenceFailed
    }
    return remaining.contains(id)
}
}

final class FakeLegacyCleanupAdapter: SyncConvergenceLegacyCleanupAdapter {
struct Step {
    let result: SyncConvergencePostCommitAdapterResult
    let externalEffectOccurred: Bool
}

var script: [Step]
var requests: [SyncConvergencePostCommitRequest] = []
var externalEffectCount = 0
let recorder: PostCommitInvocationRecorder?

var callCount: Int {
    requests.count
}

init(result: SyncConvergencePostCommitAdapterResult, recorder: PostCommitInvocationRecorder? = nil) {
    self.script = [Step(result: result, externalEffectOccurred: result == .verifiedComplete)]
    self.recorder = recorder
}

init(script: [Step], recorder: PostCommitInvocationRecorder? = nil) {
    self.script = script
    self.recorder = recorder
}

func performLegacyCleanup(
    for request: SyncConvergencePostCommitRequest
) async -> SyncConvergencePostCommitAdapterResult {
    requests.append(request)
    recorder?.record(.legacyCleanup(batchID: request.sourceBatchID))
    let step = script.isEmpty ? Step(result: .verifiedComplete, externalEffectOccurred: true) : script.removeFirst()
    if step.externalEffectOccurred {
        externalEffectCount += 1
    }
    return step.result
}
}

final class FakePresentationAdapter: SyncConvergencePresentationAdapter {
struct Step {
    let result: SyncConvergencePostCommitAdapterResult
    let externalEffectOccurred: Bool
}

var defaultResult: SyncConvergencePostCommitAdapterResult
var scriptByNoteID: [UUID: [Step]] = [:]
var requests: [SyncConvergencePresentationRequest] = []
var externalEffectNoteIDs: [UUID] = []
let recorder: PostCommitInvocationRecorder?

init(result: SyncConvergencePostCommitAdapterResult, recorder: PostCommitInvocationRecorder? = nil) {
    self.defaultResult = result
    self.recorder = recorder
}

init(
    result: SyncConvergencePostCommitAdapterResult = .verifiedComplete,
    scriptByNoteID: [UUID: [Step]],
    recorder: PostCommitInvocationRecorder? = nil
) {
    self.defaultResult = result
    self.scriptByNoteID = scriptByNoteID
    self.recorder = recorder
}

func refreshPresentation(
    for request: SyncConvergencePresentationRequest
) async -> SyncConvergencePostCommitAdapterResult {
    requests.append(request)
    recorder?.record(.presentation(noteID: request.noteID))
    if var script = scriptByNoteID[request.noteID], !script.isEmpty {
        let step = script.removeFirst()
        scriptByNoteID[request.noteID] = script
        if step.externalEffectOccurred {
            externalEffectNoteIDs.append(request.noteID)
        }
        return step.result
    }
    if defaultResult == .verifiedComplete {
        externalEffectNoteIDs.append(request.noteID)
    }
    return defaultResult
}
}

actor TrackingPresentationAdapter: SyncConvergencePresentationAdapter {
var requests: [SyncConvergencePresentationRequest] = []
var activeCount = 0
var maxActiveCount = 0

func refreshPresentation(
    for request: SyncConvergencePresentationRequest
) async -> SyncConvergencePostCommitAdapterResult {
    activeCount += 1
    maxActiveCount = max(maxActiveCount, activeCount)
    requests.append(request)
    try? await Task.sleep(nanoseconds: 50_000_000)
    activeCount -= 1
    return .verifiedComplete
}

func requestCount() -> Int {
    requests.count
}

func maximumConcurrentRequests() -> Int {
    maxActiveCount
}
}

extension SyncConvergencePostCommitTests {
    func uuid(_ value: String) -> UUID {
        postCommitUUID(value)
    }

    func sha256Hex(_ data: Data) -> String {
        postCommitSHA256Hex(data)
    }
}
