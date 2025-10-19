//
//  NotesListView.swift
//  MyRAM
//
//  Created by Benjamin Drong on 10/19/25.
//

import SwiftUI
import SwiftData

struct NotesListView: View {
    @StateObject var vm: NotesViewModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(vm.notes) { note in
                    Button {
                        vm.startEditing(note: note)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(note.title)
                                .font(.headline)
                            Text(note.content)
                                .lineLimit(1)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let note = vm.notes[index]
                        vm.delete(note: note)
                    }
                }
            }
            .navigationTitle(vm.folder.name)
            .toolbar {
                Button {
                    vm.startCreatingNewNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
            }
            .sheet(isPresented: $vm.isCreatingNewNote) {
                NoteEditorView(vm: vm, noteToEdit: nil)
            }
            .sheet(item: $vm.editingNote) { note in
                // If note is nil, create new note inside editor
                NoteEditorView(vm: vm, noteToEdit: note)
            }
        }
    }
}
