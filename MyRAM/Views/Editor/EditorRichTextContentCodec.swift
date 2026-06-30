import UIKit

enum RichTextContentCodec {
    static func decode(
        richTextData: Data?,
        plainText: String,
        baseFont: UIFont
    ) -> NSAttributedString {
        if let richTextData,
           let attributedText = try? NSAttributedString(
            data: richTextData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            return attributedText
        }
        return NSAttributedString(
            string: plainText,
            attributes: [.font: baseFont]
        )
    }

    static func encode(_ attributedText: NSAttributedString) -> Data? {
        RTFCoding.encode(attributedText)
    }

    static func normalizedForDisplay(
        _ attributedText: NSAttributedString,
        traitCollection: UITraitCollection,
        defaultTextColor: UIColor = .label
    ) -> NSAttributedString {
        // Preserve explicit colors exactly. Missing foreground means Auto, so
        // paint it with the current editor default for display only; syncContent
        // strips that default color back out before saving/syncing.
        _ = traitCollection
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            guard value == nil else { return }
            mutable.addAttribute(.foregroundColor, value: defaultTextColor, range: range)
            mutable.addAttribute(.autoTextColorDisplay, value: true, range: range)
        }
        return mutable
    }

    static func sanitizedConflictRichTextData(_ richTextData: Data?, plainText: String) -> Data? {
        guard let richTextData,
              let attributedText = try? NSAttributedString(
                data: richTextData,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ),
              let compatibleText = attributedText.compatibleConflictText(matching: plainText) else { return nil }
        let mutable = NSMutableAttributedString(attributedString: compatibleText)
        let fullRange = NSRange(location: 0, length: mutable.length)
        stripLegacyDefaultTextColors(from: mutable, range: fullRange)
        return encode(mutable)
    }

    private static func stripLegacyDefaultTextColors(from attributedText: NSMutableAttributedString, range: NSRange) {
        attributedText.enumerateAttribute(.foregroundColor, in: range) { value, range, _ in
            guard let color = value as? UIColor,
                  color.looksLikeLegacyDefaultTextColor else { return }
            attributedText.removeAttribute(.foregroundColor, range: range)
        }
        stripLegacyDefaultDecorationColor(.underlineColor, from: attributedText, range: range)
        stripLegacyDefaultDecorationColor(.strikethroughColor, from: attributedText, range: range)
    }

    private static func stripLegacyDefaultDecorationColor(
        _ key: NSAttributedString.Key,
        from attributedText: NSMutableAttributedString,
        range: NSRange
    ) {
        attributedText.enumerateAttribute(key, in: range) { value, range, _ in
            guard let color = value as? UIColor,
                  color.looksLikeLegacyDefaultTextColor else { return }
            attributedText.removeAttribute(key, range: range)
        }
    }
}

private extension NSAttributedString {
    func compatibleConflictText(matching plainText: String) -> NSAttributedString? {
        guard string != plainText else { return self }
        let nsString = string as NSString
        let nsPlainLength = (plainText as NSString).length
        guard nsString.length > nsPlainLength else { return nil }
        guard nsString.substring(to: nsPlainLength) == plainText else { return nil }

        let extraTrailingText = nsString.substring(from: nsPlainLength)
        guard extraTrailingText.isDocumentBoundaryWhitespace else { return nil }

        // Only document-boundary serialization whitespace is safe to trim; any
        // interior difference must fail instead of remapping formatting.
        let mutable = NSMutableAttributedString(attributedString: self)
        let extraTrailingRange = NSRange(
            location: nsPlainLength,
            length: nsString.length - nsPlainLength
        )
        mutable.deleteCharacters(in: extraTrailingRange)

        let matchesResolvedPlainText = mutable.string == plainText
        assert(
            matchesResolvedPlainText,
            "compatibleConflictText range arithmetic produced wrong result"
        )
        guard matchesResolvedPlainText else { return nil }
        return mutable
    }
}

private extension String {
    var isDocumentBoundaryWhitespace: Bool {
        self == "\n"
            || (!isEmpty && unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) })
    }
}

enum EditorColorComparison {
    static func isApproximatelyEqual(_ color: UIColor, to other: UIColor) -> Bool {
        guard let lhs = color.rgbaComponents,
              let rhs = other.rgbaComponents else {
            return false
        }

        return abs(lhs.red - rhs.red) <= 0.02
            && abs(lhs.green - rhs.green) <= 0.02
            && abs(lhs.blue - rhs.blue) <= 0.02
            && abs(lhs.alpha - rhs.alpha) <= 0.02
    }

}

private extension UIColor {
    var looksLikeLegacyDefaultTextColor: Bool {
        guard let components = rgbaComponents, components.alpha > 0.6 else { return false }
        return components.saturation <= 0.08
            && (components.luminance <= 0.42 || components.luminance >= 0.58)
    }

    var rgbaComponents: EditorRGBAComponents? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return EditorRGBAComponents(red: red, green: green, blue: blue, alpha: alpha)
        }

        var white: CGFloat = 0
        if getWhite(&white, alpha: &alpha) {
            return EditorRGBAComponents(red: white, green: white, blue: white, alpha: alpha)
        }

        let ciColor = CIColor(color: self)
        return EditorRGBAComponents(red: ciColor.red, green: ciColor.green, blue: ciColor.blue, alpha: ciColor.alpha)
    }
}

extension NSAttributedString.Key {
    static let autoTextColorDisplay = NSAttributedString.Key("com.myram.autoTextColorDisplay")
}

private struct EditorRGBAComponents {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    var luminance: CGFloat {
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    var saturation: CGFloat {
        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        guard maxComponent > 0 else { return 0 }
        return (maxComponent - minComponent) / maxComponent
    }
}
