#if os(macOS)
import AppKit
import SwiftUI

struct MacNoteEditorView: View {
    let note: Note?
    @Binding var attributedText: NSAttributedString
    /// MYR-195 Slice 2: mode state owned by MyRAMMacRootView; passed as binding so
    /// each scene has independent mode state.
    @Binding var markdownEditorMode: MarkdownEditorMode
    @ObservedObject var syncBridge: MacEditorSyncBridge
    let loadError: String?
    let saveError: String?
    let onTextChanged: () -> Void
    /// MYR-195 Slice 2: resign-only seam token forwarded to MacTextViewRepresentable.
    let resignFocusToggleToken: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            // MYR-195 Slice 2: ZStack keeps the AppKit text view alive during Preview so its
            // undo manager, selection, and buffer are preserved across mode switches (§10.4).
            ZStack {
                MacTextViewRepresentable(
                    attributedText: $attributedText,
                    syncBridge: syncBridge,
                    onTextChanged: onTextChanged,
                    resignFocusToggleToken: resignFocusToggleToken
                )
                .frame(minWidth: 160, minHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }
                .opacity(markdownEditorMode == .edit ? 1 : 0)
                .allowsHitTesting(markdownEditorMode == .edit)
                .accessibilityHidden(markdownEditorMode != .edit)

                if markdownEditorMode == .preview {
                    MarkdownPreviewView(source: attributedText.string)
                        .frame(minWidth: 160, minHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.separator, lineWidth: 1)
                        }
                }
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
        .padding(16)
        .frame(minWidth: 200, minHeight: 280)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MyRAM")
                .font(.title.weight(.semibold))
            Text(platformStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var platformStatus: String {
        // Keep platform identity centralized in the shared helper introduced for the Mac port.
        guard MyRAMPlatform.isNativeMacOS else { return "Unsupported platform" }
        return note.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Loading Untitled note"
    }
}
#endif
