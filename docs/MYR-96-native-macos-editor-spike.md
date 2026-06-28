# MYR-96 Native macOS Editor Spike

This spike adds a contained native macOS/AppKit editor prototype at `Spikes/MacEditorSpike`.

Run the spike from that directory:

```sh
swift run MyRAMMacEditorSpike
```

Run the spike tests:

```sh
swift test
```

The spike intentionally lives outside the shipping MyRAM app target. It provides a native `NSTextView` data point for large attributed-note drag selection and edge auto-scroll behavior without porting persistence, sync, search, note/folder models, intelligence, attachments, or product UI.

Manual evaluation details and decision output guidance live in `Spikes/MacEditorSpike/Docs/Spikes/MYR-96-native-macos-editor-spike.md`.
