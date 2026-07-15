import AppKit
import XCTest
@testable import MyRAMMac

final class MacEditorTextColorPolicyTests: XCTestCase {
    func testDynamicTextColorResolvesAcrossAquaAppearances() throws {
        let lightComponents = try XCTUnwrap(NSColor.textColor.resolvedComponents(for: .aqua))
        let darkComponents = try XCTUnwrap(NSColor.textColor.resolvedComponents(for: .darkAqua))

        XCTAssertNotEqual(lightComponents.luminance, darkComponents.luminance)
    }

    func testMissingForegroundBecomesAutoDisplayColor() {
        let normalized = MacEditorTextColorPolicy.normalizedForDisplay(
            NSAttributedString(string: "Auto"),
            defaultTextColor: .textColor
        )

        XCTAssertEqual(normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
        XCTAssertEqual(normalized.attribute(.autoTextColorDisplay, at: 0, effectiveRange: nil) as? Bool, true)
    }

    func testAutoNormalizationIsIdempotent() {
        let text = MacEditorTextColorPolicy.normalizedForDisplay(NSAttributedString(string: "Auto"))
        let normalizedAgain = MacEditorTextColorPolicy.normalizedForDisplay(text)

        XCTAssertTrue(text.isEqual(to: normalizedAgain))
    }

    func testExistingAutoMarkerRefreshesToSuppliedDefault() {
        let text = NSMutableAttributedString(string: "Auto")
        text.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: text.length))
        text.addAttribute(.autoTextColorDisplay, value: true, range: NSRange(location: 0, length: text.length))

        let normalized = MacEditorTextColorPolicy.normalizedForDisplay(text, defaultTextColor: .textColor)

        XCTAssertEqual(normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
        XCTAssertEqual(normalized.attribute(.autoTextColorDisplay, at: 0, effectiveRange: nil) as? Bool, true)
    }

    func testExplicitColorsSurviveUnchanged() {
        assertExplicitColorSurvives(.systemRed)
        assertExplicitColorSurvives(.systemBlue)
        assertExplicitColorSurvives(.black)
        assertExplicitColorSurvives(.white)
        assertExplicitColorSurvives(.gray)
    }

    func testMixedAutoAndExplicitRangesRemainClassified() {
        let text = NSMutableAttributedString(string: "AB")
        text.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: NSRange(location: 1, length: 1))

        let normalized = MacEditorTextColorPolicy.normalizedForDisplay(text)

        XCTAssertEqual(normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
        XCTAssertEqual(normalized.attribute(.autoTextColorDisplay, at: 0, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(normalized.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor, .systemBlue)
        XCTAssertNil(normalized.attribute(.autoTextColorDisplay, at: 1, effectiveRange: nil))
    }

    func testPersistenceRemovesAutoForegroundAndMarkerOnly() {
        let text = NSMutableAttributedString(string: "AB")
        text.addAttribute(.foregroundColor, value: NSColor.textColor, range: NSRange(location: 0, length: 1))
        text.addAttribute(.autoTextColorDisplay, value: true, range: NSRange(location: 0, length: 1))
        text.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 1, length: 1))

        let sanitized = MacEditorTextColorPolicy.sanitizedForPersistence(text)

        XCTAssertNil(sanitized.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertNil(sanitized.attribute(.autoTextColorDisplay, at: 0, effectiveRange: nil))
        XCTAssertEqual(sanitized.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor, .systemRed)
    }

    func testPersistencePreservesNonColorFormattingAndAttachments() {
        let attachment = NSTextAttachment()
        let text = NSMutableAttributedString(string: "Styled ")
        text.append(NSAttributedString(attachment: attachment))
        let fullRange = NSRange(location: 0, length: text.length)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 12
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: fullRange)
        text.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
        text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
        text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
        text.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
        text.addAttribute(.autoTextColorDisplay, value: true, range: fullRange)

        let sanitized = MacEditorTextColorPolicy.sanitizedForPersistence(text)

        XCTAssertNotNil(sanitized.attribute(.font, at: 0, effectiveRange: nil))
        XCTAssertNotNil(sanitized.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(sanitized.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(sanitized.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNotNil(sanitized.attribute(.attachment, at: text.length - 1, effectiveRange: nil))
        XCTAssertNil(sanitized.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertNil(sanitized.attribute(.autoTextColorDisplay, at: 0, effectiveRange: nil))
    }

    func testTypingAttributesWithoutForegroundBecomeAuto() {
        let attributes = MacEditorTextColorPolicy.normalizedTypingAttributes([.font: NSFont.systemFont(ofSize: 17)])

        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .textColor)
        XCTAssertEqual(attributes[.autoTextColorDisplay] as? Bool, true)
        XCTAssertEqual(attributes[.font] as? NSFont, NSFont.systemFont(ofSize: 17))
    }

    func testAutoTypingAttributesRefresh() {
        let attributes = MacEditorTextColorPolicy.normalizedTypingAttributes([
            .foregroundColor: NSColor.systemRed,
            .autoTextColorDisplay: true
        ])

        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .textColor)
        XCTAssertEqual(attributes[.autoTextColorDisplay] as? Bool, true)
    }

    func testExplicitTypingColorRemainsExplicit() {
        let attributes = MacEditorTextColorPolicy.normalizedTypingAttributes([.foregroundColor: NSColor.systemGreen])

        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .systemGreen)
        XCTAssertNil(attributes[.autoTextColorDisplay])
    }

    private func assertExplicitColorSurvives(
        _ color: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let text = NSMutableAttributedString(string: "Color")
        text.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: text.length))

        let normalized = MacEditorTextColorPolicy.normalizedForDisplay(text)
        let sanitized = MacEditorTextColorPolicy.sanitizedForPersistence(normalized)

        XCTAssertEqual(normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, color, file: file, line: line)
        XCTAssertNil(normalized.attribute(.autoTextColorDisplay, at: 0, effectiveRange: nil), file: file, line: line)
        XCTAssertEqual(sanitized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, color, file: file, line: line)
    }
}

private extension NSColor {
    func resolvedComponents(for appearanceName: NSAppearance.Name) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, luminance: CGFloat)? {
        guard let appearance = NSAppearance(named: appearanceName) else { return nil }
        var components: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, luminance: CGFloat)?
        appearance.performAsCurrentDrawingAppearance {
            guard let color = usingColorSpace(.deviceRGB) else { return }
            let luminance = 0.2126 * color.redComponent
                + 0.7152 * color.greenComponent
                + 0.0722 * color.blueComponent
            components = (
                red: color.redComponent,
                green: color.greenComponent,
                blue: color.blueComponent,
                alpha: color.alphaComponent,
                luminance: luminance
            )
        }
        return components
    }
}
