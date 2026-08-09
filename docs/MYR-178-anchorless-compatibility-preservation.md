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
