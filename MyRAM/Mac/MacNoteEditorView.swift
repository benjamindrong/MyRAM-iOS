#if os(macOS)
import SwiftUI

struct MacNoteEditorView: View {
    @State private var sampleText = MacEditorSampleDocument.makeSampleText()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            MacTextViewRepresentable(text: $sampleText)
                .frame(minWidth: 640, minHeight: 460)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
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
        MyRAMPlatform.isNativeMacOS ? "Native macOS editor foundation" : "Unsupported platform"
    }
}
#endif
