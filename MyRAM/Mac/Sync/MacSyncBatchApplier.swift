#if os(macOS)
// AppKit provides macOS RTF decoding/encoding support for NSAttributedString.
import AppKit
import Foundation
import SwiftData

@MainActor
final class MacSyncBatchApplier {
    private let context: ModelContext
    private let seenBatchStore: MacSyncSeenBatchStore

    init(context: ModelContext, seenBatchStore: MacSyncSeenBatchStore = MacSyncSeenBatchStore()) {
        self.context = context
        self.seenBatchStore = seenBatchStore
    }

    func apply(_ batch: MacSyncBatch) throws {
        guard !seenBatchStore.hasSeen(batch.id) else { return }

        for change in batch.changes {
            try apply(change)
        }

        try context.save()
        seenBatchStore.markSeen(batch.id)
    }

    private func apply(_ change: MacSyncChange) throws {
        switch change {
        case .noteCreated(let change):
            try applyNoteCreated(change)
        case .noteTitleChanged(let change):
            try applyTitleChanged(change)
        case .noteBodyTextInserted(let change):
            try applyBodyTextInserted(change)
        case .noteBodyTextDeleted(let change):
            try applyBodyTextDeleted(change)
        }
    }

    private func applyNoteCreated(_ change: MacSyncNoteCreatedChange) throws {
        guard try loadNote(id: change.noteID) == nil else { return }

        let note = Note(title: change.title, content: change.body, folder: try loadFolder(id: change.folderID))
        note.id = change.noteID
        note.createdAt = change.createdAt
        note.modifiedAt = change.modifiedAt
        context.insert(note)
    }

    private func applyTitleChanged(_ change: MacSyncNoteTitleChangedChange) throws {
        guard let note = try loadNote(id: change.noteID) else { return }

        note.title = change.title
        note.modifiedAt = change.modifiedAt
    }

    private func applyBodyTextInserted(_ change: MacSyncNoteBodyTextInsertedChange) throws {
        guard let note = try loadNote(id: change.noteID), !change.text.isEmpty else { return }

        let originalContent = note.content
        let clampedOffset = originalContent.clampedUTF16Offset(change.utf16Offset)
        let insertionOffset = originalContent.safeInsertionOffset(fallingForwardFrom: clampedOffset)
        note.content = originalContent.inserting(change.text, atUTF16Offset: insertionOffset)
        updateRichTextContent(for: note, originalPlainText: originalContent) { attributedText in
            attributedText.insert(NSAttributedString(string: change.text), at: insertionOffset)
        }
        note.modifiedAt = change.modifiedAt
    }

    private func applyBodyTextDeleted(_ change: MacSyncNoteBodyTextDeletedChange) throws {
        guard let note = try loadNote(id: change.noteID),
              change.utf16Length > 0,
              let range = note.content.safeUTF16Range(location: change.utf16Offset, length: change.utf16Length) else {
            return
        }

        let targetText = (note.content as NSString).substring(with: range)
        if let expectedText = change.expectedText, targetText != expectedText {
            return
        }

        let originalContent = note.content
        note.content = (note.content as NSString).replacingCharacters(in: range, with: "")
        updateRichTextContent(for: note, originalPlainText: originalContent) { attributedText in
            guard NSMaxRange(range) <= attributedText.length else { return }
            attributedText.deleteCharacters(in: range)
        }
        note.modifiedAt = change.modifiedAt
    }

    private func loadNote(id: UUID) throws -> Note? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == id && note.deletedAt == nil
            }
        )
        return try context.fetch(descriptor).first
    }

    private func loadFolder(id: UUID?) throws -> Folder? {
        guard let id else { return nil }
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { folder in
                folder.id == id
            }
        )
        // Missing folder references intentionally fall back to root so the note is preserved.
        return try context.fetch(descriptor).first
    }

    private func updateRichTextContent(
        for note: Note,
        originalPlainText: String,
        mutation: (NSMutableAttributedString) -> Void
    ) {
        guard let richTextContentData = note.richTextContentData,
              let attributedText = try? NSMutableAttributedString(
                data: richTextContentData,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ),
              attributedText.string == originalPlainText else {
            // RTF is absent, stale, or cannot be decoded. Clear it so the Mac loader
            // falls back to note.content rather than displaying a mismatched rich-text body.
            note.richTextContentData = nil
            return
        }

        mutation(attributedText)
        note.richTextContentData = RTFCoding.encode(attributedText)
    }
}

private extension String {
    func clampedUTF16Offset(_ offset: Int) -> Int {
        min(max(offset, 0), utf16.count)
    }

    func safeInsertionOffset(fallingForwardFrom offset: Int) -> Int {
        var candidate = clampedUTF16Offset(offset)
        while candidate < utf16.count, safeUTF16Range(location: candidate, length: 0) == nil {
            candidate += 1
        }
        return candidate
    }

    func inserting(_ text: String, atUTF16Offset offset: Int) -> String {
        let nsString = self as NSString
        return nsString.replacingCharacters(in: NSRange(location: clampedUTF16Offset(offset), length: 0), with: text)
    }

    func safeUTF16Range(location: Int, length: Int) -> NSRange? {
        guard location >= 0, length >= 0, location + length <= utf16.count else {
            return nil
        }

        guard isValidUTF16Boundary(location), isValidUTF16Boundary(location + length) else {
            return nil
        }

        let range = NSRange(location: location, length: length)
        guard Range(range, in: self) != nil else { return nil }
        return range
    }

    private func isValidUTF16Boundary(_ offset: Int) -> Bool {
        guard offset >= 0, offset <= utf16.count else { return false }
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: offset)
        return String.Index(utf16Index, within: self) != nil
    }
}
#endif
