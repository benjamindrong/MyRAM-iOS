# MYR-180 Completion Verification Evidence

## Identity

- Ticket: `MYR-180 — Remove offset rebasing and verify live convergence`
- Slice: `Slice 2 — Live convergence and aggregate Stage 2 completion evidence`
- Governing Blacksmith: `40aab7a57513ca0973ea7d5f6c09cac1a24c6b98`
- Approved Slice 2 handoff revision: `sha256:d111048b33cd13f453785d682b9b0ad54c0a9f902aeedb847a05349d0ce5991a`
- Revalidated post-MYR-216 base: `6faa472d684b5c8a5aab42e2fcd4fb23a5c0ab70`
- Base tree: `12d44c6182f17ebeaa444ef00fd461594ec72d85`
- Required `NearbySyncCore`: `4ab9eb91e6390947a7a2e9a4c2ec74012b4bc0e2`
- Slice 2 branch: `MYR-180-Slice-2-Live-convergence-and-aggregate-Stage-2-completion-evidence`
- Pre-acceptance source candidate: `9842909bf07e1c3bb95b7e6cf339920b6d4ec823`
- Pre-acceptance source-candidate tree: `0cd5a552892bca589c6f8839cd211aedeb120daa`
- Deterministic acceptance commit: `bf4c35eb897370d687ab22fda512e8602b5d0be4`
- Aggregate-alignment commit: `ef4cd15de349ff00bb4716501a98da13dbefda22`

This file is the canonical Stage 2 completion artifact. Its own evidence-only commit SHA and the final merge SHA are recorded in PR #143 and Jira after the exact final head is verified and merged; embedding a file's own future commit identity inside itself is intentionally avoided.

## Final Slice 2 scope

Relative to post-MYR-216 base `6faa472d…`, Slice 2 contains:

1. `MyRAM/Sync/MyRAMDeviceIdentity.swift`
   - preserves valid stored iOS sync-device UUID text instead of rewriting its representation;
   - bounds the Multipeer Connectivity peer display name to the MCPeerID UTF-8 limit while retaining the complete stable device identifier.
2. `MyRAMTests/SyncConvergenceIdentityTestSupport.swift`
   - production-seam regression coverage for long ASCII, multibyte, whitespace/fallback, and compound Unicode device names while preserving the complete device identity.
3. `MyRAMMacTests/MacSyncDeviceIdentityTests.swift`
   - deterministic Stage 2 two-replica acceptance using activated structural capture payload creation, production Multipeer envelope coding, opposite-order structural replay, canonical sequence-state persistence, and structural restart validation.
4. `docs/MYR-180-stage-2-aggregate-alignment.md`
   - final aggregate MYR-175 through MYR-179 external-reference alignment and deliberate-divergence record.
5. `docs/MYR-180-completion-verification-evidence.md`
   - this canonical completion artifact.

No SwiftData schema, transport schema, acknowledgement schema, generic transport behavior, `NearbySyncCore`, structural comparator, deletion/tombstone contract, missing-dependency recovery taxonomy, or MYR-178 guarded anchorless compatibility contract is changed by Slice 2.

## Live-discovered startup blocker and correction

The first post-MYR-216 simulator qualification exposed a real startup failure before convergence acceptance: simulator-style device names combined with the stable UUID could exceed `MCPeerID`'s display-name byte limit and terminate the iOS app at startup.

The correction is intentionally narrow:

- the full stable UUID remains present and parseable;
- only the human-readable display-name prefix is UTF-8 bounded;
- truncation occurs on character boundaries;
- a safe fallback is used when the first composed character cannot fit;
- previously stored valid UUID text remains unchanged.

Exact candidate evidence observed for this correction:

- focused iOS peer-display-name regression tests: PASS;
- complete `MyRAMTests`: PASS;
- iOS Simulator Debug build: PASS;
- native Mac Debug build: PASS;
- exact candidate install and launch in the disposable iPhone Simulator: PASS;
- the former `NSInvalidArgumentException: Invalid displayName passed to MCPeerID` startup failure did not recur after the correction.

## Preserved-data baseline classification

The validated one-shot collector `collector-20260824T131527Z.zip` established an integrity-checked continuation checkpoint:

- 64/64 SHA-256 manifest entries verified;
- 0 missing entries;
- 0 hash mismatches;
- Mac unsent queue: 0;
- Mac pending incoming queue: 94 historical identities;
- Mac pending local-convergence queue: 0;
- Mac anchored recovery store: 0;
- Simulator unresolved durable queue/recovery work: 0.

Those 94 Mac pending-incoming identities predate the final acceptance scenario and are historical pre-migration compatibility work. MYR-178 explicitly retains unproven/unreconstructable anchorless work rather than guessing it into place or falsely acknowledging it. Consequently, a global `durable queue == 0` assertion is not a valid preserved-data requirement.

The final invariant is therefore: **the Stage 2 acceptance must introduce no new unresolved durable compatibility work and must not mutate, delete, reset, or reinterpret the preserved historical baseline.** The deterministic acceptance is isolated from that baseline and creates no persistent runtime queue residue.

## Deterministic `GONE` / `HAHA` Stage 2 acceptance

Current user authority replaced the repeatedly defective human-operated terminal/UI choreography with a deterministic two-replica production-seam acceptance. This removes the user from the verification mechanism without weakening the structural convergence question.

Exact proving test:

`MYR180DeterministicTwoReplicaAcceptanceTests.testGONEHAHAOfflineEditsConvergeAcrossTransportArrivalOrderAndPersistenceRestart`

The test reproduces the historical corruption shape as follows:

1. Both replicas start from the same empty structural note state.
2. Mac independently creates anchored root insertion `GONE` with fixed operation identity `(Mac device, localCounter 1)`.
3. Simulator independently creates anchored root insertion `HAHA` with fixed operation identity `(Simulator device, localCounter 2)`.
4. Each batch passes through activated `MultipeerSyncMessageCoding.encodeBatch`, the production outer envelope decoder, and the inner V2 batch decoder unchanged.
5. Each isolated replica first applies only its local operation.
6. Mac then receives `HAHA`; Simulator receives `GONE`, exercising opposite arrival orders.
7. Before convergence assertion, the locked same-anchor comparator freezes the expected result as `HAHAGONE`: local counter 2 precedes local counter 1 for siblings at the same structural gap.
8. Both replicas must produce exactly equal `SyncTextSequenceState` values, not merely matching visible text.
9. The converged state must contain both operation identities exactly once, two visible fragments, zero tombstones, and exactly the expected UTF-16 length.
10. Both converged states pass through `NoteSequenceStatePersistenceCodec.encode`; canonical payload bytes must be equal.
11. Each persisted payload is decoded and structurally validated through `NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState`, representing restart persistence.
12. Both restarted states must remain structurally equal and materialize exactly `HAHAGONE`.

Observed exact-head CI evidence at aggregate head `ef4cd15de349ff00bb4716501a98da13dbefda22`:

- GitHub Actions run `32748140684`: SUCCESS;
- `Mac application tests`: SUCCESS;
- command: `xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO -only-testing:MyRAMMacTests test`;
- the exact Stage 2 deterministic acceptance test is recorded in the job log as **passed**;
- `Diff audit`: SUCCESS;
- `git diff --check origin/main...HEAD`: SUCCESS.

The test proves the historical `GONEHAHA` / `HAHAGONE` corruption shape cannot vary with receipt order under the activated structural authority and survives production transport encoding plus persisted structural restart.

## Aggregate MYR-175 through MYR-179 closure

Canonical aggregate record:

`docs/MYR-180-stage-2-aggregate-alignment.md`

It consumes the committed final artifacts from MYR-175, MYR-176, MYR-177, MYR-178, and MYR-179 and covers every ticket-required Stage 2 mechanism:

- same-anchor and concurrent insertion ordering;
- sibling and subtree placement;
- identity-targeted deletion and tombstone retention;
- insert-versus-delete behavior;
- missing-anchor deferral and deterministic retry;
- impossible-reference and bootstrap-content conflict classification;
- legacy anchorless replay isolation;
- visible materialization and rich-text positioning boundaries;
- activation consistency through capture, transport, persistence, replay, iPhone, native Mac, queue cleanup, and acknowledgement;
- final offset-rebase retirement/narrowing boundary.

For each adopted mechanism it records the neutral established behavior, MyRAM production location, exact proving test, and compatibility/migration impact. For each deliberate divergence it records the concrete MyRAM requirement, rationale, compatibility/storage/recovery/convergence impact, production location, targeted verification, and final Stage 2 acceptance evidence. It intentionally does not name or link external repositories.

## Offset-rebase final boundary

Slice 1's committed audit remains authoritative:

`docs/MYR-180-slice-1-offset-rebase-retirement-audit.md`

Its current-main reachability result is preserved:

- anchored V2 work is structurally planned and cannot reach raw-offset replay or UTF-16 rebasing;
- the remaining positional rebase algorithm belongs only to the exact-historical-base reconstructed MYR-178 anchorless compatibility domain;
- generic rebase naming was retired/narrowed rather than deleting compatibility behavior still required by MYR-178;
- current-base eligible anchorless replay does not use the rebase path;
- no alternative anchored ordering/replay mechanism was introduced.

## Reused verification and invalidation analysis

Blacksmith/AGENTS require rerunning only evidence invalidated by a later candidate.

The post-MYR-216 tree already had successful package, application, UI, Mac, build, scheme, diff, scope, target-membership, and dependency-topology evidence. Slice 2 invalidation is narrow:

- `MyRAMDeviceIdentity.swift` can affect iOS sync startup identity, so the affected seam was reverified by focused exact-candidate tests, exact iOS Simulator build, and exact successful simulator launch.
- `SyncConvergenceIdentityTestSupport.swift` is test support for that same boundary and was exercised by the focused/complete iOS unit evidence.
- the deterministic Stage 2 acceptance is Mac-test-only and was executed in the complete exact-PR-head `MyRAMMacTests` suite.
- `docs/MYR-180-stage-2-aggregate-alignment.md` and this completion artifact cannot affect application/test behavior.
- no Slice 2 change touches UI behavior, `AnchoredSequenceCore`, `NearbySyncCore`, Xcode scheme definitions, SwiftData schema, transport/acknowledgement schema, or target membership.

Therefore unaffected previously successful evidence remains source-equivalent and reusable, while every changed production/test seam received candidate-specific verification.

## Acceptance-criteria disposition

- MYR-174 through MYR-179 complete/merged prerequisite: PASS before Slice 2; refreshed again after MYR-216.
- Approved implementation procedure/execution identity: PASS; handoff revision retained and post-MYR-216 base revalidated.
- Current-main offset/rebase reachability audit: PASS in committed Slice 1 artifact.
- Obsolete generic rebase boundary removed/narrowed without deleting required MYR-178 compatibility: PASS.
- No anchored raw-offset replay or offset rebasing: PASS through Slice 1 reachability/focused regressions and final aggregate audit.
- No undocumented alternative ordering/deletion/dependency/bootstrap/recovery/materialization/anchored replay path: PASS through MYR-175–179 completion artifacts and aggregate audit.
- Structural replay focused coverage: PASS.
- Existing concurrent-edit convergence behavior: PASS.
- Same-anchor, missing-anchor, legacy-isolation, schema-version, and no-offset-fallback behavior: PASS through consumed final artifacts and existing exact tests.
- Required broad native Mac verification at deterministic acceptance head: PASS.
- Affected iOS production seam verification: PASS through focused complete unit, build, and exact simulator launch evidence.
- Deterministic `GONE` / `HAHA` two-replica scenario: PASS; frozen final body `HAHAGONE`.
- Identical visible and durable structural convergence without corruption, duplicate content, loss, positional fallback, or hidden divergence: PASS.
- Restart persistence: PASS through canonical sequence-state encode/decode structural validation.
- Historical unresolved compatibility work is not misclassified as acceptance failure and no new unresolved work is introduced: PASS by preserved-baseline classification plus isolated deterministic acceptance.
- Aggregate MYR-175–179 alignment/divergence record: PASS at `docs/MYR-180-stage-2-aggregate-alignment.md`.
- Canonical Stage 2 completion artifact: PASS with this file, subject only to final evidence-only-head CI, independent PR review, merge identity recording, and Jira transition.

## Remaining merge gate

Before MYR-180 is moved to Done:

1. GitHub PR #143 must be green at the final evidence-only head containing this artifact.
2. A fresh independent PR review must find no required P0/P1/P2 correction and rate the exact final candidate 10/10.
3. PR #143 must merge without rewriting shared history.
4. Jira must record the final PR-head and merge identities, then transition MYR-180 from In Progress to Done.

No additional product source change is indicated by the completed Stage 2 evidence.