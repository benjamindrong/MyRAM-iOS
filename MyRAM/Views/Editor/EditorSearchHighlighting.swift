import UIKit
import os

final class EditorSearchHighlighter {
    private static let searchHighlightLayerName = "MyRAMSearchHighlightLayer"

    private var activeRange: NSRange?
    private var activeRects: [CGRect] = []
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
        draw(validRange, in: textView)
    }

    func reposition(in textView: UITextView) {
        let positionSearchHighlightSignpostID = OSSignpostID(log: EditorSelectionProfiling.log)
        os_signpost(.begin, log: EditorSelectionProfiling.log, name: "Coordinator.positionSearchHighlightLayers", signpostID: positionSearchHighlightSignpostID)
        defer {
            os_signpost(.end, log: EditorSelectionProfiling.log, name: "Coordinator.positionSearchHighlightLayers", signpostID: positionSearchHighlightSignpostID)
        }
        guard activeLayers.count == activeRects.count,
              activeLayers.allSatisfy({ $0.superlayer === textView.layer }) else {
            if let activeRange {
                draw(activeRange, in: textView)
            }
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, rect) in zip(activeLayers, activeRects) {
            layer.frame = rect.offsetBy(
                dx: textView.textContainerInset.left - textView.contentOffset.x,
                dy: textView.textContainerInset.top - textView.contentOffset.y
            )
        }
        CATransaction.commit()
    }

    func clear(in textView: UITextView) {
        removeHighlightLayers(in: textView)
        activeRange = nil
        activeRects = []
    }

    private func removeHighlightLayers(in textView: UITextView) {
        activeLayers.forEach { $0.removeFromSuperlayer() }
        textView.layer.sublayers?
            .filter { $0.name == Self.searchHighlightLayerName }
            .forEach { $0.removeFromSuperlayer() }
        activeRects = []
        activeLayers = []
    }

    static func validHighlightRange(_ range: NSRange?, textLength: Int) -> NSRange? {
        guard let range,
              range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= textLength else {
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

    private func draw(_ range: NSRange, in textView: UITextView) {
        let drawSearchHighlightSignpostID = OSSignpostID(log: EditorSelectionProfiling.log)
        os_signpost(.begin, log: EditorSelectionProfiling.log, name: "Coordinator.drawSearchHighlight", signpostID: drawSearchHighlightSignpostID)
        defer {
            os_signpost(.end, log: EditorSelectionProfiling.log, name: "Coordinator.drawSearchHighlight", signpostID: drawSearchHighlightSignpostID)
        }
        removeHighlightLayers(in: textView)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let glyphRange = textView.layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        let emptySelection = NSRange(location: NSNotFound, length: 0)

        textView.layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: emptySelection,
            in: textView.textContainer
        ) { rect, _ in
            guard !rect.isEmpty else { return }
            let highlightLayer = CALayer()
            highlightLayer.name = Self.searchHighlightLayerName
            highlightLayer.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.45).cgColor
            highlightLayer.cornerRadius = 3
            self.activeRects.append(rect.insetBy(dx: -2, dy: -1))
            self.activeLayers.append(highlightLayer)
            textView.layer.insertSublayer(highlightLayer, at: 0)
        }
        reposition(in: textView)
    }
}
