import AppKit
import XCTest
@testable import MyRAMMac

final class MacRemoteInsertionAttributePolicyTests: XCTestCase {
    func testInsertionAtMiddleInheritsPreviousCharacterAttributes() {
        let attributed = NSMutableAttributedString(string: "AB")
        attributed.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 1))
        attributed.addAttribute(.foregroundColor, value: NSColor.blue, range: NSRange(location: 1, length: 1))

        let attributes = MacRemoteInsertionAttributePolicy.attributesForRemoteInsertion(in: attributed, at: 1)

        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .red)
    }

    func testInsertionAtOffsetZeroUsesFirstCharacterAttributes() {
        let attributed = NSMutableAttributedString(string: "AB")
        attributed.addAttribute(.foregroundColor, value: NSColor.blue, range: NSRange(location: 0, length: 1))

        let attributes = MacRemoteInsertionAttributePolicy.attributesForRemoteInsertion(in: attributed, at: 0)

        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .blue)
    }

    func testInsertionIntoEmptyTextUsesDefaultAttributes() {
        let attributes = MacRemoteInsertionAttributePolicy.attributesForRemoteInsertion(
            in: NSAttributedString(string: ""),
            at: 0,
            defaultAttributes: [.font: NSFont.systemFont(ofSize: 17)]
        )

        XCTAssertEqual(attributes[.font] as? NSFont, NSFont.systemFont(ofSize: 17))
    }
}
