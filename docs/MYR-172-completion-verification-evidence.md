# MYR-172 Completion Verification Evidence

## Scope and final verdict

MYR-172 is one final Stage 1 closure PR. Its repository diff is limited to one
MyRAM adapter integration test and this evidence document. It does not enable
structural capture, reserve operation IDs from production capture, emit anchored
changes, change transport, incorporate structural operations, replace positional
replay, or alter persistence.

Final verdict: the assembled Stage 1 foundation is verified as one coherent,
fully dark system. All required repository, package, application, compatibility,
build, static, and architectural-conformance verification passed.

## Verified identities

- Refreshed baseline SHA:
  `cc952ff391f404eb2f1c195fb9ebdc8f57398009`
- Branch: `MYR-172-verify-dark-anchored-sequence-foundations`
- Xcode: 26.5 (build 17F42)
- Swift: Apple Swift 6.3.2
  (`swiftlang-6.3.2.1.108 clang-2100.1.1.101`)
- Selected simulator: iPhone 16 Pro,
  `1C546BCF-C14F-42C8-A4F1-B53026F3183C`
- Selected runtime: iOS 26.5
  (`com.apple.CoreSimulator.SimRuntime.iOS-26-5`)
- Verified anchored-payload test blob: `7c1ae3b78ded70d10fed19b60ab90a281f7eaf24`
- Standalone extraction directory form:
  `${TMPDIR:-/tmp}/MYR-172-AnchoredSequenceCore.XXXXXX/AnchoredSequenceCore`

The final commit SHA, PR number, and post-commit parity result intentionally
belong in the PR body and final handoff metadata rather than this commit.

## Assembled Stage 1 inventory

- **Capture-time identity:** Immutable operation IDs combine an actor UUID with
  a monotonically reserved local counter. Element IDs address UTF-16 units
  within their owning operation.
- **Durable actor sequence:** The portable package owns reservation transitions;
  MyRAM owns locked, durable application storage and restart behavior.
- **Structural sequence state:** Runs, insertion origins, visible/tombstoned
  fragments, element spans, deterministic traversal, and materialization form
  the portable state model.
- **Bootstrap identity and persistence:** Exact-UTF-16 note snapshots bootstrap
  deterministically into note-scoped synthetic state and persist through the
  MyRAM SwiftData adapter.
- **Full-body path integration:** Migration, import, restore, reconciliation,
  incoming compatibility application, and authoritative full-body replacement
  boundaries prepare or validate structural state without activating structural
  replay.
- **Anchored payload schema and MyRAM translation:** Portable insertion and
  deletion payloads are translated into MyRAM batch values by an application
  adapter.
- **Dark capability enforcement:** Anchored values remain representable for
  isolated verification but are rejected before transport, queues, convergence,
  recovery, positional replay, apply, and other active side effects.
- **Capability-off compatibility:** Production capture remains legacy-only,
  envelope versions remain V1, and independent legacy DTO tests verify recursive
  semantic equivalence without creating a canonical keyed-object byte contract.

## Resulting MyRAM invariants

- Operation IDs are immutable actor-and-counter identities.
- Text element IDs address UTF-16 units within an immutable operation-owned run.
- Valid insertion locations are structural gaps represented by empty, before,
  between, or after anchors.
- Two-sided anchors retain both boundaries when both exist.
- Tombstones retain structural identity and participate in gap resolution while
  remaining absent from visible materialization.
- Sibling placement is deterministic under canonical operation ordering.
- Validated fragments are the materialization source of truth.
- Surrogate pairs cannot be split by visible offsets, ranges, origins,
  fragments, or payload derivation.
- Nonempty legacy snapshots bootstrap to one deterministic synthetic run and
  one visible fragment.
- Bootstrap identity is note-scoped, format-versioned, and based on exact UTF-16
  topology.
- Existing corrupt, unsupported, or exact-body-mismatched sequence state fails
  closed and is not silently replaced.
- Capability-off production capture remains legacy positional capture.
- Anchored payloads remain representable for isolated testing but are rejected
  before every active side-effecting boundary.

## Deliberate MyRAM divergences

### Synthetic bootstrap identity for history-free snapshots

Reason: preexisting full-body notes have no original operation history to
reconstruct.

Consequence: identical note, body, and format-version inputs converge on one
identity, while divergent exact-UTF-16 bodies produce different identities and
explicit mismatch failure.

### Run, fragment, and span compaction

Reason: compact ranges avoid per-UTF-16-unit allocation and persistence
overhead.

Consequence: range validation, fragment coalescing, tombstone behavior, and
surrogate boundaries are explicit package invariants with dedicated tests.

### Application-owned durable actor storage

Reason: the portable package owns identity transitions while MyRAM owns
platform filesystem policy, backup exclusion, locking, and durability.

Consequence: package tests verify transition semantics; application tests verify
restart, contention, failure gaps, and storage behavior.

### Dark payload representation before atomic activation

Reason: schema, adapters, and failure boundaries must be proven before capture,
incorporation, and replay change atomically.

Consequence: anchored values can round-trip in isolated tests but cannot enter
transport, durable queues, convergence, recovery, positional replay, or apply
paths.

### Structural JSON compatibility

Reason: default JSON keyed-object order is not a supported canonical transport
guarantee.

Consequence: capability-off compatibility is proven by an empty production
diff, unchanged transport constants, independent legacy DTO decoding, and
recursive JSON equivalence that preserves semantic structure and array order.

## Architectural conformance audit

This audit derives its conclusions from current MyRAM and
`AnchoredSequenceCore` source, the MYR-167 through MYR-171 requirements and
completion records, and the executable tests recorded below.

### Operation and element identity

- **Implemented invariant:** `SyncOperationID` is an immutable actor UUID and
  local counter. `SyncTextElementID` is an immutable operation ID and
  nonnegative UTF-16 element offset. Durable allocation advances the actor
  counter without reusing a committed reservation after restart or failure.
- **Deliberate divergence:** One operation-level identity owns a run, and its
  element IDs are derived lazily from UTF-16 offsets rather than allocating or
  persisting a separate clocked object per element.
- **Reason:** One capture reservation must remain stable if its run is later
  split or partially tombstoned, while avoiding per-code-unit storage and
  reservation overhead.
- **Proving tests:** `SyncSequenceIdentityTests` includes
  `testOperationIdentityEqualityHashingAndKeyBehavior`,
  `testElementIdentityRejectsNegativeOffsetsFromConstructionAndDecoding`, and
  `testRunDerivesOneIdentityPerUTF16CodeUnit`.
  `SyncActorSequenceReservationTests.testRepeatedTransitionsProduceMonotonicCounters`
  proves the portable transition. Both application hosts run
  `MyRAMSyncOperationIDAllocatorTests`, including
  `testRecreatedAllocatorAdvancesExistingActor`,
  `testFailureAfterInstallationLeavesProtectedGapOnRetry`, and
  `testFailureAfterVerificationDoesNotReuseCommittedReservation`.
- **Conformance:** The assembled implementation preserves the MYR-167 identity
  model and MYR-168 durability boundary without adding a second identity or
  allocation path.

### Insertion-gap representation

- **Implemented invariant:** Valid insertion locations are explicit structural
  gaps represented by empty, before, between, or after anchors. A two-sided gap
  retains both neighboring element IDs.
- **Deliberate divergence:** Anchored values are derived from validated
  structural state but remain dark alongside the active legacy positional
  representation.
- **Reason:** Stable structural boundaries must be proven before capture,
  incorporation, and replay are activated together.
- **Proving tests:**
  `SyncTextOperationPayloadTests.testAnchorFactoriesEncodeTheFourExactShapes`,
  `testRootStateDerivesBeforeBetweenAndAfterAnchorsWithoutMutation`, and
  `testAnchorsCrossOperationOwnedRunBoundaries` prove the portable shapes and
  derivation. `SyncBatchAnchoredPayloadTests.testInsertProducesAllBoundaryAnchorsAndPreservesEvidence`
  proves MyRAM translation. The new
  `testBootstrapBackedVisibleRunChainProducesExpectedAnchorsIncludingMidRun`
  proves the assembled bootstrap-to-capture chain at offsets 0, 2, 3, 4, and 6.
- **Conformance:** The assembled implementation retains both sides of internal
  gaps and does not fall back to a one-sided or offset-only anchored schema.

### Concurrent sibling ordering

- **Implemented invariant:** Run arrays and sibling subtrees use canonical
  operation ordering by raw UUID bytes followed by local counter. Sibling
  subtrees remain contiguous, and fragment order must match origin-derived
  structural order.
- **Deliberate divergence:** Determinism is enforced through explicit canonical
  operation order and compact structural validation rather than insertion
  arrival order or a flattened per-element sequence.
- **Reason:** Independently assembled valid states must materialize the same
  structural order without per-element allocation.
- **Proving tests:**
  `SyncTextSequenceStateTests.testCanonicalOrderUsesRawUUIDBytesThenCounter`,
  `testSiblingSubtreesUseCanonicalOrderAndRemainContiguous`,
  `testFragmentProjectionRejectsSiblingInterleavingAndEqualVisibleText`, and
  `testDeepNestedChainUsesBoundedIterativeTraversalWork`.
- **Conformance:** The current validator, canonical run sort used by the new
  seam test, and passing hostile-state tests preserve the MYR-169 ordering
  decision without introducing arrival-order behavior.

### Tombstone retention and visibility

- **Implemented invariant:** Tombstoned fragments retain their operation-owned
  element identities and participate in structural gap resolution while
  remaining absent from `visibleText`.
- **Deliberate divergence:** Tombstones and deletion evidence use compact
  fragments and element-ID spans instead of persisted per-element objects.
- **Reason:** Compact structural ranges avoid per-UTF-16-unit allocation and
  persistence while retaining deleted identity.
- **Proving tests:**
  `SyncTextSequenceStateTests.testVisibilityMaterializationAnchorsAndRangesAreSurrogateSafe`
  and `testSelectedSpansDoNotCoalesceAcrossDescendantsOrVisibilityGaps`;
  `SyncTextOperationPayloadTests.testLeadingInternalAndTrailingTombstonesUseCanonicalBias`
  and `testTombstonedDescendantKeepsAdjacentParentSpansSeparate`; and MyRAM
  `SyncBatchAnchoredPayloadTests.testInsertBesideTombstoneUsesVisibleNeighbors`
  plus `testDeleteProducesOrderedSpansAcrossRunsAndTombstones`.
- **Conformance:** Tombstones remain structurally authoritative and invisible
  in materialized text, matching the MYR-169 state model and MYR-171 payload
  derivation.

### History-free bootstrap

- **Implemented invariant:** An empty legacy body maps to canonical empty state.
  A nonempty snapshot maps to one deterministic, note-scoped, V1 synthetic run
  and one visible fragment whose identity hashes exact UTF-16 topology.
  Existing corrupt, unsupported, or exact-body-mismatched state fails closed.
- **Deliberate divergence:** A synthetic bootstrap identity represents
  preexisting snapshots that have no reconstructable operation history.
- **Reason:** Identical note, body, and format-version inputs need one stable
  identity, while different exact UTF-16 bodies must not alias.
- **Proving tests:** `SyncTextLegacyBootstrapTests` includes
  `testV1KnownVectorFreezesDeterministicOperationID`,
  `testIdenticalInputsProduceIdenticalBootstrapState`,
  `testDifferentBodiesUnderSameNoteIDProduceDifferentRunIDs`,
  `testCanonicallyEquivalentBodiesWithDifferentUTF16TopologyDoNotAlias`,
  `testNonemptyBodyProducesOneRunAndOneVisibleFragment`, and
  `testSupplementaryScalarRetainsTwoElementOffsets`.
  `SwiftDataNoteSequenceStateStoreTests` includes
  `testBootstrapAdapterMatchesExplicitCoreV1`,
  `testLoadOrBootstrapRejectsExistingStateWhoseVisibleTextIsNotExactUTF16`,
  `testLoadOrBootstrapDoesNotReplaceCorruptExistingState`, and
  `testLoadOrBootstrapDoesNotReplaceUnsupportedExistingState`.
- **Conformance:** The MyRAM adapter delegates to the frozen portable V1 rule,
  and the persistence boundary preserves rather than repairs invalid existing
  state, matching MYR-170.

### Visible materialization and UTF-16 boundary behavior

- **Implemented invariant:** Validated fragments are the source of truth for
  visible materialization and counts. Origins, fragments, visible offsets,
  visible ranges, and payload derivation reject boundaries that split surrogate
  pairs.
- **Deliberate divergence:** Structural state uses compact UTF-16 ranges, and
  bootstrap/full-body ownership checks use exact UTF-16 equality rather than
  Unicode canonical equivalence.
- **Reason:** Element addressing operates on UTF-16 code units, so identity and
  body ownership must preserve exact topology while compact ranges avoid
  per-element state.
- **Proving tests:**
  `SyncTextSequenceStateTests.testSurrogateOriginsAcceptBeforeAndAfterButRejectInterior`,
  `testFragmentValidationRejectsUnknownOversizedSurrogateSplitAndMergeable`, and
  `testVisibilityMaterializationAnchorsAndRangesAreSurrogateSafe`;
  `SyncTextOperationPayloadTests.testSupplementaryScalarAnchorAndDeletionBoundariesAreSafe`;
  `SwiftDataNoteSequenceStateStoreTests.testExactTextComparisonRejectsCanonicallyEquivalentDifferentUTF16`;
  and `NoteSequenceStateFullBodyIntegrationTests.testReplaceBodyUsesExactUTF16RatherThanCanonicalStringEquality`
  plus `testReplaceBodyPersistsExactUTF16AcrossFreshContextWithoutSecondRewrite`.
- **Conformance:** Package and application boundaries consistently preserve
  exact UTF-16 identity and reject invalid structural splits, with no conflict
  between materialization, persistence, and payload derivation.

Across all six dimensions, the assembled implementation does not contradict the
recorded Stage 1 decisions. No external design detail was inferred and no
public-repository comparison was performed. Private historical design material
is not a delivery dependency or verification gap.

## Requirement-to-evidence mapping

- **Capture sequences produce the required cross-run anchor chain, including a
  mid-run position:** New
  `SyncBatchAnchoredPayloadTests.testBootstrapBackedVisibleRunChainProducesExpectedAnchorsIncludingMidRun`
  assembles MyRAM bootstrap output with an inserted run and verifies offsets
  0, 2, 3, 4, and 6. Existing tests retain empty, before, between, after, and
  tombstone-aware coverage.
- **Actor-sequence IDs are not reused after restart:** Package
  `SyncActorSequenceReservationTests` passed 6 tests. Focused iOS and native Mac
  `MyRAMSyncOperationIDAllocatorTests` each passed 16 tests, covering persisted
  counters, allocator recreation, contention, and failure gaps.
- **Identical seeded bodies derive identical identities:** Package
  `SyncTextLegacyBootstrapTests` passed 11 tests, including identical input,
  exact UTF-16 topology, note scoping, and the known V1 vector. Application
  adapter and state-store suites passed in both hosts.
- **Divergent bodies derive different identities and mismatch explicitly:**
  Bootstrap and SwiftData store suites passed different-body, exact-body
  mismatch, corruption, verification-failure, and existing-row-preservation
  cases.
- **The core builds and tests independently:** A clean copied package containing
  only `Package.swift`, `Sources`, and `Tests` reported zero dependencies,
  built successfully, and passed 71 tests.
- **Package boundaries and extraction readiness:** Production imports are only
  Foundation and CryptoKit. No individual package source is an Xcode source
  member. Xcode links the package product. The standalone package has no root or
  sibling dependency.
- **MyRAM decisions and deliberate divergences are documented:** The inventory,
  invariants, divergence, and architectural-conformance sections above derive
  the resulting MyRAM design from current source, MYR-167 through MYR-171
  records, Jira requirements, and exact passing tests.
- **Capability-off output remains compatible:** Production, package, project,
  schema, native Mac test, and UI test diffs are empty. Capability is exactly
  `false`; no production anchored adapter caller exists; both compatibility
  invocations passed 33 tests; both envelope schema constants remain `1`; the
  outer batch kind remains `myram.batchSync.v1`; no V2 symbol or transport
  encoder change was found.
- **Full test health:** The complete in-repository package passed 71 tests; the
  complete iOS scheme passed 915 application tests plus 6 UI tests; the complete
  native Mac scheme passed 530 tests; both application builds succeeded.
- **One dark closure change:** The working diff contains only the iOS-hosted
  adapter test and this document. No structural behavior was activated.

## Command-level verification

All Xcode test commands ran sequentially. The commands below are the literal
commands executed; no test selector or audit condition is delegated to another
document.

### Baseline refresh and branch publication

```bash
set -euo pipefail

REPO_ROOT="/Users/Shared/Development/XcodeProjects/MyRAM"
BRANCH="MYR-172-verify-dark-anchored-sequence-foundations"
cd "$REPO_ROOT"

git status --short
test -z "$(git status --porcelain)"

git fetch origin
git switch main
git pull --ff-only origin main

git status --short
test -z "$(git status --porcelain)"

git rev-parse HEAD
git rev-parse origin/main
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"

BASELINE_SHA="$(git rev-parse HEAD)"
printf 'MYR-172 baseline: %s\n' "$BASELINE_SHA"

git switch -c "$BRANCH"
git push -u origin "$BRANCH"

git branch --show-current
git status --short
```

- Exit status: 0
- Refreshed baseline: `cc952ff391f404eb2f1c195fb9ebdc8f57398009`
- Branch publication: succeeded before any edit

### In-repository package

```bash
set -euo pipefail
REPO_ROOT="/Users/Shared/Development/XcodeProjects/MyRAM"
cd "$REPO_ROOT/Packages/AnchoredSequenceCore"

swift test --filter SyncSequenceIdentityTests
swift test --filter SyncActorSequenceReservationTests
swift test --filter SyncTextSequenceStateTests
swift test --filter SyncTextLegacyBootstrapTests
swift test --filter SyncTextOperationPayloadTests
swift test
```

| Command | Exit | Tests | Failures |
| --- | ---: | ---: | ---: |
| `swift test --filter SyncSequenceIdentityTests` | 0 | 14 | 0 |
| `swift test --filter SyncActorSequenceReservationTests` | 0 | 6 | 0 |
| `swift test --filter SyncTextSequenceStateTests` | 0 | 14 | 0 |
| `swift test --filter SyncTextLegacyBootstrapTests` | 0 | 11 | 0 |
| `swift test --filter SyncTextOperationPayloadTests` | 0 | 26 | 0 |
| `swift test` | 0 | 71 | 0 |

No package warning or error was recorded.

### Standalone extraction

```bash
set -euo pipefail
REPO_ROOT="/Users/Shared/Development/XcodeProjects/MyRAM"
SOURCE_PACKAGE="$REPO_ROOT/Packages/AnchoredSequenceCore"
EXTRACTION_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/MYR-172-AnchoredSequenceCore.XXXXXX")"
EXTRACTED_PACKAGE="$EXTRACTION_ROOT/AnchoredSequenceCore"
trap 'rm -rf "$EXTRACTION_ROOT"' EXIT

mkdir -p "$EXTRACTED_PACKAGE"
rsync -a \
  --exclude '.build' \
  --exclude '.swiftpm' \
  "$SOURCE_PACKAGE/" \
  "$EXTRACTED_PACKAGE/"

find "$EXTRACTED_PACKAGE" \
  -maxdepth 1 \
  -mindepth 1 \
  -exec basename {} \; |
  sort

cd "$EXTRACTED_PACKAGE"
swift package dump-package > "$EXTRACTION_ROOT/dump-package.json"
swift package show-dependencies --format json > "$EXTRACTION_ROOT/dependencies.json"
python3 -c '
import json
import sys

payload = json.load(open(sys.argv[1]))
print("Standalone dependencies:", len(payload.get("dependencies", [])))
' "$EXTRACTION_ROOT/dependencies.json"
swift build
swift test
```

The copied root contained only `Package.swift`, `Sources`, and `Tests`.

| Command | Exit | Result |
| --- | ---: | --- |
| `swift package dump-package` | 0 | Manifest loaded outside the repository |
| `swift package show-dependencies --format json` | 0 | Zero dependencies |
| `swift build` | 0 | Build succeeded |
| `swift test` | 0 | 71 tests, 0 failures |

The temporary directory was removed by the shell trap after results were
recorded.

### iOS host

The simulator was selected and booted with:

```bash
set -euo pipefail
REPO_ROOT="/Users/Shared/Development/XcodeProjects/MyRAM"
cd "$REPO_ROOT"

SIMULATOR_UDID="$(
  xcrun simctl list devices available -j |
  python3 -c '
import json
import re
import sys

payload = json.load(sys.stdin)
candidates = []
for runtime_id, devices in payload.get("devices", {}).items():
    match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime_id)
    if match is None:
        continue
    version = tuple(int(part or 0) for part in match.groups())
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        name = device.get("name", "")
        if not name.startswith("iPhone"):
            continue
        candidates.append((
            device.get("state") == "Booted",
            version,
            name,
            device["udid"],
        ))

if not candidates:
    raise SystemExit("No available iPhone simulator found")

candidates.sort(key=lambda item: (
    not item[0],
    tuple(-part for part in item[1]),
    item[2],
    item[3],
))
print(candidates[0][3])
'
)"

test -n "$SIMULATOR_UDID"
IOS_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"
xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
printf 'Using iOS destination: %s\n' "$IOS_DESTINATION"
```

The resolved destination was
`platform=iOS Simulator,id=1C546BCF-C14F-42C8-A4F1-B53026F3183C`.

The new seam test was first verified with:

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination 'platform=iOS Simulator,id=1C546BCF-C14F-42C8-A4F1-B53026F3183C' \
  test \
  -only-testing:MyRAMTests/SyncBatchAnchoredPayloadTests
```

- Exit status: 0
- Tests: 15
- Failures: 0
- Warnings: three non-material AppIntents metadata-skip messages

The complete focused iOS Stage 1 matrix was:

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination 'platform=iOS Simulator,id=1C546BCF-C14F-42C8-A4F1-B53026F3183C' \
  test \
  -only-testing:MyRAMTests/SyncBatchAnchoredPayloadTests \
  -only-testing:MyRAMTests/MyRAMSyncOperationIDAllocatorTests \
  -only-testing:MyRAMTests/SwiftDataNoteSequenceStateStoreTests \
  -only-testing:MyRAMTests/NoteSequenceStateBootstrapMigratorTests \
  -only-testing:MyRAMTests/NoteSequenceStateFullBodyIntegrationTests \
  -only-testing:MyRAMTests/MYR170FullBodyPathIntegrationTests \
  -only-testing:MyRAMTests/PendingSyncRecoveryTests
```

- Exit status: 0
- Tests: 144
- Failures: 0
- Warnings: 0

The compatibility suite was executed twice with this literal loop:

```bash
for ATTEMPT in 1 2; do
  printf 'Compatibility invocation %s\n' "$ATTEMPT"
  xcodebuild \
    -project MyRAM.xcodeproj \
    -scheme MyRAM \
    -destination 'platform=iOS Simulator,id=1C546BCF-C14F-42C8-A4F1-B53026F3183C' \
    test \
    -only-testing:MyRAMTests/SyncBatchPayloadCompatibilityTests
done
```

- Invocation 1: exit 0; 33 tests; 0 failures; 0 warnings
- Invocation 2: exit 0; 33 tests; 0 failures; 0 warnings

The complete iOS scheme, including UI tests, was:

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination 'platform=iOS Simulator,id=1C546BCF-C14F-42C8-A4F1-B53026F3183C' \
  test
```

- Exit status: 0
- Tests: 915 application tests plus 6 UI tests
- Failures: 0
- Warnings: 0

The iOS build was:

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination 'generic/platform=iOS Simulator' \
  build
```

- Exit status: 0
- Result: `** BUILD SUCCEEDED **`
- Warnings: one non-material AppIntents metadata-skip message

The focused anchored-payload build logged three instances of the non-material
AppIntents metadata message: metadata extraction was skipped because the target
does not depend on AppIntents. The final iOS build logged the same message once.
The focused Stage 1, compatibility, and complete scheme logs contained no
warnings or errors.

### Native Mac host

The focused native Mac Stage 1 matrix was:

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  test \
  -only-testing:MyRAMMacTests/MyRAMSyncOperationIDAllocatorTests \
  -only-testing:MyRAMMacTests/SwiftDataNoteSequenceStateStoreTests \
  -only-testing:MyRAMMacTests/NoteSequenceStateBootstrapMigratorTests \
  -only-testing:MyRAMMacTests/NoteSequenceStateFullBodyIntegrationTests \
  -only-testing:MyRAMMacTests/MYR170MacFullBodyPathIntegrationTests \
  -only-testing:MyRAMMacTests/MacStartupCoordinatorTests \
  -only-testing:MyRAMMacTests/MacLegacySyncReceiverTests \
  -only-testing:MyRAMMacTests/MacSyncBatchControllerTests \
  -only-testing:MyRAMMacTests/MacSyncConvergenceCoordinatorTests
```

- Exit status: 0
- Tests: 143
- Failures: 0
- Warnings: two non-material AppIntents metadata-skip messages

The complete native Mac scheme was:

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  test
```

- Exit status: 0
- Tests: 530
- Failures: 0
- Warnings: 0

The native Mac build was:

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  build
```

- Exit status: 0
- Result: `** BUILD SUCCEEDED **`
- Warnings: one non-material AppIntents metadata-skip message

The focused Mac build logged two instances of the same non-material AppIntents
metadata-skip message. The final Mac build logged it once. The complete native
Mac scheme log contained no warnings or errors.

### Static-audit invocation note

The first combined version/static-audit shell was attempted without elevated
CoreSimulator access. The exact commands reached were:

```bash
set -euo pipefail
cd /Users/Shared/Development/XcodeProjects/MyRAM
xcodebuild -version
swift --version
xcrun simctl list devices available |
  rg -n 'iPhone 16 Pro.*1C546BCF-C14F-42C8-A4F1-B53026F3183C'
```

`xcodebuild -version` and `swift --version` exited 0. The simulator pipeline
exited 1 because the sandbox could not connect to CoreSimulatorService, so
`set -e` stopped the shell before any repository audit. No pass result is
claimed from that invocation.

### Successful static audit commands

Version and simulator identity:

```bash
xcodebuild -version
swift --version
xcrun simctl list devices available |
  rg -n 'iPhone 16 Pro.*1C546BCF-C14F-42C8-A4F1-B53026F3183C'
```

- Exit status: 0
- Result: Xcode 26.5 build 17F42; Apple Swift 6.3.2; selected iPhone 16
  Pro found

Package imports and prohibited-import failure condition:

```bash
set -euo pipefail
REPO_ROOT="/Users/Shared/Development/XcodeProjects/MyRAM"
CORE_SOURCES="$REPO_ROOT/Packages/AnchoredSequenceCore/Sources/AnchoredSequenceCore"

rg -n '^\s*import\s+' "$CORE_SOURCES"

if rg -n '^\s*import\s+(MyRAM|MyRAMMac|NearbySyncCore|SwiftData|SwiftUI|UIKit|AppKit|MultipeerConnectivity)\b' "$CORE_SOURCES"; then
  echo 'Prohibited AnchoredSequenceCore import found' >&2
  exit 1
fi
```

- Exit status: 0
- Result: imports limited to Foundation and CryptoKit; prohibited match absent

Direct Xcode source membership and package product linkage:

```bash
set -euo pipefail
REPO_ROOT="/Users/Shared/Development/XcodeProjects/MyRAM"
PBXPROJ="$REPO_ROOT/MyRAM.xcodeproj/project.pbxproj"
CORE_SOURCES="$REPO_ROOT/Packages/AnchoredSequenceCore/Sources/AnchoredSequenceCore"

while IFS= read -r SOURCE_FILE; do
  BASENAME="$(basename "$SOURCE_FILE")"
  if rg -n -F "$BASENAME" "$PBXPROJ"; then
    echo "Core source is directly referenced by Xcode project: $BASENAME" >&2
    exit 1
  fi
done < <(find "$CORE_SOURCES" -maxdepth 1 -type f -name '*.swift' | sort)

rg -n 'AnchoredSequenceCore' "$PBXPROJ" | head -30
```

- Exit status: 0
- Result: no direct source-file membership; expected local package and product
  references present

Public API inventory:

```bash
set -euo pipefail
REPO_ROOT="/Users/Shared/Development/XcodeProjects/MyRAM"
CORE_SOURCES="$REPO_ROOT/Packages/AnchoredSequenceCore/Sources/AnchoredSequenceCore"

rg -n '^\s*public\s+' "$CORE_SOURCES" |
  tee /private/tmp/MYR-172-public-api.txt
wc -l < /private/tmp/MYR-172-public-api.txt
```

- Exit status: 0
- Result: 104 public declaration lines reviewed and classified

Dark capability, production capture, reservation, and anchored-case inventories:

```bash
set -euo pipefail
REPO_ROOT="/Users/Shared/Development/XcodeProjects/MyRAM"
cd "$REPO_ROOT"

rg -n 'static let isEnabled = false' \
  MyRAM/Sync/Batch/SyncBatchAnchoredPayloadPolicy.swift

if rg -n 'static let isEnabled = true|SyncBatchAnchoredPayloadCapability\.isEnabled\s*=\s*true' MyRAM; then
  echo 'Anchored payload capability was enabled' >&2
  exit 1
fi

if rg -n 'SyncBatchAnchoredPayloadAdapter\.make(Inserted|Deleted)Change' MyRAM --glob '*.swift'; then
  echo 'Production anchored capture caller found' >&2
  exit 1
fi

rg -n 'reserveOperationID\(' MyRAM --glob '*.swift' || true
rg -n 'noteBodyTextInsertedAnchored|noteBodyTextDeletedAnchored' MyRAM --glob '*.swift'
```

- Exit status: 0
- Result: capability remained false; no production anchored adapter caller;
  reservation remained at the allocator boundary; anchored cases were
  declarations or fail-closed handling

Transport constants, encoder inventory, V2 failure condition, and baseline diff:

```bash
set -euo pipefail
REPO_ROOT="/Users/Shared/Development/XcodeProjects/MyRAM"
cd "$REPO_ROOT"

rg -n -C 2 'currentSchemaVersion|myram\.batchSync\.v1|JSONEncoder\(\)|outputFormatting' \
  MyRAM --glob '*.swift' |
  rg 'SyncBatchEnvelope|MultipeerSyncMessageEnvelope|myram\.batchSync\.v1|currentSchemaVersion|outputFormatting|JSONEncoder' |
  head -120

if rg -n 'batchSync\.v2|currentSchemaVersion\s*=\s*2' MyRAM --glob '*.swift'; then
  echo 'V2 transport behavior found' >&2
  exit 1
fi

git diff --name-only cc952ff391f404eb2f1c195fb9ebdc8f57398009 --

test -z "$(git diff --name-only \
  cc952ff391f404eb2f1c195fb9ebdc8f57398009 -- \
  MyRAM \
  Packages/AnchoredSequenceCore \
  Packages/NearbySyncCore \
  MyRAM.xcodeproj/project.pbxproj \
  MyRAMMacTests \
  MyRAMUITests)"
```

- Exit status: 0
- Result: both schema constants were `1`; outer kind was
  `myram.batchSync.v1`; no V2 value or transport option change; no prohibited
  baseline diff

Architectural-conformance source and test inventory:

```bash
rg -n '^\s*func test' \
  Packages/AnchoredSequenceCore/Tests/AnchoredSequenceCoreTests/SyncSequenceIdentityTests.swift \
  Packages/AnchoredSequenceCore/Tests/AnchoredSequenceCoreTests/SyncActorSequenceReservationTests.swift \
  Packages/AnchoredSequenceCore/Tests/AnchoredSequenceCoreTests/SyncTextSequenceStateTests.swift \
  Packages/AnchoredSequenceCore/Tests/AnchoredSequenceCoreTests/SyncTextOperationPayloadTests.swift \
  Packages/AnchoredSequenceCore/Tests/AnchoredSequenceCoreTests/SyncTextLegacyBootstrapTests.swift \
  MyRAMTests/MyRAMSyncOperationIDAllocatorTests.swift \
  MyRAMTests/SwiftDataNoteSequenceStateStoreTests.swift \
  MyRAMTests/NoteSequenceStateBootstrapMigratorTests.swift \
  MyRAMTests/NoteSequenceStateFullBodyIntegrationTests.swift \
  MyRAMTests/MYR170FullBodyPathIntegrationTests.swift

rg -n \
  'public struct SyncOperationID|public struct SyncTextElementID|public struct SyncTextInsertionOrigin|public struct SyncTextSequenceRun|public struct SyncTextSequenceFragment|public struct SyncTextSequenceState|operationAnchor|tombstonedUTF16Count|visibleText|isOrderedBefore|makeState|requireExactBody|loadOrBootstrap' \
  Packages/AnchoredSequenceCore/Sources/AnchoredSequenceCore \
  MyRAM/Sync/AnchoredSequence \
  --glob '*.swift'

rg -n -C 3 \
  'identity|anchor|sibling|tombstone|bootstrap|UTF-16|dark|capability|compatib' \
  docs/MYR-171-completion-verification-evidence.md
```

- Exit status: 0
- Result: all six required dimensions mapped to current implementation,
  established rationale, exact proving tests, and a no-contradiction conclusion

Project integrity and whitespace checks:

```bash
plutil -lint MyRAM.xcodeproj/project.pbxproj
xcodebuild -project MyRAM.xcodeproj -list
git diff --check
```

- Exit status: 0
- Result: project file valid; MyRAM and MyRAMMac schemes present; no whitespace
  errors

## Static, target-membership, and extraction audits

### Import and dependency boundary

Package production sources import Foundation, with CryptoKit additionally used
by deterministic legacy bootstrap. No application module, UI framework,
SwiftData, transport framework, or sibling package is imported. The standalone
dependency graph is empty, so the package does not depend on the repository
root.

### Xcode target membership

No `AnchoredSequenceCore` source filename appears as an individual Xcode source
reference. `project.pbxproj` contains the expected local Swift package reference,
product reference, and framework linkage. Package product linkage remains the
application integration mechanism.

### Public API classification

Every `public` declaration under
`Packages/AnchoredSequenceCore/Sources/AnchoredSequenceCore` was inventoried and
classified as:

- operation and UTF-16 element identity values and validation errors;
- actor-sequence state, reservation result, and transition operation;
- sequence operation ordering, origins, runs, fragments, spans, visibility,
  state, and documented state errors;
- materialized visibility, element-span, anchor, and payload queries;
- deterministic legacy bootstrap and its format version;
- portable insertion/deletion payloads, anchors, format versions, Codable
  conformance, and documented payload errors.

These values and operations are required across the package-to-application
boundary. Validation implementations, traversal metrics, encoding helpers,
digest framing, and unchecked construction remain non-public. MYR-172 adds no
package or production API and adds no convenience API for its test.

### Exact diff

The intended final diff is exactly:

1. `MyRAMTests/SyncBatchAnchoredPayloadTests.swift`
2. `docs/MYR-172-completion-verification-evidence.md`

There is no production, package, project, schema, native Mac test, UI test, or
script diff.

## Non-goals and remaining ownership

MYR-172 does not activate anchored capture, structural incorporation, mutation,
replay, convergence, negotiation, or rollout. MYR-173 retains atomic activation.
MYR-174 retains negotiation, rollout, and transport-version work.
