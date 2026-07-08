import UIKit

@MainActor
final class UIKitEditorSyncBridge: ObservableObject {
    weak var textView: UITextView?
    var publishAttributedText: ((NSAttributedString) -> Void)?
    var onMarkedTextEnded: (() -> Void)?

    private(set) var isApplyingRemoteSync = false
    private var previouslyHadMarkedText = false

    var hasMarkedText: Bool {
        textView?.markedTextRange != nil
    }

    func observeMarkedTextState(_ hasMarkedText: Bool) {
        defer { previouslyHadMarkedText = hasMarkedText }
        guard previouslyHadMarkedText, !hasMarkedText else { return }
        onMarkedTextEnded?()
    }

    func apply(
        _ batch: AppliedEditorMutationBatch,
        selectedNoteID: UUID
    ) -> EditorRemoteBatchApplyResult {
        guard batch.noteID == selectedNoteID else {
            return EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations)
        }

        guard let textView else {
            return EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .requiresReload(.editorUnavailable))
        }

        guard textView.text == batch.authoritativeBody || !batch.mutations.isEmpty else {
            return EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .requiresReload(.preApplyBodyMismatch))
        }

        var selection = textView.selectedRange
        let originalOffset = textView.contentOffset
        let originalTypingAttributes = textView.typingAttributes
        let wasFirstResponder = textView.isFirstResponder
        var appliedCount = 0

        isApplyingRemoteSync = true
        textView.textStorage.beginEditing()
        defer {
            textView.textStorage.endEditing()
            textView.selectedRange = selection.editorClamped(toLength: textView.textStorage.length)
            textView.setContentOffset(clampedContentOffset(originalOffset, in: textView), animated: false)
            textView.typingAttributes = originalTypingAttributes
            if wasFirstResponder, !textView.isFirstResponder {
                textView.becomeFirstResponder()
            }
            if appliedCount > 0 {
                textView.undoManager?.removeAllActions()
                publishAttributedText?(NSAttributedString(attributedString: textView.attributedText))
            }
            isApplyingRemoteSync = false
        }

        for mutation in batch.mutations {
            switch mutation {
            case .bodyInsertion(let insertion):
                guard insertion.noteID == selectedNoteID else { continue }
                guard insertion.utf16Offset >= 0, insertion.utf16Offset <= textView.textStorage.length else {
                    return EditorRemoteBatchApplyResult(
                        appliedCount: appliedCount,
                        disposition: appliedCount > 0 ? .requiresReload(.partialBatchApplication) : .requiresReload(.invalidInsertionOffset)
                    )
                }

                let attributes = UIKitRemoteInsertionAttributePolicy.attributesForRemoteInsertion(
                    in: textView.textStorage,
                    at: insertion.utf16Offset,
                    typingAttributes: textView.typingAttributes,
                    defaultAttributes: defaultBodyAttributes(for: textView)
                )
                let attributedText = NSAttributedString(string: insertion.text, attributes: attributes)
                textView.textStorage.replaceCharacters(in: NSRange(location: insertion.utf16Offset, length: 0), with: attributedText)
                selection = EditorSelectionMapper.selectionAfterInsertion(
                    current: selection,
                    insertionOffset: insertion.utf16Offset,
                    insertedUTF16Length: (insertion.text as NSString).length,
                    resultingTextLength: textView.textStorage.length
                )
                appliedCount += 1

            case .bodyDeletion(let deletion):
                guard deletion.noteID == selectedNoteID else { continue }
                guard deletion.range.location >= 0,
                      deletion.range.length >= 0,
                      NSMaxRange(deletion.range) <= textView.textStorage.length else {
                    return EditorRemoteBatchApplyResult(
                        appliedCount: appliedCount,
                        disposition: appliedCount > 0 ? .requiresReload(.partialBatchApplication) : .requiresReload(.invalidDeletionRange)
                    )
                }

                let editorText = (textView.textStorage.string as NSString).substring(with: deletion.range)
                guard editorText == deletion.deletedText else {
                    return EditorRemoteBatchApplyResult(
                        appliedCount: appliedCount,
                        disposition: appliedCount > 0 ? .requiresReload(.partialBatchApplication) : .requiresReload(.deletedTextMismatch)
                    )
                }

                textView.textStorage.replaceCharacters(in: deletion.range, with: "")
                selection = EditorSelectionMapper.selectionAfterDeletion(
                    current: selection,
                    deletedRange: deletion.range,
                    resultingTextLength: textView.textStorage.length
                )
                appliedCount += 1
            }
        }

        guard appliedCount > 0 else {
            return EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations)
        }

        guard textView.text == batch.authoritativeBody else {
            return EditorRemoteBatchApplyResult(
                appliedCount: appliedCount,
                disposition: .requiresReload(.postApplyBodyMismatch)
            )
        }

        return EditorRemoteBatchApplyResult(appliedCount: appliedCount, disposition: .applied)
    }

    private func defaultBodyAttributes(for textView: UITextView) -> [NSAttributedString.Key: Any] {
        [
            .font: textView.font ?? EditorTypography.defaultTextFont,
            .foregroundColor: textView.textColor ?? UIColor.label,
            .paragraphStyle: ChecklistItemEditor.editorParagraphStyle
        ]
    }

    private func clampedContentOffset(_ offset: CGPoint, in textView: UITextView) -> CGPoint {
        let maxX = max(textView.contentSize.width + textView.adjustedContentInset.right - textView.bounds.width, -textView.adjustedContentInset.left)
        let maxY = max(textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height, -textView.adjustedContentInset.top)
        return CGPoint(
            x: min(max(offset.x, -textView.adjustedContentInset.left), maxX),
            y: min(max(offset.y, -textView.adjustedContentInset.top), maxY)
        )
    }
}

enum UIKitRemoteInsertionAttributePolicy {
    static func attributesForRemoteInsertion(
        in attributedString: NSAttributedString,
        at offset: Int,
        typingAttributes: [NSAttributedString.Key: Any],
        defaultAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        guard attributedString.length > 0 else {
            return filteredEditorBodyAttributes(typingAttributes.isEmpty ? defaultAttributes : typingAttributes)
        }

        if offset > 0 {
            return filteredEditorBodyAttributes(
                attributedString.attributes(at: min(offset - 1, attributedString.length - 1), effectiveRange: nil)
            )
        }

        return filteredEditorBodyAttributes(attributedString.attributes(at: 0, effectiveRange: nil))
    }

    private static func filteredEditorBodyAttributes(
        _ attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        attributes
    }
}
