#if os(macOS)
import SwiftUI

@main
struct MyRAMMacApp: App {
    @StateObject private var markdownExternalImportCoordinator =
        MacMarkdownExternalImportCoordinator()
    @StateObject private var widgetCoordinator: MyRAMWidgetHostCoordinator

    init() {
        _widgetCoordinator = StateObject(wrappedValue: MyRAMWidgetHostCoordinator(
            container: PersistenceManager.shared.container,
            observedContext: PersistenceManager.shared.context,
            platform: .macOS
        ))
    }

    var body: some Scene {
        WindowGroup {
            MyRAMMacRootView()
                .environmentObject(markdownExternalImportCoordinator)
                .environmentObject(widgetCoordinator)
                .onAppear {
                    widgetCoordinator.start()
                }
        }
        .commands {
            TextEditingCommands()
            TextFormattingCommands()
            SidebarCommands()
            MacNoteViewZoomCommands()
            MacMarkdownFileCommands()
        }
    }
}
#endif
