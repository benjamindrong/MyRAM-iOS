#if os(macOS)
import AnchoredSequenceCore
import AppKit

@MainActor
enum MacStructuralFormattingAdapter {
    static let defaultBodyFont = NSFont.systemFont(ofSize: 24)

    static func project(
        _ attributedText: NSAttributedString,
        baseBodyFont: NSFont = defaultBodyFont
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
            let font = attributes[.font] as? NSFont ?? baseBodyFont
            let traits = font.fontDescriptor.symbolicTraits
            runs.append(NoteStructuralFormattingProjectionRun(
                startUTF16Offset: range.location,
                utf16Length: range.length,
                assignments: [
                    .bold: traits.contains(.bold) ? .enabled : .clear,
                    .italic: traits.contains(.italic) ? .enabled : .clear,
                    .underline: decorationEnabled(
                        attributes[.underlineStyle]
                    ) ? .enabled : .clear,
                    .strikethrough: decorationEnabled(
                        attributes[.strikethroughStyle]
                    ) ? .enabled : .clear,
                    .fontSize: canonicalFontSizeAssignment(
                        attributes: attributes,
                        font: font,
                        baseBodyFont: baseBodyFont
                    ),
                    .textColor: canonicalColorAssignment(attributes: attributes)
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
        baseBodyFont: NSFont = defaultBodyFont
    ) throws -> NSAttributedString {
        let mutable = NSMutableAttributedString(
            string: sequence.visibleText,
            attributes: [.font: baseBodyFont]
        )
        for span in try marks.visibleProjection(in: sequence) {
            let range = NSRange(
                location: span.startUTF16Offset,
                length: span.utf16Length
            )
            var traits = baseBodyFont.fontDescriptor.symbolicTraits
            traits.remove([.bold, .italic])
            if span.assignments[.bold] == .enabled {
                traits.insert(.bold)
            }
            if span.assignments[.italic] == .enabled {
                traits.insert(.italic)
            }
            let descriptor = baseBodyFont.fontDescriptor
                .withSymbolicTraits(traits)
            let sizeAssignment = span.assignments[.fontSize] ?? .clear
            let pointSize: CGFloat
            if case .fontSizeMilliPoints(let milliPoints) = sizeAssignment {
                pointSize = CGFloat(milliPoints) / 1_000
            } else {
                pointSize = baseBodyFont.pointSize
            }
            let font = NSFont(
                descriptor: descriptor,
                size: pointSize
            ) ?? NSFont.systemFont(ofSize: pointSize)
            mutable.addAttribute(.font, value: font, range: range)

            if case .fontSizeMilliPoints(let milliPoints) = sizeAssignment {
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
                    value: NSColor(
                        srgbRed: CGFloat(rgba.red) / 255,
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
        baseBodyFont: NSFont = defaultBodyFont
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
        return project(attributed, baseBodyFont: baseBodyFont)
    }

    private static func canonicalFontSizeAssignment(
        attributes: [NSAttributedString.Key: Any],
        font: NSFont,
        baseBodyFont: NSFont
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
        attributes: [NSAttributedString.Key: Any]
    ) -> SyncTextMarkAssignment {
        if (attributes[.autoTextColorDisplay] as? Bool) == true {
            return .clear
        }
        guard let color = attributes[.foregroundColor] as? NSColor,
              !isInheritedSystemTextColor(color),
              let converted = color.usingColorSpace(.sRGB),
              let rgba = NoteStructuralFormattingCanonicalization.rgbaColor(
                red: Double(converted.redComponent),
                green: Double(converted.greenComponent),
                blue: Double(converted.blueComponent),
                alpha: Double(converted.alphaComponent)
              ) else {
            return .clear
        }
        return .textColor(rgba)
    }

    private static func isInheritedSystemTextColor(_ color: NSColor) -> Bool {
        [
            NSColor.textColor,
            .labelColor,
            .secondaryLabelColor,
            .tertiaryLabelColor,
            .quaternaryLabelColor,
            .placeholderTextColor
        ].contains { color.isEqual($0) }
    }

    private static func decorationEnabled(_ value: Any?) -> Bool {
        (value as? NSNumber)?.intValue != 0
    }
}
#endif
