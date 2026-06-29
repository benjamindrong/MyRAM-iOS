#if os(macOS)
import AppKit
import Foundation
import SwiftData

@MainActor
final class MacNotePersistenceAdapter {
    private let context: ModelContext

    init() {
        self.context = PersistenceManager.shared.context
    }

    init(context: ModelContext) {
        self.context = context
    }

    func loadDefaultNote() throws -> Note {
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        if let note = try context.fetch(descriptor).first {
            return note
        }

        let note = Note(title: "Untitled", content: "")
        context.insert(note)
        try context.save()
        return note
    }

    func attributedContent(for note: Note) -> NSAttributedString {
        if let richTextContentData = note.richTextContentData,
           let attributedText = try? NSAttributedString(
            data: richTextContentData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            return Self.removingDefaultAppearanceColors(from: attributedText)
        }

        return NSAttributedString(string: note.content)
    }

    func save(note: Note, attributedContent: NSAttributedString) throws {
        guard note.deletedAt == nil else {
            throw MacNotePersistenceError.deletedNote
        }

        let storageContent = Self.removingDefaultAppearanceColors(from: attributedContent)
        note.content = storageContent.string
        note.richTextContentData = Self.encodeRTF(storageContent)
        note.modifiedAt = .now
        try context.save()
    }

    private static func encodeRTF(_ attributedContent: NSAttributedString) -> Data? {
        guard attributedContent.length > 0 else { return nil }

        return try? attributedContent.data(
            from: NSRange(location: 0, length: attributedContent.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    private static func removingDefaultAppearanceColors(from attributedContent: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedContent)
        let fullRange = NSRange(location: 0, length: mutable.length)

        // AppKit can serialize automatic editor colors as concrete black/white.
        // Strip default-looking colors so appearance decides them on reload.
        stripDefaultAppearanceColor(.foregroundColor, from: mutable, range: fullRange)
        stripDefaultAppearanceColor(.underlineColor, from: mutable, range: fullRange)
        stripDefaultAppearanceColor(.strikethroughColor, from: mutable, range: fullRange)
        return mutable
    }

    private static func stripDefaultAppearanceColor(
        _ key: NSAttributedString.Key,
        from attributedContent: NSMutableAttributedString,
        range: NSRange
    ) {
        attributedContent.enumerateAttribute(key, in: range) { value, range, _ in
            guard let color = value as? NSColor,
                  color.looksLikeDefaultAppearanceTextColor else { return }
            attributedContent.removeAttribute(key, range: range)
        }
    }
}

enum MacNotePersistenceError: Error, Equatable {
    case deletedNote
}

private extension NSColor {
    var looksLikeDefaultAppearanceTextColor: Bool {
        guard let components = rgbaComponents, components.alpha > 0.6 else { return false }
        return components.saturation <= 0.08
            && (components.luminance <= 0.42 || components.luminance >= 0.58)
    }

    var rgbaComponents: MacEditorRGBAComponents? {
        guard let color = usingColorSpace(.deviceRGB) ?? usingColorSpace(.sRGB) else {
            return nil
        }

        return MacEditorRGBAComponents(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
    }
}

private struct MacEditorRGBAComponents {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    var luminance: CGFloat {
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    var saturation: CGFloat {
        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        guard maxComponent > 0 else { return 0 }
        return (maxComponent - minComponent) / maxComponent
    }
}
#endif
