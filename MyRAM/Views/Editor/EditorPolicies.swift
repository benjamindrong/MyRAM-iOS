import Foundation

enum EditorSelectionFormattingPolicy {
    static let largeSelectionFormattingThreshold = 2_000

    static func shouldDeferFullFormattingScan(selectionLength: Int) -> Bool {
        selectionLength > largeSelectionFormattingThreshold
    }
}

struct DeferredRichTextContentEncoder {
    let encode: () -> Data?
}

enum EditorRichTextContentUpdate {
    case immediate(Data?)
    case deferred(DeferredRichTextContentEncoder)
}

enum EditorRichTextCommitPolicy {
    static func committedRichTextContentData(
        currentData: Data?,
        pendingEncoder: DeferredRichTextContentEncoder?
    ) -> Data? {
        pendingEncoder?.encode() ?? currentData
    }
}
