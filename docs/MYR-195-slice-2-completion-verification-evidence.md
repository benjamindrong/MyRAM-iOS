# MYR-195 Slice 2 Completion & Verification Evidence (Ninth Remediation)

**Date:** 2026-07-29
**Story:** MYR-195 (Slice 2: Rendered Markdown Preview)
**Branch:** `MYR-195-Slice-2-Rendered-Markdown-Preview`

---

## 1. Repository Identity

```text
Repository:                     benjamindrong/MyRAM-iOS
Pull request:                   #113
PR title:                       MYR-195 Slice 2: Rendered Preview
Branch:                         MYR-195-Slice-2-Rendered-Markdown-Preview
Base SHA (main):                ce48f814a2c74e7f01bd5e4e34c22f732f680871
Ninth-remediation baseline:     17594b8d0d1e17b21ef415941ac4058653213757
Immutable implementation SHA:   69beb37617b3dde2eb335920755528d11d8e1a06
Verification simulator:         iPhone 16 Pro
Verification simulator UDID:    1C546BCF-C14F-42C8-A4F1-B53026F3183C
```

The evidence commit SHA is intentionally not recorded in this file. The PR body owns the
evidence SHA and final local/upstream/PR-head parity after push.

GitHub preflight at the ninth-remediation baseline reported no check runs. Final check-run
state must be queried again after the evidence commit is pushed; this document does not
describe CI as green.

---

## 2. Ninth Remediation Summary

### 2.1 Accepted restore supersession

**Production:** `MyRAM/Markdown/MarkdownPreviewUIKitAcceptedRestoreSupersession.swift`,
`MyRAM/Markdown/MarkdownPreviewUIKitPostResignationReconciliation.swift`,
`MyRAM/Views/NoteEditorView.swift`

**Tests:** `MyRAMTests/MarkdownPreviewUIKitHarnessTests.swift`

- Restore token, restore generation, and editor synchronization generation remain distinct
  Swift types and ownership domains.
- Restore acceptance uses ordered restore-generation semantics. Generation `0`, an
  already-handled token, an equal generation, and a lower generation are rejected.
- A first valid owner-issued restore is accepted when there is no last-applied generation.
- Every accepted restore calls one synchronous, `@MainActor`, callback-free production
  operation that begins a new synchronization generation and discards older applied-content
  bookkeeping.
- Accepted restore handling runs before the ordinary stale synchronization-input guard, so
  a valid explicit restore is not rejected because its reconciliation snapshot is stale.
- The accepted-restore operation runs even when the native attributed content already equals
  the requested content. Assignment and replacement-maintenance callbacks are skipped in
  that case, but synchronization is still superseded and the restore is still acknowledged.
- Native assignment necessity uses full `NSAttributedString` equality, including attributes.

### 2.2 Rejected restore and queued-sync contracts

- A `nil` restore request means no new restore command exists and ordinary reconciliation may
  continue.
- A non-`nil` restore request that classifies as already handled, invalid, duplicate, or stale
  returns immediately with no synchronization advancement, bookkeeping mutation, native
  replacement, ordinary bound replacement, publication, clear, or acknowledgment.
- Deterministic tests queue editor synchronization A through the production sync executor,
  accept restore B through production reconciliation and the production supersession
  operation, then execute A.
- In both accepted/different and accepted/already-matching cases, A writes zero plain or rich
  bound values, publishes zero changes, clears no restore-era bookkeeping, and completes
  exactly once. Native and bound values remain B.
- Existing ordinary B-before-A, synchronous supersession, no-difference supersession,
  callback-boundary supersession, weak teardown, scheduler, and native Undo controls remain
  green.

---

## 3. Implementation Files

Implementation commit `69beb37617b3dde2eb335920755528d11d8e1a06` changes exactly:

```text
MyRAM.xcodeproj/project.pbxproj
MyRAM/Markdown/MarkdownPreviewUIKitAcceptedRestoreSupersession.swift
MyRAM/Markdown/MarkdownPreviewUIKitPostResignationReconciliation.swift
MyRAM/Views/NoteEditorView.swift
MyRAMTests/MarkdownPreviewUIKitHarnessTests.swift
```

No model, schema, package, synchronization transport, payload, replay, convergence,
capability, or Slice 1 file-I/O file changed.

---

## 4. Verification Commands and Results

All post-commit verification ran against immutable implementation
`69beb37617b3dde2eb335920755528d11d8e1a06`. Every post-commit command block in sections 4.2
through 4.7 verified the exact head and clean worktree before invoking its check. Console
output was filtered to retain diagnostics and result/count lines under `pipefail`; the exact
`xcodebuild` invocations, destinations, and selectors are shown below.

### 4.1 Focused pre-commit checks

```bash
SIMULATOR_UDID='1C546BCF-C14F-42C8-A4F1-B53026F3183C'
IOS_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"

xcrun simctl boot "$SIMULATOR_UDID"
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination "$IOS_DESTINATION" \
  test \
  -only-testing:MyRAMTests/MarkdownPreviewUIKitHarnessTests \
  -only-testing:MyRAMTests/MarkdownPreviewIntegrationTests

git diff --check
```

**Result:** `TEST SUCCEEDED` — **49 tests, 0 failures**

- UIKit harness: 35 tests
- Preview integration: 14 tests
- Working-tree `git diff --check`: no output

### 4.2 Focused tests against the immutable implementation SHA

```bash
set -euo pipefail

IMPLEMENTATION_SHA='69beb37617b3dde2eb335920755528d11d8e1a06'
SIMULATOR_UDID='1C546BCF-C14F-42C8-A4F1-B53026F3183C'
IOS_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"

test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"

xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination "$IOS_DESTINATION" \
  test \
  -only-testing:MyRAMTests/MarkdownPreviewParserTests \
  -only-testing:MyRAMTests/MarkdownPreviewIntegrationTests \
  -only-testing:MyRAMTests/MarkdownPreviewUIKitHarnessTests
```

**Result:** `TEST SUCCEEDED` — **65 tests, 0 failures**

- Preview parser: 16 tests
- Preview integration: 14 tests
- UIKit harness: 35 tests

The harness result includes:

```text
accepted newer restore with different native attributed content
first valid restore with already-matching native attributed content
already-handled token rejection
generation-zero rejection
duplicate-generation rejection
stale-generation rejection
rejected non-nil native/bound mismatch with no ordinary replacement
restore B before queued synchronization A
ordinary deferred B before A
synchronous and no-difference B before A
mid-callback supersession
weak-dependency teardown
production scheduler enqueue-only behavior
native Undo through resignation and both reconciliation passes
```

### 4.3 Explicit Preview UI tests

```bash
set -euo pipefail

IMPLEMENTATION_SHA='69beb37617b3dde2eb335920755528d11d8e1a06'
SIMULATOR_UDID='1C546BCF-C14F-42C8-A4F1-B53026F3183C'
IOS_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"

test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"

xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination "$IOS_DESTINATION" \
  test \
  -only-testing:MyRAMUITests/MarkdownPreviewUITests
```

**Result:** `TEST SUCCEEDED` — **7 UI tests, 0 failures**

- `testDifferentNoteSelectionResetsToEditMode`
- `testEditIsDefaultModeOnNoteOpen`
- `testEditorDismissesKeyboardAndDoesNotRegainFocusInPreview`
- `testMixedNestedListRendersWithoutFallback`
- `testRapidPreviewToggleRemainsEdit`
- `testTopBarSearchCannotPresentDuringPreview`
- `testUnsavedMarkdownAppearsInPreview`

### 4.4 Complete iOS scheme

```bash
set -euo pipefail

IMPLEMENTATION_SHA='69beb37617b3dde2eb335920755528d11d8e1a06'
SIMULATOR_UDID='1C546BCF-C14F-42C8-A4F1-B53026F3183C'
IOS_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"

test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"

xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination "$IOS_DESTINATION" \
  test
```

**Result:** `TEST SUCCEEDED`

- Application tests: **1,019**, 0 failures
- UI and launch tests: **13**, 0 failures

The UI count comprises 7 `MarkdownPreviewUITests`, 5 `MyRAMUITests`, and 1
`MyRAMUITestsLaunchTests` test.

### 4.5 Complete Mac scheme

```bash
set -euo pipefail

IMPLEMENTATION_SHA='69beb37617b3dde2eb335920755528d11d8e1a06'

test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  test
```

**Result:** `TEST SUCCEEDED` — **599 tests, 0 failures**

### 4.6 Generic iOS Simulator and native Mac builds

```bash
set -euo pipefail

IMPLEMENTATION_SHA='69beb37617b3dde2eb335920755528d11d8e1a06'

test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination 'generic/platform=iOS Simulator' \
  build

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  build
```

**Result:**

- Generic iOS Simulator build: `BUILD SUCCEEDED`
- Native Mac build: `BUILD SUCCEEDED`

### 4.7 Project checks

```bash
set -euo pipefail

IMPLEMENTATION_SHA='69beb37617b3dde2eb335920755528d11d8e1a06'

test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"

plutil -lint MyRAM.xcodeproj/project.pbxproj
xcodebuild -project MyRAM.xcodeproj -list
```

**Result:**

- `MyRAM.xcodeproj/project.pbxproj: OK`
- Scheme discovery succeeded and included `MyRAM` and `MyRAMMac`

---

## 5. Static and Range Audits

### 5.1 Implementation-range whitespace

```bash
set -euo pipefail

IMPLEMENTATION_SHA='69beb37617b3dde2eb335920755528d11d8e1a06'

test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"

git diff --check \
  ce48f814a2c74e7f01bd5e4e34c22f732f680871..."$IMPLEMENTATION_SHA"
```

**Result:** no output

### 5.2 Forbidden scope

```bash
set -euo pipefail

IMPLEMENTATION_SHA='69beb37617b3dde2eb335920755528d11d8e1a06'

test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"

git diff \
  ce48f814a2c74e7f01bd5e4e34c22f732f680871..."$IMPLEMENTATION_SHA" \
  -- \
  Packages \
  MyRAM/MyRAMSchema.swift \
  MyRAM/Models \
  MyRAM/Sync \
  MyRAM/Markdown/MarkdownFileIO.swift \
  MyRAM/Mac/MacMarkdownFileCommands.swift \
  MyRAM/Mac/MacMarkdownExternalImportCoordinator.swift \
  MyRAM/Mac/MacMarkdownFileOperationCoordinator.swift \
  MyRAM/Views/NoteEditorFileOperationBridge.swift
```

**Result:** no output

### 5.3 Restore and synchronization ownership mapping

```bash
rg -n \
  'MarkdownPreviewUIKitRestoreAcceptance|supersedeEditorSynchronizationForAcceptedRestore|MarkdownPreviewUIKitAcceptedRestoreSupersession|isEqual\(to:|testAcceptedNewerRestore|testAcceptedFirstRestore|testRejectedNonNilRestore|testDeferredBPublishesBeforeA|testNativeUndoSurvives' \
  MyRAM/Markdown \
  MyRAM/Views/NoteEditorView.swift \
  MyRAMTests/MarkdownPreviewUIKitHarnessTests.swift
```

**Result:** mapped and manually inspected

- Ordered restore classification is production-owned.
- `nil` restore input is distinct from terminal non-`nil` rejection.
- Classification precedes accepted-restore supersession.
- Rejected requests cannot reach supersession, assignment, acknowledgment, or ordinary
  reconciliation.
- Accepted restore supersession advances the real coordinator-scoped synchronization owner
  and discards older applied-content state in one synchronous operation.
- Production reconciliation and deterministic tests call that same operation.
- Full attributed equality controls assignment only; it does not control acceptance or
  supersession.
- Restore, restore-generation, and synchronization-generation types are not compared or
  assigned across ownership domains.

### 5.4 Deterministic restore-versus-queued-sync results

| Case | Sync advancement | Old bookkeeping | Native assignment | A after restore | A completion |
|---|---:|---|---|---|---:|
| Accepted newer B, native differs | Once | Discarded | Full attributed B | 0 writes, 0 publications | Once |
| First accepted B, native already matches | Once | Discarded | Skipped | 0 writes, 0 publications | Once |
| Already-handled token | None | Preserved | None | Not applicable | Not applicable |
| Generation `0` | None | Preserved | None | Not applicable | Not applicable |
| Duplicate generation | None | Preserved | None | Not applicable | Not applicable |
| Stale generation | None | Preserved | None | Not applicable | Not applicable |

The rejected cases use a native/bound mismatch and prove there is no fallthrough to ordinary
bound replacement. Both accepted cases preserve native B, bound plain B, and bound rich-text
B after queued A executes.

---

## 6. Verification Classification

| Evidence | Classification | Result |
|---|---|---|
| Focused parser/integration/UIKit harness tests | Automated | PASS |
| Explicit Preview UI tests | Automated | PASS |
| Complete iOS application and UI schemes | Automated | PASS |
| Complete Mac scheme | Automated | PASS |
| Generic iOS Simulator and native Mac builds | Automated | PASS |
| Project lint and scheme discovery | Automated | PASS |
| Working-tree and implementation-range whitespace checks | Automated | PASS |
| Forbidden-scope diff | Automated | PASS |
| Restore/synchronization ownership mapping | Manual code audit | PASS |
| Hands-on exploratory UI run | Not run | Automated UI coverage used |
| Final GitHub local/upstream/PR-head parity | Not run | Requires evidence commit and push |
| Final GitHub check-run query | Not run | Requires evidence commit and push |
| PR-body evidence mapping | Not run | Requires evidence commit and GitHub write |
| Inline thread reply and resolution | Not run | Requires final parity and PR-body mapping |
| Top-level review closure | Not run | Requires subsequent independent PR review |
| Final evidence-head ranged `git diff --check` | Not run | Must run immediately after evidence commit |

No manual or GitHub result is inferred from an automated test.

---

## 7. Non-Failing Diagnostics

The successful Mac test and both build runs reported that App Intents metadata extraction
was skipped because there is no `AppIntents.framework` dependency. Git read commands
intermittently reported an fsmonitor IPC warning while otherwise completing successfully.
Neither diagnostic failed a test, build, lint, or audit, and the working tree remained clean.

---

## 8. Remaining Review-State Gates

This evidence does **not** claim that PR `#113` is merge-ready.

After the evidence-only commit:

1. Prove the implementation-to-evidence range contains exactly this document.
2. Run the final evidence-head/full-PR `git diff --check`.
3. Push and prove local/upstream/PR-head parity.
4. Re-query GitHub check runs and accurately record that state.
5. Update the PR body from this committed evidence without changing the PR title.
6. Reply to and resolve inline thread `PRRT_kwDOQFbles6UvUzQ` with the implementation SHA,
   production supersession operation, combined regression tests, and evidence mapping.
7. Map top-level review `PRR_kwDOQFbles8AAAABHpBUCw` to the implementation and evidence.
8. Request an independent PR re-review. Only that review may confirm closure of the
   top-level accepted-restore supersession finding.
