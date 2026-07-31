#if os(macOS)
import AppKit
import Foundation

/// Projects the shared Markdown parser result into one immutable native document.
struct MacMarkdownPreviewDocumentBuilder {
    private let parser: MarkdownPreviewParser

    init(parser: MarkdownPreviewParser = MarkdownPreviewParser()) {
        self.parser = parser
    }

    func build(source: String) -> NSAttributedString {
        switch parser.parseDocument(source) {
        case .plainTextFallback(let exactSource):
            return NSAttributedString(
                string: exactSource,
                attributes: baseAttributes(font: bodyFont)
            )
        case .rendered(let document):
            return build(document: document)
        }
    }

    private func build(document: MarkdownPreviewDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for (index, block) in document.blocks.enumerated() {
            result.append(build(block: block))

            guard index < document.blocks.count - 1 else { continue }
            let nextBlock = document.blocks[index + 1]
            let separator = block.kind.isListItem && nextBlock.kind.isListItem ? "\n" : "\n\n"
            result.append(NSAttributedString(string: separator))
        }

        return NSAttributedString(attributedString: result)
    }

    private func build(block: MarkdownPreviewBlock) -> NSAttributedString {
        switch block.kind {
        case .paragraph:
            return buildTextBlock(
                content: block.content,
                font: bodyFont,
                paragraphStyle: paragraphStyle(spacing: 10)
            )
        case .heading(let level):
            return buildTextBlock(
                content: block.content,
                font: headingFont(level: level),
                paragraphStyle: paragraphStyle(spacing: 12),
                forceBold: true
            )
        case .orderedListItem(let metadata):
            guard case .ordered(let ordinal) = metadata.style else {
                return buildTextBlock(content: block.content, font: bodyFont)
            }
            return buildListItem(
                marker: "\(ordinal).",
                content: block.content,
                depth: metadata.depth
            )
        case .unorderedListItem(let metadata):
            return buildListItem(
                marker: "•",
                content: block.content,
                depth: metadata.depth
            )
        case .blockQuote:
            let style = paragraphStyle(spacing: 10)
            style.firstLineHeadIndent = 16
            style.headIndent = 16
            return buildTextBlock(
                content: block.content,
                font: bodyFont,
                paragraphStyle: style,
                foregroundColor: .secondaryLabelColor,
                backgroundColor: .controlBackgroundColor.withAlphaComponent(0.55)
            )
        case .codeBlock:
            return buildTextBlock(
                content: block.content,
                font: NSFont.monospacedSystemFont(
                    ofSize: bodyFont.pointSize,
                    weight: .regular
                ),
                paragraphStyle: paragraphStyle(spacing: 10),
                backgroundColor: .controlBackgroundColor.withAlphaComponent(0.65)
            )
        }
    }

    private func buildListItem(
        marker: String,
        content: AttributedString,
        depth: Int
    ) -> NSAttributedString {
        let effectiveDepth = max(1, depth)
        let depthPrefix = String(repeating: "    ", count: effectiveDepth - 1)
        let prefixAndMarker = "\(depthPrefix)\(marker)"
        let mutable = NSMutableAttributedString(
            string: "\(prefixAndMarker)\t",
            attributes: baseAttributes(font: bodyFont)
        )
        mutable.addAttribute(
            .foregroundColor,
            value: NSColor.secondaryLabelColor,
            range: NSRange(location: 0, length: mutable.length)
        )

        let contentStart = mutable.length
        mutable.append(buildInlineContent(content, baseFont: bodyFont))

        let contentIndent = renderedWidth(of: prefixAndMarker, font: bodyFont) + 8
        let style = paragraphStyle(spacing: 0)
        style.firstLineHeadIndent = 0
        style.headIndent = contentIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: contentIndent)]
        style.defaultTabInterval = contentIndent
        mutable.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: 0, length: mutable.length)
        )

        if contentStart < mutable.length {
            mutable.addAttribute(
                .foregroundColor,
                value: NSColor.textColor,
                range: NSRange(location: contentStart, length: mutable.length - contentStart)
            )
        }
        return mutable
    }

    private func buildTextBlock(
        content: AttributedString,
        font: NSFont,
        paragraphStyle: NSParagraphStyle? = nil,
        forceBold: Bool = false,
        foregroundColor: NSColor = .textColor,
        backgroundColor: NSColor? = nil
    ) -> NSAttributedString {
        let effectiveFont = forceBold ? font.withTraits([.boldFontMask]) : font
        let mutable = NSMutableAttributedString(
            attributedString: buildInlineContent(content, baseFont: effectiveFont)
        )
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: foregroundColor, range: fullRange)
        if let paragraphStyle {
            mutable.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
        }
        if let backgroundColor {
            mutable.addAttribute(.backgroundColor, value: backgroundColor, range: fullRange)
        }
        return mutable
    }

    private func buildInlineContent(
        _ content: AttributedString,
        baseFont: NSFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for run in content.runs {
            let characters = String(content[run.range].characters)
            let intent = run.inlinePresentationIntent
            var font = baseFont
            var attributes = baseAttributes(font: font)

            if intent?.contains(.code) == true {
                font = NSFont.monospacedSystemFont(
                    ofSize: baseFont.pointSize,
                    weight: .regular
                )
                attributes[.backgroundColor] = NSColor.controlBackgroundColor
            }

            var traits: NSFontTraitMask = []
            if intent?.contains(.stronglyEmphasized) == true {
                traits.insert(.boldFontMask)
            }
            if intent?.contains(.emphasized) == true {
                traits.insert(.italicFontMask)
            }
            attributes[.font] = font.withTraits(traits)

            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: characters, attributes: attributes))
        }

        return result
    }

    private func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
    }

    private var bodyFont: NSFont {
        NSFont.preferredFont(forTextStyle: .body)
    }

    private func headingFont(level: Int) -> NSFont {
        switch level {
        case 1:
            return NSFont.preferredFont(forTextStyle: .title1)
        case 2:
            return NSFont.preferredFont(forTextStyle: .title2)
        case 3:
            return NSFont.preferredFont(forTextStyle: .title3)
        default:
            return NSFont.preferredFont(forTextStyle: .headline)
        }
    }

    private func paragraphStyle(spacing: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        return style
    }

    private func renderedWidth(of string: String, font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontTraitMask) -> NSFont {
        guard !traits.isEmpty else { return self }
        return NSFontManager.shared.convert(self, toHaveTrait: traits)
    }
}

private extension MarkdownBlockKind {
    var isListItem: Bool {
        switch self {
        case .orderedListItem, .unorderedListItem:
            return true
        default:
            return false
        }
    }
}
#endif
