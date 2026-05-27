// NotesViewModel.swift
import SwiftUI
import SwiftData

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var currentNote: Note? = nil
    
    private static let recentlyDeletedRetention: TimeInterval = 7 * 24 * 60 * 60
    private static let noteSectionSeparator = String(repeating: "=", count: 48)
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        purgeExpiredDeletedNotes()
        fetchNotes()
        loadLastNote()
    }

    func fetchNotes() {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        notes = (try? context.fetch(descriptor)) ?? []
    }

    func fetchRecentlyDeletedNotes() -> [Note] {
        purgeExpiredDeletedNotes()
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.deletedAt != nil },
            sortBy: [SortDescriptor(\.deletedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func loadLastNote() {
        if let idString = UserDefaults.standard.string(forKey: "lastNoteID"),
           let uuid = UUID(uuidString: idString),
           let note = notes.first(where: { $0.id == uuid }) {
            currentNote = note
        }
    }

    @discardableResult
    func createNewNote() -> Note {
        let note = Note()
        context.insert(note)
        try? context.save()
        fetchNotes()
        selectNote(note)
        return note
    }

    func selectNote(_ note: Note?) {
        currentNote = note
        UserDefaults.standard.set(note?.id.uuidString, forKey: "lastNoteID")
    }

    func updateNote(_ note: Note, title: String, content: String) {
        guard note.deletedAt == nil else { return }
        note.title = title
        note.content = content
        note.modifiedAt = .now
        try? context.save()
        fetchNotes()
    }

    func addPhotoAttachment(to note: Note, imageData: Data) {
        guard note.deletedAt == nil else { return }
        let attachment = NotePhotoAttachment(imageData: imageData, note: note)
        context.insert(attachment)
        note.photoAttachments.append(attachment)
        note.modifiedAt = .now
        try? context.save()
        fetchNotes()
    }

    func removePhotoAttachment(_ attachment: NotePhotoAttachment, from note: Note) {
        guard note.deletedAt == nil else { return }
        note.photoAttachments.removeAll { $0.id == attachment.id }
        context.delete(attachment)
        note.modifiedAt = .now
        try? context.save()
        fetchNotes()
    }

    func deleteNote(_ note: Note) {
        note.deletedAt = .now
        note.modifiedAt = .now
        try? context.save()
        fetchNotes()
        if currentNote?.id == note.id {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }
    }

    func restoreNote(_ note: Note) {
        note.deletedAt = nil
        note.modifiedAt = .now
        try? context.save()
        fetchNotes()
    }

    func permanentlyDeleteNote(_ note: Note) {
        context.delete(note)
        try? context.save()
        fetchNotes()
        if currentNote?.id == note.id {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }
    }

    private func purgeExpiredDeletedNotes() {
        let cutoff = Date().addingTimeInterval(-Self.recentlyDeletedRetention)
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt != nil })
        let deletedNotes = (try? context.fetch(descriptor)) ?? []

        for note in deletedNotes {
            if let deletedAt = note.deletedAt, deletedAt < cutoff {
                context.delete(note)
            }
        }

        try? context.save()
    }

    func exportNotesToTextFile(
        _ notesToExport: [Note],
        nowProvider: () -> Date = Date.init
    ) throws -> URL {
        let nonDeletedNotes = notesToExport.filter { $0.deletedAt == nil }
        guard !nonDeletedNotes.isEmpty else {
            throw NoteExportError.noNotesSelected
        }

        let exportText = Self.buildExportText(for: nonDeletedNotes)
        guard let utf8Data = exportText.data(using: .utf8) else {
            throw NoteExportError.failedToEncodeText
        }

        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyRAMExports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )

        let filename = Self.makeExportFilename(notes: nonDeletedNotes, now: nowProvider())
        let exportURL = exportDirectory.appendingPathComponent(filename)
        try utf8Data.write(to: exportURL, options: .atomic)
        return exportURL
    }

    static func buildExportText(
        for notes: [Note],
        dateFormatter: (Date) -> String = NotesViewModel.defaultDateFormatter
    ) -> String {
        let entries = notes.map { note in
            let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled"
                : note.title
            let body = note.content.isEmpty ? "(No content)" : note.content

            return [
                "Title: \(title)",
                "Created: \(dateFormatter(note.createdAt))",
                "Modified: \(dateFormatter(note.modifiedAt))",
                "Body:",
                body
            ].joined(separator: "\n")
        }

        let header = [
            "MyRAM Notes Export",
            "Exported: \(dateFormatter(Date()))",
            ""
        ].joined(separator: "\n")

        let body = entries.joined(separator: "\n\n\(noteSectionSeparator)\n\n")
        return "\(header)\(body)\n"
    }

    static func makeExportFilename(notes: [Note], now: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: now)

        if notes.count == 1 {
            let title = notes[0].title.trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitizedTitle = title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(40)
            let fallbackTitle = sanitizedTitle.isEmpty ? "Note" : String(sanitizedTitle)
            return "\(fallbackTitle)-\(timestamp).txt"
        }

        return "MyRAM-Notes-\(timestamp).txt"
    }

    static func defaultDateFormatter(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

enum NoteExportError: LocalizedError {
    case noNotesSelected
    case failedToEncodeText

    var errorDescription: String? {
        switch self {
        case .noNotesSelected:
            "No notes were selected to export."
        case .failedToEncodeText:
            "The note export could not be encoded as UTF-8."
        }
    }
}
