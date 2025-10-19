import SwiftUI
import SwiftData

@MainActor
final class NotesViewModel: ObservableObject {
    @Bindable var folder: Folder
    @Published var notes: [Note] = []
    
    // Tracks editing or new note
    @Published var editingNote: Note? = nil
    @Published var isCreatingNewNote = false
    
    init(folder: Folder) {
        self.folder = folder
        self.notes = folder.notes
    }
    
    func startEditing(note: Note) {
        editingNote = note
        isCreatingNewNote = false
    }
    
    func startCreatingNewNote() {
        editingNote = nil
        isCreatingNewNote = true
    }
    
    func saveNewNote(title: String, content: String) {
        guard let context = folder.modelContext else { return }
        let newNote = Note(title: title, content: content, folder: folder)
        context.insert(newNote)
        folder.notes.append(newNote)
        notes.append(newNote) // triggers SwiftUI update
        try? context.save()
        isCreatingNewNote = false
    }
    
    // Add a new note only when saving
//    func addNote(title: String, content: String) {
//        guard let context = folder.modelContext else { return }
//        let note = Note(title: title, content: content, folder: folder)
//        context.insert(note)
//        folder.notes.append(note)
//        notes.append(note)
//        try? context.save()
//    }
    
    func update(note: Note, title: String, content: String) {
        note.title = title
        note.content = content
        note.modifiedAt = .now
        try? folder.modelContext?.save()
    }
    
    func delete(note: Note) {
        folder.notes.removeAll { $0.id == note.id }
        notes.removeAll { $0.id == note.id }
        folder.modelContext?.delete(note)
        try? folder.modelContext?.save()
    }
}
