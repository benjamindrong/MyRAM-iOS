#if os(macOS)
import SwiftUI

@main
struct MyRAMMacApp: App {
    init() {
#if DEBUG
        MyRAMSyncBenchmarkEnduranceMacIsolation.activateOrFailIfRequested()
        if MyRAMSyncBenchmarkConfiguration.isEnduranceRequested() {
            MyRAMSyncBenchmarkEnduranceRoutingGatedMacDriver.shared.startIfNeeded()
        }
#endif
    }

    var body: some Scene {
        WindowGroup {
            MyRAMMacAppRootFactory.makeRoot(
                environment: ProcessInfo.processInfo.environment,
                isXCTestRuntimeLoaded: NSClassFromString("XCTestCase") != nil
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

enum MyRAMMacAppRootFactory {
    static func makeRoot(
        environment: [String: String],
        isXCTestRuntimeLoaded: Bool,
        hostedRoot: () -> AnyView = { AnyView(MyRAMMacHostedTestRoot()) },
        productionRoot: () -> AnyView = { AnyView(MyRAMMacProductionRoot()) }
    ) -> AnyView {
        if MacStartupNetworkingPolicy.isHostedTest(
            environment: environment,
            isXCTestRuntimeLoaded: isXCTestRuntimeLoaded
        ) {
            return hostedRoot()
        }
        return productionRoot()
    }
}

private struct MyRAMMacHostedTestRoot: View {
    var body: some View {
        Color.clear
            .frame(minWidth: 1, minHeight: 1)
            .accessibilityHidden(true)
    }
}

private struct MyRAMMacProductionRoot: View {
    @StateObject private var markdownExternalImportCoordinator =
        MacMarkdownExternalImportCoordinator()
    @StateObject private var widgetCoordinator: MyRAMWidgetHostCoordinator
    @StateObject private var externalOpenDispatcher = MyRAMExternalOpenDispatcher()

    init() {
        _widgetCoordinator = StateObject(wrappedValue: MyRAMWidgetHostCoordinator(
            container: PersistenceManager.shared.container,
            observedContext: PersistenceManager.shared.context,
            platform: .macOS
        ))
    }

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
