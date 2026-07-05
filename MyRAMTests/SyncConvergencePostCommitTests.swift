import XCTest
import SwiftData
import CryptoKit
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
        XCTAssertEqual(clearedPresentation.root.postCommitWorkPayloadData, workPayloadData)
        assertRootProjection(
            clearedPresentation.root,
            equals: loadedA.root,
            replacingStatePayloadData: clearedPresentation.postCommitStatePayloadData
        )

        let storeB = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        guard case .fullRoot(let loadedB) = try storeB.loadState(matching: identity) else {
            return XCTFail("Expected partial-clear full root")
        }
        XCTAssertTrue(loadedB.postCommitState.queueCleanupPending)
        XCTAssertFalse(loadedB.postCommitState.presentationRefreshPending)
        XCTAssertEqual(loadedB.postCommitWorkPayload?.queueCleanupBatchIDs, [identity.batchID, TestIDs.extraBatch].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(loadedB.postCommitWorkPayload?.presentationEntries.count, 1)
        XCTAssertEqual(loadedB.postCommitWorkPayloadData, workPayloadData)
        assertRootProjection(
            loadedB.root,
            equals: loadedA.root,
            replacingStatePayloadData: clearedPresentation.postCommitStatePayloadData
        )

        let fullyCleared = try storeB.compareAndSetPostCommitState(
            expectedRoot: SyncConvergencePostCommitRootSnapshot(root: loadedB.root),
            expectedPayloadData: loadedB.postCommitStatePayloadData,
            newState: .none
        )
        XCTAssertEqual(fullyCleared.postCommitWorkPayloadData, workPayloadData)
        XCTAssertEqual(fullyCleared.root.postCommitWorkPayloadData, workPayloadData)
        assertRootProjection(
            fullyCleared.root,
            equals: loadedA.root,
            replacingStatePayloadData: fullyCleared.postCommitStatePayloadData
        )
        let storeC = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        guard case .fullRoot(let loadedC) = try storeC.loadState(matching: identity) else {
            return XCTFail("Expected completed full root")
        }
        XCTAssertEqual(loadedC.postCommitState, .none)
        XCTAssertEqual(loadedC.postCommitWorkPayloadData, workPayloadData)
        assertRootProjection(
            loadedC.root,
            equals: loadedA.root,
            replacingStatePayloadData: fullyCleared.postCommitStatePayloadData
        )
    }

    func testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation() throws {
        struct Case {
            let label: String
            let expectedFailure: SyncConvergencePostCommitFailure
            let mutate: (MYR136Fixture, ModelContext, IncorporatedSyncBatch) throws -> Void
        }

        let sourceBatchID = uuid("00000000-0000-0000-0000-000000135702")
        let cases: [Case] = [
            Case(
                label: "batchID",
                expectedFailure: .missingAuthoritativeIncorporation(batchID: sourceBatchID)
            ) { _, _, root in
                root.batchID = self.uuid("00000000-0000-0000-0000-000000136001")
            },
            Case(label: "originDeviceID", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.originDeviceID = self.uuid("00000000-0000-0000-0000-000000136002")
            },
            Case(label: "createdAt", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.setCreatedAt(Date(timeIntervalSince1970: 136_003))
            },
            Case(label: "batchSequence", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.batchSequence = (root.batchSequence ?? 0) + 136
            },
            Case(label: "schemaVersion", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.schemaVersion += 1
            },
            Case(label: "committedAt", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.setCommittedAt(Date(timeIntervalSince1970: 136_006))
            },
            Case(label: "canonicalPayloadDigest", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.canonicalPayloadDigest = "myr136-canonical-digest"
            },
            Case(label: "canonicalPayloadDigestFormatVersion", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.canonicalPayloadDigestFormatVersion += 1
            },
            Case(label: "committedResultDigest", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.committedResultDigest = "myr136-committed-result-digest"
            },
            Case(label: "committedResultDigestFormatVersion", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.committedResultDigestFormatVersion += 1
            },
            Case(label: "affectedNotesPayloadData", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.affectedNotesPayloadData = Data([0x13, 0x60, 0x11])
            },
            Case(label: "authoritativeChildCount", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.authoritativeChildCount += 1
            },
            Case(label: "authoritativeChildBytes", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.authoritativeChildBytes += 1
            },
            Case(label: "authoritativeChildrenDigest", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { _, _, root in
                root.authoritativeChildrenDigest = "myr136-authoritative-children"
            },
            Case(label: "postCommitWorkPayloadData", expectedFailure: .inconsistentIncorporationIdentity(batchID: sourceBatchID)) { fixture, _, root in
                root.postCommitWorkPayloadData = try SyncConvergencePostCommitWorkPayloadV1(
                    queueCleanupBatchIDs: [fixture.request.sourceBatchID],
                    legacyCleanupRequired: false,
                    presentationEntries: []
                ).encodedPayloadData()
            }
        ]

        XCTAssertEqual(cases.count, 15)
        for testCase in cases {
            let fixture = try makeMYR136Fixture()
            let mutationContext = ModelContext(fixture.container)
            let row = try fixture.rawRoot(context: mutationContext)
            try testCase.mutate(fixture, mutationContext, row)
            try mutationContext.save()
            let beforeCAS = try fixture.rawRootSnapshot()

            XCTAssertThrowsError(
                try fixture.store().compareAndSetPostCommitState(
                    expectedRoot: SyncConvergencePostCommitRootSnapshot(root: fixture.loaded.root),
                    expectedPayloadData: fixture.loaded.postCommitStatePayloadData,
                    newState: myr136StateC()
                ),
                testCase.label
            ) { error in
                XCTAssertEqual(error as? SyncConvergencePostCommitFailure, testCase.expectedFailure, testCase.label)
            }
            XCTAssertEqual(try fixture.rawRootSnapshot(), beforeCAS, testCase.label)
        }
    }

    func testMYR136DerivedCommittedAtOrderingPayloadMismatchRejectsCASWithoutMutation() throws {
        let fixture = try makeMYR136Fixture()
        let beforeCAS = try fixture.rawRootSnapshot()
        let alteredOrderingPayloadData = try CommittedAtOrderingPayload(
            batchID: fixture.request.sourceBatchID,
            committedAt: Date(timeIntervalSince1970: 136_016)
        ).encodedEvidenceData()
        let staleRoot = copyRootProjection(
            fixture.loaded.root,
            committedAtOrderingPayloadData: alteredOrderingPayloadData
        )

        XCTAssertThrowsError(
            try fixture.store().compareAndSetPostCommitState(
                expectedRoot: SyncConvergencePostCommitRootSnapshot(root: staleRoot),
                expectedPayloadData: fixture.loaded.postCommitStatePayloadData,
                newState: myr136StateC()
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncConvergencePostCommitFailure,
                .inconsistentIncorporationIdentity(batchID: fixture.request.sourceBatchID)
            )
        }
        XCTAssertEqual(try fixture.rawRootSnapshot(), beforeCAS)
    }

    func testMYR136StaleExpectedStatePayloadRejectsCASWithoutMutation() throws {
        let fixture = try makeMYR136Fixture()
        let stateAData = fixture.loaded.postCommitStatePayloadData
        let stateB = myr136StateB()
        let stateC = myr136StateC()
        let afterStateB = try fixture.store().compareAndSetPostCommitState(
            expectedRoot: SyncConvergencePostCommitRootSnapshot(root: fixture.loaded.root),
            expectedPayloadData: stateAData,
            newState: stateB
        )
        let stateBRow = try fixture.rawRootSnapshot()

        XCTAssertThrowsError(
            try fixture.store().compareAndSetPostCommitState(
                expectedRoot: SyncConvergencePostCommitRootSnapshot(root: afterStateB.root),
                expectedPayloadData: stateAData,
                newState: stateC
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncConvergencePostCommitFailure,
                .inconsistentIncorporationIdentity(batchID: fixture.request.sourceBatchID)
            )
        }
        XCTAssertEqual(try fixture.rawRootSnapshot(), stateBRow)
        XCTAssertEqual(
            try SyncConvergenceStableEncoding.decode(
                SyncConvergencePostCommitState.self,
                from: stateBRow.postCommitStatePayloadData
            ),
            stateB
        )
    }

    func testMYR136MatchingRootAndPriorStateCASChangesOnlyMutableState() throws {
        let fixture = try makeMYR136Fixture()
        let beforeCAS = try fixture.rawRootSnapshot()
        let stateB = myr136StateB()
        let expectedStateBData = try SyncConvergenceStableEncoding.encode(stateB)

        let afterCAS = try fixture.store().compareAndSetPostCommitState(
            expectedRoot: SyncConvergencePostCommitRootSnapshot(root: fixture.loaded.root),
            expectedPayloadData: fixture.loaded.postCommitStatePayloadData,
            newState: stateB
        )

        XCTAssertEqual(afterCAS.postCommitState, stateB)
        XCTAssertEqual(afterCAS.postCommitStatePayloadData, expectedStateBData)
        XCTAssertEqual(afterCAS.root.postCommitStatePayloadData, expectedStateBData)
        assertRootProjection(
            afterCAS.root,
            equals: fixture.loaded.root,
            replacingStatePayloadData: expectedStateBData
        )

        let afterRow = try fixture.rawRootSnapshot()
        XCTAssertNotEqual(afterRow.postCommitStatePayloadData, beforeCAS.postCommitStatePayloadData)
        XCTAssertEqual(afterRow, beforeCAS.replacingPostCommitStatePayloadData(expectedStateBData))
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

    func testEightPendingStateMatrixWithLegacyAdapterPinsSingleCASEffects() async {
        struct Case {
            let name: String
            let state: SyncConvergencePostCommitState
            let expectedOutcome: SyncConvergencePostCommitOutcome
            let expectedEvents: [PostCommitInvocationEvent]
            let expectedPersistedState: SyncConvergencePostCommitState?
        }

        let cases = [
            Case(
                name: "none pending",
                state: .none,
                expectedOutcome: .complete,
                expectedEvents: [],
                expectedPersistedState: nil
            ),
            Case(
                name: "queue only",
                state: SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: false, presentationRefreshPending: false),
                expectedOutcome: .complete,
                expectedEvents: [.queueCleanup([TestIDs.batch, TestIDs.extraBatch])],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "legacy only",
                state: SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: false),
                expectedOutcome: .complete,
                expectedEvents: [.legacyCleanup(batchID: TestIDs.batch)],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "presentation only",
                state: SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: false, presentationRefreshPending: true),
                expectedOutcome: .complete,
                expectedEvents: [.presentation(noteID: TestIDs.noteA)],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "queue legacy",
                state: SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: true, presentationRefreshPending: false),
                expectedOutcome: .complete,
                expectedEvents: [.queueCleanup([TestIDs.batch, TestIDs.extraBatch]), .legacyCleanup(batchID: TestIDs.batch)],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "queue presentation",
                state: SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: false, presentationRefreshPending: true),
                expectedOutcome: .complete,
                expectedEvents: [.queueCleanup([TestIDs.batch, TestIDs.extraBatch]), .presentation(noteID: TestIDs.noteA)],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "legacy presentation",
                state: SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: true),
                expectedOutcome: .complete,
                expectedEvents: [.legacyCleanup(batchID: TestIDs.batch), .presentation(noteID: TestIDs.noteA)],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "all pending",
                state: SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: true, presentationRefreshPending: true),
                expectedOutcome: .complete,
                expectedEvents: [
                    .queueCleanup([TestIDs.batch, TestIDs.extraBatch]),
                    .legacyCleanup(batchID: TestIDs.batch),
                    .presentation(noteID: TestIDs.noteA)
                ],
                expectedPersistedState: SyncConvergencePostCommitState.none
            )
        ]

        for testCase in cases {
            let identity = testIdentity()
            let persistedEntry = workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)
            let committedNote = note(id: TestIDs.noteA, title: "Matrix", body: "post")
            let store = FakePostCommitStore(
                state: .fullRoot(fullRootState(
                    identity: identity,
                    state: testCase.state,
                    presentationEntries: testCase.state.presentationRefreshPending ? [persistedEntry] : []
                ))
            )
            store.notes[TestIDs.noteA] = committedNote
            let recorder = PostCommitInvocationRecorder()
            let queue = FakeQueueCleanupAdapter(recorder: recorder)
            let legacy = FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: recorder)
            let presentation = FakePresentationAdapter(result: .verifiedComplete, recorder: recorder)
            let executor = SyncConvergencePostCommitExecutor(
                store: store,
                queueCleanupAdapter: queue,
                legacyCleanupAdapter: legacy,
                presentationAdapter: presentation
            )

            let outcome = await executor.execute(request(identity: identity, state: testCase.state))

            XCTAssertEqual(outcome, testCase.expectedOutcome, testCase.name)
            XCTAssertEqual(recorder.events, testCase.expectedEvents, testCase.name)
            XCTAssertEqual(queue.removals, testCase.state.queueCleanupPending ? [[TestIDs.batch, TestIDs.extraBatch]] : [], testCase.name)
            XCTAssertEqual(legacy.requests.map(\.sourceBatchID), testCase.state.legacyCleanupPending ? [TestIDs.batch] : [], testCase.name)
            XCTAssertEqual(
                presentation.requests,
                testCase.state.presentationRefreshPending
                    ? [expectedPresentationRequest(identity: identity, entry: persistedEntry, committedNote: committedNote)]
                    : [],
                testCase.name
            )
            XCTAssertEqual(store.persistedState, testCase.expectedPersistedState, testCase.name)
            XCTAssertEqual(store.currentWorkPayloadData, store.originalWorkPayloadData, testCase.name)
            XCTAssertEqual(store.writeCount, testCase.expectedPersistedState == nil ? 0 : 1, testCase.name)
        }
    }

    func testEightPendingStateMatrixWithoutLegacyAdapterLeavesLegacyPending() async {
        let states: [(SyncConvergencePostCommitState, SyncConvergencePostCommitState?)] = [
            (
                SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: false),
                nil
            ),
            (
                SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: true, presentationRefreshPending: false),
                SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: false)
            ),
            (
                SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: true),
                SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: false)
            ),
            (
                SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: true, presentationRefreshPending: true),
                SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: false)
            )
        ]

        for (state, expectedPersistedState) in states {
            let identity = testIdentity()
            let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state)))
            let recorder = PostCommitInvocationRecorder()
            let queue = FakeQueueCleanupAdapter(recorder: recorder)
            let presentation = FakePresentationAdapter(result: .verifiedComplete, recorder: recorder)
            let executor = SyncConvergencePostCommitExecutor(
                store: store,
                queueCleanupAdapter: queue,
                presentationAdapter: presentation
            )

            let outcome = await executor.execute(request(identity: identity, state: state))

            XCTAssertEqual(outcome, .pending([.legacyCleanup]))
            var expectedEvents: [PostCommitInvocationEvent] = []
            if state.queueCleanupPending {
                expectedEvents.append(.queueCleanup([TestIDs.batch, TestIDs.extraBatch]))
            }
            if state.presentationRefreshPending {
                expectedEvents.append(.presentation(noteID: TestIDs.noteA))
            }
            XCTAssertEqual(recorder.events, expectedEvents)
            XCTAssertEqual(store.persistedState, expectedPersistedState)
            XCTAssertEqual(store.currentWorkPayloadData, store.originalWorkPayloadData)
            XCTAssertEqual(store.writeCount, expectedPersistedState == nil ? 0 : 1)
        }
    }

    func testFinalCASFailureThenFreshStoreRetryRerunsIdempotentWorkAndCompletes() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )
        let committedNote = note(id: TestIDs.noteA, title: "Retry", body: "Body")
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state)))
        store.notes[TestIDs.noteA] = committedNote
        store.shouldFailCAS = true
        let recorder = PostCommitInvocationRecorder()
        let queue = FakeQueueCleanupAdapter(recorder: recorder)
        let legacy = FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: recorder)
        let presentation = FakePresentationAdapter(result: .verifiedComplete, recorder: recorder)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            legacyCleanupAdapter: legacy,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .pending([.queueCleanup, .legacyCleanup, .presentationRefresh, .postCommitStatePersistence]))
        XCTAssertEqual(recorder.events, [
            .queueCleanup([TestIDs.batch, TestIDs.extraBatch]),
            .legacyCleanup(batchID: TestIDs.batch),
            .presentation(noteID: TestIDs.noteA)
        ])
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(store.persistedState, nil)
        XCTAssertEqual(store.currentPostCommitState, state)
        XCTAssertEqual(store.currentWorkPayloadData, store.originalWorkPayloadData)

        guard case .fullRoot(let persistedRoot) = store.state else {
            return XCTFail("Expected failed-CAS store to retain full root")
        }
        let persistedStateBytes = Data(persistedRoot.root.postCommitStatePayloadData)
        let persistedWorkBytes = Data(try! XCTUnwrap(persistedRoot.root.postCommitWorkPayloadData))
        let retryStore = try! FakePostCommitStore(
            reloading: persistedRoot.root,
            notes: [TestIDs.noteA: committedNote]
        )
        XCTAssertEqual(retryStore.currentPostCommitState, state)
        XCTAssertEqual(retryStore.currentWorkPayloadData, persistedWorkBytes)
        guard case .fullRoot(let reloadedRoot) = retryStore.state else {
            return XCTFail("Expected reloaded retry store to contain a full root")
        }
        XCTAssertEqual(reloadedRoot.postCommitStatePayloadData, persistedStateBytes)
        XCTAssertEqual(reloadedRoot.postCommitWorkPayloadData, persistedWorkBytes)
        let retryRecorder = PostCommitInvocationRecorder()
        let retryQueue = FakeQueueCleanupAdapter(recorder: retryRecorder)
        let retryLegacy = FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: retryRecorder)
        let retryPresentation = FakePresentationAdapter(result: .verifiedComplete, recorder: retryRecorder)
        let retryExecutor = SyncConvergencePostCommitExecutor(
            store: retryStore,
            queueCleanupAdapter: retryQueue,
            legacyCleanupAdapter: retryLegacy,
            presentationAdapter: retryPresentation
        )

        let retryOutcome = await retryExecutor.execute(request(identity: identity, state: state))

        XCTAssertEqual(retryOutcome, .complete)
        XCTAssertEqual(retryRecorder.events, [
            .queueCleanup([TestIDs.batch, TestIDs.extraBatch]),
            .legacyCleanup(batchID: TestIDs.batch),
            .presentation(noteID: TestIDs.noteA)
        ])
        XCTAssertEqual(retryStore.persistedState, Optional(SyncConvergencePostCommitState.none))
        XCTAssertEqual(retryStore.currentPostCommitState, Optional(SyncConvergencePostCommitState.none))
        XCTAssertEqual(retryStore.writeCount, 1)
        XCTAssertEqual(retryStore.currentWorkPayloadData, retryStore.originalWorkPayloadData)
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
        let incrementalEntry = entries[1]
        let fallbackEntry = entries[0]
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state, presentationEntries: entries)))
        let noteA = note(id: TestIDs.noteA, title: "A", body: "body-a")
        let noteB = note(id: TestIDs.noteB, title: "B", body: "body-b")
        store.notes[TestIDs.noteA] = noteA
        store.notes[TestIDs.noteB] = noteB
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
        XCTAssertEqual(presentation.requests, [
            expectedPresentationRequest(identity: identity, entry: incrementalEntry, committedNote: noteA),
            expectedPresentationRequest(identity: identity, entry: fallbackEntry, committedNote: noteB)
        ])
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

    func testPostCommitPayloadRejectsMalformedOperationIdentity() {
        let postHash = SyncBatchContentHash.sha256Hex(for: "post")
        let operation = incrementalOperation(noteID: TestIDs.noteA, resultHash: postHash)
        let malformedIdentity = OperationIdentityPayload(
            version: OperationIdentityPayload.supportedVersion + 1,
            batchID: TestIDs.batch,
            originDeviceID: TestIDs.device,
            operationIndex: operation.operationIndex,
            operationKind: operation.kind.rawValue,
            canonicalReplayKey: operation.operationIdentity.canonicalReplayKey
        )
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [],
            legacyCleanupRequired: false,
            presentationEntries: [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: postHash,
                    incrementalOperations: [
                        SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
                            noteID: operation.noteID,
                            operationIndex: operation.operationIndex,
                            kind: operation.kind,
                            utf16Offset: operation.utf16Offset,
                            utf16Length: operation.utf16Length,
                            text: operation.text,
                            expectedText: operation.expectedText,
                            baseContentHash: operation.baseContentHash,
                            resultContentHash: operation.resultContentHash,
                            operationIdentity: malformedIdentity
                        )
                    ]
                )
            ]
        )

        XCTAssertThrowsError(try payload.encodedPayloadData())
    }

    func testPostCommitPayloadRejectsOperationHashChainMismatch() {
        let firstHash = SyncBatchContentHash.sha256Hex(for: "first")
        let finalHash = SyncBatchContentHash.sha256Hex(for: "final")
        let wrongBaseHash = SyncBatchContentHash.sha256Hex(for: "wrong")
        let first = incrementalOperation(noteID: TestIDs.noteA, resultHash: firstHash)
        let secondIdentity = OperationIdentityPayload(
            batchID: TestIDs.batch,
            originDeviceID: TestIDs.device,
            operationIndex: 1,
            operationKind: "insert",
            canonicalReplayKey: CanonicalReplayKeyPayload(
                modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSince1970: 4)),
                originDeviceIDLowercase: TestIDs.device.uuidString.lowercased(),
                batchOrderKind: .legacy,
                legacyCreatedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSince1970: 1)),
                sequence: nil,
                batchIDLowercase: TestIDs.batch.uuidString.lowercased(),
                operationIndex: 1
            )
        )
        let second = SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
            noteID: TestIDs.noteA,
            operationIndex: 1,
            kind: .insert,
            utf16Offset: 1,
            utf16Length: nil,
            text: "y",
            expectedText: nil,
            baseContentHash: wrongBaseHash,
            resultContentHash: finalHash,
            operationIdentity: secondIdentity
        )
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [],
            legacyCleanupRequired: false,
            presentationEntries: [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: finalHash,
                    incrementalOperations: [first, second]
                )
            ]
        )

        XCTAssertThrowsError(try payload.encodedPayloadData())
    }

    func testPostCommitPayloadRejectsMissingFirstBaseHashWhenExpectedPreHashExists() {
        let expectedPreHash = SyncBatchContentHash.sha256Hex(for: "A")
        let postHash = SyncBatchContentHash.sha256Hex(for: "AB")
        let operation = incrementalOperation(
            noteID: TestIDs.noteA,
            operationIndex: 0,
            utf16Offset: 1,
            text: "B",
            baseHash: nil,
            resultHash: postHash
        )
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [],
            legacyCleanupRequired: false,
            presentationEntries: [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: expectedPreHash,
                    committedPostBodyHash: postHash,
                    incrementalOperations: [operation]
                )
            ]
        )

        XCTAssertThrowsError(try payload.encodedPayloadData())
    }

    func testPostCommitPayloadRejectsMissingIntermediateBaseHash() {
        let firstHash = SyncBatchContentHash.sha256Hex(for: "AB")
        let finalHash = SyncBatchContentHash.sha256Hex(for: "ABC")
        let first = incrementalOperation(
            noteID: TestIDs.noteA,
            operationIndex: 0,
            utf16Offset: 1,
            text: "B",
            baseHash: SyncBatchContentHash.sha256Hex(for: "A"),
            resultHash: firstHash
        )
        let second = incrementalOperation(
            noteID: TestIDs.noteA,
            operationIndex: 1,
            utf16Offset: 2,
            text: "C",
            baseHash: nil,
            resultHash: finalHash
        )
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [],
            legacyCleanupRequired: false,
            presentationEntries: [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: "A"),
                    committedPostBodyHash: finalHash,
                    incrementalOperations: [first, second]
                )
            ]
        )

        XCTAssertThrowsError(try payload.encodedPayloadData())
    }

    func testPostCommitPayloadAllowsMissingExpectedPreHashAndMissingFirstBaseHash() {
        let postHash = SyncBatchContentHash.sha256Hex(for: "AB")
        let operation = incrementalOperation(
            noteID: TestIDs.noteA,
            operationIndex: 0,
            utf16Offset: 1,
            text: "B",
            baseHash: nil,
            resultHash: postHash
        )
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [],
            legacyCleanupRequired: false,
            presentationEntries: [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: postHash,
                    incrementalOperations: [operation]
                )
            ]
        )

        XCTAssertNoThrow(try payload.encodedPayloadData())
    }

    func testMYR135PostCommitPayloadIdentityValidationMatrix() throws {
        let postHash = SyncBatchContentHash.sha256Hex(for: "post")
        let valid = incrementalOperation(noteID: TestIDs.noteA, resultHash: postHash)
        let validPayload = payload(entryNoteID: TestIDs.noteA, committedPostBodyHash: postHash, operations: [valid])
        let encoded = try validPayload.encodedPayloadData()
        XCTAssertEqual(try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData(encoded), validPayload)

        let otherUUID = uuid("00000000-0000-0000-0000-000000135501")
        let letterBatchID = uuid("abcdefab-cdef-abcd-efab-cdefabcdefab")
        let letterOriginID = uuid("fedcbafe-dcba-fedc-bafe-dcbafedcbafe")
        let letterBearingIdentity = valid.operationIdentity.replacingForTest(
            batchID: letterBatchID,
            originDeviceID: letterOriginID,
            canonicalReplayKey: valid.operationIdentity.canonicalReplayKey.replacingForTest(
                originDeviceID: letterOriginID,
                batchID: letterBatchID
            )
        )
        let letterBearingValid = valid.replacingForTest(operationIdentity: letterBearingIdentity)
        XCTAssertNoThrow(
            try payload(
                entryNoteID: TestIDs.noteA,
                committedPostBodyHash: postHash,
                operations: [letterBearingValid]
            ).encodedPayloadData()
        )

        let uppercaseOuterBatch = letterBearingValid.operationIdentity.batchIDLowercase.uppercased()
        XCTAssertNotEqual(uppercaseOuterBatch, letterBearingValid.operationIdentity.batchIDLowercase)
        let uppercaseOuterOrigin = letterBearingValid.operationIdentity.originDeviceIDLowercase.uppercased()
        XCTAssertNotEqual(uppercaseOuterOrigin, letterBearingValid.operationIdentity.originDeviceIDLowercase)
        let uppercaseNestedBatch = letterBearingValid.operationIdentity.canonicalReplayKey.batchIDLowercase.uppercased()
        XCTAssertNotEqual(uppercaseNestedBatch, letterBearingValid.operationIdentity.canonicalReplayKey.batchIDLowercase)

        let cases: [(String, SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload)] = [
            (
                "unsupported identity version",
                valid.replacingForTest(operationIdentity: valid.operationIdentity.replacingForTest(version: OperationIdentityPayload.supportedVersion + 1))
            ),
            (
                "malformed outer batch UUID string",
                valid.replacingForTest(operationIdentity: try valid.operationIdentity.replacingRawStringsForTest(batchIDLowercase: "not-a-uuid"))
            ),
            (
                "malformed outer origin UUID string",
                valid.replacingForTest(operationIdentity: try valid.operationIdentity.replacingRawStringsForTest(originDeviceIDLowercase: "not-a-uuid"))
            ),
            (
                "uppercase outer batch UUID string",
                letterBearingValid.replacingForTest(operationIdentity: try letterBearingValid.operationIdentity.replacingRawStringsForTest(
                    batchIDLowercase: uppercaseOuterBatch
                ))
            ),
            (
                "uppercase outer origin UUID string",
                letterBearingValid.replacingForTest(operationIdentity: try letterBearingValid.operationIdentity.replacingRawStringsForTest(
                    originDeviceIDLowercase: uppercaseOuterOrigin
                ))
            ),
            (
                "malformed nested replay-key UUID string",
                valid.replacingForTest(operationIdentity: try valid.operationIdentity.replacingRawStringsForTest(
                    canonicalReplayKeyBatchIDLowercase: "not-a-uuid"
                ))
            ),
            (
                "uppercase nested replay-key UUID string",
                letterBearingValid.replacingForTest(operationIdentity: try letterBearingValid.operationIdentity.replacingRawStringsForTest(
                    canonicalReplayKeyBatchIDLowercase: uppercaseNestedBatch
                ))
            ),
            (
                "negative operation index",
                valid.replacingForTest(operationIndex: -1, operationIdentity: valid.operationIdentity.replacingForTest(operationIndex: -1))
            ),
            (
                "work operation index mismatch",
                valid.replacingForTest(operationIndex: 1)
            ),
            (
                "work operation kind mismatch",
                valid.replacingForTest(kind: .delete, utf16Length: 1, text: nil, expectedText: "x")
            ),
            (
                "identity replay key batch mismatch",
                valid.replacingForTest(operationIdentity: valid.operationIdentity.replacingForTest(
                    canonicalReplayKey: valid.operationIdentity.canonicalReplayKey.replacingForTest(batchID: otherUUID)
                ))
            ),
            (
                "identity replay key origin mismatch",
                valid.replacingForTest(operationIdentity: valid.operationIdentity.replacingForTest(
                    canonicalReplayKey: valid.operationIdentity.canonicalReplayKey.replacingForTest(originDeviceID: otherUUID)
                ))
            ),
            (
                "identity replay key index mismatch",
                valid.replacingForTest(operationIdentity: valid.operationIdentity.replacingForTest(
                    canonicalReplayKey: valid.operationIdentity.canonicalReplayKey.replacingForTest(operationIndex: 1)
                ))
            )
        ]

        for testCase in cases {
            XCTAssertThrowsError(
                try payload(entryNoteID: TestIDs.noteA, committedPostBodyHash: postHash, operations: [testCase.1]).encodedPayloadData(),
                testCase.0
            )
        }

        XCTAssertThrowsError(
            try payload(entryNoteID: TestIDs.noteB, committedPostBodyHash: postHash, operations: [valid]).encodedPayloadData(),
            "operation note entry note mismatch"
        )
    }

    func testMYR135OperationHashChainValidationMatrix() throws {
        let expectedPreHash = SyncBatchContentHash.sha256Hex(for: "A")
        let firstHash = SyncBatchContentHash.sha256Hex(for: "AB")
        let finalHash = SyncBatchContentHash.sha256Hex(for: "ABC")
        let first = incrementalOperation(
            noteID: TestIDs.noteA,
            operationIndex: 0,
            utf16Offset: 1,
            text: "B",
            baseHash: expectedPreHash,
            resultHash: firstHash
        )
        let second = incrementalOperation(
            noteID: TestIDs.noteA,
            operationIndex: 1,
            utf16Offset: 2,
            text: "C",
            baseHash: firstHash,
            resultHash: finalHash
        )
        let control = payload(
            entryNoteID: TestIDs.noteA,
            expectedPreBodyHash: expectedPreHash,
            committedPostBodyHash: finalHash,
            operations: [first, second]
        )
        XCTAssertNoThrow(try control.encodedPayloadData())

        let wrongHash = SyncBatchContentHash.sha256Hex(for: "wrong")
        let cases = [
            (
                "first operation base hash differs from expected pre body hash",
                [first.replacingForTest(baseContentHash: wrongHash), second]
            ),
            (
                "later operation base hash differs from preceding result hash",
                [first, second.replacingForTest(baseContentHash: wrongHash)]
            ),
            (
                "final operation result hash differs from committed post body hash",
                [first, second.replacingForTest(resultContentHash: wrongHash)]
            )
        ]

        for testCase in cases {
            XCTAssertThrowsError(
                try payload(
                    entryNoteID: TestIDs.noteA,
                    expectedPreBodyHash: expectedPreHash,
                    committedPostBodyHash: finalHash,
                    operations: testCase.1
                ).encodedPayloadData(),
                testCase.0
            )
        }
    }

    func testMYR135ValidPersistedIdentityRowLoadsAndReachesPresentation() async throws {
        let fixture = try makeMYR135PersistedIdentityFixture()
        let row = try fixture.authoritativeRow()
        let operation = try XCTUnwrap(fixture.workPayload.presentationEntries.first?.incrementalOperations.first)

        XCTAssertEqual(row.identityKey, SyncConvergenceKey.batchOperationIdentity(batchID: fixture.request.sourceBatchID, operationIndex: operation.operationIndex))
        XCTAssertEqual(row.batchID, fixture.request.sourceBatchID)
        XCTAssertEqual(row.noteID, fixture.noteID)
        XCTAssertEqual(row.operationIndex, operation.operationIndex)
        XCTAssertEqual(row.payloadUTF8ByteCount, row.operationIdentityPayloadData.count + row.canonicalReplayKeyPayloadData.count)
        XCTAssertEqual(try OperationIdentityPayload.decodePayloadData(row.operationIdentityPayloadData), operation.operationIdentity)
        XCTAssertEqual(try CanonicalReplayKeyPayload.decodeEvidenceData(row.canonicalReplayKeyPayloadData), operation.operationIdentity.canonicalReplayKey)

        let queue = FakeQueueCleanupAdapter()
        let legacy = FakeLegacyCleanupAdapter(result: .verifiedComplete)
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        let executor = SyncConvergencePostCommitExecutor(
            store: SwiftDataSyncConvergencePostCommitStore(context: ModelContext(fixture.container)),
            queueCleanupAdapter: queue,
            legacyCleanupAdapter: legacy,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(fixture.request)

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(queue.removals, [Set([fixture.request.sourceBatchID])])
        XCTAssertEqual(legacy.callCount, 1)
        XCTAssertEqual(presentation.requests.map(\.noteID), [fixture.noteID])
        XCTAssertEqual(presentation.requests.first?.incrementalOperations, [operation])
    }

    func testMYR135PersistedIdentityRowCorruptionFailsBeforeAdapters() async throws {
        struct Case {
            let name: String
            let corrupt: (MYR135PersistedIdentityFixture, ModelContext, IncorporatedBatchOperationIdentity) throws -> Void
        }

        let otherUUID = uuid("00000000-0000-0000-0000-000000135601")
        let cases: [Case] = [
            Case(name: "wrong persisted row note ID") { _, _, row in
                row.noteID = otherUUID
            },
            Case(name: "wrong persisted row batch ID") { _, _, row in
                row.batchID = otherUUID
            },
            Case(name: "wrong persisted row operation index") { _, _, row in
                row.operationIndex = 99
            },
            Case(name: "wrong persisted row kind") { fixture, _, row in
                let identity = try fixture.workOperation().operationIdentity.replacingForTest(operationKind: "delete")
                row.operationIdentityPayloadData = try identity.encodedPayloadData()
                row.payloadUTF8ByteCount = row.operationIdentityPayloadData.count + row.canonicalReplayKeyPayloadData.count
            },
            Case(name: "wrong persisted identity bytes") { _, _, row in
                row.operationIdentityPayloadData = Data([0xde, 0xad])
            },
            Case(name: "valid but substituted identity bytes") { fixture, _, row in
                let identity = try fixture.workOperation().operationIdentity.replacingForTest(originDeviceID: otherUUID)
                row.operationIdentityPayloadData = try identity.encodedPayloadData()
                row.payloadUTF8ByteCount = row.operationIdentityPayloadData.count + row.canonicalReplayKeyPayloadData.count
            },
            Case(name: "wrong persisted replay key bytes") { fixture, _, row in
                let replayKey = try fixture.workOperation().operationIdentity.canonicalReplayKey.replacingForTest(originDeviceID: otherUUID)
                row.canonicalReplayKeyPayloadData = try replayKey.encodedEvidenceData()
                row.payloadUTF8ByteCount = row.operationIdentityPayloadData.count + row.canonicalReplayKeyPayloadData.count
            },
            Case(name: "missing persisted identity row") { _, context, row in
                context.delete(row)
            },
            Case(name: "duplicate persisted identity rows") { fixture, context, row in
                let duplicate = IncorporatedBatchOperationIdentity(
                    batchID: row.batchID,
                    noteID: row.noteID,
                    operationIndex: 99,
                    operationIdentityPayloadData: row.operationIdentityPayloadData,
                    canonicalReplayKeyPayloadData: row.canonicalReplayKeyPayloadData
                )
                duplicate.identityKey = "\(row.identityKey)|duplicate"
                duplicate.operationIndex = row.operationIndex
                context.insert(duplicate)
                _ = fixture
            },
            Case(name: "noncanonical persisted identity key") { _, _, row in
                row.identityKey = "\(row.identityKey)|corrupt"
            },
            Case(name: "wrong stored byte count") { _, _, row in
                row.payloadUTF8ByteCount += 1
            }
        ]

        for testCase in cases {
            let fixture = try makeMYR135PersistedIdentityFixture()
            let corruptionContext = ModelContext(fixture.container)
            let row = try fixture.authoritativeRow(context: corruptionContext)
            try testCase.corrupt(fixture, corruptionContext, row)
            try corruptionContext.save()
            let rootSnapshotBeforeExecution = try fixture.rootSnapshot()

            let queue = FakeQueueCleanupAdapter()
            let legacy = FakeLegacyCleanupAdapter(result: .verifiedComplete)
            let presentation = FakePresentationAdapter(result: .verifiedComplete)
            let store = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(fixture.container))
            let executor = SyncConvergencePostCommitExecutor(
                store: store,
                queueCleanupAdapter: queue,
                legacyCleanupAdapter: legacy,
                presentationAdapter: presentation
            )

            let outcome = await executor.execute(fixture.request)
            let rootSnapshotAfterExecution = try fixture.rootSnapshot()

            XCTAssertEqual(
                outcome,
                .failedBeforeWork(.malformedPostCommitWorkPayload(batchID: fixture.request.sourceBatchID)),
                testCase.name
            )
            XCTAssertEqual(queue.removals, [], testCase.name)
            XCTAssertEqual(legacy.callCount, 0, testCase.name)
            XCTAssertEqual(presentation.requests, [], testCase.name)
            XCTAssertEqual(rootSnapshotAfterExecution, rootSnapshotBeforeExecution, testCase.name)
            XCTAssertEqual(try fixture.reloadedNoteBody(), "AB", testCase.name)
        }
    }

    func testPostCommitPayloadValidationMatrixRejectsContradictoryPresentationEntries() {
        let postHash = SyncBatchContentHash.sha256Hex(for: "post")
        let base = incrementalOperation(noteID: TestIDs.noteA, resultHash: postHash)
        let wrongNote = SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
            noteID: TestIDs.noteB,
            operationIndex: base.operationIndex,
            kind: base.kind,
            utf16Offset: base.utf16Offset,
            utf16Length: base.utf16Length,
            text: base.text,
            expectedText: base.expectedText,
            baseContentHash: base.baseContentHash,
            resultContentHash: base.resultContentHash,
            operationIdentity: base.operationIdentity
        )
        let wrongKindIdentity = SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
            noteID: base.noteID,
            operationIndex: base.operationIndex,
            kind: .delete,
            utf16Offset: base.utf16Offset,
            utf16Length: 1,
            text: nil,
            expectedText: "x",
            baseContentHash: base.baseContentHash,
            resultContentHash: base.resultContentHash,
            operationIdentity: base.operationIdentity
        )
        let cases: [(String, [SyncConvergencePostCommitWorkPayloadV1.PresentationEntry])] = [
            ("incremental without executable operation", [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: postHash,
                    incrementalOperations: []
                )
            ]),
            ("whole note fallback with incremental operation", [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .wholeNoteFallback,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: postHash,
                    incrementalOperations: [base]
                )
            ]),
            ("operation note differs from entry note", [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: postHash,
                    incrementalOperations: [wrongNote]
                )
            ]),
            ("operation kind differs from identity kind", [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: postHash,
                    incrementalOperations: [wrongKindIdentity]
                )
            ]),
            ("duplicate presentation note", [
                workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback),
                workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)
            ])
        ]

        for testCase in cases {
            let payload = SyncConvergencePostCommitWorkPayloadV1(
                queueCleanupBatchIDs: [],
                legacyCleanupRequired: false,
                presentationEntries: testCase.1
            )

            XCTAssertThrowsError(try payload.encodedPayloadData(), testCase.0)
        }
    }

    func testRepresentativeWorkPayloadGoldenDigestPinsStableEncoding() throws {
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [TestIDs.extraBatch, TestIDs.batch],
            legacyCleanupRequired: true,
            presentationEntries: [
                workEntry(
                    noteID: TestIDs.noteB,
                    routing: .wholeNoteFallback,
                    postHash: SyncBatchContentHash.sha256Hex(for: "whole-note-final")
                ),
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: "A"),
                    committedPostBodyHash: SyncBatchContentHash.sha256Hex(for: "ABC"),
                    incrementalOperations: [
                        incrementalOperation(
                            noteID: TestIDs.noteA,
                            operationIndex: 0,
                            utf16Offset: 1,
                            text: "B",
                            baseHash: SyncBatchContentHash.sha256Hex(for: "A"),
                            resultHash: SyncBatchContentHash.sha256Hex(for: "AB")
                        ),
                        incrementalOperation(
                            noteID: TestIDs.noteA,
                            operationIndex: 1,
                            utf16Offset: 2,
                            text: "C",
                            baseHash: SyncBatchContentHash.sha256Hex(for: "AB"),
                            resultHash: SyncBatchContentHash.sha256Hex(for: "ABC")
                        )
                    ]
                )
            ]
        )

        let data = try payload.encodedPayloadData()
        XCTAssertEqual(sha256Hex(data), "9cd2489d7c1338e54c0db95eabf20e5a98c8fefc872e4b02665ce3a678e1e3e5")
        let decoded = try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData(data)
        XCTAssertEqual(decoded.queueCleanupBatchIDs, [TestIDs.batch, TestIDs.extraBatch])
        XCTAssertEqual(decoded.presentationEntries.map(\.noteID), [TestIDs.noteA, TestIDs.noteB])
        let incrementalEntry = decoded.presentationEntries[0]
        let fallbackEntry = decoded.presentationEntries[1]
        XCTAssertEqual(incrementalEntry.routing, .incremental)
        XCTAssertEqual(incrementalEntry.expectedPreBodyHash, SyncBatchContentHash.sha256Hex(for: "A"))
        XCTAssertEqual(incrementalEntry.committedPostBodyHash, SyncBatchContentHash.sha256Hex(for: "ABC"))
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.operationIndex), [0, 1])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.utf16Offset), [1, 2])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.text), ["B", "C"])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.baseContentHash), [
            SyncBatchContentHash.sha256Hex(for: "A"),
            SyncBatchContentHash.sha256Hex(for: "AB")
        ])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.resultContentHash), [
            SyncBatchContentHash.sha256Hex(for: "AB"),
            SyncBatchContentHash.sha256Hex(for: "ABC")
        ])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.operationIdentity.operationIndex), [0, 1])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.operationIdentity.canonicalReplayKey.operationIndex), [0, 1])
        var replayedBody = "A"
        for operation in incrementalEntry.incrementalOperations {
            let index = String.Index(utf16Offset: operation.utf16Offset, in: replayedBody)
            replayedBody.insert(contentsOf: operation.text ?? "", at: index)
        }
        XCTAssertEqual(replayedBody, "ABC")
        XCTAssertEqual(SyncBatchContentHash.sha256Hex(for: replayedBody), incrementalEntry.committedPostBodyHash)
        XCTAssertEqual(fallbackEntry.routing, .wholeNoteFallback)
        XCTAssertEqual(fallbackEntry.incrementalOperations, [])
    }

    func testBodyHashCapabilityRemainsDisabled() {
        XCTAssertFalse(SyncBatchBodyHashCapability.defaultEnabled)
    }

}
