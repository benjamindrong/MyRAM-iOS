import AppKit

final class EditorWindowController: NSWindowController {
    init(content: NSAttributedString) {
        let editorViewController = EditorViewController(content: content)
        let window = NSWindow(contentViewController: editorViewController)
        window.title = "MYR-96 Native macOS Editor Spike"
        window.setContentSize(NSSize(width: 960, height: 720))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
