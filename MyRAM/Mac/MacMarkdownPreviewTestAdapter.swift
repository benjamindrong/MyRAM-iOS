#if os(macOS)
import AppKit

@MainActor
struct MacMarkdownPreviewTestAdapter {
    let resignFirstResponderIfOwned: (_ window: NSWindow?, _ textView: NSTextView) -> Void
    let currentFirstResponder: (_ window: NSWindow?) -> NSResponder?
}

@MainActor
final class MacMarkdownPreviewTestRecorder {
    private(set) var onTextChangedCount = 0
    private(set) var saveScheduledCount = 0

    func recordTextChanged() {
        onTextChangedCount += 1
    }

    func recordSaveScheduled() {
        saveScheduledCount += 1
    }
}
#endif
