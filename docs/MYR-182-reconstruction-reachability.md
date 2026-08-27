# MYR-182 Reconstruction and Deferred-State Reachability

## Execution identity

- Ticket: `MYR-182 — Prove remaining reconstruction and deferred-state reachability`
- Parent: `MYR-181 — Retire obsolete body reconstruction paths`
- Reviewed base / starting head: `90dfc582c9a4673a970a7fd2005e82314d237bf1`
- Blacksmith instructions: `40aab7a57513ca0973ea7d5f6c09cac1a24c6b98`
- Approved handoff revision: `sha256:891ecc19148263379ca3ebb382f0c22a6e39928ffd893068d6eb91216403114b`
- Branch: `MYR-182-Prove-remaining-reconstruction-and-deferred-state-reachability`
- This ticket changes no production behavior. It records reachability and defines the only cleanup family MYR-183 may consume.

## Disposition summary

The reviewed surface contains 21 classified state/outcome entries:

- normal reachable: 8
- anchorless compatibility-only: 7
- dependency-ordering/recoverable: 3
- genuine user-resolvable content conflict: 2
- structurally impossible/obsolete: 1

Disposition: 20 entries are **preserve**. One dead finalized-effect family is **remove** for MYR-183: `SyncConvergenceBodyEffect.legacyPositional` / `LegacyBodyPlan` and only the handling that exists solely for that impossible final-plan representation.

Retained snapshots, `SyncBaseReconstructor`, reconstructed conflict replay, legacy conflict offset transformation after exact historical-base proof, anchored recovery, tombstones, and rewrite-safety validation are explicitly protected.

## Body-effect reachability

### `matchingBaseIncremental` — normal reachable — PRESERVE

Production caller: `SyncConvergencePlanner.planBodyChanges` accepts only a positive `SyncBatchAnchorlessReplayEligibility`, calls `planSequentialBodyChange`, and finalizes `matchingBaseIncremental`. The current body is therefore replayed only after exact declared-base proof.

Protection: `SyncConvergencePlanningTests.testPlanningSuccessReturnsPlannedOutcome` and the MYR-178 anchored-payload compatibility tests pin matching-base eligibility and reject hashless or divergent direct replay.

### `reconstructedConflict` — anchorless compatibility-only — PRESERVE

Production caller: a declared current-base divergence in `planBodyChanges` routes to `planReconstructedBodyChanges`. That function requires `SyncBaseReconstructor` to return an exact historical base before building the retained/current operation union and calling `SyncOperationReplayEngine.planReconstructed`.

The final reconstructed plan adds retained-operation evidence, a new retained snapshot, whole-note presentation routing, and a rewrite-safety receipt. It is the supported MYR-178 exact-historical-base domain and is not made obsolete by anchored structural replay.

Protection includes:

- `testReconstructedConflictUsesDeleteEvidenceForWholeNoteRouting`
- `testReconstructionFromRetainedOperationDoesNotReplayConsumedHistoryTwice`
- `testCorruptRetainedOperationResultFailsBeforeCommit`
- `testConcurrentInsertsRebaseOffsetsInsteadOfCorruptingLaterText`
- `testConcurrentDeleteRebasesLaterInsertOffsetBackward`
- `testConcurrentEditsConvergeToIdenticalBodyRegardlessOfWhichSideIsLocal`

### `legacyPositional` / `LegacyBodyPlan` — structurally impossible/obsolete — REMOVE

`PlannedBodyResult.single` is the only production construction of `.legacyPositional`; `singleNoop` delegates to `single`. This value is only a temporary carrier produced by `SyncOperationReplayEngine.replaySingle`.

Every production route that consumes that carrier prevents it from becoming a final body effect:

1. `planMatchingBase` maps the low-level result and replaces `effect` with `.matchingBaseIncremental`.
2. `planDeclaredChainStep` maps the low-level result and replaces `effect` with `.matchingBaseIncremental`; `SyncBaseReconstructor` consumes the reconstructed body/evidence, not the temporary effect.
3. `planReconstructed` consumes only replay output needed to build its operation union and then finalizes `.reconstructedConflict`.
4. Anchored changes bypass `replaySingle` and route through `SyncConvergenceAnchoredBatchPlanner`; `replaySingle` explicitly rejects anchored variants.

No production caller returns the raw `replaySingle` result as a `SyncConvergenceBatchPlan`. Repository reference inspection shows the remaining `.legacyPositional` references outside the temporary construction are defensive validation/incorporation/helper branches and test helper branches. This is the deterministic production-seam proof: a finalized `.legacyPositional` plan cannot be emitted on current `main`.

MYR-183 may remove only this finalized-effect family and direct dead handling required by that removal. It must preserve the low-level replay behavior used by matching-base, reconstruction-chain, and reconstructed-conflict paths.

### `anchoredStructural` — normal reachable — PRESERVE

Production caller: anchored insert/delete operations in `SyncConvergencePlanner.planCore` require an authoritative sequence snapshot and recovery snapshot, then delegate to `SyncConvergenceAnchoredBatchPlanner`. Success finalizes `.anchoredStructural` and uses structural-refresh presentation when visible text changes.

Protection: `testMYR180AnchoredStructuralPlanningBypassesLegacyConflictRebasePath` proves anchored planning is disjoint from legacy conflict rebase logic.

### `compatibilityNoopMissingNote` — anchorless compatibility-only — PRESERVE

Production caller: `unknownLegacyBodyNoop` handles an anchorless legacy body batch for a note absent locally only when every operation lacks a declared base hash. It consumes the operation identities without inventing note state, retained operations, or snapshots.

A missing note with declared base evidence does not use this no-op; it defers as `unreconstructableBase`.

Protection: the unknown-legacy compatibility planning regression in `SyncConvergencePlanningTests` asserts `.compatibilityNoopMissingNote` and no history additions.

## Deferred planning reasons

### `anchorlessMatchingBaseEvidenceUnavailable` — anchorless compatibility-only — PRESERVE

Current caller: `planBodyChanges` receives `.unavailableEvidence` from `SyncBatchAnchorlessCompatibilityEvaluator` and defers before current-body replay. `SyncConvergenceRemoteBatchDispositionPolicy` maps an incoming instance to `recoverableAnchorlessCompatibilityRejection`, withholding acknowledgement so the durable sender can retry.

Protection: `testHashlessAnchorlessBodyOperationDefersBeforeCurrentBodyReplay` and `testAnchorlessCompatibilityDeferralSuppressesTransportAcknowledgement`.

### `unreconstructableBase` — anchorless compatibility-only — PRESERVE

Current callers: a missing current note with declared base evidence, or `SyncBaseReconstructor.unavailable` after a declared divergence. It is the fail-safe exact-evidence-unavailable result; there is no fallback to raw replay against the current body.

Runtime disposition is recoverable anchorless compatibility rejection with acknowledgement withheld.

Protection: `testMissingHistoricalBaseDefersAsUnreconstructableBase` and `testDivergentUnreconstructableBaseSuppressesTransportAcknowledgement`.

### `unsupportedReconciliation` — dependency-ordering/recoverable — PRESERVE

Current caller: `planCore` detects an incoming legacy `noteBodyReconciled` before normal planning and returns this typed deferral. The state is externally reachable from durable/remote legacy payloads even though current production planning does not apply reconciliation payloads.

Protection: `testUnsupportedReconciliationDefersBatch`. It is deferred queue state, not a user content conflict and not MYR-183 cleanup.

### `historyPressure` — dependency-ordering/recoverable — PRESERVE

Current caller: `SyncConvergenceHistoryPolicy.plan` defers when projected snapshot, retained-operation, provenance, incorporation-evidence, diagnostic, cleanup, or reconciliation history crosses hard limits, or when new bounded evidence would extend a soft-limit state.

This is capacity/recovery pressure, not content conflict. Removing retained snapshot accounting while reconstruction remains reachable would invalidate this guard.

## Exact-base reconstruction states

### `exactSnapshot` — anchorless compatibility-only — PRESERVE

`SyncBaseReconstructor.reconstruct` first accepts a retained snapshot whose content hash exactly equals the required historical base. This is the shortest current production reconstruction path.

### `reconstructed` — anchorless compatibility-only — PRESERVE

If no exact snapshot matches, `SyncBaseReconstructor` deterministically searches forward from retained snapshots through retained operations. It returns only a body whose hash equals the required base, together with consumed operation identities so those operations are not replayed twice.

Protection: `testReconstructionFromRetainedOperationDoesNotReplayConsumedHistoryTwice` and the nil-base retained-operation chain regression.

### `unavailable` — anchorless compatibility-only — PRESERVE

No exact retained evidence chain, or exhaustion of the bounded 4,096-state search, returns `.unavailable`. `planReconstructedBodyChanges` converts it to recoverable `unreconstructableBase`; the search never guesses.

### `failed` — normal reachable — PRESERVE

Contradictory retained evidence or invalid canonical history returns a typed failure such as `corruptHistory` before mutation. This is an integrity boundary, not a conflict-routing opportunity.

Protection: `testCorruptRetainedOperationResultFailsBeforeCommit`.

## Retained snapshot consumption and bookkeeping

Retained snapshots remain production-reachable and protected:

- `SyncConvergenceRuntime.makePlanningInput` loads retained snapshots for affected notes.
- `SyncBaseReconstructor` consumes exact snapshots directly and uses retained snapshots as deterministic chain-search starting points.
- successful reconstructed conflict planning creates `SyncConvergenceSnapshotAddition` at `base.generation + 1`.
- `SyncConvergenceHistoryPolicy` budgets existing and proposed snapshot count/bytes.
- plan validation requires history snapshot additions to equal exactly those owned by body effects before incorporation.

Disposition: **no retained-snapshot storage, loading, reconstruction consumption, snapshot addition, generation, or history-pressure bookkeeping is authorized for MYR-183 removal by this record.**

Anchored `NoteSequenceStateMutationSnapshot` is a separate structural-authority state and is also protected.

## Anchored deferred and quarantined states

### missing structural dependency / `.anchoredDeferred` — dependency-ordering/recoverable — PRESERVE

`SyncBatchAnchoredRecoveryPlanner` classifies missing insertion anchors and deletion targets as `.waiting`. `SyncConvergenceAnchoredBatchPlanner` converts that route to `SyncConvergenceAnchoredDeferredPlan`; runtime persists the recovery transitions, records the missing operation dependency, blocks dependent work, and leaves the batch queued.

This is explicitly recoverable dependency state, never content conflict.

Protection includes:

- `testInitialMissingInsertionCreatesExactWaitingRecord`
- `testInsertionRetriesAfterParentArrivalAndProducesRemovalPlan`
- `testDeletionWaitsForTargetThenTombstonesIt`
- `testRetryReindexesFromOneMissingAnchorToAnother`

### terminal structural failure / anchored quarantine — normal reachable — PRESERVE

Identity collisions and other terminal structural failures are durably represented by the anchored recovery lifecycle and route to `.anchoredQuarantined(.terminal(...))`. Runtime persists the transition and emits `anchoredTerminalStructuralFailure` quarantine evidence.

This is structural integrity evidence, not user-resolvable text conflict.

### bootstrap content conflict / anchored quarantine — genuine user-resolvable content conflict — PRESERVE

A bootstrap presented against a non-equivalent established structural state becomes `bootstrapContentConflict`, including the tombstone-history case. It routes to `.anchoredQuarantined(.bootstrapConflict(...))` and is the anchored-state candidate MYR-184 may evaluate for user conflict routing.

Protection: `testSameVisibleTextWithDifferentStructureCreatesBootstrapConflict` and `testTombstoneHistoryConflictsAndLateBootstrapCannotResurrectContent`.

Tombstone semantics are protected indefinitely; bootstrap conflict handling may not resurrect tombstoned content.

## Rewrite-safety policy and conflict distinction

`SyncConvergenceRewriteSafetyPolicy` is a text-loss proof guard. Current production has two calls, both in `SyncConvergencePlanner.swift`:

1. `SyncOperationReplayEngine.planReconstructed` validates the candidate reconstructed body with context `.plannerMerge` before it can produce `.reconstructedConflict`.
2. incorporation revalidates the stored reconstructed-conflict receipt against the authoritative pre-body with context `.reconciliation`; mismatch or unsafe proof fails as `unprovenTextLoss` before commit.

The result states are classified as follows:

- `.safe(receipt)` — normal reachable — PRESERVE.
- `.unsafe(.duplicateDeleteIdentity)` — normal reachable safety validation — PRESERVE.
- `.unsafe(.malformedDeleteEvidence)` — normal reachable safety validation — PRESERVE.
- `.unsafe(.unprovenTextLoss)` — normal reachable safety validation — PRESERVE.

None of the unsafe rewrite-safety outcomes is a user-resolvable content conflict. They prove that destructive whole-body replacement is not authorized and must continue to fail closed. `SyncConvergenceRewriteSafetyPolicyTests` covers identical bodies, evidence shape, duplicate identities, unproven loss, whitespace, Unicode, reordering, and explicit-delete proof.

The unused `SyncConvergenceRewriteContext` values are not part of the MYR-183 reconstruction/snapshot removal allowlist. Any later simplification of that enum belongs to the routing/safety work that owns it.

## Genuine user-resolvable conflict state

`SyncConvergenceLifecycleEffect.Verdict.preserveLiveNote` is current production conflict-producing state. When lifecycle base hashes do not match the projected live note, the planner preserves the live note rather than applying the remote lifecycle operation. `SyncConvergenceRuntime.preserveLifecycleConflicts` then writes differing title/body versions to the existing `SyncConflictStore`.

Classification: **genuine user-resolvable content conflict — PRESERVE**. This is categorically different from reconstruction safety failures and dependency deferrals.

Protection: `testLifecycleDivergencePreservesLiveNoteWithoutBlockingPlan` plus the divergence incorporation regressions in `SyncConvergenceIncorporationTests`.

## MYR-183 bounded removal allowlist

MYR-183 may remove only the dead finalized `.legacyPositional` representation family below, and only direct code/test handling made unnecessary by that removal:

- `MyRAM/Sync/Convergence/SyncConvergencePlanningTypes.swift`
  - `SyncConvergenceBodyEffect.legacyPositional`
  - `LegacyBodyPlan`
- `MyRAM/Sync/Convergence/SyncConvergencePlanner.swift`
  - the temporary `.legacyPositional(LegacyBodyPlan(...))` construction inside `PlannedBodyResult.single`, replacing it only with the minimum internal replay-result representation needed by the preserved callers
  - every `case .legacyPositional` validation/incorporation/canonical-result/presentation helper branch that exists solely to accept a final effect current production cannot emit
  - comments that describe `.legacyPositional` as a reachable incremental post-commit route
- `MyRAMTests/SyncConvergenceIncorporationTests.swift`
  - test-helper switch arms or synthetic fixtures whose sole purpose is accepting a finalized `.legacyPositional` effect, but only when removal does not reduce coverage of matching-base or reconstructed replay behavior

The repository-wide `legacyPositional` reference set on the reviewed base is limited to those three files. No other file is authorized by this record.

## Explicit protected surface for MYR-183

MYR-183 must not remove or bypass:

- `SyncBatchAnchorlessCompatibilityEvaluator` or `SyncBatchAnchorlessReplayEligibility`
- `SyncConvergenceBodyEffect.matchingBaseIncremental`
- `SyncConvergenceBodyEffect.reconstructedConflict`
- `SyncConvergenceBodyEffect.anchoredStructural`
- `SyncConvergenceBodyEffect.compatibilityNoopMissingNote`
- `SyncBaseReconstructor`, `SyncBaseReconstructionResult`, or `ReconstructedBase`
- retained snapshot loading, storage, generation, chain-search consumption, or history accounting
- retained local/remote operations used by reconstruction and conflict union
- `SyncOperationReplayEngine.planReconstructed` or the legacy conflict offset transformation it still requires after exact historical-base proof
- `SyncConvergenceRewriteSafetyPolicy`, its planned receipt, or incorporation-time revalidation
- `anchorlessMatchingBaseEvidenceUnavailable`, `unreconstructableBase`, `unsupportedReconciliation`, or `historyPressure`
- anchored sequence snapshots, `SyncConvergenceAnchoredBatchPlanner`, `SyncBatchAnchoredRecoveryPlanner`, waiting dependency recovery, structural quarantine, or bootstrap conflicts
- incorporated-batch tombstones or anchored text tombstones
- `SyncConflictStore` / lifecycle `preserveLiveNote` conflict preservation
- Stage 2 deterministic two-replica convergence acceptance and MYR-175–180 structural invariants

## Verification basis

MYR-182 is documentation-only. No shared test or production source is changed, so the existing focused tests above remain the proof surface and no application test target acquires a new compilation requirement from this candidate.

Before MYR-182 closure, exact-candidate evidence must still record the committed document identity, changed-file audit, `git diff --check`, final-head CI required for the docs-only candidate, and an independent review confirming that the allowlist above is bounded and preserves MYR-178 compatibility and anchored dependency recovery.
