#if os(macOS)
import AppKit

@MainActor
final class MacEditorSyncBridge: ObservableObject {
    weak var textView: NSTextView?
    var publishAttributedText: ((NSAttributedString) -> Void)?
#if DEBUG
    var fullDocumentMetrics: EditorRemoteFullDocumentMetrics?
#endif
    private(set) var isApplyingRemoteSync = false

    func applyBatch(
        _ actions: [MacSelectedEditorAction],
        selectedNoteID: UUID,
        authoritativeBody: String
    ) -> EditorRemoteBatchApplyResult {
        guard let textView, let textStorage = textView.textStorage else {
            return EditorRemoteBatchApplyResult(
                appliedCount: 0,
                disposition: actions.isEmpty ? .noApplicableMutations : .requiresReload(.editorUnavailable)
            )
        }

        var selection = textView.selectedRange()
        var appliedCount = 0
        let originalScrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin

        isApplyingRemoteSync = true
        textStorage.beginEditing()
        defer {
            textStorage.endEditing()
            textView.setSelectedRange(selection.editorClamped(toLength: textStorage.length))
            if let originalScrollOrigin {
                textView.enclosingScrollView?.contentView.setBoundsOrigin(originalScrollOrigin)
            }
            if appliedCount > 0 {
                let undoManager = textView.delegate?.undoManager?(for: textView) ?? textView.undoManager
                undoManager?.removeAllActions()
#if DEBUG
                fullDocumentMetrics?.recordAttributedStringCopy()
#endif
                publishAttributedText?(NSAttributedString(attributedString: textView.attributedString()))
            }
            isApplyingRemoteSync = false
        }

        for action in actions {
            guard action.noteID == selectedNoteID else { continue }
            switch action {
            case .applyBodyInsertion(let insertion):
                guard insertion.utf16Offset >= 0, insertion.utf16Offset <= textStorage.length else {
                    return EditorRemoteBatchApplyResult(
                        appliedCount: appliedCount,
                        disposition: appliedCount > 0 ? .requiresReload(.partialBatchApplication) : .requiresReload(.invalidInsertionOffset)
                    )
                }

                let attributes = MacRemoteInsertionAttributePolicy.attributesForRemoteInsertion(
                    in: textStorage,
                    at: insertion.utf16Offset,
                    defaultAttributes: textView.typingAttributes
                )
                let attributedText = NSAttributedString(string: insertion.text, attributes: attributes)
                textStorage.replaceCharacters(in: NSRange(location: insertion.utf16Offset, length: 0), with: attributedText)
                selection = EditorSelectionMapper.selectionAfterInsertion(
                    current: selection,
                    insertionOffset: insertion.utf16Offset,
                    insertedUTF16Length: (insertion.text as NSString).length,
                    resultingTextLength: textStorage.length
                )
                appliedCount += 1

            case .applyBodyDeletion(let deletion):
                guard NSMaxRange(deletion.range) <= textStorage.length else {
                    return EditorRemoteBatchApplyResult(
                        appliedCount: appliedCount,
                        disposition: appliedCount > 0 ? .requiresReload(.partialBatchApplication) : .requiresReload(.invalidDeletionRange)
                    )
                }

                let editorText = (textStorage.string as NSString).substring(with: deletion.range)
                guard editorText == deletion.deletedText else {
                    return EditorRemoteBatchApplyResult(
                        appliedCount: appliedCount,
                        disposition: appliedCount > 0 ? .requiresReload(.partialBatchApplication) : .requiresReload(.deletedTextMismatch)
                    )
                }

                textStorage.replaceCharacters(in: deletion.range, with: "")
                selection = EditorSelectionMapper.selectionAfterDeletion(
                    current: selection,
                    deletedRange: deletion.range,
                    resultingTextLength: textStorage.length
                )
                appliedCount += 1
            }
        }

        if appliedCount > 0 {
#if DEBUG
            fullDocumentMetrics?.recordAuthoritativeBodyComparison()
#endif
        }
        guard appliedCount == 0 || textStorage.string == authoritativeBody else {
            return EditorRemoteBatchApplyResult(
                appliedCount: appliedCount,
                disposition: .requiresReload(.postApplyBodyMismatch)
            )
        }

        return EditorRemoteBatchApplyResult(
            appliedCount: appliedCount,
            disposition: appliedCount > 0 ? .applied : .noApplicableMutations
        )
    }
}

private extension MacSelectedEditorAction {
    var noteID: UUID {
        switch self {
        case .applyBodyInsertion(let insertion):
            insertion.noteID
        case .applyBodyDeletion(let deletion):
            deletion.noteID
        }
    }
}

#endif
