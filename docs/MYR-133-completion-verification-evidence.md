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
| Final CAS failure leaves original domains retryable, then fresh-store retry converges | `testMYR138FailedFinalCASFreshRelaunchDecodesBytesAndAvoidsDuplicateEffects` | Reconstructs retry state and immutable work by decoding persisted root payload bytes, re-invokes queue, legacy, and presentation adapter entry points from persisted all-pending state, and keeps physical effects exactly once through durable adapter idempotency keys |
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

Historical-at-SHA `036f38e8d4ef57777076698907c229bcbda81280`; the renamed MYR-138 final-head verification is recorded in `MYR-138 Verification`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testEightPendingStateMatrixWithLegacyAdapterPinsSingleCASEffects -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testPresentationRequestsUseAuthoritativeCommittedStateInDeterministicOrder -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testFinalCASFailureThenFreshStoreRetryRerunsIdempotentWorkAndCompletes
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Executed 3 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

Historical-at-SHA `036f38e8d4ef57777076698907c229bcbda81280`; the renamed MYR-138 final-head verification is recorded in `MYR-138 Verification`.

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

Verified implementation SHA: `83871a48b54377861e460e783c98bafb8fe7a735`

MYR-135 completes the operation-identity validation matrix for construction-time authority, post-commit payload validation, persisted SwiftData identity-row validation, and operation hash-chain validation.

This remediation is test-only except for Xcode test-target membership for the shared test helper. Production code remains unchanged from the original MYR-135 implementation.

### MYR-135 Requirement Matrix

| Requirement | Code/Test Location | Verification |
|---|---|---|
| Valid source-batch identity is accepted, persisted, and used to build exact work identity | `MyRAMTests/SyncConvergenceIncorporationTests.swift` `testMYR135ValidSourceIdentityPersistsAndBuildsExactWorkIdentity` | Focused iOS/macOS incorporation and post-commit suites |
| Legitimate non-source reconstructed-conflict identity remains accepted | `testMYR135ReconstructedConflictAcceptsLegitimateNonSourceIdentities` | Proves source-only pinning does not reject retained non-source evidence |
| Missing authoritative identity fails before commit without mutation | `testMYR135ConstructionIdentityMatrixFailsBeforeCommitWithoutMutation` case `missing authoritative identity` | Asserts `.failedBeforeCommit(.invalidMergePlan(...))` and `assertNoPreflightMutation` |
| Duplicate authoritative identity fails before commit without mutation | `testMYR135ConstructionIdentityMatrixFailsBeforeCommitWithoutMutation` case `duplicate batch index identity` | Same construction matrix and zero-mutation assertion |
| Wrong source batch ID fails before commit without mutation | `testMYR135ConstructionIdentityMatrixFailsBeforeCommitWithoutMutation` case `wrong outer batch ID` | Mutates outer and nested batch IDs |
| Wrong source origin fails before commit without mutation | `testMYR135ConstructionIdentityMatrixFailsBeforeCommitWithoutMutation` case `wrong source origin` | Source-batch exactness rejection |
| Negative operation index fails closed | Construction helper `assertMalformedIdentityFailsDuringProjectedEvidenceRecompute` case `negative outer operation index`; payload matrix case `negative operation index` | Construction path preserves original projected byte count and returns `.failedBeforeCommit(.unexpected)`; payload path rejects malformed work payload |
| Out-of-range source operation index fails before commit without mutation | `testMYR135ConstructionIdentityMatrixFailsBeforeCommitWithoutMutation` case `out-of-range source operation index` | Source index bounds rejection |
| Wrong operation kind fails closed | Construction case `wrong source operation kind`; payload case `work operation kind mismatch` | Construction and payload validators both reject kind mismatch |
| Wrong note ID fails closed | Construction-time ownership case `testSwappedOperationIdentityAcrossNotesFailsBeforeCommit`; payload case `operation note entry note mismatch` in `testMYR135PostCommitPayloadIdentityValidationMatrix` | Swapped same-kind identities fail before commit and work payload rejects note-entry mismatch |
| Same-kind swapped two-note identities fail before commit | `testSwappedOperationIdentityAcrossNotesFailsBeforeCommit` | Asserts swapped identities validate structurally but belong to the other note |
| Replay-key batch mismatch fails closed | Construction case `replay key batch mismatch`; payload case `identity replay key batch mismatch` | Nested replay-key linkage coverage |
| Replay-key origin mismatch fails closed | Construction case `replay key origin mismatch`; payload case `identity replay key origin mismatch` | Nested replay-key linkage coverage |
| Replay-key operation-index mismatch fails closed | Construction case `replay key operation index mismatch`; payload case `identity replay key index mismatch` | Nested replay-key linkage coverage |
| Resolvable replay-key note mismatch fails before commit | `testSwappedOperationIdentityAcrossNotesFailsBeforeCommit` helper `noteIDResolvingReplayKey` | Proves each swapped replay key resolves to the other note before rejection |
| Malformed UUID strings fail closed | Construction helper case `malformed outer batch UUID string`; payload cases `malformed outer batch UUID string`, `malformed outer origin UUID string`, `malformed nested replay-key UUID string` | Construction helper case `malformed outer batch UUID string` fails during projected-evidence recomputation and returns `.failedBeforeCommit(.unexpected)` with zero preflight mutation. Payload malformed UUID cases reach payload identity validation. |
| Noncanonical uppercase UUID strings fail closed | Construction case `uppercase outer source origin`; payload cases `uppercase outer batch UUID string`, `uppercase outer origin UUID string`, `uppercase nested replay-key UUID string` | Construction case `uppercase outer source origin` reaches canonical lowercase validation and returns `.failedBeforeCommit(.invalidMergePlan(noteID: nil))`; payload uppercase cases reject noncanonical UUID strings through `OperationIdentityPayload.validate()` |
| Plan to persisted child to work payload identity ownership is exact | `testTwoNoteExactOwnershipIncorporatesSuccessfully` | Proves exactly two persisted identity rows, one row per note, exactly two presentation entries, one entry per note, one incremental operation per entry, and each note's planned identity equals its persisted identity row and work payload identity without attaching to the other note |
| Post-commit payload rejects malformed operation identity matrix | `MyRAMTests/SyncConvergencePostCommitTests.swift` `testMYR135PostCommitPayloadIdentityValidationMatrix` | Covers note, index, kind, UUID, and replay-key linkage payload rows |
| Operation hash-chain matrix fails closed | `testMYR135OperationHashChainValidationMatrix` | Covers first operation base hash, later operation base hash, and final operation result hash mismatches |
| Valid persisted authoritative identity row loads and reaches presentation | `testMYR135ValidPersistedIdentityRowLoadsAndReachesPresentation` | Uses real SwiftData rows and a tracking legacy adapter, then reaches presentation |
| Persisted row corruption fails before queue, legacy, presentation, or CAS work | `testMYR135PersistedIdentityRowCorruptionFailsBeforeAdapters` | Covers wrong note ID, wrong batch ID, wrong operation index, wrong kind, wrong identity bytes, substituted identity bytes, wrong replay-key bytes, missing row, duplicate rows, noncanonical key, and wrong byte count; asserts queue removals, legacy calls, presentation requests, and root snapshot remain unchanged |
| Shared test helpers are consolidated | `MyRAMTests/SyncConvergenceIdentityTestSupport.swift` | Replaces duplicate `OperationIdentityPayload.replacingForTest` and `CanonicalReplayKeyPayload.replacingForTest` helpers in incorporation/post-commit tests |
| MYR-136 immutable-root CAS field matrix remains excluded | No MYR-136 production or test changes in this PR | Scope boundary preserved |
| MYR-133 remains incomplete | `Remaining MYR-133 Coverage Not Completed In This Pass` | This PR does not claim full MYR-133 completion |

### Commands Run

```bash
xcrun simctl list devices available
```

Exit code: 0. Selected `iPhone 16 Pro (1C546BCF-C14F-42C8-A4F1-B53026F3183C)` from available iOS 26.5 simulators.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergenceIncorporationTests -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Commit SHA: `83871a48b54377861e460e783c98bafb8fe7a735`. Exit code: 0. Executed 74 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergenceIncorporationTests -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Commit SHA: `83871a48b54377861e460e783c98bafb8fe7a735`. Exit code: 0. Executed 74 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePlanningTests -only-testing:MyRAMTests/SyncConvergenceIncorporationTests -only-testing:MyRAMTests/SyncConvergencePostCommitTests -only-testing:MyRAMTests/SyncConvergenceFoundationTests -only-testing:MyRAMTests/SyncBatchPayloadCompatibilityTests -only-testing:MyRAMTests/SyncBatchUnsentQueueTests
```

Commit SHA: `83871a48b54377861e460e783c98bafb8fe7a735`. Exit code: 0. Executed 191 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePlanningTests -only-testing:MyRAMMacTests/SyncConvergenceIncorporationTests -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests -only-testing:MyRAMMacTests/SyncBatchUnsentQueueTests
```

Commit SHA: `83871a48b54377861e460e783c98bafb8fe7a735`. Exit code: 0. Executed 150 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS Simulator' build
```

Commit SHA: `83871a48b54377861e460e783c98bafb8fe7a735`. Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' build
```

Commit SHA: `83871a48b54377861e460e783c98bafb8fe7a735`. Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
git diff --check
```

Commit SHA: `83871a48b54377861e460e783c98bafb8fe7a735`. Exit code: 0.

MYR-135 implementation is complete.

## MYR-136 Verification

Verified implementation SHA: `851c3f459513c650c885b40f22a96bc180e78c63`

Chosen iOS simulator: `iPhone 16 Pro (1C546BCF-C14F-42C8-A4F1-B53026F3183C)`

MYR-136 completes the immutable-root stale-CAS matrix for `SwiftDataSyncConvergencePostCommitStore.compareAndSetPostCommitState(...)`. The implementation is test-only. No production architecture changed, no per-domain CAS writes were added, and no active iOS or native macOS drain/controller integration was added.

### MYR-136 Requirement Matrix

| Requirement | Code/Test Location | Verification |
|---|---|---|
| `batchID` stale persisted root rejects as missing authoritative incorporation | `MyRAMTests/SyncConvergencePostCommitTests.swift` `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `batchID` | Focused iOS/macOS post-commit suites and adjacent regressions |
| `originDeviceID` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `originDeviceID` | Same matrix; complete raw row equality before/after CAS |
| `createdAt` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `createdAt` | Uses `setCreatedAt(...)` and proves no CAS-side mutation |
| `batchSequence` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `batchSequence` | Same matrix |
| `schemaVersion` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `schemaVersion` | Same matrix |
| `committedAt` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `committedAt` | Uses `setCommittedAt(...)` and proves no CAS-side mutation |
| `canonicalPayloadDigest` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `canonicalPayloadDigest` | Same matrix |
| `canonicalPayloadDigestFormatVersion` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `canonicalPayloadDigestFormatVersion` | Same matrix |
| `committedResultDigest` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `committedResultDigest` | Same matrix |
| `committedResultDigestFormatVersion` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `committedResultDigestFormatVersion` | Same matrix |
| `affectedNotesPayloadData` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `affectedNotesPayloadData` | Same matrix |
| `authoritativeChildCount` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `authoritativeChildCount` | Same matrix |
| `authoritativeChildBytes` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `authoritativeChildBytes` | Same matrix |
| `authoritativeChildrenDigest` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `authoritativeChildrenDigest` | Same matrix |
| `postCommitWorkPayloadData` stale persisted root rejects closed | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation` case `postCommitWorkPayloadData` | Same matrix; attempted new state differs so a partial write would be observable |
| Derived `committedAtOrderingPayloadData` stale expected snapshot rejects closed | `testMYR136DerivedCommittedAtOrderingPayloadMismatchRejectsCASWithoutMutation` | Separate derived-field row without mutating persisted `committedAt` |
| 15 persisted fields + 1 derived field cover all 16 immutable root projection fields | `testMYR136PersistedImmutableRootFieldMatrixRejectsStaleCASWithoutMutation`, `testMYR136DerivedCommittedAtOrderingPayloadMismatchRejectsCASWithoutMutation` | Focused iOS/macOS post-commit suites and adjacent regressions |
| Stale mutable expected-state payload is isolated from immutable-root mismatch | `testMYR136StaleExpectedStatePayloadRejectsCASWithoutMutation` | A -> B succeeds, then current root + stale A expected bytes attempting C fails and leaves B unchanged |
| Matching root plus matching prior state succeeds | `testMYR136MatchingRootAndPriorStateCASChangesOnlyMutableState` | Returned state and encoded bytes match expected B |
| Successful CAS changes only mutable state bytes | `testMYR136MatchingRootAndPriorStateCASChangesOnlyMutableState`, `MYR136RawRootSnapshot.replacingPostCommitStatePayloadData` | Full raw row equality except `postCommitStatePayloadData` |
| Partial clear, complete clear, and fresh-context reload preserve exact immutable work bytes | `testSwiftDataStoreReloadsAfterPartialAndFullClearWithRetainedWorkPayload`, `assertRootProjection` | Existing inline SwiftData fixture retained; exact work bytes and immutable projection are asserted across both clears and reloads |
| MYR-136 remains test/evidence scoped | No production files changed | No executor redesign, per-domain state persistence, model migration, or drain/controller integration |
| MYR-133 remains incomplete | `Remaining MYR-133 Coverage Not Completed In This Pass` | MYR-138, MYR-139, inherited review-thread disposition, and final ticket-wide evidence remain incomplete |

### Commands Run

```bash
xcrun simctl list devices available
```

Exit code: 0. Selected `iPhone 16 Pro (1C546BCF-C14F-42C8-A4F1-B53026F3183C)` from available iOS 26.5 simulators.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Commit SHA: `851c3f459513c650c885b40f22a96bc180e78c63`. Exit code: 0. Executed 33 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Commit SHA: `851c3f459513c650c885b40f22a96bc180e78c63`. Exit code: 0. Executed 33 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePlanningTests -only-testing:MyRAMTests/SyncConvergenceIncorporationTests -only-testing:MyRAMTests/SyncConvergencePostCommitTests -only-testing:MyRAMTests/SyncConvergenceFoundationTests -only-testing:MyRAMTests/SyncBatchPayloadCompatibilityTests -only-testing:MyRAMTests/SyncBatchUnsentQueueTests
```

Commit SHA: `851c3f459513c650c885b40f22a96bc180e78c63`. Exit code: 0. Executed 195 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePlanningTests -only-testing:MyRAMMacTests/SyncConvergenceIncorporationTests -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests -only-testing:MyRAMMacTests/SyncBatchUnsentQueueTests
```

Commit SHA: `851c3f459513c650c885b40f22a96bc180e78c63`. Exit code: 0. Executed 154 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS Simulator' build
```

Commit SHA: `851c3f459513c650c885b40f22a96bc180e78c63`. Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' build
```

Commit SHA: `851c3f459513c650c885b40f22a96bc180e78c63`. Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
git diff --check
```

Commit SHA: `851c3f459513c650c885b40f22a96bc180e78c63`. Exit code: 0.

MYR-136 is complete.
MYR-133 remains incomplete.

## MYR-137 Verification

Verified implementation SHA: `b42bc6a9529be587a1848ee9c3bcd385c9616b4b`.

Final evidence/head SHA: recorded by the evidence-only commit that updates this section.

Chosen iOS simulator: `iPhone 16 Pro (1C546BCF-C14F-42C8-A4F1-B53026F3183C)`.

This pass completes the MYR-137 shared test-support extraction, typed configurable fake store and adapter modes, executor-boundary failure coverage, adapter-failure matrices, real SwiftData malformed-load checks, stale-state remediation, and fresh-context partial-completion retry proof. It preserves the settled single-final-CAS executor architecture. No production files changed, no per-domain persistence writes were added, and no active iOS or native macOS drain/controller integration was added.

The new shared test-support file is `MyRAMTests/SyncConvergencePostCommitTestDoubles.swift`. It is compiled by both `MyRAMTests` and `MyRAMMacTests`.

### MYR-137 Requirement Matrix

| Requirement | Code/Test Location | Verification |
|---|---|---|
| Mechanical extraction compiles in both test targets | `SyncConvergencePostCommitTestDoubles.swift`, `MyRAM.xcodeproj/project.pbxproj` | Extraction-only focused iOS/macOS post-commit suites each passed 33 tests |
| Boolean fake failure flags are retired | `FakePostCommitStore.CASBehavior`, `FakeQueueCleanupAdapter.Behavior` | `shouldFailCAS` and `shouldThrowOnRemove` no longer exist |
| Fake store load boundary stops before adapters or CAS | `testMYR137FakeStoreLoadOutcomeAndFailureMatrixStopsBeforeAdaptersOrCAS` | Covers fake `.missing`, fake `.inconsistent`, typed thrown failure, and unexpected thrown error |
| Executor-only nil decoded work branch remains distinct from real-store missing persisted work | `testMYR137FakeFullRootMissingDecodedWorkFailsBeforeAdaptersOrCAS` | Uses fake `.fullRoot` with pending state and nil decoded work payload |
| Real SwiftData malformed/contradictory persisted loads fail closed without mutation | `testMYR137PersistedLoadFailureMatrixFailsClosedWithoutMutation` | Covers malformed state, missing work, malformed work, queue-pending empty IDs, and presentation-pending empty entries with full raw-row equality |
| Tombstone queue retry does not CAS and mismatch layers are distinct | `testMYR137TombstoneQueueFailureRetriesWithoutCASAndDistinguishesMismatchLayers` | Covers tombstone queue failure/retry, real-store tombstone identity mismatch, and executor `executeTombstone` request guard |
| Queue failure modes clear successful later domains and retry only queue | `testMYR137QueueFailureModesClearSuccessfulLaterDomainsAndRetryOnlyQueue` | Covers failure before removal, incomplete removal, and idempotent post-effect verification failure |
| Legacy failure modes clear other domains and retry only legacy | `testMYR137LegacyFailureModesClearOtherDomainsAndRetryOnlyLegacy` | Covers still-pending after effect, failure before effect, and idempotent after-effect failure |
| Presentation pre-action load failures clear earlier domains without adapter calls | `testMYR137PresentationPreActionLoadFailuresClearEarlierDomainsWithoutCallingAdapter` | Covers missing committed note and thrown note load |
| Presentation scripted failure replays domain idempotently | `testMYR137PresentationScriptedFailureReplaysDomainIdempotently` | Two-entry presentation work retains immutable bytes and replays both entries on retry |
| Mixed-domain zero-completion branch does not CAS | `testMYR137MixedFailureMatrixPreservesExactPendingSetIncludingZeroCompletionBranch` | Queue fail-before-removal, legacy failed, presentation failed; all three remain pending, CAS count is zero |
| Final CAS failure modes share executor outcome while preserving distinct authoritative states | `testMYR137FinalCASFailureModesPreserveAuthoritativeStoreStateAndImmutableWork` | Covers persistence failure, stale mutable state with queue/legacy already cleared, and immutable-root replacement |
| Advanced stale state changes only synchronized mutable state bytes | `replacingMutablePostCommitState`, `testMYR137FinalCASFailureModesPreserveAuthoritativeStoreStateAndImmutableWork` | `postCommitState`, `postCommitStatePayloadData`, and `root.postCommitStatePayloadData` advance together; original work object and bytes remain equal |
| Stale-state retry skips already-cleared domains from persisted authority | `testMYR137FinalCASFailureModesPreserveAuthoritativeStoreStateAndImmutableWork` retry assertions | Retry uses the unchanged original all-pending request, loads queue/legacy-cleared presentation-pending state, invokes only presentation, and persists `.none` |
| CAS attempt count increments before injected failure/replacement | `FakePostCommitStore.compareAndSetPostCommitState`, final-CAS matrix assertions | `casAttemptCount == 1` for injected CAS failures |
| Real fresh-context partial-completion retry preserves immutable evidence | `testMYR137PartialCompletionSurvivesFreshSwiftDataContextAndRetryRunsOnlyRemainingDomain` | First pass persists legacy-only state; fresh-context retry invokes only legacy and completes |
| Existing retained tests remain present | `SyncConvergencePostCommitTests` | Eight-state matrices, queue-failure progress, final-CAS retry, tombstone cleanup, pre-payload guard, queue rollback, and MYR-136 CAS/retained-work tests all passed in focused suites |

### Commands Run

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Extraction commit `395fb0e`. Exit code: 0. Executed 33 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Extraction commit `395fb0e`. Exit code: 0. Executed 33 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Typed-mode conversion pass before new MYR-137 matrix tests. Exit code: 0. Executed 33 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Typed-mode conversion pass before new MYR-137 matrix tests. Exit code: 0. Executed 33 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Partial MYR-137 checkpoint before the remaining adapter and real-store matrix rows. Exit code: 0. Executed 37 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Partial MYR-137 checkpoint before the remaining adapter and real-store matrix rows. Exit code: 0. Executed 37 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Final MYR-137 implementation. Exit code: 0. Executed 44 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Final MYR-137 implementation. Exit code: 0. Executed 44 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

MYR-137 is complete. MYR-133 remains incomplete.

### PR #85 Second-Review Remediation Verification

```bash
xcrun simctl list devices available
```

Exit code: 0. Selected `iPhone 16 Pro (1C546BCF-C14F-42C8-A4F1-B53026F3183C)`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Implementation commit `b42bc6a9529be587a1848ee9c3bcd385c9616b4b`. Destination `iPhone 16 Pro (1C546BCF-C14F-42C8-A4F1-B53026F3183C)`. Exit code: 0. Executed 44 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Implementation commit `b42bc6a9529be587a1848ee9c3bcd385c9616b4b`. Destination `platform=macOS`. Exit code: 0. Executed 44 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePlanningTests -only-testing:MyRAMTests/SyncConvergenceIncorporationTests -only-testing:MyRAMTests/SyncConvergencePostCommitTests -only-testing:MyRAMTests/SyncConvergenceFoundationTests -only-testing:MyRAMTests/SyncBatchPayloadCompatibilityTests -only-testing:MyRAMTests/SyncBatchUnsentQueueTests
```

Implementation commit `b42bc6a9529be587a1848ee9c3bcd385c9616b4b`. Destination `iPhone 16 Pro (1C546BCF-C14F-42C8-A4F1-B53026F3183C)`. Exit code: 0. Executed 206 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePlanningTests -only-testing:MyRAMMacTests/SyncConvergenceIncorporationTests -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests -only-testing:MyRAMMacTests/SyncBatchUnsentQueueTests
```

Implementation commit `b42bc6a9529be587a1848ee9c3bcd385c9616b4b`. Destination `platform=macOS`. Exit code: 0. Executed 165 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS Simulator' build
```

Implementation commit `b42bc6a9529be587a1848ee9c3bcd385c9616b4b`. Destination `generic/platform=iOS Simulator`. Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' build
```

Implementation commit `b42bc6a9529be587a1848ee9c3bcd385c9616b4b`. Destination `platform=macOS`. Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
git diff --check
```

Implementation commit `b42bc6a9529be587a1848ee9c3bcd385c9616b4b`. Exit code: 0.

```bash
git status --short
```

Implementation commit `b42bc6a9529be587a1848ee9c3bcd385c9616b4b`. Exit code: 0. Working tree clean.

```bash
git diff --stat origin/main...HEAD
```

Implementation commit `b42bc6a9529be587a1848ee9c3bcd385c9616b4b`. Exit code: 0. Diff remains scoped to `MyRAM.xcodeproj/project.pbxproj`, `MyRAMTests/SyncConvergencePostCommitTestDoubles.swift`, `MyRAMTests/SyncConvergencePostCommitTests.swift`, and `docs/MYR-133-completion-verification-evidence.md`.

```bash
git log --oneline origin/main..HEAD
```

Implementation commit `b42bc6a9529be587a1848ee9c3bcd385c9616b4b`. Exit code: 0. Commits at verification time: `b42bc6a`, `6bc54d2`, `a3c2b85`, `395fb0e`.

At the end of the MYR-137 remediation, MYR-137 was complete. MYR-133 remained incomplete. MYR-138 remained incomplete at that historical checkpoint. MYR-139 remained incomplete.

## MYR-138 Verification

Implementation SHA: recorded by the MYR-138 implementation commit.

Final evidence/head SHA: recorded by the MYR-138 implementation commit.

Selected iOS simulator: `iPhone 16 Pro (1C546BCF-C14F-42C8-A4F1-B53026F3183C)`.

MYR-138 is a test and evidence pass. No production source changed. `MyRAM.xcodeproj/project.pbxproj` remained unchanged. No per-domain CAS was introduced. No active drain/controller integration was added.

"Interruption after one domain CAS and before another" is not applicable. The settled executor performs queue, legacy, and presentation work before one final CAS. Crashes between domains leave the original persisted pending state intact and are covered through idempotent replay from seeded durable external-effect snapshots.

### MYR-138 Requirement Matrix

| Requirement | Code/Test Location | Verification |
|---|---|---|
| Durable external-effect state survives executor, adapter, and store reconstruction | `DurablePostCommitExternalEffectLedger` in `MyRAMTests/SyncConvergencePostCommitTestDoubles.swift` | Shared iOS/macOS post-commit suites |
| Seeded queue removals and runtime `containsBatch` consult the same durable removed-batch state | `seedQueueRemoval(...)`, `containsBatch(...)`, `IdempotentQueueCleanupAdapter.containsBatch` | `testMYR138TombstoneRelaunchAfterQueueEffectReverifiesIdempotentlyWithoutCAS` |
| Adapter invocation is distinct from physical effect count | `DurablePostCommitExternalEffectLedger` invocation and physical-effect counters | Same-context, fresh-relaunch, pre-CAS matrix, acknowledgement-loss, and tombstone tests |
| Presentation deduplication and seeding use immutable `entry.committedPostBodyHash` | `seedPresentationCompletion(...)`, `IdempotentPresentationAdapter.refreshPresentation(...)` | All MYR-138 presentation-pending tests assert physical presentation count by immutable work-entry hash |
| Pre-CAS crash boundaries replay persisted pending domains idempotently | `testMYR138RelaunchFromEachPreCASCrashBoundaryReplaysAdaptersIdempotently` | Covers before external work, after queue cleanup, after legacy cleanup, and after presentation refresh |
| Same-context final-CAS failure retry re-invokes adapters without duplicate physical effects | `testMYR138FailedFinalCASSameContextRetryReinvokesAdaptersWithoutDuplicatingEffects` | First pass fails before mutation; retry uses same store/context and reaches `.none` |
| Fresh relaunch after failed final CAS decodes state and work from bytes | `testMYR138FailedFinalCASFreshRelaunchDecodesBytesAndAvoidsDuplicateEffects` | Reconstructs through `FakePostCommitStore(reloading:notes:)`, re-invokes adapters, and preserves immutable work bytes |
| Final persistence completed but caller lost acknowledgement relaunches complete | `testMYR138CommittedFinalStateSurvivesLostCASResponseAndRelaunchesComplete`, `FakePostCommitStore.CASBehavior.commitThenFailResponse` | First process commits `.none` then throws; relaunch uses post-CAS committed root and performs no adapters or CAS |
| Tombstone relaunch after queue effect reverifies idempotently without CAS | `testMYR138TombstoneRelaunchAfterQueueEffectReverifiesIdempotentlyWithoutCAS` | Seeded removal makes `containsBatch` return false, queue verifies completion, no CAS occurs |
| Every legacy-pending fixture uses a non-nil idempotent legacy adapter | MYR-138 tests in `SyncConvergencePostCommitTests.swift` | Executor reaches `.none` for legacy-pending fixtures |
| Every presentation-pending relaunch seeds the committed note through `FakePostCommitStore(reloading:notes:)` | MYR-138 pre-CAS, fresh-relaunch, and acknowledgement-loss tests | Avoids unrelated missing-note failure and proves crash recovery |
| Immutable work bytes remain unchanged through retry and state transition | MYR-138 assertions against `postCommitWorkPayloadData` and `currentWorkPayloadData` | Shared iOS/macOS post-commit suites |

### Commands Run

```bash
xcrun simctl list devices available
```

Exit code: 0. Selected `iPhone 16 Pro (1C546BCF-C14F-42C8-A4F1-B53026F3183C)` from available iOS 26.5 simulators.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Immediately after changing the shared fake CAS success path. Exit code: 0. Executed 44 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Immediately after changing the shared fake CAS success path. Exit code: 0. Executed 44 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Final MYR-138 iOS verification. Exit code: 0. Executed 48 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Final MYR-138 macOS verification. Exit code: 0. Executed 48 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

The same-context retry result is covered by `testMYR138FailedFinalCASSameContextRetryReinvokesAdaptersWithoutDuplicatingEffects`.

The fresh-context byte-reconstruction result is covered by `testMYR138FailedFinalCASFreshRelaunchDecodesBytesAndAvoidsDuplicateEffects`.

The pre-CAS boundary matrix result is covered by `testMYR138RelaunchFromEachPreCASCrashBoundaryReplaysAdaptersIdempotently`.

The acknowledgement-loss result is covered by `testMYR138CommittedFinalStateSurvivesLostCASResponseAndRelaunchesComplete`.

The tombstone relaunch result is covered by `testMYR138TombstoneRelaunchAfterQueueEffectReverifiesIdempotentlyWithoutCAS`.

The immutable-work equality result is asserted in the MYR-138 pre-CAS, same-context, fresh-relaunch, and acknowledgement-loss tests.

MYR-138 is complete. MYR-133 remains incomplete. MYR-139 remains incomplete.

## Remaining MYR-133 Coverage Not Completed In This Pass

The attached MYR-133 proposal is broader than this initial implementation pass. These items still need additional work before claiming full ticket completion:

- MYR-139 final MYR-133 release-evidence pass.
- Final-head evidence from an approved commit.
- Inherited PR 2d review-thread disposition.
- Complete ticket-wide requirement mapping.
