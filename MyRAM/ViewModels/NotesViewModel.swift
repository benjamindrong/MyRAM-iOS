// NotesViewModel.swift
import SwiftUI
import SwiftData

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var currentNote: Note? = nil
    
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        fetchNotes()
        loadLastNote()
    }

    func fetchNotes() {
        let descriptor = FetchDescriptor<Note>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)])
        notes = (try? context.fetch(descriptor)) ?? []
    }

    private func loadLastNote() {
        if let idString = UserDefaults.standard.string(forKey: "lastNoteID"),
           let uuid = UUID(uuidString: idString),
           let note = notes.first(where: { $0.id == uuid }) {
            currentNote = note
        }
    }

    func createNewNote() {
        let note = Note()
        context.insert(note)
        try? context.save()
        fetchNotes()
        selectNote(note)
    }

    func selectNote(_ note: Note?) {
        currentNote = note
        UserDefaults.standard.set(note?.id.uuidString, forKey: "lastNoteID")
    }

    func updateNote(_ note: Note, title: String, content: String) {
        note.title = title
        note.content = content
        note.modifiedAt = .now
        try? context.save()
        fetchNotes()
    }

    func deleteNote(_ note: Note) {
        context.delete(note)
        try? context.save()
        fetchNotes()
        if currentNote?.id == note.id {
            currentNote = nil
        }
    }
}
