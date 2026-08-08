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
  - `applyBodyTextInserted(_:)`
  - `applyBodyTextDeleted(_:)`
- Native Mac direct application:
  - `MyRAM/Mac/Sync/MacSyncBatchApplier.swift`
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

## Matching-base evidence

Slice 1 accepts exactly one evidence source for positive direct-replay eligibility:

- Declared `baseContentHash` on the anchorless insertion or deletion.
- Provenance: the payload field is the sender-declared hash of the body against which the operation offsets were created.
- Consumption boundary: `SyncBatchAnchorlessCompatibilityEvaluator.evaluate(change:authoritativeBody:)`.
- Proof rule: SHA-256 of the authoritative pre-operation body must exactly equal the declared hash.

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

Existing ownership remains:

- convergence planning outcomes in `SyncConvergencePlanningTypes.swift`;
- convergence runtime/queue handling in `SyncConvergenceRuntime.swift`;
- iPhone incoming queue/application boundaries in the iPhone sync batch path;
- native Mac incoming queue/application boundaries in the Mac sync batch path;
- direct-apply preflight errors in `SyncBatchPayload.swift`.

Slice 2 owns routing new compatibility rejection into those existing recoverable/observable outcomes. Slice 1 intentionally does not emit a new production failure.

## Shared compatibility decision

Production location:

- `MyRAM/Sync/Batch/SyncBatchAnchoredPayloadPolicy.swift`
- `SyncBatchAnchorlessCompatibilityEvaluator`
- `SyncBatchAnchorlessCompatibilityDecision`
- `SyncBatchAnchorlessReplayEligibility`

The positive eligibility value can only be created by the evaluator. It is bound to the exact `SyncBatchChange` and authoritative body hash so Slice 2 can require validated evidence rather than caller convention.

## Proving tests

iOS/shared semantics:

- `MyRAMTests/SyncBatchAnchoredPayloadTests.swift`
- matching declared hash produces positive eligibility;
- mismatched declared hash produces distinct divergence;
- hashless in-range, clampable, Unicode-split, and `expectedText`/substring-plausible cases remain unavailable;
- repeated classification is deterministic and does not mutate its inputs.

Native Mac visibility of the shared semantics:

- `MyRAMMacTests/MacSyncBatchApplierTests.swift`
- matching declared hash is eligible;
- hashless deletion with plausible `expectedText` remains unavailable.

Existing convergence coverage remains authoritative for exact-base reconstruction and unreconstructable-base deferral in `MyRAMTests/SyncConvergencePlanningTests.swift` and related convergence tests.

## Deliberate divergence

None in Slice 1.

## Deferred ownership

- MYR-178 Slice 2: integrate positive eligibility at every direct anchorless raw-offset production boundary and preserve recoverable failure semantics.
- MYR-179: production anchored activation.
- MYR-180: live two-device closure and aggregate alignment evidence.
