#if os(macOS)
import AppKit
import SwiftUI

struct MacNoteEditorView: View {
    let note: Note?
    @Binding var attributedText: NSAttributedString
    let loadError: String?
    let saveError: String?
    let onTextChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            MacTextViewRepresentable(attributedText: $attributedText, onTextChanged: onTextChanged)
                .frame(minWidth: 640, minHeight: 460)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }

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
        .padding(28)
        .frame(minWidth: 720, minHeight: 560)
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
