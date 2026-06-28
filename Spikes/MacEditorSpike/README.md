# MyRAMMacEditorSpike

Native macOS/AppKit editor spike for MYR-96.

Run the spike:

```sh
swift run MyRAMMacEditorSpike
```

Run as a foreground macOS app bundle:

```sh
Scripts/run-app-bundle.sh
```

Run tests:

```sh
swift test
```

The app opens a minimal `NSTextView` loaded with a generated large attributed note so native macOS selection and edge auto-scroll behavior can be compared with the MyRAM Catalyst editor results from MYR-95.
