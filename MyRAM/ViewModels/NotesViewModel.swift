// NotesViewModel.swift
import SwiftUI
import SwiftData

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var currentNote: Note? = nil
    
    private static let recentlyDeletedRetention: TimeInterval = 7 * 24 * 60 * 60
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
}
