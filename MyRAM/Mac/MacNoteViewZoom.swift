#if os(macOS)
import AppKit
import SwiftUI

/// Scene-local document magnification shared by the native editor and Preview.
enum MacNoteViewZoom {
    static let actualSize: CGFloat = 1.0
    static let minimum: CGFloat = 0.5
    static let maximum: CGFloat = 3.0
    static let step: CGFloat = 0.1

    private static let equalityEpsilon: CGFloat = 0.0001

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

    /// Uses AppKit document magnification without changing text or attributed content.
    static func apply(_ value: CGFloat, to scrollView: NSScrollView) {
        let requestedMagnification = normalized(value)
        scrollView.allowsMagnification = false
        scrollView.minMagnification = minimum
        scrollView.maxMagnification = maximum

        guard abs(scrollView.magnification - requestedMagnification) > equalityEpsilon else {
            return
        }

        let visibleRect = scrollView.documentVisibleRect
        let center = NSPoint(x: visibleRect.midX, y: visibleRect.midY)
        scrollView.setMagnification(requestedMagnification, centeredAt: center)
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
