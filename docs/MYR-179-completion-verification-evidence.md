# MYR-179 Slice 2 Completion Verification Evidence

## Status

MYR-179 Slice 2 is implemented and verified for independent PR review. This record closes the Slice 2 production-activation candidate; it does not mark the Jira ticket Done. Ticket completion remains bounded by merge and consolidation into the canonical MYR-179 Completion Artifact. MYR-180 continues to own obsolete offset-rebasing removal and the final live two-device corruption-reproduction scenario.

## Candidate identity

- Pull request: [#139](https://github.com/benjamindrong/MyRAM-iOS/pull/139)
- Title: `MYR-179 Slice 2: Atomic production activation and completion evidence`
- Base: `main` at `727ffc594b5535b8cf64ca409c6324e16ab07936`
- Branch: `MYR-179-Slice-2-Atomic-production-activation-and-completion-evidence`
- Verified source/test candidate: `01ae0875b36f10842766c246d2a6222febad59b1`
- Initial tree-only delivery commit: `0a8483619c7080a8520614e86b205ed29bbf2cb9`
- Activation-fixture alignment commit: `4fd58e91533e43c1edcceba1ff1ebd77ca8d2cc9`
- Mac structural-save rollback commit: `01ae0875b36f10842766c246d2a6222febad59b1`
- Instruction repository `main` revision used at completion: `03980a563387559e009ce9e30831207f4a36ca09`
- Reviewed continuation handoff SHA-256: `d3feed8c2e016f690683746dec5df28fea97da64fb6470db883191c8e162c15a`
- `NearbySyncCore` revision: `4ab9eb91e6390947a7a2e9a4c2ec74012b4bc0e2` (clean and unchanged)

The staging implementation commit was `3cc3fa5`; its tree was transferred without staging history to the delivery branch. Subsequent commits contain only failures classified from activation-on verification. This document intentionally identifies the exact source/test candidate rather than claiming that the commit containing this document verified itself.

## Implemented activation boundary

- The sole production anchored-batch capability is enabled atomically.
- The generic validation core is removed while the operation-specific validation paths remain.
- Activation-sensitive payload, envelope, replay, recovery, lifecycle, queue, convergence, controller, and Mac persistence fixtures use authoritative sequence state.
- Mac structural persistence now restores the exact staged sequence snapshot after an injected save failure before allowing the same prepared edit to retry. Restoration is conditional on the record still matching the expected failed revision and final state, preventing rollback from overwriting unrelated state.
- The activation-driven scope divergence and its evidence are recorded in `docs/MYR-179-activation-alignment.md`.

## Failure-first and remediation evidence

The first complete activation-on runs exposed stale activation-off host fixtures. Those tests were migrated to the production capability and durable-obligation contracts rather than weakening production admission.

The first ready-for-review Mac CI run, Actions run `31988288799`, then exposed eight failures: six Mac persistence tests reached the production activation precondition, and two controller/coordinator tests retained activation-off expectations. Local reproduction also exposed a production defect: after a structural save failure, note fields were restored but the authoritative sequence record remained at revision + 1, causing a retry to fail as stale. The bounded rollback implementation and focused retry proof were added in `01ae087`.

No failure was treated as permission to restore partial capability, raw-offset replay, or an alternate structural path.

## Verification results

All results below were observed on the source/test candidate `01ae0875b36f10842766c246d2a6222febad59b1` unless explicitly identified as staging evidence.

| Verification | Result | Ownership |
|---|---:|---|
| Focused iOS activation/payload/replay/recovery/lifecycle/controller matrix | 140/140 passed | local staging candidate; source-equivalent production activation tree before classified fixture remediation |
| Focused Mac activation/persistence/controller/coordinator matrix after rollback remediation | 58/58 passed | local |
| `AnchoredSequenceCore` Debug | 114/114 passed | local staging candidate; package unchanged afterward |
| `AnchoredSequenceCore` Release | 114/114 passed | local staging candidate; package unchanged afterward |
| Complete iOS application suite | 1184/1184 passed | local exact source/test candidate |
| Required iOS UI suite | 13/13 passed | local exact source/test candidate |
| Complete native Mac suite | 714/714 passed | local exact source/test candidate |
| Complete native Mac suite | 714/714 passed | GitHub Actions run `31989028408`, job `95269065367` |
| iOS Simulator application build | passed | local exact source/test candidate |
| Native Mac application build | passed | local staging candidate and CI test build; production Mac source changes were then exercised by the exact-candidate Mac suites |
| Automatic diff audit | passed | GitHub Actions run `31989028408`, job `95269036787` |

The iOS preflight encountered a transient simulator `Busy` state after the macOS restart. Re-running against the recovered simulator completed successfully; this was an environment interruption, not a product failure.

## Persistence and lifecycle proof

The passing focused and broad host suites cover:

- structural save success with captured anchored evidence;
- injected save failure with exact note-field and sequence-state rollback;
- successful retry of the same prepared edit after rollback;
- interruption recovery and durable incoming/local obligations;
- restart and applied-state equivalence;
- durable queueing without a compatible peer;
- acknowledgement and success-side-effect ordering;
- sibling identity preservation.

## Static and compatibility audits

The exact source/test candidate passed `git diff --check`, changed-file review, test-target membership review, and the automatic PR diff audit. Manual activation review found one production capability authority and no partial capability combination.

The audited diff preserves these boundaries:

- no anchored raw-offset replay;
- no alternate structural ordering, deletion, tombstone, dependency, bootstrap, or materialization path;
- MYR-178 anchorless behavior remains isolated;
- acknowledgement and success side effects remain post-commit;
- no SwiftData schema change;
- no transport or acknowledgement wire-format change;
- no `NearbySyncCore` change;
- no new generic hash-validation authority.

The final source/test diff from the recorded base contains 23 files. The files beyond the handoff's expected pre-evidence list are activation-driven iOS controller/queue/convergence fixtures plus the Mac production rollback and its Mac fixtures; that divergence is classified in the activation-alignment record. No unrelated file is included.

## CI evidence

- Source-candidate workflow: [Actions run 31989028408](https://github.com/benjamindrong/MyRAM-iOS/actions/runs/31989028408)
- Diff audit: passed in 10 seconds.
- Mac application tests: 714 tests, zero failures; job passed in 2 minutes 21 seconds.
- The branch was ready for review when this workflow ran.

## Completion boundary

The source/test candidate is coherent and ready for independent PR review. The documentation-only commit containing this record does not alter production or test behavior. After that commit, identity, scope, diff cleanliness, clean-tree, upstream parity, and PR-head parity must be rechecked against the new documentation head; the successful Xcode and CI results remain source-equivalent because only this evidence file is added.
