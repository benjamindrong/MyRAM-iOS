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
        queue.behavior = .failBeforeRemoval
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

    func testMYR137FakeStoreLoadOutcomeAndFailureMatrixStopsBeforeAdaptersOrCAS() async {
        let identity = testIdentity()
        let initialRoot = fullRootState(identity: identity, state: SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        ))
        let cases: [(String, FakePostCommitStore.LoadBehavior, SyncConvergencePostCommitOutcome)] = [
            (
                "fake store protocol missing result",
                .returnState(.missing),
                .failedBeforeWork(.missingAuthoritativeIncorporation(batchID: identity.batchID))
            ),
            (
                "fake store protocol inconsistent result",
                .returnState(.inconsistent),
                .failedBeforeWork(.inconsistentIncorporationIdentity(batchID: identity.batchID))
            ),
            (
                "fake store typed thrown persistence failure",
                .fail(.persistence),
                .failedBeforeWork(.persistence)
            ),
            (
                "fake store unexpected thrown error",
                .failUnexpectedly,
                .failedBeforeWork(.unexpected)
            )
        ]

        for testCase in cases {
            let store = FakePostCommitStore(state: .fullRoot(initialRoot))
            store.loadBehavior = testCase.1
            let queue = FakeQueueCleanupAdapter()
            let legacy = FakeLegacyCleanupAdapter(result: .verifiedComplete)
            let presentation = FakePresentationAdapter(result: .verifiedComplete)
            let executor = SyncConvergencePostCommitExecutor(
                store: store,
                queueCleanupAdapter: queue,
                legacyCleanupAdapter: legacy,
                presentationAdapter: presentation
            )

            let outcome = await executor.execute(request(identity: identity, state: initialRoot.postCommitState))

            XCTAssertEqual(outcome, testCase.2, testCase.0)
            XCTAssertEqual(store.loadCallCount, 1, testCase.0)
            XCTAssertEqual(queue.removals, [], testCase.0)
            XCTAssertEqual(legacy.callCount, 0, testCase.0)
            XCTAssertEqual(presentation.requests, [], testCase.0)
            XCTAssertEqual(store.committedNoteLoadRequests, [], testCase.0)
            XCTAssertEqual(store.casAttemptCount, 0, testCase.0)
            XCTAssertEqual(store.state, .fullRoot(initialRoot), testCase.0)
            XCTAssertEqual(store.originalWorkPayloadData, initialRoot.postCommitWorkPayloadData, testCase.0)
        }
    }

    func testMYR137FakeFullRootMissingDecodedWorkFailsBeforeAdaptersOrCAS() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let loaded = fullRootState(identity: identity, state: state, includeWorkPayload: false)
        let store = FakePostCommitStore(state: .fullRoot(loaded))
        let queue = FakeQueueCleanupAdapter()
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .failedBeforeWork(.missingPostCommitWorkPayload(batchID: identity.batchID)))
        XCTAssertEqual(queue.removals, [])
        XCTAssertEqual(presentation.requests, [])
        XCTAssertEqual(store.committedNoteLoadRequests, [])
        XCTAssertEqual(store.casAttemptCount, 0)
    }

    func testMYR137PersistedLoadFailureMatrixFailsClosedWithoutMutation() async throws {
        struct Case {
            let label: String
            let expectedFailure: (UUID) -> SyncConvergencePostCommitFailure
            let mutate: (MYR136Fixture, ModelContext, IncorporatedSyncBatch) throws -> Void
        }

        let cases: [Case] = [
            Case(
                label: "real-store malformed postCommitStatePayloadData",
                expectedFailure: { .malformedPostCommitState(batchID: $0) }
            ) { _, _, root in
                root.postCommitStatePayloadData = Data([0x13, 0x70, 0x01])
            },
            Case(
                label: "real-store missing persisted work payload while pending",
                expectedFailure: { .missingPostCommitWorkPayload(batchID: $0) }
            ) { _, _, root in
                root.postCommitWorkPayloadData = nil
            },
            Case(
                label: "real-store malformed postCommitWorkPayloadData",
                expectedFailure: { .malformedPostCommitWorkPayload(batchID: $0) }
            ) { _, _, root in
                root.postCommitWorkPayloadData = Data([0x13, 0x70, 0x03])
            },
            Case(
                label: "real-store inconsistent queue pending with empty cleanup IDs",
                expectedFailure: { .contradictoryPostCommitWorkPayload(batchID: $0) }
            ) { _, _, root in
                root.postCommitStatePayloadData = try SyncConvergenceStableEncoding.encode(SyncConvergencePostCommitState(
                    queueCleanupPending: true,
                    legacyCleanupPending: false,
                    presentationRefreshPending: false
                ))
                root.postCommitWorkPayloadData = try SyncConvergencePostCommitWorkPayloadV1(
                    queueCleanupBatchIDs: [],
                    legacyCleanupRequired: false,
                    presentationEntries: []
                ).encodedPayloadData()
            },
            Case(
                label: "real-store inconsistent presentation pending with empty entries",
                expectedFailure: { .contradictoryPostCommitWorkPayload(batchID: $0) }
            ) { fixture, _, root in
                root.postCommitStatePayloadData = try SyncConvergenceStableEncoding.encode(SyncConvergencePostCommitState(
                    queueCleanupPending: false,
                    legacyCleanupPending: true,
                    presentationRefreshPending: true
                ))
                root.postCommitWorkPayloadData = try SyncConvergencePostCommitWorkPayloadV1(
                    queueCleanupBatchIDs: [],
                    legacyCleanupRequired: true,
                    presentationEntries: []
                ).encodedPayloadData()
                XCTAssertEqual(fixture.request.sourceBatchID, root.batchID)
            }
        ]

        for testCase in cases {
            let fixture = try makeMYR137Fixture()
            let mutationContext = ModelContext(fixture.container)
            let row = try fixture.rawRoot(context: mutationContext)
            try testCase.mutate(fixture, mutationContext, row)
            try mutationContext.save()
            let before = try fixture.rawRootSnapshot()
            let queue = FakeQueueCleanupAdapter()
            let legacy = FakeLegacyCleanupAdapter(result: .verifiedComplete)
            let presentation = FakePresentationAdapter(result: .verifiedComplete)
            let executor = SyncConvergencePostCommitExecutor(
                store: fixture.store(context: ModelContext(fixture.container)),
                queueCleanupAdapter: queue,
                legacyCleanupAdapter: legacy,
                presentationAdapter: presentation
            )

            let outcome = await executor.execute(fixture.request)

            XCTAssertEqual(outcome, .failedBeforeWork(testCase.expectedFailure(fixture.request.sourceBatchID)), testCase.label)
            XCTAssertEqual(queue.removals, [], testCase.label)
            XCTAssertEqual(legacy.callCount, 0, testCase.label)
            XCTAssertEqual(presentation.requests, [], testCase.label)
            XCTAssertEqual(try fixture.rawRootSnapshot(), before, testCase.label)
        }
    }

    func testMYR137TombstoneQueueFailureRetriesWithoutCASAndDistinguishesMismatchLayers() async throws {
        let identity = testIdentity()
        let store = FakePostCommitStore(state: .tombstone(tombstone(identity: identity)))
        let queue = FakeQueueCleanupAdapter()
        queue.behavior = .failBeforeRemoval
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            presentationAdapter: FakePresentationAdapter(result: .verifiedComplete)
        )

        let failedOutcome = await executor.execute(request(identity: identity))

        XCTAssertEqual(failedOutcome, .pending([.queueCleanup]))
        XCTAssertEqual(queue.removalAttempts, 1)
        XCTAssertEqual(queue.removals, [])
        XCTAssertEqual(store.casAttemptCount, 0)

        queue.behavior = .verifiedComplete
        let retryOutcome = await executor.execute(request(identity: identity))

        XCTAssertEqual(retryOutcome, .complete)
        XCTAssertEqual(queue.removals, [[identity.batchID]])
        XCTAssertEqual(queue.verificationChecks, [identity.batchID])
        XCTAssertEqual(store.casAttemptCount, 0)

        let fixture = try makeMYR137Fixture()
        let tombstoneContext = ModelContext(fixture.container)
        tombstoneContext.insert(try IncorporatedBatchTombstone.makeValidated(
            batchID: fixture.request.sourceBatchID,
            originDeviceID: TestIDs.device,
            canonicalPayloadDigest: String(repeating: "a", count: 64),
            canonicalPayloadDigestFormatVersion: fixture.request.persistedIncorporationIdentity.canonicalPayloadDigestFormatVersion,
            schemaVersion: 1,
            committedResultDigest: fixture.request.persistedIncorporationIdentity.committedResultDigest,
            committedResultDigestFormatVersion: fixture.request.persistedIncorporationIdentity.committedResultDigestFormatVersion,
            committedAtOrderingPayloadData: try CommittedAtOrderingPayload(
                batchID: fixture.request.sourceBatchID,
                committedAt: Date(timeIntervalSince1970: 137_001)
            ).encodedEvidenceData()
        ))
        let root = try fixture.rawRoot(context: tombstoneContext)
        tombstoneContext.delete(root)
        try tombstoneContext.save()
        let realMismatchOutcome = await SyncConvergencePostCommitExecutor(
            store: fixture.store(context: ModelContext(fixture.container)),
            queueCleanupAdapter: FakeQueueCleanupAdapter(),
            presentationAdapter: FakePresentationAdapter(result: .verifiedComplete)
        ).execute(fixture.request)

        XCTAssertEqual(
            realMismatchOutcome,
            .failedBeforeWork(.inconsistentIncorporationIdentity(batchID: fixture.request.sourceBatchID)),
            "real-store tombstone identity mismatch"
        )

        let requestMismatchID = uuid("00000000-0000-0000-0000-000000137002")
        let requestMismatch = SyncConvergencePostCommitRequest(
            sourceBatchID: requestMismatchID,
            affectedNoteIDs: [],
            cleanupPlan: SyncConvergenceCleanupPlan(
                batchIDs: [requestMismatchID],
                retryQueueCleanup: true,
                retryLegacyCleanup: false,
                retryPresentationRefresh: false
            ),
            presentationPlan: SyncConvergencePresentationPlan(noteRoutings: [:]),
            persistedIncorporationIdentity: identity
        )
        let guardQueue = FakeQueueCleanupAdapter()
        let guardOutcome = await SyncConvergencePostCommitExecutor(
            store: FakePostCommitStore(state: .tombstone(tombstone(identity: identity))),
            queueCleanupAdapter: guardQueue,
            presentationAdapter: FakePresentationAdapter(result: .verifiedComplete)
        ).execute(requestMismatch)

        XCTAssertEqual(
            guardOutcome,
            .failedBeforeWork(.inconsistentIncorporationIdentity(batchID: requestMismatchID)),
            "executor executeTombstone request guard"
        )
        XCTAssertEqual(guardQueue.removalAttempts, 0)
    }

    func testMYR137QueueFailureModesClearSuccessfulLaterDomainsAndRetryOnlyQueue() async {
        struct Case {
            let label: String
            let behavior: FakeQueueCleanupAdapter.Behavior
            let externalEffectExpected: Bool
        }

        let cases = [
            Case(label: "failure before removal", behavior: .failBeforeRemoval, externalEffectExpected: false),
            Case(label: "incomplete removal leaves source batch present", behavior: .incompleteRemoval(remaining: [TestIDs.batch]), externalEffectExpected: true),
            Case(label: "idempotent queue post-effect verification failure", behavior: .failVerificationAfterRemoval, externalEffectExpected: true)
        ]
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )

        for testCase in cases {
            let original = fullRootState(identity: identity, state: state)
            let store = FakePostCommitStore(state: .fullRoot(original))
            let recorder = PostCommitInvocationRecorder()
            let queue = FakeQueueCleanupAdapter(recorder: recorder)
            queue.behavior = testCase.behavior
            let legacy = FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: recorder)
            let presentation = FakePresentationAdapter(result: .verifiedComplete, recorder: recorder)
            let executor = SyncConvergencePostCommitExecutor(
                store: store,
                queueCleanupAdapter: queue,
                legacyCleanupAdapter: legacy,
                presentationAdapter: presentation
            )

            let outcome = await executor.execute(request(identity: identity, state: state))

            XCTAssertEqual(outcome, .pending([.queueCleanup]), testCase.label)
            var expectedEvents: [PostCommitInvocationEvent] = [
                .presentation(noteID: TestIDs.noteA),
                .legacyCleanup(batchID: identity.batchID)
            ]
            if testCase.externalEffectExpected {
                expectedEvents.append(.queueCleanup([TestIDs.batch, TestIDs.extraBatch]))
            }
            XCTAssertEqual(recorder.events, expectedEvents, testCase.label)
            if testCase.externalEffectExpected {
                XCTAssertTrue(queue.externalRemovalEffectOccurred, testCase.label)
            } else {
                XCTAssertFalse(queue.externalRemovalEffectOccurred, testCase.label)
            }
            XCTAssertEqual(store.casAttemptCount, 2, testCase.label)
            XCTAssertEqual(store.currentPostCommitState, SyncConvergencePostCommitState(
                queueCleanupPending: true,
                legacyCleanupPending: false,
                presentationRefreshPending: false
            ), testCase.label)
            XCTAssertEqual(store.currentWorkPayloadData, original.postCommitWorkPayloadData, testCase.label)

            let retryRecorder = PostCommitInvocationRecorder()
            let retryQueue = FakeQueueCleanupAdapter(recorder: retryRecorder)
            let retryLegacy = FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: retryRecorder)
            let retryPresentation = FakePresentationAdapter(result: .verifiedComplete, recorder: retryRecorder)
            let retryExecutor = SyncConvergencePostCommitExecutor(
                store: store,
                queueCleanupAdapter: retryQueue,
                legacyCleanupAdapter: retryLegacy,
                presentationAdapter: retryPresentation
            )

            let retryOutcome = await retryExecutor.execute(request(identity: identity, state: state))

            XCTAssertEqual(retryOutcome, .complete, testCase.label)
            XCTAssertEqual(retryRecorder.events, [.queueCleanup([TestIDs.batch, TestIDs.extraBatch])], testCase.label)
            XCTAssertEqual(store.currentPostCommitState, SyncConvergencePostCommitState.none, testCase.label)
            XCTAssertEqual(store.currentWorkPayloadData, original.postCommitWorkPayloadData, testCase.label)
        }
    }

    func testMYR137LegacyFailureModesClearOtherDomainsAndRetryOnlyLegacy() async {
        struct Case {
            let label: String
            let step: FakeLegacyCleanupAdapter.Step
        }

        let cases = [
            Case(label: "legacy stillPending after external effect is idempotent", step: .init(result: .stillPending, externalEffectOccurred: true)),
            Case(label: "legacy failed before external effect", step: .init(result: .failed, externalEffectOccurred: false)),
            Case(label: "legacy after-effect failure is idempotent", step: .init(result: .failed, externalEffectOccurred: true))
        ]
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )

        for testCase in cases {
            let original = fullRootState(identity: identity, state: state)
            let store = FakePostCommitStore(state: .fullRoot(original))
            let recorder = PostCommitInvocationRecorder()
            let queue = FakeQueueCleanupAdapter(recorder: recorder)
            let legacy = FakeLegacyCleanupAdapter(script: [testCase.step], recorder: recorder)
            let presentation = FakePresentationAdapter(result: .verifiedComplete, recorder: recorder)
            let executor = SyncConvergencePostCommitExecutor(
                store: store,
                queueCleanupAdapter: queue,
                legacyCleanupAdapter: legacy,
                presentationAdapter: presentation
            )

            let outcome = await executor.execute(request(identity: identity, state: state))

            XCTAssertEqual(outcome, .pending([.queueCleanup, .legacyCleanup]), testCase.label)
            XCTAssertEqual(recorder.events, [
                .presentation(noteID: TestIDs.noteA),
                .legacyCleanup(batchID: identity.batchID),
            ], testCase.label)
            XCTAssertEqual(legacy.externalEffectCount, testCase.step.externalEffectOccurred ? 1 : 0, testCase.label)
            XCTAssertEqual(store.casAttemptCount, 1, testCase.label)
            XCTAssertEqual(store.currentPostCommitState, SyncConvergencePostCommitState(
                queueCleanupPending: true,
                legacyCleanupPending: true,
                presentationRefreshPending: false
            ), testCase.label)
            XCTAssertEqual(store.currentWorkPayloadData, original.postCommitWorkPayloadData, testCase.label)

            let retryRecorder = PostCommitInvocationRecorder()
            let retryExecutor = SyncConvergencePostCommitExecutor(
                store: store,
                queueCleanupAdapter: FakeQueueCleanupAdapter(recorder: retryRecorder),
                legacyCleanupAdapter: FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: retryRecorder),
                presentationAdapter: FakePresentationAdapter(result: .verifiedComplete, recorder: retryRecorder)
            )
            let retryOutcome = await retryExecutor.execute(request(identity: identity, state: state))

            XCTAssertEqual(retryOutcome, .complete, testCase.label)
            XCTAssertEqual(retryRecorder.events, [
                .legacyCleanup(batchID: identity.batchID),
                .queueCleanup([TestIDs.batch, TestIDs.extraBatch])
            ], testCase.label)
            XCTAssertEqual(store.currentPostCommitState, SyncConvergencePostCommitState.none, testCase.label)
            XCTAssertEqual(store.currentWorkPayloadData, original.postCommitWorkPayloadData, testCase.label)
        }
    }

    func testMYR137PresentationPreActionLoadFailuresClearEarlierDomainsWithoutCallingAdapter() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )
        let original = fullRootState(identity: identity, state: state)
        let store = FakePostCommitStore(state: .fullRoot(original))
        store.committedNoteLoadBehavior = .fail
        let recorder = PostCommitInvocationRecorder()
        let presentation = FakePresentationAdapter(result: .verifiedComplete, recorder: recorder)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: FakeQueueCleanupAdapter(recorder: recorder),
            legacyCleanupAdapter: FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: recorder),
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .failedBeforeWork(.persistence))
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(presentation.requests, [])
        XCTAssertEqual(store.casAttemptCount, 0)
        XCTAssertEqual(store.currentPostCommitState, state)
        XCTAssertEqual(store.currentWorkPayloadData, original.postCommitWorkPayloadData)

        store.committedNoteLoadBehavior = .currentNotes
        let retryRecorder = PostCommitInvocationRecorder()
        let retryExecutor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: FakeQueueCleanupAdapter(recorder: retryRecorder),
            legacyCleanupAdapter: FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: retryRecorder),
            presentationAdapter: FakePresentationAdapter(result: .verifiedComplete, recorder: retryRecorder)
        )

        let retryOutcome = await retryExecutor.execute(request(identity: identity, state: state))

        XCTAssertEqual(retryOutcome, .complete)
        XCTAssertEqual(retryRecorder.events, [
            .presentation(noteID: TestIDs.noteA),
            .legacyCleanup(batchID: identity.batchID),
            .queueCleanup([TestIDs.batch, TestIDs.extraBatch])
        ])
        XCTAssertEqual(store.currentPostCommitState, SyncConvergencePostCommitState.none)
    }

    func testMYR137PresentationMissingNoteIsTreatedAsSatisfiedAndDrainsOtherDomains() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )
        let original = fullRootState(identity: identity, state: state)
        let store = FakePostCommitStore(state: .fullRoot(original))
        store.committedNoteLoadBehavior = .returnMissing
        let recorder = PostCommitInvocationRecorder()
        let presentation = FakePresentationAdapter(result: .verifiedComplete, recorder: recorder)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: FakeQueueCleanupAdapter(recorder: recorder),
            legacyCleanupAdapter: FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: recorder),
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        // A note that can no longer be loaded (deleted, or never locally present) has nothing left
        // to refresh; the batch should still drain instead of getting stuck behind it forever.
        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(presentation.requests, [])
        XCTAssertEqual(recorder.events, [
            .legacyCleanup(batchID: identity.batchID),
            .queueCleanup([TestIDs.batch, TestIDs.extraBatch])
        ])
        XCTAssertEqual(store.currentPostCommitState, SyncConvergencePostCommitState.none)
    }

    func testMYR137PresentationScriptedFailureReplaysDomainIdempotently() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )
        let entries = [
            workEntry(noteID: TestIDs.noteB, routing: .wholeNoteFallback, postHash: SyncBatchContentHash.sha256Hex(for: "body-b")),
            workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback, postHash: SyncBatchContentHash.sha256Hex(for: "body-a"))
        ]
        let original = fullRootState(identity: identity, state: state, presentationEntries: entries)
        let store = FakePostCommitStore(state: .fullRoot(original))
        store.notes[TestIDs.noteA] = note(id: TestIDs.noteA, title: "A", body: "body-a")
        store.notes[TestIDs.noteB] = note(id: TestIDs.noteB, title: "B", body: "body-b")
        let recorder = PostCommitInvocationRecorder()
        let presentation = FakePresentationAdapter(
            scriptByNoteID: [
                TestIDs.noteA: [.init(result: .verifiedComplete, externalEffectOccurred: true)],
                TestIDs.noteB: [.init(result: .failed, externalEffectOccurred: true)]
            ],
            recorder: recorder
        )
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: FakeQueueCleanupAdapter(recorder: recorder),
            legacyCleanupAdapter: FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: recorder),
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .failedBeforeWork(.persistence))
        XCTAssertEqual(recorder.events, [
            .presentation(noteID: TestIDs.noteA),
            .presentation(noteID: TestIDs.noteB)
        ])
        XCTAssertEqual(presentation.externalEffectNoteIDs, [TestIDs.noteA, TestIDs.noteB])
        XCTAssertEqual(store.casAttemptCount, 0)
        XCTAssertEqual(store.currentPostCommitState, state)
        XCTAssertEqual(store.currentWorkPayloadData, original.postCommitWorkPayloadData)

        let retryRecorder = PostCommitInvocationRecorder()
        let retryPresentation = FakePresentationAdapter(result: .verifiedComplete, recorder: retryRecorder)
        retryPresentation.scriptByNoteID = [:]
        let retryExecutor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: FakeQueueCleanupAdapter(recorder: retryRecorder),
            legacyCleanupAdapter: FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: retryRecorder),
            presentationAdapter: retryPresentation
        )

        let retryOutcome = await retryExecutor.execute(request(identity: identity, state: state))

        XCTAssertEqual(retryOutcome, .complete)
        XCTAssertEqual(retryRecorder.events, [
            .presentation(noteID: TestIDs.noteA),
            .presentation(noteID: TestIDs.noteB),
            .legacyCleanup(batchID: identity.batchID),
            .queueCleanup([TestIDs.batch, TestIDs.extraBatch])
        ])
        XCTAssertEqual(store.currentPostCommitState, SyncConvergencePostCommitState.none)
        XCTAssertEqual(store.currentWorkPayloadData, original.postCommitWorkPayloadData)
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

    func testMYR137MixedFailureMatrixPreservesExactPendingSetIncludingZeroCompletionBranch() async {
        struct Case {
            let label: String
            let queueBehavior: FakeQueueCleanupAdapter.Behavior
            let legacyStep: FakeLegacyCleanupAdapter.Step
            let presentationStep: FakePresentationAdapter.Step
            let expectedPending: Set<SyncConvergencePostCommitPendingWork>
            let expectedCASAttempts: Int
            let expectedEvents: [PostCommitInvocationEvent]
        }

        let cases = [
            Case(
                label: "queue fails legacy stillPending presentation completes",
                queueBehavior: .failBeforeRemoval,
                legacyStep: .init(result: .stillPending, externalEffectOccurred: true),
                presentationStep: .init(result: .verifiedComplete, externalEffectOccurred: true),
                expectedPending: [.queueCleanup, .legacyCleanup],
                expectedCASAttempts: 1,
                expectedEvents: [
                    .presentation(noteID: TestIDs.noteA),
                    .legacyCleanup(batchID: TestIDs.batch)
                ]
            ),
            Case(
                label: "queue completes legacy failed presentation failed",
                queueBehavior: .verifiedComplete,
                legacyStep: .init(result: .failed, externalEffectOccurred: false),
                presentationStep: .init(result: .failed, externalEffectOccurred: false),
                expectedPending: [.queueCleanup, .legacyCleanup, .presentationRefresh],
                expectedCASAttempts: 0,
                expectedEvents: [
                    .presentation(noteID: TestIDs.noteA)
                ]
            ),
            Case(
                label: "queue incomplete legacy completes presentation stillPending",
                queueBehavior: .incompleteRemoval(remaining: [TestIDs.extraBatch]),
                legacyStep: .init(result: .verifiedComplete, externalEffectOccurred: true),
                presentationStep: .init(result: .stillPending, externalEffectOccurred: true),
                expectedPending: [.queueCleanup, .legacyCleanup, .presentationRefresh],
                expectedCASAttempts: 0,
                expectedEvents: [
                    .presentation(noteID: TestIDs.noteA)
                ]
            ),
            Case(
                label: "zero completion branch queue fails legacy failed presentation failed",
                queueBehavior: .failBeforeRemoval,
                legacyStep: .init(result: .failed, externalEffectOccurred: false),
                presentationStep: .init(result: .failed, externalEffectOccurred: false),
                expectedPending: [.queueCleanup, .legacyCleanup, .presentationRefresh],
                expectedCASAttempts: 0,
                expectedEvents: [
                    .presentation(noteID: TestIDs.noteA)
                ]
            )
        ]
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )

        for testCase in cases {
            let loaded = fullRootState(identity: identity, state: state)
            let store = FakePostCommitStore(state: .fullRoot(loaded))
            let recorder = PostCommitInvocationRecorder()
            let queue = FakeQueueCleanupAdapter(recorder: recorder)
            queue.behavior = testCase.queueBehavior
            let legacy = FakeLegacyCleanupAdapter(script: [testCase.legacyStep], recorder: recorder)
            let presentation = FakePresentationAdapter(
                scriptByNoteID: [TestIDs.noteA: [testCase.presentationStep]],
                recorder: recorder
            )
            let executor = SyncConvergencePostCommitExecutor(
                store: store,
                queueCleanupAdapter: queue,
                legacyCleanupAdapter: legacy,
                presentationAdapter: presentation
            )

            let outcome = await executor.execute(request(identity: identity, state: state))

            if testCase.label.contains("presentation failed") {
                XCTAssertEqual(outcome, .failedBeforeWork(.persistence), testCase.label)
            } else {
                XCTAssertEqual(outcome, .pending(testCase.expectedPending), testCase.label)
            }
            XCTAssertEqual(recorder.events, testCase.expectedEvents, testCase.label)
            let expectsQueue = testCase.expectedEvents.contains {
                if case .queueCleanup = $0 { return true }
                return false
            }
            let expectsLegacy = testCase.expectedEvents.contains {
                if case .legacyCleanup = $0 { return true }
                return false
            }
            XCTAssertEqual(queue.removalAttempts, expectsQueue ? 1 : 0, testCase.label)
            XCTAssertEqual(legacy.callCount, expectsLegacy ? 1 : 0, testCase.label)
            XCTAssertEqual(presentation.requests.map(\.noteID), [TestIDs.noteA], testCase.label)
            XCTAssertEqual(store.casAttemptCount, testCase.expectedCASAttempts, testCase.label)
            XCTAssertEqual(store.currentWorkPayloadData, loaded.postCommitWorkPayloadData, testCase.label)
            if testCase.expectedCASAttempts == 0 {
                XCTAssertEqual(store.state, .fullRoot(loaded), testCase.label)
            } else {
                XCTAssertEqual(store.currentPostCommitState?.pendingWork, testCase.expectedPending, testCase.label)
            }
        }
    }

    func testMYR137FinalCASFailureModesPreserveAuthoritativeStoreStateAndImmutableWork() async throws {
        let identity = testIdentity()
        let originalState = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )
        let originalRoot = fullRootState(identity: identity, state: originalState)
        let advancedState = SyncConvergencePostCommitState(
            queueCleanupPending: false,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let advancedRoot = try replacingMutablePostCommitState(in: originalRoot, with: advancedState)
        let originalRequest = request(identity: identity, state: originalState)
        XCTAssertNotEqual(advancedRoot.postCommitStatePayloadData, originalRoot.postCommitStatePayloadData)
        XCTAssertEqual(advancedRoot.postCommitWorkPayload, originalRoot.postCommitWorkPayload)
        XCTAssertEqual(advancedRoot.postCommitWorkPayloadData, originalRoot.postCommitWorkPayloadData)
        XCTAssertEqual(
            advancedRoot.root,
            copyRootProjection(
                originalRoot.root,
                postCommitStatePayloadData: advancedRoot.postCommitStatePayloadData
            )
        )
        let immutableReplacement = fullRootState(
            identity: SyncConvergencePersistedIncorporationIdentity(
                batchID: uuid("00000000-0000-0000-0000-000000137901"),
                canonicalPayloadDigest: identity.canonicalPayloadDigest,
                canonicalPayloadDigestFormatVersion: identity.canonicalPayloadDigestFormatVersion,
                committedResultDigest: identity.committedResultDigest,
                committedResultDigestFormatVersion: identity.committedResultDigestFormatVersion
            ),
            state: originalState
        )
        let cases: [(String, FakePostCommitStore.CASBehavior, SyncConvergencePostCommitLoadedState, Data?)] = [
            (
                "state-save persistence failure before fake-store mutation",
                .failPersistence,
                .fullRoot(originalRoot),
                originalRoot.postCommitWorkPayloadData
            ),
            (
                "stale mutable state with queue and legacy already cleared",
                .replaceCurrentBeforeCompare(advancedRoot),
                .fullRoot(advancedRoot),
                originalRoot.postCommitWorkPayloadData
            ),
            (
                "immutable-root mismatch replacement",
                .replaceCurrentBeforeCompare(immutableReplacement),
                .fullRoot(immutableReplacement),
                immutableReplacement.postCommitWorkPayloadData
            )
        ]

        for testCase in cases {
            let store = FakePostCommitStore(state: .fullRoot(originalRoot))
            store.casBehavior = testCase.1
            let queue = FakeQueueCleanupAdapter()
            let legacy = FakeLegacyCleanupAdapter(result: .verifiedComplete)
            let presentation = FakePresentationAdapter(result: .verifiedComplete)
            let executor = SyncConvergencePostCommitExecutor(
                store: store,
                queueCleanupAdapter: queue,
                legacyCleanupAdapter: legacy,
                presentationAdapter: presentation
            )

            let outcome = await executor.execute(originalRequest)

            XCTAssertEqual(
                outcome,
                .pending([.queueCleanup, .legacyCleanup, .presentationRefresh, .postCommitStatePersistence]),
                testCase.0
            )
            XCTAssertEqual(queue.removalAttempts, 0, testCase.0)
            XCTAssertEqual(legacy.callCount, 0, testCase.0)
            XCTAssertEqual(presentation.requests.map(\.noteID), [TestIDs.noteA], testCase.0)
            XCTAssertEqual(store.casAttemptCount, 1, testCase.0)
            XCTAssertEqual(store.attemptedNewStates, [
                SyncConvergencePostCommitState(
                    queueCleanupPending: true,
                    legacyCleanupPending: true,
                    presentationRefreshPending: false
                )
            ], testCase.0)
            XCTAssertEqual(store.state, testCase.2, testCase.0)
            XCTAssertEqual(store.currentWorkPayloadData, testCase.3, testCase.0)
            if testCase.0 == "stale mutable state with queue and legacy already cleared" {
                XCTAssertEqual(store.currentWorkPayloadData, originalRoot.postCommitWorkPayloadData, testCase.0)
                XCTAssertEqual(store.currentPostCommitState, advancedState, testCase.0)
            }
        }

        let retryStore = FakePostCommitStore(state: .fullRoot(advancedRoot))
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

        let retryOutcome = await retryExecutor.execute(originalRequest)

        XCTAssertEqual(retryOutcome, .complete)
        XCTAssertEqual(retryRecorder.events, [.presentation(noteID: TestIDs.noteA)])
        XCTAssertEqual(retryQueue.removalAttempts, 0)
        XCTAssertEqual(retryLegacy.callCount, 0)
        XCTAssertEqual(retryStore.casAttemptCount, 1)
        XCTAssertEqual(retryStore.attemptedNewStates, [.none])
        XCTAssertEqual(retryStore.currentPostCommitState, SyncConvergencePostCommitState.none)
        XCTAssertEqual(retryStore.currentWorkPayloadData, originalRoot.postCommitWorkPayloadData)
    }

    func testMYR137PartialCompletionSurvivesFreshSwiftDataContextAndRetryRunsOnlyRemainingDomain() async throws {
        let fixture = try makeMYR137Fixture()
        let before = try fixture.rawRootSnapshot()
        let firstRecorder = PostCommitInvocationRecorder()
        let firstQueue = FakeQueueCleanupAdapter(recorder: firstRecorder)
        let firstLegacy = FakeLegacyCleanupAdapter(
            script: [.init(result: .stillPending, externalEffectOccurred: true)],
            recorder: firstRecorder
        )
        let firstPresentation = FakePresentationAdapter(result: .verifiedComplete, recorder: firstRecorder)
        let firstExecutor = SyncConvergencePostCommitExecutor(
            store: fixture.store(context: ModelContext(fixture.container)),
            queueCleanupAdapter: firstQueue,
            legacyCleanupAdapter: firstLegacy,
            presentationAdapter: firstPresentation
        )

        let firstOutcome = await firstExecutor.execute(fixture.request)

        XCTAssertEqual(firstOutcome, .pending([.queueCleanup, .legacyCleanup]))
        XCTAssertEqual(firstRecorder.events, [
            .presentation(noteID: fixture.base.noteID),
            .legacyCleanup(batchID: fixture.request.sourceBatchID),
        ])
        let afterFirst = try fixture.rawRootSnapshot()
        let legacyOnly = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: false
        )
        let legacyOnlyData = try SyncConvergenceStableEncoding.encode(legacyOnly)
        XCTAssertNotEqual(afterFirst.postCommitStatePayloadData, before.postCommitStatePayloadData)
        XCTAssertEqual(
            afterFirst,
            before.replacingPostCommitStatePayloadData(
                legacyOnlyData,
                hasPendingPostCommitWork: legacyOnly.hasPendingWork
            )
        )
        XCTAssertEqual(afterFirst.postCommitWorkPayloadData, before.postCommitWorkPayloadData)

        let secondRecorder = PostCommitInvocationRecorder()
        let secondQueue = FakeQueueCleanupAdapter(recorder: secondRecorder)
        let secondLegacy = FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: secondRecorder)
        let secondPresentation = FakePresentationAdapter(result: .verifiedComplete, recorder: secondRecorder)
        let secondExecutor = SyncConvergencePostCommitExecutor(
            store: fixture.store(context: ModelContext(fixture.container)),
            queueCleanupAdapter: secondQueue,
            legacyCleanupAdapter: secondLegacy,
            presentationAdapter: secondPresentation
        )

        let secondOutcome = await secondExecutor.execute(fixture.request)

        XCTAssertEqual(secondOutcome, .complete)
        XCTAssertEqual(secondRecorder.events, [
            .legacyCleanup(batchID: fixture.request.sourceBatchID),
            .queueCleanup(fixture.base.workPayload.queueCleanupBatchIDs.sorted { $0.uuidString < $1.uuidString })
        ])
        XCTAssertEqual(secondQueue.removalAttempts, 1)
        XCTAssertEqual(secondPresentation.requests, [])
        let afterSecond = try fixture.rawRootSnapshot()
        XCTAssertEqual(
            afterSecond,
            before.replacingPostCommitStatePayloadData(
                try SyncConvergenceStableEncoding.encode(SyncConvergencePostCommitState.none),
                hasPendingPostCommitWork: SyncConvergencePostCommitState.none.hasPendingWork
            )
        )
        XCTAssertEqual(afterSecond.postCommitWorkPayloadData, before.postCommitWorkPayloadData)
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
            postCommitStatePayloadData: try SyncConvergenceStableEncoding.encode(initialState),
            hasPendingPostCommitWork: initialState.hasPendingWork
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
        XCTAssertEqual(
            afterRow,
            beforeCAS.replacingPostCommitStatePayloadData(
                expectedStateBData,
                hasPendingPostCommitWork: stateB.hasPendingWork
            )
        )
    }

    func testMYR158CASSaveFailureRollsBackStateAndIndex() throws {
        let fixture = try makeMYR136Fixture()
        let beforeCAS = try fixture.rawRootSnapshot()
        let casContext = ModelContext(fixture.container)
        let failingStore = fixture.store(context: casContext)
        failingStore.testOnlyFailNextSaveAt = .compareAndSet

        XCTAssertThrowsError(
            try failingStore.compareAndSetPostCommitState(
                expectedRoot: SyncConvergencePostCommitRootSnapshot(root: fixture.loaded.root),
                expectedPayloadData: fixture.loaded.postCommitStatePayloadData,
                newState: .none
            )
        ) { error in
            XCTAssertEqual(error as? SyncConvergencePostCommitFailure, .persistence)
        }

        XCTAssertNil(failingStore.testOnlyFailNextSaveAt)
        XCTAssertFalse(casContext.hasChanges)
        XCTAssertEqual(try MYR136RawRootSnapshot(root: fixture.rawRoot(context: casContext)), beforeCAS)
        XCTAssertEqual(try fixture.rawRootSnapshot(), beforeCAS)
    }

    func testMYR158LegacyNilSuccessfulCASWritesDerivedIndex() throws {
        let fixture = try makeMYR136Fixture()
        let mutationContext = ModelContext(fixture.container)
        let rawRoot = try fixture.rawRoot(context: mutationContext)
        rawRoot.hasPendingPostCommitWork = nil
        try mutationContext.save()
        let beforeCAS = try fixture.rawRootSnapshot()
        XCTAssertNil(beforeCAS.hasPendingPostCommitWork)

        let newState = SyncConvergencePostCommitState.none
        let encodedNewState = try SyncConvergenceStableEncoding.encode(newState)
        let loaded = try fixture.store().compareAndSetPostCommitState(
            expectedRoot: SyncConvergencePostCommitRootSnapshot(root: fixture.loaded.root),
            expectedPayloadData: fixture.loaded.postCommitStatePayloadData,
            newState: newState
        )

        XCTAssertEqual(loaded.postCommitState, newState)
        XCTAssertEqual(loaded.postCommitStatePayloadData, encodedNewState)
        let afterCAS = try fixture.rawRootSnapshot()
        XCTAssertEqual(afterCAS.postCommitStatePayloadData, encodedNewState)
        XCTAssertEqual(afterCAS.hasPendingPostCommitWork, newState.hasPendingWork)
        XCTAssertEqual(afterCAS.postCommitWorkPayloadData, beforeCAS.postCommitWorkPayloadData)
    }

    func testMYR158CASGuardPrecedenceIgnoresLaterIndexContradictions() throws {
        struct Case {
            let label: String
            let prepare: (MYR136Fixture, ModelContext, IncorporatedSyncBatch) throws -> (SyncConvergencePostCommitRootSnapshot, Data)
        }

        let cases: [Case] = [
            Case(label: "expected root mismatch") { fixture, context, root in
                root.postCommitStatePayloadData = try SyncConvergenceStableEncoding.encode(SyncConvergencePostCommitState.none)
                root.hasPendingPostCommitWork = true
                try context.save()
                return (
                    SyncConvergencePostCommitRootSnapshot(root: fixture.loaded.root),
                    fixture.loaded.postCommitStatePayloadData
                )
            },
            Case(label: "persisted identity mismatch") { fixture, context, root in
                root.canonicalPayloadDigest = String(repeating: "d", count: 64)
                root.postCommitStatePayloadData = try SyncConvergenceStableEncoding.encode(SyncConvergencePostCommitState.none)
                root.hasPendingPostCommitWork = true
                try context.save()
                return (
                    SyncConvergencePostCommitRootSnapshot(root: fixture.loaded.root),
                    root.postCommitStatePayloadData
                )
            },
            Case(label: "expected payload mismatch") { fixture, context, root in
                root.postCommitStatePayloadData = try SyncConvergenceStableEncoding.encode(SyncConvergencePostCommitState.none)
                root.hasPendingPostCommitWork = true
                try context.save()
                let currentProjection = try SwiftDataSyncConvergencePersistenceTransaction(context: context)
                    .loadIncorporatedBatch(batchID: fixture.request.sourceBatchID)
                return (
                    SyncConvergencePostCommitRootSnapshot(root: try XCTUnwrap(currentProjection)),
                    fixture.loaded.postCommitStatePayloadData
                )
            }
        ]

        for testCase in cases {
            let fixture = try makeMYR136Fixture()
            let mutationContext = ModelContext(fixture.container)
            let root = try fixture.rawRoot(context: mutationContext)
            let (expectedRoot, expectedPayloadData) = try testCase.prepare(fixture, mutationContext, root)

            XCTAssertThrowsError(
                try fixture.store().compareAndSetPostCommitState(
                    expectedRoot: expectedRoot,
                    expectedPayloadData: expectedPayloadData,
                    newState: SyncConvergencePostCommitState.none
                ),
                testCase.label
            ) { error in
                XCTAssertEqual(
                    error as? SyncConvergencePostCommitFailure,
                    .inconsistentIncorporationIdentity(batchID: fixture.request.sourceBatchID),
                    testCase.label
                )
            }
        }
    }

    func testMYR158CASPostSaveContradictionReturnsTypedFailure() throws {
        let fixture = try makeMYR136Fixture()
        let store = fixture.store()
        store.testOnlyPostSaveMutation = .contradictoryIndex

        XCTAssertThrowsError(
            try store.compareAndSetPostCommitState(
                expectedRoot: SyncConvergencePostCommitRootSnapshot(root: fixture.loaded.root),
                expectedPayloadData: fixture.loaded.postCommitStatePayloadData,
                newState: SyncConvergencePostCommitState.none
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncConvergencePostCommitFailure,
                .contradictoryPostCommitIndex(batchID: fixture.request.sourceBatchID)
            )
        }
        XCTAssertNil(store.testOnlyPostSaveMutation)
    }

    func testMYR158CASPostSaveUnexpectedSelfConsistentStateReturnsPersistence() throws {
        let fixture = try makeMYR136Fixture()
        let store = fixture.store()
        store.testOnlyPostSaveMutation = .selfConsistentUnexpectedState

        XCTAssertThrowsError(
            try store.compareAndSetPostCommitState(
                expectedRoot: SyncConvergencePostCommitRootSnapshot(root: fixture.loaded.root),
                expectedPayloadData: fixture.loaded.postCommitStatePayloadData,
                newState: SyncConvergencePostCommitState.none
            )
        ) { error in
            XCTAssertEqual(error as? SyncConvergencePostCommitFailure, .persistence)
        }
        XCTAssertNil(store.testOnlyPostSaveMutation)
    }

    func testMYR158IndexedPendingSelectionSkipsCompletedHistory() throws {
        let container = try makeMYR158Container()
        let seedContext = ModelContext(container)
        for index in 0..<300 {
            seedContext.insert(try makeMYR158Root(index: index, state: .none, hasPendingPostCommitWork: false))
        }
        let firstPendingID = postCommitUUID("00000000-0000-0000-0000-000000158901")
        let secondPendingID = postCommitUUID("00000000-0000-0000-0000-000000158902")
        let sharedDate = Date(timeIntervalSince1970: 158_999)
        seedContext.insert(try makeMYR158Root(batchID: secondPendingID, index: 901, state: myr158QueueOnlyState(), committedAt: sharedDate, hasPendingPostCommitWork: true))
        seedContext.insert(try makeMYR158Root(batchID: firstPendingID, index: 902, state: myr158QueueOnlyState(), committedAt: sharedDate, hasPendingPostCommitWork: true))
        try seedContext.save()

        let store = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        let requests = try store.loadPendingPostCommitRequests()

        XCTAssertEqual(requests.map(\.sourceBatchID), [firstPendingID, secondPendingID])
        XCTAssertEqual(store.testOnlyLastCandidateFetchCount, 2)
        XCTAssertEqual(store.testOnlyLastBackfillSaveCount, 0)
    }

    func testMYR158LegacyRowsBackfillOnceAndThenStayBounded() throws {
        let container = try makeMYR158Container()
        let seedContext = ModelContext(container)
        for index in 0..<300 {
            let row = try makeMYR158Root(index: index, state: .none, hasPendingPostCommitWork: false)
            row.hasPendingPostCommitWork = nil
            seedContext.insert(row)
        }
        let pendingA = postCommitUUID("00000000-0000-0000-0000-000000158911")
        let pendingB = postCommitUUID("00000000-0000-0000-0000-000000158912")
        for (index, batchID) in [pendingA, pendingB].enumerated() {
            let row = try makeMYR158Root(batchID: batchID, index: 400 + index, state: myr158QueueOnlyState(), hasPendingPostCommitWork: true)
            row.hasPendingPostCommitWork = nil
            seedContext.insert(row)
        }
        try seedContext.save()

        let firstStore = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        let firstRequests = try firstStore.loadPendingPostCommitRequests()

        XCTAssertEqual(firstRequests.map(\.sourceBatchID), [pendingA, pendingB])
        XCTAssertEqual(firstStore.testOnlyLastCandidateFetchCount, 302)
        XCTAssertEqual(firstStore.testOnlyLastBackfillSaveCount, 1)
        XCTAssertEqual(try myr158IndexCounts(container: container), MYR158IndexCounts(nilCount: 0, falseCount: 300, trueCount: 2))

        let secondStore = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        let secondRequests = try secondStore.loadPendingPostCommitRequests()

        XCTAssertEqual(secondRequests.map(\.sourceBatchID), [pendingA, pendingB])
        XCTAssertEqual(secondStore.testOnlyLastCandidateFetchCount, 2)
        XCTAssertEqual(secondStore.testOnlyLastBackfillSaveCount, 0)
    }

    func testMYR158UnindexedPendingRowIsIncludedByNullPredicateAndBackfilled() throws {
        let container = try makeMYR158Container()
        let batchID = postCommitUUID("00000000-0000-0000-0000-000000158921")
        let seedContext = ModelContext(container)
        let row = try makeMYR158Root(batchID: batchID, index: 921, state: myr158QueueOnlyState(), hasPendingPostCommitWork: true)
        row.hasPendingPostCommitWork = nil
        seedContext.insert(row)
        try seedContext.save()

        let store = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        let requests = try store.loadPendingPostCommitRequests()

        XCTAssertEqual(requests.map(\.sourceBatchID), [batchID])
        XCTAssertEqual(store.testOnlyLastCandidateFetchCount, 1)
        XCTAssertEqual(store.testOnlyLastBackfillSaveCount, 1)
        XCTAssertEqual(try myr158Root(batchID: batchID, container: container).hasPendingPostCommitWork, true)
    }

    func testMYR158CompletedLegacyBackfillDoesNotValidateImmutableWorkPayload() throws {
        let container = try makeMYR158Container()
        let batchID = postCommitUUID("00000000-0000-0000-0000-000000158931")
        let seedContext = ModelContext(container)
        let row = try makeMYR158Root(
            batchID: batchID,
            index: 931,
            state: .none,
            hasPendingPostCommitWork: false,
            postCommitWorkPayloadData: Data([0xde, 0xad, 0xbe, 0xef])
        )
        row.hasPendingPostCommitWork = nil
        seedContext.insert(row)
        try seedContext.save()

        let store = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        let requests = try store.loadPendingPostCommitRequests()

        XCTAssertEqual(requests, [])
        XCTAssertEqual(store.testOnlyLastCandidateFetchCount, 1)
        XCTAssertEqual(store.testOnlyLastBackfillSaveCount, 1)
        XCTAssertEqual(try myr158Root(batchID: batchID, container: container).hasPendingPostCommitWork, false)
    }

    func testMYR158PhaseOneFailureDoesNotPersistPartialBackfill() throws {
        let container = try makeMYR158Container()
        let seedContext = ModelContext(container)
        let validA = try makeMYR158Root(index: 941, state: .none, hasPendingPostCommitWork: false)
        let malformed = try makeMYR158Root(index: 942, state: .none, hasPendingPostCommitWork: false)
        let validB = try makeMYR158Root(index: 943, state: myr158QueueOnlyState(), hasPendingPostCommitWork: true)
        validA.hasPendingPostCommitWork = nil
        malformed.hasPendingPostCommitWork = nil
        malformed.postCommitStatePayloadData = Data([0x13, 0x70, 0x01])
        validB.hasPendingPostCommitWork = nil
        seedContext.insert(validA)
        seedContext.insert(malformed)
        seedContext.insert(validB)
        try seedContext.save()

        let store = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        XCTAssertThrowsError(try store.loadPendingPostCommitRequests()) { error in
            XCTAssertEqual(error as? SyncConvergencePostCommitFailure, .malformedPostCommitState(batchID: malformed.batchID))
        }
        XCTAssertEqual(try myr158Rows(container: container).map(\.hasPendingPostCommitWork), [nil, nil, nil])
    }

    func testMYR158MalformedPendingWorkPhaseOneDoesNotPersistBackfill() throws {
        let container = try makeMYR158Container()
        let seedContext = ModelContext(container)
        let validBefore = try makeMYR158Root(index: 945, state: .none, hasPendingPostCommitWork: false)
        let malformed = try makeMYR158Root(
            index: 946,
            state: myr158QueueOnlyState(),
            hasPendingPostCommitWork: true,
            postCommitWorkPayloadData: Data([0xde, 0xad, 0xbe, 0xef])
        )
        let validAfter = try makeMYR158Root(index: 947, state: myr158QueueOnlyState(), hasPendingPostCommitWork: true)
        for row in [validBefore, malformed, validAfter] {
            row.hasPendingPostCommitWork = nil
            seedContext.insert(row)
        }
        try seedContext.save()

        let store = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        XCTAssertThrowsError(try store.loadPendingPostCommitRequests()) { error in
            XCTAssertEqual(error as? SyncConvergencePostCommitFailure, .malformedPostCommitWorkPayload(batchID: malformed.batchID))
        }
        XCTAssertEqual(store.testOnlyLastBackfillSaveCount, 0)
        XCTAssertEqual(try myr158Rows(container: container).map(\.hasPendingPostCommitWork), [nil, nil, nil])
    }

    func testMYR158ContradictoryPendingWorkPhaseOneDoesNotPersistBackfill() throws {
        let container = try makeMYR158Container()
        let seedContext = ModelContext(container)
        let contradictoryPayload = try SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [],
            legacyCleanupRequired: false,
            presentationEntries: []
        ).encodedPayloadData()
        let pending = try makeMYR158Root(
            index: 948,
            state: myr158QueueOnlyState(),
            hasPendingPostCommitWork: true,
            postCommitWorkPayloadData: contradictoryPayload
        )
        pending.hasPendingPostCommitWork = nil
        seedContext.insert(pending)
        try seedContext.save()

        let store = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        XCTAssertThrowsError(try store.loadPendingPostCommitRequests()) { error in
            XCTAssertEqual(error as? SyncConvergencePostCommitFailure, .contradictoryPostCommitWorkPayload(batchID: pending.batchID))
        }
        XCTAssertEqual(store.testOnlyLastBackfillSaveCount, 0)
        XCTAssertEqual(try myr158Root(batchID: pending.batchID, container: container).hasPendingPostCommitWork, nil)
    }

    func testMYR158DirtySharedContextBackfillsWithoutSavingOrRollingBackCallerChanges() throws {
        let container = try makeMYR158Container()
        let pendingID = postCommitUUID("00000000-0000-0000-0000-000000158951")
        let completedID = postCommitUUID("00000000-0000-0000-0000-000000158952")
        let seedContext = ModelContext(container)
        let pending = try makeMYR158Root(batchID: pendingID, index: 951, state: myr158QueueOnlyState(), hasPendingPostCommitWork: true)
        let completed = try makeMYR158Root(batchID: completedID, index: 952, state: .none, hasPendingPostCommitWork: false)
        pending.hasPendingPostCommitWork = nil
        completed.hasPendingPostCommitWork = nil
        seedContext.insert(pending)
        seedContext.insert(completed)
        try seedContext.save()

        let dirtyContext = ModelContext(container)
        let note = Note(title: "Unsaved", content: "Body")
        dirtyContext.insert(note)
        let store = SwiftDataSyncConvergencePostCommitStore(context: dirtyContext)

        let requests = try store.loadPendingPostCommitRequests()

        XCTAssertEqual(requests.map(\.sourceBatchID), [pendingID])
        XCTAssertEqual(store.testOnlyLastCandidateFetchCount, 2)
        XCTAssertEqual(store.testOnlyLastBackfillSaveCount, 1)
        XCTAssertTrue(dirtyContext.hasChanges)
        XCTAssertEqual(note.title, "Unsaved")
        XCTAssertEqual(try myr158Root(batchID: pendingID, container: container).hasPendingPostCommitWork, true)
        XCTAssertEqual(try myr158Root(batchID: completedID, container: container).hasPendingPostCommitWork, false)
        XCTAssertTrue(try myr158PersistedNotes(container: container).isEmpty)
    }

    @MainActor
    func testMYR158RuntimeCompletedOnlyLegacyBackfillPreservesDirtyCallerState() async throws {
        let container = try makeMYR158Container()
        let completedID = postCommitUUID("00000000-0000-0000-0000-000000158955")
        let seedContext = ModelContext(container)
        let completed = try makeMYR158Root(batchID: completedID, index: 955, state: .none, hasPendingPostCommitWork: false)
        completed.hasPendingPostCommitWork = nil
        seedContext.insert(completed)
        try seedContext.save()

        let sharedContext = ModelContext(container)
        let unsavedNote = Note(title: "Unsaved runtime", content: "Body")
        sharedContext.insert(unsavedNote)
        let presentation = MYR158CountingPresentationAdapter()
        let runtime = SyncConvergenceRuntime(
            context: sharedContext,
            convergenceQueue: FileBackedSyncBatchQueue(fileURL: nil),
            localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil),
            localBatchTransportAdapter: nil,
            presentationAdapter: presentation
        )

        let outcome = await runtime.resumePendingWork()

        guard case .drained = outcome else { return XCTFail("Expected completed-only legacy recovery to drain, got \(outcome)") }
        XCTAssertEqual(presentation.requestCount, 0)
        XCTAssertTrue(sharedContext.hasChanges)
        XCTAssertEqual(unsavedNote.title, "Unsaved runtime")
        XCTAssertEqual(try myr158Root(batchID: completedID, container: container).hasPendingPostCommitWork, false)
        XCTAssertTrue(try myr158PersistedNotes(container: container).isEmpty)
    }

    @MainActor
    func testMYR158RuntimePendingLegacyRecoveryIsNotCorruptHistory() async throws {
        let container = try makeMYR158Container()
        let pendingID = postCommitUUID("00000000-0000-0000-0000-000000158956")
        let seedContext = ModelContext(container)
        let pending = try makeMYR158Root(batchID: pendingID, index: 956, state: myr158QueueOnlyState(), hasPendingPostCommitWork: true)
        pending.hasPendingPostCommitWork = nil
        seedContext.insert(pending)
        try seedContext.save()

        let sharedContext = ModelContext(container)
        sharedContext.insert(Note(title: "Dirty before CAS", content: "Body"))
        let runtime = SyncConvergenceRuntime(
            context: sharedContext,
            convergenceQueue: FileBackedSyncBatchQueue(fileURL: nil),
            localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil),
            localBatchTransportAdapter: nil,
            presentationAdapter: MYR158CountingPresentationAdapter()
        )

        let outcome = await runtime.resumePendingWork()

        if case .blocked(let failure) = outcome, failure.kind == .corruptHistory {
            XCTFail("Pending legacy recovery must not be misclassified as corrupt history")
        }
        guard case .drained = outcome else { return XCTFail("Expected pending legacy recovery to drain, got \(outcome)") }
        XCTAssertEqual(try myr158Root(batchID: pendingID, container: container).hasPendingPostCommitWork, false)
    }

    func testMYR158BackfillSaveFailureRollsBackAssignedIndexes() throws {
        let container = try makeMYR158Container()
        let batchID = postCommitUUID("00000000-0000-0000-0000-000000158961")
        let seedContext = ModelContext(container)
        let row = try makeMYR158Root(batchID: batchID, index: 961, state: myr158QueueOnlyState(), hasPendingPostCommitWork: true)
        row.hasPendingPostCommitWork = nil
        seedContext.insert(row)
        try seedContext.save()

        let failingStore = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        failingStore.testOnlyFailNextSaveAt = .backfill
        XCTAssertThrowsError(try failingStore.loadPendingPostCommitRequests()) { error in
            XCTAssertEqual(error as? SyncConvergencePostCommitFailure, .persistence)
        }
        XCTAssertEqual(failingStore.testOnlyLastBackfillSaveCount, 0)
        XCTAssertNil(failingStore.testOnlyFailNextSaveAt)
        XCTAssertEqual(try myr158Root(batchID: batchID, container: container).hasPendingPostCommitWork, nil)

        let retryStore = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        XCTAssertEqual(try retryStore.loadPendingPostCommitRequests().map(\.sourceBatchID), [batchID])
        XCTAssertEqual(try myr158Root(batchID: batchID, container: container).hasPendingPostCommitWork, true)
    }

    func testMYR158ContradictoryIndexesFailClosed() throws {
        let container = try makeMYR158Container()
        let trueButCompleted = postCommitUUID("00000000-0000-0000-0000-000000158971")
        let falseButPending = postCommitUUID("00000000-0000-0000-0000-000000158972")
        let seedContext = ModelContext(container)
        seedContext.insert(try makeMYR158Root(batchID: trueButCompleted, index: 971, state: .none, hasPendingPostCommitWork: true))
        seedContext.insert(try makeMYR158Root(batchID: falseButPending, index: 972, state: myr158QueueOnlyState(), hasPendingPostCommitWork: false))
        try seedContext.save()

        let pendingStore = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        XCTAssertThrowsError(try pendingStore.loadPendingPostCommitRequests()) { error in
            XCTAssertEqual(error as? SyncConvergencePostCommitFailure, .contradictoryPostCommitIndex(batchID: trueButCompleted))
        }
        XCTAssertEqual(pendingStore.testOnlyLastCandidateFetchCount, 1)

        let statusStore = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        XCTAssertThrowsError(try statusStore.loadPostCommitStatus(forBatchID: falseButPending)) { error in
            XCTAssertEqual(error as? SyncConvergencePostCommitFailure, .contradictoryPostCommitIndex(batchID: falseButPending))
        }
    }

    func testMYR158DirectNilReadsRemainNonmutatingUntilGlobalLoadBackfills() throws {
        let container = try makeMYR158Container()
        let pendingID = postCommitUUID("00000000-0000-0000-0000-000000158981")
        let completedID = postCommitUUID("00000000-0000-0000-0000-000000158982")
        let seedContext = ModelContext(container)
        let pending = try makeMYR158Root(batchID: pendingID, index: 981, state: myr158QueueOnlyState(), hasPendingPostCommitWork: true)
        let completed = try makeMYR158Root(batchID: completedID, index: 982, state: .none, hasPendingPostCommitWork: false)
        let pendingIdentity = pending.persistedIdentityForTest
        let completedIdentity = completed.persistedIdentityForTest
        pending.hasPendingPostCommitWork = nil
        completed.hasPendingPostCommitWork = nil
        seedContext.insert(pending)
        seedContext.insert(completed)
        try seedContext.save()

        let pendingLoadStore = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        guard case .fullRoot(let loadedPending) = try pendingLoadStore.loadState(matching: pendingIdentity) else {
            return XCTFail("Expected direct pending state load")
        }
        XCTAssertEqual(loadedPending.postCommitState, myr158QueueOnlyState())
        XCTAssertEqual(try myr158Root(batchID: pendingID, container: container).hasPendingPostCommitWork, nil)
        XCTAssertEqual(pendingLoadStore.testOnlyLastBackfillSaveCount, 0)

        let completedLoadStore = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        guard case .fullRoot(let loadedCompleted) = try completedLoadStore.loadState(matching: completedIdentity) else {
            return XCTFail("Expected direct completed state load")
        }
        XCTAssertEqual(loadedCompleted.postCommitState, .none)
        XCTAssertEqual(try myr158Root(batchID: completedID, container: container).hasPendingPostCommitWork, nil)
        XCTAssertEqual(completedLoadStore.testOnlyLastBackfillSaveCount, 0)

        let statusStore = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        guard case .pending(let request) = try statusStore.loadPostCommitStatus(forBatchID: pendingID) else {
            return XCTFail("Expected direct pending status")
        }
        XCTAssertEqual(request.sourceBatchID, pendingID)
        guard case .completed(let completedStatusIdentity) = try statusStore.loadPostCommitStatus(forBatchID: completedID) else {
            return XCTFail("Expected direct completed status")
        }
        XCTAssertEqual(completedStatusIdentity.batchID, completedID)
        XCTAssertEqual(try myr158Root(batchID: pendingID, container: container).hasPendingPostCommitWork, nil)
        XCTAssertEqual(try myr158Root(batchID: completedID, container: container).hasPendingPostCommitWork, nil)

        let globalStore = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        XCTAssertEqual(try globalStore.loadPendingPostCommitRequests().map(\.sourceBatchID), [pendingID])
        XCTAssertEqual(try myr158Root(batchID: pendingID, container: container).hasPendingPostCommitWork, true)
        XCTAssertEqual(try myr158Root(batchID: completedID, container: container).hasPendingPostCommitWork, false)
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
                expectedEvents: [.legacyCleanup(batchID: TestIDs.batch), .queueCleanup([TestIDs.batch, TestIDs.extraBatch])],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "queue presentation",
                state: SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: false, presentationRefreshPending: true),
                expectedOutcome: .complete,
                expectedEvents: [.presentation(noteID: TestIDs.noteA), .queueCleanup([TestIDs.batch, TestIDs.extraBatch])],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "legacy presentation",
                state: SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: true),
                expectedOutcome: .complete,
                expectedEvents: [.presentation(noteID: TestIDs.noteA), .legacyCleanup(batchID: TestIDs.batch)],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "all pending",
                state: SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: true, presentationRefreshPending: true),
                expectedOutcome: .complete,
                expectedEvents: [
                    .presentation(noteID: TestIDs.noteA),
                    .legacyCleanup(batchID: TestIDs.batch),
                    .queueCleanup([TestIDs.batch, TestIDs.extraBatch])
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
            XCTAssertEqual(store.writeCount, testCase.state.pendingWork.count, testCase.name)
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
                nil
            ),
            (
                SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: true),
                SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: false)
            ),
            (
                SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: true, presentationRefreshPending: true),
                SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: true, presentationRefreshPending: false)
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

            var expectedPending = state.pendingWork
            expectedPending.remove(.presentationRefresh)
            XCTAssertEqual(outcome, .pending(expectedPending))
            var expectedEvents: [PostCommitInvocationEvent] = []
            if state.presentationRefreshPending {
                expectedEvents.append(.presentation(noteID: TestIDs.noteA))
            }
            XCTAssertEqual(recorder.events, expectedEvents)
            XCTAssertEqual(store.persistedState, expectedPersistedState)
            XCTAssertEqual(store.currentWorkPayloadData, store.originalWorkPayloadData)
            XCTAssertEqual(store.writeCount, state.presentationRefreshPending ? 1 : 0)
        }
    }

    func testMYR138RelaunchFromEachPreCASCrashBoundaryReplaysAdaptersIdempotently() async throws {
        let identity = testIdentity()
        let allPending = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )
        let originalRoot = fullRootState(identity: identity, state: allPending)
        let originalRequest = request(identity: identity, state: allPending)
        let committedNote = note(id: TestIDs.noteA, title: "Relaunch", body: "Body")
        let workBytes = try XCTUnwrap(originalRoot.postCommitWorkPayloadData)
        let presentationHash = try XCTUnwrap(originalRoot.postCommitWorkPayload?.presentationEntries.first?.committedPostBodyHash)
        let cases: [(String, Bool, Bool, Bool)] = [
            ("before external work", false, false, false),
            ("after queue cleanup", true, false, false),
            ("after legacy cleanup", true, true, false),
            ("after presentation refresh", true, true, true)
        ]

        for testCase in cases {
            let ledger = DurablePostCommitExternalEffectLedger()
            if testCase.1 {
                ledger.seedQueueRemoval(Set(originalRequest.cleanupPlan.batchIDs))
            }
            if testCase.2 {
                ledger.seedLegacyCompletion(batchID: identity.batchID)
            }
            if testCase.3 {
                ledger.seedPresentationCompletion(
                    incorporationBatchID: identity.batchID,
                    noteID: TestIDs.noteA,
                    committedPostBodyHash: presentationHash
                )
            }
            let retryStore = try FakePostCommitStore(
                reloading: originalRoot.root,
                notes: [TestIDs.noteA: committedNote]
            )
            guard case .fullRoot(let reloadedRoot) = retryStore.state else {
                return XCTFail("Expected full root for \(testCase.0)")
            }
            XCTAssertEqual(reloadedRoot.postCommitStatePayloadData, originalRoot.root.postCommitStatePayloadData, testCase.0)
            XCTAssertEqual(reloadedRoot.postCommitWorkPayloadData, workBytes, testCase.0)
            XCTAssertEqual(reloadedRoot.postCommitState, allPending, testCase.0)
            let recorder = PostCommitInvocationRecorder()
            let queue = IdempotentQueueCleanupAdapter(ledger: ledger, recorder: recorder)
            let legacy = IdempotentLegacyCleanupAdapter(ledger: ledger, recorder: recorder)
            let presentation = IdempotentPresentationAdapter(ledger: ledger, recorder: recorder)
            let executor = SyncConvergencePostCommitExecutor(
                store: retryStore,
                queueCleanupAdapter: queue,
                legacyCleanupAdapter: legacy,
                presentationAdapter: presentation
            )

            let outcome = await executor.execute(originalRequest)

            XCTAssertEqual(outcome, .complete, testCase.0)
            XCTAssertEqual(recorder.events, [
                .presentation(noteID: TestIDs.noteA),
                .legacyCleanup(batchID: TestIDs.batch),
                .queueCleanup([TestIDs.batch, TestIDs.extraBatch])
            ], testCase.0)
            XCTAssertEqual(retryStore.currentPostCommitState, SyncConvergencePostCommitState.none, testCase.0)
            XCTAssertEqual(retryStore.currentWorkPayloadData, workBytes, testCase.0)
            XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: TestIDs.batch), 1, testCase.0)
            XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: TestIDs.extraBatch), 1, testCase.0)
            XCTAssertEqual(ledger.legacyPhysicalEffectCount(batchID: TestIDs.batch), 1, testCase.0)
            XCTAssertEqual(
                ledger.presentationPhysicalEffectCount(
                    incorporationBatchID: identity.batchID,
                    noteID: TestIDs.noteA,
                    committedPostBodyHash: presentationHash
                ),
                1,
                testCase.0
            )
        }
    }

    func testMYR138FailedFinalCASSameContextRetryReinvokesAdaptersWithoutDuplicatingEffects() async throws {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )
        let originalRoot = fullRootState(identity: identity, state: state)
        let workBytes = try XCTUnwrap(originalRoot.postCommitWorkPayloadData)
        let presentationHash = try XCTUnwrap(originalRoot.postCommitWorkPayload?.presentationEntries.first?.committedPostBodyHash)
        let committedNote = note(id: TestIDs.noteA, title: "Retry", body: "Body")
        let store = FakePostCommitStore(state: .fullRoot(originalRoot))
        store.notes[TestIDs.noteA] = committedNote
        store.casBehavior = .failPersistence
        let ledger = DurablePostCommitExternalEffectLedger()
        let recorder = PostCommitInvocationRecorder()
        let queue = IdempotentQueueCleanupAdapter(ledger: ledger, recorder: recorder)
        let legacy = IdempotentLegacyCleanupAdapter(ledger: ledger, recorder: recorder)
        let presentation = IdempotentPresentationAdapter(ledger: ledger, recorder: recorder)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            legacyCleanupAdapter: legacy,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .pending([.queueCleanup, .legacyCleanup, .presentationRefresh, .postCommitStatePersistence]))
        XCTAssertEqual(recorder.events, [.presentation(noteID: TestIDs.noteA)])
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(store.persistedState, nil)
        XCTAssertEqual(store.currentPostCommitState, state)
        XCTAssertEqual(store.currentWorkPayloadData, workBytes)
        XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: TestIDs.batch), 0)
        XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: TestIDs.extraBatch), 0)
        XCTAssertEqual(ledger.legacyPhysicalEffectCount(batchID: TestIDs.batch), 0)
        XCTAssertEqual(
            ledger.presentationPhysicalEffectCount(
                incorporationBatchID: identity.batchID,
                noteID: TestIDs.noteA,
                committedPostBodyHash: presentationHash
            ),
            1
        )

        store.casBehavior = .succeed

        let retryOutcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(retryOutcome, .complete)
        XCTAssertEqual(recorder.events, [
            .presentation(noteID: TestIDs.noteA),
            .legacyCleanup(batchID: TestIDs.batch),
            .queueCleanup([TestIDs.batch, TestIDs.extraBatch])
        ])
        XCTAssertEqual(store.currentPostCommitState, Optional(SyncConvergencePostCommitState.none))
        XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: TestIDs.batch), 1)
        XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: TestIDs.extraBatch), 1)
        XCTAssertEqual(ledger.legacyPhysicalEffectCount(batchID: TestIDs.batch), 1)
        XCTAssertEqual(
            ledger.presentationPhysicalEffectCount(
                incorporationBatchID: identity.batchID,
                noteID: TestIDs.noteA,
                committedPostBodyHash: presentationHash
            ),
            1
        )
    }

    func testMYR138FailedFinalCASFreshRelaunchDecodesBytesAndAvoidsDuplicateEffects() async throws {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )
        let committedNote = note(id: TestIDs.noteA, title: "Retry", body: "Body")
        let originalRoot = fullRootState(identity: identity, state: state)
        let workBytes = try XCTUnwrap(originalRoot.postCommitWorkPayloadData)
        let presentationHash = try XCTUnwrap(originalRoot.postCommitWorkPayload?.presentationEntries.first?.committedPostBodyHash)
        let store = FakePostCommitStore(state: .fullRoot(originalRoot))
        store.notes[TestIDs.noteA] = committedNote
        store.casBehavior = .failPersistence
        let ledger = DurablePostCommitExternalEffectLedger()
        let recorder = PostCommitInvocationRecorder()
        let queue = IdempotentQueueCleanupAdapter(ledger: ledger, recorder: recorder)
        let legacy = IdempotentLegacyCleanupAdapter(ledger: ledger, recorder: recorder)
        let presentation = IdempotentPresentationAdapter(ledger: ledger, recorder: recorder)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            legacyCleanupAdapter: legacy,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .pending([.queueCleanup, .legacyCleanup, .presentationRefresh, .postCommitStatePersistence]))
        XCTAssertEqual(recorder.events, [.presentation(noteID: TestIDs.noteA)])
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(store.persistedState, nil)
        XCTAssertEqual(store.currentPostCommitState, state)
        XCTAssertEqual(store.currentWorkPayloadData, workBytes)

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
        let retryQueue = IdempotentQueueCleanupAdapter(ledger: ledger, recorder: retryRecorder)
        let retryLegacy = IdempotentLegacyCleanupAdapter(ledger: ledger, recorder: retryRecorder)
        let retryPresentation = IdempotentPresentationAdapter(ledger: ledger, recorder: retryRecorder)
        let retryExecutor = SyncConvergencePostCommitExecutor(
            store: retryStore,
            queueCleanupAdapter: retryQueue,
            legacyCleanupAdapter: retryLegacy,
            presentationAdapter: retryPresentation
        )

        let retryOutcome = await retryExecutor.execute(request(identity: identity, state: state))

        XCTAssertEqual(retryOutcome, .complete)
        XCTAssertEqual(retryRecorder.events, [
            .presentation(noteID: TestIDs.noteA),
            .legacyCleanup(batchID: TestIDs.batch),
            .queueCleanup([TestIDs.batch, TestIDs.extraBatch])
        ])
        XCTAssertEqual(retryStore.persistedState, Optional(SyncConvergencePostCommitState.none))
        XCTAssertEqual(retryStore.currentPostCommitState, Optional(SyncConvergencePostCommitState.none))
        XCTAssertEqual(retryStore.writeCount, 3)
        XCTAssertEqual(retryStore.currentWorkPayloadData, retryStore.originalWorkPayloadData)
        XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: TestIDs.batch), 1)
        XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: TestIDs.extraBatch), 1)
        XCTAssertEqual(ledger.legacyPhysicalEffectCount(batchID: TestIDs.batch), 1)
        XCTAssertEqual(
            ledger.presentationPhysicalEffectCount(
                incorporationBatchID: identity.batchID,
                noteID: TestIDs.noteA,
                committedPostBodyHash: presentationHash
            ),
            1
        )
    }

    func testMYR138CommittedFinalStateSurvivesLostCASResponseAndRelaunchesComplete() async throws {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )
        let originalRoot = fullRootState(identity: identity, state: state)
        let originalStateBytes = originalRoot.postCommitStatePayloadData
        let workBytes = try XCTUnwrap(originalRoot.postCommitWorkPayloadData)
        let presentationHash = try XCTUnwrap(originalRoot.postCommitWorkPayload?.presentationEntries.first?.committedPostBodyHash)
        let committedNote = note(id: TestIDs.noteA, title: "Lost Ack", body: "Body")
        let store = FakePostCommitStore(state: .fullRoot(originalRoot))
        store.notes[TestIDs.noteA] = committedNote
        store.casBehavior = .commitThenFailResponse
        let ledger = DurablePostCommitExternalEffectLedger()
        let recorder = PostCommitInvocationRecorder()
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: IdempotentQueueCleanupAdapter(ledger: ledger, recorder: recorder),
            legacyCleanupAdapter: IdempotentLegacyCleanupAdapter(ledger: ledger, recorder: recorder),
            presentationAdapter: IdempotentPresentationAdapter(ledger: ledger, recorder: recorder)
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .pending([.queueCleanup, .legacyCleanup, .postCommitStatePersistence]))
        guard case .fullRoot(let committedRoot) = store.state else {
            return XCTFail("Expected committed root after lost CAS response")
        }
        let stateAfterLostLegacyCAS = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: false
        )
        XCTAssertEqual(store.currentPostCommitState, stateAfterLostLegacyCAS)
        XCTAssertEqual(committedRoot.postCommitState, stateAfterLostLegacyCAS)
        XCTAssertNotEqual(committedRoot.postCommitStatePayloadData, originalStateBytes)
        XCTAssertEqual(committedRoot.postCommitWorkPayloadData, workBytes)
        XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: TestIDs.batch), 0)
        XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: TestIDs.extraBatch), 0)
        XCTAssertEqual(ledger.legacyPhysicalEffectCount(batchID: TestIDs.batch), 1)
        XCTAssertEqual(
            ledger.presentationPhysicalEffectCount(
                incorporationBatchID: identity.batchID,
                noteID: TestIDs.noteA,
                committedPostBodyHash: presentationHash
            ),
            1
        )

        let retryStore = try FakePostCommitStore(
            reloading: committedRoot.root,
            notes: [TestIDs.noteA: committedNote]
        )
        guard case .fullRoot(let reloadedRoot) = retryStore.state else {
            return XCTFail("Expected full root after committed-root reload")
        }
        XCTAssertEqual(reloadedRoot.postCommitState, stateAfterLostLegacyCAS)
        XCTAssertEqual(reloadedRoot.postCommitStatePayloadData, committedRoot.root.postCommitStatePayloadData)
        let retryRecorder = PostCommitInvocationRecorder()
        let retryExecutor = SyncConvergencePostCommitExecutor(
            store: retryStore,
            queueCleanupAdapter: IdempotentQueueCleanupAdapter(ledger: ledger, recorder: retryRecorder),
            legacyCleanupAdapter: IdempotentLegacyCleanupAdapter(ledger: ledger, recorder: retryRecorder),
            presentationAdapter: IdempotentPresentationAdapter(ledger: ledger, recorder: retryRecorder)
        )

        let retryOutcome = await retryExecutor.execute(request(identity: identity, state: state))

        XCTAssertEqual(retryOutcome, .complete)
        XCTAssertEqual(retryRecorder.events, [.queueCleanup([TestIDs.batch, TestIDs.extraBatch])])
        XCTAssertEqual(retryStore.casAttemptCount, 1)
        XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: TestIDs.batch), 1)
        XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: TestIDs.extraBatch), 1)
        XCTAssertEqual(ledger.legacyPhysicalEffectCount(batchID: TestIDs.batch), 1)
        XCTAssertEqual(
            ledger.presentationPhysicalEffectCount(
                incorporationBatchID: identity.batchID,
                noteID: TestIDs.noteA,
                committedPostBodyHash: presentationHash
            ),
            1
        )
    }

    func testMYR138TombstoneRelaunchAfterQueueEffectReverifiesIdempotentlyWithoutCAS() async {
        let identity = testIdentity()
        let ledger = DurablePostCommitExternalEffectLedger()
        ledger.seedQueueRemoval([identity.batchID])
        XCTAssertFalse(ledger.containsBatch(identity.batchID))
        let recorder = PostCommitInvocationRecorder()
        let store = FakePostCommitStore(state: .tombstone(tombstone(identity: identity)))
        let queue = IdempotentQueueCleanupAdapter(ledger: ledger, recorder: recorder)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            presentationAdapter: FakePresentationAdapter(result: .verifiedComplete)
        )

        let outcome = await executor.execute(request(
            identity: identity,
            state: .none,
            presentationPlan: SyncConvergencePresentationPlan(noteRoutings: [:])
        ))

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(recorder.events, [.queueCleanup([TestIDs.batch])])
        XCTAssertEqual(queue.verificationChecks, [identity.batchID])
        XCTAssertEqual(ledger.queuePhysicalEffectCount(batchID: identity.batchID), 1)
        XCTAssertEqual(store.casAttemptCount, 0)
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
            ("whole note fallback without rewrite receipt", [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .wholeNoteFallback,
                    expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: "pre"),
                    committedPostBodyHash: postHash,
                    incrementalOperations: []
                )
            ]),
            ("whole note fallback with contradictory rewrite receipt", [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .wholeNoteFallback,
                    expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: "pre"),
                    committedPostBodyHash: postHash,
                    incrementalOperations: [],
                    rewriteSafetyReceipt: SyncConvergenceRewriteSafetyReceipt(
                        noteID: TestIDs.noteB,
                        priorBodyHash: SyncBatchContentHash.sha256Hex(for: "wrong"),
                        candidateBodyHash: postHash,
                        consumedDeleteIdentities: []
                    )
                )
            ]),
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
        XCTAssertEqual(sha256Hex(data), "7e4815ab5ec666a687c94d422eb5a582ffd9da12529532654c3cd506bfc591ad")
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

    private func makeMYR158Container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func myr158QueueOnlyState() -> SyncConvergencePostCommitState {
        SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: false
        )
    }

    private func makeMYR158Root(
        batchID: UUID? = nil,
        index: Int,
        state: SyncConvergencePostCommitState,
        committedAt: Date? = nil,
        hasPendingPostCommitWork: Bool,
        postCommitWorkPayloadData: Data? = nil
    ) throws -> IncorporatedSyncBatch {
        let resolvedBatchID = batchID ?? postCommitUUID(String(format: "00000000-0000-0000-0000-%012d", 158_000 + index))
        let workPayloadData: Data
        if let postCommitWorkPayloadData {
            workPayloadData = postCommitWorkPayloadData
        } else {
            workPayloadData = try SyncConvergencePostCommitWorkPayloadV1(
                queueCleanupBatchIDs: state.queueCleanupPending ? [resolvedBatchID] : [],
                legacyCleanupRequired: state.legacyCleanupPending,
                presentationEntries: []
            ).encodedPayloadData()
        }
        return IncorporatedSyncBatch(
            batchID: resolvedBatchID,
            originDeviceID: postCommitUUID("00000000-0000-0000-0000-000000158001"),
            createdAt: Date(timeIntervalSince1970: TimeInterval(158_000 + index)),
            batchSequence: UInt64(index),
            schemaVersion: 1,
            committedAt: committedAt ?? Date(timeIntervalSince1970: TimeInterval(159_000 + index)),
            canonicalPayloadDigest: String(format: "%064d", index),
            canonicalPayloadDigestFormatVersion: 1,
            committedResultDigest: String(format: "%064d", index + 1_000),
            committedResultDigestFormatVersion: 1,
            affectedNotesPayloadData: try SyncConvergenceAffectedNotesPayloadV1(noteIDs: []).encodedData(),
            authoritativeChildCount: 0,
            authoritativeChildBytes: 0,
            authoritativeChildrenDigest: String(repeating: "c", count: 64),
            postCommitWorkPayloadData: workPayloadData,
            postCommitStatePayloadData: try state.encodedPayloadData(),
            hasPendingPostCommitWork: hasPendingPostCommitWork
        )
    }

    private func myr158Rows(container: ModelContainer) throws -> [IncorporatedSyncBatch] {
        try ModelContext(container)
            .fetch(FetchDescriptor<IncorporatedSyncBatch>())
            .sorted { $0.batchID.uuidString < $1.batchID.uuidString }
    }

    private func myr158Root(batchID: UUID, container: ModelContainer) throws -> IncorporatedSyncBatch {
        try XCTUnwrap(
            ModelContext(container)
                .fetch(FetchDescriptor<IncorporatedSyncBatch>(predicate: #Predicate { $0.batchID == batchID }))
                .first
        )
    }

    private func myr158PersistedNotes(container: ModelContainer) throws -> [Note] {
        try ModelContext(container).fetch(FetchDescriptor<Note>())
    }

    private func myr158IndexCounts(container: ModelContainer) throws -> MYR158IndexCounts {
        try myr158Rows(container: container).reduce(into: MYR158IndexCounts()) { counts, row in
            switch row.hasPendingPostCommitWork {
            case .none:
                counts.nilCount += 1
            case .some(false):
                counts.falseCount += 1
            case .some(true):
                counts.trueCount += 1
            }
        }
    }

}

private struct MYR158IndexCounts: Equatable {
    var nilCount = 0
    var falseCount = 0
    var trueCount = 0
}

@MainActor
private final class MYR158CountingPresentationAdapter: SyncConvergencePresentationAdapter {
    private(set) var requestCount = 0

    func refreshPresentation(
        for request: SyncConvergencePresentationRequest
    ) async -> SyncConvergencePostCommitAdapterResult {
        requestCount += 1
        return .verifiedComplete
    }
}

private extension IncorporatedSyncBatch {
    var persistedIdentityForTest: SyncConvergencePersistedIncorporationIdentity {
        SyncConvergencePersistedIncorporationIdentity(
            batchID: batchID,
            canonicalPayloadDigest: canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: canonicalPayloadDigestFormatVersion,
            committedResultDigest: committedResultDigest,
            committedResultDigestFormatVersion: committedResultDigestFormatVersion
        )
    }
}
