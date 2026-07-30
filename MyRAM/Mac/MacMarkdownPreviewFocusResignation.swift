#if os(macOS)
import AppKit

// MARK: - AppKit Focus Resignation Seam (§6 Sixth Remediation)
//
// Production-named seam that MacTextViewRepresentable.updateNSView calls when a
// resignFocusToggleToken increment is detected. Tests exercise this same enum
// directly with real NSWindow and NSTextView instances.
//
// No test types are compiled into this file. MacMarkdownPreviewTestRecorder lives in MyRAMMacTests.

@MainActor
enum MacMarkdownPreviewFocusResignation {
    /// Resigns first-responder status from `textView` only if `window.firstResponder === textView`.
    /// Must not trigger scheduleSave, flushPendingSave, onTextChanged, buffer replacement,
    /// revision replacement, or sync publication.
    static func resignIfOwned(window: NSWindow?, textView: NSTextView) {
        guard window?.firstResponder === textView else { return }
        window?.makeFirstResponder(nil)
    }
}
#endif
