#if os(macOS)
import SwiftUI

@main
struct MyRAMMacApp: App {
    var body: some Scene {
        WindowGroup {
            MyRAMMacRootView()
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
