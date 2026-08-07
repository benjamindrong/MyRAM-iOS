# MYR-177 Dependency and Bootstrap Alignment

## Scope

This record covers MYR-177 Slice 1 only: durable structural-dependency deferral, deterministic retry, interruption recovery, and immutable commit planning. Bootstrap conflict classification remains Slice 2.

The approved reference set was reviewed at these exact revisions:

- Reference A: `64248a12829d04f62ddf3230c6c592f6226b57ab`
- Reference B: `cdeb8053c3aa2510189429d717ab09e70f134716`
- Reference C: `5fa067b182ddda3ea2477c4d5e4054da7318973f`
- Reference D: `89c162d3c1ae02c426c9002419aef0814e779ed8`
- Reference E: `26f9425ef74d45937e00d6c8ec2e8bb12889013d`

Repository names, organizations, URLs, and copied external source are intentionally omitted.

## Alignment summary

### Durable state and restart

Reference A serializes synchronization state independently from transient reliable-session state and requires explicit reset after an interrupted session. Reference B separates durable document bytes from in-memory orchestration and reconstructs state by loading the durable base plus incremental changes.

MYR-177 adopts:

- a versioned recovery-store envelope;
- exact operation payload preservation;
- deterministic reconstruction of the dependency index after restart;
- explicit persisted-store health instead of assuming decoded state is usable.

MYR-177 deliberately diverges by storing unresolved anchored operations rather than peer-session state or whole-document change chunks. This keeps the persistence scope limited to the ticket and avoids introducing a second synchronization engine.

Production locations:

- `SyncBatchAnchoredRecoveryTypes.swift`
- `FileBackedSyncBatchAnchoredRecoveryStore.swift`

Proving tests:

- `SyncBatchAnchoredRecoveryStoreTests.testStoreRoundTripsRecordsInDeterministicOrder`
- `SyncBatchAnchoredRecoveryStoreTests.testCorruptAndUnsupportedVersionRemainDistinct`
- `SyncBatchAnchoredRecoveryTests.testNativeMacRecoveryStoreRoundTripsTemporaryFile`

### Persist before cleanup

Reference B compacts by durably storing the replacement document before removing incremental chunks. Removal is intentionally last so interruption cannot destroy the only recoverable representation.

MYR-177 adopts the same ordering invariant for future activation:

1. plan without mutation;
2. persist application state;
3. durably apply recovery-store transitions;
4. acknowledge only after both boundaries succeed.

Slice 1 does not wire that transaction. It returns an immutable commit plan and retains the original record until explicit commit confirmation.

Production location:

- `SyncBatchAnchoredRecoveryPlanner.swift`

Proving tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testInterruptedInsertionCleanupUsesExactAppliedEquivalence`
- `SyncBatchAnchoredRecoveryStoreTests.testWriteFailureRollsBackMemoryAndDiskAndMarksWriteFailure`

Deferred ownership:

- MYR-179 owns application-state persistence, recovery transition application, publication, and acknowledgement ordering.

### Structural identity and dependency progress

Reference D represents changes with stable actor, sequence, dependency, operation, object, and element identities. Its text metadata keeps deleted elements structurally represented. Reference E likewise retains deleted structure and anchor-related metadata rather than treating current visible offsets as durable identity.

MYR-177 adopts:

- note identity plus anchored operation identity as the recovery key;
- complete missing element identity for insertion deferral;
- missing target operation identity for deletion deferral;
- operation-ID-indexed retry;
- tombstoned runs as structurally available dependencies;
- exact original anchored changes as replay authority.

MYR-177 deliberately rejects:

- visible-offset reconstruction;
- retargeting delete spans;
- current-body placement authority;
- generic Boolean retry state;
- payload expiry.

Production locations:

- `SyncBatchAnchoredRecoveryTypes.swift`
- `SyncBatchAnchoredRecoveryPlanner.swift`

Proving tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testInitialMissingInsertionCreatesExactWaitingRecord`
- `SyncBatchAnchoredRecoveryPlannerTests.testDeletionWaitsForTargetThenTombstonesIt`
- `SyncBatchAnchoredRecoveryPlannerTests.testRetryReindexesFromOneMissingAnchorToAnother`

### Deterministic bounded retry

Reference D records explicit causal dependencies on each change rather than discovering readiness through repeated full-state polling. Reference A uses stable change hashes and heads to describe causal state. Reference B keeps document and synchronization state behind serialized ownership boundaries.

MYR-177 adopts:

- one dependency index rebuilt from durable records;
- canonical operation ordering;
- stable recovery-key tie-breaking;
- one in-memory candidate sequence state;
- bounded chained progression when successful insertion exposes another structural operation;
- exact reindexing when replay reveals a different missing dependency.

MYR-177 deliberately does not adopt Reference D's volatile timer queue because that queue has no durable retry or failure-preservation contract.

Production location:

- `SyncBatchAnchoredRecoveryPlanner.swift`

Proving tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testInsertionRetriesAfterParentArrivalAndProducesRemovalPlan`
- `SyncBatchAnchoredRecoveryPlannerTests.testRetryReindexesFromOneMissingAnchorToAnother`
- `SyncBatchAnchoredRecoveryPlannerTests.testMultiLevelInsertionChainProgressesInOneDeterministicPlan`
- `SyncBatchAnchoredRecoveryPlannerTests.testSameAnchorSnapshotOrderDoesNotChangePlan`
- `SyncBatchAnchoredRecoveryPlannerTests.testRetryMetricsSelectOnlyTriggeredDependencyChain`

### Duplicate delivery and interruption recovery

The approved references preserve operation or change identities across transport, persistence, merge, and deletion. Reference B compares durable document heads before saving and retains recoverable incremental data until replacement persistence succeeds.

MYR-177 adopts exact applied equivalence only for interrupted cleanup:

- insertion requires the same operation ID, origin endpoints, and text;
- deletion relies on identity-targeted tombstoning being idempotent;
- non-equivalent reuse of an insertion identity is terminal.

This does not weaken `AnchoredSequenceCore` duplicate-run validation and does not add a delete ledger.

Production location:

- `SyncBatchAnchoredRecoveryPlanner.swift`

Proving tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testInterruptedInsertionCleanupUsesExactAppliedEquivalence`
- `SyncBatchAnchoredRecoveryPlannerTests.testSameInsertionIdentityWithDifferentTextBecomesTerminal`
- `SyncBatchAnchoredRecoveryStoreTests.testSameKeyDifferentContentIsRejectedWithoutOverwrite`

### Host and platform boundaries

Reference C was reviewed for host-level document persistence and synchronization ownership. Its application-facing integration reinforces that transport, persistence, and UI publication are separate concerns from structural change semantics.

MYR-177 adopts only shared, future-callable dark components. It does not activate platform controllers or editor publication.

Production and test locations:

- shared sources under `MyRAM/Sync/Batch/`;
- iPhone coverage under `MyRAMTests/`;
- native Mac coverage under `MyRAMMacTests/`;
- explicit shared-source and test-target membership in `MyRAM.xcodeproj/project.pbxproj`.

Proving tests and audits:

- `SyncBatchAnchoredRecoveryTests.testNativeMacPlansMissingInsertionAndRetry`
- `SyncBatchAnchoredRecoveryTests.testNativeMacRecoveryStoreRoundTripsTemporaryFile`
- exact target-membership audit in the Slice 1 local completion runner

Deferred ownership:

- MYR-179 owns production wiring.
- MYR-180 owns live two-device verification and Stage 2 closure.

## Bootstrap review carried forward to Slice 2

The approved reference review also covered conflict isolation, existing structural history, deleted-state retention, and host integration boundaries. Slice 2 must map those observations to:

- admissible bootstrap;
- exact idempotent bootstrap;
- bootstrap-content conflict;
- late-bootstrap rejection after edit or tombstone history;
- prohibition against ordinary dependency or rewrite-safety conflict routing.

No bootstrap production code is added in Slice 1.
