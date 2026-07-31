#if os(macOS)
import AppKit
import SwiftUI

/// Scene-local reading zoom shared by the native editor and Preview.
enum MacNoteViewZoom {
    static let actualSize: CGFloat = 1.0
    static let minimum: CGFloat = 0.5
    static let maximum: CGFloat = 3.0
    static let step: CGFloat = 0.1

    fileprivate static let equalityEpsilon: CGFloat = 0.0001

    static func zoomedIn(from value: CGFloat) -> CGFloat {
        normalized(value + step)
    }

    static func zoomedOut(from value: CGFloat) -> CGFloat {
        normalized(value - step)
    }

    static func normalized(_ value: CGFloat) -> CGFloat {
        let finiteValue = value.isFinite ? value : actualSize
        let steppedValue = (finiteValue / step).rounded() * step
        return min(maximum, max(minimum, steppedValue))
    }

    static func canZoomIn(_ value: CGFloat) -> Bool {
        normalized(value) < maximum - equalityEpsilon
    }

    static func canZoomOut(_ value: CGFloat) -> Bool {
        normalized(value) > minimum + equalityEpsilon
    }

    static func isActualSize(_ value: CGFloat) -> Bool {
        abs(normalized(value) - actualSize) <= equalityEpsilon
    }

    /// Magnifies the document while reducing its TextKit layout width by the same
    /// factor. The visible width remains equal to the viewport, so text reflows
    /// instead of extending horizontally beyond the window.
    static func apply(_ value: CGFloat, to scrollView: NSScrollView) {
        let requestedZoom = normalized(value)
        if let reflowingScrollView = scrollView as? MacNoteReflowingScrollView {
            reflowingScrollView.noteZoom = requestedZoom
        }
        applyZoomAndReflow(requestedZoom, to: scrollView)
    }

    fileprivate static func applyZoomAndReflow(
        _ value: CGFloat,
        to scrollView: NSScrollView
    ) {
        guard let textView = scrollView.documentView as? NSTextView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return
        }

        let requestedZoom = normalized(value)
        let viewportSize = scrollView.contentSize
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        scrollView.allowsMagnification = false
        scrollView.minMagnification = minimum
        scrollView.maxMagnification = maximum
        scrollView.hasHorizontalScroller = false

        let targetDocumentWidth = max(1, viewportSize.width / requestedZoom)
        let targetContainerWidth = max(
            1,
            targetDocumentWidth - (textView.textContainerInset.width * 2)
        )

        // AppKit's ordinary width autoresizing would immediately expand the
        // document view back to the clip-view width and defeat reflow zoom.
        textView.autoresizingMask = []
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: targetDocumentWidth, height: 0)
        textView.maxSize = NSSize(
            width: targetDocumentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(
            width: targetContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )

        var frame = textView.frame
        frame.size.width = targetDocumentWidth
        textView.frame = frame

        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
            + (textView.textContainerInset.height * 2)
        let minimumDocumentHeight = viewportSize.height / requestedZoom
        let targetDocumentHeight = max(minimumDocumentHeight, ceil(usedHeight))

        if abs(textView.frame.height - targetDocumentHeight) > equalityEpsilon {
            frame = textView.frame
            frame.size.height = targetDocumentHeight
            textView.frame = frame
        }

        guard abs(scrollView.magnification - requestedZoom) > equalityEpsilon else {
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }

        let visibleRect = scrollView.documentVisibleRect
        let center = NSPoint(x: visibleRect.midX, y: visibleRect.midY)
        scrollView.setMagnification(requestedZoom, centeredAt: center)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// Reapplies reflow whenever the window or split-view viewport changes size.
final class MacNoteReflowingScrollView: NSScrollView {
    var noteZoom: CGFloat = MacNoteViewZoom.actualSize
    private var isApplyingZoom = false

    override func layout() {
        super.layout()
        applyZoomAndReflow()
    }

    func applyZoomAndReflow() {
        guard !isApplyingZoom else { return }
        isApplyingZoom = true
        MacNoteViewZoom.applyZoomAndReflow(noteZoom, to: self)
        isApplyingZoom = false
    }
}

private struct MacNoteViewZoomFocusedValueKey: FocusedValueKey {
    typealias Value = Binding<CGFloat>
}

extension FocusedValues {
    var macNoteViewZoom: Binding<CGFloat>? {
        get { self[MacNoteViewZoomFocusedValueKey.self] }
        set { self[MacNoteViewZoomFocusedValueKey.self] = newValue }
    }
}

struct MacNoteViewZoomCommands: Commands {
    @FocusedBinding(\.macNoteViewZoom) private var zoom

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Button("Zoom In") {
                guard let zoom else { return }
                self.zoom = MacNoteViewZoom.zoomedIn(from: zoom)
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(zoom.map(MacNoteViewZoom.canZoomIn) != true)

            Button("Zoom Out") {
                guard let zoom else { return }
                self.zoom = MacNoteViewZoom.zoomedOut(from: zoom)
            }
            .keyboardShortcut(",", modifiers: [.command, .shift])
            .disabled(zoom.map(MacNoteViewZoom.canZoomOut) != true)

            Button("Actual Size") {
                zoom = MacNoteViewZoom.actualSize
            }
            .keyboardShortcut("0", modifiers: [.command, .shift])
            .disabled(zoom.map { !MacNoteViewZoom.isActualSize($0) } != true)
        }
    }
}
#endif
