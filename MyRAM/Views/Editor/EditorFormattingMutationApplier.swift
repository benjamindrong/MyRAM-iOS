import UIKit

enum EditorFormattingMutationApplier {
    static func applyingTraitPlan(
        _ plan: EditorFormattingTraitPlan,
        to attributedText: NSAttributedString,
        fallbackFont: UIFont
    ) -> NSMutableAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        guard isValidSelectedRange(plan.range, in: mutable) else { return mutable }

        mutable.enumerateAttribute(.font, in: plan.range) { value, range, _ in
            let baseFont = value as? UIFont ?? fallbackFont
            mutable.addAttribute(
                .font,
                value: EditorFormattingCommandResolver.fontBySettingTrait(
                    on: baseFont,
                    trait: plan.trait,
                    isEnabled: plan.shouldApply
                ),
                range: range
            )
        }
        return mutable
    }

    static func applyingTraitPlan(
        _ plan: EditorFormattingTraitPlan,
        to typingAttributes: [NSAttributedString.Key: Any],
        fallbackFont: UIFont
    ) -> [NSAttributedString.Key: Any] {
        var updatedAttributes = typingAttributes
        let baseFont = typingAttributes[.font] as? UIFont ?? fallbackFont
        updatedAttributes[.font] = EditorFormattingCommandResolver.fontBySettingTrait(
            on: baseFont,
            trait: plan.trait,
            isEnabled: plan.shouldApply
        )
        return updatedAttributes
    }

    static func applyingDecorationPlan(
        _ plan: EditorFormattingDecorationPlan,
        to attributedText: NSAttributedString
    ) -> NSMutableAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        guard isValidSelectedRange(plan.range, in: mutable) else { return mutable }

        let value = plan.shouldApply ? NSUnderlineStyle.single.rawValue : 0
        mutable.addAttribute(plan.styleKey, value: value, range: plan.range)
        guard let colorKey = plan.colorKey else { return mutable }

        if plan.shouldApply {
            mutable.enumerateAttribute(.foregroundColor, in: plan.range) { foregroundColor, range, _ in
                if let foregroundColor {
                    mutable.addAttribute(colorKey, value: foregroundColor, range: range)
                } else {
                    mutable.removeAttribute(colorKey, range: range)
                }
            }
        } else {
            mutable.removeAttribute(colorKey, range: plan.range)
        }
        return mutable
    }

    static func applyingDecorationPlan(
        _ plan: EditorFormattingDecorationPlan,
        to typingAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var updatedAttributes = typingAttributes
        updatedAttributes[plan.styleKey] = plan.shouldApply ? NSUnderlineStyle.single.rawValue : 0
        if let colorKey = plan.colorKey {
            if plan.shouldApply, let color = typingAttributes[.foregroundColor] as? UIColor {
                updatedAttributes[colorKey] = color
            } else {
                updatedAttributes.removeValue(forKey: colorKey)
            }
        }
        return updatedAttributes
    }

    static func applyingFontSizePlan(
        _ plan: EditorFormattingFontSizePlan,
        to attributedText: NSAttributedString,
        fallbackFont: UIFont
    ) -> NSMutableAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        guard isValidSelectedRange(plan.range, in: mutable) else { return mutable }

        mutable.enumerateAttribute(.font, in: plan.range) { value, range, _ in
            let baseFont = value as? UIFont ?? fallbackFont
            mutable.addAttribute(
                .font,
                value: EditorFormattingCommandResolver.adjustedFontSize(
                    from: baseFont,
                    delta: plan.delta
                ),
                range: range
            )
        }
        return mutable
    }

    static func applyingFontSizePlan(
        _ plan: EditorFormattingFontSizePlan,
        to typingAttributes: [NSAttributedString.Key: Any],
        fallbackFont: UIFont
    ) -> [NSAttributedString.Key: Any] {
        var updatedAttributes = typingAttributes
        let baseFont = typingAttributes[.font] as? UIFont ?? fallbackFont
        updatedAttributes[.font] = EditorFormattingCommandResolver.adjustedFontSize(
            from: baseFont,
            delta: plan.delta
        )
        return updatedAttributes
    }

    static func applyingColorPlan(
        _ plan: EditorFormattingColorPlan,
        to attributedText: NSAttributedString,
        defaultTextColor: UIColor,
        fallbackTextColor: UIColor?
    ) -> NSMutableAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        guard isValidSelectedRange(plan.range, in: mutable) else { return mutable }

        if plan.usesDefaultColor {
            mutable.addAttribute(.foregroundColor, value: defaultTextColor, range: plan.range)
            mutable.addAttribute(.autoTextColorDisplay, value: true, range: plan.range)
            syncDecorationColorsWithForeground(in: mutable, range: plan.range, color: defaultTextColor)
        } else {
            let resolvedColor = plan.color ?? fallbackTextColor ?? defaultTextColor
            mutable.addAttribute(.foregroundColor, value: resolvedColor, range: plan.range)
            mutable.removeAttribute(.autoTextColorDisplay, range: plan.range)
            syncDecorationColorsWithForeground(in: mutable, range: plan.range, color: resolvedColor)
        }
        return mutable
    }

    static func applyingColorPlan(
        _ plan: EditorFormattingColorPlan,
        to typingAttributes: [NSAttributedString.Key: Any],
        defaultTextColor: UIColor,
        fallbackTextColor: UIColor?
    ) -> [NSAttributedString.Key: Any] {
        var updatedAttributes = typingAttributes
        if plan.usesDefaultColor {
            // Auto uses a display color live; storage removes the marker later.
            updatedAttributes[.foregroundColor] = defaultTextColor
            updatedAttributes[.autoTextColorDisplay] = true
            syncDecorationColorsWithForeground(in: &updatedAttributes, color: defaultTextColor)
        } else {
            let resolvedColor = plan.color ?? fallbackTextColor ?? defaultTextColor
            updatedAttributes[.foregroundColor] = resolvedColor
            updatedAttributes.removeValue(forKey: .autoTextColorDisplay)
            syncDecorationColorsWithForeground(in: &updatedAttributes, color: resolvedColor)
        }
        return updatedAttributes
    }

    static func syncDecorationColorsWithForeground(
        in typingAttributes: inout [NSAttributedString.Key: Any],
        color: UIColor?
    ) {
        syncDecorationColor(
            in: &typingAttributes,
            styleKey: .underlineStyle,
            colorKey: .underlineColor,
            color: color
        )
        syncDecorationColor(
            in: &typingAttributes,
            styleKey: .strikethroughStyle,
            colorKey: .strikethroughColor,
            color: color
        )
    }

    static func syncDecorationColorsWithForeground(
        in attributedText: NSMutableAttributedString,
        range: NSRange,
        color: UIColor?
    ) {
        guard isValidSelectedRange(range, in: attributedText) else { return }

        syncDecorationColor(
            in: attributedText,
            range: range,
            styleKey: .underlineStyle,
            colorKey: .underlineColor,
            color: color
        )
        syncDecorationColor(
            in: attributedText,
            range: range,
            styleKey: .strikethroughStyle,
            colorKey: .strikethroughColor,
            color: color
        )
    }

    private static func syncDecorationColor(
        in typingAttributes: inout [NSAttributedString.Key: Any],
        styleKey: NSAttributedString.Key,
        colorKey: NSAttributedString.Key,
        color: UIColor?
    ) {
        let style = typingAttributes[styleKey] as? Int ?? 0
        guard style != 0 else {
            typingAttributes.removeValue(forKey: colorKey)
            return
        }

        if let color {
            typingAttributes[colorKey] = color
        } else {
            typingAttributes.removeValue(forKey: colorKey)
        }
    }

    private static func syncDecorationColor(
        in attributedText: NSMutableAttributedString,
        range: NSRange,
        styleKey: NSAttributedString.Key,
        colorKey: NSAttributedString.Key,
        color: UIColor?
    ) {
        attributedText.enumerateAttribute(styleKey, in: range) { value, range, _ in
            let style = value as? Int ?? 0
            guard style != 0 else {
                attributedText.removeAttribute(colorKey, range: range)
                return
            }

            if let color {
                attributedText.addAttribute(colorKey, value: color, range: range)
            } else {
                attributedText.removeAttribute(colorKey, range: range)
            }
        }
    }

    private static func isValidSelectedRange(_ range: NSRange, in attributedText: NSAttributedString) -> Bool {
        guard range.location != NSNotFound,
              range.length > 0,
              range.location <= attributedText.length else {
            return false
        }
        return range.length <= attributedText.length - range.location
    }
}
