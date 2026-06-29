import XCTest
import UIKit
@testable import MyRAM

final class EditorFormattingMutationApplierTests: XCTestCase {
    func testAppliesTraitPlanToSelectedAttributedText() throws {
        let attributedText = NSMutableAttributedString(
            string: "Bold",
            attributes: [.font: UIFont.systemFont(ofSize: 17)]
        )
        let plan = EditorFormattingTraitPlan(
            range: NSRange(location: 0, length: attributedText.length),
            trait: .traitBold,
            shouldApply: true
        )

        let result = EditorFormattingMutationApplier.applyingTraitPlan(
            plan,
            to: attributedText,
            fallbackFont: UIFont.systemFont(ofSize: 17)
        )

        let font = try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testRemovesTraitPlanFromSelectedAttributedText() throws {
        let attributedText = NSMutableAttributedString(
            string: "Bold",
            attributes: [.font: UIFont.boldSystemFont(ofSize: 17)]
        )
        let plan = EditorFormattingTraitPlan(
            range: NSRange(location: 0, length: attributedText.length),
            trait: .traitBold,
            shouldApply: false
        )

        let result = EditorFormattingMutationApplier.applyingTraitPlan(
            plan,
            to: attributedText,
            fallbackFont: UIFont.systemFont(ofSize: 17)
        )

        let font = try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testAppliesDecorationPlanAndSyncsDecorationColor() throws {
        let attributedText = NSMutableAttributedString(string: "Underline")
        let range = NSRange(location: 0, length: attributedText.length)
        attributedText.addAttribute(.foregroundColor, value: UIColor.systemRed, range: range)
        let plan = EditorFormattingDecorationPlan(
            range: range,
            styleKey: .underlineStyle,
            colorKey: .underlineColor,
            shouldApply: true
        )

        let result = EditorFormattingMutationApplier.applyingDecorationPlan(plan, to: attributedText)

        XCTAssertEqual(
            result.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        let underlineColor = try XCTUnwrap(result.attribute(.underlineColor, at: 0, effectiveRange: nil) as? UIColor)
        XCTAssertTrue(underlineColor.isEqual(UIColor.systemRed))
    }

    func testRemovesDecorationPlanAndDecorationColor() {
        let attributedText = NSMutableAttributedString(string: "Strike")
        let range = NSRange(location: 0, length: attributedText.length)
        attributedText.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        attributedText.addAttribute(.strikethroughColor, value: UIColor.systemBlue, range: range)
        let plan = EditorFormattingDecorationPlan(
            range: range,
            styleKey: .strikethroughStyle,
            colorKey: .strikethroughColor,
            shouldApply: false
        )

        let result = EditorFormattingMutationApplier.applyingDecorationPlan(plan, to: attributedText)

        XCTAssertEqual(result.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int, 0)
        XCTAssertNil(result.attribute(.strikethroughColor, at: 0, effectiveRange: nil))
    }

    func testFontSizePlanClampsSelectedTextToSupportedBoundaries() throws {
        let minimumText = NSMutableAttributedString(
            string: "Small",
            attributes: [.font: UIFont.systemFont(ofSize: 12)]
        )
        let maximumText = NSMutableAttributedString(
            string: "Large",
            attributes: [.font: UIFont.systemFont(ofSize: 39)]
        )

        let minimumResult = EditorFormattingMutationApplier.applyingFontSizePlan(
            EditorFormattingFontSizePlan(range: NSRange(location: 0, length: minimumText.length), delta: -10),
            to: minimumText,
            fallbackFont: UIFont.systemFont(ofSize: 17)
        )
        let maximumResult = EditorFormattingMutationApplier.applyingFontSizePlan(
            EditorFormattingFontSizePlan(range: NSRange(location: 0, length: maximumText.length), delta: 10),
            to: maximumText,
            fallbackFont: UIFont.systemFont(ofSize: 17)
        )

        let minimumFont = try XCTUnwrap(minimumResult.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let maximumFont = try XCTUnwrap(maximumResult.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(minimumFont.pointSize, EditorFormattingCommandResolver.minimumFontSize, accuracy: 0.1)
        XCTAssertEqual(maximumFont.pointSize, EditorFormattingCommandResolver.maximumFontSize, accuracy: 0.1)
    }

    func testAppliesExplicitColorPlanAndSyncsActiveDecorationColors() throws {
        let attributedText = NSMutableAttributedString(string: "Color")
        let range = NSRange(location: 0, length: attributedText.length)
        attributedText.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        attributedText.addAttribute(.autoTextColorDisplay, value: true, range: range)
        let plan = EditorFormattingColorPlan(range: range, color: .systemGreen, usesDefaultColor: false)

        let result = EditorFormattingMutationApplier.applyingColorPlan(
            plan,
            to: attributedText,
            defaultTextColor: .label,
            fallbackTextColor: .systemBlue
        )

        let foregroundColor = try XCTUnwrap(result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        let underlineColor = try XCTUnwrap(result.attribute(.underlineColor, at: 0, effectiveRange: nil) as? UIColor)
        XCTAssertTrue(foregroundColor.isEqual(UIColor.systemGreen))
        XCTAssertTrue(underlineColor.isEqual(UIColor.systemGreen))
        XCTAssertNil(result.attribute(.autoTextColorDisplay, at: 0, effectiveRange: nil))
    }

    func testAppliesDefaultColorPlanWithAutoDisplayMarker() throws {
        let attributedText = NSMutableAttributedString(string: "Auto")
        let range = NSRange(location: 0, length: attributedText.length)
        attributedText.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        let plan = EditorFormattingColorPlan(range: range, color: nil, usesDefaultColor: true)

        let result = EditorFormattingMutationApplier.applyingColorPlan(
            plan,
            to: attributedText,
            defaultTextColor: .label,
            fallbackTextColor: .systemBlue
        )

        let foregroundColor = try XCTUnwrap(result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        let strikethroughColor = try XCTUnwrap(result.attribute(.strikethroughColor, at: 0, effectiveRange: nil) as? UIColor)
        XCTAssertTrue(foregroundColor.isEqual(UIColor.label))
        XCTAssertTrue(strikethroughColor.isEqual(UIColor.label))
        XCTAssertEqual(result.attribute(.autoTextColorDisplay, at: 0, effectiveRange: nil) as? Bool, true)
    }

    func testCollapsedCaretUpdatesTypingAttributesWithoutMutatingAttributedText() throws {
        let attributedText = NSMutableAttributedString(
            string: "Body",
            attributes: [.font: UIFont.systemFont(ofSize: 17)]
        )
        let originalText = NSAttributedString(attributedString: attributedText)
        let typingAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17),
            .foregroundColor: UIColor.systemPurple,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        let traitPlan = EditorFormattingTraitPlan(
            range: NSRange(location: 2, length: 0),
            trait: .traitItalic,
            shouldApply: true
        )
        let colorPlan = EditorFormattingColorPlan(
            range: NSRange(location: 2, length: 0),
            color: .systemOrange,
            usesDefaultColor: false
        )

        let traitAttributes = EditorFormattingMutationApplier.applyingTraitPlan(
            traitPlan,
            to: typingAttributes,
            fallbackFont: UIFont.systemFont(ofSize: 17)
        )
        let colorAttributes = EditorFormattingMutationApplier.applyingColorPlan(
            colorPlan,
            to: traitAttributes,
            defaultTextColor: .label,
            fallbackTextColor: nil
        )

        let font = try XCTUnwrap(colorAttributes[.font] as? UIFont)
        let foregroundColor = try XCTUnwrap(colorAttributes[.foregroundColor] as? UIColor)
        let underlineColor = try XCTUnwrap(colorAttributes[.underlineColor] as? UIColor)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertTrue(foregroundColor.isEqual(UIColor.systemOrange))
        XCTAssertTrue(underlineColor.isEqual(UIColor.systemOrange))
        XCTAssertTrue(attributedText.isEqual(to: originalText))
    }

    func testInvalidSelectedRangeLeavesAttributedTextUnchanged() {
        let attributedText = NSMutableAttributedString(
            string: "Safe",
            attributes: [.font: UIFont.systemFont(ofSize: 17)]
        )
        let originalText = NSAttributedString(attributedString: attributedText)
        let plan = EditorFormattingFontSizePlan(range: NSRange(location: 20, length: 4), delta: 4)

        let result = EditorFormattingMutationApplier.applyingFontSizePlan(
            plan,
            to: attributedText,
            fallbackFont: UIFont.systemFont(ofSize: 17)
        )

        XCTAssertTrue(result.isEqual(to: originalText))
    }
}
