# MYR-93 Catalyst Selection Profiling

Note: This document is historical. The current desktop strategy was superseded by the native macOS direction established in MYR-104+ and formalized by MYR-110. Mac Catalyst is no longer the active desktop support path.

## Goal

Use Instruments to identify the actual Mac Catalyst large-selection and auto-scroll hot path before making more optimization changes.

## Repro

1. Build and run MyRAM as Mac Catalyst in Debug.
2. Open or create a large note with enough body text to require sustained scrolling.
3. Drag-select a large body-text range.
4. Keep dragging past the editor edge so selection expansion triggers auto-scroll.
5. Capture the janky/high-CPU window in Instruments using the Time Profiler template.

## What Instruments And Time Profiler Are

Instruments is Apple's performance-recording app. It comes with Xcode.

Time Profiler is an Instruments recording template that samples the running app many times per second and shows where the CPU is spending time. For this ticket, Time Profiler is the main tool because the symptom is high CPU and UI jank.

Main Thread activity means the work happening on the app's UI thread. If the main thread is busy for too long, scrolling and selection feel laggy. Time Profiler can show main-thread call stacks after a recording.

## First-Time Setup

1. Open `MyRAM.xcodeproj` in Xcode.
2. In the top toolbar, choose the `MyRAM` scheme.
3. Choose `My Mac (Mac Catalyst)` or a `Mac Catalyst` destination.
4. Build once with `Product > Build`.
5. Run once with `Product > Run` and confirm the app opens.
6. Quit the app before starting the Instruments recording.

## Capture A Time Profiler Trace

1. In Xcode, choose `Product > Profile`.
2. Xcode will build the app and open Instruments.
3. When Instruments asks for a template, select `Time Profiler`.
4. Click `Choose`.
5. Instruments should show MyRAM as the target app. If it does not, use the target/process chooser near the top of the Instruments window and select MyRAM.
6. Click the red Record button in the top-left corner.
7. Wait for MyRAM to launch.
8. In MyRAM, open the large note.
9. Start drag-selecting a large amount of body text.
10. Keep dragging past the editor edge so the selection expands while the editor auto-scrolls.
11. Keep the jank happening for about 10-20 seconds.
12. Click the Stop button in Instruments.
13. Save the trace with `File > Save`.

Use a filename that says what was tested, for example:

```text
MYR-93-baseline-time-profiler.trace
```

## Find The Janky Window In The Trace

1. After stopping the recording, look at the timeline at the top of Instruments.
2. Drag-select the time range where you were actively selecting text and auto-scrolling.
3. In the lower pane, choose the call-tree view.
4. Turn on these options if they are available in the right-side inspector or call-tree controls:
   - `Separate by Thread`
   - `Invert Call Tree`
   - `Hide System Libraries` off for the first pass, then on for a second pass
5. Find the `Main Thread` section.
6. Expand the highest-percentage rows under `Main Thread`.
7. Record the top stack names and percentages.

If the top rows are mostly app symbols like `NoteEditorView`, `ChecklistItemEditor`, `RichTextContentCodec`, `syncContent`, or `drawSearchHighlight`, the hot path is likely app code.

If the top rows are mostly Apple framework symbols like `UITextView`, `NSTextView`, `NSLayoutManager`, `NSTextLayoutManager`, `TextKit`, `UIKitCore`, `AppKit`, or Core Animation functions, the hot path may be system selection/autoscroll behavior on Catalyst.

## Capture Main-Thread Evidence

Time Profiler already contains main-thread call stacks. For this ticket, "capture Main Thread activity" means:

1. Select the janky time range in the timeline.
2. Open the call tree.
3. Expand `Main Thread`.
4. Screenshot the top expanded call stacks, or write down the top 5-10 rows with percentages.
5. Note whether the stack is mostly MyRAM code or mostly Apple framework code.

Useful screenshots:

- Timeline with the janky range selected.
- Call tree with `Main Thread` expanded.
- A second call tree with `Hide System Libraries` enabled, if it changes what appears at the top.

## Add Isolation Flags In Xcode

Use these steps to run one isolation scenario:

1. In Xcode, choose `Product > Scheme > Edit Scheme...`.
2. Select `Run` in the left sidebar.
3. Select the `Arguments` tab.
4. Under `Arguments Passed On Launch`, click `+`.
5. Add one flag, for example:

```text
MYR_PROFILE_DISABLE_FORMATTING_UPDATES
```

6. Make sure the checkbox next to the flag is enabled.
7. Close the scheme editor.
8. Run `Product > Profile` again and capture another Time Profiler trace.
9. After the run, go back to the scheme editor and disable or remove that flag before testing the next scenario.

The same flags can also be set as environment variables with value `1`, but launch arguments are simpler from Xcode.

## Isolation Flags

These launch arguments can be enabled one at a time, or combined, to isolate app-layer costs while profiling the Debug build:

- `MYR_PROFILE_DISABLE_FORMATTING_UPDATES`
- `MYR_PROFILE_DISABLE_SEARCH_HIGHLIGHTS`
- `MYR_PROFILE_DISABLE_CHECKLIST_RENDERING`
- `MYR_PROFILE_DISABLE_CUSTOM_GESTURES`
- `MYR_PROFILE_BARE_TEXTVIEW`

The same names can also be set as environment variables with value `1`.

`MYR_PROFILE_BARE_TEXTVIEW` replaces the normal app shell with a single large attributed `UITextView`. Use it as a system-control run: it keeps Catalyst `UITextView` selection and auto-scroll behavior, but removes MyRAM editor coordination, formatting-state reporting, search highlights, checklist rendering, custom gestures, and persistence callbacks.

## App Signposts

The profiling build emits signposts under the system `PointsOfInterest` logging category. Add the `Points of Interest` instrument beside Time Profiler, or inspect signpost intervals from the Time Profiler recording, to correlate app-owned work with the janky selection window.

Relevant signposts:

- `SelectableTextView.updateUIView`
- `Coordinator.textViewDidChange`
- `Coordinator.textViewDidChangeSelection`
- `Coordinator.scrollViewWillBeginDragging`
- `Coordinator.scrollViewDidScroll`
- `Coordinator.applySearchHighlight`
- `Coordinator.drawSearchHighlight`
- `Coordinator.positionSearchHighlightLayers`
- `Coordinator.syncContent`
- `Coordinator.deferredRichTextContentEncoder`
- `Coordinator.storageAttributedText`
- `Coordinator.formattingState`
- `Coordinator.normalizeTypingAttributes`
- `Coordinator.reportFormattingState`
- `Coordinator.applyChecklistRendering`
- `Coordinator.updateEditorLayout`
- `BareProfilingTextView.makeUIView`
- `BareProfilingTextView.updateUIView`

## Profiling Matrix

Capture the baseline first, then repeat the same repro with each isolation:

1. Baseline, no flags.
2. Formatting updates disabled.
3. Search highlights disabled.
4. Checklist rendering disabled.
5. Custom gestures disabled.
6. All isolation flags enabled.
7. Bare Catalyst `UITextView` harness with `MYR_PROFILE_BARE_TEXTVIEW`.

Suggested trace filenames:

- `MYR-93-baseline-time-profiler.trace`
- `MYR-93-no-formatting-updates.trace`
- `MYR-93-no-search-highlights.trace`
- `MYR-93-no-checklist-rendering.trace`
- `MYR-93-no-custom-gestures.trace`
- `MYR-93-all-isolation-flags.trace`
- `MYR-93-bare-textview.trace`

## What To Record

For each run, record:

- Whether selection drag and auto-scroll visibly improve.
- Top Time Profiler symbols.
- Main-thread call stacks during the janky interval.
- Whether hot time is in app code, SwiftUI, UIKit/TextKit, Core Animation, or gesture/autoscroll machinery.

Use this note format for each run:

```text
Run:
Flags:
Trace file:
Visible behavior:
Top main-thread symbols:
Top app symbols with Hide System Libraries enabled:
Signpost intervals active during hotspot:
Likely category:
Notes:
```

## Findings

Analyzed trace:

- Trace file: `docs/MYR-93-baseline-time-profiler.trace`
- Run inspected: `run6`
- Launch arguments present in trace metadata:
  - `MYR_PROFILE_BARE_TEXTVIEW`
  - `MYR_PROFILE_DISABLE_FORMATTING_UPDATES`
  - `MYR_PROFILE_DISABLE_SEARCH_HIGHLIGHTS`
  - `MYR_PROFILE_DISABLE_CHECKLIST_RENDERING`
  - `MYR_PROFILE_DISABLE_CUSTOM_GESTURES`
- App symbols present: `BareProfilingTextView.makeUIView`, `BareProfilingTextView.largeAttributedBody`
- System text symbols present in symbol archives: `UITextView`, `NSTextView`, `NSTextLayoutManager`, `NSTextSelectionNavigation`, `NSTextLayoutFragment`, AppKit text/selection/layout machinery

Signpost caveat:

- The trace contains `os-signpost`, ROI, and Points of Interest stores.
- The app signpost names were not present in the signpost stores or run uniquing data.
- `xcrun xctrace export --toc` crashed with exit 139 for this trace, so exact signpost interval percentages could not be exported.

Root-cause hypothesis:

Large-selection auto-scroll jank reproduces in a stripped Catalyst `UITextView` with MyRAM editor layers disabled. That points to Catalyst `UITextView` / TextKit / AppKit selection-autoscroll/layout machinery rather than app-owned editor work.

Isolation results:

- Formatting updates disabled: included in run6.
- Search highlights disabled: included in run6.
- Checklist rendering disabled: included in run6.
- Custom gestures disabled: included in run6.
- All isolation flags enabled: included in run6.
- Bare Catalyst `UITextView` harness: included in run6; this is the strongest isolation evidence because it bypasses MyRAM editor coordination, formatting-state reporting, search highlights, checklist rendering, custom gestures, persistence, and sync callbacks.

Follow-up tickets:

- `MYR-94 Reduce Catalyst large-selection auto-scroll jank`
  - Investigate product and interaction alternatives for Mac Catalyst large selection instead of more callback micro-optimizations.
  - Candidate scopes:
    - Add a Catalyst-specific large-selection mode that suppresses nonessential editor chrome refresh until drag ends.
    - Evaluate a non-`UITextView` selection interaction for long notes, such as keyboard-assisted range selection, paragraph/block selection, or a temporary plain-text selection mode.
    - Test whether TextKit configuration changes, attributed-body simplification, or viewport chunking reduce system selection/autoscroll cost.
    - Capture one comparison trace in the bare harness and one in the full editor after any selected approach.
  - Acceptance criteria:
    - Chosen approach is backed by profiling or focused prototype evidence.
    - Large-selection auto-scroll on Mac Catalyst shows visibly reduced jank on a large note.
    - Follow-up trace documents whether remaining time is still in system text selection/layout.

## Follow-Up Rule

Do not make additional performance fixes from this branch unless profiling points to a specific hot path. If the hotspot is app code, scope a targeted fix. If it is mainly UIKit/TextKit selection/autoscroll on Catalyst, scope a product-level interaction change instead of another callback micro-optimization.
