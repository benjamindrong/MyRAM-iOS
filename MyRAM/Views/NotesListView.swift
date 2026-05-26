// NotesListView.swift
import SwiftUI
import SwiftData

struct NotesListView: View {
    @StateObject private var vm: NotesViewModel
    @State private var selectedNote: Note? = nil
    @State private var showingRecentlyDeleted = false
    @State private var recentlyDeletedNotes: [Note] = []
    @AppStorage("appearanceSetting") private var appearanceSettingRaw = AppearanceSetting.system.rawValue
    
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Appearance", selection: $appearanceSettingRaw) {
                            ForEach(AppearanceSetting.allCases) { appearanceSetting in
                                Text(appearanceSetting.title).tag(appearanceSetting.rawValue)
                            }
                        }
                    } label: {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                    }

                    Button {
                        recentlyDeletedNotes = vm.fetchRecentlyDeletedNotes()
                        showingRecentlyDeleted = true
                    } label: {
                        Label("Recently Deleted", systemImage: "trash")
                    }

                    Button {
                        selectedNote = vm.createNewNote()
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                }
            }
            .sheet(item: $selectedNote) { note in
                NoteEditorView(vm: vm, note: note) { newNote in
                    selectedNote = newNote
                }
            }
            .sheet(isPresented: $showingRecentlyDeleted) {
                RecentlyDeletedView(
                    notes: recentlyDeletedNotes,
                    onRestore: { note in
                        vm.restoreNote(note)
                        recentlyDeletedNotes = vm.fetchRecentlyDeletedNotes()
                    },
                    onDelete: { note in
                        vm.permanentlyDeleteNote(note)
                        recentlyDeletedNotes = vm.fetchRecentlyDeletedNotes()
                    }
                )
            }
        }
        .onChange(of: vm.currentNote) { _, newValue in
            if let newValue, selectedNote == nil {
                selectedNote = newValue
            }
        }
    }
}

private struct RecentlyDeletedView: View {
    @Environment(\.dismiss) private var dismiss
    let notes: [Note]
    let onRestore: (Note) -> Void
    let onDelete: (Note) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if notes.isEmpty {
                    ContentUnavailableView(
                        "No Recently Deleted Notes",
                        systemImage: "trash",
                        description: Text("Deleted notes are kept here for 7 days.")
                    )
                } else {
                    List {
                        ForEach(notes) { note in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(note.title.isEmpty ? "Untitled" : note.title)
                                    .font(.headline)
                                Text(note.content.isEmpty ? "No content" : note.content)
                                    .lineLimit(2)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if let deletedAt = note.deletedAt {
                                    Text("Deleted \(deletedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button("Restore") {
                                    onRestore(note)
                                }
                                .tint(.green)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete") {
                                    onDelete(note)
                                }
                                .tint(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Deleted notes are kept here for 7 days.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
            }
            .toolbar {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}
