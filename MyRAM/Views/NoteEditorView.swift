//
//  NoteEditorView.swift
//  MyRAM
//
//  Created by Benjamin Drong on 10/19/25.
//

import SwiftUI
import SwiftData

struct NoteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: NotesViewModel
    let noteToEdit: Note? // nil for new note

    @State private var title: String = ""
    @State private var content: String = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextEditor(text: $content)
                    .frame(height: 250)
            }
            .navigationTitle(noteToEdit == nil ? "New Note" : "Edit Note")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let note = noteToEdit {
                            vm.update(note: note, title: title, content: content)
                        } else {
                            vm.saveNewNote(title: title, content: content)
                        }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let note = noteToEdit {
                    title = note.title
                    content = note.content
                }
            }
        }
    }
}
