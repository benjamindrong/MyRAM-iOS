# MYR-195 Slice 1 Completion Verification Evidence

## Scope and verdict

MYR-195 Slice 1 adds detached raw Markdown file import and export to the
iOS/iPadOS application and the native `MyRAMMac` target. It does not add a
Markdown note type, parser, rendered Preview, schema field, sync payload,
anchored capture, structural replay, file bookmark, or write-back behavior.

Automated verdict: remediation-focused tests, complete application suites, both
application builds, project/property-list validation, and architectural guards
passed at the tested implementation SHA below.

Manual picker, Finder/Open With, forced-save-failure, and destination-write
failure scenarios were not driven interactively in this automated session.
Their underlying ordering and failure contracts are covered by focused tests,
but the proposal's manual verification checklist remains a pre-merge product
verification gate.

## Verified identities

- Base SHA: `417cda0437e3e14703f6ee15250a3b4884ed2589`
- Reviewed remediation base SHA:
  `d3ab61ce2e4073470381b28e2988cf4a0218db21`
- Tested implementation SHA:
  `1ba561f539e8f4610f98df2eee7cbceead762a6d`
- Branch: `MYR-195-Slice-1-Raw-Markdown-file-I-O`
- Intended PR title: `MYR-195 Slice 1: Raw Markdown file I/O`
- Xcode: 26.5 (build 17F42)
- Swift: Apple Swift 6.3.2
  (`swiftlang-6.3.2.1.108 clang-2100.1.1.101`)
- Simulator: iPhone 16 Pro,
  `1C546BCF-C14F-42C8-A4F1-B53026F3183C`
- Runtime: iOS 26.5
  (`com.apple.CoreSimulator.SimRuntime.iOS-26-5`)

All behavioral and static results below apply to the tested implementation SHA.
The evidence commit identity and evidence-only parity proof belong in the PR
body and final handoff metadata.

## Changed-file inventory through the tested implementation SHA

```text
MyRAM.xcodeproj/project.pbxproj
MyRAM/Info.plist
MyRAM/Mac/Info.plist
MyRAM/Mac/MacMarkdownFileCommands.swift
MyRAM/Mac/MacMarkdownFileOperationCoordinator.swift
MyRAM/Mac/MacNotePersistenceAdapter.swift
MyRAM/Mac/MyRAMMacApp.swift
MyRAM/Mac/MyRAMMacRootView.swift
MyRAM/Markdown/MarkdownFileIO.swift
MyRAM/ViewModels/NotesViewModel.swift
MyRAM/Views/NoteEditorFileOperationBridge.swift
MyRAM/Views/NoteEditorView.swift
MyRAM/Views/NotesListView.swift
MyRAMMacTests/MacMarkdownFileIOIntegrationTests.swift
MyRAMMacTests/MacNotePersistenceAdapterTests.swift
MyRAMTests/MarkdownFileIOTests.swift
MyRAMTests/MarkdownFileOperationBoundaryTests.swift
MyRAMTests/MarkdownImportIntegrationTests.swift
MyRAMTests/MyRAMTests.swift
docs/MYR-195-slice-1-completion-verification-evidence.md
```

The range contains 20 files. The remediation commit changes only the ten
expected production and test surfaces relative to the reviewed remediation
base.

## Shared file contracts

- Classification uses content-type metadata first and case-insensitive `.md`
  and `.myram` extension fallbacks. Markdown and `.myram` remain closed,
  distinct routes; the router does not use trial decoding.
- The shared Markdown content type is the existing public
  `net.daringfireball.markdown` UTI. MyRAM does not export or redefine it.
- Reading performs one complete `Data` load and failable strict UTF-8 decoding.
  Invalid UTF-8 fails before an imported document or model is created.
- Valid source is not trimmed, parsed, normalized, or line-ending converted.
  Empty source, CRLF, bare CR, LF, whitespace topology, supplementary scalars,
  and canonically distinct Unicode sequences remain intact.
- Imported title comes only from the visible filename stem, with `Untitled` as
  the empty/whitespace fallback.
- Export bytes are exactly `Data(source.utf8)`: no BOM, appended newline,
  Unicode normalization, RTF, attachments, pinned text, Preview output, or
  `.myram` manifest.
- Filename sanitization removes a duplicate `.md` suffix, replaces invalid
  characters, applies the deterministic character-safe cap, and appends one
  `.md`.
- Direct writing uses `Data.write(to:options: .atomic)` behind an injectable
  seam. Tests prove exact bytes, preserved existing destination on injected
  failure, and no temporary artifact left by successful or injected-failure
  cases.

## iOS ownership and ordering

`NotesListView` owns one `NoteEditorFileOperationBridge`, one
`MarkdownImportOperationCoordinator`, and the production
`ExternalImportURLRouter`. The mounted `NoteEditorView` registers and
unregisters an editor-local flush closure that cannot provide its own identity.
The caller supplies `ExpectedEditor` from the authoritative `selectedNote`
lifecycle state, and the bridge authorizes that identity before invoking the
closure. A stale editor unregister cannot clear a newer registration.

The flush closure cancels the debounce without discarding pending state,
resolves deferred rich-text encoding through the existing editor commit path,
and receives the result-bearing `NotesViewModel.commitNoteEdit` outcome.
Persistence/capture failure leaves the mutation pending and returns failure.

Explicit picker import enters `MarkdownImportOperationCoordinator.perform`.
Externally delivered files enter `ExternalImportURLRouter`, which performs
metadata/extension-only classification and dispatches Markdown to that same
coordinator while leaving `.myram` on its existing importer. The coordinator
then:

1. Rejects concurrent ownership.
2. Authorizes the expected editor identity.
3. Flushes only the matching editor.
4. Stops before any body read or model consumption when the editor is
   unavailable, mismatched, or fails its local flush.
5. Enters balanced security-scoped consumption access.
6. Revalidates Markdown classification.
7. Reads and strictly decodes the body.
8. Calls the dedicated view-model import transaction.

The view-model transaction constructs the note with its final title and exact
body, prepares revision-zero state from that body, inserts note and state
through `NoteSequenceStateFullBodyIntegration.insertNewNote`, applies the
ordinary current-folder policy, and saves once. Failure rolls back note, state,
folder timestamp, undo state, and selection. Sync publication, folder
publication, undo registration, refresh, and selection occur only after save.

iOS export calls the editor-local flush method directly; it does not consult the
list-owned bridge or another editor registration. The export preparation
coordinator cannot snapshot source after a failed flush and captures the latest
raw editor source only after success. The system file exporter receives the
shared exact UTF-8 data and shared sanitized filename.

Focused boundary tests prove the five-case identity matrix, bridge-owned
identity, stale-unregister safety, zero downstream effects for flush failure,
mismatch, and unavailable-editor states, production Markdown routing order,
`.myram` and unsupported routing isolation, export snapshot suppression on
failure, capture of latest raw source after success, and independence from
another editor's bridge registration.

## Native Mac ownership and ordering

`MacNotePersistenceAdapter.createNote` is the single blank/imported creation
seam. Markdown import supplies the final title, exact body, and nil rich-text
data before revision-zero state preparation, one atomic insert, and one save.
Save failure rolls back both note and state.

`MacMarkdownFileCommands` uses focused scene actions from
`MyRAMMacRootView`; it does not use global callbacks or NotificationCenter.
Import/export command availability is gated by startup readiness, selection
where required, and single file-operation ownership.

`MacMarkdownFileOperationCoordinator` owns the ordering:

- Import flushes before panel presentation, file consumption, persistence,
  publication, or selection. Cancellation stops before consumption. A
  committed note publishes before list/editor presentation. Presentation
  failure returns an explicit committed-but-not-presented outcome and is
  surfaced as non-retryable.
- Export flushes before reloading canonical persisted source, presenting the
  save panel, or writing. Cancellation does not write. Only `Note.content`
  enters the shared writer.

Finder/Open With URLs are captured outside the ready subtree in the production
`MacMarkdownOpenURLQueue`, then drained serially after startup reaches `.ready`.
The queue refuses to dequeue while an operation or unacknowledged error is
present. Alert acknowledgment clears the error and resumes draining. Queued
imports use the same coordinator and flush boundary as the File menu action.

Focused tests prove panel and downstream suppression on failed flush,
commit-before-publication/presentation ordering, committed presentation
failure semantics without automatic re-import, cancellation, queue startup
gating, error pause/preservation/resumption, latest-source capture after flush,
exact raw export, generalized atomic Markdown creation, revision-zero state,
nil rich-text data, and rollback.

## Document registration

Both `MyRAM/Info.plist` and `MyRAM/Mac/Info.plist` register:

```text
Content type: net.daringfireball.markdown
Extension: md
Role: Editor
Handler rank: Alternate
```

The iOS proprietary `.myram` declaration is unchanged. The native Mac Bonjour
and local-network entries are preserved. Neither property list exports a new
Markdown UTI.

## Focused verification

### iOS

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination \
    'platform=iOS Simulator,id=1C546BCF-C14F-42C8-A4F1-B53026F3183C' \
  test \
  -only-testing:MyRAMTests/MarkdownFileIOTests \
  -only-testing:MyRAMTests/MarkdownImportIntegrationTests \
  -only-testing:MyRAMTests/MarkdownFileOperationBoundaryTests \
  -only-testing:MyRAMTests/MYR170FullBodyPathIntegrationTests \
  -only-testing:MyRAMTests/SyncBatchPayloadCompatibilityTests
```

Result: `TEST SUCCEEDED`; 95 tests executed, 0 failures.

- `MarkdownFileIOTests`: 15
- `MarkdownImportIntegrationTests`: 6
- `MarkdownFileOperationBoundaryTests`: 18
- `MYR170FullBodyPathIntegrationTests`: 23
- `SyncBatchPayloadCompatibilityTests`: 33

### Native Mac

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  test \
  -only-testing:MyRAMMacTests/MarkdownFileIOTests \
  -only-testing:MyRAMMacTests/MacMarkdownFileIOIntegrationTests \
  -only-testing:MyRAMMacTests/MacNotePersistenceAdapterTests \
  -only-testing:MyRAMMacTests/MYR170MacFullBodyPathIntegrationTests \
  -only-testing:MyRAMMacTests/MacStartupCoordinatorTests
```

Result: `TEST SUCCEEDED`; 71 tests executed, 0 failures.

- `MarkdownFileIOTests`: 15
- `MacMarkdownFileIOIntegrationTests`: 10
- `MacNotePersistenceAdapterTests`: 33
- `MYR170MacFullBodyPathIntegrationTests`: 10
- `MacStartupCoordinatorTests`: 3

## Complete-suite verification

### iOS application

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination \
    'platform=iOS Simulator,id=1C546BCF-C14F-42C8-A4F1-B53026F3183C' \
  test
```

Result: `TEST SUCCEEDED`.

- `MyRAMTests.xctest`: 954 tests, 0 failures.
- `MyRAMUITests`: five UI tests passed.
- `MyRAMUITestsLaunchTests`: one launch test passed.

### Native Mac application

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  test
```

Result: `TEST SUCCEEDED`; 557 tests executed, 0 failures.

## Build verification

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Result: `BUILD SUCCEEDED`.

```bash
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  build
```

Result: `BUILD SUCCEEDED`.

Both builds emitted only the existing informational warning that App Intents
metadata extraction was skipped because the target has no AppIntents framework
dependency.

## Project and static verification

The following passed:

```bash
plutil -lint MyRAM/Info.plist
plutil -lint MyRAM/Mac/Info.plist
plutil -lint MyRAM.xcodeproj/project.pbxproj
xcodebuild -project MyRAM.xcodeproj -list
git diff --check origin/main...HEAD
git status -sb
git diff --stat origin/main...HEAD
git diff --name-only origin/main...HEAD
```

The Xcode project lists both `MyRAM` and `MyRAMMac` targets and schemes.
At the tested implementation SHA, the working tree was modified only by this
pending evidence update.

## Architectural guardrails

- `SyncBatchAnchoredPayloadCapability.isEnabled` remains `false`.
- No `isEnabled = true` anchored capability activation was found.
- No production call to
  `SyncBatchAnchoredPayloadAdapter.makeInsertedChange` or
  `makeDeletedChange` was introduced.
- No `batchSync.v2` or `currentSchemaVersion = 2` activation was found.
- Shared files under `MyRAM/Markdown` import neither UIKit nor AppKit.
- No Markdown model, schema, or sync field was added under models, sync code,
  or packages.
- Markdown creation reuses the existing MYR-170
  `prepareInitialState` plus
  `NoteSequenceStateFullBodyIntegration.insertNewNote` boundary on both
  platforms. No second shared full-body persistence coordinator was added.
- `.myram` remains a separate route and Markdown bytes cannot reach its JSON
  decoder.
- No parser, rendered Preview, mode state, syntax highlighting, third-party
  package, bookmark, monitoring, or write-back behavior is present.

## Manual verification record

No interactive manual file-picker, Finder/Open With, forced persistence
failure, or forced destination-write failure runs were performed during this
automated implementation session.

The automated coverage verifies the underlying behavior at deterministic
boundaries:

- exact representative UTF-8 source topology and filename title;
- empty source and invalid UTF-8;
- active-editor flush success/failure ordering;
- explicit/external type-only routing without body reads;
- import transaction rollback and post-commit ordering;
- latest raw source export after flush;
- exclusion of rich-text representation from export bytes;
- cancellation and atomic writer failure;
- production external Markdown/`.myram`/unsupported routing;
- expected-editor mismatch and unavailable-editor fail-closed behavior;
- startup gating and queued Mac pause/resume around acknowledged errors;
- committed Mac import followed by presentation failure;
- existing `.myram`, rich-text, blank-note, sync, convergence, and capability
  compatibility through complete suites.

Interactive product verification remains explicitly unclaimed and should be
completed before merge using Section 14 of the approved implementation
proposal.
