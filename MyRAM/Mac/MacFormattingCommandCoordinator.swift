#if os(macOS)
import AppKit
import SwiftUI

enum MacFormattingCommand {
    case bold, italic, underline, strikethrough
    case size(Int), adjustSize(Int)
    case color(NSColor?)
}

struct MacFormattingSelectionState: Equatable {
    var enabled = false
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    var pointSize: Int?
    var defaultColor: Bool?
}

/// Editor intent only: all persisted and transmitted marks remain owned by MYR-227.
@MainActor
enum MacFormattingMutation {
    static let defaultFont = MacStructuralFormattingAdapter.defaultBodyFont

    static func transform(
        _ source: NSAttributedString,
        range: NSRange,
        command: MacFormattingCommand
    ) -> NSAttributedString {
        guard range.location >= 0, range.length > 0,
              range.location <= source.length,
              range.length <= source.length - range.location else { return source }
        let enable = shouldEnable(command, attributes: attributeRuns(in: source, range: range))
        let result = NSMutableAttributedString(attributedString: source)
        source.enumerateAttributes(in: range) { attributes, part, _ in
            result.setAttributes(changing(attributes, command: command, enable: enable), range: part)
        }
        return result
    }

    static func typingAttributes(
        _ source: [NSAttributedString.Key: Any],
        command: MacFormattingCommand
    ) -> [NSAttributedString.Key: Any] {
        changing(source, command: command, enable: shouldEnable(command, attributes: [source]))
    }

    static func supportedTypingAttributes(
        _ source: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        let supported: Set<NSAttributedString.Key> = [
            .font, .underlineStyle, .strikethroughStyle, .foregroundColor,
            .autoTextColorDisplay, .explicitStructuralFontSizeMilliPoints
        ]
        return MacEditorTextColorPolicy.normalizedTypingAttributes(
            source.filter { supported.contains($0.key) }
        )
    }

    static func attributeRuns(
        in source: NSAttributedString, range: NSRange
    ) -> [[NSAttributedString.Key: Any]] {
        var result: [[NSAttributedString.Key: Any]] = []
        if range.length > 0 {
            source.enumerateAttributes(in: range) { attributes, _, _ in result.append(attributes) }
        }
        return result
    }

    static func state(
        from source: NSAttributedString,
        selection: NSRange,
        typing: [NSAttributedString.Key: Any],
        enabled: Bool
    ) -> MacFormattingSelectionState {
        guard enabled else { return MacFormattingSelectionState() }
        let runs = selection.length == 0 ? [typing] : attributeRuns(in: source, range: selection)
        func uniform<T: Equatable>(_ value: ([NSAttributedString.Key: Any]) -> T) -> T? {
            guard let first = runs.first.map(value), runs.allSatisfy({ value($0) == first }) else {
                return nil
            }
            return first
        }
        return MacFormattingSelectionState(
            enabled: true,
            bold: uniform { font(in: $0).fontDescriptor.symbolicTraits.contains(.bold) },
            italic: uniform { font(in: $0).fontDescriptor.symbolicTraits.contains(.italic) },
            underline: uniform { decorated($0[.underlineStyle]) },
            strikethrough: uniform { decorated($0[.strikethroughStyle]) },
            pointSize: uniform { Int(font(in: $0).pointSize.rounded()) },
            defaultColor: uniform { inheritedColor($0) }
        )
    }

    private static func shouldEnable(
        _ command: MacFormattingCommand,
        attributes: [[NSAttributedString.Key: Any]]
    ) -> Bool {
        switch command {
        case .bold:
            return attributes.contains { !font(in: $0).fontDescriptor.symbolicTraits.contains(.bold) }
        case .italic:
            return attributes.contains { !font(in: $0).fontDescriptor.symbolicTraits.contains(.italic) }
        case .underline:
            return attributes.contains { !decorated($0[.underlineStyle]) }
        case .strikethrough:
            return attributes.contains { !decorated($0[.strikethroughStyle]) }
        case .size, .adjustSize, .color:
            return true
        }
    }

    private static func changing(
        _ source: [NSAttributedString.Key: Any],
        command: MacFormattingCommand,
        enable: Bool
    ) -> [NSAttributedString.Key: Any] {
        var result = source
        switch command {
        case .bold, .italic:
            let base = font(in: source)
            var traits = base.fontDescriptor.symbolicTraits
            let trait: NSFontDescriptor.SymbolicTraits = command.isBold ? .bold : .italic
            if enable { traits.insert(trait) } else { traits.remove(trait) }
            let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
            result[.font] = NSFont(descriptor: descriptor, size: base.pointSize)
                ?? NSFont.systemFont(ofSize: base.pointSize)
        case .underline, .strikethrough:
            let key: NSAttributedString.Key = command.isUnderline ? .underlineStyle : .strikethroughStyle
            if enable { result[key] = NSUnderlineStyle.single.rawValue }
            else { result.removeValue(forKey: key) }
            result.removeValue(forKey: command.isUnderline ? .underlineColor : .strikethroughColor)
        case .size(let points):
            guard (11...40).contains(points) else { return source }
            guard let resized = NSFont(descriptor: font(in: source).fontDescriptor, size: CGFloat(points)) else {
                return source
            }
            result[.font] = resized
            result[.explicitStructuralFontSizeMilliPoints] = points * 1_000
        case .adjustSize(let step):
            let current = Int(font(in: source).pointSize.rounded())
            let points = min(max(current + step, 11), 40)
            guard let resized = NSFont(descriptor: font(in: source).fontDescriptor, size: CGFloat(points)) else {
                return source
            }
            result[.font] = resized
            result[.explicitStructuralFontSizeMilliPoints] = points * 1_000
        case .color(let color):
            if let color {
                guard let rgb = color.usingColorSpace(.sRGB),
                      let rgba = NoteStructuralFormattingCanonicalization.rgbaColor(
                        red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                        blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent)
                      ) else { return source }
                result[.foregroundColor] = NSColor(
                    srgbRed: CGFloat(rgba.red) / 255, green: CGFloat(rgba.green) / 255,
                    blue: CGFloat(rgba.blue) / 255, alpha: CGFloat(rgba.alpha) / 255
                )
                result.removeValue(forKey: .autoTextColorDisplay)
            } else {
                result[.foregroundColor] = NSColor.textColor
                result[.autoTextColorDisplay] = true
            }
            result.removeValue(forKey: .underlineColor)
            result.removeValue(forKey: .strikethroughColor)
        }
        return result
    }

    private static func font(in attributes: [NSAttributedString.Key: Any]) -> NSFont {
        attributes[.font] as? NSFont ?? defaultFont
    }

    private static func decorated(_ value: Any?) -> Bool {
        ((value as? NSNumber)?.intValue ?? 0) != 0
    }

    private static func inheritedColor(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        (attributes[.autoTextColorDisplay] as? Bool) == true ||
        attributes[.foregroundColor] == nil ||
        (attributes[.foregroundColor] as? NSColor)?.isEqual(NSColor.textColor) == true
    }
}

private extension MacFormattingCommand {
    var isBold: Bool { if case .bold = self { return true }; return false }
    var isUnderline: Bool { if case .underline = self { return true }; return false }
}

@MainActor
final class MacFormattingController: ObservableObject {
    @Published private(set) var selection = MacFormattingSelectionState()
    weak var textView: NSTextView?
    private var noteID: UUID?
    private var editorEnabled = false
    private let injectedUndoManager: UndoManager?

    init(undoManager: UndoManager? = nil) {
        injectedUndoManager = undoManager
    }

    private func activeUndoManager(for view: NSTextView) -> UndoManager? {
        injectedUndoManager ?? view.undoManager
    }

    func bind(textView: NSTextView, noteID: UUID?, enabled: Bool) {
        if self.noteID != noteID || self.textView !== textView {
            activeUndoManager(for: textView)?.removeAllActions()
        }
        self.textView = textView
        self.noteID = noteID
        editorEnabled = enabled && noteID != nil
        refreshSelection()
    }

    func refreshSelection() {
        guard let view = textView, let storage = view.textStorage else {
            if selection != MacFormattingSelectionState() { selection = MacFormattingSelectionState() }
            return
        }
        let next = MacFormattingMutation.state(
            from: storage, selection: view.selectedRange(),
            typing: view.typingAttributes, enabled: editorEnabled
        )
        if selection != next { selection = next }
    }

    func perform(_ command: MacFormattingCommand) {
        guard editorEnabled, let view = textView, let storage = view.textStorage,
              let noteID else { return }
        let range = view.selectedRange()
        guard range.location >= 0, range.length >= 0,
              range.location <= storage.length,
              range.length <= storage.length - range.location else { return }
        if range.length == 0 {
            view.typingAttributes = MacFormattingMutation.supportedTypingAttributes(
                MacFormattingMutation.typingAttributes(view.typingAttributes, command: command)
            )
            refreshSelection()
            view.window?.makeFirstResponder(view)
            return
        }
        let before = NSAttributedString(attributedString: storage)
        let after = MacFormattingMutation.transform(before, range: range, command: command)
        guard !before.isEqual(to: after) else { return }
        apply(after.attributedSubstring(from: range), at: range, to: view, noteID: noteID)
        view.window?.makeFirstResponder(view)
    }

    func showColors() {
        guard editorEnabled, let view = textView else { return }
        view.window?.makeFirstResponder(view)
        NSColorPanel.shared.orderFront(nil)
    }

    private func apply(
        _ replacement: NSAttributedString,
        at range: NSRange,
        to view: NSTextView,
        noteID: UUID
    ) {
        guard self.noteID == noteID, let storage = view.textStorage,
              range.location >= 0, range.length > 0,
              range.location <= storage.length,
              range.length <= storage.length - range.location,
              storage.attributedSubstring(from: range).string == replacement.string else { return }
        let inverse = storage.attributedSubstring(from: range)
        if inverse.isEqual(to: replacement) { return }
        storage.beginEditing()
        replacement.enumerateAttributes(in: NSRange(location: 0, length: replacement.length)) { attributes, part, _ in
            storage.setAttributes(attributes, range: NSRange(location: range.location + part.location, length: part.length))
        }
        storage.endEditing()
        view.setSelectedRange(range)
        refreshSelection()
        activeUndoManager(for: view)?.registerUndo(withTarget: self) { [weak view] controller in
            guard let view else { return }
            controller.apply(inverse, at: range, to: view, noteID: noteID)
        }
        activeUndoManager(for: view)?.setActionName("Format Text")
    }
}

struct MacFormattingSceneActions {
    let enabled: Bool
    let perform: (MacFormattingCommand) -> Void
    let showColors: () -> Void
}

private struct MacFormattingSceneActionsKey: FocusedValueKey {
    typealias Value = MacFormattingSceneActions
}

extension FocusedValues {
    var macFormattingActions: MacFormattingSceneActions? {
        get { self[MacFormattingSceneActionsKey.self] }
        set { self[MacFormattingSceneActionsKey.self] = newValue }
    }
}

struct MacFormattingMenuCommands: Commands {
    @FocusedValue(\.macFormattingActions) private var actions

    var body: some Commands {
        CommandMenu("Format") {
            Button("Bold") { actions?.perform(.bold) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(actions?.enabled != true)
            Button("Italic") { actions?.perform(.italic) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(actions?.enabled != true)
            Button("Underline") { actions?.perform(.underline) }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(actions?.enabled != true)
            Button("Strikethrough") { actions?.perform(.strikethrough) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(actions?.enabled != true)
            Divider()
            Button("Increase Font Size") { actions?.perform(.adjustSize(1)) }
                .keyboardShortcut("+", modifiers: [.command, .shift])
                .disabled(actions?.enabled != true)
            Button("Decrease Font Size") { actions?.perform(.adjustSize(-1)) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(actions?.enabled != true)
            Divider()
            Button("Show Colors…") { actions?.showColors() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(actions?.enabled != true)
            Button("Default Text Color") { actions?.perform(.color(nil)) }
                .disabled(actions?.enabled != true)
        }
        // Disabled explicitly in Preview/without an active note; keyboard and
        // toolbar actions share the same bound command owner.
    }
}
#endif
