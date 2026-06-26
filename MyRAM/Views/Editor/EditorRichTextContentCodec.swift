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
        guard attributedText.length > 0 else { return nil }
        return try? attributedText.data(
            from: NSRange(location: 0, length: attributedText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
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
              attributedText.string == plainText else { return nil }
        let mutable = NSMutableAttributedString(attributedString: attributedText)
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

extension UIColor {
    func isApproximatelyEqual(to other: UIColor) -> Bool {
        guard let lhs = rgbaComponents,
              let rhs = other.rgbaComponents else {
            return false
        }

        return abs(lhs.red - rhs.red) <= 0.02
            && abs(lhs.green - rhs.green) <= 0.02
            && abs(lhs.blue - rhs.blue) <= 0.02
            && abs(lhs.alpha - rhs.alpha) <= 0.02
    }

    var looksLikeLegacyDefaultTextColor: Bool {
        guard let components = rgbaComponents, components.alpha > 0.6 else { return false }
        return components.saturation <= 0.08
            && (components.luminance <= 0.42 || components.luminance >= 0.58)
    }

    private var rgbaComponents: RGBAComponents? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return RGBAComponents(red: red, green: green, blue: blue, alpha: alpha)
        }

        var white: CGFloat = 0
        if getWhite(&white, alpha: &alpha) {
            return RGBAComponents(red: white, green: white, blue: white, alpha: alpha)
        }

        let ciColor = CIColor(color: self)
        return RGBAComponents(red: ciColor.red, green: ciColor.green, blue: ciColor.blue, alpha: ciColor.alpha)
    }
}

extension NSAttributedString.Key {
    static let autoTextColorDisplay = NSAttributedString.Key("com.myram.autoTextColorDisplay")
}

struct RGBAComponents {
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
