#if os(iOS)
import UIKit

/// Performs the native focus resignation used by the Preview transition.
@MainActor
enum MarkdownPreviewUIKitEditorResignation {
    static func resignIfOwned(_ textView: UITextView) {
        guard textView.isFirstResponder else { return }
        textView.resignFirstResponder()
    }
}
#endif
