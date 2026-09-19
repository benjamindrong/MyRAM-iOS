import AnchoredSequenceCore
import UIKit

@MainActor
enum EditorStructuralFormattingAdapter {
    static func project(
        _ attributedText: NSAttributedString,
        baseBodyFont: UIFont,
        traitCollection: UITraitCollection
    ) -> NoteStructuralFormattingProjection {
        guard attributedText.length > 0 else {
            return NoteStructuralFormattingProjection(
                plainText: attributedText.string,
                runs: []
            )
        }

        var runs: [NoteStructuralFormattingProjectionRun] = []
        let fullRange = NSRange(location: 0, length: attributedText.length)
        attributedText.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let font = attributes[.font] as? UIFont ?? baseBodyFont
            let traits = font.fontDescriptor.symbolicTraits
            let fontSize = canonicalFontSizeAssignment(
                attributes: attributes,
                font: font,
                baseBodyFont: baseBodyFont
            )
            let color = canonicalColorAssignment(
                attributes: attributes,
                traitCollection: traitCollection
            )

            runs.append(NoteStructuralFormattingProjectionRun(
                startUTF16Offset: range.location,
                utf16Length: range.length,
                assignments: [
                    .bold: traits.contains(.traitBold) ? .enabled : .clear,
                    .italic: traits.contains(.traitItalic) ? .enabled : .clear,
                    .underline: decorationEnabled(
                        attributes[.underlineStyle]
                    ) ? .enabled : .clear,
                    .strikethrough: decorationEnabled(
                        attributes[.strikethroughStyle]
                    ) ? .enabled : .clear,
                    .fontSize: fontSize,
                    .textColor: color
                ]
            ))
        }

        return NoteStructuralFormattingProjection(
            plainText: attributedText.string,
            runs: runs
        )
    }

    static func render(
        sequence: SyncTextSequenceState,
        marks: SyncTextMarkState,
        baseBodyFont: UIFont,
        traitCollection: UITraitCollection
    ) throws -> NSAttributedString {
        _ = traitCollection
        let mutable = NSMutableAttributedString(
            string: sequence.visibleText,
            attributes: [.font: baseBodyFont]
        )
        for span in try marks.visibleProjection(in: sequence) {
            let range = NSRange(
                location: span.startUTF16Offset,
                length: span.utf16Length
            )
            let bold = span.assignments[.bold] == .enabled
            let italic = span.assignments[.italic] == .enabled
            let fontSizeAssignment = span.assignments[.fontSize] ?? .clear

            var traits = baseBodyFont.fontDescriptor.symbolicTraits
            traits.remove([.traitBold, .traitItalic])
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }
            let descriptor = baseBodyFont.fontDescriptor.withSymbolicTraits(traits)
                ?? baseBodyFont.fontDescriptor
            let pointSize: CGFloat
            if case .fontSizeMilliPoints(let milliPoints) = fontSizeAssignment {
                pointSize = CGFloat(milliPoints) / 1_000
            } else {
                pointSize = baseBodyFont.pointSize
            }
            mutable.addAttribute(
                .font,
                value: UIFont(descriptor: descriptor, size: pointSize),
                range: range
            )

            if case .fontSizeMilliPoints(let milliPoints) = fontSizeAssignment {
                mutable.addAttribute(
                    .explicitStructuralFontSizeMilliPoints,
                    value: milliPoints,
                    range: range
                )
            }
            if span.assignments[.underline] == .enabled {
                mutable.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
            if span.assignments[.strikethrough] == .enabled {
                mutable.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
            if case .textColor(let rgba) = span.assignments[.textColor] {
                mutable.addAttribute(
                    .foregroundColor,
                    value: UIColor(
                        red: CGFloat(rgba.red) / 255,
                        green: CGFloat(rgba.green) / 255,
                        blue: CGFloat(rgba.blue) / 255,
                        alpha: CGFloat(rgba.alpha) / 255
                    ),
                    range: range
                )
            }
        }
        return mutable
    }

    static func render(
        projection: NoteStructuralFormattingProjection,
        baseBodyFont: UIFont,
        traitCollection: UITraitCollection
    ) -> NSAttributedString {
        _ = traitCollection
        let mutable = NSMutableAttributedString(
            string: projection.plainText,
            attributes: [.font: baseBodyFont]
        )
        for run in projection.runs {
            let range = NSRange(
                location: run.startUTF16Offset,
                length: run.utf16Length
            )
            guard range.location >= 0,
                  range.length > 0,
                  range.location <= mutable.length,
                  range.length <= mutable.length - range.location else {
                continue
            }

            let assignments = run.assignments
            var traits = baseBodyFont.fontDescriptor.symbolicTraits
            traits.remove([.traitBold, .traitItalic])
            if assignments[.bold] == .enabled { traits.insert(.traitBold) }
            if assignments[.italic] == .enabled { traits.insert(.traitItalic) }
            let descriptor = baseBodyFont.fontDescriptor.withSymbolicTraits(traits)
                ?? baseBodyFont.fontDescriptor

            let sizeAssignment = assignments[.fontSize] ?? .clear
            let pointSize: CGFloat
            if case .fontSizeMilliPoints(let milliPoints) = sizeAssignment {
                pointSize = CGFloat(milliPoints) / 1_000
            } else {
                pointSize = baseBodyFont.pointSize
            }
            mutable.addAttribute(
                .font,
                value: UIFont(descriptor: descriptor, size: pointSize),
                range: range
            )
            if case .fontSizeMilliPoints(let milliPoints) = sizeAssignment {
                mutable.addAttribute(
                    .explicitStructuralFontSizeMilliPoints,
                    value: milliPoints,
                    range: range
                )
            }

            if assignments[.underline] == .enabled {
                mutable.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
            if assignments[.strikethrough] == .enabled {
                mutable.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
            if case .textColor(let rgba) = assignments[.textColor] {
                mutable.addAttribute(
                    .foregroundColor,
                    value: UIColor(
                        red: CGFloat(rgba.red) / 255,
                        green: CGFloat(rgba.green) / 255,
                        blue: CGFloat(rgba.blue) / 255,
                        alpha: CGFloat(rgba.alpha) / 255
                    ),
                    range: range
                )
            }
        }
        return mutable
    }

    static func strictLegacyProjection(
        data: Data,
        baseBodyFont: UIFont,
        traitCollection: UITraitCollection
    ) -> NoteStructuralFormattingProjection? {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.rtf
            ],
            documentAttributes: nil
        ) else {
            return nil
        }
        return project(
            attributed,
            baseBodyFont: baseBodyFont,
            traitCollection: traitCollection
        )
    }

    private static func canonicalFontSizeAssignment(
        attributes: [NSAttributedString.Key: Any],
        font: UIFont,
        baseBodyFont: UIFont
    ) -> SyncTextMarkAssignment {
        if let explicit = attributes[.explicitStructuralFontSizeMilliPoints] as? Int,
           (11_000...40_000).contains(explicit) {
            return .fontSizeMilliPoints(explicit)
        }

        guard let value = NoteStructuralFormattingCanonicalization
            .fontSizeMilliPoints(Double(font.pointSize)) else {
            return .clear
        }
        let base = NoteStructuralFormattingCanonicalization
            .fontSizeMilliPoints(Double(baseBodyFont.pointSize))
        return value == base ? .clear : .fontSizeMilliPoints(value)
    }

    private static func canonicalColorAssignment(
        attributes: [NSAttributedString.Key: Any],
        traitCollection: UITraitCollection
    ) -> SyncTextMarkAssignment {
        if (attributes[.autoTextColorDisplay] as? Bool) == true {
            return .clear
        }
        guard let color = attributes[.foregroundColor] as? UIColor,
              !isInheritedSystemTextColor(color),
              let rgba = canonicalRGBA(
                color.resolvedColor(with: traitCollection)
              ) else {
            return .clear
        }
        return .textColor(rgba)
    }

    private static func canonicalRGBA(
        _ color: UIColor
    ) -> SyncTextMarkRGBAColor? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.cgColor.converted(
                to: colorSpace,
                intent: .defaultIntent,
                options: nil
              ),
              let components = converted.components,
              components.count >= 4 else {
            return nil
        }
        return NoteStructuralFormattingCanonicalization.rgbaColor(
            red: Double(components[0]),
            green: Double(components[1]),
            blue: Double(components[2]),
            alpha: Double(components[3])
        )
    }

    private static func isInheritedSystemTextColor(_ color: UIColor) -> Bool {
        [
            UIColor.label,
            .secondaryLabel,
            .tertiaryLabel,
            .quaternaryLabel,
            .placeholderText
        ].contains { color.isEqual($0) }
    }

    private static func decorationEnabled(_ value: Any?) -> Bool {
        (value as? NSNumber)?.intValue != 0
    }
}
