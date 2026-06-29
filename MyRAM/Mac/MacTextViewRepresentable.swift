#if os(macOS)
import AppKit
import SwiftUI

struct MacTextViewRepresentable: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    var onTextChanged: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(attributedText: $attributedText, onTextChanged: onTextChanged)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.textStorage?.setAttributedString(attributedText)
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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.attributedText = $attributedText
        context.coordinator.onTextChanged = onTextChanged

        guard let textView = context.coordinator.textView ?? scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.textView = textView
        textView.textStorage?.delegate = context.coordinator
        let currentText = textView.attributedString()
        if !currentText.isEqual(to: attributedText) {
            let selectedRange = textView.selectedRange()
            context.coordinator.isApplyingSwiftUIUpdate = true
            textView.textStorage?.setAttributedString(attributedText)
            textView.setSelectedRange(selectedRange.clamped(toLength: attributedText.length))
            context.coordinator.isApplyingSwiftUIUpdate = false
        }
    }

    final class Coordinator: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
        var attributedText: Binding<NSAttributedString>
        var onTextChanged: () -> Void
        weak var textView: NSTextView?
        var isApplyingSwiftUIUpdate = false

        init(attributedText: Binding<NSAttributedString>, onTextChanged: @escaping () -> Void) {
            self.attributedText = attributedText
            self.onTextChanged = onTextChanged
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingSwiftUIUpdate else { return }
            guard let textView = notification.object as? NSTextView else {
                return
            }

            publishCurrentText(from: textView)
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard !isApplyingSwiftUIUpdate else { return }
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
    }
}

private extension NSRange {
    func clamped(toLength length: Int) -> NSRange {
        let safeLocation = min(location, length)
        let maxLength = length - safeLocation
        return NSRange(location: safeLocation, length: min(self.length, maxLength))
    }
}
#endif
