# MYR-133 PR 2d Completion Verification Evidence

## Scope

MYR-133 is the completion checkpoint for the settled MYR-132 PR 2d post-commit cleanup and presentation contract. This pass preserves the production architecture and adds focused verification for executor state coverage, final-CAS retry behavior, retained immutable work payloads, payload validation, and stable work-payload encoding.

The corrective slice after commit `6b1017e` fixes two defects found in that verification evidence:

- The representative golden encoded invalid incremental offsets. The golden now replays insert `"B"` at UTF-16 offset `1` and insert `"C"` at UTF-16 offset `2`, proving the decoded operations produce `"ABC"` and match the committed post-body hash.
- The payload validator previously skipped hash-chain comparisons when an incremental operation omitted a base hash. Incremental entries now fail closed when the first base hash is missing while an expected pre-hash exists, or when any later operation omits the previous-result base hash.

The production fix is validation-only. It does not change the persistence format or executor behavior. Malformed payloads that previously skipped chain validation are now rejected.

MYR-134 completed the planner and routed-note construction verification slice. It added real planner-to-incorporation coverage for every supported finalized planner shape, exact persisted routed-note work construction, `.none` route filtering, malformed route/effect rejection, and deterministic note-entry and operation ordering.

MYR-134 also found one settled-contract defect in legacy positional post-commit work construction: legacy body operations can predate per-operation base hashes, but persisted incremental presentation work requires a replayable base/result hash chain. The fix is limited to private post-commit payload construction, where missing operation base hashes are derived only for legacy positional post-commit operations from the entry pre-body hash and preceding operation result hash. Matching-base incremental operations do not receive synthesized base hashes and remain fail-closed when malformed.

No live drain/controller integration was added. No per-domain CAS boundary was introduced. No production visibility was broadened for tests.

## Phase 1 Inventory

Production post-commit surface:

- `MyRAM/Sync/Convergence/SyncConvergencePostCommitTypes.swift`
- `MyRAM/Sync/Convergence/SyncConvergencePostCommitExecutor.swift`
- `MyRAM/Sync/Convergence/SwiftDataSyncConvergencePostCommitStore.swift`
- `MyRAM/Sync/Convergence/SyncConvergencePostCommitGating.swift`
- `MyRAM/Sync/Convergence/SyncConvergencePersistenceTransaction.swift`

CAS immutable root projection:

- `batchID`
- `originDeviceID`
- `createdAt`
- `batchSequence`
- `schemaVersion`
- `committedAt`
- `canonicalPayloadDigest`
- `canonicalPayloadDigestFormatVersion`
- `committedResultDigest`
- `committedResultDigestFormatVersion`
- `committedAtOrderingPayloadData`
- `affectedNotesPayloadData`
- `authoritativeChildCount`
- `authoritativeChildBytes`
- `authoritativeChildrenDigest`
- `postCommitWorkPayloadData`

Mutable CAS payload:

- `postCommitStatePayloadData`

Load-time identity validation fields:

- root `batchID`
- root and persisted identity canonical payload digest/version
- root and persisted identity committed-result digest/version
- operation identity row `identityKey`
- operation identity row `batchID`
- operation identity row `noteID`
- operation identity row `operationIndex`
- operation identity row byte count
- decoded canonical replay key
- decoded operation identity payload

Executor persistence model:

- Queue cleanup, legacy cleanup, and presentation refresh run in deterministic queue, legacy, presentation order.
- The executor accumulates completed domains in memory.
- One final compare-and-set persists the accumulated mutable-state result.
- If the final CAS fails, all originally pending domains remain retryable and `.postCommitStatePersistence` is reported.

Target membership decision:

- `SyncConvergencePostCommitTests` is compiled into both `MyRAMTests` and `MyRAMMacTests`.
- `SyncConvergenceFoundationTests` and `SyncBatchPayloadCompatibilityTests` are currently iOS-test-target members only.
- This PR keeps those foundation/compatibility suites iOS-only and verifies native macOS shared post-commit behavior through `MyRAMMacTests/SyncConvergencePostCommitTests`.
- Adding broad foundation/compatibility target membership to native macOS is intentionally not mixed into this verification pass because it changes project membership and may require portability work outside the PR 2d post-commit contract.

## Requirement Matrix

| Requirement | Code/Test Location | Verification |
|---|---|---|
| Preserve settled PR 2d production architecture | Narrow validation-only production change in `MyRAM/Sync/Convergence/SyncConvergencePostCommitTypes.swift` | Focused post-commit suites passed |
| Fake CAS preserves immutable work bytes | `MyRAMTests/SyncConvergencePostCommitTests.swift` `testFakeStoreCASPreservesImmutableWorkPayloadAfterPartialClear`, `FakePostCommitStore.currentWorkPayloadData` | iOS/macOS post-commit suites |
| Eight pending-state executor matrix with legacy adapter | `testEightPendingStateMatrixWithLegacyAdapterPinsSingleCASEffects` | Pins queue -> legacy -> presentation order, exact queue and legacy work, full presentation request equality, one CAS for changed states, and no CAS for complete roots |
| Legacy pending with nil adapter remains pending | `testEightPendingStateMatrixWithoutLegacyAdapterLeavesLegacyPending`, `testLegacyTrueWithoutAdapterRemainsPending` | iOS/macOS post-commit suites |
| Final CAS failure leaves original domains retryable, then fresh-store retry converges | `testFinalCASFailureThenFreshStoreRetryRerunsIdempotentWorkAndCompletes` | Reconstructs retry state and work by decoding persisted root payload bytes, then re-runs queue, legacy, and presentation work from persisted all-pending state |
| Completed roots remain no-op | `testCompletedPostCommitStateDoesNotCallAdaptersOrWrite` | iOS/macOS post-commit suites |
| Caller-regenerated plans do not suppress persisted work | `testCallerPlansCannotSuppressPersistedQueueOrPresentationWork` | iOS/macOS post-commit suites |
| Presentation requests use authoritative committed state and deterministic order | `testPresentationRequestsUseAuthoritativeCommittedStateInDeterministicOrder` | Pins complete incremental and whole-note-fallback requests in deterministic note order |
| Missing work payload fails before adapters | `testPrePayloadPendingRootFailsClosedBeforeAdapters` | iOS/macOS post-commit suites |
| Payload rejects malformed nested operation identity | `testPostCommitPayloadRejectsMalformedOperationIdentity` | iOS/macOS post-commit suites |
| Payload rejects hash-chain discontinuity | `testPostCommitPayloadRejectsOperationHashChainMismatch` | iOS/macOS post-commit suites |
| Payload rejects missing first base hash when expected pre-hash exists | `testPostCommitPayloadRejectsMissingFirstBaseHashWhenExpectedPreHashExists` | iOS/macOS post-commit suites |
| Payload rejects missing intermediate base hash | `testPostCommitPayloadRejectsMissingIntermediateBaseHash` | iOS/macOS post-commit suites |
| Payload allows absent expected pre-state with absent first base hash | `testPostCommitPayloadAllowsMissingExpectedPreHashAndMissingFirstBaseHash` | iOS/macOS post-commit suites |
| Payload rejects contradictory presentation entries | `testPostCommitPayloadValidationMatrixRejectsContradictoryPresentationEntries` | iOS/macOS post-commit suites |
| Executable replay-verified representative work-payload golden | `testRepresentativeWorkPayloadGoldenDigestPinsStableEncoding` | Golden SHA-256 `9cd2489d7c1338e54c0db95eabf20e5a98c8fefc872e4b02665ce3a678e1e3e5` |
| Deterministic all-idempotent payload digest | `testAllIdempotentRetainedBodyDeliveryPersistsWithoutPresentationWork` | Golden SHA-256 `7441711fd109820ef330485c1e431b8f75b2c1d99037855189ed213b16d7e50b` |
| Partial and full clear reload from fresh SwiftData contexts | `testSwiftDataStoreReloadsAfterPartialAndFullClearWithRetainedWorkPayload` | iOS/macOS post-commit suites |
| Tombstone cleanup ignores regenerated caller-plan content | `testTombstoneCleanupRemovesOnlyVerifiedSourceBatchID` | iOS/macOS post-commit suites |
| Real planner Path B disabled across supported finalized shapes | `MyRAMTests/SyncConvergenceIncorporationTests.swift` `testMYR134RealPlannerShapeMatrixPersistsExpectedRoutedWork`, `planIncorporateAndDecode` | Asserts `.planned`, `cleanupPlan.retryLegacyCleanup == false`, persisted `legacyCleanupPending == false`, work `legacyCleanupRequired == false`, and `work.derivedInitialState() == state` for matching-base incremental, all-idempotent, mixed idempotent/executable, legacy positional, creation-only create/idempotent, creation-plus-body create/idempotent, title-only, reconstructed conflict, compatibility body no-op, and compatibility title no-op |
| Zero/one/multiple routed-note cardinality | `testMYR134RealPlannerShapeMatrixPersistsExpectedRoutedWork`, `testMYR134MixedRoutingsPersistOnlyNonNoneEntriesInDeterministicOrder` | Zero-entry title/creation/no-op cases, one-entry matching-base incremental case, and mixed multi-note fixture |
| Mixed `.none`/incremental/fallback exact persisted set | `testMYR134MixedRoutingsPersistOnlyNonNoneEntriesInDeterministicOrder` | Work contains only incremental and fallback notes, excludes `.none`, and stores entries in UUID order |
| Missing and duplicate note-plan rejection | `testMYR134MalformedRoutedNoteConstructionFailsBeforeCommitWithoutMutation` | Mutates valid real planner output, uses DEBUG test token only, asserts `.failedBeforeCommit(.invalidMergePlan(noteID: ...))`, and proves no preflight mutation |
| Matching-base operation missing source base hash remains fail-closed | `testMYR134MalformedRoutedNoteConstructionFailsBeforeCommitWithoutMutation` | Mutates real planner matching-base output to remove one operation base hash, removes retained operation additions so payload encoding is reached, asserts `.failedBeforeCommit(.unexpected)`, and proves no preflight mutation |
| Route/effect contradiction rejection | `testMYR134MalformedRoutedNoteConstructionFailsBeforeCommitWithoutMutation` | Covers incremental route with no executable operations, fallback route with incremental effect, incremental route for reconstructed conflict, and extraneous routing for title-only note |
| Incremental-without-executable-work normalization/rejection proof | `testMYR134RealPlannerShapeMatrixPersistsExpectedRoutedWork`, `testMYR134MalformedRoutedNoteConstructionFailsBeforeCommitWithoutMutation` | Real all-idempotent planner output normalizes to `.none`; malformed incremental route with empty operations is rejected before commit |
| Deterministic note-entry and operation order | `testMYR134MixedRoutingsPersistOnlyNonNoneEntriesInDeterministicOrder`, `testMYR134RepeatedPlanningAndIncorporationProducesIdenticalWorkPayload` | Affected note plans and presentation entries are UUID ordered; mixed-route source first-occurrence order differs from persisted UUID order; incremental operations preserve ascending source indexes; repeated construction produces identical work bytes |
| Legacy positional derived hash chain | `testMYR134RealPlannerShapeMatrixPersistsExpectedRoutedWork` | Two-operation legacy positional fixture asserts indexes `[0, 1]`, expected pre-body hash, committed post-body hash, every base/result chain link, and `assertHashChain(legacyEntry)` |

## Commands Run

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testRepresentativeWorkPayloadGoldenDigestPinsStableEncoding
```

Exit code: 65. Purpose: captured the new golden digest before replacing the placeholder. Executed 1 test, 1 failure, 0 skips.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Exit code: 65. Purpose: caught incorrect matrix expectations. Executed 22 tests, 8 failures, 0 skips.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Exit code: 0. Executed 22 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Exit code: 0. Executed 22 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS Simulator' build
```

Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' build
```

Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePlanningTests -only-testing:MyRAMTests/SyncConvergenceIncorporationTests -only-testing:MyRAMTests/SyncConvergencePostCommitTests -only-testing:MyRAMTests/SyncConvergenceFoundationTests -only-testing:MyRAMTests/SyncBatchPayloadCompatibilityTests -only-testing:MyRAMTests/SyncBatchUnsentQueueTests
```

Exit code: 0. Executed 180 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePlanningTests -only-testing:MyRAMMacTests/SyncConvergenceIncorporationTests -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests -only-testing:MyRAMMacTests/SyncBatchUnsentQueueTests
```

Exit code: 0. Executed 139 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests -only-testing:MyRAMTests/SyncConvergenceIncorporationTests/testAllIdempotentRetainedBodyDeliveryPersistsWithoutPresentationWork
```

Exit code: 0. Executed 26 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

## Final Remediation Verification

Verified implementation SHA: `036f38e8d4ef57777076698907c229bcbda81280`

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testEightPendingStateMatrixWithLegacyAdapterPinsSingleCASEffects -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testPresentationRequestsUseAuthoritativeCommittedStateInDeterministicOrder -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testFinalCASFailureThenFreshStoreRetryRerunsIdempotentWorkAndCompletes
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Executed 3 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests/testEightPendingStateMatrixWithLegacyAdapterPinsSingleCASEffects -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests/testPresentationRequestsUseAuthoritativeCommittedStateInDeterministicOrder -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests/testFinalCASFailureThenFreshStoreRetryRerunsIdempotentWorkAndCompletes
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Executed 3 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePlanningTests -only-testing:MyRAMTests/SyncConvergenceIncorporationTests -only-testing:MyRAMTests/SyncConvergencePostCommitTests -only-testing:MyRAMTests/SyncConvergenceFoundationTests -only-testing:MyRAMTests/SyncBatchPayloadCompatibilityTests -only-testing:MyRAMTests/SyncBatchUnsentQueueTests
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Executed 180 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePlanningTests -only-testing:MyRAMMacTests/SyncConvergenceIncorporationTests -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests -only-testing:MyRAMMacTests/SyncBatchUnsentQueueTests
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Executed 139 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS Simulator' build
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' build
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
git diff --check
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0.

## MYR-134 Verification

Verified implementation SHA: `6ff9bc0f55257a3a4cbf2b70cd4f79e52aa72e25`

Chosen iOS simulator: `iPhone 16 Pro`

```bash
xcrun simctl list devices available
```

Exit code: 0. Selected `iPhone 16 Pro` from available iOS 26.5 simulators.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePlanningTests -only-testing:MyRAMTests/SyncConvergenceIncorporationTests
```

Commit SHA: `6ff9bc0f55257a3a4cbf2b70cd4f79e52aa72e25`. Exit code: 0. Executed 95 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePlanningTests -only-testing:MyRAMMacTests/SyncConvergenceIncorporationTests
```

Commit SHA: `6ff9bc0f55257a3a4cbf2b70cd4f79e52aa72e25`. Exit code: 0. Executed 95 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Commit SHA: `6ff9bc0f55257a3a4cbf2b70cd4f79e52aa72e25`. Exit code: 0. Executed 25 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Commit SHA: `6ff9bc0f55257a3a4cbf2b70cd4f79e52aa72e25`. Exit code: 0. Executed 25 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS Simulator' build
```

Commit SHA: `6ff9bc0f55257a3a4cbf2b70cd4f79e52aa72e25`. Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' build
```

Commit SHA: `6ff9bc0f55257a3a4cbf2b70cd4f79e52aa72e25`. Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
git diff --check
```

Commit SHA: `6ff9bc0f55257a3a4cbf2b70cd4f79e52aa72e25`. Exit code: 0.

MYR-134 is complete.
MYR-133 remains incomplete.

## MYR-135 Verification

Verified implementation SHA: `7f1ca4b`

MYR-135 completes the operation-identity validation matrix for construction-time authority, post-commit payload validation, persisted SwiftData identity-row validation, and operation hash-chain validation.

The MYR-135 implementation preserves the existing construction authority and payload contract while adding source-batch exactness checks, nested replay-key linkage, multiplicity-aware persisted identity-row lookup, and exact persisted-row payload comparison before any post-commit external work runs.

MYR-135 focused requirement coverage:

- Valid source-batch identity persists and builds exact work identity: `MyRAMTests/SyncConvergenceIncorporationTests.swift` `testMYR135ValidSourceIdentityPersistsAndBuildsExactWorkIdentity`
- Legitimate non-source reconstructed-conflict identity remains accepted: `testMYR135ReconstructedConflictAcceptsLegitimateNonSourceIdentities`
- Construction malformed identity matrix fails before commit without mutation: `testMYR135ConstructionIdentityMatrixFailsBeforeCommitWithoutMutation`
- Payload identity matrix rejects malformed operation, replay-key, note, and kind shapes: `MyRAMTests/SyncConvergencePostCommitTests.swift` `testMYR135PostCommitPayloadIdentityValidationMatrix`
- Operation hash-chain matrix rejects pre-hash, intermediate, and final-result discontinuities: `testMYR135OperationHashChainValidationMatrix`
- Valid persisted authoritative identity row loads and reaches presentation: `testMYR135ValidPersistedIdentityRowLoadsAndReachesPresentation`
- Persisted row corruption fails before queue, legacy, presentation, or CAS work: `testMYR135PersistedIdentityRowCorruptionFailsBeforeAdapters`

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergenceIncorporationTests/testMYR135ValidSourceIdentityPersistsAndBuildsExactWorkIdentity -only-testing:MyRAMTests/SyncConvergenceIncorporationTests/testMYR135ReconstructedConflictAcceptsLegitimateNonSourceIdentities -only-testing:MyRAMTests/SyncConvergenceIncorporationTests/testMYR135ConstructionIdentityMatrixFailsBeforeCommitWithoutMutation -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testMYR135PostCommitPayloadIdentityValidationMatrix -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testMYR135OperationHashChainValidationMatrix -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testMYR135ValidPersistedIdentityRowLoadsAndReachesPresentation -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testMYR135PersistedIdentityRowCorruptionFailsBeforeAdapters
```

Exit code: 0. Executed 7 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergenceIncorporationTests -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Exit code: 0. Executed 74 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergenceIncorporationTests -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Exit code: 0. Executed 74 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS Simulator' build
```

Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' build
```

Exit code: 65. First attempt failed because it ran concurrently with the iOS build and Xcode reported `build.db` was locked.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' build
```

Exit code: 0. Sequential rerun final result: `** BUILD SUCCEEDED **`.

```bash
git diff --check
```

Exit code: 0.

MYR-135 implementation is complete.

## Remaining MYR-133 Coverage Not Completed In This Pass

The attached MYR-133 proposal is broader than this initial implementation pass. These items still need additional work before claiming full ticket completion:

- Per-field stale-CAS matrix against SwiftData roots.
- Remaining Phase 7 and Phase 9 load, save, reload, adapter-failure, and crash-window coverage beyond the fresh-store final-CAS retry added here.
- Final-head evidence from an approved commit.
- Inherited PR 2d review-thread disposition.
- Complete ticket-wide requirement mapping.
