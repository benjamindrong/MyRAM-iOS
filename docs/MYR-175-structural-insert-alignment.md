# MYR-175 Structural Insert Alignment

## Baseline

- Ticket: MYR-175, Slice 1 — sibling ordering contract and structural traversal.
- MyRAM baseline: `e51ccca9ff6a77c8648e365b6569313c55c1e9d4`.
- Blacksmith instruction revision: `a6efd7024966027e9caffc9ba9281eb8eede0814`.
- Review date: 2026-08-04.
- Review role: implementing coding agent.
- Approved external reference revisions:
  - Reference A: `64248a12829d04f62ddf3230c6c592f6226b57ab`.
  - Reference B: `cdeb8053c3aa2510189429d717ab09e70f134716`.
  - Reference C: `5fa067b182ddda3ea2477c4d5e4054da7318973f`.
  - Reference D: `89c162d3c1ae02c426c9002419aef0814e779ed8`.
  - Reference E: `26f9425ef74d45937e00d6c8ec2e8bb12889013d`.

### Baseline verification evidence

The accepted complete matrix was run against tested source `ec3a52246253e70be6695e9b35b946788190962d`:

- AnchoredSequenceCore: 71 passed.
- Complete iOS: 1,085 passed.
- Complete native Mac: 649 passed.
- iOS Simulator application build: passed.
- Native Mac application build: passed.

The comparison from that tested source to refreshed `main` contains only `docs/MYR-174-completion-verification-evidence.md`. No package source, application source, test source, project configuration, persistence schema, or build configuration changed.

## Persistence compatibility audit

Accepted conclusion:

> No current active or previously shipped production writer was found that could persist a same-anchor sibling state under the superseded materialization order.

Evidence:

- `SwiftDataNoteSequenceStateStore.compareAndSet` is generically capable of storing any already validated state, but current direct call sites are test-only.
- Current production full-body paths construct deterministic bootstrap state rather than incorporating structural sibling runs.
- A nonempty bootstrap state contains one root run and one visible fragment; it cannot create a same-anchor sibling set.
- Anchored capture, durable admission, convergence incorporation, replay, persistence application, and editor application remain disabled.
- The merged MYR-169 record identifies the store as fully dark with no production store callers at introduction.
- The merged MYR-172 record confirms structural incorporation and replay remained disabled.
- The merged MYR-174 record confirms anchored capture, durability, incorporation, persistence, replay, and apply remain disabled.

The persistence store's generic capability is dormant for this state shape. No migration or compatibility decoder is required for Slice 1.

## Superseded materialization invariant

The MYR-172 statement that sibling placement follows canonical operation ordering is superseded for same-anchor materialization by MYR-175. Canonical operation ordering remains the run-array storage contract.

## Behavior alignment matrix

| Behavior | External behavior reviewed | MyRAM requirement | MyRAM decision | Adopt or diverge | Compatibility/convergence impact | Production location | Proving test | Slice status |
|---|---|---|---|---|---|---|---|---|
| Concurrent inserts sharing one anchor | References preserve operation identity and derive deterministic sequence placement rather than using receipt order. | Same-anchor roots must materialize deterministically. | Group runs by exact structural gap and sort every completed bucket explicitly. | Adopt deterministic structural placement; diverge on the locked comparator. | Future peers with the same state derive the same projection. | `SyncTextSequenceStateValidator.makeGapIndex` | `testSameAnchorSiblingOrderingIsIndependentOfInputPermutation` | Slice 1 |
| Deterministic sibling ordering | References use stable operation identity as the ordering substrate; wrapper and application layers do not own ordering. | Counter descending, then raw RFC 4122 device bytes ascending. | Add one named package-internal comparator and direct ordered-index seam. | Deliberate divergence required by MYR-175. | Canonical run storage remains compatible; future sibling materialization changes deterministically. | `SyncOperationIDSameAnchorSiblingOrder` | `testSameAnchorOrderUsesDescendingCounterThenRawUUIDByteTieBreak` | Slice 1 |
| Descendant subtree ordering and contiguity | References retain insertion ancestry and materialize descendants with their structural parent rather than globally sorting all operations. | Each sibling root's descendants must remain contiguous. | Preserve iterative depth-first expansion and reverse-push sibling roots. | Adopt. | Descendant counters cannot reorder root subtrees. | `SyncTextSequenceStateValidator.deriveStructuralSpans` | `testSameAnchorSiblingSubtreesRemainContiguous` | Slice 1 |
| Supported delivery-order independence | References separate stable operation identity from local receipt order. | Supported permutations must produce the same sibling projection. | Sort each exact-gap bucket through the production comparator. | Adopt. | Same state yields one projection independent of input permutation. | `orderedRunIndices`, `makeGapIndex` | `testSameAnchorOrderedProjectionProducesDeterministicState` | Slice 1 |
| Unavailable dependencies | References preserve causal/structural dependencies rather than guessing an offset fallback. | MYR-177 owns deferral and retry. | Do not add incorporation or dependency errors in Slice 1. | Adopt fail-closed boundary; defer mechanism. | No unsupported convergence claim. | Deferred insertion incorporation seam | Slice 2 dependency tests | Deferred to MYR-177/Slice 2 |
| Malformed and impossible references | References distinguish invalid structure from ordinary delivery order. | Preserve current errors; Slice 2 adds exact incorporation classifications. | Keep existing public error surface unchanged. | Adopt classification principle. | No existing error is renamed or repurposed. | `SyncTextSequenceStateError` | Existing origin and range validation tests | Slice 1 preservation; Slice 2 additions |
| Mid-run anchor resolution | References model positions relative to durable sequence elements rather than current visible offsets. | Support mid-run structural anchors. | Preserve current scalar-boundary gap traversal; no incorporation API yet. | Adopt. | Existing anchor derivation remains stable. | Existing `operationAnchor` and traversal gaps | Existing anchor tests; Slice 2 insertion tests | Deferred implementation to Slice 2 |
| Tombstoned-anchor participation | References retain deleted structural identity while omitting it from visible materialization. | Tombstones participate in placement but remain invisible. | Preserve structural fragments and visibility separation. | Adopt. | Future insertion can resolve around retained identity without visible text dependence. | Existing fragments and materialization | Existing tombstone tests; Slice 2 insertion tests | Preserved in Slice 1 |
| Structural order versus visible materialization | References separate structural sequence identity from rendered text. | Fragment projection must match structural order even for equal visible strings. | Continue validating fragments against structural spans before materialization. | Adopt. | Equal text cannot mask a structural mismatch. | `compareProjection` | `testFragmentProjectionRejectsSiblingOrderMismatchEvenWithEqualVisibleText` | Slice 1 |
| Duplicate operation identity | References require globally stable operation identity. | Duplicate runs remain invalid. | Preserve duplicate rejection before sibling ordering. | Adopt. | Comparator does not require an index tie-breaker. | `validatedRunIndex` | `testNoncanonicalAndDuplicateRunArraysAreRejected` | Slice 1 |
| Compact run and fragment representation | References demonstrate structural identity independent from rendered representation; compact representation is implementation-specific. | Preserve compact runs/fragments. | Retain current state representation and iterative traversal. | Deliberate MyRAM representation choice. | No schema or persistence change. | Existing run, fragment, and span types | Large sibling and deep-chain traversal tests | Slice 1 |
| Persistence compatibility under sibling order change | External ordering mechanisms do not establish a reachable historical MyRAM writer. | Do not reinterpret persisted reachable state silently. | Treat the old projection as unreachable in current and shipped production. | MyRAM-specific audit conclusion. | No migration or decoder required. | Audit only; production persistence unchanged | Static call-site and history audit | Slice 1 |

## Deliberate divergences

### Locked same-anchor comparator

- MyRAM requirement: larger local counter first; equal counters use raw RFC 4122 device bytes ascending.
- Reason: MYR-175 locks an explicit application-independent sibling contract that differs from canonical run storage and from comparator details in the reviewed mechanisms.
- Compatibility and convergence: run serialization and bootstrap ordering do not change; all future peers using the Slice 1 package derive the same sibling projection.
- Production location: `SyncOperationIDSameAnchorSiblingOrder` and `SyncTextSequenceStateValidator.makeGapIndex`.
- Adversarial tests: `testSameAnchorOrderUsesDescendingCounterThenRawUUIDByteTieBreak`, `testSameAnchorSiblingOrderingIsIndependentOfInputPermutation`, and `testSameAnchorOrderDiffersFromCanonicalRunStorageWithoutChangingRunValidation`.

### Compact run and fragment state

- MyRAM requirement: retain operation-owned runs and compact visible/tombstoned fragments.
- Reason: adopting a per-element persisted representation would expand scope, change schemas, and violate Slice 1 compatibility requirements.
- Compatibility and convergence: no persistence or codec change; structural validation remains authoritative.
- Production location: existing sequence-state types and iterative traversal.
- Adversarial tests: `testLargeSameAnchorSiblingSetUsesBoundedIterativeTraversalWork` and `testDeepNestedChainUsesBoundedIterativeTraversalWork`.

### Deferred unavailable-dependency handling

- MyRAM requirement: Slice 1 remains a validation/materialization foundation; MYR-177 owns durable deferral and retry.
- Reason: adding incorporation, retry, or fallback would cross the Slice 1 activation and scope boundaries.
- Compatibility and convergence: no unsupported arrival-order convergence is claimed.
- Production location: no Slice 1 production location; Slice 2 defines incorporation and MYR-177 consumes its missing-dependency classification.
- Adversarial test: deferred child-before-parent classification coverage.

## Slice boundary

Implemented in Slice 1:

- named same-anchor ordering contract;
- separation from canonical run storage;
- deterministic exact-gap bucket ordering;
- subtree-contiguous iterative traversal preservation;
- direct permutation, projection, and complexity coverage;
- persistence compatibility and zero-activation audits.

Deferred:

- insertion incorporation and exact anchor-error taxonomy: Slice 2;
- application-owned dark replay seam and cross-host tests: Slice 3;
- dependency persistence, retry, and eventual convergence: MYR-177;
- production activation: MYR-179.
