import AppKit

public enum LargeAttributedNoteFactory {
    public static let defaultSectionCount = 420

    public static func makeSampleNote(sectionCount: Int = defaultSectionCount) -> NSAttributedString {
        let note = NSMutableAttributedString()

        for index in 1...sectionCount {
            appendHeading("Selection stress section \(index)", to: note)
            appendBody(index: index, to: note)
            appendList(index: index, to: note)
            appendQuote(index: index, to: note)
        }

        return note
    }

    private static func appendHeading(_ text: String, to note: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 18
        paragraph.paragraphSpacing = 8
        paragraph.lineBreakMode = .byWordWrapping

        note.append(NSAttributedString(
            string: "\(text)\n",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 19),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        ))
    }

    private static func appendBody(index: Int, to note: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 10
        paragraph.lineBreakMode = .byWordWrapping

        let body = """
        This paragraph mimics a dense MyRAM note body with enough formatting variance to exercise native AppKit layout, glyph generation, selection painting, and edge auto-scroll. Section \(index) includes emphasized spans, a link-like range, and repeated prose so drag-selection has to cross many laid-out fragments before it reaches the bottom of the document.

        """

        let start = note.length
        note.append(NSAttributedString(
            string: body,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraph
            ]
        ))

        let emphasizedRange = NSRange(location: start + 66, length: 27)
        if NSMaxRange(emphasizedRange) <= note.length {
            note.addAttributes([
                .font: NSFont.boldSystemFont(ofSize: 15),
                .foregroundColor: NSColor.controlAccentColor
            ], range: emphasizedRange)
        }

        let linkRange = (note.string as NSString).range(of: "link-like range", options: [], range: NSRange(location: start, length: note.length - start))
        if linkRange.location != NSNotFound {
            note.addAttributes([
                .link: URL(string: "https://example.com/myr-96") as Any,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.linkColor
            ], range: linkRange)
        }
    }

    private static func appendList(index: Int, to note: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 22
        paragraph.headIndent = 38
        paragraph.paragraphSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping

        let text = """
        - Preserve enough attributes to stress layout and selection behavior.
        - Keep the shell intentionally separate from MyRAM persistence for this spike.
        - Compare section \(index) auto-scroll behavior against the Catalyst MYR-95 traces.

        """

        note.append(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        ))
    }

    private static func appendQuote(index: Int, to note: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 24
        paragraph.firstLineHeadIndent = 24
        paragraph.paragraphSpacing = 12
        paragraph.lineBreakMode = .byWordWrapping

        note.append(NSAttributedString(
            string: "Manual checkpoint \(index): drag-select through this block and hold near the viewport edge to observe native NSTextView auto-scroll.\n\n",
            attributes: [
                .font: italicSystemFont(ofSize: 15),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph
            ]
        ))
    }

    private static func italicSystemFont(ofSize size: CGFloat) -> NSFont {
        let baseFont = NSFont.systemFont(ofSize: size)
        return NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
    }
}
