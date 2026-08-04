# MYR-174 Completion Verification Evidence

## Scope and classification

MYR-174 adds the inner anchored batch-envelope V2 contract and the mixed-version compatibility gate while leaving anchored production traffic disabled. MYR-179 remains the activation boundary for anchored capture, durability, emission, incorporation, persistence, replay, and apply.

Slice 3 changes only this file:

- `docs/MYR-174-completion-verification-evidence.md`

The user approved the actual merged Slice 1 and Slice 2 work as the Slice 3 baseline on August 3, 2026. This approval accepts the Slice 1 removal of the ignored per-user Xcode scheme-management file and Slice 2's actual branch name plus its post-verification `AGENTS.md` alignment.

This evidence separates current-tree connector inspection from prior exact-head Xcode verification. The Slice 3 environment exposed Jira and GitHub, but not the macOS Xcode checkout, simulator, or sibling working tree. It therefore does not claim new local Xcode results.

## Jira, project, and repository instructions

- Jira: `MYR-174 - Add anchored batch-envelope schema and compatibility gate`
- Status: `In Progress`
- Execution-time Jira `updated`: `2026-08-02T08:47:42.189-0500`
- Parent: `MYR-173`
- Deferred activation: `MYR-179`

Jira retains the four locked resolutions: activation-disabled anchored traffic is rejected before durability; committed evidence excludes its own identities and PR parity; Slice 1 controller changes are codec migration only; and the exact pre-MYR-174 model structurally decodes valid V2, rejects schema `2`, and performs no downstream side effect.

Instruction repository commit used:

- `b8389fcd2ec091d6488c7782d4aa4cf5b3e46e1c`

Instruction blobs:

- overall: `b60a2e9c8e1ae38ac86c10448439c0971f00a2ac`
- coding: `0b4f9f80b7de3b9aa7e89d87e1bc0c089adbd7fd`
- software review: `fa9041826da567f13e68c25b101fe4e038637ba2`
- MyRAM `AGENTS.md`: `71d332053dc806ce151f6671a32857307c91633c`

Slice 3 branch:

- `MYR-174-Slice-3-Compatibility-and-dark-integration-closure`

Required PR title:

- `MYR-174 Slice 3: Compatibility and dark-integration closure`

## Slice identities and file inventories

### Slice 1

- PR `#116`
- Base: `0061a31b81757012278e708cb7f1acf71128449b`
- Verified head: `ba68a8ade2335c3719b40347ecd607d3b6e61694`
- Merge commit: `99464cb02c699507b2326816a5beae2b67cd2eff`
- Branch: `MYR-174-Slice-1-anchored-envelope-v2`

Inventory:

- `MyRAM.xcodeproj/project.pbxproj`
- `MyRAM.xcodeproj/xcuserdata/benjamindrong.xcuserdatad/xcschemes/xcschememanagement.plist` removed
- `MyRAM/Mac/Sync/MacSyncBatchController.swift`
- `MyRAM/Sync/Batch/MultipeerSyncMessageEnvelope.swift`
- `MyRAM/Sync/Batch/SyncBatchEnvelope.swift`
- `MyRAM/Sync/MyRAMSyncController.swift`
- `MyRAMMacTests/MacSyncBatchControllerTests.swift`
- `MyRAMMacTests/SyncBatchEnvelopeV2Tests.swift`
- `MyRAMTests/MyRAMSyncControllerTests.swift`
- `MyRAMTests/SyncBatchAnchoredPayloadTests.swift`
- `MyRAMTests/SyncBatchEnvelopeV2Tests.swift`
- `MyRAMTests/SyncBatchPayloadCompatibilityTests.swift`

### Slice 2

- PR `#117`
- Base: `99464cb02c699507b2326816a5beae2b67cd2eff`
- Verified code head: `9f5efa392c784fd3f683245ff94704959650687c`
- Squashed PR head: `aa1f715064280aff202de81a5d1e9ea655f4b3ae`
- Merge commit: `ec3a52246253e70be6695e9b35b946788190962d`
- Actual branch: `MYR-174-Slice-2-peer-negotiation-and-admitted-transport-routing`

Verified code inventory:

- `MyRAM.xcodeproj/project.pbxproj`
- `MyRAM/Mac/Sync/MacSyncBatchController.swift`
- `MyRAM/Sync/Batch/SyncBatchPeerCapability.swift`
- `MyRAM/Sync/Batch/SyncBatchTransportAdmissionPlanner.swift`
- `MyRAM/Sync/MyRAMSyncController.swift`
- `MyRAMMacTests/MacSyncBatchControllerTests.swift`
- `MyRAMMacTests/SyncBatchPeerCapabilityTests.swift`
- `MyRAMMacTests/SyncBatchTransportAdmissionPlannerTests.swift`
- `MyRAMTests/MyRAMSyncControllerTests.swift`
- `MyRAMTests/SyncBatchPeerCapabilityTests.swift`
- `MyRAMTests/SyncBatchTransportAdmissionPlannerTests.swift`

The only change from the verified code head to the squashed PR head was `AGENTS.md`. No source, test, package, or project file changed after verification.

### Slice 3 baseline

- Base and tested source SHA: `ec3a52246253e70be6695e9b35b946788190962d`
- `main` contained Slice 1 followed by Slice 2 with no later commit at branch creation.
- Slice 3 inventory is this evidence file only.

## Requirement-to-code and requirement-to-test mapping

### Envelope contract

Production:

- `MyRAM/Sync/Batch/SyncBatchEnvelope.swift`
  - derives V1 for `.none` and `.legacy`;
  - derives V2 for `.anchored`;
  - rejects `.mixed` before envelope creation;
  - decodes the integer schema before the nested batch;
  - applies exact schema-to-representation validation;
  - uses sorted keys only for V2.
- Blob: `92006b1d8e4d20b83b2594f9743fdf5822e50958`.

Tests:

- `MyRAMTests/SyncBatchEnvelopeV2Tests.swift`
- `MyRAMMacTests/SyncBatchEnvelopeV2Tests.swift`

The mirrored suites cover schema derivation, mixed rejection, all schema/representation mismatches, zero/negative/future versions before nested decode, malformed versions, V1 structural and bidirectional compatibility, repeated canonical V2 encoding, outer-V1/inner-V2 framing, and the exact pre-MYR-174 rejection sequence.

### Outer message and host integration

- `MyRAM/Sync/Batch/MultipeerSyncMessageEnvelope.swift`
  - batch kind remains `myram.batchSync.v1`;
  - outer schema remains `1`;
  - batch construction and exact decoding are codec-owned.
- Blob: `0f326ad440e980d6ee78e6de1c21f1b6b721c855`.
- `MyRAM/Sync/MyRAMSyncController.swift`
  - blob `e55a384cdef18d905f7664c4728e5201b394b403`.
- `MyRAM/Mac/Sync/MacSyncBatchController.swift`
  - blob `09a4f963a3e2d70871562d8c29283c2fa66b98f4`.

Both hosts require exact outer schema equality before message-kind dispatch. Mirrored controller regressions for outer versions `0` and `-1` prove rejection before capture, callbacks, acknowledgement, queue, timestamp, trust/status, and downstream effects. Positive V1 send and receive controls remain in both controller suites.

### Capability and registry

- `MyRAM/Sync/Batch/SyncBatchPeerCapability.swift`
  - one shared strict codec;
  - canonical `1`, `2`, and `1,2`;
  - rejection of empty tokens, duplicates, unsupported values, signs, whitespace, leading zeros, malformed UTF-8, and descending order;
  - in-memory state keyed by stable peer identity;
  - missing/malformed evidence falls back to V1;
  - discovery and invitation evidence intersects, never unions;
  - evidence clears on disconnect and peer loss;
  - decoded traffic does not upgrade registry state.
- Blob: `9dd23ae21e3885209a9be044d881d8a1580e54df`.

Both hosts advertise `productionDiscoveryInfo`, invite with `productionInvitationContext`, record both evidence paths, clear session evidence, and query the same registry.

Tests:

- `MyRAMTests/SyncBatchPeerCapabilityTests.swift`
- `MyRAMMacTests/SyncBatchPeerCapabilityTests.swift`

These mirrored suites prove the codec matrix, V1-only production evidence, conservative registry behavior, session clearing, no traffic upgrade, both host evidence paths, and V1 broadcast preservation.

### Admission and routing

- `MyRAM/Sync/Batch/SyncBatchTransportAdmissionPlanner.swift`
  - V1 is durably admitted and broadcast;
  - anchored durability rejects while activation is disabled;
  - future V2 routing requires activation, exactly one connected transport entry, and explicit current-session V2 support;
  - zero, multiple, unknown, and V1-only peer states withhold V2;
  - mixed representations reject or withhold;
  - inbound V2 requires negotiated support and enabled activation.
- Blob: `f3bc9e7f10af17735009c547fad3a5bf1fb3a7c6`.

Tests:

- `MyRAMTests/SyncBatchTransportAdmissionPlannerTests.swift`
- `MyRAMMacTests/SyncBatchTransportAdmissionPlannerTests.swift`

The mirrored suites cover the complete durable, outbound, and inbound decision matrices.

### Dark state and side-effect suppression

- `MyRAM/Sync/Batch/SyncBatchAnchoredPayloadPolicy.swift`
  - `SyncBatchAnchoredPayloadCapability.isEnabled` is exactly `false`;
  - fail-closed boundaries remain transport, controllers, durable queue, convergence, recovery, offset replay, and apply.
- Blob: `d9a0f2c95d9fbe5930698bba4b8b1d65f22f6a2a`.

Both hosts perform durable admission before queueing local anchored work. Inbound order is outer decode and exact schema check, inner decode, negotiated-peer and activation admission, then durable capture and downstream work. Disabled V2 returns before those side effects.

Production-seam proof is in:

- `MyRAMSyncControllerTests`
- `MacSyncBatchControllerTests`
- `SyncBatchPeerCapabilityTests`
- `SyncBatchUnsentQueueTests`
- `PendingSyncRecoveryTests`
- `IPhoneSyncBatchApplierTests`
- retained convergence, recovery, replay, apply, and policy tests

The tests assert zero durability, callback, acknowledgement, timestamp, trust/status, queue, model, convergence, recovery, replay, apply, and sequence-state effects.

### Unchanged boundaries

- `SyncBatchAcknowledgement` remains the baseline single-`batchID` declaration.
- `SyncBatchUnsentQueue.swift`
  - baseline and current blob: `51f70bff860b398c6c3d0066588dad702eb9c90a`.
- `FileBackedSyncBatchQueue.swift`
  - baseline and current blob: `ace8bb25f691f11d0c876ae911d958b63df76367`;
  - persisted queue version remains `1`.
- Current project blob: `7b803a228874a42f2e6bebc4da30846d6e163181`.

Neither implementation slice changed `Packages/AnchoredSequenceCore`, convergence, recovery, replay, apply, sequence-state, or SwiftData model files. Repository search for `reserveOperationID(` returns the existing allocator and its tests only; neither slice changed those paths. No production reservation caller, per-peer delivery ledger, or multi-peer V2 fan-out was introduced.

## Envelope and legacy-peer compatibility proof

The exact mapping is:

- `.none` -> V1
- `.legacy` -> V1
- `.anchored` -> V2
- `.mixed` -> rejected

V1 accepts only `.none` and `.legacy`. V2 accepts only `.anchored`, while unrelated non-body changes may coexist. The frozen V2 batch includes an anchored insertion and title change.

The older-peer harness uses the unchanged outer V1 envelope and a pre-MYR-174 inner model containing integer `schemaVersion` and `batch`. It proves outer decode, structural inner V2 decode, rejection of schema `2`, and zero downstream calls. V1 compatibility is proven by recursive structural equality and bidirectional decoding without claiming keyed-object byte order.

## Canonical V2 fixture identity

Independent fixture sources:

- iOS test blob: `78fd3101b5fb964167939b894c9092dc7eb26e98`
- Mac test blob: `b82f15c03cd917d3e21e106a17d2cf73833b05d6`

The literal UTF-8 bytes are identical:

- byte count: `906`
- SHA-256: `093ea19d6e582234f295590eb3aaf8e94ae842b610f7ce43543e6d6fe741c013`
- inner schema: `2`
- anchor: `.between`
- left element: device `17400000-0000-0000-0000-000000000004`, counter `4`, offset `0`
- right element: device `17400000-0000-0000-0000-000000000005`, counter `5`, offset `0`

Both suites require repeated production encoding to equal the frozen bytes.

## Capability, registry, and routing proof

Production discovery is `batch-schemas=1`, and invitation context is UTF-8 `1`, because activation is false. Registry state is session-only and nonpersistent. Unknown, missing, malformed, stale, or contradictory evidence cannot admit V2. Existing V1 batches continue broadcasting to all connected peers.

Future V2 routing is a pure plan requiring exactly one connected peer, explicit current-session V2 support, and enabled activation. Production currently cannot satisfy the activation condition.

## Inbound side-effect-suppression proof

Both hosts execute:

1. outer decode;
2. exact outer schema V1 check;
3. supported kind dispatch;
4. exact inner decode;
5. negotiated-peer and activation admission;
6. return unless admitted;
7. durable capture and downstream processing.

Activation-disabled V2 stops at step 6. Controller recorders prove no callback, acknowledgement, timestamp, trust/status, queue, model, convergence, recovery, replay, apply, or sequence-state effect. Because no mutation precedes rejection, no rollback is required.

## Production dark-state and boundary audits

Current-tree inspection confirms:

- one compile-time `isEnabled = false`;
- no production runtime V2 toggle;
- no production anchored capture caller;
- no new operation-ID reservation caller;
- no per-peer delivery ledger;
- no V2 multi-peer fan-out;
- unchanged batch-level acknowledgement;
- unchanged queue sources and version;
- unchanged outer batch kind and schema;
- no implementation diff in package, model, convergence, recovery, replay, apply, or sequence-state ownership.

## Focused, complete, and build verification

### Slice 1 exact head

At `ba68a8ade2335c3719b40347ecd607d3b6e61694`:

- focused iOS: `79/79`
  - envelope `9`, compatibility `33`, anchored policy `15`, controller `22`
- focused native Mac: `22/22`
  - envelope `9`, controller `13`
- `AnchoredSequenceCore`: `71/71`
- complete native Mac: `629/629`
- complete iOS: `1061/1061` after one transient Markdown Preview UI failure passed in isolation and on a clean full rerun
- iOS and native Mac builds: passed
- scope, API, project, whitespace, dark-capability, local-state, and sibling-state audits: passed
- GitHub CI: not configured

### Slice 2 exact code head

At `9f5efa392c784fd3f683245ff94704959650687c`:

- failure-first regressions at former permissive code: iOS `2/2` and Mac `2/2` executed and failed with expected prohibited effects
- remediation regressions: iOS `2/2`, Mac `2/2`
- focused iOS: `46/46`
  - controller `24`, capability `17`, planner `5`
- focused native Mac: `33/33`
  - controller `15`, capability `13`, planner `5`
- complete iOS: `1085/1085`
- complete native Mac: `649/649`
- iOS and native Mac builds: passed
- project, whitespace, capability-off, outer-V1, membership, package, queue/acknowledgement, and no-activation audits: passed
- GitHub CI: not configured

The only post-verification PR-head change was `AGENTS.md`.

### Slice 3 classification

Directly inspected at `ec3a52246253e70be6695e9b35b946788190962d`:

- Jira and instruction identities;
- ordered merge lineage and exact inventories;
- accepted administrative exceptions;
- current source and test blobs;
- queue blob equality;
- acknowledgement declaration;
- fixture equality, byte count, and SHA-256;
- current `main` and branch baseline;
- evidence-only scope.

Not rerun in the connector environment:

- focused or complete Xcode suites;
- repeated standalone V1 invocation;
- `swift test`;
- application builds;
- `plutil`;
- local `git diff --check`;
- simulator checks;
- sibling checkout porcelain.

No new result is claimed for those commands. Slice 3 modifies documentation only and does not change the verified source or tests.

## Project, membership, whitespace, and sibling audits

Target membership is supported by project membership changes plus nonzero focused suites from both application test targets and successful application builds at the exact verified heads.

Slice 1 recorded project and whitespace audits as passed. Slice 2 recorded `plutil -lint` and full-range `git diff --check` as passed. Slice 3 evidence was checked for unresolved placeholders and trailing whitespace before commit.

Slice 2 recorded `NearbySyncCore` clean at `4ab9eb91e6390947a7a2e9a4c2ec74012b4bc0e2`. Slice 3 did not access or mutate that checkout and does not claim a fresh local porcelain read.

## Automated, manual, and not-run classification

Previously observed automated evidence:

- all Slice 1 and Slice 2 test counts above;
- package and complete application suites;
- both builds;
- project, whitespace, scope, capability, queue, acknowledgement, package, model, membership, and no-activation audits.

Slice 3 direct inspection:

- Jira, instructions, lineage, inventories, source/test mappings, blobs, fixture identity, queue equality, acknowledgement shape, and baseline freshness.

Manual:

- outbound and inbound source-flow inspection;
- independent fixture extraction from both test sources;
- no interactive UI verification because Slice 3 changes no product code.

Intentionally not run:

- live two-device V2 traffic;
- anchored production capture;
- V2 durable admission;
- structural incorporation or replay;
- multi-peer V2 fan-out;
- per-peer acknowledgement behavior.

## Known limitations and deferred activation

MYR-174 does not activate anchored capture, operation-ID reservation, queue admission, emission, incorporation, replay, apply, multi-peer V2 delivery, or a runtime/user setting. It does not change `AnchoredSequenceCore`, `NearbySyncCore`, or SwiftData schemas.

The batch-level acknowledgement still removes a batch globally after one peer acknowledgement, so simultaneous V2 fan-out remains prohibited without a separate per-peer durable-delivery design.

MYR-179 remains the atomic activation boundary. MYR-174 must remain In Progress until Slice 3 receives independent review, merges, refreshed `main` contains this evidence, and the user explicitly approves the Jira transition.
