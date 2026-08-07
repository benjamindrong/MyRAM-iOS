# MYR-177 Completion Verification Evidence

## Status

Implementation is present on the Slice 2 feature branch. Completion remains pending the required local exact-head Xcode verification matrix. This document defines the implementation/evidence mapping before local verification begins; exact local execution output is written outside the repository so recording results does not invalidate the tested head.

## Identity

- Ticket: MYR-177 — Add missing-anchor deferral and bootstrap-conflict handling.
- Slice: 2 — Bootstrap-conflict isolation and dark completion integration.
- Branch: `MYR-177-Slice-2-Bootstrap-conflict-isolation-and-dark-completion-integration`.
- Slice 2 base SHA: `d83973f677c53dcf7f4fdf57657ab2e07761dbd3`.
- Instruction repository revision: `b3333d8ca55b70794e09c3c946c0e1a09d912a1a`.
- Pull request: #127.
- Verification state: `PENDING LOCAL EXACT-HEAD RUN`.

## Approved reference confirmation

The approved MYR-177 private/reference review remains pinned by the merged alignment record to:

- Reference A: `64248a12829d04f62ddf3230c6c592f6226b57ab`
- Reference B: `cdeb8053c3aa2510189429d717ab09e70f134716`
- Reference C: `5fa067b182ddda3ea2477c4d5e4054da7318973f`
- Reference D: `89c162d3c1ae02c426c9002419aef0814e779ed8`
- Reference E: `26f9425ef74d45937e00d6c8ec2e8bb12889013d`

Slice 2 carries these exact approved revisions forward. This record does not claim an independent re-fetch of undisclosed reference repositories; it preserves the revisions approved and recorded by merged Slice 1 evidence.

## Implementation inventory

Production changes are confined to:

- `Packages/AnchoredSequenceCore/Sources/AnchoredSequenceCore/SyncTextLegacyBootstrap.swift`
- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryTypes.swift`
- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryPlanner.swift`

Focused test changes are confined to:

- `Packages/AnchoredSequenceCore/Tests/AnchoredSequenceCoreTests/SyncTextLegacyBootstrapTests.swift`
- `MyRAMTests/SyncBatchAnchoredRecoveryPlannerTests.swift`
- `MyRAMMacTests/SyncBatchAnchoredRecoveryTests.swift`

Documentation changes are confined to:

- `docs/MYR-177-dependency-bootstrap-alignment.md`
- `docs/MYR-177-completion-verification-evidence.md`

No Slice 2 change is intended for SwiftData models, transport envelopes, convergence submission, active application persistence, editors, acknowledgements, anchored queue admission, or capability activation.

## Requirement mapping

| Requirement | Production location | Test or audit evidence |
|---|---|---|
| Deterministic bootstrap identity for empty and nonempty bodies | `SyncTextLegacyBootstrap.makeDescriptor` | V1 empty/nonempty known-vector tests; descriptor compatibility test |
| Accept only known bootstrap versions and verified derived identity | `SyncBatchAnchoredBootstrapChange` custom decoding | Unsupported-version and tampered-operation-ID test |
| Preserve absent versus established-empty foundation | `SyncBatchAnchoredStructuralFoundation`; commit-plan foundations | Empty-bootstrap admission/idempotence tests on iOS and Mac |
| Fail ordinary replay closed when foundation is absent | Foundation overloads in `SyncBatchAnchoredRecoveryPlanner` | Initial insertion/deletion plus dependency/restart retry rejection tests |
| Classify bootstrap by exact structural state, not visible text | Bootstrap branch of planner evaluation | Same-visible-text/different-structure conflict test |
| Prevent late bootstrap resurrection after tombstones | Bootstrap conflict classification | Tombstone-history conflict/non-resurrection tests on iOS and Mac |
| Persist exact recovery-owned structural conflict evidence | `SyncBatchAnchoredStructuralStateEvidence` | Exact round-trip and restart persistence tests |
| Reject malformed structural evidence | Evidence custom decoding through core validation | Malformed evidence decode test |
| Keep conflict reason consistent with evidence | `SyncBatchAnchoredBootstrapConflict` custom decoding | Native Mac reason/evidence mismatch test |
| Keep bootstrap conflict separate from dependency lifecycle | Recovery change/lifecycle record invariants | Bootstrap-cannot-wait and ordinary-cannot-conflict test |
| Progress dependents in one deterministic plan | Shared planner worklist | Nonempty bootstrap dependent-unblocking tests on iOS and Mac |
| Empty bootstrap exposes no nonexistent operation | Bootstrap planner evaluation | Empty-bootstrap operation-list tests |
| Preserve Slice 1 duplicate/applied-equivalence/collision semantics | Shared ordinary replay path | Full retained `SyncBatchAnchoredRecoveryPlannerTests` suite |
| Preserve persistence on conflict write failure | Existing file-backed recovery store + bootstrap conflict transition | Bootstrap conflict write-failure test |
| Preserve shared iPhone/native Mac production seam | Shared `MyRAM/Sync/Batch` source | Mirrored host tests and target-membership audit |
| Keep anchored production behavior dark | No new production callers or activation source | Capability-off and zero-production-reachability audits |

## Foundation admission behavior

Expected immutable planning behavior:

- `.absent` + nonempty bootstrap -> `.established(candidate)`, application state changed, bootstrap operation exposed.
- `.absent` + empty bootstrap -> `.established(.empty)`, application state changed, no structural operation exposed.
- `.established(candidate)` + equivalent bootstrap -> unchanged foundation, no application-state change; nonempty represented operation may be exposed to progress existing dependents.
- `.established(other)` + bootstrap -> durable bootstrap-content conflict, established foundation unchanged, no operation exposed.
- `.absent` + ordinary insertion/deletion/retry/restart -> typed `missingStructuralFoundation`, no synthesized sequence state and no recovery-store transition.

The missing-foundation contract is represented as a typed thrown orchestration error rather than a successful commit plan. Because planning stops before mutation or transition creation, no application-state change or structural-operation availability can be requested by that result.

## Structural evidence representation and validation

Bootstrap conflict evidence records:

- run operation identities;
- left and right insertion-origin element identities;
- exact run text;
- fragment operation identities;
- fragment start offsets and UTF-16 lengths;
- visible/tombstone fragment state.

Reconstruction uses normal `AnchoredSequenceCore` initializers and `SyncTextSequenceState` validation. The recovery representation has no dependency on SwiftData records or persistence-specific revision/payload metadata. Persisted conflict reason must match evidence-derived tombstone presence.

## Verification results

### Remotely observed before local exact-head verification

- Slice 1 start gate: passed; Slice 2 branch was created from merged `main` base `d83973f677c53dcf7f4fdf57657ab2e07761dbd3`.
- Branch/PR naming: matches the Slice 2 ticket title convention.
- PR scope before evidence publication: confined to the three production sources and three focused test files listed above.
- Production caller search for `SyncBatchAnchoredRecoveryPlanner`: no active application caller found; references were test-only.
- GitHub Actions: no workflow run was available for the Slice 2 PR head, so no remote Xcode compile/test result is claimed.

### Pending required local observation

The exact candidate head must pass:

- focused Slice 2 recovery tests;
- retained Slice 1 recovery tests;
- `AnchoredSequenceCore` Debug and Release;
- complete iOS application tests;
- required iOS UI tests;
- complete native Mac tests;
- iOS application build;
- native Mac application build;
- persistence/restart/corruption/unsupported-version/write-failure tests;
- deterministic bounded-work tests;
- interrupted-cleanup recovery;
- bootstrap-conflict restart and persistence-failure tests;
- structural-evidence round-trip and malformed-evidence tests;
- missing-foundation fail-closed tests;
- changed-scope and target-membership audits;
- public API audit;
- capability-off and zero-production-reachability audits;
- no-offset/no-general-hash-validation audits;
- transport/convergence/editor/acknowledgement audits;
- SwiftData schema audit;
- NearbySyncCore preservation;
- `git diff --check`;
- clean tree;
- local/upstream/PR-head parity.

## Persistence and interruption results

Implementation-level tests cover conflict restart persistence, exact evidence reconstruction, interrupted Slice 1 cleanup, and conflict write-failure preservation. Their execution status is `PENDING LOCAL EXACT-HEAD RUN`.

## Activation-boundary results

Source scope shows no intended production activation changes. Exact-head audits for capability state, zero production reachability, queue/capture/emission/convergence/persistence/editor/acknowledgement absence, no raw-offset fallback, no general replay-time `baseContentHash` validation, unchanged transport, and unchanged SwiftData schema are `PENDING LOCAL EXACT-HEAD RUN`.

MYR-179 remains the sole production activation boundary. MYR-180 remains responsible for live two-device closure.

## Final evidence location

The local completion runner creates a unique external evidence directory and prints its absolute path. That directory contains the command log, result summaries, audit output, relevant result-bundle locations, exact tested SHA/tree/parity information, and runner identity.

After execution, the external summary should be attached or pasted to PR #127. The repository evidence document must not be edited merely to copy those results after exact-head verification, because doing so would create a new untested head.

## Completion boundary

MYR-177 Slice 2 is not complete until the local exact-head matrix passes and its external evidence proves the tested local SHA, upstream branch SHA, and PR head are identical. Any production or test change after that matrix begins invalidates the run and requires a fresh exact-head verification.
