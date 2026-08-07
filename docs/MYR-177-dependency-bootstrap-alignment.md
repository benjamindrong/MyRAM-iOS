# MYR-177 Dependency and Bootstrap Alignment

## Scope

This record covers MYR-177 Slice 1 and Slice 2: durable structural-dependency recovery, deterministic retry, bootstrap admission and conflict isolation, explicit structural-foundation presence, and dark completion integration.

The approved reference set remains pinned to the exact revisions reviewed for MYR-177:

- Reference A: `64248a12829d04f62ddf3230c6c592f6226b57ab`
- Reference B: `cdeb8053c3aa2510189429d717ab09e70f134716`
- Reference C: `5fa067b182ddda3ea2477c4d5e4054da7318973f`
- Reference D: `89c162d3c1ae02c426c9002419aef0814e779ed8`
- Reference E: `26f9425ef74d45937e00d6c8ec2e8bb12889013d`

Repository names, organizations, URLs, and copied external source remain intentionally omitted. Slice 2 carries these approved revisions forward without substituting later or inferred reference content.

## Durable recovery and interruption ordering

Slice 1 established a versioned file-backed recovery store, exact anchored-change preservation, deterministic restart reconstruction, persisted store health, compare-and-swap transitions, atomic replacement, and rollback on write failure.

The ordering contract remains:

1. plan without mutation;
2. persist application state;
3. durably apply recovery-store transitions;
4. acknowledge only after both boundaries succeed.

Slice 2 does not activate that transaction. MYR-179 remains responsible for production application-state persistence, recovery cleanup ordering, publication, and acknowledgement.

Production locations:

- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryTypes.swift`
- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryPlanner.swift`
- `MyRAM/Sync/Batch/FileBackedSyncBatchAnchoredRecoveryStore.swift`

Representative retained tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testFileBackedInterruptedCleanupSurvivesRestartAndCleansUpExactly`
- `SyncBatchAnchoredRecoveryStoreTests.testWriteFailureRollsBackMemoryAndDiskAndMarksWriteFailure`
- `SyncBatchAnchoredRecoveryStoreTests.testCorruptAndUnsupportedVersionRemainDistinct`

## Structural identity and deterministic retry

MYR-177 continues to treat stable operation and element identity, not visible offsets, as replay authority. Recovery preserves complete missing insertion anchors and missing deletion-target operation IDs. Tombstoned runs remain structurally represented and can satisfy dependencies.

Slice 2 retains the Slice 1 bounded worklist and extends initial planning so a newly represented operation can progress newly satisfiable waiting records in the same immutable plan. Reindexing remains exact when replay reveals another dependency, and transition collapse is still computed against the original durable snapshot.

Production location:

- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryPlanner.swift`

Representative tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testRetryReindexesFromOneMissingAnchorToAnother`
- `SyncBatchAnchoredRecoveryPlannerTests.testMultiLevelInsertionChainProgressesInOneDeterministicPlan`
- `SyncBatchAnchoredRecoveryPlannerTests.testSameAnchorSnapshotOrderDoesNotChangePlan`
- `SyncBatchAnchoredRecoveryPlannerTests.testNonemptyBootstrapUnblocksWaitingDependentInSameInitialPlan`
- `SyncBatchAnchoredRecoveryTests.testNativeMacBootstrapUnblocksWaitingDependentInSamePlan`

## Duplicate and collision semantics preserved from Slice 1

Slice 2 preserves the merged Slice 1 rules exactly:

- fresh structural duplicates retain normal `AnchoredSequenceCore` validation;
- applied equivalence is available only when an existing durable recovery record proves interrupted cleanup;
- same-key/different-content redelivery of a waiting record terminalizes the original stored change as identity collision;
- conflicting redelivery against an already-terminal record cannot rewrite the durable terminal record.

Bootstrap handling does not weaken these rules or reuse applied-equivalence as general duplicate acceptance.

Representative tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testFreshInsertionDuplicateUsesCoreDuplicateRun`
- `SyncBatchAnchoredRecoveryPlannerTests.testPersistedRecoveryInsertionWithNonEquivalentStateBecomesTerminalIdentityCollision`
- `SyncBatchAnchoredRecoveryPlannerTests.testConflictingWaitingRedeliveryTerminalizesOriginalRecordAndPersists`
- `SyncBatchAnchoredRecoveryPlannerTests.testConflictingRedeliveryCannotRewriteExistingTerminalRecord`

## Deterministic bootstrap descriptor

`AnchoredSequenceCore` now exposes `SyncTextLegacyBootstrapDescriptor`, containing the deterministic synthetic bootstrap `operationID` and canonical `SyncTextSequenceState`.

The identity derivation remains versioned and based on the note ID plus exact UTF-16 body. Empty content still produces canonical `.empty` sequence state, but its synthetic operation identity is retained by the descriptor. Only explicitly represented format versions are accepted.

Production location:

- `Packages/AnchoredSequenceCore/Sources/AnchoredSequenceCore/SyncTextLegacyBootstrap.swift`

Proving tests:

- `SyncTextLegacyBootstrapTests.testV1EmptyKnownVectorFreezesDeterministicOperationID`
- `SyncTextLegacyBootstrapTests.testV1KnownVectorFreezesDeterministicOperationID`
- `SyncTextLegacyBootstrapTests.testDescriptorMatchesExistingStateAPI`
- `SyncTextLegacyBootstrapTests.testUnknownFormatVersionCannotBeConstructed`

## Foundation admission

Slice 2 makes structural-foundation presence explicit:

- `.absent`
- `.established(SyncTextSequenceState)`

An absent foundation is not an empty document. Bootstrap may classify either state. Ordinary anchored insertion, deletion, dependency retry, and restart recovery require `.established` and fail closed with `missingStructuralFoundation(noteID:)` when the foundation is absent.

No `.empty` candidate is synthesized for ordinary replay, no recovery record is created merely because the foundation is absent, and no positional fallback is available through this seam.

An admissible empty bootstrap transitions `.absent` to `.established(.empty)`, so `didChangeApplicationState` is true even though the sequence value and visible text are empty. Equivalent bootstrap against `.established(.empty)` is idempotent and reports no application-state change.

Production locations:

- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryTypes.swift`
- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryPlanner.swift`

Proving tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testAbsentNonemptyBootstrapIsAdmissibleAndEstablishesFoundation`
- `SyncBatchAnchoredRecoveryPlannerTests.testAbsentEmptyBootstrapEstablishesEmptyFoundationWithoutOperation`
- `SyncBatchAnchoredRecoveryPlannerTests.testMissingFoundationRejectsInitialInsertionAndDeletionWithoutMutation`
- `SyncBatchAnchoredRecoveryPlannerTests.testMissingFoundationRejectsDependencyAndRestartRetry`
- `SyncBatchAnchoredRecoveryTests.testNativeMacEmptyBootstrapEstablishesFoundationWithoutOperation`
- `SyncBatchAnchoredRecoveryTests.testNativeMacMissingFoundationRejectsInsertionDeletionAndRetry`

## Bootstrap classification and conflict isolation

A validated bootstrap change stores the note ID, exact body, supported format version, and core-derived operation ID. Construction and decoding recompute the descriptor identity and reject unsupported or tampered input.

Classification is structural:

- absent foundation: admissible;
- established state exactly equal to the canonical bootstrap state: idempotent;
- any other established structural state: bootstrap-content conflict.

Visible-text equality does not establish equivalence. Tombstoned history therefore conflicts even if visible text would otherwise permit a legacy snapshot to appear current. Rejected bootstrap exposes no structural operation and does not enter dependency waiting or rewrite-safety handling.

Representative tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testEquivalentNonemptyBootstrapIsIdempotentAndExposesRepresentedOperation`
- `SyncBatchAnchoredRecoveryPlannerTests.testSameVisibleTextWithDifferentStructureCreatesBootstrapConflict`
- `SyncBatchAnchoredRecoveryPlannerTests.testTombstoneHistoryConflictsAndLateBootstrapCannotResurrectContent`
- `SyncBatchAnchoredRecoveryPlannerTests.testBootstrapCannotWaitAndOrdinaryChangesCannotHoldBootstrapConflict`
- `SyncBatchAnchoredRecoveryTests.testNativeMacBootstrapAdmissionIdempotenceAndConflict`
- `SyncBatchAnchoredRecoveryTests.testNativeMacBootstrapTombstoneConflictPreservesExactEvidence`

## Recovery-owned structural conflict evidence

Bootstrap conflicts persist the exact validated incoming bootstrap change plus recovery-owned structural evidence for the established sequence state. The evidence contains run operation IDs, insertion-origin endpoints, exact run text, fragment operation IDs, fragment ranges, and visibility/tombstone state.

Evidence reconstruction passes through normal `SyncTextInsertionOrigin`, `SyncTextSequenceRun`, `SyncTextSequenceFragment`, and `SyncTextSequenceState` validation. Malformed evidence is rejected during decoding. The representation does not depend on SwiftData records, revision fields, or sequence-persistence payload metadata.

Conflict reasons are intentionally minimal:

- `nonEquivalentEstablishedState`
- `tombstoneHistory`

Persisted reason and evidence must agree; a forged tombstone reason without tombstone evidence is rejected.

Production location:

- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryTypes.swift`

Proving tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testStructuralEvidenceRoundTripsExactlyAndRejectsMalformedState`
- `SyncBatchAnchoredRecoveryPlannerTests.testBootstrapChangeDecodingRejectsUnsupportedVersionAndTamperedIdentity`
- `SyncBatchAnchoredRecoveryPlannerTests.testBootstrapConflictPersistsAndSurvivesRestartExactly`
- `SyncBatchAnchoredRecoveryPlannerTests.testBootstrapConflictWriteFailurePreservesPriorMemoryAndDisk`
- `SyncBatchAnchoredRecoveryTests.testNativeMacBootstrapConflictDecodingRejectsReasonEvidenceMismatch`

## Host and activation boundaries

The Slice 2 planner and recovery types remain shared source used by the iPhone and native Mac test targets. No duplicated platform production implementation is introduced.

The production activation boundary remains unchanged:

- anchored capability remains disabled;
- the dark recovery planner has no active production caller;
- no anchored queue admission, capture, emission, convergence submission, editor publication, persistence wiring, or acknowledgement is added;
- no raw-offset fallback or general replay-time `baseContentHash` gate is introduced;
- SwiftData schema and transport formats remain unchanged.

MYR-179 remains the sole production activation boundary. MYR-180 remains responsible for live two-device closure.

Exact-head target membership, zero-production-reachability, capability, transport, schema, editor, acknowledgement, offset/hash, NearbySyncCore, and changed-scope audits are part of the Slice 2 local completion runner and completion evidence.
