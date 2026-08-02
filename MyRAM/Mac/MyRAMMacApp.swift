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
            MyRAMMacSceneRoot(
                markdownExternalImportCoordinator: markdownExternalImportCoordinator,
                widgetCoordinator: widgetCoordinator
            )
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

private struct MyRAMMacSceneRoot: View {
    @ObservedObject var markdownExternalImportCoordinator: MacMarkdownExternalImportCoordinator
    @ObservedObject var widgetCoordinator: MyRAMWidgetHostCoordinator
    @StateObject private var externalOpenDispatcher = MyRAMExternalOpenDispatcher()

    var body: some View {
        MyRAMMacRootView()
            .environmentObject(markdownExternalImportCoordinator)
            .environmentObject(externalOpenDispatcher)
            .environmentObject(widgetCoordinator)
            .onAppear {
                widgetCoordinator.start()
            }
    }
}
#endif
