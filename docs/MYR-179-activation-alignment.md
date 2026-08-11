# MYR-179 Slice 1 activation alignment

## Execution identity and refreshed-baseline revalidation

- `validated_handoff_revision`: `0581f2a2-55d0-4407-afa8-5761aa1226f6`
- `instruction_repository_sha`: `1ae8822cc848a03c57da4d24cc67a267f7a9af4c`
- `prior_reviewed_main_sha`: `bcba06b1d57a705d437f13e6b318d47909f36070`
- `prior_observed_pr129_head`: `80aa80a87dd94f3df0453ac5334ca86cfd6de365`
- `myr178_status`: Done
- `pr129_state`: merged
- `pr129_merge_commit`: `9ecd3df3f428b3d8fb5afbb00daf8ba49d97114f`
- `base_sha`: `9ecd3df3f428b3d8fb5afbb00daf8ba49d97114f`
- `starting_head_sha`: `9ecd3df3f428b3d8fb5afbb00daf8ba49d97114f`
- `approved_preexisting_changed_files`: `[]`
- `NearbySyncCore` pre-state: clean `main` at `4ab9eb91e6390947a7a2e9a4c2ec74012b4bc0e2`
- working tree before branching: clean; `HEAD == origin/main == base_sha`

Baseline evidence from the exact base:

- `AnchoredSequenceCore` Debug: passed.
- `AnchoredSequenceCore` Release: passed.
- iOS application and UI tests: 1,166 passed, 0 failed, 0 skipped (1,153 application and 13 UI tests).
- native Mac tests: 703 passed, 0 failed, 0 skipped.
- iOS Simulator application build: passed.
- native Mac application build: passed.
- `git diff --check`: clean.

Revalidation verdict: **VALID — implementation authorized.** The named production symbols, host seams, structural replay components, recovery planner/store, convergence transaction and post-commit pipeline, acknowledgement consumers, and MYR-178 anchorless guard remain present at the reviewed paths. Slice 1 retains the execution packet's expected scope and exact base.

## Boundary map

| Activation boundary | Reviewed mechanism and preserved invariant | Production location | Proving test or focused seam | Impact |
| --- | --- | --- | --- | --- |
| V2 production capability advertisement | The single capability selects V1-only or V1+V2 atomically. | `SyncBatchAnchoredPayloadCapability.isEnabled`; `SyncBatchPeerCapabilityCodec.productionCapability` | `SyncBatchPeerCapabilityTests`; future-enabled codec seam | Compatibility |
| Invitation/discovery evidence | Discovery and invitation payloads encode the shared production capability, never a host toggle. | `SyncBatchPeerCapabilityCodec.productionDiscoveryInfo` and invitation context | `SyncBatchPeerCapabilityTests` | Compatibility/transport |
| Outbound V2 routing | The shared planner preserves the exactly-one-compatible-peer acknowledgement restriction. | `SyncBatchTransportAdmissionPlanner.outboundRouting`; iPhone and Mac controller wrappers | `SyncBatchTransportAdmissionPlannerTests`; controller tests | Transport/acknowledgement |
| Inbound V2 admission | V2 requires local activation plus current-session peer compatibility. | `SyncBatchTransportAdmissionPlanner.inboundAdmission`; both host controllers | planner and host controller tests | Compatibility/transport |
| Durable queue admission | Anchored durable admission is denied while activation is off and decided once by shared policy. | `SyncBatchTransportAdmissionPlanner.durableAdmission`; both host controllers | planner and durable queue tests | Persistence/transport |
| Local operation-ID reservation | One durable monotonic allocator supplies every anchored primitive operation ID; consumed IDs are never reused. | `SyncOperationIDReserving`; `MyRAMSyncOperationIDAllocator.shared`; planned `SyncBatchAnchoredLocalCapture` | allocator and anchored local-capture tests | Persistence |
| Local anchored insertion capture | Existing positional edit script identifies the local edit; adapter and structural insertion replay establish anchored authority. | planned `SyncBatchAnchoredLocalCapture`; `SyncBatchAnchoredPayloadAdapter`; `SyncBatchAnchoredInsertReplay` | anchored local-capture tests | Persistence/structural replay |
| Local anchored deletion capture | Adapter captures exact structural identities and existing deletion replay owns tombstones. | planned `SyncBatchAnchoredLocalCapture`; `SyncBatchAnchoredPayloadAdapter`; `SyncBatchAnchoredDeleteReplay` | anchored local-capture deletion tests | Persistence/structural replay |
| Structural load and exact-body validation | Caller-owned snapshot carries authoritative body plus exact sequence revision across async work. | `NoteSequenceStateFullBodyIntegration` planned snapshot seam | supplied-state persistence tests | Persistence/concurrency |
| Atomic local body/sequence mutation | A supplied-state mutation seam is the sole owner of anchored `Note.content` plus sequence payload/revision and saves only through the caller transaction. | `NoteSequenceStateFullBodyIntegration`; `NotesViewModel`; `MacNotePersistenceAdapter` | shared persistence and host integration tests | Persistence |
| Anchored local obligation/history | Anchored body operations use structural pre/post evidence; retained offsets/hashes remain compatibility evidence only. | `SyncConvergenceLocalEvidenceCapture`; `SyncConvergenceRuntime` | local-obligation/history tests on both hosts | Convergence/compatibility |
| Anchored convergence submission | One typed activation planner feeds existing convergence and never performs side effects. | planned `SyncBatchAnchoredActivationPlanner`; `SyncConvergencePlanner`; `SyncConvergenceRuntime` | activation-routing and incorporation tests | Convergence |
| Structural insertion replay | Existing replay owns anchor resolution, same-anchor order, and materialization; raw offsets are never authority. | `SyncBatchAnchoredInsertReplay` through recovery planner | insertion replay and activation planner tests | Structural replay |
| Structural deletion replay | Existing replay owns identity targeting, tombstones, and idempotence; positional retargeting is forbidden. | `SyncBatchAnchoredDeleteReplay` through recovery planner | deletion replay and activation planner tests | Structural replay |
| Missing-dependency persistence | Existing recovery planning owns exact waiting records; runtime returns typed deferred work only after durable transition. | `SyncBatchAnchoredRecoveryPlanner`; `FileBackedSyncBatchAnchoredRecoveryStore`; activation planner/runtime | waiting persistence and fail-closed routing tests | Recovery/convergence |
| Deterministic retry/reindex | Retry is driven by durable dependency availability/restart/source work and uses the existing planner. | recovery planner/store plus convergence drain scheduling | dependency arrival, restart, and reindex tests | Recovery |
| Bootstrap-content conflict | Existing distinct conflict lifecycle cannot become waiting, rewrite, or success. | recovery planner/store; activation route; typed runtime quarantine | bootstrap conflict and redelivery tests | Recovery/convergence |
| Terminal structural failure | Exact typed evidence is durably persisted and mapped to non-acknowledgeable quarantine. | recovery planner/store; activation route; drain scheduler outcome | terminal failure and persistence-failure tests | Recovery/diagnostics |
| Incoming atomic application persistence | Existing convergence transaction uses the supplied-state seam as sole body/sequence mutation owner and rolls back metadata/incorporation together. | `SwiftDataSyncConvergencePersistenceTransaction`; `NoteSequenceStateFullBodyIntegration` | save-failure, stale-revision, mixed-batch tests | Persistence/convergence |
| Reviewed no-application-change completion | Only a positively typed owning result may complete without mutating body, sequence payload, or revision. | activation route; convergence planner/transaction continuation path | idempotent/applied-equivalent and stale-state tests | Recovery/convergence |
| Recovery transition/cleanup after commit | Versioned persisted work records success-dependent recovery before the application commit returns; V1 rows remain decodable. | convergence post-commit types/store/executor | V1 compatibility, recovery failure, restart tests | Recovery/persistence |
| Interrupted-cleanup recovery | Applied-equivalence finishes persisted recovery without a second visible mutation. | recovery planner/store and post-commit executor | crash-window and restart tests | Recovery |
| Editor-visible publication | Presentation is gated after application commit and required recovery durability. | `SyncConvergencePostCommitExecutor` and host presentation adapters | ordering and injected recovery-failure tests | Presentation/recovery |
| Queue/seen completion | Success cleanup executes only after every prior durability gate. | post-commit gating/executor and convergence runtime | gate-order and source-retention tests | Convergence/persistence |
| Acknowledgement | Shared exhaustive policy grants permission only to explicit completed success; hosts cannot reinterpret outcomes. | `SyncConvergenceRemoteBatchDispositionPolicy`; `MyRAMSyncController`; `MacSyncBatchController` | exhaustive policy plus both host controller tests | Acknowledgement |
| MYR-178 anchorless isolation | Exact matching-base evidence remains mandatory before legacy raw-offset replay; anchored activation never reclassifies anchorless work. | `SyncBatchAnchorlessCompatibilityEvaluator`; convergence and direct host guards | MYR-178 compatibility, applier, planner, and controller tests | Compatibility |

## Confirmed Slice 1 constraints

- `SyncBatchAnchoredPayloadCapability.isEnabled` remains the only production activation source and remains `false`.
- Production wrappers derive activation from that source and delegate immediately to shared cores; focused tests may pass `activationEnabled: true` only to those cores.
- Existing insertion, deletion, recovery, anchorless compatibility, convergence, transport, and acknowledgement mechanisms remain authoritative.
- A non-success operation makes its whole source batch non-success; no candidate body, sequence, metadata, incorporation, presentation, cleanup, or acknowledgement effect may commit.
- Recovery transitions that establish waiting/terminal/conflict lifecycle are disjoint from success-dependent post-commit cleanup.
- Persisted V1 post-commit work, SwiftData schema, transport schema, acknowledgement schema, and exactly-one-compatible-peer V2 routing remain compatible.
- No activation-driven structural divergence is currently required. Any evidence to the contrary is a review stop before implementation.

## PR #133 remediation revalidation — 2026-08-11

- `validated_handoff_revision`: `sha256:758493ff1fa9c54f0eda0f64c5b57f98134ca183c44ef335e399e776ca93340b`
- `instruction_repository_sha`: `7c390b32193c4852a3edc5c2192ee6391f4b268b`
- `prior_starting_head_sha`: `c17829434af1ec825809455d3bfa52b608a74a19`
- `merged_origin_main_sha`: `312f443a21416d925db457ef4d5cb33411631105`
- `post_merge_starting_head_sha`: `515d564111da72a54f06e678224fcee04d26b900`
- merge method: normal two-parent merge commit; first parent `c17829434af1ec825809455d3bfa52b608a74a19`, second parent `312f443a21416d925db457ef4d5cb33411631105`; no rebase, amend, force-push, or history rewrite.
- overlap reconciliation: `MyRAM/Views/NotesListView.swift` preserves MYR-179 asynchronous external-open/import draining and MYR-208 pinned-highlight widget republishing; `MyRAMTests/MyRAMWidgetHostTests.swift` preserves MYR-179 async widget routing tests and MYR-208 pinned-highlight snapshot/republication coverage.
- exact `base_sha..post_merge_starting_head_sha` changed-file set (sorted):
  - `MyRAM.xcodeproj/project.pbxproj`
  - `MyRAM/Mac/MacNotePersistenceAdapter.swift`
  - `MyRAM/Mac/MyRAMMacRootView.swift`
  - `MyRAM/Mac/Sync/MacSyncConvergenceCoordinator.swift`
  - `MyRAM/Mac/Sync/MacSyncConvergencePresentationAdapter.swift`
  - `MyRAM/Sync/AnchoredSequence/NoteSequenceStateFullBodyIntegration.swift`
  - `MyRAM/Sync/Batch/FileBackedSyncBatchAnchoredRecoveryStore.swift`
  - `MyRAM/Sync/Batch/FileBackedSyncBatchQueue.swift`
  - `MyRAM/Sync/Batch/SyncBatchAnchoredActivationPlanner.swift`
  - `MyRAM/Sync/Batch/SyncBatchAnchoredLocalCapture.swift`
  - `MyRAM/Sync/Batch/SyncBatchAnchoredPayloadPolicy.swift`
  - `MyRAM/Sync/Convergence/SwiftDataSyncConvergencePersistenceTransaction.swift`
  - `MyRAM/Sync/Convergence/SwiftDataSyncConvergencePostCommitStore.swift`
  - `MyRAM/Sync/Convergence/SyncConvergenceDrainPassScheduler.swift`
  - `MyRAM/Sync/Convergence/SyncConvergenceLocalObligation.swift`
  - `MyRAM/Sync/Convergence/SyncConvergencePlanner.swift`
  - `MyRAM/Sync/Convergence/SyncConvergencePlanningTypes.swift`
  - `MyRAM/Sync/Convergence/SyncConvergencePostCommitExecutor.swift`
  - `MyRAM/Sync/Convergence/SyncConvergencePostCommitTypes.swift`
  - `MyRAM/Sync/Convergence/SyncConvergenceRuntime.swift`
  - `MyRAM/Sync/Convergence/SyncConvergenceTypes.swift`
  - `MyRAM/Sync/Recovery/PendingSyncRecoveryCoordinator.swift`
  - `MyRAM/ViewModels/NotesViewModel.swift`
  - `MyRAM/Views/NearbySyncView.swift`
  - `MyRAM/Views/NoteEditorFileOperationBridge.swift`
  - `MyRAM/Views/NoteEditorView.swift`
  - `MyRAM/Views/NotesListView.swift`
  - `MyRAM/WidgetHost/MyRAMWidgetHostCoordinator.swift`
  - `MyRAM/WidgetHost/MyRAMWidgetNoteRouting.swift`
  - `MyRAM/WidgetShared/MyRAMWidgetSnapshot.swift`
  - `MyRAMTests/MarkdownFileOperationBoundaryTests.swift`
  - `MyRAMTests/MarkdownImportIntegrationTests.swift`
  - `MyRAMTests/MyRAMWidgetCoreTests.swift`
  - `MyRAMTests/MyRAMWidgetHostTests.swift`
  - `MyRAMTests/NoteSequenceStateFullBodyIntegrationTests.swift`
  - `MyRAMTests/SyncBatchAnchoredPayloadTests.swift`
  - `MyRAMTests/SyncBatchAnchoredRecoveryPlannerTests.swift`
  - `MyRAMTests/SyncBatchUnsentQueueTests.swift`
  - `MyRAMTests/SyncConvergenceIncorporationTests.swift`
  - `MyRAMTests/SyncConvergencePlanningTests.swift`
  - `MyRAMWidget/MyRAMWidget.swift`
  - `docs/MYR-179-activation-alignment.md`
- review finding revalidation: all four findings remain applicable at the same named seams. `NoteEditorView` still schedules teardown persistence asynchronously before unregistering; `SyncConvergencePostCommitExecutor` already orders anchored recovery before presentation/cleanup but lacks the required real persisted-store durability/restart proof; malformed V2 transition validation still reads a force-unwrapped key before validating shape; prior `c178294…` exact-head evidence is historical after the merge.
- preservation revalidation: the single disabled capability remains the production activation source; the MYR-175 insertion, MYR-176 identity/tombstone deletion, MYR-177 recovery/retry/bootstrap/applied-equivalence, and MYR-178 anchorless contracts remain intact; no new SwiftData, transport, or acknowledgement schema requirement was introduced by MYR-208.

Remediation revalidation verdict: **VALID — proceed with the named remediation seams only.**
