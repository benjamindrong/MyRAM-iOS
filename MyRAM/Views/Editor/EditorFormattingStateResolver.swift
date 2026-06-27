import UIKit
import os

struct EditorFormattingState: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var fontSize: CGFloat = EditorTypography.defaultTextFont.pointSize
    var foregroundColor: UIColor?
}

struct EditorSelectionFormattingCache {
    var range = NSRange(location: 0, length: 0)
    var formattingState: EditorFormattingState?
    var formattingStateIsDirty = true
    var formattingStateIsApproximate = false

    mutating func markDirty(range: NSRange) {
        self.range = range
        formattingStateIsDirty = true
    }

    mutating func update(range: NSRange, formattingState: EditorFormattingState, isApproximate: Bool) {
        self.range = range
        self.formattingState = formattingState
        formattingStateIsDirty = false
        formattingStateIsApproximate = isApproximate
    }
}

enum EditorFormattingStateResolver {
    // The coordinator owns effective selection resolution; this helper only derives formatting state.
    static func formattingState(
        from textView: UITextView,
        selectedRange: NSRange,
        cache: inout EditorSelectionFormattingCache,
        allowsLargeSelectionScan: Bool = false
    ) -> EditorFormattingState {
        let formattingStateSignpostID = OSSignpostID(log: EditorSelectionProfiling.log)
        os_signpost(
            .begin,
            log: EditorSelectionProfiling.log,
            name: "EditorFormattingStateResolver.formattingState",
            signpostID: formattingStateSignpostID
        )
        defer {
            os_signpost(
                .end,
                log: EditorSelectionProfiling.log,
                name: "EditorFormattingStateResolver.formattingState",
                signpostID: formattingStateSignpostID
            )
        }

        return formattingState(
            attributedText: textView.attributedText,
            selectedRange: selectedRange,
            typingAttributes: textView.typingAttributes,
            fallbackFont: textView.font,
            allowsLargeSelectionScan: allowsLargeSelectionScan,
            cache: &cache
        )
    }

    static func formattingState(
        attributedText: NSAttributedString,
        selectedRange: NSRange,
        typingAttributes: [NSAttributedString.Key: Any],
        fallbackFont: UIFont?,
        allowsLargeSelectionScan: Bool,
        cache: inout EditorSelectionFormattingCache
    ) -> EditorFormattingState {
        let usesLargeSelectionPath = EditorSelectionFormattingPolicy
            .shouldDeferFullFormattingScan(selectionLength: selectedRange.length)
        let needsFullState = usesLargeSelectionPath && allowsLargeSelectionScan
        if let cachedState = cache.formattingState,
           !cache.formattingStateIsDirty,
           NSEqualRanges(cache.range, selectedRange),
           !(needsFullState && cache.formattingStateIsApproximate) {
            return cachedState
        }

        let state: EditorFormattingState
        let isApproximate: Bool
        if usesLargeSelectionPath && !allowsLargeSelectionScan {
            state = approximateFormattingState(
                attributedText: attributedText,
                range: selectedRange,
                typingAttributes: typingAttributes,
                fallbackFont: fallbackFont
            )
            isApproximate = true
        } else {
            state = fullFormattingState(
                attributedText: attributedText,
                range: selectedRange,
                typingAttributes: typingAttributes,
                fallbackFont: fallbackFont
            )
            isApproximate = false
        }
        cache.update(range: selectedRange, formattingState: state, isApproximate: isApproximate)
        return state
    }

    private static func fullFormattingState(
        attributedText: NSAttributedString,
        range: NSRange,
        typingAttributes: [NSAttributedString.Key: Any],
        fallbackFont: UIFont?
    ) -> EditorFormattingState {
        let font = selectedFont(
            in: attributedText,
            range: range,
            typingAttributes: typingAttributes,
            fallbackFont: fallbackFont
        )
        let foregroundColor = selectedForegroundColor(
            in: attributedText,
            range: range,
            typingAttributes: typingAttributes
        )
        return EditorFormattingState(
            bold: hasTrait(
                .traitBold,
                in: attributedText,
                range: range,
                typingAttributes: typingAttributes,
                fallbackFont: fallbackFont
            ),
            italic: hasTrait(
                .traitItalic,
                in: attributedText,
                range: range,
                typingAttributes: typingAttributes,
                fallbackFont: fallbackFont
            ),
            underline: hasDecoration(
                .underlineStyle,
                in: attributedText,
                range: range,
                typingAttributes: typingAttributes
            ),
            strikethrough: hasDecoration(
                .strikethroughStyle,
                in: attributedText,
                range: range,
                typingAttributes: typingAttributes
            ),
            fontSize: font.pointSize,
            foregroundColor: foregroundColor
        )
    }

    private static func approximateFormattingState(
        attributedText: NSAttributedString,
        range: NSRange,
        typingAttributes: [NSAttributedString.Key: Any],
        fallbackFont: UIFont?
    ) -> EditorFormattingState {
        let font = selectedFont(
            in: attributedText,
            range: range,
            typingAttributes: typingAttributes,
            fallbackFont: fallbackFont
        )
        let foregroundColor = selectedForegroundColor(
            in: attributedText,
            range: range,
            typingAttributes: typingAttributes
        )
        return EditorFormattingState(
            bold: approximateTrait(
                .traitBold,
                in: attributedText,
                range: range,
                typingAttributes: typingAttributes,
                fallbackFont: fallbackFont
            ),
            italic: approximateTrait(
                .traitItalic,
                in: attributedText,
                range: range,
                typingAttributes: typingAttributes,
                fallbackFont: fallbackFont
            ),
            underline: approximateDecoration(
                .underlineStyle,
                in: attributedText,
                range: range,
                typingAttributes: typingAttributes
            ),
            strikethrough: approximateDecoration(
                .strikethroughStyle,
                in: attributedText,
                range: range,
                typingAttributes: typingAttributes
            ),
            fontSize: font.pointSize,
            foregroundColor: foregroundColor
        )
    }

    private static func approximateTrait(
        _ trait: UIFontDescriptor.SymbolicTraits,
        in attributedText: NSAttributedString,
        range: NSRange,
        typingAttributes: [NSAttributedString.Key: Any],
        fallbackFont: UIFont?
    ) -> Bool {
        let font = selectedFont(
            in: attributedText,
            range: range,
            typingAttributes: typingAttributes,
            fallbackFont: fallbackFont
        )
        return font.fontDescriptor.symbolicTraits.contains(trait)
    }

    private static func approximateDecoration(
        _ key: NSAttributedString.Key,
        in attributedText: NSAttributedString,
        range: NSRange,
        typingAttributes: [NSAttributedString.Key: Any]
    ) -> Bool {
        if range.length == 0 {
            return (typingAttributes[key] as? Int ?? 0) != 0
        }
        if range.location < attributedText.length {
            return (attributedText.attribute(key, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        }
        return false
    }

    private static func selectedFont(
        in attributedText: NSAttributedString,
        range: NSRange,
        typingAttributes: [NSAttributedString.Key: Any],
        fallbackFont: UIFont?
    ) -> UIFont {
        if range.length == 0 {
            return (typingAttributes[.font] as? UIFont)
                ?? fallbackFont
                ?? EditorTypography.defaultTextFont
        }
        if range.location < attributedText.length,
           let font = attributedText.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont {
            return font
        }
        return fallbackFont ?? EditorTypography.defaultTextFont
    }

    private static func selectedForegroundColor(
        in attributedText: NSAttributedString,
        range: NSRange,
        typingAttributes: [NSAttributedString.Key: Any]
    ) -> UIColor? {
        if range.length == 0 {
            return typingAttributes[.foregroundColor] as? UIColor
        }
        if range.location < attributedText.length {
            return attributedText.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
        }
        return nil
    }

    private static func hasTrait(
        _ trait: UIFontDescriptor.SymbolicTraits,
        in attributedText: NSAttributedString,
        range: NSRange,
        typingAttributes: [NSAttributedString.Key: Any],
        fallbackFont: UIFont?
    ) -> Bool {
        if range.length == 0 {
            let font = (typingAttributes[.font] as? UIFont)
                ?? fallbackFont
                ?? EditorTypography.defaultTextFont
            return font.fontDescriptor.symbolicTraits.contains(trait)
        }

        var hasAll = true
        attributedText.enumerateAttribute(.font, in: range) { value, _, stop in
            let font = value as? UIFont ?? EditorTypography.defaultTextFont
            if !font.fontDescriptor.symbolicTraits.contains(trait) {
                hasAll = false
                stop.pointee = true
            }
        }
        return hasAll
    }

    private static func hasDecoration(
        _ key: NSAttributedString.Key,
        in attributedText: NSAttributedString,
        range: NSRange,
        typingAttributes: [NSAttributedString.Key: Any]
    ) -> Bool {
        if range.length == 0 {
            return (typingAttributes[key] as? Int ?? 0) != 0
        }

        var hasAll = true
        attributedText.enumerateAttribute(key, in: range) { value, _, stop in
            if (value as? Int ?? 0) == 0 {
                hasAll = false
                stop.pointee = true
            }
        }
        return hasAll
    }
}
