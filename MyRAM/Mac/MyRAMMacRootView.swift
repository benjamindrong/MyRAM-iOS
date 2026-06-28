#if os(macOS)
import SwiftUI

struct MyRAMMacRootView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MyRAM")
                    .font(.largeTitle.weight(.semibold))
                Text(platformStatus)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Label("Native Mac shell is ready for future desktop UI.", systemImage: "macwindow")
                .font(.title3)
            Text("The production note editor is intentionally placeholder-only in MYR-105.")
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(minWidth: 520, minHeight: 340)
    }

    private var platformStatus: String {
        // Keep platform identity centralized in the shared helper introduced for the Mac port.
        MyRAMPlatform.isNativeMacOS ? "Native macOS target" : "Unsupported platform"
    }
}
#endif
