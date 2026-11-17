#if os(macOS)
import AppKit
import SwiftUI

struct MacTextViewRepresentable: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @ObservedObject var syncBridge: MacEditorSyncBridge
    @ObservedObject var formattingController: MacFormattingController
    let noteID: UUID?
    let editorEnabled: Bool
    var onTextChanged: () -> Void = {}
    /// MYR-195 Slice 2: resign-only seam. Token increment causes the representable to call
    /// makeFirstResponder(nil) only if the text view is currently first responder.
    /// Must not trigger scheduleSave, flushPendingSave, onTextChanged, buffer replacement,
    /// revision replacement, or sync publication.
    var resignFocusToggleToken: Int = 0
    let zoom: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(attributedText: $attributedText, syncBridge: syncBridge, formattingController: formattingController, onTextChanged: onTextChanged)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MacNoteReflowingScrollView()
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
        textView.font = .systemFont(ofSize: 24)
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
        // Reflow zoom owns document width. AppKit width autoresizing would undo it.
        textView.autoresizingMask = []

        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        MacNoteViewZoom.apply(zoom, to: scrollView)
        context.coordinator.textView = textView
        context.coordinator.register(textView)
        formattingController.bind(textView: textView, noteID: noteID, enabled: editorEnabled)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.attributedText = $attributedText
        context.coordinator.syncBridge = syncBridge
        context.coordinator.formattingController = formattingController
        context.coordinator.onTextChanged = onTextChanged

        guard let textView = context.coordinator.textView ?? scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.textView = textView
        context.coordinator.register(textView)
        textView.textStorage?.delegate = context.coordinator
        MacNoteViewZoom.apply(zoom, to: scrollView)
        let displayText = MacEditorTextColorPolicy.normalizedForDisplay(attributedText)
        let currentText = textView.attributedString()
        if !currentText.isEqual(to: displayText) {
            let selectedRange = textView.selectedRange()
            context.coordinator.isApplyingSwiftUIUpdate = true
            textView.textStorage?.setAttributedString(displayText)
            textView.typingAttributes = MacEditorTextColorPolicy.normalizedTypingAttributes(textView.typingAttributes)
            textView.setSelectedRange(selectedRange.macClamped(toLength: displayText.length))
            context.coordinator.isApplyingSwiftUIUpdate = false
            MacNoteViewZoom.apply(zoom, to: scrollView)
        }

        formattingController.bind(textView: textView, noteID: noteID, enabled: editorEnabled)
        if context.coordinator.resignFocusToggleToken != resignFocusToggleToken {
            context.coordinator.resignFocusToggleToken = resignFocusToggleToken
            MacMarkdownPreviewFocusResignation.resignIfOwned(window: textView.window, textView: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor NSTextStorageDelegate, NSTextViewDelegate {
        var attributedText: Binding<NSAttributedString>
        var syncBridge: MacEditorSyncBridge
        var formattingController: MacFormattingController
        var onTextChanged: () -> Void
        weak var textView: NSTextView?
        var isApplyingSwiftUIUpdate = false
        var resignFocusToggleToken = 0

        init(
            attributedText: Binding<NSAttributedString>,
            syncBridge: MacEditorSyncBridge,
            formattingController: MacFormattingController,
            onTextChanged: @escaping () -> Void
        ) {
            self.attributedText = attributedText
            self.syncBridge = syncBridge
            self.formattingController = formattingController
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

            sanitizeEditedFormatting(in: textStorage, range: editedRange, textView: textView)
            textView.typingAttributes = MacFormattingMutation.supportedTypingAttributes(textView.typingAttributes)
            publishCurrentText(from: textView)
            formattingController.refreshSelection()
        }

        /// Canonicalize only the edited span, not an entire large note. Imported rich
        /// attributes outside MYR-227's six marks are never left as local-only RTF.
        /// Saving and synchronization still flow through the existing onTextChanged owner.
        private func sanitizeEditedFormatting(
            in textStorage: NSTextStorage, range: NSRange, textView: NSTextView
        ) {
            guard range.location >= 0, range.length > 0,
                  range.location <= textStorage.length,
                  range.length <= textStorage.length - range.location else { return }
            let current = textStorage.attributedSubstring(from: range)
            let canonical = MacEditorTextColorPolicy.normalizedForDisplay(
                MacStructuralFormattingAdapter.render(
                    projection: MacStructuralFormattingAdapter.project(current)
                )
            )
            guard !current.isEqual(to: canonical) else { return }
            let selection = textView.selectedRange()
            isApplyingSwiftUIUpdate = true
            textStorage.beginEditing()
            canonical.enumerateAttributes(in: NSRange(location: 0, length: canonical.length)) { attrs, part, _ in
                textStorage.setAttributes(attrs, range: NSRange(location: range.location + part.location, length: part.length))
            }
            textStorage.endEditing()
            textView.setSelectedRange(selection.macClamped(toLength: textStorage.length))
            isApplyingSwiftUIUpdate = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingSwiftUIUpdate, !syncBridge.isApplyingRemoteSync else { return }
            formattingController.refreshSelection()
        }

        private func publishCurrentText(from textView: NSTextView) {
            // Resolve a color-panel change before the save callback observes the
            // bound attributes; otherwise a stale automatic-color marker would
            // turn the user's explicit color into a structural .clear operation.
            attributedText.wrappedValue = MacEditorTextColorPolicy.normalizedForDisplay(
                textView.attributedString()
            )
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
            if let scrollView = textView.enclosingScrollView as? MacNoteReflowingScrollView {
                scrollView.applyZoomAndReflow()
            }
            formattingController.refreshSelection()
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
