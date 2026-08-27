# MYR-182 Reconstruction and Deferred-State Reachability

## Execution identity

- Ticket: `MYR-182 — Prove remaining reconstruction and deferred-state reachability`
- Parent: `MYR-181 — Retire obsolete body reconstruction paths`
- Approved base: `90dfc582c9a4673a970a7fd2005e82314d237bf1`
- Original reviewed starting head: `90dfc582c9a4673a970a7fd2005e82314d237bf1`
- Remediation starting head: `ecaf3622aa142f6cb67777c15b058d1b6579e97f`
- Blacksmith instructions: `40aab7a57513ca0973ea7d5f6c09cac1a24c6b98`
- Approved handoff revision: `sha256:891ecc19148263379ca3ebb382f0c22a6e39928ffd893068d6eb91216403114b`
- Branch: `MYR-182-Prove-remaining-reconstruction-and-deferred-state-reachability`
- Current-main revalidation: `4cb5afd75e4d1b09342dce03efb04926dacce9f6` differs from the approved base only in MYR-217 widget files; no MYR-182 convergence source or focused test seam changed.
- This ticket changes no production behavior. It records reachability and defines the only cleanup family MYR-183 may consume.

## Disposition summary

The reviewed surface contains 21 classified state/outcome entries:

- normal reachable: 11
- anchorless compatibility-only: 7
- dependency-ordering/recoverable: 1
- genuine user-resolvable content conflict: 1
- structurally impossible/obsolete: 1

Disposition: 20 entries are **preserve**. One dead finalized-effect family is **remove** for MYR-183: `SyncConvergenceBodyEffect.legacyPositional` / `LegacyBodyPlan` and only handling that exists solely for that impossible final-plan representation.

Two boundaries are intentionally explicit:

1. Anchored bootstrap conflicts are reachable structural quarantine, not pre-authorized user content conflicts. MYR-184 must keep structural quarantine out of the ordinary content-conflict list unless a later approved requirement changes that contract.
2. `unsupportedReconciliation` is reachable but non-progressing on the current version. Retrying the same payload with unchanged code/evidence cannot make it succeed; it is not dependency recovery.

Retained snapshots, `SyncBaseReconstructor`, reconstructed conflict replay, exact-base legacy conflict offset transformation, anchored dependency recovery, structural quarantine, tombstones, and rewrite-safety validation are protected.

## Body-effect reachability

### `matchingBaseIncremental` — normal reachable — PRESERVE

Production caller: `SyncConvergencePlanner.planBodyChanges` accepts only positive `SyncBatchAnchorlessReplayEligibility`, calls sequential replay, and finalizes `.matchingBaseIncremental`. Current-body positional replay therefore requires exact declared-base proof.

Protection includes `SyncConvergencePlanningTests.testPlanningSuccessReturnsPlannedOutcome` plus the MYR-178 compatibility regressions that reject hashless or divergent direct replay.

### `reconstructedConflict` — anchorless compatibility-only — PRESERVE

Production caller: a declared current-base divergence in `planBodyChanges` routes to `planReconstructedBodyChanges`. That path requires `SyncBaseReconstructor` to prove an exact historical base before building the retained/current operation union and calling `SyncOperationReplayEngine.planReconstructed`.

The final plan retains operation evidence, adds a retained snapshot, uses whole-note presentation routing, and carries rewrite-safety proof. This is the supported MYR-178 exact-historical-base domain.

Protection includes:

- `testReconstructedConflictUsesDeleteEvidenceForWholeNoteRouting`
- `testReconstructionFromRetainedOperationDoesNotReplayConsumedHistoryTwice`
- `testCorruptRetainedOperationResultFailsBeforeCommit`
- `testConcurrentInsertsRebaseOffsetsInsteadOfCorruptingLaterText`
- `testConcurrentDeleteRebasesLaterInsertOffsetBackward`
- `testConcurrentEditsConvergeToIdenticalBodyRegardlessOfWhichSideIsLocal`

### `legacyPositional` / `LegacyBodyPlan` — structurally impossible/obsolete — REMOVE

`PlannedBodyResult.single` is the only production construction of `.legacyPositional`; `singleNoop` delegates to it. The value is only a temporary carrier produced by `SyncOperationReplayEngine.replaySingle`.

Every production consumer prevents that temporary carrier from becoming a final body effect:

1. `planMatchingBase` replaces it with `.matchingBaseIncremental`.
2. `planDeclaredChainStep` replaces it with `.matchingBaseIncremental`; `SyncBaseReconstructor` consumes reconstructed body/evidence, not the temporary effect.
3. `planReconstructed` consumes replay output and finalizes `.reconstructedConflict`.
4. Anchored changes bypass `replaySingle`; that function rejects anchored variants.

No production caller returns the raw `replaySingle` result as a `SyncConvergenceBatchPlan`. The repository-wide `legacyPositional` reference set is limited to `SyncConvergencePlanningTypes.swift`, `SyncConvergencePlanner.swift`, and test-helper handling in `SyncConvergenceIncorporationTests.swift`. The non-construction references are defensive final-effect validation/incorporation/helper branches.

Deterministic invariant: a finalized `.legacyPositional` plan cannot be emitted by current production planning.

MYR-183 may remove only this finalized-effect representation and direct dead handling made unnecessary by that removal. It must preserve low-level replay behavior required by matching-base, reconstruction-chain, and reconstructed-conflict paths.

### `anchoredStructural` — normal reachable — PRESERVE

Production caller: anchored insert/delete operations in `SyncConvergencePlanner.planCore` require authoritative sequence/recovery snapshots and delegate to `SyncConvergenceAnchoredBatchPlanner`. Success finalizes `.anchoredStructural` and uses structural-refresh presentation when visible text changes.

Protection: `testMYR180AnchoredStructuralPlanningBypassesLegacyConflictRebasePath` and the Stage 2 deterministic two-replica acceptance.

### `compatibilityNoopMissingNote` — anchorless compatibility-only — PRESERVE

Production caller: `unknownLegacyBodyNoop` handles anchorless legacy body work for a note absent locally only when every operation lacks declared base evidence. It consumes identities without inventing note state, retained operations, or snapshots.

A missing note with declared base evidence instead defers as `unreconstructableBase`.

Protection: the unknown-legacy missing-note regression in `SyncConvergencePlanningTests` asserts `.compatibilityNoopMissingNote` and no history additions.

## Deferred planning reasons

### `anchorlessMatchingBaseEvidenceUnavailable` — anchorless compatibility-only — PRESERVE

Current caller: `planBodyChanges` receives `.unavailableEvidence` from `SyncBatchAnchorlessCompatibilityEvaluator` and defers before current-body replay. `SyncConvergenceRemoteBatchDispositionPolicy` maps the incoming instance to `recoverableAnchorlessCompatibilityRejection`, withholding acknowledgement so the durable sender can retry.

Protection: `testHashlessAnchorlessBodyOperationDefersBeforeCurrentBodyReplay` and `testAnchorlessCompatibilityDeferralSuppressesTransportAcknowledgement`.

### `unreconstructableBase` — anchorless compatibility-only — PRESERVE

Current callers: a missing current note with declared base evidence, or `SyncBaseReconstructor.unavailable` after declared divergence. It is the fail-safe exact-evidence-unavailable result; there is no current-body raw-replay fallback.

Runtime disposition is recoverable anchorless compatibility rejection with acknowledgement withheld. New exact evidence can change the result on a later delivery/retry.

Protection: `testMissingHistoricalBaseDefersAsUnreconstructableBase` and `testDivergentUnreconstructableBaseSuppressesTransportAcknowledgement`.

### `unsupportedReconciliation` — normal reachable, non-progressing unsupported-version deferral — PRESERVE

Current caller: `planCore` detects an incoming legacy `noteBodyReconciled` before normal planning and deterministically returns `.deferred(.unsupportedReconciliation(...))`. Durable/remote legacy payloads can therefore reach this state.

Current-version progress invariant: no production planner applies `noteBodyReconciled`, and runtime leaves this deferral queued with acknowledgement withheld. Re-running the same batch with unchanged code/evidence produces the same deferral. This is not dependency-ordering/recoverable state and must not be surfaced as a user content conflict.

Protection: `testUnsupportedReconciliationDefersBatch`.

Disposition: preserve the typed unsupported-version evidence in MYR-182/MYR-183. Any migration, rejection, or retirement policy for legacy reconciliation requires separately approved scope; MYR-183 may not silently delete or reinterpret it as positional work.

### `historyPressure` — normal reachable capacity-safety deferral — PRESERVE

Current caller: `SyncConvergenceHistoryPolicy.plan` defers when projected snapshot, retained-operation, provenance, incorporation-evidence, diagnostic, cleanup, or reconciliation history crosses configured limits, or when new bounded evidence would extend a soft-limit state.

This is a capacity/safety guard, not user conflict and not ordinary dependency ordering. Same-state retry is not claimed to recover it; progress requires the relevant history/accounting state or product policy to change. Removing retained-snapshot accounting while reconstruction remains reachable would invalidate this guard.

## Exact-base reconstruction states

### `exactSnapshot` — anchorless compatibility-only — PRESERVE

`SyncBaseReconstructor.reconstruct` accepts a retained snapshot only when its content hash exactly equals the required historical base.

### `reconstructed` — anchorless compatibility-only — PRESERVE

If no exact snapshot matches, `SyncBaseReconstructor` deterministically searches forward from retained snapshots through retained operations. It returns only a body whose hash equals the required base, together with consumed operation identities so those operations are not replayed twice.

Protection: `testReconstructionFromRetainedOperationDoesNotReplayConsumedHistoryTwice` and the nil-base retained-operation chain regression.

### `unavailable` — anchorless compatibility-only — PRESERVE

No exact retained evidence chain, or exhaustion of the bounded search, returns `.unavailable`. `planReconstructedBodyChanges` converts it to recoverable `unreconstructableBase`; reconstruction never guesses.

### `failed` — normal reachable — PRESERVE

Contradictory retained evidence or invalid canonical history returns a typed failure such as `corruptHistory` before mutation. This is an integrity boundary, not conflict routing.

Protection: `testCorruptRetainedOperationResultFailsBeforeCommit`.

## Retained snapshot consumption and bookkeeping

Retained snapshots remain production-reachable and protected:

- `SyncConvergenceRuntime.makePlanningInput` loads retained snapshots for affected notes.
- `SyncBaseReconstructor` consumes exact snapshots directly and uses retained snapshots as deterministic chain-search starting points.
- successful reconstructed conflict planning creates `SyncConvergenceSnapshotAddition` at `base.generation + 1`.
- `SyncConvergenceHistoryPolicy` budgets existing and proposed snapshot count/bytes.
- plan validation requires history snapshot additions to equal exactly those owned by body effects before incorporation.

Disposition: **no retained-snapshot storage, loading, reconstruction consumption, snapshot addition, generation, or history-pressure bookkeeping is authorized for MYR-183 removal.**

Anchored `NoteSequenceStateMutationSnapshot` is separate structural-authority state and is also protected.

## Anchored deferred and quarantined states

### missing structural dependency / `.anchoredDeferred` — dependency-ordering/recoverable — PRESERVE

`SyncBatchAnchoredRecoveryPlanner` classifies missing insertion anchors and deletion targets as `.waiting`. `SyncConvergenceAnchoredBatchPlanner` converts that route to `SyncConvergenceAnchoredDeferredPlan`; runtime persists transitions, records the exact missing dependency, blocks dependent work, and leaves the batch queued.

This is the one audited state classified as dependency-ordering/recoverable. Arrival of the missing operation can make a later retry succeed.

Protection includes:

- `testInitialMissingInsertionCreatesExactWaitingRecord`
- `testInsertionRetriesAfterParentArrivalAndProducesRemovalPlan`
- `testDeletionWaitsForTargetThenTombstonesIt`
- `testRetryReindexesFromOneMissingAnchorToAnother`

### terminal structural failure / anchored quarantine — normal reachable — PRESERVE

Identity collisions and other terminal structural failures are durably represented by anchored recovery and route to `.anchoredQuarantined(.terminal(...))`. Runtime persists the transition and emits `anchoredTerminalStructuralFailure` quarantine evidence.

This is structural integrity evidence. It is not user-resolvable text conflict and must remain outside the content-conflict store/list.

### bootstrap content conflict / anchored quarantine — normal reachable structural quarantine — PRESERVE

A bootstrap presented against a non-equivalent established structural state becomes `bootstrapContentConflict` and routes to `.anchoredQuarantined(.bootstrapConflict(...))`.

The two current conflict reasons remain structural quarantine:

- `nonEquivalentEstablishedState`: visible text may even match while structural authority differs; it is not automatically a choice between two ordinary durable note-body versions.
- `tombstoneHistory`: the established state contains deletion history. Accepting the bootstrap as ordinary incoming content could resurrect deleted content, which Stage 3 explicitly forbids.

Therefore MYR-182 does **not** classify either bootstrap-quarantine reason as a genuine user-resolvable content conflict. MYR-184 must keep structural quarantine out of the existing content-conflict count/list under its current contract. Any future product decision to expose specialized structural-conflict repair requires explicit authority and must preserve tombstones.

Protection: `testSameVisibleTextWithDifferentStructureCreatesBootstrapConflict` and `testTombstoneHistoryConflictsAndLateBootstrapCannotResurrectContent`.

## Rewrite-safety policy and conflict distinction

`SyncConvergenceRewriteSafetyPolicy` is a text-loss proof guard. Current production has two calls in `SyncConvergencePlanner.swift`:

1. `SyncOperationReplayEngine.planReconstructed` validates the candidate reconstructed body with context `.plannerMerge` before `.reconstructedConflict` can be finalized.
2. incorporation revalidates the stored reconstructed-conflict receipt against the authoritative pre-body with context `.reconciliation`; mismatch or unsafe proof fails as `unprovenTextLoss` before commit.

Result classifications:

- `.safe(receipt)` — normal reachable — PRESERVE.
- `.unsafe(.duplicateDeleteIdentity)` — normal reachable safety validation — PRESERVE.
- `.unsafe(.malformedDeleteEvidence)` — normal reachable safety validation — PRESERVE.
- `.unsafe(.unprovenTextLoss)` — normal reachable safety validation — PRESERVE.

None is a user-resolvable content conflict. Unsafe results prove destructive whole-body replacement is not authorized and must continue to fail closed. `SyncConvergenceRewriteSafetyPolicyTests` covers identical bodies, evidence shape, duplicate identities, unproven loss, whitespace, Unicode, reordering, and explicit-delete proof.

Unused `SyncConvergenceRewriteContext` values are outside MYR-183's removal allowlist.

## Genuine user-resolvable conflict state

`SyncConvergenceLifecycleEffect.Verdict.preserveLiveNote` is the one audited state currently classified as genuine user-resolvable content conflict.

When lifecycle base hashes do not match the projected live note, the planner preserves the live note rather than applying the remote lifecycle operation. `SyncConvergenceRuntime.preserveLifecycleConflicts` writes differing title/body versions to the existing `SyncConflictStore`.

Classification: **genuine user-resolvable content conflict — PRESERVE**.

Protection: `testLifecycleDivergencePreservesLiveNoteWithoutBlockingPlan` plus the divergence incorporation regressions in `SyncConvergenceIncorporationTests`.

## MYR-183 bounded removal allowlist

MYR-183 may remove only the dead finalized `.legacyPositional` representation family and direct code/test handling made unnecessary by that removal:

- `MyRAM/Sync/Convergence/SyncConvergencePlanningTypes.swift`
  - `SyncConvergenceBodyEffect.legacyPositional`
  - `LegacyBodyPlan`
- `MyRAM/Sync/Convergence/SyncConvergencePlanner.swift`
  - temporary `.legacyPositional(LegacyBodyPlan(...))` construction inside `PlannedBodyResult.single`, replacing it only with the minimum internal replay-result representation required by preserved callers
  - `case .legacyPositional` validation/incorporation/canonical-result/presentation helper branches that exist solely to accept a finalized effect current production cannot emit
  - comments describing `.legacyPositional` as a reachable incremental post-commit route
- `MyRAMTests/SyncConvergenceIncorporationTests.swift`
  - test-helper switch arms or synthetic fixtures whose sole purpose is accepting a finalized `.legacyPositional` effect, only when removal does not reduce matching-base or reconstructed replay coverage

The reviewed repository-wide `legacyPositional` reference set is limited to those three files. No other file is authorized for removal by this record.

## Explicit protected surface for MYR-183

MYR-183 must not remove or bypass:

- `SyncBatchAnchorlessCompatibilityEvaluator` or `SyncBatchAnchorlessReplayEligibility`
- `.matchingBaseIncremental`, `.reconstructedConflict`, `.anchoredStructural`, or `.compatibilityNoopMissingNote`
- `SyncBaseReconstructor`, `SyncBaseReconstructionResult`, or `ReconstructedBase`
- retained snapshot loading, storage, generation, chain-search consumption, or history accounting
- retained local/remote operations used by reconstruction and conflict union
- `SyncOperationReplayEngine.planReconstructed` or the exact-base legacy conflict offset transformation it still requires
- `SyncConvergenceRewriteSafetyPolicy`, its planned receipt, or incorporation-time revalidation
- `anchorlessMatchingBaseEvidenceUnavailable`, `unreconstructableBase`, `unsupportedReconciliation`, or `historyPressure`
- anchored sequence snapshots, `SyncConvergenceAnchoredBatchPlanner`, `SyncBatchAnchoredRecoveryPlanner`, waiting dependency recovery, structural terminal quarantine, or bootstrap quarantine
- incorporated-batch tombstones or anchored text tombstones
- `SyncConflictStore` / lifecycle `preserveLiveNote` conflict preservation
- Stage 2 deterministic two-replica convergence acceptance and MYR-175–180 structural invariants

## Observed verification and evidence reuse

MYR-182 changes documentation only. No production or test source changed, so repository evidence-reuse rules allow already-observed source-equivalent focused/full test evidence to prove the unchanged seams.

### Source-equivalent iOS/shared test evidence

MYR-180's canonical completion artifact records:

- pre-acceptance source candidate `9842909bf07e1c3bb95b7e6cf339920b6d4ec823`;
- focused iOS regression tests: PASS;
- complete `MyRAMTests`: PASS;
- iOS Simulator Debug build and launch: PASS.

A tree comparison from `9842909bf07e1c3bb95b7e6cf339920b6d4ec823` to the MYR-182 approved base `90dfc582c9a4673a970a7fd2005e82314d237bf1` shows changes only in `MyRAM/Sync/MyRAMDeviceIdentity.swift`, `MyRAMTests/SyncConvergenceIdentityTestSupport.swift`, `MyRAMMacTests/MacSyncDeviceIdentityTests.swift`, and Stage 2 documentation. None of the planning, runtime, anchored-recovery, rewrite-safety, reconstruction, or cited focused test files in this record changed.

Therefore the observed complete `MyRAMTests` PASS is source-equivalent evidence for the cited unchanged planning/runtime/recovery/rewrite-safety tests. No MYR-182 change invalidates it.

### Source-equivalent native Mac / Stage 2 evidence

MYR-180's canonical completion artifact also records aggregate head `ef4cd15de349ff00bb4716501a98da13dbefda22` and GitHub Actions run `32748140684`:

- `Mac application tests`: SUCCESS;
- deterministic Stage 2 two-replica acceptance: passed;
- `Diff audit`: SUCCESS;
- `git diff --check origin/main...HEAD`: SUCCESS.

A tree comparison from `ef4cd15de349ff00bb4716501a98da13dbefda22` to `90dfc582c9a4673a970a7fd2005e82314d237bf1` has the same narrow identity/test-support/documentation-only difference set above; the convergence/recovery source and proving tests are unchanged.

### MYR-182 exact-candidate audit

For original MYR-182 candidate `ecaf3622aa142f6cb67777c15b058d1b6579e97f`, PR verification run `33086557456` completed successfully:

- `Run git diff check`: SUCCESS;
- documentation-only detection: SUCCESS;
- Mac application tests: correctly skipped because no production/test source changed.

The remediation remains a one-file documentation-only change. Final-head PR verification, final changed-file audit, exact committed document identity, and the fresh independent review are closure evidence to record against the remediated candidate.
