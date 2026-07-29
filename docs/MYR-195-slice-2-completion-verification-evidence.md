# MYR-195 Slice 2 Completion & Verification Evidence (Eighth Remediation)

**Date:** 2026-07-28
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
Eighth-remediation baseline:    f92fc640416a00311a1507573644de9090ed86c2
Immutable implementation SHA:   b5f0be93d664da52f06d6ff8db91a610fac108a3
Verification simulator UDID:    1C546BCF-C14F-42C8-A4F1-B53026F3183C
```

The evidence commit SHA is intentionally not recorded in this file. The PR body owns the
evidence SHA and final local/upstream/PR-head parity after push.

---

## 2. Eighth Remediation Summary

### 2.1 Generation-owned UIKit synchronization

**Production:** `MyRAM/Markdown/MarkdownPreviewUIKitSyncExecutor.swift`,
`MyRAM/Markdown/MarkdownPreviewUIKitDeferredScheduler.swift`,
`MyRAM/Views/NoteEditorView.swift`

**Tests:** `MyRAMTests/MarkdownPreviewUIKitHarnessTests.swift`

- Every editor synchronization begins a coordinator-scoped, monotonically increasing
  `MarkdownPreviewUIKitSyncGeneration`.
- Beginning newer synchronous, deferred, or no-difference work invalidates older pending
  bookkeeping before bound values are read.
- Generation-owned record, clear, and discard operations centralize their ownership
  predicates and contain no suspension points or external callbacks.
- Deferred work checks generation and weak-dependency availability at entry and after every
  potentially reentrant binding or publication callback.
- Superseded work stops all later writes, publication, and bookkeeping mutation while still
  completing exactly once.
- Production uses the shared enqueue-only
  `MarkdownPreviewUIKitDeferredScheduler.enqueue` operation. Deterministic executor tests
  inject a controllable queue and deliberately execute B before A.

### 2.2 Private editor boundary and production-path Undo proof

**Production:** `MyRAM/Views/NoteEditorView.swift`,
`MyRAM/Markdown/MarkdownPreviewUIKitEditorResignation.swift`,
`MyRAM/Markdown/MarkdownPreviewUIKitPostResignationReconciliation.swift`

**Tests:** `MyRAMTests/MarkdownPreviewUIKitHarnessTests.swift`,
`MyRAMUITests/MarkdownPreviewUITests.swift`

- `SelectableTextView` is file-private again; tests do not instantiate the representable or
  expose its coordinator.
- Production and tests call the same focus-resignation operation.
- `updateUIView` delegates raw-state reconciliation to the shared production reconciliation
  operation. Callers do not supply a precomputed replacement decision.
- Restore token, restore generation, and synchronization generation are distinct Swift types
  and ownership domains.
- The production operation internally derives restore, native-buffer preservation,
  binding-catch-up, and authoritative bound-replacement behavior.
- A real hosted `UITextView` test performs a native edit, Preview resignation, Preview
  reconciliation, return-to-Edit reconciliation, and native Undo using the same text view
  and `UndoManager`.

### 2.3 Hygiene

- Removed the existing full-PR trailing whitespace from
  `MyRAM/Markdown/MarkdownPreview.swift` and
  `MyRAMTests/MarkdownPreviewParserTests.swift`.
- The implementation-range whitespace audit and forbidden-scope audit are clean.

---

## 3. Implementation Files

The eighth-remediation implementation commit changes exactly:

```text
MyRAM.xcodeproj/project.pbxproj
MyRAM/Markdown/MarkdownPreview.swift
MyRAM/Markdown/MarkdownPreviewUIKitDeferredScheduler.swift
MyRAM/Markdown/MarkdownPreviewUIKitEditorResignation.swift
MyRAM/Markdown/MarkdownPreviewUIKitPostResignationReconciliation.swift
MyRAM/Markdown/MarkdownPreviewUIKitSyncExecutor.swift
MyRAM/Views/NoteEditorView.swift
MyRAMTests/MarkdownPreviewParserTests.swift
MyRAMTests/MarkdownPreviewUIKitHarnessTests.swift
```

`MarkdownPreview.swift` and `MarkdownPreviewParserTests.swift` contain whitespace-only
eighth-remediation changes.

---

## 4. Verification Commands and Results

Every post-commit verification group first proved:

```bash
IMPLEMENTATION_SHA='b5f0be93d664da52f06d6ff8db91a610fac108a3'
test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"
```

### 4.1 Focused pre-commit checks

```bash
SIMULATOR_UDID='1C546BCF-C14F-42C8-A4F1-B53026F3183C'
IOS_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination "$IOS_DESTINATION" \
  test \
  -only-testing:MyRAMTests/MarkdownPreviewUIKitHarnessTests \
  -only-testing:MyRAMTests/MarkdownPreviewIntegrationTests

git diff --check
```

**Result:** `TEST SUCCEEDED` — **46 tests, 0 failures**

- UIKit harness: 32 tests
- Preview integration: 14 tests
- Working-tree `git diff --check`: no output

### 4.2 Focused tests against the immutable implementation SHA

```bash
IMPLEMENTATION_SHA='b5f0be93d664da52f06d6ff8db91a610fac108a3'
SIMULATOR_UDID='1C546BCF-C14F-42C8-A4F1-B53026F3183C'
IOS_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"

test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination "$IOS_DESTINATION" \
  test \
  -only-testing:MyRAMTests/MarkdownPreviewParserTests \
  -only-testing:MyRAMTests/MarkdownPreviewIntegrationTests \
  -only-testing:MyRAMTests/MarkdownPreviewUIKitHarnessTests
```

**Result:** `TEST SUCCEEDED` — **62 tests, 0 failures**

- Preview parser: 16 tests
- Preview integration: 14 tests
- UIKit harness: 32 tests

The harness result includes deterministic B-before-A execution, synchronous and
no-difference supersession, mid-plain-setter/mid-rich-setter/mid-publication supersession,
generation-scoped record/clear/discard behavior, weak-dependency teardown, exactly-once
completion, shared production scheduler execution, raw-input reconciliation controls, and
the production-path native Undo regression.

### 4.3 Explicit Preview UI tests

```bash
IMPLEMENTATION_SHA='b5f0be93d664da52f06d6ff8db91a610fac108a3'
SIMULATOR_UDID='1C546BCF-C14F-42C8-A4F1-B53026F3183C'
IOS_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"

test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"

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
IMPLEMENTATION_SHA='b5f0be93d664da52f06d6ff8db91a610fac108a3'
SIMULATOR_UDID='1C546BCF-C14F-42C8-A4F1-B53026F3183C'
IOS_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"

test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination "$IOS_DESTINATION" \
  test
```

**Result:** `TEST SUCCEEDED`

- Application tests: **1,016**, 0 failures
- UI tests: **13**, 0 failures

### 4.5 Complete Mac scheme

```bash
IMPLEMENTATION_SHA='b5f0be93d664da52f06d6ff8db91a610fac108a3'

test "$(git rev-parse HEAD)" = "$IMPLEMENTATION_SHA"
test -z "$(git status --short)"

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  test
```

**Result:** `TEST SUCCEEDED` — **599 tests, 0 failures**

### 4.6 Builds

```bash
IMPLEMENTATION_SHA='b5f0be93d664da52f06d6ff8db91a610fac108a3'

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
- Mac build: `BUILD SUCCEEDED`

### 4.7 Project checks

```bash
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
git diff --check \
  ce48f814a2c74e7f01bd5e4e34c22f732f680871...b5f0be93d664da52f06d6ff8db91a610fac108a3
```

**Result:** no output

### 5.2 Forbidden scope

```bash
git diff \
  ce48f814a2c74e7f01bd5e4e34c22f732f680871...b5f0be93d664da52f06d6ff8db91a610fac108a3 \
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

### 5.3 Generation and scheduler mapping

```bash
rg -n \
  'SyncGeneration|currentGeneration|isCurrentGeneration|MarkdownPreviewUIKitDeferredScheduler|scheduleDeferred|recordAppliedContentIfCurrent|clearAppliedContentIfOwned|discardAppliedContentSuperseded' \
  MyRAM/Markdown/MarkdownPreviewUIKitSyncExecutor.swift \
  MyRAM/Markdown/MarkdownPreviewUIKitDeferredScheduler.swift \
  MyRAM/Views/NoteEditorView.swift \
  MyRAMTests/MarkdownPreviewUIKitHarnessTests.swift
```

**Result:** mapped and manually inspected

- Generation owner creation and overflow protection:
  `MarkdownPreviewUIKitSyncExecutor.swift`
- Coordinator-scoped generation owner and exact production scheduler wiring:
  `NoteEditorView.swift`
- Generation-current record, generation-and-synchronization clear, and current-generation
  superseded-state discard: `MarkdownPreviewUIKitSyncExecutor.swift`
- Initial and post-callback stale checks:
  `MarkdownPreviewUIKitSyncExecutor.swift`
- Deterministic B-before-A, mid-callback supersession, weak teardown, and production scheduler
  tests: `MarkdownPreviewUIKitHarnessTests.swift`

### 5.4 Privacy and reconciliation mapping

```bash
rg -n \
  '^private struct SelectableTextView|^struct SelectableTextView|MarkdownPreviewUIKitEditorResignation|MarkdownPreviewUIKitPostResignationReconciliation|MarkdownPreviewUIKitRestoreToken|MarkdownPreviewUIKitRestoreGeneration|AuthoritativeReplacement|shouldReplace|isAuthoritativeReplacement' \
  MyRAM/Views/NoteEditorView.swift \
  MyRAM/Markdown \
  MyRAMTests
```

**Result:** mapped and manually inspected

- Exactly one file-private `SelectableTextView`
- No test instantiation of `SelectableTextView`
- Production and tests call the shared resignation and reconciliation operations
- Production `updateUIView` passes raw reconciliation inputs and contains no parallel
  replacement decision
- Restore token, restore generation, and synchronization generation are distinct types
- No caller-owned `AuthoritativeReplacement`, `shouldReplace`, or
  `isAuthoritativeReplacement` conclusion remains

---

## 6. Verification Classification

| Evidence | Classification | Result |
|---|---|---|
| Focused parser/integration/UIKit harness tests | Automated | PASS |
| Explicit Preview UI tests | Automated | PASS |
| Complete iOS application and UI schemes | Automated | PASS |
| Complete Mac scheme | Automated | PASS |
| Generic iOS Simulator and Mac builds | Automated | PASS |
| Project lint and scheme discovery | Automated | PASS |
| Working-tree and implementation-range whitespace checks | Automated | PASS |
| Forbidden-scope diff | Automated | PASS |
| Generation/scheduler source mapping | Manual code audit | PASS |
| Privacy/reconciliation source mapping | Manual code audit | PASS |
| Hands-on exploratory UI run | Not run | Automated UI coverage used |
| GitHub local/upstream/PR-head parity | Not run | Requires evidence commit and push |
| PR-body evidence mapping | Not run | Requires evidence commit and GitHub approval |
| Inline review-thread inventory/resolution | Not run | Requires final parity and GitHub approval |
| Top-level review closure | Not run | Requires subsequent independent PR review |
| Final evidence-head ranged `git diff --check` | Not run | Must run immediately after evidence commit |

No manual or GitHub result is inferred from an automated test.

---

## 7. Non-Failing Diagnostics

The successful verification runs emitted the following non-failing diagnostics:

- The iOS application reported that `net.daringfireball.markdown` was expected in the app
  type declarations but was not found.
- Some text-view tests reported TextKit 1 compatibility-mode activation.
- Some existing tests reported SwiftData `ModelContext` queue-use diagnostics.
- The native Undo harness emitted UIKit window/first-responder and appearance-transition
  diagnostics without a test failure.
- UI launches intermittently emitted Xcode
  `DebuggerLLDB.DebuggerVersionStore.StoreError` / `no debugger version`.
- Both builds reported that App Intents metadata extraction was skipped because there is no
  `AppIntents.framework` dependency.
- Git read commands intermittently reported an fsmonitor IPC warning; the commands otherwise
  completed successfully and the working tree remained clean.

These diagnostics did not fail a test, build, lint, or audit. They are not represented as
new eighth-remediation defects.

---

## 8. Remaining Review-State Gates

This evidence does **not** claim that review threads are resolved or that PR `#113` is
merge-ready.

After the evidence-only commit:

1. Prove the evidence-only range contains exactly this document.
2. Run the final evidence-head/full-PR `git diff --check`.
3. Push only after approval and prove local/upstream/PR-head parity.
4. Update the PR body from this committed evidence without changing the PR title.
5. Inventory, reply to, and resolve supported inline review threads after approval.
6. Map top-level review `4800107626` to the implementation and evidence.
7. Request an independent PR re-review; only that review may confirm closure of the
   top-level stale-sync and privacy findings.
