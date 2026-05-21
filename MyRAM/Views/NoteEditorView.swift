// NoteEditorView.swift
import SwiftUI

struct NoteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: NotesViewModel
    let note: Note
    
    @State private var title: String = ""
    @State private var content: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                    .font(.title2)
                
                TextEditor(text: $content)
                    .frame(minHeight: 400)
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                title = note.title
                content = note.content
            }
            .onChange(of: title) { vm.updateNote(note, title: title, content: content) }
            .onChange(of: content) { vm.updateNote(note, title: title, content: content) }
        }
    }
}
