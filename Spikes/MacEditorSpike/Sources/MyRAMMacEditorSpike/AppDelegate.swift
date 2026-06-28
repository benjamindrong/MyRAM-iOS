import AppKit
import MacEditorCore

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: EditorWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = LargeAttributedNoteFactory.makeSampleNote()
        let controller = EditorWindowController(content: content)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
