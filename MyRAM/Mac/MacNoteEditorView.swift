#if os(macOS)
import AppKit
import SwiftUI

struct MacNoteEditorView: View {
    let note: Note?
    @Binding var title: String
    @Binding var attributedText: NSAttributedString
    /// MYR-195 Slice 2: mode state owned by MyRAMMacRootView; passed as binding so
    /// each scene has independent mode state.
    @Binding var markdownEditorMode: MarkdownEditorMode
    @ObservedObject var syncBridge: MacEditorSyncBridge
    @ObservedObject var formattingController: MacFormattingController
    let loadError: String?
    let saveError: String?
    let onTextChanged: () -> Void
    /// MYR-195 Slice 2: resign-only seam token forwarded to MacTextViewRepresentable.
    let resignFocusToggleToken: Int
    let noteViewZoom: CGFloat
    /// Constructor-threaded test seam; production callers use the parser-backed default.
    let markdownPreviewBuilder: MacMarkdownPreviewDocumentBuilder

    init(
        note: Note?,
        title: Binding<String> = .constant(""),
        attributedText: Binding<NSAttributedString>,
        markdownEditorMode: Binding<MarkdownEditorMode>,
        syncBridge: MacEditorSyncBridge,
        formattingController: MacFormattingController,
        loadError: String?,
        saveError: String?,
        onTextChanged: @escaping () -> Void,
        resignFocusToggleToken: Int,
        noteViewZoom: CGFloat,
        markdownPreviewBuilder: MacMarkdownPreviewDocumentBuilder =
            MacMarkdownPreviewDocumentBuilder()
    ) {
        self.note = note
        _title = title
        _attributedText = attributedText
        _markdownEditorMode = markdownEditorMode
        self.syncBridge = syncBridge
        self.formattingController = formattingController
        self.loadError = loadError
        self.saveError = saveError
        self.onTextChanged = onTextChanged
        self.resignFocusToggleToken = resignFocusToggleToken
        self.noteViewZoom = noteViewZoom
        self.markdownPreviewBuilder = markdownPreviewBuilder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            // MYR-195 Slice 2: mode picker. Routes through MyRAMMacRootView's modeSelection binding.
            Picker("Editor Mode", selection: $markdownEditorMode) {
                Text("Edit").tag(MarkdownEditorMode.edit)
                    .accessibilityIdentifier("markdown-edit-mode")
                Text("Preview").tag(MarkdownEditorMode.preview)
                    .accessibilityIdentifier("markdown-preview-mode")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("markdown-mode-picker")

            MacFormattingToolbar(controller: formattingController, enabled: note != nil && markdownEditorMode == .edit)

            // MYR-195 Slice 2: ZStack keeps the AppKit text view alive during Preview so its
            // undo manager, selection, and buffer are preserved across mode switches (§10.4).
            ZStack {
                MacTextViewRepresentable(
                    attributedText: $attributedText,
                    syncBridge: syncBridge,
                    formattingController: formattingController,
                    noteID: note?.id,
                    editorEnabled: markdownEditorMode == .edit,
                    onTextChanged: onTextChanged,
                    resignFocusToggleToken: resignFocusToggleToken,
                    zoom: noteViewZoom
                )
                .frame(minWidth: 160, minHeight: 200)
                // Screen-space padding belongs outside NSScrollView magnification.
                .padding(.horizontal, MacNoteViewZoom.screenSpaceHorizontalInset)
                .padding(.vertical, MacNoteViewZoom.screenSpaceVerticalInset)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }
                .opacity(markdownEditorMode == .edit ? 1 : 0)
                .allowsHitTesting(markdownEditorMode == .edit)
                .accessibilityHidden(markdownEditorMode != .edit)

                MacMarkdownPreviewTextView(
                    source: attributedText.string,
                    zoom: noteViewZoom,
                    isActive: markdownEditorMode == .preview,
                    builder: markdownPreviewBuilder
                )
                .frame(minWidth: 160, minHeight: 200)
                // Screen-space padding belongs outside NSScrollView magnification.
                .padding(.horizontal, MacNoteViewZoom.screenSpaceHorizontalInset)
                .padding(.vertical, MacNoteViewZoom.screenSpaceVerticalInset)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }
                .opacity(markdownEditorMode == .preview ? 1 : 0)
                .allowsHitTesting(markdownEditorMode == .preview)
                .accessibilityHidden(markdownEditorMode != .preview)
            }
            .frame(minWidth: 160, minHeight: 200)

            if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(minWidth: 200, minHeight: 280)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("NOTE TITLE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Untitled", text: $title)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.roundedBorder)
                .disabled(note == nil || markdownEditorMode != .edit)
                .help("Edit Title")
                .accessibilityLabel("Edit Title")
                .accessibilityIdentifier("mac-note-edit-title")
        }
    }
}
#endif
