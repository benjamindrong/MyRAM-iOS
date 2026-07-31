#if os(macOS)
import AppKit
import SwiftUI

/// Retained Mac Preview container whose reminder remains outside document zoom.
struct MacMarkdownPreviewTextView: View {
    let source: String
    let zoom: CGFloat
    let isActive: Bool
    let builder: MacMarkdownPreviewDocumentBuilder

    init(
        source: String,
        zoom: CGFloat,
        isActive: Bool,
        builder: MacMarkdownPreviewDocumentBuilder = MacMarkdownPreviewDocumentBuilder()
    ) {
        self.source = source
        self.zoom = zoom
        self.isActive = isActive
        self.builder = builder
    }

    var body: some View {
        VStack(spacing: 0) {
            MacMarkdownPreviewReminderContainer()

            Divider()

            MacMarkdownPreviewNSViewRepresentable(
                source: source,
                zoom: zoom,
                isActive: isActive,
                builder: builder
            )
        }
    }
}

private struct MacMarkdownPreviewReminderContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSHostingView<MarkdownPreviewReminder> {
        let hostingView = NSHostingView(rootView: MarkdownPreviewReminder())
        hostingView.setAccessibilityIdentifier("markdown-preview-reminder")
        return hostingView
    }

    func updateNSView(
        _ hostingView: NSHostingView<MarkdownPreviewReminder>,
        context: Context
    ) {
        hostingView.rootView = MarkdownPreviewReminder()
    }
}

struct MacMarkdownPreviewNSViewRepresentable: NSViewRepresentable {
    let source: String
    let zoom: CGFloat
    let isActive: Bool
    let builder: MacMarkdownPreviewDocumentBuilder

    func makeCoordinator() -> Coordinator {
        Coordinator(builder: builder)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MacNoteReflowingScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("markdown-preview-body")

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // Reflow zoom owns document width. AppKit width autoresizing would undo it.
        textView.autoresizingMask = []
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        MacNoteViewZoom.apply(zoom, to: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView
                ?? scrollView.documentView as? NSTextView else {
            return
        }
        context.coordinator.textView = textView
        MacNoteViewZoom.apply(zoom, to: scrollView)

        guard isActive else { return }
        guard source != context.coordinator.lastRenderedSource else { return }

        let candidate = context.coordinator.builder.build(source: source)
        let current = textView.attributedString()
        if current.isEqual(to: candidate) {
            context.coordinator.lastRenderedSource = source
            context.coordinator.lastRenderedDocument = candidate
            return
        }

        let selectedRange = textView.selectedRange()
        let visibleOrigin = scrollView.contentView.bounds.origin
        textView.textStorage?.setAttributedString(candidate)
        textView.setSelectedRange(selectedRange.macClamped(toLength: candidate.length))
        MacNoteViewZoom.apply(zoom, to: scrollView)
        restoreVisibleOrigin(visibleOrigin, in: scrollView)
        context.coordinator.lastRenderedSource = source
        context.coordinator.lastRenderedDocument = candidate
    }

    private func restoreVisibleOrigin(_ origin: NSPoint, in scrollView: NSScrollView) {
        scrollView.documentView?.layoutSubtreeIfNeeded()

        let documentBounds = scrollView.documentView?.bounds ?? .zero
        let visibleSize = scrollView.contentView.bounds.size
        let maximumX = max(0, documentBounds.width - visibleSize.width)
        let maximumY = max(0, documentBounds.height - visibleSize.height)
        let clampedOrigin = NSPoint(
            x: min(max(0, origin.x), maximumX),
            y: min(max(0, origin.y), maximumY)
        )
        scrollView.contentView.scroll(to: clampedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @MainActor
    final class Coordinator {
        var lastRenderedSource: String?
        var lastRenderedDocument: NSAttributedString?
        weak var textView: NSTextView?
        let builder: MacMarkdownPreviewDocumentBuilder

        init(builder: MacMarkdownPreviewDocumentBuilder) {
            self.builder = builder
        }
    }
}
#endif
