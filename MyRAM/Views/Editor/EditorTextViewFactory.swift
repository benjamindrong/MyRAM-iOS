import UIKit

enum EditorTypography {
    static let defaultTextFont: UIFont = {
        // Legacy Catalyst keeps a fixed desktop-sized editor font; native macOS will define its own AppKit typography.
        if MyRAMPlatform.isMacCatalyst {
            return UIFont.systemFont(ofSize: 20)
        }
        return UIFont.preferredFont(forTextStyle: .body)
    }()
}

enum EditorTextViewFactory {
    static func makeTextView() -> UITextView {
        // Transitional Catalyst profiling can force TextKit 1 without becoming the future native Mac editor path.
        if MyRAMPlatform.isMacCatalyst,
           EditorSelectionProfiling.forcesTextKit1 {
            return UITextView(usingTextLayoutManager: false)
        }
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
        // Catalyst keeps its legacy desktop scroll feel; real iPhone/iPad keeps the existing mobile bounce.
        textView.alwaysBounceVertical = MyRAMPlatform.isRealIOSOrIPadOS
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
