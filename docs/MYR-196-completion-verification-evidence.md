# MYR-196 Completion Verification Evidence

## Verified revisions

```text
Repository: benjamindrong/MyRAM-iOS
Base branch: main
Base SHA: 4334f3f3ea718d5523ace296b84feb52df4c0d40
Branch: MYR-196-Mac-Note-Zoom-Native-Markdown-Preview
Original implementation SHA: 11346a8aa9ff6a582995609a355be0068392566e
Naming-policy SHA: b86e9648b8c563d39d2332684d317a5593f73879
Integration-proof SHA: 4f7225713407d639f02a02612b899b98b23bc6ca
Markdown Preview UI focus SHA: c94ec99b889a51e9d4cc648f4eef08bff32f86fe
Nested Markdown UI focus SHA: 4be12dc08677412f7c9fed5e8c644131978b3bb1
Authoritative remediation SHA: 4be12dc08677412f7c9fed5e8c644131978b3bb1
```

The existing PR branch is grandfathered by the remediation proposal. The prospective naming-policy change does not rename or replace it.

The two UI-focus commits are narrow test-harness corrections exposed during complete verification. They require the editor to become keyboard-focused before XCTest types Markdown; they do not change production behavior.

## Automated verification

Every final verification run started from a clean tree at the authoritative remediation SHA.

### Focused Mac tests

```bash
set -euo pipefail
REMEDIATION_SHA="4be12dc08677412f7c9fed5e8c644131978b3bb1"

test "$(git rev-parse HEAD)" = "$REMEDIATION_SHA"
test -z "$(git status --short)"

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  test \
  -only-testing:MyRAMMacTests/MacNoteViewZoomTests \
  -only-testing:MyRAMMacTests/MacMarkdownPreviewDocumentBuilderTests \
  -only-testing:MyRAMMacTests/MacMarkdownPreviewIntegrationTests
```

Result: **38 passed, 0 failed**.

The integration suite proves:

- retained Preview `NSScrollView`, `NSTextView`, and `NSTextStorage` identity through hierarchy reacquisition;
- an intentionally nonzero viewport with `recordedOrigin.y > 1.0`;
- unchanged viewport components within the approved `1.0`-point AppKit tolerance;
- unchanged rendered content, selected range, parser/build count, and storage-edit count;
- shared editor/Preview magnification at `1.0 → 1.1 → 1.2 → 1.1 → 1.0`;
- production `zoomedOut(from:)` coverage;
- zero zoom-only source, callback, parser, storage, save, or sync mutation;
- one latest-source build after multiple hidden edits;
- changed-source selection and viewport clamping.

### Complete Mac scheme

```bash
set -euo pipefail
REMEDIATION_SHA="4be12dc08677412f7c9fed5e8c644131978b3bb1"

test "$(git rev-parse HEAD)" = "$REMEDIATION_SHA"
test -z "$(git status --short)"

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  test
```

Result: **619 passed, 0 failed**.

### Complete iOS scheme

The final run used the erased and rebooted available iPhone 16 Pro simulator:

```text
Simulator UDID: 1C546BCF-C14F-42C8-A4F1-B53026F3183C
Destination: platform=iOS Simulator,id=1C546BCF-C14F-42C8-A4F1-B53026F3183C
```

```bash
set -euo pipefail
REMEDIATION_SHA="4be12dc08677412f7c9fed5e8c644131978b3bb1"
SIMULATOR_UDID="1C546BCF-C14F-42C8-A4F1-B53026F3183C"

test "$(git rev-parse HEAD)" = "$REMEDIATION_SHA"
test -z "$(git status --short)"

xcrun simctl erase "$SIMULATOR_UDID"
xcrun simctl boot "$SIMULATOR_UDID"
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -parallel-testing-enabled NO \
  test
```

Result:

```text
Application tests: 1,019 passed, 0 failed
UI and launch tests: 13 passed, 0 failed
Total: 1,032 passed, 0 failed
TEST SUCCEEDED
```

An earlier simulator run exposed an accessibility environment failure and two real XCTest keyboard-focus races. The simulator was erased, the two tests gained explicit keyboard-focus preconditions in separate commits, both affected tests passed directly, and the complete iOS scheme then passed from the clean authoritative remediation SHA. No superseded result is used as completion evidence.

### Builds and project checks

```bash
set -euo pipefail
REMEDIATION_SHA="4be12dc08677412f7c9fed5e8c644131978b3bb1"

test "$(git rev-parse HEAD)" = "$REMEDIATION_SHA"
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

plutil -lint MyRAM.xcodeproj/project.pbxproj
xcodebuild -project MyRAM.xcodeproj -list
```

Results:

```text
Generic iOS Simulator build: BUILD SUCCEEDED
Native Mac build: BUILD SUCCEEDED
project.pbxproj: OK
Project/scheme listing: succeeded
```

The builds emitted only the existing metadata-extraction notice that AppIntents metadata was skipped because the dependency is absent.

## Scope and whitespace audits

```bash
set -euo pipefail
BASE_SHA="4334f3f3ea718d5523ace296b84feb52df4c0d40"
IMPLEMENTATION_SHA="11346a8aa9ff6a582995609a355be0068392566e"
REMEDIATION_SHA="4be12dc08677412f7c9fed5e8c644131978b3bb1"

test "$(git rev-parse HEAD)" = "$REMEDIATION_SHA"
test -z "$(git status --short)"

git diff --check "$BASE_SHA"..."$REMEDIATION_SHA"

git diff "$BASE_SHA"..."$REMEDIATION_SHA" -- \
  Packages \
  MyRAM/MyRAMSchema.swift \
  MyRAM/Models \
  MyRAM/Sync \
  MyRAM/Markdown/MarkdownFileIO.swift \
  MyRAM/Mac/MacMarkdownFileCommands.swift \
  MyRAM/Mac/MacMarkdownExternalImportCoordinator.swift \
  MyRAM/Mac/MacMarkdownFileOperationCoordinator.swift \
  MyRAM/Views/NoteEditorFileOperationBridge.swift

git diff "$BASE_SHA"..."$REMEDIATION_SHA" -- \
  MyRAM/Markdown/MarkdownPreviewModePolicy.swift \
  MyRAM/Views/NoteEditorView.swift \
  MyRAMTests

git diff --unified=0 "$BASE_SHA"..."$REMEDIATION_SHA" -- \
  MyRAM/Markdown/MarkdownPreview.swift

git diff --name-status "$IMPLEMENTATION_SHA"..."$REMEDIATION_SHA"
```

Results:

- whitespace audit: no output;
- forbidden production scope: no output;
- shared/iPhone production non-change audit: no output;
- `MarkdownPreview.swift`: exactly one visibility change from `private struct MarkdownPreviewReminder` to `struct MarkdownPreviewReminder`;
- remediation range: `AGENTS.md`, `MyRAMMacTests/MacMarkdownPreviewIntegrationTests.swift`, and `MyRAMUITests/MarkdownPreviewUITests.swift`;
- `MyRAMUITests` contains only the previously approved reminder assertion and two keyboard-focus preconditions.

The working tree was clean before and after all automated verification and static audits.

## Manual Mac verification

Manual checks used an ad-hoc-signed disposable copy of the exact built app with `UITEST_MODE`. It used only its in-memory store and a distinct temporary bundle/executable identity. The normal MyRAM app, persisted notes, and repository files were not touched. The disposable app and screenshots were removed afterward.

### View menu and shortcuts

**Manual — passed**

- one existing View menu contained Zoom In, Zoom Out, and Actual Size;
- accessibility shortcut metadata reported `.`, `,`, and `0`, each with the Shift modifier in addition to Command;
- Shift-Command-. changed the scene zoom;
- Shift-Command-, changed it back;
- Shift-Command-0 restored Actual Size;
- Zoom In was disabled at 300%;
- Zoom Out was disabled at 50%;
- Actual Size was disabled at 100%;
- all three commands were disabled when no scene binding was available.

### Active scene, multiple windows, and scene lifetime

**Manual — passed**

- a new scene began at 100%;
- two separated windows retained independent 100% and 50% states;
- activating each scene routed the View commands only to that scene;
- switching active windows exposed the corresponding independent command state;
- changing a 100% scene enabled Actual Size without changing the 50% scene;
- after closing a changed scene, the no-scene command state was disabled and a newly opened scene began at 100% rather than restoring the closed scene's zoom.

### Edit/Preview continuity and non-mutation

**Manual — passed**

- a scene retained 300% through Preview → Edit → Preview;
- the persistent reminder remained outside the magnified document;
- zoom changes left the rendered 216-character document unchanged;
- no save, revision, persistence, or sync activity appeared while zooming; the isolated verification instance remained disconnected;
- automated hosted integration separately proved the exact zero binding-write, callback, save, sync, parser, and storage-edit counts.

### Preview document behavior

**Manual — passed**

- Command-A selected the complete 216-character representative document;
- Command-C copied heading, paragraph, ordered markers, the nested bullet, quote, and code as one document;
- the copied depth-2 marker began with exactly four U+0020 spaces before `•`;
- keyboard selection operated in the native Preview;
- a confined mouse drag in the large Preview produced a cross-document native selected range;
- typing into Preview left its text unchanged, confirming read-only behavior;
- Command-F presented the native find field;
- the link rendered with native link treatment; automated builder and integration tests proved the retained URL attribute without opening the user's browser.

### Nonzero viewport and retained document state

**Manual — passed**

Before an unchanged mode round trip:

```text
Rendered length: 216
Selected length: 216
Vertical scrollbar value: 0.697678703021
```

After Preview → Edit → Preview:

```text
Rendered length: 216
Selected length: 216
Vertical scrollbar value: 0.697678703021
Rendered text equal: true
Selected text equal: true
```

The automated integration test additionally reacquired and proved stable native scroll-view, text-view, and text-storage identity with a `1.0`-point viewport tolerance and no extra parser build or storage replacement.

### Large-document behavior

**Manual — passed**

```text
Source characters: 37,566
Representative sections: 250
Approximate projected blocks: 1,750
Native Preview selected range after Command-A: 1, 37,566
Scrollbar value after midpoint scroll: 0.515283677184
Mouse-drag selected range: 18,694, 18,731
```

- first Preview activation rendered the latest source as one native document;
- scrolling to the midpoint was responsive;
- Command-A and the confined long mouse drag remained responsive;
- Zoom In, Zoom Out, and Actual Size responded without rebuilding visible text;
- the large selected range and `0.515283677184` viewport survived an unchanged Edit/Preview round trip exactly;
- the initial long AX-value injection was excluded as a harness cost: the app completed the 37,566-character assignment, and direct native interaction was then responsive without full accessibility-tree enumeration.

### Editor default

**Manual and automated — passed**

- a disposable empty note typed at Actual Size with the visually verified larger default;
- zoom magnified the view without rewriting the source;
- the real hosted-editor tests proved an exact 24-point empty typing font, preservation of existing explicit font sizes, no binding mutation, and zero `onTextChanged` calls when existing content opens.

### iPhone non-regression

**Automated — passed**

- the complete iOS application and UI/launch suites passed;
- the shared parser and iPhone editor/Preview production files remained unchanged;
- no Mac zoom state or command was added to iPhone.

## Classification and remaining external state

```text
Automated: focused Mac, complete Mac, complete iOS, both builds, project checks,
           identity/cache/zoom/font proofs, scope audits, whitespace audit
Manual: View menu, shortcuts, boundaries, no-scene state, multiwindow routing,
        new-scene reset, mode continuity, selection, copy, find, read-only behavior,
        nonzero viewport, large-document interaction, visual font behavior
Not run: external URL navigation from the Preview link, to avoid mutating the user's
         active browser; native link rendering and URL attributes passed instead
Not applicable: pinch magnification, persistence migration, schema/package/sync work
GitHub-hosted checks: not claimed; final-head status is queried only after the
                       evidence commit is pushed
```

This document intentionally does not contain the SHA of the evidence-only commit that creates it. That SHA is recorded afterward in parity checks and the PR body.
