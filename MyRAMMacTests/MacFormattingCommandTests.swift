import AnchoredSequenceCore
import AppKit
import SwiftUI
import XCTest
@testable import MyRAMMac

@MainActor
final class MacFormattingCommandTests: XCTestCase {
    func testLiveCoordinatorPublishesStructuralFormattingAfterCommandAndStripsUnsupportedPaste() {
        var published = NSAttributedString(string: "AB")
        var publications = 0
        let controller = MacFormattingController()
        let coordinator = MacTextViewRepresentable.Coordinator(
            attributedText: .init(get: { published }, set: { published = $0 }),
            syncBridge: MacEditorSyncBridge(),
            formattingController: controller,
            onTextChanged: { publications += 1 }
        )
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        editor.textStorage?.setAttributedString(NSAttributedString(string: "AB"))
        coordinator.textView = editor
        editor.delegate = coordinator
        editor.textStorage?.delegate = coordinator
        coordinator.register(editor)
        controller.bind(textView: editor, noteID: UUID(), enabled: true)
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        controller.perform(.bold)
        XCTAssertGreaterThan(publications, 0)
        XCTAssertEqual(published.string, "AB")
        XCTAssertEqual(MacStructuralFormattingAdapter.project(published).runs.first?.assignments[.bold], .enabled)
        XCTAssertEqual(MacStructuralFormattingAdapter.project(published).plainText, "AB")

        let paste = NSMutableAttributedString(string: "Z", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 25),
            .kern: 19,
            .backgroundColor: NSColor.systemGreen
        ])
        editor.textStorage?.replaceCharacters(in: NSRange(location: 1, length: 0), with: paste)
        XCTAssertEqual(editor.string, "AZB")
        XCTAssertNil(editor.attributedString().attribute(.kern, at: 1, effectiveRange: nil))
        XCTAssertNil(editor.attributedString().attribute(.backgroundColor, at: 1, effectiveRange: nil))
        XCTAssertEqual(MacStructuralFormattingAdapter.project(published).plainText, "AZB")
    }
    private let whole = NSRange(location: 0, length: 2)

    func testSixSupportedMarksProjectWithoutChangingBody() throws {
        let source = NSAttributedString(
            string: "AB", attributes: [.font: NSFont.systemFont(ofSize: 24)]
        )
        let commands: [MacFormattingCommand] = [
            .bold, .italic, .underline, .strikethrough, .size(25),
            .color(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ]
        let final = commands.reduce(source) {
            MacFormattingMutation.transform($0, range: whole, command: $1)
        }
        let projection = MacStructuralFormattingAdapter.project(final)
        XCTAssertEqual(final.string, "AB")
        XCTAssertEqual(projection.runs.count, 1)
        let marks = try XCTUnwrap(projection.runs.first?.assignments)
        XCTAssertEqual(marks[.bold], .enabled)
        XCTAssertEqual(marks[.italic], .enabled)
        XCTAssertEqual(marks[.underline], .enabled)
        XCTAssertEqual(marks[.strikethrough], .enabled)
        XCTAssertEqual(marks[.fontSize], .fontSizeMilliPoints(25_000))
        XCTAssertEqual(marks[.textColor], .textColor(
            SyncTextMarkRGBAColor(red: 255, green: 0, blue: 0, alpha: 255)
        ))
    }

    func testMixedRangeToggleNormalizesOnlyRequestedTrait() throws {
        let source = NSMutableAttributedString(string: "AB")
        source.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 24),
                            range: NSRange(location: 0, length: 1))
        source.addAttribute(.font, value: NSFont.systemFont(ofSize: 24),
                            range: NSRange(location: 1, length: 1))
        source.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                            range: NSRange(location: 1, length: 1))
        let bothBold = MacFormattingMutation.transform(source, range: whole, command: .bold)
        let runs = MacFormattingMutation.attributeRuns(in: bothBold, range: whole)
        XCTAssertTrue(runs.allSatisfy { ($0[.font] as? NSFont)?
            .fontDescriptor.symbolicTraits.contains(.bold) == true })
        XCTAssertEqual((bothBold.attribute(.underlineStyle, at: 1, effectiveRange: nil) as? Int),
                       NSUnderlineStyle.single.rawValue)
        XCTAssertNil(bothBold.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        let cleared = MacFormattingMutation.transform(bothBold, range: whole, command: .bold)
        XCTAssertFalse(MacFormattingMutation.attributeRuns(in: cleared, range: whole)
            .contains { ($0[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true })
    }

    func testCollapsedCaretUpdatesTypingOnlyAndNeverCreatesZeroLengthMark() {
        let source = NSAttributedString(string: "AB", attributes: [
            .font: NSFont.systemFont(ofSize: 24)
        ])
        let empty = NSRange(location: 1, length: 0)
        XCTAssertTrue(MacFormattingMutation.transform(source, range: empty, command: .bold)
            .isEqual(to: source))
        let typed = MacFormattingMutation.typingAttributes(
            [.font: NSFont.systemFont(ofSize: 24)], command: .bold
        )
        XCTAssertTrue((typed[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertEqual(source.string, "AB")
    }

    func testBoundsAndMixedFontSizesArePreservedByRelativeCommands() {
        let source = NSMutableAttributedString(string: "AB")
        source.addAttribute(.font, value: NSFont.systemFont(ofSize: 11),
                            range: NSRange(location: 0, length: 1))
        source.addAttribute(.font, value: NSFont.systemFont(ofSize: 40),
                            range: NSRange(location: 1, length: 1))
        let increased = MacFormattingMutation.transform(source, range: whole, command: .adjustSize(1))
        XCTAssertEqual((increased.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 12)
        XCTAssertEqual((increased.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.pointSize, 40)
        let invalid = MacFormattingMutation.transform(source, range: whole, command: .size(41))
        XCTAssertTrue(invalid.isEqual(to: source))
    }

    func testDefaultColorAndExplicitColorProjectDistinctly() throws {
        let source = NSAttributedString(string: "AB")
        let explicit = MacFormattingMutation.transform(source, range: whole,
            command: .color(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)))
        let marked = try XCTUnwrap(MacStructuralFormattingAdapter.project(explicit).runs.first)
        XCTAssertNotEqual(marked.assignments[.textColor], .clear)
        let reset = MacFormattingMutation.transform(explicit, range: whole, command: .color(nil))
        XCTAssertEqual(try XCTUnwrap(MacStructuralFormattingAdapter.project(reset).runs.first)
            .assignments[.textColor], .clear)
        XCTAssertEqual(reset.attribute(.autoTextColorDisplay, at: 0, effectiveRange: nil) as? Bool, true)
    }

    func testUnsupportedPasteAttributesAreRemovedBeforePersistenceProjection() {
        let paste = NSMutableAttributedString(string: "AB")
        paste.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 25), range: whole)
        paste.addAttribute(.kern, value: 14, range: whole)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 33
        paste.addAttribute(.paragraphStyle, value: style, range: whole)
        let canonical = MacStructuralFormattingAdapter.render(
            projection: MacStructuralFormattingAdapter.project(paste)
        )
        XCTAssertNil(canonical.attribute(.kern, at: 0, effectiveRange: nil))
        XCTAssertNil(canonical.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(MacStructuralFormattingAdapter.project(canonical)
            .runs.first?.assignments[.bold], .enabled)
    }

    func testSelectedFormattingUndoRedoUsesSameTextStorageMutationPath() {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        editor.textStorage?.setAttributedString(NSAttributedString(string: "AB"))
        editor.setSelectedRange(whole)
        let undo = UndoManager()
        let controller = MacFormattingController(undoManager: undo)
        controller.bind(textView: editor, noteID: UUID(), enabled: true)
        controller.perform(.bold)
        XCTAssertEqual(MacStructuralFormattingAdapter.project(editor.attributedString())
            .runs.first?.assignments[.bold], .enabled)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(MacStructuralFormattingAdapter.project(editor.attributedString())
            .runs.first?.assignments[.bold], .clear)
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(MacStructuralFormattingAdapter.project(editor.attributedString())
            .runs.first?.assignments[.bold], .enabled)
    }
}
