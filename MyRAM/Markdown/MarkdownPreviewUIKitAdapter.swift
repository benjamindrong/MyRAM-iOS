#if os(iOS)
import UIKit

@MainActor
struct MarkdownPreviewUIKitPublicationAdapter {
    let publish: (_ plainText: String, _ richTextUpdate: EditorRichTextContentUpdate) -> Void
}

@MainActor
final class MarkdownPreviewUIKitTestRecorder {
    private(set) var events: [String] = []
    private(set) var publishedPlainText: String?
    private(set) var saveCount: Int = 0
    private(set) var flushCount: Int = 0

    func recordPublish(plainText: String) {
        events.append("publish")
        publishedPlainText = plainText
    }

    func recordComplete() {
        events.append("complete")
    }

    func recordAcknowledge() {
        events.append("acknowledge")
    }

    func recordSave() {
        saveCount += 1
    }

    func recordFlush() {
        flushCount += 1
    }
}
#endif
