import UIKit

enum ChecklistItemEditor {
    static let uncheckedPrefix = "☐\t"
    static let checkedPrefix = "☑︎\t"
    static let checkedPrefixVariant = "☑\t"
    static let legacyUncheckedGlyphPrefix = "☐ "
    static let legacyCheckedGlyphPrefix = "☑︎ "
    static let legacyCheckedGlyphPrefixVariant = "☑ "
    static let legacyUncheckedPrefix = "- [ ] "
    static let legacyCheckedPrefix = "- [x] "
    static let legacyShortUncheckedPrefix = "[ ] "
    static let legacyShortCheckedPrefix = "[x] "

    private static let autoChecklistStrikethroughKey = NSAttributedString.Key("com.apexcoretechs.myram.checklist-auto-strikethrough")
    private static let minimumChecklistGutterWidth: CGFloat = 28
    private static let checklistGutterReferenceFontSize: CGFloat = 20
    private static let uncheckedChecklistIconFontSize = checklistGutterReferenceFontSize
    private static let checkedChecklistIconFontSize = checklistGutterReferenceFontSize
    private static let checklistGutterWidth: CGFloat = {
        let iconFont = UIFont.systemFont(ofSize: checklistGutterReferenceFontSize, weight: .regular)
        let uncheckedWidth = (uncheckedPrefix.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .size(withAttributes: [.font: iconFont])
            .width
        let checkedWidth = (checkedPrefix.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .size(withAttributes: [.font: iconFont])
            .width
        return max(minimumChecklistGutterWidth, ceil(max(uncheckedWidth, checkedWidth)) + 12)
    }()
    private static let paragraphSpacing: CGFloat = UIFont.preferredFont(forTextStyle: .body).lineHeight * 0.5
    private static let compactTextInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
    static let gutterTapWidth: CGFloat = 44

    static var editorParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = 0
        style.lineBreakMode = .byWordWrapping
        applyParagraphSpacing(to: style)
        return style
    }

    static func bodyParagraphStyle(hasChecklistItems: Bool) -> NSParagraphStyle {
        guard hasChecklistItems else { return editorParagraphStyle }

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = checklistGutterWidth
        style.headIndent = checklistGutterWidth
        style.tabStops = [NSTextTab(textAlignment: .left, location: checklistGutterWidth)]
        style.defaultTabInterval = checklistGutterWidth
        style.lineBreakMode = .byWordWrapping
        applyParagraphSpacing(to: style)
        return style
    }

    static func textContainerInsets(hasChecklistItems: Bool) -> UIEdgeInsets {
        guard hasChecklistItems else { return compactTextInset }
        return UIEdgeInsets(
            top: compactTextInset.top,
            left: compactTextInset.left,
            bottom: compactTextInset.bottom,
            right: compactTextInset.right + checklistGutterWidth
        )
    }

    private static var checklistParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = checklistGutterWidth
        style.tabStops = [NSTextTab(textAlignment: .left, location: checklistGutterWidth)]
        style.defaultTabInterval = checklistGutterWidth
        style.lineBreakMode = .byWordWrapping
        applyParagraphSpacing(to: style)
        return style
    }

    private static func applyParagraphSpacing(to style: NSMutableParagraphStyle) {
        style.lineSpacing = 0
        style.paragraphSpacing = paragraphSpacing
    }

    static func applyChecklistAction(
        in attributedText: NSMutableAttributedString,
        selection: NSRange
    ) -> NSRange {
        let text = attributedText.string as NSString
        let clampedSelectionLocation = EditorSelectionRangeResolver.clampedCaretLocation(
            selection.location,
            textLength: text.length
        )
        let lineRangeWithNewline = text.lineRange(for: NSRange(location: clampedSelectionLocation, length: 0))
        let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
        let line = text.substring(with: lineRange)

        let replacement: (range: NSRange, prefix: String)
        if line.hasPrefix(checkedPrefix) {
            replacement = (NSRange(location: lineRange.location, length: checkedPrefix.utf16.count), uncheckedPrefix)
        } else if line.hasPrefix(checkedPrefixVariant) {
            replacement = (NSRange(location: lineRange.location, length: checkedPrefixVariant.utf16.count), uncheckedPrefix)
        } else if line.hasPrefix(uncheckedPrefix) {
            replacement = (NSRange(location: lineRange.location, length: uncheckedPrefix.utf16.count), checkedPrefix)
        } else if line.hasPrefix(legacyCheckedGlyphPrefix) {
            replacement = (NSRange(location: lineRange.location, length: legacyCheckedGlyphPrefix.utf16.count), uncheckedPrefix)
        } else if line.hasPrefix(legacyCheckedGlyphPrefixVariant) {
            replacement = (NSRange(location: lineRange.location, length: legacyCheckedGlyphPrefixVariant.utf16.count), uncheckedPrefix)
        } else if line.hasPrefix(legacyUncheckedGlyphPrefix) {
            replacement = (NSRange(location: lineRange.location, length: legacyUncheckedGlyphPrefix.utf16.count), checkedPrefix)
        } else if line.hasPrefix(legacyCheckedPrefix) {
            replacement = (NSRange(location: lineRange.location, length: legacyCheckedPrefix.utf16.count), uncheckedPrefix)
        } else if line.hasPrefix(legacyUncheckedPrefix) {
            replacement = (NSRange(location: lineRange.location, length: legacyUncheckedPrefix.utf16.count), checkedPrefix)
        } else if line.hasPrefix(legacyShortCheckedPrefix) {
            replacement = (NSRange(location: lineRange.location, length: legacyShortCheckedPrefix.utf16.count), uncheckedPrefix)
        } else if line.hasPrefix(legacyShortUncheckedPrefix) {
            replacement = (NSRange(location: lineRange.location, length: legacyShortUncheckedPrefix.utf16.count), checkedPrefix)
        } else {
            replacement = (NSRange(location: lineRange.location, length: 0), uncheckedPrefix)
        }

        let delta = replacement.prefix.utf16.count - replacement.range.length
        attributedText.replaceCharacters(in: replacement.range, with: replacement.prefix)
        _ = applyEditorRendering(in: attributedText)

        let oldLocation = clampedSelectionLocation
        let adjustedLocation: Int
        if oldLocation < replacement.range.location {
            adjustedLocation = oldLocation
        } else if oldLocation <= replacement.range.location + replacement.range.length {
            adjustedLocation = replacement.range.location + replacement.prefix.utf16.count
        } else {
            adjustedLocation = oldLocation + delta
        }

        let newLength = attributedText.length
        return NSRange(
            location: EditorSelectionRangeResolver.clampedCaretLocation(
                adjustedLocation,
                textLength: newLength
            ),
            length: 0
        )
    }

    @discardableResult
    static func applyEditorRendering(in attributedText: NSMutableAttributedString) -> Bool {
        let previous = attributedText.copy() as? NSAttributedString
        normalizeLegacyPrefixes(in: attributedText)
        applyEditorParagraphStyles(in: attributedText)
        applyChecklistPrefixRendering(in: attributedText)
        let fullRange = NSRange(location: 0, length: attributedText.length)

        var autoRanges: [NSRange] = []
        attributedText.enumerateAttribute(autoChecklistStrikethroughKey, in: fullRange) { value, range, _ in
            if (value as? Bool) == true {
                autoRanges.append(range)
            }
        }

        autoRanges.forEach { range in
            attributedText.removeAttribute(.strikethroughStyle, range: range)
            attributedText.removeAttribute(.strikethroughColor, range: range)
            attributedText.removeAttribute(autoChecklistStrikethroughKey, range: range)
        }

        checkedContentRanges(in: attributedText.string as NSString).forEach { range in
            guard range.length > 0 else { return }
            attributedText.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: range
            )
            attributedText.addAttribute(
                autoChecklistStrikethroughKey,
                value: true,
                range: range
            )
        }

        return previous?.isEqual(to: attributedText) == false
    }

    static func checkedContentRanges(in text: NSString) -> [NSRange] {
        guard text.length > 0 else { return [] }

        var ranges: [NSRange] = []
        var cursor = 0
        while cursor < text.length {
            let lineRangeWithNewline = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
            let line = text.substring(with: lineRange)

            let prefixLength: Int?
            if line.hasPrefix(checkedPrefix) {
                prefixLength = checkedPrefix.utf16.count
            } else if line.hasPrefix(checkedPrefixVariant) {
                prefixLength = checkedPrefixVariant.utf16.count
            } else if line.hasPrefix(legacyCheckedGlyphPrefix) {
                prefixLength = legacyCheckedGlyphPrefix.utf16.count
            } else if line.hasPrefix(legacyCheckedGlyphPrefixVariant) {
                prefixLength = legacyCheckedGlyphPrefixVariant.utf16.count
            } else {
                prefixLength = nil
            }

            if let prefixLength {
                let start = lineRange.location + prefixLength
                let length = max(lineRange.length - prefixLength, 0)
                ranges.append(NSRange(location: start, length: length))
            }

            let nextCursor = lineRangeWithNewline.location + lineRangeWithNewline.length
            if nextCursor <= cursor { break }
            cursor = nextCursor
        }
        return ranges
    }

    static func pinCandidate(in text: NSString, selection: NSRange) -> (text: String, sourceRange: NSRange)? {
        guard text.length > 0,
              selection.location != NSNotFound,
              selection.location <= text.length else { return nil }

        let lineProbeLocation = min(selection.location, max(text.length - 1, 0))
        let lineRangeWithNewline = text.lineRange(for: NSRange(location: lineProbeLocation, length: 0))
        let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
        let line = text.substring(with: lineRange)
        let prefixLength = checklistPrefixLength(in: line) ?? 0
        guard lineRange.length >= prefixLength else { return nil }

        let contentRange = NSRange(
            location: lineRange.location + prefixLength,
            length: lineRange.length - prefixLength
        )
        let pinnedText = text.substring(with: contentRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pinnedText.isEmpty else { return nil }

        return (pinnedText, lineRangeWithNewline)
    }

    static func isChecklistIcon(at characterIndex: Int, in text: NSString) -> Bool {
        guard text.length > 0 else { return false }
        let clampedLocation = min(max(characterIndex, 0), max(text.length - 1, 0))
        let lineRangeWithNewline = text.lineRange(for: NSRange(location: clampedLocation, length: 0))
        let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
        guard lineRange.length > 0 else { return false }

        let line = text.substring(with: lineRange)
        guard let glyphRange = checklistGlyphRange(in: line, lineLocation: lineRange.location) else {
            return false
        }

        return NSLocationInRange(clampedLocation, glyphRange)
    }

    static func isChecklistLine(at characterIndex: Int, in text: NSString) -> Bool {
        guard text.length > 0 else { return false }
        let clampedLocation = min(max(characterIndex, 0), max(text.length - 1, 0))
        let lineRangeWithNewline = text.lineRange(for: NSRange(location: clampedLocation, length: 0))
        let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
        guard lineRange.length > 0 else { return false }
        let line = text.substring(with: lineRange)
        return checklistPrefixLength(in: line) != nil
    }

    static func containsChecklistItems(in text: NSString) -> Bool {
        guard text.length > 0 else { return false }

        var cursor = 0
        while cursor < text.length {
            let lineRangeWithNewline = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
            let line = text.substring(with: lineRange)
            if checklistPrefixLength(in: line) != nil {
                return true
            }

            let nextCursor = lineRangeWithNewline.location + lineRangeWithNewline.length
            if nextCursor <= cursor { break }
            cursor = nextCursor
        }

        return false
    }

    private static func checklistIconFontSize(for line: String) -> CGFloat {
        if line.hasPrefix(uncheckedPrefix) || line.hasPrefix(legacyUncheckedGlyphPrefix) {
            return uncheckedChecklistIconFontSize
        }
        return checkedChecklistIconFontSize
    }

    private static func applyChecklistPrefixRendering(in attributedText: NSMutableAttributedString) {
        let text = attributedText.string as NSString
        guard text.length > 0 else { return }

        var cursor = 0
        while cursor < text.length {
            let lineRangeWithNewline = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
            let line = text.substring(with: lineRange)
            if let glyphRange = checklistGlyphRange(in: line, lineLocation: lineRange.location) {
                attributedText.addAttribute(
                    .font,
                    value: UIFont.systemFont(ofSize: checklistIconFontSize(for: line), weight: .regular),
                    range: glyphRange
                )
                attributedText.addAttribute(.baselineOffset, value: -1, range: glyphRange)
                attributedText.addAttribute(.foregroundColor, value: UIColor.label, range: glyphRange)
            }

            let nextCursor = lineRangeWithNewline.location + lineRangeWithNewline.length
            if nextCursor <= cursor { break }
            cursor = nextCursor
        }
    }

    private static func normalizeLegacyPrefixes(in attributedText: NSMutableAttributedString) {
        let text = attributedText.string as NSString
        guard text.length > 0 else { return }

        var replacements: [(range: NSRange, replacement: String)] = []
        var cursor = 0
        while cursor < text.length {
            let lineRangeWithNewline = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
            let line = text.substring(with: lineRange)

            if line.hasPrefix(legacyCheckedGlyphPrefix) {
                replacements.append((NSRange(location: lineRange.location, length: legacyCheckedGlyphPrefix.utf16.count), checkedPrefix))
            } else if line.hasPrefix(legacyCheckedGlyphPrefixVariant) {
                replacements.append((NSRange(location: lineRange.location, length: legacyCheckedGlyphPrefixVariant.utf16.count), checkedPrefix))
            } else if line.hasPrefix(legacyUncheckedGlyphPrefix) {
                replacements.append((NSRange(location: lineRange.location, length: legacyUncheckedGlyphPrefix.utf16.count), uncheckedPrefix))
            } else if line.hasPrefix(legacyCheckedPrefix) {
                replacements.append((NSRange(location: lineRange.location, length: legacyCheckedPrefix.utf16.count), checkedPrefix))
            } else if line.hasPrefix(legacyUncheckedPrefix) {
                replacements.append((NSRange(location: lineRange.location, length: legacyUncheckedPrefix.utf16.count), uncheckedPrefix))
            } else if line.hasPrefix(legacyShortCheckedPrefix) {
                replacements.append((NSRange(location: lineRange.location, length: legacyShortCheckedPrefix.utf16.count), checkedPrefix))
            } else if line.hasPrefix(legacyShortUncheckedPrefix) {
                replacements.append((NSRange(location: lineRange.location, length: legacyShortUncheckedPrefix.utf16.count), uncheckedPrefix))
            }

            let nextCursor = lineRangeWithNewline.location + lineRangeWithNewline.length
            if nextCursor <= cursor { break }
            cursor = nextCursor
        }

        replacements.reversed().forEach { replacement in
            attributedText.replaceCharacters(in: replacement.range, with: replacement.replacement)
        }
    }

    private static func applyEditorParagraphStyles(in attributedText: NSMutableAttributedString) {
        let text = attributedText.string as NSString
        guard text.length > 0 else { return }
        let hasChecklistItems = containsChecklistItems(in: text)

        var cursor = 0
        while cursor < text.length {
            let lineRangeWithNewline = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
            let line = text.substring(with: lineRange)
            let paragraphStyle = checklistPrefixLength(in: line) == nil
                ? bodyParagraphStyle(hasChecklistItems: hasChecklistItems)
                : checklistParagraphStyle

            attributedText.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: lineRangeWithNewline
            )

            let nextCursor = lineRangeWithNewline.location + lineRangeWithNewline.length
            if nextCursor <= cursor { break }
            cursor = nextCursor
        }
    }

    private static func normalizedLineRange(from lineRange: NSRange, in text: NSString) -> NSRange {
        guard lineRange.length > 0 else { return lineRange }
        var length = lineRange.length
        let lastIndex = lineRange.location + lineRange.length - 1
        if lastIndex >= 0, lastIndex < text.length, text.character(at: lastIndex) == 10 {
            length -= 1
        }
        return NSRange(location: lineRange.location, length: max(length, 0))
    }

    private static func checklistPrefixLength(in line: String) -> Int? {
        if line.hasPrefix(checkedPrefix) {
            return checkedPrefix.utf16.count
        }
        if line.hasPrefix(checkedPrefixVariant) {
            return checkedPrefixVariant.utf16.count
        }
        if line.hasPrefix(uncheckedPrefix) {
            return uncheckedPrefix.utf16.count
        }
        if line.hasPrefix(legacyCheckedGlyphPrefix) {
            return legacyCheckedGlyphPrefix.utf16.count
        }
        if line.hasPrefix(legacyCheckedGlyphPrefixVariant) {
            return legacyCheckedGlyphPrefixVariant.utf16.count
        }
        if line.hasPrefix(legacyUncheckedGlyphPrefix) {
            return legacyUncheckedGlyphPrefix.utf16.count
        }
        if line.hasPrefix(legacyCheckedPrefix) {
            return legacyCheckedPrefix.utf16.count
        }
        if line.hasPrefix(legacyUncheckedPrefix) {
            return legacyUncheckedPrefix.utf16.count
        }
        if line.hasPrefix(legacyShortCheckedPrefix) {
            return legacyShortCheckedPrefix.utf16.count
        }
        if line.hasPrefix(legacyShortUncheckedPrefix) {
            return legacyShortUncheckedPrefix.utf16.count
        }
        return nil
    }

    private static func checklistGlyphRange(in line: String, lineLocation: Int) -> NSRange? {
        let prefixLength: Int
        let delimiterLength: Int
        if line.hasPrefix(checkedPrefix) {
            prefixLength = checkedPrefix.utf16.count
            delimiterLength = "\t".utf16.count
        } else if line.hasPrefix(checkedPrefixVariant) {
            prefixLength = checkedPrefixVariant.utf16.count
            delimiterLength = "\t".utf16.count
        } else if line.hasPrefix(uncheckedPrefix) {
            prefixLength = uncheckedPrefix.utf16.count
            delimiterLength = "\t".utf16.count
        } else if line.hasPrefix(legacyCheckedGlyphPrefix) {
            prefixLength = legacyCheckedGlyphPrefix.utf16.count
            delimiterLength = " ".utf16.count
        } else if line.hasPrefix(legacyCheckedGlyphPrefixVariant) {
            prefixLength = legacyCheckedGlyphPrefixVariant.utf16.count
            delimiterLength = " ".utf16.count
        } else if line.hasPrefix(legacyUncheckedGlyphPrefix) {
            prefixLength = legacyUncheckedGlyphPrefix.utf16.count
            delimiterLength = " ".utf16.count
        } else {
            return nil
        }

        return NSRange(
            location: lineLocation,
            length: max(prefixLength - delimiterLength, 0)
        )
    }
}
