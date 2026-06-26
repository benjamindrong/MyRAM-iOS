import UIKit

enum EditorTypography {
    #if targetEnvironment(macCatalyst)
    static let defaultTextFont = UIFont.systemFont(ofSize: 20)
    #else
    static let defaultTextFont = UIFont.preferredFont(forTextStyle: .body)
    #endif
}

enum EditorTextViewFactory {
    static func makeTextView() -> UITextView {
        #if targetEnvironment(macCatalyst)
        if EditorSelectionProfiling.forcesTextKit1 {
            return UITextView(usingTextLayoutManager: false)
        }
        #endif
        return UITextView()
    }

    static func makeEditorTextView(
        backgroundColor: UIColor,
        textColor: UIColor,
        tintColor: UIColor?
    ) -> UITextView {
        let textView = makeTextView()
        textView.font = EditorTypography.defaultTextFont
        textView.textColor = textColor
        textView.adjustsFontForContentSizeCategory = true
        textView.allowsEditingTextAttributes = true
        textView.backgroundColor = backgroundColor
        textView.tintColor = tintColor
        textView.layer.cornerRadius = 8
        textView.typingAttributes = [
            .font: textView.font ?? EditorTypography.defaultTextFont,
            .foregroundColor: textColor,
            .paragraphStyle: ChecklistItemEditor.editorParagraphStyle
        ]
        textView.textContainerInset = ChecklistItemEditor.textContainerInsets(hasChecklistItems: false)
        textView.keyboardDismissMode = .interactive
#if targetEnvironment(macCatalyst)
        textView.alwaysBounceVertical = false
#else
        textView.alwaysBounceVertical = true
#endif
        return textView
    }

    static func makeBareProfilingTextView(attributedText: NSAttributedString) -> UITextView {
        let textView = makeTextView()
        textView.attributedText = attributedText
        textView.font = EditorTypography.defaultTextFont
        textView.textColor = .label
        textView.backgroundColor = .systemBackground
        textView.allowsEditingTextAttributes = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.alwaysBounceVertical = false
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 18, bottom: 24, right: 18)
        textView.typingAttributes = [
            .font: EditorTypography.defaultTextFont,
            .foregroundColor: UIColor.label
        ]
        return textView
    }
}
