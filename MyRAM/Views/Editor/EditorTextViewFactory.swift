import UIKit

#if targetEnvironment(macCatalyst)
let defaultEditorTextFont = UIFont.systemFont(ofSize: 20)
#else
let defaultEditorTextFont = UIFont.preferredFont(forTextStyle: .body)
#endif

enum EditorTextViewFactory {
    static func makeTextView() -> UITextView {
        EditorSelectionProfiling.forcesTextKit1 ? UITextView(usingTextLayoutManager: false) : UITextView()
    }

    static func makeEditorTextView(
        backgroundColor: UIColor,
        textColor: UIColor,
        tintColor: UIColor?
    ) -> UITextView {
        let textView = makeTextView()
        textView.font = defaultEditorTextFont
        textView.textColor = textColor
        textView.adjustsFontForContentSizeCategory = true
        textView.allowsEditingTextAttributes = true
        textView.backgroundColor = backgroundColor
        textView.tintColor = tintColor
        textView.layer.cornerRadius = 8
        textView.typingAttributes = [
            .font: textView.font ?? defaultEditorTextFont,
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
        textView.font = defaultEditorTextFont
        textView.textColor = .label
        textView.backgroundColor = .systemBackground
        textView.allowsEditingTextAttributes = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.alwaysBounceVertical = false
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 18, bottom: 24, right: 18)
        textView.typingAttributes = [
            .font: defaultEditorTextFont,
            .foregroundColor: UIColor.label
        ]
        return textView
    }
}
