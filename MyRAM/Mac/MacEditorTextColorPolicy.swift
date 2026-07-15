#if os(macOS)
import AppKit

enum MacEditorTextColorPolicy {
    static func normalizedForDisplay(
        _ attributedText: NSAttributedString,
        defaultTextColor: NSColor = .textColor
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let isAuto = (attributes[.autoTextColorDisplay] as? Bool) == true
            if attributes[.foregroundColor] == nil || isAuto {
                mutable.addAttribute(.foregroundColor, value: defaultTextColor, range: range)
                mutable.addAttribute(.autoTextColorDisplay, value: true, range: range)
            }
        }
        return mutable
    }

    static func sanitizedForPersistence(_ attributedText: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.autoTextColorDisplay, in: fullRange) { value, range, _ in
            guard (value as? Bool) == true else { return }
            mutable.removeAttribute(.foregroundColor, range: range)
            mutable.removeAttribute(.autoTextColorDisplay, range: range)
        }
        return mutable
    }

    static func normalizedTypingAttributes(
        _ attributes: [NSAttributedString.Key: Any],
        defaultTextColor: NSColor = .textColor
    ) -> [NSAttributedString.Key: Any] {
        var normalized = attributes
        let isAuto = (attributes[.autoTextColorDisplay] as? Bool) == true
        if attributes[.foregroundColor] == nil || isAuto {
            normalized[.foregroundColor] = defaultTextColor
            normalized[.autoTextColorDisplay] = true
        }
        return normalized
    }
}
#endif
