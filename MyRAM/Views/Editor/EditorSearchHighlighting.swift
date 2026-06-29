import UIKit
import os

final class EditorSearchHighlighter {
    private static let searchHighlightLayerName = "MyRAMSearchHighlightLayer"

    private var activeRange: NSRange?
    private var activeLayers: [CALayer] = []

    var hasActiveHighlight: Bool {
        activeRange != nil
    }

    func apply(range: NSRange?, in textView: UITextView) {
#if DEBUG
        if EditorSelectionProfiling.disablesSearchHighlights {
            clear(in: textView)
            return
        }
#endif
        let searchHighlightSignpostID = OSSignpostID(log: EditorSelectionProfiling.log)
        os_signpost(.begin, log: EditorSelectionProfiling.log, name: "Coordinator.applySearchHighlight", signpostID: searchHighlightSignpostID)
        defer {
            os_signpost(.end, log: EditorSelectionProfiling.log, name: "Coordinator.applySearchHighlight", signpostID: searchHighlightSignpostID)
        }
        if let range, isSameActiveRange(range, in: textView) {
            reposition(in: textView)
            return
        }
        clear(in: textView)

        guard let validRange = Self.validHighlightRange(range, textLength: textView.textStorage.length) else {
            return
        }

        activeRange = validRange
        textView.scrollRangeToVisible(validRange)
        redraw(validRange, in: textView)
        schedulePostScrollReposition(in: textView)
    }

    func reposition(in textView: UITextView) {
        let positionSearchHighlightSignpostID = OSSignpostID(log: EditorSelectionProfiling.log)
        os_signpost(.begin, log: EditorSelectionProfiling.log, name: "Coordinator.positionSearchHighlightLayers", signpostID: positionSearchHighlightSignpostID)
        defer {
            os_signpost(.end, log: EditorSelectionProfiling.log, name: "Coordinator.positionSearchHighlightLayers", signpostID: positionSearchHighlightSignpostID)
        }
        guard let activeRange else { return }
        guard let layerRects = Self.highlightLayerRects(for: activeRange, in: textView) else {
            clear(in: textView)
            return
        }

        guard activeLayers.count == layerRects.count,
              activeLayers.allSatisfy({ $0.superlayer === textView.layer }) else {
            redraw(activeRange, in: textView)
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, rect) in zip(activeLayers, layerRects) {
            layer.frame = rect
        }
        CATransaction.commit()
    }

    func clear(in textView: UITextView) {
        removeHighlightLayers(in: textView)
        activeRange = nil
    }

    private func removeHighlightLayers(in textView: UITextView) {
        activeLayers.forEach { $0.removeFromSuperlayer() }
        textView.layer.sublayers?
            .filter { $0.name == Self.searchHighlightLayerName }
            .forEach { $0.removeFromSuperlayer() }
        activeLayers = []
    }

    static func validHighlightRange(_ range: NSRange?, textLength: Int) -> NSRange? {
        guard let range,
              EditorSelectionRangeResolver.hasPositiveLengthResolvedRange(range, textLength: textLength) else {
            return nil
        }
        return range
    }

    func isSameActiveRange(_ range: NSRange, in textView: UITextView) -> Bool {
        range == activeRange && hasSearchHighlightLayers(in: textView)
    }

    private func hasSearchHighlightLayers(in textView: UITextView) -> Bool {
        activeLayers.contains { $0.superlayer === textView.layer }
    }

    private func redraw(_ range: NSRange, in textView: UITextView) {
        let drawSearchHighlightSignpostID = OSSignpostID(log: EditorSelectionProfiling.log)
        os_signpost(.begin, log: EditorSelectionProfiling.log, name: "Coordinator.drawSearchHighlight", signpostID: drawSearchHighlightSignpostID)
        defer {
            os_signpost(.end, log: EditorSelectionProfiling.log, name: "Coordinator.drawSearchHighlight", signpostID: drawSearchHighlightSignpostID)
        }
        removeHighlightLayers(in: textView)
        guard let layerRects = Self.highlightLayerRects(for: range, in: textView) else {
            activeRange = nil
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for rect in layerRects {
            let highlightLayer = CALayer()
            highlightLayer.name = Self.searchHighlightLayerName
            highlightLayer.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.45).cgColor
            highlightLayer.cornerRadius = 3
            highlightLayer.frame = rect
            self.activeLayers.append(highlightLayer)
            textView.layer.insertSublayer(highlightLayer, at: 0)
        }
        CATransaction.commit()
    }

    // scrollRangeToVisible can settle after the current layout pass; this final
    // runloop pass converges the highlight after scrolling and layout finish.
    private func schedulePostScrollReposition(in textView: UITextView) {
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, self.hasActiveHighlight else { return }
            self.reposition(in: textView)
        }
    }

    static func highlightLayerRects(for range: NSRange, in textView: UITextView) -> [CGRect]? {
        guard let validRange = validHighlightRange(range, textLength: textView.textStorage.length) else {
            return nil
        }

        textView.layoutIfNeeded()
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let glyphRange = textView.layoutManager.glyphRange(
            forCharacterRange: validRange,
            actualCharacterRange: nil
        )
        let emptySelection = NSRange(location: NSNotFound, length: 0)
        var layerRects: [CGRect] = []

        textView.layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: emptySelection,
            in: textView.textContainer
        ) { rect, _ in
            guard !rect.isEmpty else { return }
            let paddedRect = rect.insetBy(dx: -2, dy: -1)
            layerRects.append(EditorSearchHighlightGeometry.layerRect(
                forTextContainerRect: paddedRect,
                textContainerInset: textView.textContainerInset
            ))
        }

        return layerRects
    }
}

enum EditorSearchHighlightGeometry {
    static func layerRect(
        forTextContainerRect rect: CGRect,
        textContainerInset: UIEdgeInsets
    ) -> CGRect {
        // TextKit returns glyph enclosing rects in text-container coordinates.
        // Layers inserted into UITextView.layer live in content coordinates, so
        // scrolling is handled by the scroll view's bounds instead of this frame.
        rect.offsetBy(
            dx: textContainerInset.left,
            dy: textContainerInset.top
        )
    }
}
