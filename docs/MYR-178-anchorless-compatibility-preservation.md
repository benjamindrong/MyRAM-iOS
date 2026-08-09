# MYR-178 Anchorless Compatibility Preservation

## Slice 1 baseline

- Refreshed `main`: `535345898ce7f03fbe00db357a04d07fdd8750ba`.
- Instruction repository: `5eab9420bf8ef6dd72ae6efc9dae4d7d0182bbea`.
- MYR-177 Slice 2 is present on the baseline.
- Slice 1 is dark: the new classifier has no active production caller and changes no replay behavior.

## Completed structural boundaries preserved from MYR-175 through MYR-177

Slice 1 does not alter anchored insertion ordering, deletion identity, tombstones, dependency recovery, bootstrap admission/conflict handling, structural materialization, or recovery-store behavior. Anchored capability remains dark.

Relevant completed boundaries remain in:

- `MyRAM/Sync/Batch/SyncBatchAnchoredPayloadAdapter.swift`
- `MyRAM/Sync/Batch/SyncBatchAnchoredPayloadPolicy.swift`
- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryPlanner.swift`
- `MyRAM/Sync/Batch/FileBackedSyncBatchAnchoredRecoveryStore.swift`

The new anchorless decision is only a compatibility classifier. It does not create a structural ordering, replay, or materialization mechanism.

## Direct positional replay entry points

The post-MYR-177 production map contains these raw-offset application boundaries:

- iPhone direct application:
  - `MyRAM/iOS/Sync/Batch/IPhoneSyncBatchApplier.swift`
  - `apply(_:)`
  - `applyBodyTextInserted(_:)`
  - `applyBodyTextDeleted(_:)`
- Native Mac direct application:
  - `MyRAM/Mac/Sync/MacSyncBatchApplier.swift`
  - `apply(_:)`
  - `applyBodyTextInserted(_:rollbackSnapshots:)`
  - `applyBodyTextDeleted(_:rollbackSnapshots:)`
- Shared preflight positional simulation:
  - `MyRAM/Sync/Batch/SyncBatchPayload.swift`
  - `SyncBatchPreflight.validate(batch:bodyProvider:)`
- Convergence positional planning:
  - `MyRAM/Sync/Convergence/SyncConvergencePlanner.swift`
  - `planSequentialBodyChange`
  - `SyncOperationReplayEngine.planLegacy`
  - `SyncOperationReplayEngine.planMatchingBase`
  - `SyncOperationReplayEngine.replaySingle`

Slice 1 does not wire the new decision into any of these entry points. Slice 2 owns that activation and structural guarding.

## Matching-base evidence and exact provenance

Slice 1 accepts exactly one evidence source for positive direct-replay eligibility: declared `baseContentHash` on an anchorless insertion or deletion.

The production provenance contract is shared across platforms:

- `MyRAM/Sync/Batch/SyncBatchNoteChangeCapture.swift`
- `SyncBatchNoteChangeCapture.capturedBodyChanges` delegates to `bodyTextChanges`.
- `bodyTextChanges` delegates to `SyncBatchBodyEditScript.changes`.
- `SyncBatchBodyEditScript.makeInsert` and `makeDelete` set `baseContentHash` to SHA-256 of the exact `baseBody` against which that operation's UTF-16 offset or range is constructed when body-hash capability is enabled.
- For a multi-operation script, `scriptedChanges` advances `currentBody` after each generated operation and passes that updated body as the next operation's `baseBody`. Each operation therefore carries the hash of its own exact pre-operation positional base, not merely the original edit-session body.

Platform production capture entries into that shared contract are:

- iPhone prepared local body edit:
  - `MyRAM/ViewModels/NotesViewModel.swift`
  - `NotesViewModel.prepareLocalNoteEdit`
  - direct call to `SyncBatchNoteChangeCapture.capturedBodyChanges`
- iPhone wrapper used by other capture/test seams:
  - `MyRAM/iOS/Sync/Batch/IPhoneSyncBatchCaptureHook.swift`
  - `bodyTextChanges` delegates to `SyncBatchNoteChangeCapture.bodyTextChanges`
- Native Mac prepared local body edit:
  - `MyRAM/Mac/MacNotePersistenceAdapter.swift`
  - `MacNotePersistenceAdapter.prepareLocalNoteEdit`
  - direct call to `SyncBatchNoteChangeCapture.capturedBodyChanges`

Consumption remains separate from production:

- `MyRAM/Sync/Batch/SyncBatchAnchoredPayloadPolicy.swift`
- `SyncBatchAnchorlessCompatibilityEvaluator.evaluate(change:authoritativeBody:)`
- Positive proof requires SHA-256 of the authoritative pre-operation body to equal the declared `baseContentHash` exactly.

No non-hash evidence source is accepted in Slice 1.

The following never produce positive eligibility on their own:

- in-range offsets;
- clampable offsets;
- Unicode-boundary adjustment;
- `expectedText`;
- substring equality;
- current-body similarity;
- operation or batch ordering;
- successful trial replay.

Hashless anchorless work therefore classifies as `unavailableEvidence`. A positive declared-hash mismatch classifies separately as `divergentBase`.

## Exact historical-base reconstruction remains separate

The existing convergence route remains unchanged:

- `SyncConvergencePlanner.planBodyChanges` detects a declared base that differs from the current body.
- `SyncConvergencePlanner.planReconstructedBodyChanges` asks `SyncBaseReconstructor` for the exact historical base.
- Exact reconstruction replays against that reconstructed base and combines retained/current operation evidence through the existing convergence mechanism.
- Unavailable reconstruction remains `.deferred(.unreconstructableBase(...))`.
- Failed reconstruction remains a typed convergence failure.

The new direct-replay classifier does not authorize raw replay against a divergent current body and is not consulted by the reconstruction path in Slice 1.

## Recoverability and runtime ownership

Slice 1 does not change queue, acknowledgement, seen/incorporated, persistence, editor publication, rollback, or runtime outcomes.

### iPhone

Transport receipt and acknowledgement ownership remain in:

- `MyRAM/Sync/MyRAMSyncController.swift`
- `onDurablyCaptureIncomingBatch`
- `onBatchReceived`
- batch acknowledgement after durable capture

Incoming durable queue and convergence ownership remain in:

- `MyRAM/ViewModels/NotesViewModel.swift`
- `pendingIncomingBatches`
- `durablyCaptureIncomingBatch(_:)`
- `applyIncomingSyncBatch(_:)`
- `syncConvergenceRuntime.submitRemoteBatch`

Direct mutation ownership remains in `MyRAM/iOS/Sync/Batch/IPhoneSyncBatchApplier.swift` at the raw-offset methods named above.

### Native Mac

Transport/controller receipt and acknowledgement ownership remain in:

- `MyRAM/Mac/Sync/MacSyncBatchController.swift`

Incoming durable queue and convergence ownership remain in:

- `MyRAM/Mac/Sync/MacSyncConvergenceCoordinator.swift`
- `pendingIncomingQueue`
- `durablyCaptureIncomingBatch(_:)`
- `submitRemoteBatch(_:)`
- shared `SyncConvergenceRuntime`

Direct mutation ownership remains in `MyRAM/Mac/Sync/MacSyncBatchApplier.swift` at the raw-offset methods named above.

### Shared runtime and failure ownership

- convergence planning outcomes: `MyRAM/Sync/Convergence/SyncConvergencePlanningTypes.swift`
- convergence runtime/queue handling: `MyRAM/Sync/Convergence/SyncConvergenceRuntime.swift`
- direct-apply preflight errors: `MyRAM/Sync/Batch/SyncBatchPayload.swift`

Slice 2 owns routing new compatibility rejection into these existing recoverable and observable outcomes. Slice 1 intentionally emits no new production failure.

## Shared compatibility decision

Production location:

- `MyRAM/Sync/Batch/SyncBatchAnchoredPayloadPolicy.swift`
- `SyncBatchAnchorlessCompatibilityEvaluator`
- `SyncBatchAnchorlessCompatibilityDecision`
- `SyncBatchAnchorlessReplayEligibility`

The positive eligibility value can only be created by the evaluator. It is bound to the exact `SyncBatchChange` and authoritative body hash so Slice 2 can require validated evidence rather than caller convention.

## Proving tests

### Evidence-production provenance

`MyRAMTests/IPhoneSyncBatchAccumulatorTests.swift` proves the shared construction contract through:

- `testCapturedBodyEvidenceSurvivesPendingBatchEmission`
- `testSharedCapturedBodyChangesReturnEvidenceChain`
- `testIPhoneBodyCaptureMatchesSharedCapturedOperationSequence`
- `testBodyReplacementEmitsContinuousDeleteInsertChain`

Together these prove captured pre/post evidence continuity, shared iPhone operation construction, and that replacement operations use the correct intermediate base hash.

### Slice 1 compatibility classification

`MyRAMTests/SyncBatchAnchoredPayloadTests.swift` proves:

- matching declared hash produces positive eligibility;
- mismatched declared hash produces distinct divergence;
- hashless in-range, clampable, Unicode-split, and `expectedText`/substring-plausible cases remain unavailable;
- current-body similarity alone remains unavailable;
- operation/batch ordering alone remains unavailable;
- repeated classification is deterministic and does not mutate its inputs.

### Platform/runtime preservation coverage

- Native Mac shared-decision parity: `MyRAMMacTests/MacSyncBatchControllerTests.swift`, `testMYR178MacConsumerUsesSharedMatchingBaseDecisionSemantics`.
- iPhone transport and durable-capture behavior: `MyRAMTests/MyRAMSyncControllerTests.swift`.
- iPhone direct application: `MyRAMTests/IPhoneSyncBatchApplierTests.swift`.
- Native Mac convergence and durable incoming ownership: `MyRAMMacTests/MacSyncConvergenceCoordinatorTests.swift`.
- Native Mac direct application and rollback behavior: `MyRAMMacTests/MacSyncBatchApplierTests.swift`.
- Exact-base reconstruction and unreconstructable-base planning: `MyRAMTests/SyncConvergencePlanningTests.swift`.

These existing runtime tests remain preservation evidence; Slice 1 does not change their production paths.

## Deliberate divergence

None in Slice 1.

## Deferred ownership

- MYR-178 Slice 2: integrate positive eligibility at every direct anchorless raw-offset production boundary and preserve recoverable failure semantics.
- MYR-179: production anchored activation.
- MYR-180: live two-device closure and aggregate alignment evidence.


## Slice 2 guarded replay and recovery record

Original Slice 2 execution baseline: `bcba06b1d57a705d437f13e6b318d47909f36070`. Original implementation Blacksmith instruction revision: `5eab9420bf8ef6dd72ae6efc9dae4d7d0182bbea`. PR #129 follow-up remediation starts at `1d09433b813393ce3c60917654638836ac5b5a20` under Blacksmith revision `1ae8822cc848a03c57da4d24cc67a267f7a9af4c`.

Production iPhone and native Mac body-edit capture now opt into the existing body-hash capability seam so each emitted insertion/deletion carries the exact SHA-256 of its sequential pre-operation body. `SyncBatchBodyHashCapability.defaultEnabled` remains false and `SyncBatchAnchoredPayloadCapability.isEnabled` remains false.

`SyncBatchAnchorlessCompatibilityEvaluator` remains the single direct-replay classifier. `SyncBatchPreflight`, the iPhone applier, the native Mac applier, and current-body convergence replay all require its positive eligibility before any UTF-16 offset/range mutation. Clamping, Unicode boundary adjustment, `expectedText`, and successful speculative positioning remain secondary checks and cannot establish eligibility.

Hashless/unproven current-body convergence is typed as `anchorlessMatchingBaseEvidenceUnavailable` and remains durably queued. A declared positive divergence is classified at the shared evaluator boundary and routes only through the existing `SyncBaseReconstructor` exact-historical-base path; reconstruction failure never falls back to current-body raw replay. `SyncOperationReplayEngine.planLegacy` is no longer production reachable.

The shared receive disposition distinguishes three states. Confirmed success or already-completed work maps to `acknowledgementPermitted`. MYR-178 unavailable-evidence deferral and declared-divergent work whose exact historical base is unreconstructable map to `recoverableAnchorlessCompatibilityRejection`. An immediate `.alreadyDraining` outcome maps to `acknowledgementDeferred`: this is an undecided acknowledgement state while the active drain still owns compatibility classification, not itself a compatibility rejection.

iPhone and native Mac both durably capture first, run convergence second, and send `SyncBatchAcknowledgement` only for `acknowledgementPermitted`. Capture is necessary but not sufficient for ACK. Withholding ACK for either undecided or rejected work leaves the sender's exact batch in its durable unsent queue. The existing manual sync paths (`MyRAMSyncController.flushPendingChanges()` and `MacSyncBatchController.flushPendingBatch()`) and the existing connected-peer flush paths retransmit retained work; no retry mechanism was added. Receiver deduplication by batch ID prevents a second incorporation. Once redelivery observes the batch as already completed, ACK is permitted and the sender removes that batch from its unsent queue.

Incoming iPhone `lastSyncAt` advances only in the same `acknowledgementPermitted` branch that sends the ACK. Deferred or recoverably rejected incoming work therefore cannot be represented as successfully synchronized. Native Mac convergence status already advances only for a drained successful source batch. Rejected work remains queued without incorporation, seen/completion recording, cleanup, body mutation, ACK, or successful-sync status; duplicate delivery remains idempotently unacknowledged.

Raw-offset reachability is therefore partitioned into exactly two proof domains: (1) current/sequential matching-base replay authorized by `SyncBatchAnchorlessReplayEligibility`; and (2) replay against an independently proven exact historical base through the existing reconstruction/conflict-union path. No new ordering, deletion, tombstone, dependency, bootstrap, anchor reconstruction, or materialization mechanism is introduced.

MYR-175 through MYR-177 structural semantics remain preserved. Anchored capture/replay remains dark for MYR-179. MYR-180 retains ownership of its later migration/cleanup scope. Deterministic completion verification records focused and full proving tests, changed-file scope, final raw-offset reachability, exact reconstruction preservation, anchored-dark state, `NearbySyncCore` pre/post state, and detached exact-candidate verification.

The follow-up remediation proves compatible deferred redelivery through real production seams rather than invented dispositions or acknowledgements. `MyRAMSyncControllerTests.testManualResendRetainsDeferredBatchUntilRealConvergenceRedeliveryAcknowledgesIt` drives an actual iPhone controller into the real `NotesViewModel` convergence runtime, observes the first `.alreadyDraining` result as `acknowledgementDeferred`, preserves sender retention through the active drain, retransmits the exact retained batch through `flushPendingChanges()`, and routes the receiver-generated ACK back through the sender's production receive path. `MacSyncBatchControllerTests.testManualResendRetainsExactBatchUntilRealReceiverRedeliveryAcknowledgement` proves the equivalent native Mac sender → receiver controller → convergence coordinator → resend → already-completed dedupe → receiver-generated ACK → sender removal path. Both tests assert the target note reflects exactly one incorporation. `MyRAMTests.testReentrantHashlessBatchDefersAcknowledgementWhileActiveDrainClassifiesIt` continues to prove the incompatible reentrant path, and `SyncConvergencePlanningTests.testAlreadyDrainingDefersTransportAcknowledgementWithoutClassifyingCompatibility` pins the shared policy mapping. The existing ordinary/title-only reentrant drain test remains unchanged.
