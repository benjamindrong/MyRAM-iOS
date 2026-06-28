#if os(macOS)
enum MacEditorSampleDocument {
    static let defaultSectionCount = 360

    static func makeSampleText(sectionCount: Int = defaultSectionCount) -> String {
        guard sectionCount > 0 else {
            return ""
        }

        return (1...sectionCount)
            .map(makeSection)
            .joined(separator: "\n")
    }

    private static func makeSection(_ index: Int) -> String {
        """
        Selection stress section \(index)
        This paragraph mimics a dense MyRAM note body with enough plain text to exercise native AppKit layout, glyph generation, selection painting, edge auto-scroll, copy and paste, and undo behavior. Section \(index) repeats practical note prose so drag-selection has to cross many laid-out fragments before it reaches the bottom of the document.

        - Keep this native editor separate from persistence for MYR-106.
        - Verify typing, scrolling, selection, copy and paste, and undo manually.
        - Preserve a stable generated workload for future Mac editor checks.

        Manual checkpoint \(index): drag-select through this block and hold near the viewport edge to observe native NSTextView auto-scroll.
        """
    }
}
#endif
