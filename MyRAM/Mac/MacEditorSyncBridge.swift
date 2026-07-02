#if os(macOS)
import AppKit

struct MacEditorRemoteBatchApplyResult: Equatable {
    let appliedCount: Int
    let requiresFallbackReload: Bool
}

@MainActor
final class MacEditorSyncBridge: ObservableObject {
    weak var textView: NSTextView?
    var publishAttributedText: ((NSAttributedString) -> Void)?
    private(set) var isApplyingRemoteSync = false

    func applyBatch(
        _ actions: [MacSelectedEditorAction],
        selectedNoteID: UUID
    ) -> MacEditorRemoteBatchApplyResult {
        guard let textView, let textStorage = textView.textStorage else {
            return MacEditorRemoteBatchApplyResult(appliedCount: 0, requiresFallbackReload: !actions.isEmpty)
        }

        var selection = textView.selectedRange()
        var appliedCount = 0
        var requiresFallbackReload = false
        let originalScrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin

        isApplyingRemoteSync = true
        textStorage.beginEditing()
        defer {
            textStorage.endEditing()
            textView.setSelectedRange(selection.macClamped(toLength: textStorage.length))
            if let originalScrollOrigin {
                textView.enclosingScrollView?.contentView.setBoundsOrigin(originalScrollOrigin)
            }
            if appliedCount > 0 {
                let undoManager = textView.delegate?.undoManager?(for: textView) ?? textView.undoManager
                undoManager?.removeAllActions()
                publishAttributedText?(NSAttributedString(attributedString: textView.attributedString()))
            }
            isApplyingRemoteSync = false
        }

        for action in actions {
            guard action.noteID == selectedNoteID else { continue }
            switch action {
            case .applyBodyInsertion(let insertion):
                guard insertion.utf16Offset >= 0, insertion.utf16Offset <= textStorage.length else {
                    requiresFallbackReload = true
                    return MacEditorRemoteBatchApplyResult(appliedCount: appliedCount, requiresFallbackReload: true)
                }

                let attributes = MacRemoteInsertionAttributePolicy.attributesForRemoteInsertion(
                    in: textStorage,
                    at: insertion.utf16Offset,
                    defaultAttributes: textView.typingAttributes
                )
                let attributedText = NSAttributedString(string: insertion.text, attributes: attributes)
                textStorage.replaceCharacters(in: NSRange(location: insertion.utf16Offset, length: 0), with: attributedText)
                selection = MacEditorSelectionMapper.selectionAfterInsertion(
                    current: selection,
                    insertionOffset: insertion.utf16Offset,
                    insertedUTF16Length: (insertion.text as NSString).length,
                    resultingTextLength: textStorage.length
                )
                appliedCount += 1

            case .applyBodyDeletion(let deletion):
                guard NSMaxRange(deletion.range) <= textStorage.length else {
                    requiresFallbackReload = true
                    return MacEditorRemoteBatchApplyResult(appliedCount: appliedCount, requiresFallbackReload: true)
                }

                let editorText = (textStorage.string as NSString).substring(with: deletion.range)
                guard editorText == deletion.deletedText else {
                    requiresFallbackReload = true
                    return MacEditorRemoteBatchApplyResult(appliedCount: appliedCount, requiresFallbackReload: true)
                }

                textStorage.replaceCharacters(in: deletion.range, with: "")
                selection = MacEditorSelectionMapper.selectionAfterDeletion(
                    current: selection,
                    deletedRange: deletion.range,
                    resultingTextLength: textStorage.length
                )
                appliedCount += 1
            }
        }

        return MacEditorRemoteBatchApplyResult(
            appliedCount: appliedCount,
            requiresFallbackReload: requiresFallbackReload
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
