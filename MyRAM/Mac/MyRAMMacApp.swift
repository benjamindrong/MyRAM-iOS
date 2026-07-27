#if os(macOS)
import SwiftUI

@main
struct MyRAMMacApp: App {
    @StateObject private var markdownExternalImportCoordinator =
        MacMarkdownExternalImportCoordinator()

    var body: some Scene {
        WindowGroup {
            MyRAMMacRootView()
                .environmentObject(markdownExternalImportCoordinator)
        }
        .commands {
            TextEditingCommands()
            TextFormattingCommands()
            SidebarCommands()
            MacMarkdownFileCommands()
        }
    }
}
#endif
