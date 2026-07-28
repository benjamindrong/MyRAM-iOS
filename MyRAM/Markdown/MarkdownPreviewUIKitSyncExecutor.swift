#if os(iOS)
import UIKit

// MARK: - UIKit Sync Executor (§5 Sixth Remediation)
//
// Owns all sync decision and ordering logic that the private Coordinator.syncContent invokes.
// The production coordinator calls MarkdownPreviewUIKitSyncExecutor.synchronize; tests call
// the same function so they exercise the same branch selection, bookkeeping, and ordering.
//
// No test types are compiled into this file. MarkdownPreviewUIKitTestRecorder lives in MyRAMTests.

// MARK: - Publication Callback

/// Thin value type injected by the coordinator and replaced by a recording closure in tests.
@MainActor
struct MarkdownPreviewUIKitPublicationAdapter {
    let publish: (_ plainText: String, _ richTextUpdate: EditorRichTextContentUpdate) -> Void
}

// MARK: - Executor dependencies (injected by coordinator, replaced by recording closures in tests)

/// Stable side-effect and state access hooks injected by the coordinator or test harness.
@MainActor
struct MarkdownPreviewUIKitSyncDependencies {
    /// Reads the current bound plain text.
    var getBoundPlainText: () -> String
    /// Reads the current bound rich text data.
    var getBoundRichTextData: () -> Data?
    /// Publishes the finalized plain text and rich-text update to the editor binding.
    var publish: (_ plainText: String, _ richTextUpdate: EditorRichTextContentUpdate) -> Void
    /// Writes the new plain-text value into the coordinator's text binding.
    var setBoundPlainText: (_ plainText: String) -> Void
    /// Writes the new rich-text data value into the coordinator's richTextContentData binding.
    var setBoundRichTextData: (_ data: Data?) -> Void
    /// Clears `appliedPlainTextAwaitingBinding` and its paired data after bindings are confirmed synced.
    var clearAppliedContentIfSynced: () -> Void
    /// Records applied plain text and rich text data awaiting binding during UIView update cycles.
    var setAppliedContentAwaitingBinding: (_ plainText: String?, _ richTextData: Data?) -> Void
}

// MARK: - Executor

/// Extracted sync decision and ordering that was previously private inside Coordinator.syncContent.
/// The coordinator remains private; this struct is internal so the test target can call it directly.
@MainActor
enum MarkdownPreviewUIKitSyncExecutor {

    /// Decides and performs the correct sync action for a content-changed event.
    ///
    /// - Parameters:
    ///   - nativePlainText: The current `textView.text` plain-text value.
    ///   - encodedRichText: Synchronously-encoded RTF data when `serializesRichTextImmediately` is true; nil otherwise.
    ///   - richTextUpdate: The rich-text update token passed to the publication callback.
    ///   - serializesRichTextImmediately: Whether RTF is serialized synchronously (true) or lazily (false).
    ///   - isUpdatingUIView: Whether the text change occurred while SwiftUI is updating the UIView.
    ///   - dependencies: Side-effect hooks injected by the coordinator or test harness.
    ///   - completion: The caller-supplied completion closure. Always invoked exactly once.
    static func synchronize(
        nativePlainText: String,
        encodedRichText: Data?,
        richTextUpdate: EditorRichTextContentUpdate,
        serializesRichTextImmediately: Bool,
        isUpdatingUIView: Bool,
        dependencies: MarkdownPreviewUIKitSyncDependencies,
        completion: @escaping @MainActor () -> Void
    ) {
        let gate = EditorContentSyncCompletionGate(completion: completion)

        let currentBoundText = dependencies.getBoundPlainText()
        let currentBoundRichTextData = dependencies.getBoundRichTextData()

        // Path A: No content difference — nothing to publish.
        guard currentBoundText != nativePlainText
            || (serializesRichTextImmediately && currentBoundRichTextData != encodedRichText) else {
            dependencies.clearAppliedContentIfSynced()
            gate.complete()
            return
        }

        // Path B & C: Content changed.
        if isUpdatingUIView {
            // Path C: Deferred — inside a SwiftUI update cycle. Schedule publication after the
            // UIView update unwinds. The gate is captured strongly so it survives until the
            // deferred block executes.
            dependencies.setAppliedContentAwaitingBinding(nativePlainText, encodedRichText)

            RunLoop.main.perform { [gate] in
                // Path C recheck: another update may have synced the binding already.
                let recheckBoundText = dependencies.getBoundPlainText()
                let recheckBoundData = dependencies.getBoundRichTextData()
                guard recheckBoundText != nativePlainText
                    || recheckBoundData != encodedRichText else {
                    dependencies.clearAppliedContentIfSynced()
                    gate.complete()
                    return
                }
                // Path C publish: deferred publication succeeds.
                dependencies.setBoundPlainText(nativePlainText)
                dependencies.setBoundRichTextData(encodedRichText)
                dependencies.publish(nativePlainText, richTextUpdate)
                dependencies.clearAppliedContentIfSynced()
                gate.complete()
            }
            return
        }

        // Path B: Synchronous publication.
        dependencies.setBoundPlainText(nativePlainText)
        if serializesRichTextImmediately {
            dependencies.setBoundRichTextData(encodedRichText)
        }
        dependencies.publish(nativePlainText, richTextUpdate)
        dependencies.clearAppliedContentIfSynced()
        gate.complete()
    }
}
#endif
