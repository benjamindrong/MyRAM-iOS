// NotesListView.swift
import SwiftUI
import SwiftData

struct NotesListView: View {
    @StateObject private var vm: NotesViewModel
    @State private var selectedNote: Note? = nil
    
    init(context: ModelContext) {
        _vm = StateObject(wrappedValue: NotesViewModel(context: context))
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(vm.notes) { note in
                    Button {
                        vm.selectNote(note)
                        selectedNote = note
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.title.isEmpty ? "Untitled" : note.title)
                                .font(.headline)
                            Text(note.content.isEmpty ? "No content yet" : note.content)
                                .lineLimit(2)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        vm.deleteNote(vm.notes[index])
                    }
                }
            }
            .navigationTitle("My Notes")
            .toolbar {
                Button {
                    selectedNote = vm.createNewNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
            }
            .sheet(item: $selectedNote) { note in
                NoteEditorView(vm: vm, note: note) { newNote in
                    selectedNote = newNote
                }
            }
        }
        .onChange(of: vm.currentNote) { _, newValue in
            if let newValue, selectedNote == nil {
                selectedNote = newValue
            }
        }
    }
}
