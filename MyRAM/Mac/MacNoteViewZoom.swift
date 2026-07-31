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

    /// Applies view-only font scaling through NSLayoutManager temporary attributes.
    /// NSTextStorage remains unchanged, while TextKit re-lays out and wraps at the
    /// existing viewport width.
    static func apply(_ value: CGFloat, to scrollView: NSScrollView) {
        let requestedZoom = normalized(value)
        if let reflowingScrollView = scrollView as? MacNoteReflowingScrollView {
            reflowingScrollView.noteZoom = requestedZoom
        }
        applyDisplayZoom(requestedZoom, to: scrollView)
    }

    fileprivate static func applyDisplayZoom(_ value: CGFloat, to scrollView: NSScrollView) {
        guard let textView = scrollView.documentView as? NSTextView,
              let textStorage = textView.textStorage,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        scrollView.allowsMagnification = false
        scrollView.minMagnification = actualSize
        scrollView.maxMagnification = actualSize
        scrollView.magnification = actualSize
        scrollView.hasHorizontalScroller = false

        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(
            width: max(1, scrollView.contentSize.width),
            height: CGFloat.greatestFiniteMagnitude
        )

        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }

        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)

        textStorage.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let sourceFont = attributes[.font] as? NSFont
                ?? textView.font
                ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let displayFont = NSFont(
                descriptor: sourceFont.fontDescriptor,
                size: max(1, sourceFont.pointSize * value)
            ) ?? sourceFont
            layoutManager.addTemporaryAttribute(
                .font,
                value: displayFont,
                forCharacterRange: range
            )
        }

        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        layoutManager.invalidateDisplay(forCharacterRange: fullRange)
        layoutManager.ensureLayout(for: textContainer)
    }
}

/// Reapplies display zoom after window and split-view layout changes.
final class MacNoteReflowingScrollView: NSScrollView {
    var noteZoom: CGFloat = MacNoteViewZoom.actualSize
    private var isApplyingZoom = false

    override func layout() {
        super.layout()
        guard !isApplyingZoom else { return }
        isApplyingZoom = true
        MacNoteViewZoom.applyDisplayZoom(noteZoom, to: self)
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
