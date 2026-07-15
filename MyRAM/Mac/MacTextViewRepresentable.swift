#if os(macOS)
import AppKit
import SwiftUI

struct MacTextViewRepresentable: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @ObservedObject var syncBridge: MacEditorSyncBridge
    var onTextChanged: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(attributedText: $attributedText, syncBridge: syncBridge, onTextChanged: onTextChanged)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = AppearanceAwareTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.effectiveAppearanceDidChange = { [weak coordinator = context.coordinator] in
            coordinator?.refreshDisplayText()
        }
        let displayText = MacEditorTextColorPolicy.normalizedForDisplay(attributedText)
        textView.textStorage?.setAttributedString(displayText)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.typingAttributes = MacEditorTextColorPolicy.normalizedTypingAttributes(textView.typingAttributes)
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        // Width tracking keeps AppKit wrapping behavior stable as the SwiftUI window resizes.
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.register(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.attributedText = $attributedText
        context.coordinator.syncBridge = syncBridge
        context.coordinator.onTextChanged = onTextChanged

        guard let textView = context.coordinator.textView ?? scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.textView = textView
        context.coordinator.register(textView)
        textView.textStorage?.delegate = context.coordinator
        let displayText = MacEditorTextColorPolicy.normalizedForDisplay(attributedText)
        let currentText = textView.attributedString()
        if !currentText.isEqual(to: displayText) {
            let selectedRange = textView.selectedRange()
            context.coordinator.isApplyingSwiftUIUpdate = true
            textView.textStorage?.setAttributedString(displayText)
            textView.typingAttributes = MacEditorTextColorPolicy.normalizedTypingAttributes(textView.typingAttributes)
            textView.setSelectedRange(selectedRange.macClamped(toLength: displayText.length))
            context.coordinator.isApplyingSwiftUIUpdate = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor NSTextStorageDelegate, NSTextViewDelegate {
        var attributedText: Binding<NSAttributedString>
        var syncBridge: MacEditorSyncBridge
        var onTextChanged: () -> Void
        weak var textView: NSTextView?
        var isApplyingSwiftUIUpdate = false

        init(
            attributedText: Binding<NSAttributedString>,
            syncBridge: MacEditorSyncBridge,
            onTextChanged: @escaping () -> Void
        ) {
            self.attributedText = attributedText
            self.syncBridge = syncBridge
            self.onTextChanged = onTextChanged
        }

        func register(_ textView: NSTextView) {
            syncBridge.textView = textView
            syncBridge.publishAttributedText = { [weak self] attributedText in
                self?.attributedText.wrappedValue = attributedText
            }
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard !isApplyingSwiftUIUpdate, !syncBridge.isApplyingRemoteSync else { return }
            guard editedMask.contains(.editedAttributes) || editedMask.contains(.editedCharacters) else {
                return
            }
            guard let textView else { return }

            publishCurrentText(from: textView)
        }

        private func publishCurrentText(from textView: NSTextView) {
            attributedText.wrappedValue = NSAttributedString(attributedString: textView.attributedString())
            onTextChanged()
        }

        func refreshDisplayText() {
            guard let textView else { return }

            let displayText = MacEditorTextColorPolicy.normalizedForDisplay(attributedText.wrappedValue)
            let selectedRange = textView.selectedRange()
            isApplyingSwiftUIUpdate = true
            textView.textStorage?.setAttributedString(displayText)
            textView.typingAttributes = MacEditorTextColorPolicy.normalizedTypingAttributes(textView.typingAttributes)
            textView.setSelectedRange(selectedRange.macClamped(toLength: displayText.length))
            isApplyingSwiftUIUpdate = false
        }
    }
}

private final class AppearanceAwareTextView: NSTextView {
    var effectiveAppearanceDidChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearanceDidChange?()
    }
}
#endif
