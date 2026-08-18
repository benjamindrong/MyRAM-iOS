# MYR-180 Slice 1 Offset-Rebase Retirement Audit

## Execution identity

- Ticket: `MYR-180 — Remove offset rebasing and verify live convergence`
- Slice: `Slice 1 — Offset-rebase retirement and automated structural closure`
- `base_sha`: `37920c23a9deb25c973617f952f6b5efd86bc666`
- `starting_head_sha`: `37920c23a9deb25c973617f952f6b5efd86bc666`
- Blacksmith instruction revision: `367a6044b700bd9f00decb041051c271be0cbbab`
- Implementation handoff revision: `sha256:d80dbd107d5ab0654a6b3e29fa943b8d67e295723a795d6ddcb5f39e1d6226cc`
- Required `NearbySyncCore`: `4ab9eb91e6390947a7a2e9a4c2ec74012b4bc0e2`
- Local pre-edit gate evidence: `/Users/Shared/Dev/MYR-180-verification/MYR-180-Slice-1-local-preflight-20260817T171731Z`

The local pre-edit gate passed at the exact base and required sibling identity before this branch was created. No source file was modified before this audit.

## Current offset/rebase surface

The current production offset-rebase implementation is private to `MyRAM/Sync/Convergence/SyncConvergencePlanner.swift`, inside `SyncOperationReplayEngine.planReconstructed` and its private helpers.

Definitions:

- `SyncConvergenceAppliedRebaseEvent`
- `SyncOperationReplayEngine.rebasedChange(_:for:against:)`
- `SyncOperationReplayEngine.rebasedOffset(_:excludingOriginDeviceIDLowercase:against:)`
- `SyncOperationReplayEngine.utf16Offset(of:)`
- the local `appliedForeignEvents` collection in `planReconstructed`

Direct caller chain:

1. `SyncOperationReplayEngine.planReconstructed`
2. `rebasedChange`
3. `rebasedOffset`
4. `utf16Offset(of:)` when a replayed operation changes UTF-16 length and a transform event is recorded

No second production caller of these helpers exists on the reviewed base.

## Indirect production reachability

### Guarded pre-migration anchorless compatibility

Legacy body operations enter `SyncConvergencePlanner.planBodyChanges` through `.noteBodyTextInserted` or `.noteBodyTextDeleted`.

The current-body path first calls `SyncBatchAnchorlessCompatibilityEvaluator.evaluate`:

- exact current-base proof -> `planSequentialBodyChange` -> `SyncOperationReplayEngine.planMatchingBase`;
- unavailable exact-base evidence -> typed `anchorlessMatchingBaseEvidenceUnavailable` deferral;
- positively divergent current base -> `planReconstructedBodyChanges`.

`planReconstructedBodyChanges` does not authorize replay against the divergent current body. It first requires `SyncBaseReconstructor` to produce an exact historical base from retained snapshots/operations. Only an exact reconstructed base proceeds to the operation union and `SyncOperationReplayEngine.planReconstructed`. Unavailable reconstruction remains typed `unreconstructableBase` deferral; corrupt reconstruction fails before mutation.

Therefore the rebase transform remains production-reachable only inside the MYR-178 historical-base compatibility proof domain. It is not safe to delete merely because anchored structural replay is active.

### Anchored structural work

Anchored `.noteBodyTextInsertedAnchored` and `.noteBodyTextDeletedAnchored` cases are handled separately in `SyncConvergencePlanner.planCore`.

That branch obtains an authoritative `NoteSequenceStateMutationSnapshot`, requires the anchored recovery snapshot, and delegates to `SyncConvergenceAnchoredBatchPlanner`. Successful work is recorded as `.anchoredStructural`.

Anchored operations do not call `planBodyChanges`, `planReconstructedBodyChanges`, `SyncOperationReplayEngine.planReconstructed`, or any offset-rebase helper. `SyncOperationReplayEngine.replaySingle` also rejects anchored change variants as an invalid merge plan rather than applying them positionally.

Classification: anchored structural path is disjoint from the offset-rebase implementation.

## Raw-offset mutation boundaries relevant to this audit

The remaining positional convergence replay in this file has two reviewed compatibility roles:

1. exact current/sequential base replay, authorized by `SyncBatchAnchorlessReplayEligibility`;
2. replay against an independently reconstructed exact historical base, including the reconstructed conflict union.

Neither role is an anchored placement/deletion mechanism. Neither may be entered as fallback for an anchored operation.

The MYR-178 preservation record explicitly defines these as the two positional proof domains and forbids direct replay against an unproven or divergent current body.

## Proving tests

The existing MYR-165 regressions in `MyRAMTests/SyncConvergencePlanningTests.swift` remain required and must remain behaviorally unchanged:

- `testConcurrentInsertsRebaseOffsetsInsteadOfCorruptingLaterText`
- `testConcurrentDeleteRebasesLaterInsertOffsetBackward`
- `testConcurrentEditsConvergeToIdenticalBodyRegardlessOfWhichSideIsLocal`

These prove that legacy reconstructed concurrent operations still require cross-origin UTF-16 transform behavior to avoid corruption and asymmetric convergence.

Existing anchored structural coverage includes the anchored-planning and anchored replay/recovery suites. Slice 1 adds a focused planner regression named `testMYR180AnchoredStructuralPlanningBypassesLegacyConflictRebasePath` to pin the production-seam distinction directly.

## Removal, retention, and narrowing decision

### Retain behavior

Retain the cross-origin UTF-16 transform algorithm used by reconstructed legacy conflict replay. Current-main reachability and the unchanged MYR-165 regression tests prove this behavior is still required for safe pre-migration compatibility.

### Remove generic naming

The generic names imply a system-wide convergence rule even though MYR-179 activation made structural identity the sole authority for anchored operations. That naming is obsolete.

Narrow the private surface without changing its algorithm:

- `SyncConvergenceAppliedRebaseEvent` -> `SyncConvergenceLegacyOffsetRebaseEvent`
- `rebasedChange` -> `legacyConflictRebasedChange`
- `rebasedOffset` -> `legacyConflictRebasedOffset`
- `utf16Offset(of:)` -> `legacyBodyUTF16Offset(of:)`
- `appliedForeignEvents` -> `appliedLegacyForeignEvents`

Update the adjacent comments to state that this is pre-migration anchorless reconstructed-conflict compatibility only, after exact historical-base proof, and is never anchored V2 placement authority.

### Do not alter the algorithm

No offset math, event filtering, operation ordering, clamping behavior, reconstruction policy, rewrite-safety policy, or error classification is changed in Slice 1. A discovered need to alter that algorithm is a stop condition requiring procedure re-review.

## Structural-authority conclusion

At the reviewed base:

- anchored work uses structural identity through `SyncConvergenceAnchoredBatchPlanner` and cannot reach the legacy rebase helpers;
- matching-base anchorless work remains guarded by `SyncBatchAnchorlessCompatibilityEvaluator`;
- divergent anchorless work cannot replay against the current body and reaches reconstructed conflict replay only after exact historical-base reconstruction;
- the remaining rebase behavior is therefore required legacy compatibility, not an alternative anchored structural mechanism;
- the correct Slice 1 implementation is to narrow and label the private compatibility surface, preserve its algorithm, and add direct anchored-route regression coverage.

## Stop-condition review

No current-main evidence requires an algorithmic change, schema change, transport change, acknowledgement change, `NearbySyncCore` change, new structural mechanism, or expansion outside the approved Slice 1 changed-file budget.

Audit verdict: **proceed with the approved narrow rename/comment change and focused planner regression.**
