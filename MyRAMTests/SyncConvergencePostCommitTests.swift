import XCTest
import SwiftData
#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

final class SyncConvergencePostCommitTests: XCTestCase {
    func testThrowingQueueRemovalRemovesExactlyRequestedIDsAndPreservesOrder() throws {
        let fileURL = temporaryQueueURL()
        let first = batch(id: uuid("00000000-0000-0000-0000-000000000001"))
        let second = batch(id: uuid("00000000-0000-0000-0000-000000000002"))
        let third = batch(id: uuid("00000000-0000-0000-0000-000000000003"))
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)
        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(third)

        try queue.removeBatches(withIDs: [second.id])

        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [first, third])
    }

    func testThrowingQueueRemovalRestoresExactQueueOnPersistenceFailure() throws {
        let fileURL = temporaryQueueURL()
        let first = batch(id: uuid("00000000-0000-0000-0000-000000000011"))
        let second = batch(id: uuid("00000000-0000-0000-0000-000000000012"))
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)
        queue.enqueue(first)
        queue.enqueue(second)

        queue.injectPersistenceFailureForNextWrite()

        XCTAssertThrowsError(try queue.removeBatches(withIDs: [first.id])) { error in
            XCTAssertEqual(error as? FileBackedSyncBatchQueue.QueueError, .persistenceFailed)
        }
        XCTAssertEqual(queue.pendingBatches, [first, second])
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [first, second])
    }

    func testNonthrowingQueueRemovalPreservesPriorInMemoryFailureSemantics() throws {
        let fileURL = temporaryQueueURL()
        let first = batch(id: uuid("00000000-0000-0000-0000-000000000021"))
        let second = batch(id: uuid("00000000-0000-0000-0000-000000000022"))
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)
        queue.enqueue(first)
        queue.enqueue(second)

        queue.injectPersistenceFailureForNextWrite()
        queue.removeAll(withIDs: [first.id])

        XCTAssertEqual(queue.pendingBatches, [second])
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [first, second])
    }

    func testCompletedPostCommitStateDoesNotCallAdaptersOrWrite() async {
        let identity = testIdentity()
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: .none)))
        let queue = FakeQueueCleanupAdapter()
        let legacy = FakeLegacyCleanupAdapter(result: .verifiedComplete)
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            legacyCleanupAdapter: legacy,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request(identity: identity))

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(queue.removals, [])
        XCTAssertEqual(legacy.callCount, 0)
        XCTAssertEqual(presentation.requests, [])
        XCTAssertEqual(store.writeCount, 0)
    }

    func testQueueFailureDoesNotBlockPresentationProgress() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state)))
        let queue = FakeQueueCleanupAdapter()
        queue.shouldThrowOnRemove = true
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .pending([.queueCleanup]))
        XCTAssertEqual(store.persistedState?.queueCleanupPending, true)
        XCTAssertEqual(store.persistedState?.presentationRefreshPending, false)
        XCTAssertEqual(presentation.requests.map(\.noteID), [TestIDs.noteA])
    }

    func testFakeStoreCASPreservesImmutableWorkPayloadAfterPartialClear() throws {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let original = fullRootState(identity: identity, state: state)
        let store = FakePostCommitStore(state: .fullRoot(original))
        let queueOnly = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: false
        )

        let loaded = try store.compareAndSetPostCommitState(
            expectedRoot: SyncConvergencePostCommitRootSnapshot(root: original.root),
            expectedPayloadData: original.postCommitStatePayloadData,
            newState: queueOnly
        )

        XCTAssertEqual(loaded.postCommitState, queueOnly)
        XCTAssertEqual(loaded.postCommitWorkPayloadData, original.postCommitWorkPayloadData)
        XCTAssertEqual(loaded.postCommitWorkPayload?.presentationEntries.count, 1)
        XCTAssertEqual(loaded.postCommitWorkPayload?.queueCleanupBatchIDs, [identity.batchID, TestIDs.extraBatch].sorted { $0.uuidString < $1.uuidString })
    }

    func testWorkPayloadAllowsClearedFlagsWithRetainedEvidence() throws {
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [TestIDs.batch],
            legacyCleanupRequired: false,
            presentationEntries: [workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)]
        )

        XCTAssertNoThrow(try payload.validateCurrentState(.none))
        XCTAssertNoThrow(try payload.validateCurrentState(SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: false
        )))
        XCTAssertThrowsError(try payload.validateCurrentState(SyncConvergencePostCommitState(
            queueCleanupPending: false,
            legacyCleanupPending: true,
            presentationRefreshPending: false
        )))
    }

    func testSwiftDataStoreReloadsAfterPartialAndFullClearWithRetainedWorkPayload() throws {
        let identity = testIdentity()
        let initialState = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let workPayload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [identity.batchID, TestIDs.extraBatch],
            legacyCleanupRequired: false,
            presentationEntries: [workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)]
        )
        let workPayloadData = try workPayload.encodedPayloadData()
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let contextA = ModelContext(container)
        let committedAt = Date(timeIntervalSince1970: 2)
        let orderingPayload = try CommittedAtOrderingPayload(
            batchID: identity.batchID,
            committedAt: committedAt
        ).encodedEvidenceData()
        contextA.insert(IncorporatedSyncBatch(
            batchID: identity.batchID,
            originDeviceID: TestIDs.device,
            createdAt: Date(timeIntervalSince1970: 1),
            batchSequence: 1,
            schemaVersion: 1,
            committedAt: committedAt,
            canonicalPayloadDigest: identity.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: identity.canonicalPayloadDigestFormatVersion,
            committedResultDigest: identity.committedResultDigest,
            committedResultDigestFormatVersion: identity.committedResultDigestFormatVersion,
            affectedNotesPayloadData: Data(),
            authoritativeChildCount: 0,
            authoritativeChildBytes: 0,
            authoritativeChildrenDigest: "children",
            postCommitWorkPayloadData: workPayloadData,
            postCommitStatePayloadData: try SyncConvergenceStableEncoding.encode(initialState)
        ))
        try contextA.save()

        let storeA = SwiftDataSyncConvergencePostCommitStore(context: contextA)
        guard case .fullRoot(let loadedA) = try storeA.loadState(matching: identity) else {
            return XCTFail("Expected full root")
        }
        XCTAssertEqual(loadedA.root.committedAtOrderingPayloadData, orderingPayload)
        let queueOnly = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: false
        )
        let clearedPresentation = try storeA.compareAndSetPostCommitState(
            expectedRoot: SyncConvergencePostCommitRootSnapshot(root: loadedA.root),
            expectedPayloadData: loadedA.postCommitStatePayloadData,
            newState: queueOnly
        )
        XCTAssertEqual(clearedPresentation.postCommitWorkPayloadData, workPayloadData)

        let storeB = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        guard case .fullRoot(let loadedB) = try storeB.loadState(matching: identity) else {
            return XCTFail("Expected partial-clear full root")
        }
        XCTAssertTrue(loadedB.postCommitState.queueCleanupPending)
        XCTAssertFalse(loadedB.postCommitState.presentationRefreshPending)
        XCTAssertEqual(loadedB.postCommitWorkPayload?.queueCleanupBatchIDs, [identity.batchID, TestIDs.extraBatch].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(loadedB.postCommitWorkPayload?.presentationEntries.count, 1)

        _ = try storeB.compareAndSetPostCommitState(
            expectedRoot: SyncConvergencePostCommitRootSnapshot(root: loadedB.root),
            expectedPayloadData: loadedB.postCommitStatePayloadData,
            newState: .none
        )
        let storeC = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        guard case .fullRoot(let loadedC) = try storeC.loadState(matching: identity) else {
            return XCTFail("Expected completed full root")
        }
        XCTAssertEqual(loadedC.postCommitState, .none)
        XCTAssertEqual(loadedC.postCommitWorkPayloadData, workPayloadData)
    }

    func testLegacyTrueWithoutAdapterRemainsPending() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: false,
            legacyCleanupPending: true,
            presentationRefreshPending: false
        )
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state)))
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: FakeQueueCleanupAdapter(),
            presentationAdapter: FakePresentationAdapter(result: .verifiedComplete)
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .pending([.legacyCleanup]))
        XCTAssertEqual(store.writeCount, 0)
    }

    func testPresentationRequestsUseAuthoritativeCommittedStateInDeterministicOrder() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: false,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let entries = [
            workEntry(noteID: TestIDs.noteB, routing: .wholeNoteFallback, postHash: SyncBatchContentHash.sha256Hex(for: "body-b")),
            workEntry(noteID: TestIDs.noteA, routing: .incremental, postHash: SyncBatchContentHash.sha256Hex(for: "body-a"))
        ]
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state, presentationEntries: entries)))
        store.notes[TestIDs.noteA] = note(id: TestIDs.noteA, title: "A", body: "body-a")
        store.notes[TestIDs.noteB] = note(id: TestIDs.noteB, title: "B", body: "body-b")
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: FakeQueueCleanupAdapter(),
            presentationAdapter: presentation
        )

        let plan = SyncConvergencePresentationPlan(noteRoutings: [
            TestIDs.noteB: .wholeNoteFallback,
            TestIDs.noteA: .incremental
        ])
        let outcome = await executor.execute(request(identity: identity, state: state, presentationPlan: plan))

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(presentation.requests.map(\.noteID), [TestIDs.noteA, TestIDs.noteB])
        XCTAssertEqual(presentation.requests[0].committedTitle, "A")
        XCTAssertEqual(presentation.requests[0].committedBodyHash, SyncBatchContentHash.sha256Hex(for: "body-a"))
        XCTAssertEqual(presentation.requests[0].expectedPreBodyHash, SyncBatchContentHash.sha256Hex(for: "pre"))
        XCTAssertEqual(presentation.requests[0].committedPostBodyHash, SyncBatchContentHash.sha256Hex(for: "body-a"))
    }

    func testCallerPlansCannotSuppressPersistedQueueOrPresentationWork() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let entries = [workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)]
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state, presentationEntries: entries)))
        let queue = FakeQueueCleanupAdapter()
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            presentationAdapter: presentation
        )

        let emptyCallerRequest = SyncConvergencePostCommitRequest(
            sourceBatchID: identity.batchID,
            affectedNoteIDs: [],
            cleanupPlan: SyncConvergenceCleanupPlan(
                batchIDs: [],
                retryQueueCleanup: false,
                retryLegacyCleanup: false,
                retryPresentationRefresh: false
            ),
            presentationPlan: SyncConvergencePresentationPlan(noteRoutings: [:]),
            persistedIncorporationIdentity: identity
        )
        let outcome = await executor.execute(emptyCallerRequest)

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(queue.removals, [[identity.batchID, TestIDs.extraBatch]])
        XCTAssertEqual(presentation.requests.map(\.noteID), [TestIDs.noteA])
    }

    func testTombstoneCleanupRemovesOnlyVerifiedSourceBatchID() async {
        let identity = testIdentity()
        let store = FakePostCommitStore(state: .tombstone(tombstone(identity: identity)))
        let queue = FakeQueueCleanupAdapter()
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            presentationAdapter: FakePresentationAdapter(result: .verifiedComplete)
        )

        let outcome = await executor.execute(request(identity: identity))

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(queue.removals, [[identity.batchID]])
        XCTAssertEqual(store.writeCount, 0)
    }

    func testPrePayloadPendingRootFailsClosedBeforeAdapters() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: false
        )
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state, includeWorkPayload: false)))
        let queue = FakeQueueCleanupAdapter()
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            presentationAdapter: FakePresentationAdapter(result: .verifiedComplete)
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .failedBeforeWork(.missingPostCommitWorkPayload(batchID: identity.batchID)))
        XCTAssertEqual(queue.removals, [])
        XCTAssertEqual(store.writeCount, 0)
    }

    func testSameExecutorInstanceSerializesOverlappingRuns() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: false,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state)))
        let presentation = TrackingPresentationAdapter()
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: FakeQueueCleanupAdapter(),
            presentationAdapter: presentation
        )

        async let first = executor.execute(request(identity: identity, state: state))
        async let second = executor.execute(request(identity: identity, state: state))
        let outcomes = await [first, second]
        let requestCount = await presentation.requestCount()
        let maximumConcurrentRequests = await presentation.maximumConcurrentRequests()

        XCTAssertEqual(outcomes, [.complete, .complete])
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(maximumConcurrentRequests, 1)
        XCTAssertEqual(store.writeCount, 1)
    }

    func testPersistedWorkPayloadProvesCurrentPathBDoesNotRequireLegacyCleanup() throws {
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [TestIDs.batch],
            legacyCleanupRequired: false,
            presentationEntries: [workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)]
        )
        let decoded = try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData(payload.encodedPayloadData())

        XCTAssertFalse(decoded.legacyCleanupRequired)
        XCTAssertFalse(decoded.derivedInitialState().legacyCleanupPending)
    }

    func testBodyHashCapabilityRemainsDisabled() {
        XCTAssertFalse(SyncBatchBodyHashCapability.defaultEnabled)
    }

    private func request(
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

    private func testIdentity() -> SyncConvergencePersistedIncorporationIdentity {
        SyncConvergencePersistedIncorporationIdentity(
            batchID: TestIDs.batch,
            canonicalPayloadDigest: "canonical",
            canonicalPayloadDigestFormatVersion: 1,
            committedResultDigest: "committed",
            committedResultDigestFormatVersion: 1
        )
    }

    private func fullRootState(
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

    private func workEntry(
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

    private func incrementalOperation(
        noteID: UUID,
        resultHash: String
    ) -> SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload {
        SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
            noteID: noteID,
            operationIndex: 0,
            kind: .insert,
            utf16Offset: 0,
            utf16Length: nil,
            text: "x",
            expectedText: nil,
            baseContentHash: nil,
            resultContentHash: resultHash,
            operationIdentity: OperationIdentityPayload(
                batchID: TestIDs.batch,
                originDeviceID: TestIDs.device,
                operationIndex: 0,
                operationKind: "insert",
                canonicalReplayKey: CanonicalReplayKeyPayload(
                    modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSince1970: 3)),
                    originDeviceIDLowercase: TestIDs.device.uuidString.lowercased(),
                    batchOrderKind: .legacy,
                    legacyCreatedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSince1970: 1)),
                    sequence: nil,
                    batchIDLowercase: TestIDs.batch.uuidString.lowercased(),
                    operationIndex: 0
                )
            )
        )
    }

    private func tombstone(
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

    private func note(id: UUID, title: String, body: String) -> SyncConvergenceMutableNoteRecord {
        SyncConvergenceMutableNoteRecord(
            noteID: id,
            folderID: nil,
            title: title,
            body: body,
            createdAt: Date(timeIntervalSince1970: 3),
            modifiedAt: Date(timeIntervalSince1970: 4)
        )
    }

    private func batch(id: UUID) -> SyncBatch {
        SyncBatch(
            id: id,
            originDeviceID: TestIDs.device,
            createdAt: Date(timeIntervalSince1970: 5),
            batchSequence: nil,
            changes: []
        )
    }

    private func temporaryQueueURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("queue.json")
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}

private enum TestIDs {
    static let batch = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    static let extraBatch = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    static let device = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    static let noteA = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    static let noteB = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
}

private final class FakePostCommitStore: SyncConvergencePostCommitStateStore {
    var state: SyncConvergencePostCommitLoadedState
    var notes: [UUID: SyncConvergenceMutableNoteRecord] = [:]
    var persistedState: SyncConvergencePostCommitState?
    var writeCount = 0

    init(state: SyncConvergencePostCommitLoadedState) {
        self.state = state
        notes[TestIDs.noteA] = SyncConvergenceMutableNoteRecord(
            noteID: TestIDs.noteA,
            folderID: nil,
            title: "Title",
            body: "Body",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
    }

    func loadState(
        matching identity: SyncConvergencePersistedIncorporationIdentity
    ) throws -> SyncConvergencePostCommitLoadedState {
        state
    }

    func loadCommittedNote(id: UUID) throws -> SyncConvergenceMutableNoteRecord? {
        notes[id]
    }

    func compareAndSetPostCommitState(
        expectedRoot: SyncConvergencePostCommitRootSnapshot,
        expectedPayloadData: Data,
        newState: SyncConvergencePostCommitState
    ) throws -> SyncConvergencePostCommitFullRootState {
        writeCount += 1
        persistedState = newState
        guard case .fullRoot(let current) = state,
              current.root == expectedRoot.root,
              current.postCommitStatePayloadData == expectedPayloadData else {
            throw SyncConvergencePostCommitFailure.inconsistentIncorporationIdentity(batchID: expectedRoot.root.batchID)
        }
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

    private func makeFullRootState(
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

private final class FakeQueueCleanupAdapter: SyncConvergenceQueueCleanupAdapter {
    var removals: [Set<SyncBatchID>] = []
    var remaining: Set<SyncBatchID> = []
    var shouldThrowOnRemove = false

    func removeBatches(withIDs ids: Set<SyncBatchID>) throws {
        if shouldThrowOnRemove {
            throw FileBackedSyncBatchQueue.QueueError.persistenceFailed
        }
        removals.append(ids)
        remaining.subtract(ids)
    }

    func containsBatch(withID id: SyncBatchID) throws -> Bool {
        remaining.contains(id)
    }
}

private final class FakeLegacyCleanupAdapter: SyncConvergenceLegacyCleanupAdapter {
    let result: SyncConvergencePostCommitAdapterResult
    var callCount = 0

    init(result: SyncConvergencePostCommitAdapterResult) {
        self.result = result
    }

    func performLegacyCleanup(
        for request: SyncConvergencePostCommitRequest
    ) async -> SyncConvergencePostCommitAdapterResult {
        callCount += 1
        return result
    }
}

private final class FakePresentationAdapter: SyncConvergencePresentationAdapter {
    let result: SyncConvergencePostCommitAdapterResult
    var requests: [SyncConvergencePresentationRequest] = []

    init(result: SyncConvergencePostCommitAdapterResult) {
        self.result = result
    }

    func refreshPresentation(
        for request: SyncConvergencePresentationRequest
    ) async -> SyncConvergencePostCommitAdapterResult {
        requests.append(request)
        return result
    }
}

private actor TrackingPresentationAdapter: SyncConvergencePresentationAdapter {
    private var requests: [SyncConvergencePresentationRequest] = []
    private var activeCount = 0
    private var maxActiveCount = 0

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
