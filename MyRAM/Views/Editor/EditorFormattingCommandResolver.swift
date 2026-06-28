import UIKit

// Plans describe formatting intent only; the editor coordinator owns every mutation side effect.
enum EditorFormattingCommandPlan: Equatable {
    case trait(EditorFormattingTraitPlan)
    case decoration(EditorFormattingDecorationPlan)
    case fontSize(EditorFormattingFontSizePlan)
    case color(EditorFormattingColorPlan)
}

struct EditorFormattingTraitPlan: Equatable {
    let range: NSRange
    let trait: UIFontDescriptor.SymbolicTraits
    let shouldApply: Bool
}

struct EditorFormattingDecorationPlan: Equatable {
    let range: NSRange
    let styleKey: NSAttributedString.Key
    let colorKey: NSAttributedString.Key?
    let shouldApply: Bool
}

struct EditorFormattingFontSizePlan: Equatable {
    let range: NSRange
    let delta: CGFloat
}

struct EditorFormattingColorPlan: Equatable {
    let range: NSRange
    let color: UIColor?
    let usesDefaultColor: Bool
}

enum EditorFormattingCommandResolver {
    static let minimumFontSize: CGFloat = 11
    static let maximumFontSize: CGFloat = 40

    static func traitPlan(
        in attributedText: NSAttributedString,
        range: NSRange,
        trait: UIFontDescriptor.SymbolicTraits
    ) -> EditorFormattingCommandPlan {
        .trait(EditorFormattingTraitPlan(
            range: range,
            trait: trait,
            shouldApply: shouldApplyFontTrait(in: attributedText, range: range, trait: trait)
        ))
    }

    static func collapsedTraitPlan(
        range: NSRange,
        baseFont: UIFont,
        trait: UIFontDescriptor.SymbolicTraits
    ) -> EditorFormattingCommandPlan {
        .trait(EditorFormattingTraitPlan(
            range: range,
            trait: trait,
            shouldApply: !baseFont.fontDescriptor.symbolicTraits.contains(trait)
        ))
    }

    static func shouldApplyFontTrait(
        in attributedText: NSAttributedString,
        range: NSRange,
        trait: UIFontDescriptor.SymbolicTraits
    ) -> Bool {
        var hasTraitMissing = false
        attributedText.enumerateAttribute(.font, in: range) { value, _, stop in
            let font = value as? UIFont ?? EditorTypography.defaultTextFont
            if !font.fontDescriptor.symbolicTraits.contains(trait) {
                hasTraitMissing = true
                stop.pointee = true
            }
        }
        return hasTraitMissing
    }

    static func fontBySettingTrait(
        on baseFont: UIFont,
        trait: UIFontDescriptor.SymbolicTraits,
        isEnabled: Bool
    ) -> UIFont {
        var traits = baseFont.fontDescriptor.symbolicTraits
        if isEnabled {
            traits.insert(trait)
        } else {
            traits.remove(trait)
        }

        if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: baseFont.pointSize)
        }

        let systemDescriptor = UIFont.systemFont(ofSize: baseFont.pointSize).fontDescriptor
        if let descriptor = systemDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: baseFont.pointSize)
        }

        if trait == .traitBold {
            if isEnabled {
                return UIFont.boldSystemFont(ofSize: baseFont.pointSize)
            }
            if traits.contains(.traitItalic) {
                return UIFont.italicSystemFont(ofSize: baseFont.pointSize)
            }
            return UIFont.systemFont(ofSize: baseFont.pointSize)
        }

        if trait == .traitItalic {
            if isEnabled {
                return UIFont.italicSystemFont(ofSize: baseFont.pointSize)
            }
            if traits.contains(.traitBold) {
                return UIFont.boldSystemFont(ofSize: baseFont.pointSize)
            }
            return UIFont.systemFont(ofSize: baseFont.pointSize)
        }

        return baseFont
    }

    static func fontSizePlan(range: NSRange, delta: CGFloat) -> EditorFormattingCommandPlan {
        .fontSize(EditorFormattingFontSizePlan(range: range, delta: delta))
    }

    static func adjustedFontSize(from baseFont: UIFont, delta: CGFloat) -> UIFont {
        let newPointSize = min(max(baseFont.pointSize + delta, minimumFontSize), maximumFontSize)
        return UIFont(descriptor: baseFont.fontDescriptor, size: newPointSize)
    }

    static func decorationPlan(
        in attributedText: NSAttributedString,
        range: NSRange,
        key: NSAttributedString.Key
    ) -> EditorFormattingCommandPlan {
        .decoration(EditorFormattingDecorationPlan(
            range: range,
            styleKey: key,
            colorKey: decorationColorKey(for: key),
            shouldApply: shouldApplyDecoration(in: attributedText, range: range, key: key)
        ))
    }

    static func collapsedDecorationPlan(
        range: NSRange,
        key: NSAttributedString.Key,
        currentValue: Int
    ) -> EditorFormattingCommandPlan {
        .decoration(EditorFormattingDecorationPlan(
            range: range,
            styleKey: key,
            colorKey: decorationColorKey(for: key),
            shouldApply: currentValue == 0
        ))
    }

    static func decorationColorKey(for key: NSAttributedString.Key) -> NSAttributedString.Key? {
        switch key {
        case .underlineStyle:
            return .underlineColor
        case .strikethroughStyle:
            return .strikethroughColor
        default:
            return nil
        }
    }

    static func shouldApplyDecoration(
        in attributedText: NSAttributedString,
        range: NSRange,
        key: NSAttributedString.Key
    ) -> Bool {
        var hasUndecoratedSegment = false
        attributedText.enumerateAttribute(key, in: range) { value, _, stop in
            let style = value as? Int ?? 0
            if style == 0 {
                hasUndecoratedSegment = true
                stop.pointee = true
            }
        }
        return hasUndecoratedSegment
    }

    static func colorPlan(
        range: NSRange,
        color: UIColor?,
        usesDefaultColor: Bool
    ) -> EditorFormattingCommandPlan {
        .color(EditorFormattingColorPlan(
            range: range,
            color: color,
            usesDefaultColor: usesDefaultColor
        ))
    }
}
