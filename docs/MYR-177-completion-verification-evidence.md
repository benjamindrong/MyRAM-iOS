# MYR-177 Completion Verification Evidence

## Status

MYR-177 Slice 2 remediation completed successfully and PR #127 was merged. The historical sections below preserve the pre-closeout evidence boundary; the final exact-head remediation result and merge identity are consolidated in this committed record so downstream Stage 2 closure does not depend on PR prose.

The earlier successful matrix at `bfaab5be12d15ac7dcc5d5c1066a47791e1fb4be` remains valid historical evidence for that exact head. Final closing evidence is the later remediation candidate `de5bb3285578c8b49cb879f58e67f97d2ba7eab3` recorded below.

## Identity

- Ticket: MYR-177 — Add missing-anchor deferral and bootstrap-conflict handling.
- Slice: 2 — Bootstrap-conflict isolation and dark completion integration.
- Pull request: #127.
- Branch: `MYR-177-Slice-2-Bootstrap-conflict-isolation-and-dark-completion-integration`.
- Slice 2 base SHA: `d83973f677c53dcf7f4fdf57657ab2e07761dbd3`.
- Independent-review starting head: `bfaab5be12d15ac7dcc5d5c1066a47791e1fb4be`.
- Final remediation candidate: `de5bb3285578c8b49cb879f58e67f97d2ba7eab3`.
- Merge commit: `535345898ce7f03fbe00db357a04d07fdd8750ba`.
- Instruction repository revision used for remediation: `5eab9420bf8ef6dd72ae6efc9dae4d7d0182bbea`.
- Verification state: `PASSED FINAL EXACT-HEAD REMEDIATION RUN`.

The exact candidate identity is bound by the external completion-runner manifest and PR metadata. This later evidence-only consolidation does not claim that the Xcode matrix ran against the documentation commit containing this update.

## Approved reference confirmation

The approved MYR-177 private/reference review remains pinned to:

- Reference A: `64248a12829d04f62ddf3230c6c592f6226b57ab`
- Reference B: `cdeb8053c3aa2510189429d717ab09e70f134716`
- Reference C: `5fa067b182ddda3ea2477c4d5e4054da7318973f`
- Reference D: `89c162d3c1ae02c426c9002419aef0814e779ed8`
- Reference E: `26f9425ef74d45937e00d6c8ec2e8bb12889013d`

The final completion runner verified those exact revisions before the closing Xcode verification. `docs/MYR-177-dependency-bootstrap-alignment.md` contains the finalized neutral behavior-to-requirement traceability without naming or linking the private repositories.

## Remediation scope

Independent review identified four proposed blockers. Current approved-procedure review resolves them as follows:

1. The proposed extra empty-bootstrap provenance layer is **not adopted**. The approved Slice 2 contract explicitly distinguishes `.absent` from `.established(.empty)` and defines an equivalent empty bootstrap against the established empty foundation as idempotent. Adding a second provenance persistence mechanism would contradict that approved design and unnecessarily broaden persistence scope.
2. Required focused coverage is added for a different bootstrap delivered against an established bootstrap and for a late equivalent bootstrap delivered after an ordinary structural edit. Both cases are mirrored on iOS and native Mac.
3. The external-reference alignment record now maps required behaviors to approved neutral reference revisions, adopted mechanisms or deliberate divergences, impacts, production locations, exact proof, and deferred ownership.
4. This completion-evidence record distinguishes the historical pre-remediation matrix from the final exact-head remediation run instead of using the earlier candidate as closing evidence.

No remediation production source, recovery-store format, transport representation, SwiftData schema, controller, editor, acknowledgement, capability, or `NearbySyncCore` change is introduced.

## Implementation inventory

Slice 2 production changes remain confined to:

- `Packages/AnchoredSequenceCore/Sources/AnchoredSequenceCore/SyncTextLegacyBootstrap.swift`
- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryTypes.swift`
- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryPlanner.swift`
- `MyRAM/Sync/Batch/FileBackedSyncBatchAnchoredRecoveryStore.swift`

The remediation adds the two required bootstrap-conflict scenarios as dedicated `SyncBatchAnchoredBootstrapConflictCoverageTests` classes in these already existing iOS/native Mac test-target files:

- `MyRAMTests/SyncBatchTransportAdmissionPlannerTests.swift`
- `MyRAMMacTests/SyncBatchTransportAdmissionPlannerTests.swift`

The files already belong to their respective host test targets, so no project-membership change is required. The remediation also revises only the two MYR-177 evidence documents. No production source is changed by the remediation itself.

## Requirement mapping

| Requirement | Production location | Test or audit evidence |
|---|---|---|
| Deterministic bootstrap identity for empty and nonempty bodies | `SyncTextLegacyBootstrap.makeDescriptor` | empty/nonempty known-vector and descriptor compatibility tests |
| Preserve absent versus established-empty foundation | `SyncBatchAnchoredStructuralFoundation`; planner commit plans | existing empty-bootstrap admission/idempotence tests on iOS and Mac |
| Reject a different bootstrap against an established bootstrap | bootstrap branch of `SyncBatchAnchoredRecoveryPlanner` | `SyncBatchAnchoredBootstrapConflictCoverageTests.testDifferentBootstrapAgainstEstablishedBootstrapCreatesConflict` on both hosts |
| Reject a late bootstrap after ordinary structural edits | bootstrap branch of `SyncBatchAnchoredRecoveryPlanner` | `SyncBatchAnchoredBootstrapConflictCoverageTests.testLateBootstrapAfterOrdinaryEditCreatesConflict` on both hosts |
| Prevent late bootstrap resurrection after tombstones | bootstrap conflict classification | retained tombstone-history conflict/non-resurrection tests on iOS and Mac |
| Persist bootstrap conflict separately from dependency waiting | recovery change/lifecycle types and file-backed store | retained lifecycle, restart, exact-evidence, and write-failure tests |
| Fail ordinary replay closed when foundation is absent | foundation planner overloads | retained insertion/deletion/retry/restart missing-foundation tests |
| Preserve deterministic dependency retry and Slice 1 collision semantics | shared planner worklist | retained Slice 1 planner/store suites |
| Preserve iPhone/native Mac shared dark behavior | shared `MyRAM/Sync/Batch` production source | mirrored host tests and target-membership audit |
| Keep production anchored behavior dark | no active caller or activation-source remediation | capability-off and zero-production-reachability audits |
| Preserve external-reference traceability | `docs/MYR-177-dependency-bootstrap-alignment.md` | exact-reference and mapping audits |

## Historical exact-head verification

The pre-remediation candidate `bfaab5be12d15ac7dcc5d5c1066a47791e1fb4be` passed the local runner `MYR-177-S2-local-completion-v4-store-fixture-remediation-20260807` with SHA-256 `b612987c8dd2fdcc4bf6a5a7132e40d4c79579f4fac6a3b4a13ffd1be82df448`.

Historical results at that exact head were:

- approved references A–E: exact revisions verified;
- `AnchoredSequenceCore` Debug and Release: passed;
- iOS focused recovery tests: 50/50 passed;
- native Mac focused recovery tests: 10/10 passed;
- complete iOS application tests: 1136/1136 passed;
- complete native Mac tests: 671/671 passed;
- required iOS UI tests: 13/13 passed;
- iOS application build: passed;
- native Mac application build: passed;
- scope, target, store-version, public-API, capability, activation, offset/hash, SwiftData, `NearbySyncCore`, clean-tree, and parity audits: passed.

Those results establish the baseline but did not close the remediation candidate because test and documentation commits were added afterward.

## Final exact-head remediation verification

The final remediation candidate `de5bb3285578c8b49cb879f58e67f97d2ba7eab3` passed the complete local remediation matrix recorded for PR #127.

Closing evidence:

- local runner: `MYR-177-Slice-2-remediation-local-completion-v6-20260808.sh`;
- runner SHA-256: `571888ff9fdb3ae9955576b961c9edd31ca73cec87e8181318fca30a45a097a8`;
- approved reference revisions A–E: exact revisions verified;
- `AnchoredSequenceCore` Debug and Release: passed;
- iOS focused recovery tests: 52/52 passed;
- native Mac focused recovery tests: 12/12 passed;
- complete iOS application tests: 1138/1138 passed;
- complete native Mac tests: 673/673 passed;
- required iOS UI tests: 13/13 passed;
- iOS application build: passed;
- native Mac application build: passed;
- exact PR/remediation scope, capability-off and zero-production-reachability, compatibility/schema, dependency, and `NearbySyncCore` preservation audits: passed;
- detached exact candidate, remote branch, and PR-head parity: passed.

PR #127 subsequently merged that reviewed candidate as `535345898ce7f03fbe00db357a04d07fdd8750ba`.

## Final remediation verification requirement

The exact remediation candidate was required to pass:

- the two new bootstrap-conflict scenarios on iOS and native Mac;
- all retained Slice 1 and Slice 2 focused recovery tests;
- `AnchoredSequenceCore` Debug and Release;
- complete iOS application tests;
- required iOS UI tests;
- complete native Mac tests;
- iOS application build;
- native Mac application build;
- persistence round-trip, restart, corruption, unsupported-version, malformed-record, interruption, and injected-write-failure coverage;
- deterministic bounded-work and reindex coverage;
- changed-scope and target-membership audits;
- recovery-store version and public API audits;
- capability-off and zero-production-reachability audits;
- no-offset and no-general-hash-validation audits;
- transport, convergence, editor, persistence, and acknowledgement boundary audits;
- unchanged SwiftData schema audit;
- `NearbySyncCore` preservation;
- `git diff --check`;
- clean tree;
- detached exact candidate / remote branch / PR-head parity.

The recorded final matrix satisfied this closing gate. A production or test change after that matrix would have invalidated candidate-specific verification and required the matrix to restart; no such change was part of the MYR-177 closing candidate.

## Evidence contract

The local completion runner creates a unique external evidence directory and machine-readable manifest. Candidate-specific phases are bound to the exact candidate SHA. The runner preserves failed attempts, uses unique phase/attempt identities, and may resume only evidence that remains valid for the same candidate and evidence-contract version.

The runner must not commit, push, merge, reset, rebase, force-push, or mutate `main`. It may verify branch parity through standard Git without requiring `gh`.

After a successful run, the external summary is the closing exact-head evidence. A later documentation-only closure change must not be described as though the Xcode matrix executed against that later documentation SHA. This MYR-180 evidence consolidation follows that rule: it records the already-observed MYR-177 closing result without claiming a rerun.

## Completion boundary

MYR-177 Slice 2 passed its final exact-head remediation matrix and PR #127 merged. MYR-179 remained the sole production activation boundary, and MYR-180 remains responsible for final Stage 2 closure.
