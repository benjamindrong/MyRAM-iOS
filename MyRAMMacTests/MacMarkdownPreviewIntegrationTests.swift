import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import MyRAMMac

// MARK: - AppKit Test Recorder (§6 Sixth Remediation)
// Lives in MyRAMMacTests target so no test double types leak into production.

@MainActor
final class MacMarkdownPreviewTestRecorder {
    private(set) var onTextChangedCount = 0
    private(set) var parsedSources: [String] = []

    func recordTextChanged() {
        onTextChangedCount += 1
    }

    func recordParse(source: String) {
        parsedSources.append(source)
    }
}

@MainActor
final class MacMarkdownPreviewHostState: ObservableObject {
    @Published var attributedText: NSAttributedString
    @Published var resignFocusToggleToken = 0
    @Published var mode: MarkdownEditorMode = .edit
    @Published var zoom = MacNoteViewZoom.actualSize
    let syncBridge = MacEditorSyncBridge()
    let recorder: MacMarkdownPreviewTestRecorder
    let previewBuilder: MacMarkdownPreviewDocumentBuilder

    init(
        text: String,
        parseOperation: MarkdownPreviewParser.ParseOperation? = nil
    ) {
        attributedText = NSAttributedString(string: text)
        let recorder = MacMarkdownPreviewTestRecorder()
        self.recorder = recorder
        let operation = parseOperation ?? { source in
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .throwError,
                languageCode: nil
            )
            return try AttributedString(markdown: source, options: options)
        }
        previewBuilder = MacMarkdownPreviewDocumentBuilder(
            parser: MarkdownPreviewParser { source in
                recorder.recordParse(source: source)
                return try operation(source)
            }
        )
    }

    func enterPreview() {
        modeBinding.wrappedValue = .preview
    }

    func enterEdit() {
        modeBinding.wrappedValue = .edit
    }

    var modeBinding: Binding<MarkdownEditorMode> {
        MacMarkdownModeBindingFactory.make(
            mode: Binding(
                get: { self.mode },
                set: { self.mode = $0 }
            ),
            resignFocusToggleToken: Binding(
                get: { self.resignFocusToggleToken },
                set: { self.resignFocusToggleToken = $0 }
            ),
            prepareForPreview: {
                guard let textView = self.syncBridge.textView else { return }
                MacMarkdownPreviewFocusResignation.finalizeAndResignIfOwned(
                    window: textView.window,
                    textView: textView
                )
            }
        )
    }
}

@MainActor
private final class PreviewTextStorageEditRecorder: NSObject, @MainActor NSTextStorageDelegate {
    private(set) var editTransactionCount = 0

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) || editedMask.contains(.editedAttributes) else {
            return
        }
        editTransactionCount += 1
    }
}

private struct MacMarkdownPreviewHostedEditor: View {
    @ObservedObject var state: MacMarkdownPreviewHostState

    var body: some View {
        MacNoteEditorView(
            note: nil,
            attributedText: $state.attributedText,
            markdownEditorMode: state.modeBinding,
            syncBridge: state.syncBridge,
            loadError: nil,
            saveError: nil,
            onTextChanged: { state.recorder.recordTextChanged() },
            resignFocusToggleToken: state.resignFocusToggleToken,
            noteViewZoom: state.zoom,
            markdownPreviewBuilder: state.previewBuilder
        )
        .frame(width: 700, height: 520)
    }
}

// MARK: - MacMarkdownPreviewIntegrationTests (§6 Sixth Remediation)
// Real AppKit host and production focus seam tests.

@MainActor
final class MacMarkdownPreviewIntegrationTests: XCTestCase {

    // MARK: - MYR-196 Production mode binding

    func testModeBindingFactoryOrdersPreviewResignationAndIgnoresNoOp() {
        var mode = MarkdownEditorMode.edit
        var token = 4
        var events: [String] = []
        var observations: [(MarkdownEditorMode, Int)] = []
        let modeBinding = Binding(
            get: { mode },
            set: {
                mode = $0
                events.append("mode:\($0.rawValue):\(token)")
                observations.append((mode, token))
            }
        )
        let tokenBinding = Binding(
            get: { token },
            set: { token = $0 }
        )
        let binding = MacMarkdownModeBindingFactory.make(
            mode: modeBinding,
            resignFocusToggleToken: tokenBinding,
            prepareForPreview: {
                events.append("prepare:\(mode.rawValue):\(token)")
            }
        )

        binding.wrappedValue = .edit
        XCTAssertEqual(token, 4)
        XCTAssertTrue(observations.isEmpty)

        binding.wrappedValue = .preview
        XCTAssertEqual(token, 5)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.0, .preview)
        XCTAssertEqual(observations.first?.1, 5, "The token must advance before Preview is published")
        XCTAssertEqual(events, ["prepare:edit:4", "mode:preview:5"])

        binding.wrappedValue = .edit
        XCTAssertEqual(token, 5)
        XCTAssertEqual(observations.last?.0, .edit)
    }

    // MARK: - MYR-196 retained native Preview

    func testRetainedPreviewDefersHiddenWorkAndBuildsOnlyLatestSourceOnActivation() throws {
        let host = makeHostedEditor(text: "# Initial")
        let editor = try XCTUnwrap(host.state.syncBridge.textView)
        let preview = try XCTUnwrap(previewTextView(in: host.container))
        let previewScrollView = try XCTUnwrap(preview.enclosingScrollView)
        let previewStorage = try XCTUnwrap(preview.textStorage)
        let previewIdentity = ObjectIdentifier(preview)
        let storageIdentity = ObjectIdentifier(previewStorage)

        XCTAssertEqual(host.state.recorder.parsedSources, [])
        XCTAssertTrue(preview.string.isEmpty)
        XCTAssertFalse(preview.isEditable)
        XCTAssertTrue(preview.isSelectable)
        XCTAssertFalse(preview.allowsUndo)
        XCTAssertFalse(host.state.syncBridge.textView === preview)

        host.state.attributedText = NSAttributedString(string: "# Hidden first")
        drainMainRunLoop()
        host.state.attributedText = NSAttributedString(string: "# Latest hidden")
        drainMainRunLoop()
        XCTAssertEqual(host.state.recorder.parsedSources, [])
        XCTAssertTrue(preview.string.isEmpty)

        host.state.enterPreview()
        drainMainRunLoop()

        XCTAssertEqual(host.state.recorder.parsedSources, ["# Latest hidden"])
        XCTAssertEqual(preview.string, "Latest hidden")
        let accessibilityIdentifiers = accessibilityIdentifiers(in: host.window)
        XCTAssertTrue(accessibilityIdentifiers.contains("markdown-preview-reminder"))
        XCTAssertTrue(accessibilityIdentifiers.contains("markdown-preview-body"))
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(previewTextView(in: host.container))), previewIdentity)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(preview.textStorage)), storageIdentity)
        XCTAssertTrue(host.state.syncBridge.textView === editor)

        preview.setSelectedRange(NSRange(location: 1, length: 5))
        let selectedRange = preview.selectedRange()
        let visibleOrigin = previewScrollView.contentView.bounds.origin
        host.state.enterEdit()
        drainMainRunLoop()
        host.state.enterPreview()
        drainMainRunLoop()

        XCTAssertEqual(host.state.recorder.parsedSources.count, 1)
        XCTAssertEqual(preview.selectedRange(), selectedRange)
        XCTAssertEqual(previewScrollView.contentView.bounds.origin, visibleOrigin)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(previewTextView(in: host.container))), previewIdentity)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(preview.textStorage)), storageIdentity)
    }

    func testSharedZoomUpdatesBothRetainedSurfacesWithoutTextMutationOrBuild() throws {
        let host = makeHostedEditor(text: "Zoom source")
        let editor = try XCTUnwrap(host.state.syncBridge.textView)
        let preview = try XCTUnwrap(previewTextView(in: host.container))
        let editorScrollView = try XCTUnwrap(editor.enclosingScrollView)
        let previewScrollView = try XCTUnwrap(preview.enclosingScrollView)
        let originalBinding = host.state.attributedText
        let editorIdentity = ObjectIdentifier(editor)
        let editorStorageIdentity = ObjectIdentifier(try XCTUnwrap(editor.textStorage))
        let editorUndoIdentity = ObjectIdentifier(try XCTUnwrap(editor.undoManager))
        editor.setSelectedRange(NSRange(location: 2, length: 3))

        host.state.zoom = MacNoteViewZoom.zoomedIn(from: host.state.zoom)
        drainMainRunLoop()

        XCTAssertEqual(editorScrollView.magnification, 1.1, accuracy: 0.0001)
        XCTAssertEqual(previewScrollView.magnification, 1.1, accuracy: 0.0001)
        XCTAssertEqual(host.state.recorder.parsedSources.count, 0)
        XCTAssertTrue(host.state.attributedText.isEqual(to: originalBinding))
        XCTAssertEqual(host.state.recorder.onTextChangedCount, 0)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(host.state.syncBridge.textView)), editorIdentity)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(editor.textStorage)), editorStorageIdentity)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(editor.undoManager)), editorUndoIdentity)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3))

        host.state.enterPreview()
        drainMainRunLoop()
        host.state.zoom = MacNoteViewZoom.actualSize
        drainMainRunLoop()

        XCTAssertEqual(editorScrollView.magnification, 1.0, accuracy: 0.0001)
        XCTAssertEqual(previewScrollView.magnification, 1.0, accuracy: 0.0001)
        XCTAssertEqual(host.state.recorder.parsedSources.count, 1)
        XCTAssertEqual(preview.string, "Zoom source")
    }

    func testHiddenEditsCollapseIntoOneReplacementAndPreserveRetainedIdentities() throws {
        let host = makeHostedEditor(text: "Initial")
        host.state.enterPreview()
        drainMainRunLoop()
        let preview = try XCTUnwrap(previewTextView(in: host.container))
        let storage = try XCTUnwrap(preview.textStorage)
        let previewIdentity = ObjectIdentifier(preview)
        let storageIdentity = ObjectIdentifier(storage)
        let storageRecorder = PreviewTextStorageEditRecorder()
        storage.delegate = storageRecorder

        host.state.enterEdit()
        drainMainRunLoop()
        host.state.attributedText = NSAttributedString(string: "Hidden one")
        drainMainRunLoop()
        host.state.attributedText = NSAttributedString(string: "Hidden two")
        drainMainRunLoop()

        XCTAssertEqual(host.state.recorder.parsedSources.count, 1)
        XCTAssertEqual(storageRecorder.editTransactionCount, 0)
        XCTAssertEqual(preview.string, "Initial")

        host.state.enterPreview()
        drainMainRunLoop()

        XCTAssertEqual(host.state.recorder.parsedSources, ["Initial", "Hidden two"])
        XCTAssertEqual(storageRecorder.editTransactionCount, 1)
        XCTAssertEqual(preview.string, "Hidden two")
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(previewTextView(in: host.container))), previewIdentity)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(preview.textStorage)), storageIdentity)
    }

    func testChangedSourceWithEquivalentRenderedDocumentDoesNotEditStorage() throws {
        let host = makeHostedEditor(
            text: "First source",
            parseOperation: { _ in AttributedString("Equivalent document") }
        )
        host.state.enterPreview()
        drainMainRunLoop()
        let preview = try XCTUnwrap(previewTextView(in: host.container))
        let storageRecorder = PreviewTextStorageEditRecorder()
        preview.textStorage?.delegate = storageRecorder

        host.state.attributedText = NSAttributedString(string: "Different source")
        drainMainRunLoop()

        XCTAssertEqual(host.state.recorder.parsedSources, ["First source", "Different source"])
        XCTAssertEqual(preview.string, "Equivalent document")
        XCTAssertEqual(storageRecorder.editTransactionCount, 0)
    }

    func testPreviewSelectionSelectAllCopyAndLinksSpanOneNativeDocument() throws {
        let source = """
        # Heading

        Paragraph with a [link](https://example.com).

        1. Ordered
           - Nested

        > Quote

        ```
        code
        ```
        """
        let host = makeHostedEditor(text: source)
        host.state.enterPreview()
        drainMainRunLoop()
        let preview = try XCTUnwrap(previewTextView(in: host.container))

        let headingStart = (preview.string as NSString).range(of: "Heading").location
        let codeRange = (preview.string as NSString).range(of: "code")
        preview.setSelectedRange(
            NSRange(location: headingStart, length: NSMaxRange(codeRange) - headingStart)
        )
        XCTAssertTrue(preview.selectedRange().length > codeRange.length)

        XCTAssertTrue(host.window.makeFirstResponder(preview))
        preview.selectAll(nil)
        XCTAssertEqual(preview.selectedRange(), NSRange(location: 0, length: preview.string.utf16.count))
        NSPasteboard.general.clearContents()
        preview.copy(nil)
        let copied = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertEqual(copied, preview.string)
        XCTAssertTrue(copied.contains("    •\tNested"))

        let linkRange = (preview.string as NSString).range(of: "link")
        let link = try XCTUnwrap(
            preview.attributedString().attribute(.link, at: linkRange.location, effectiveRange: nil)
                as? URL
        )
        XCTAssertEqual(link.absoluteString, "https://example.com")
    }

    func testActiveChangedSourceUsesOneStorageTransactionAndClampsSelection() throws {
        let longSource = String(repeating: "A long Preview line that wraps in the document.\n", count: 100)
        let host = makeHostedEditor(text: longSource)
        host.state.enterPreview()
        drainMainRunLoop()
        let preview = try XCTUnwrap(previewTextView(in: host.container))
        let scrollView = try XCTUnwrap(preview.enclosingScrollView)
        preview.setSelectedRange(NSRange(location: 10, length: 15))
        scrollView.documentView?.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 300))
        let storageRecorder = PreviewTextStorageEditRecorder()
        preview.textStorage?.delegate = storageRecorder

        host.state.attributedText = NSAttributedString(string: "Short")
        drainMainRunLoop()

        XCTAssertEqual(storageRecorder.editTransactionCount, 1)
        XCTAssertEqual(preview.string, "Short")
        XCTAssertEqual(preview.selectedRange(), NSRange(location: 5, length: 0))
        let maximumY = max(
            0,
            (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height
        )
        XCTAssertGreaterThanOrEqual(scrollView.contentView.bounds.origin.y, 0)
        XCTAssertLessThanOrEqual(scrollView.contentView.bounds.origin.y, maximumY)
    }

    func testEmptyEditorDefaultsTo24PointsAndExistingExplicitFontsRemainUnchanged() throws {
        let emptyHost = makeHostedEditor(text: "")
        let emptyEditor = try XCTUnwrap(emptyHost.state.syncBridge.textView)
        XCTAssertEqual(try XCTUnwrap(emptyEditor.font).pointSize, 24, accuracy: 0.0001)
        XCTAssertEqual(emptyHost.state.recorder.onTextChangedCount, 0)

        XCTAssertTrue(emptyHost.window.makeFirstResponder(emptyEditor))
        emptyEditor.insertText("Typed", replacementRange: NSRange(location: 0, length: 0))
        drainMainRunLoop()
        let typedFont = try XCTUnwrap(
            emptyEditor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(typedFont.pointSize, 24, accuracy: 0.0001)

        let explicit = NSMutableAttributedString(string: "Stored")
        explicit.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: 17),
            range: NSRange(location: 0, length: explicit.length)
        )
        let existingHost = makeHostedEditor(text: "", attributedText: explicit)
        let existingEditor = try XCTUnwrap(existingHost.state.syncBridge.textView)
        let existingFont = try XCTUnwrap(
            existingEditor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(existingFont.pointSize, 17, accuracy: 0.0001)
        XCTAssertTrue(existingHost.state.attributedText.isEqual(to: explicit))
        XCTAssertEqual(existingHost.state.recorder.onTextChangedCount, 0)
    }

    func testFocusFinalizationBuildsFirstPreviewFromFinalNativeSourceExactlyOnce() throws {
        let host = makeHostedEditor(text: "Draft")
        let editor = try XCTUnwrap(host.state.syncBridge.textView)
        let preview = try XCTUnwrap(previewTextView(in: host.container))
        let storageRecorder = PreviewTextStorageEditRecorder()
        preview.textStorage?.delegate = storageRecorder
        XCTAssertTrue(host.window.makeFirstResponder(editor))

        editor.setMarkedText(
            " finalized",
            selectedRange: NSRange(location: 10, length: 0),
            replacementRange: NSRange(location: editor.string.utf16.count, length: 0)
        )
        XCTAssertTrue(editor.hasMarkedText())
        let publicationCountBeforePreview = host.state.recorder.onTextChangedCount

        host.state.enterPreview()
        drainMainRunLoop()

        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertFalse(host.window.firstResponder === editor)
        XCTAssertEqual(preview.string, editor.string)
        XCTAssertEqual(host.state.recorder.parsedSources, [editor.string])
        XCTAssertEqual(storageRecorder.editTransactionCount, 1)
        XCTAssertGreaterThan(publicationCountBeforePreview, 0)
        XCTAssertGreaterThan(
            host.state.recorder.onTextChangedCount,
            publicationCountBeforePreview,
            "Finalizing marked text must publish the legitimate finalized editor state"
        )
    }

    func testLargeDocumentRetainedCacheAvoidsHiddenAndNoOpWork() throws {
        let block = """
        ## Section

        Paragraph with **strong**, *emphasis*, and `code`.

        1. First
        2. Second
           - Nested

        > Quote

        ```
        let value = 1
        ```

        """
        let largeSource = String(repeating: block, count: 180)
        XCTAssertGreaterThan(largeSource.count, 10_000)
        let host = makeHostedEditor(text: largeSource)
        let preview = try XCTUnwrap(previewTextView(in: host.container))
        let storageIdentity = ObjectIdentifier(try XCTUnwrap(preview.textStorage))
        XCTAssertEqual(host.state.recorder.parsedSources.count, 0)

        host.state.attributedText = NSAttributedString(string: largeSource + "\nHidden latest")
        drainMainRunLoop()
        XCTAssertEqual(host.state.recorder.parsedSources.count, 0)

        host.state.enterPreview()
        drainMainRunLoop()
        XCTAssertEqual(host.state.recorder.parsedSources.count, 1)
        let selection = NSRange(location: 100, length: 500)
        preview.setSelectedRange(selection)

        host.state.zoom = 1.2
        drainMainRunLoop()
        host.state.enterEdit()
        drainMainRunLoop()
        host.state.enterPreview()
        drainMainRunLoop()

        XCTAssertEqual(host.state.recorder.parsedSources.count, 1)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(preview.textStorage)), storageIdentity)
        XCTAssertEqual(preview.selectedRange(), selection)
    }

    // MARK: - Real AppKit Host & Resignation Tests (§6)

    func testHostedRepresentableTokenResignsOwnedEditorWithoutPublishing() throws {
        let host = makeHostedEditor(text: "Existing Note Content")
        let textView = try XCTUnwrap(host.state.syncBridge.textView)
        let originalIdentity = ObjectIdentifier(textView)

        XCTAssertTrue(host.window.makeFirstResponder(textView))
        XCTAssertTrue(host.window.firstResponder === textView)

        host.state.enterPreview()
        drainMainRunLoop()

        let installedTextView = try XCTUnwrap(host.state.syncBridge.textView)
        XCTAssertEqual(ObjectIdentifier(installedTextView), originalIdentity)
        XCTAssertFalse(host.window.firstResponder === textView)
        XCTAssertEqual(
            host.state.recorder.onTextChangedCount,
            0,
            "Focus-only updateNSView token handling MUST not invoke onTextChanged; production save scheduling is owned exclusively by that callback"
        )
    }

    func testHostedRepresentableTokenPreservesAnotherFirstResponder() throws {
        let host = makeHostedEditor(text: "Existing Note Content")
        let textView = try XCTUnwrap(host.state.syncBridge.textView)
        let otherResponder = NSTextField(frame: NSRect(x: 10, y: 10, width: 180, height: 24))
        host.container.addSubview(otherResponder)

        XCTAssertTrue(host.window.makeFirstResponder(otherResponder))
        let otherFirstResponder = try XCTUnwrap(host.window.firstResponder)
        XCTAssertFalse(otherFirstResponder === textView)

        host.state.enterPreview()
        drainMainRunLoop()

        XCTAssertTrue(host.window.firstResponder === otherFirstResponder)
        XCTAssertTrue(host.state.syncBridge.textView === textView)
        XCTAssertEqual(host.state.recorder.onTextChangedCount, 0)
    }

    func testHostedRepresentableReturningToEditDoesNotForceFocus() throws {
        let host = makeHostedEditor(text: "Existing Note Content")
        let textView = try XCTUnwrap(host.state.syncBridge.textView)
        XCTAssertTrue(host.window.makeFirstResponder(textView))

        host.state.enterPreview()
        drainMainRunLoop()
        XCTAssertFalse(host.window.firstResponder === textView)

        host.state.enterEdit()
        drainMainRunLoop()

        XCTAssertFalse(host.window.firstResponder === textView, "Returning to Edit MUST NOT force focus")
        XCTAssertTrue(host.state.syncBridge.textView === textView)
    }

    func testHostedRepresentableNativeUndoWorksAfterModeRoundTrip() throws {
        let host = makeHostedEditor(text: "")
        let textView = try XCTUnwrap(host.state.syncBridge.textView)
        XCTAssertTrue(host.window.makeFirstResponder(textView))

        textView.insertText("First edit", replacementRange: NSRange(location: 0, length: 0))
        drainMainRunLoop()
        XCTAssertEqual(textView.string, "First edit")
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        host.state.enterPreview()
        drainMainRunLoop()
        host.state.enterEdit()
        drainMainRunLoop()

        XCTAssertTrue(host.state.syncBridge.textView === textView)
        XCTAssertFalse(host.window.firstResponder === textView)
        textView.undoManager?.undo()
        drainMainRunLoop()

        XCTAssertEqual(textView.string, "", "Native Undo MUST restore text after the hosted production mode round trip")
    }

    func testTwoHostedRepresentablesMaintainIndependentModeAndTokenState() throws {
        let first = makeHostedEditor(text: "First")
        let second = makeHostedEditor(text: "Second")
        let firstTextView = try XCTUnwrap(first.state.syncBridge.textView)
        let secondTextView = try XCTUnwrap(second.state.syncBridge.textView)
        let firstEditorScrollView = try XCTUnwrap(firstTextView.enclosingScrollView)
        let secondEditorScrollView = try XCTUnwrap(secondTextView.enclosingScrollView)

        XCTAssertTrue(first.window.makeFirstResponder(firstTextView))
        XCTAssertTrue(second.window.makeFirstResponder(secondTextView))

        first.state.zoom = 1.3
        first.state.enterPreview()
        drainMainRunLoop()

        XCTAssertEqual(first.state.mode, .preview)
        XCTAssertEqual(first.state.resignFocusToggleToken, 1)
        XCTAssertFalse(first.window.firstResponder === firstTextView)
        XCTAssertEqual(second.state.mode, .edit)
        XCTAssertEqual(second.state.resignFocusToggleToken, 0)
        XCTAssertTrue(second.window.firstResponder === secondTextView)
        XCTAssertEqual(firstEditorScrollView.magnification, 1.3, accuracy: 0.0001)
        XCTAssertEqual(secondEditorScrollView.magnification, 1.0, accuracy: 0.0001)
        XCTAssertEqual(first.state.zoom, 1.3, accuracy: 0.0001)
        XCTAssertEqual(second.state.zoom, 1.0, accuracy: 0.0001)
    }

    func testSameNoteReloadPreservesPreviewModeUsingProductionPolicy() {
        let sameID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: sameID,
            newID: sameID
        )
        XCTAssertEqual(mode, .preview, "Production selection policy MUST preserve Preview mode on same-note reloads")
    }

    func testDifferentNoteSelectionResetsToEditModeUsingProductionPolicy() {
        let oldID = UUID()
        let newID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: oldID,
            newID: newID
        )
        XCTAssertEqual(mode, .edit, "Production selection policy MUST reset to Edit mode when selected note changes")
    }

    func testSyncDrivenRemovalResetsToEditModeUsingProductionPolicy() {
        let oldID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: oldID,
            newID: nil
        )
        XCTAssertEqual(mode, .edit, "Production selection policy MUST reset to Edit mode when selected note is removed")
    }

    func testIndependentSceneStatesDoNotInterfere() {
        let modeSceneA = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: UUID(),
            newID: UUID()
        )
        let sameID = UUID()
        let modeSceneB = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: sameID,
            newID: sameID
        )

        XCTAssertEqual(modeSceneA, .edit)
        XCTAssertEqual(modeSceneB, .preview, "Independent scenes MUST calculate their selection policy states independently")
    }

    // MARK: - Interaction State Policy

    func testInteractionStateIsEditInteractiveInEditMode() {
        let state = MarkdownPreviewInteractionPolicy.state(
            requestedMode: .edit,
            committedMode: .edit,
            hasPendingFocusRequest: false
        )
        XCTAssertEqual(state, .editInteractive)
        XCTAssertFalse(state.isPreviewOrPending)
    }

    func testInteractionStateIsPendingWhenFocusRequestIsOutstanding() {
        let state = MarkdownPreviewInteractionPolicy.state(
            requestedMode: .preview,
            committedMode: .edit,
            hasPendingFocusRequest: true
        )
        XCTAssertEqual(state, .previewTransitionPending)
        XCTAssertTrue(state.isPreviewOrPending)
    }

    func testInteractionStateIsVisiblePreviewWhenCommitted() {
        let state = MarkdownPreviewInteractionPolicy.state(
            requestedMode: .preview,
            committedMode: .preview,
            hasPendingFocusRequest: false
        )
        XCTAssertEqual(state, .previewVisible)
        XCTAssertTrue(state.isPreviewOrPending)
    }

    // MARK: - Resignation Policy (AppKit focus behavior)

    func testResignationWithNoTextChangeMeansAcknowledgeWithoutPublication() {
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: true,
            boundPlainText: "Note text",
            nativePlainText: "Note text"
        )
        XCTAssertEqual(disposition, .acknowledgeWithoutPublication,
            "AppKit Preview resignation with no text change MUST NOT schedule save or trigger onTextChanged")
    }

    func testResignationWithIMEMutationPublishesFinalizedEditThenAcknowledges() {
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: true,
            boundPlainText: "Draft",
            nativePlainText: "Draft + finalized"
        )
        XCTAssertEqual(disposition, .publishFinalizedUserEditThenAcknowledge,
            "AppKit Preview resignation with IME-finalized text MUST publish exactly once before acknowledging")
    }

    func testOrdinaryFocusLossProducesOrdinaryEndEditing() {
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: false,
            boundPlainText: "any",
            nativePlainText: "any"
        )
        XCTAssertEqual(disposition, .ordinaryEndEditing,
            "Non-Preview focus loss MUST follow ordinary end-editing path")
    }

    // MARK: - Search Isolation During Preview (AppKit)

    func testSearchSuppressedInPendingPreviewState() {
        XCTAssertFalse(
            MarkdownPreviewSearchInteractionPolicy.isSearchPresented(
                state: .previewTransitionPending,
                isSearchActiveInState: true
            ),
            "Search MUST be suppressed while AppKit Preview transition is pending"
        )
    }

    func testSearchSuppressedInVisiblePreviewState() {
        XCTAssertFalse(
            MarkdownPreviewSearchInteractionPolicy.isSearchPresented(
                state: .previewVisible,
                isSearchActiveInState: true
            ),
            "Search MUST be suppressed while AppKit Preview is visible"
        )
    }

    func testSearchBodyHighlightNilInAnyPreviewState() {
        let highlight = MarkdownPreviewSearchInteractionPolicy.bodyHighlightRange(
            state: .previewVisible,
            highlightRange: NSRange(location: 0, length: 5)
        )
        XCTAssertNil(highlight,
            "Body search highlight MUST be nil when AppKit Preview is visible — must not scroll hidden editor")
    }

    private func makeHostedEditor(
        text: String,
        parseOperation: MarkdownPreviewParser.ParseOperation? = nil,
        attributedText: NSAttributedString? = nil
    ) -> (state: MacMarkdownPreviewHostState, window: NSWindow, container: NSView) {
        let state = MacMarkdownPreviewHostState(text: text, parseOperation: parseOperation)
        if let attributedText {
            state.attributedText = attributedText
        }
        let hostingView = NSHostingView(rootView: MacMarkdownPreviewHostedEditor(state: state))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 520))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        drainMainRunLoop()

        XCTAssertNotNil(state.syncBridge.textView, "The production representable MUST install an NSTextView")
        XCTAssertNotNil(previewTextView(in: container), "The retained native Preview must be installed while inactive")
        return (state, window, container)
    }

    private func previewTextView(in root: NSView) -> NSTextView? {
        descendantTextViews(in: root).first {
            !$0.isEditable && $0.isSelectable && $0.isRichText
        }
    }

    private func descendantTextViews(in view: NSView) -> [NSTextView] {
        let current = (view as? NSTextView).map { [$0] } ?? []
        return current + view.subviews.flatMap(descendantTextViews(in:))
    }

    private func accessibilityIdentifiers(in root: Any) -> [String] {
        var visited: Set<ObjectIdentifier> = []
        var identifiers: [String] = []

        func visit(_ candidate: Any) {
            guard let object = candidate as? NSObject else { return }
            let identity = ObjectIdentifier(object)
            guard visited.insert(identity).inserted else { return }

            let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
            if object.responds(to: identifierSelector),
               let identifier = object.perform(identifierSelector)?.takeUnretainedValue() as? String,
               !identifier.isEmpty {
                identifiers.append(identifier)
            }

            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: childrenSelector),
               let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [Any] {
                for child in children {
                    visit(child)
                }
            }

            // NSHostingView does not expose every hosted accessibility element from
            // an unattached test container's AX root, so traverse its native view
            // hierarchy as well as the synthesized accessibility hierarchy.
            if let view = object as? NSView {
                for subview in view.subviews {
                    visit(subview)
                }
            }
        }

        visit(root)
        return identifiers
    }

    private func drainMainRunLoop() {
        let expectation = expectation(description: "RunLoop drain")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}
