#if os(iOS)
import Foundation

/// Shared production scheduler for UIKit work that must run after updateUIView unwinds.
@MainActor
enum MarkdownPreviewUIKitDeferredScheduler {
    static func enqueue(_ operation: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            operation()
        }
    }
}
#endif
