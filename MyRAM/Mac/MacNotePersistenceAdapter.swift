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
            return attributedText
        }

        return NSAttributedString(string: note.content)
    }

    func save(note: Note, attributedContent: NSAttributedString) throws {
        guard note.deletedAt == nil else {
            throw MacNotePersistenceError.deletedNote
        }

        note.content = attributedContent.string
        note.richTextContentData = Self.encodeRTF(attributedContent)
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
}

enum MacNotePersistenceError: Error, Equatable {
    case deletedNote
}
#endif
