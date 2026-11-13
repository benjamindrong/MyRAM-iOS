#if os(macOS)
import SwiftUI

/// Presentation only; the AppKit text view owns selection and MYR-227 owns persisted marks.
struct MacFormattingToolbar: View {
    @ObservedObject var controller: MacFormattingController
    let enabled: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                traitButton("Bold", icon: "bold", enabled: controller.selection.bold, command: .bold)
                traitButton("Italic", icon: "italic", enabled: controller.selection.italic, command: .italic)
                traitButton("Underline", icon: "underline", enabled: controller.selection.underline, command: .underline)
                traitButton("Strikethrough", icon: "strikethrough", enabled: controller.selection.strikethrough, command: .strikethrough)
                sizeMenu
                colorMenu
            }
            .fixedSize(horizontal: true, vertical: false)
            Menu("Formatting") { formattingMenuItems }
        }
        .disabled(!enabled || !controller.selection.enabled)
        .accessibilityIdentifier("mac-formatting-toolbar")
    }

    private func traitButton(
        _ title: String, icon: String, enabled: Bool?, command: MacFormattingCommand
    ) -> some View {
        Button { controller.perform(command) } label: {
            Image(systemName: icon)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.bordered)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(enabled.map { $0 ? "On" : "Off" } ?? "Mixed")
    }

    private var sizeMenu: some View {
        Menu {
            ForEach(11...40, id: \.self) { pointSize in
                Button("\(pointSize) pt") { controller.perform(.size(pointSize)) }
            }
        } label: {
            Text(controller.selection.pointSize.map { "\($0) pt" } ?? "Mixed size")
                .frame(minWidth: 65)
        }
        .help("Font Size (11–40 pt)")
        .accessibilityIdentifier("mac-font-size-menu")
    }

    private var colorMenu: some View {
        Menu {
            Button("Show Colors…") { controller.showColors() }
            Button("Default Text Color") { controller.perform(.color(nil)) }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
        .help("Text Color")
        .accessibilityIdentifier("mac-text-color-menu")
    }

    @ViewBuilder
    private var formattingMenuItems: some View {
        Button("Bold") { controller.perform(.bold) }
        Button("Italic") { controller.perform(.italic) }
        Button("Underline") { controller.perform(.underline) }
        Button("Strikethrough") { controller.perform(.strikethrough) }
        Divider()
        Button("Increase Font Size") { controller.perform(.adjustSize(1)) }
        Button("Decrease Font Size") { controller.perform(.adjustSize(-1)) }
        sizeMenu
        Divider()
        Button("Show Colors…") { controller.showColors() }
        Button("Default Text Color") { controller.perform(.color(nil)) }
    }
}
#endif
