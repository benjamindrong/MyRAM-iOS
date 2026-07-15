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

    func loadNotes() throws -> [Note] {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.deletedAt == nil
            }
        )

        return try context.fetch(descriptor).sortedByMacSelectionOrder()
    }

    func loadNotesCreatingFirstIfNeeded() throws -> [Note] {
        let notes = try loadNotes()
        guard notes.isEmpty else { return notes }

        return [try createNote()]
    }

    func loadNote(id: UUID) throws -> Note? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == id && note.deletedAt == nil
            }
        )

        return try context.fetch(descriptor).first
    }

    func loadDefaultNote() throws -> Note {
        if let note = try loadNotes().first {
            return note
        }

        return try createNote()
    }

    func createNote() throws -> Note {
        let note = Note()
        context.insert(note)
        try context.save()
        return note
    }

    func attributedContent(for note: Note) -> NSAttributedString {
        // Decode intentionally stays local to the Mac adapter: the Mac fallback omits
        // a base font because NSTextView manages its own defaults, while the editor
        // codec requires UIKit fallback attributes.
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

        let storageText = MacEditorTextColorPolicy.sanitizedForPersistence(attributedContent)
        assert(storageText.string == attributedContent.string, "Mac Auto-color persistence sanitization changed note text")
        note.content = storageText.string
        note.richTextContentData = RTFCoding.encode(storageText)
        note.modifiedAt = .now
        try context.save()
    }
}

enum MacNotePersistenceError: Error, Equatable {
    case deletedNote
}

private extension Array where Element == Note {
    func sortedByMacSelectionOrder() -> [Note] {
        sorted { first, second in
            if first.modifiedAt != second.modifiedAt {
                return first.modifiedAt > second.modifiedAt
            }

            if first.createdAt != second.createdAt {
                return first.createdAt > second.createdAt
            }

            // UUID string order makes equal-timestamp lists stable across fetches and test runs.
            return first.id.uuidString < second.id.uuidString
        }
    }
}
#endif
