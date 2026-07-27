#if os(macOS)
import SwiftUI

struct MacMarkdownCommandActions {
    let canImport: Bool
    let canExport: Bool
    let importMarkdown: () -> Void
    let exportMarkdown: () -> Void
}

private struct MacMarkdownCommandActionsKey: FocusedValueKey {
    typealias Value = MacMarkdownCommandActions
}

extension FocusedValues {
    var markdownCommandActions: MacMarkdownCommandActions? {
        get { self[MacMarkdownCommandActionsKey.self] }
        set { self[MacMarkdownCommandActionsKey.self] = newValue }
    }
}

struct MacMarkdownFileCommands: Commands {
    @FocusedValue(\.markdownCommandActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import Markdown…") {
                actions?.importMarkdown()
            }
            .disabled(actions?.canImport != true)

            Button("Export Markdown…") {
                actions?.exportMarkdown()
            }
            .disabled(actions?.canExport != true)
        }
    }
}
#endif
