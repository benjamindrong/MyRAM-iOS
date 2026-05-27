// NotesListView.swift
import SwiftUI
import SwiftData
import UIKit

struct NotesListView: View {
    @Environment(\.editMode) private var editMode
    @StateObject private var vm: NotesViewModel
    @State private var selectedNote: Note? = nil
    @State private var showingRecentlyDeleted = false
    @State private var recentlyDeletedNotes: [Note] = []
    @State private var selectedNoteIDs: Set<UUID> = []
    @State private var shareURL: URL?
    @State private var showingShareSheet = false
    @State private var exportErrorMessage: String?
    @AppStorage("appearanceSetting") private var appearanceSettingRaw = AppearanceSetting.system.rawValue
    
    init(context: ModelContext) {
        _vm = StateObject(wrappedValue: NotesViewModel(context: context))
    }
    
    var body: some View {
        NavigationStack {
            List(selection: $selectedNoteIDs) {
                ForEach(vm.notes, id: \.id) { note in
                    Button {
                        if editMode?.wrappedValue.isEditing == true {
                            toggleSelection(for: note.id)
                        } else {
                            vm.selectNote(note)
                            selectedNote = note
                        }
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
                    .tag(note.id)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        vm.deleteNote(vm.notes[index])
                    }
                }
            }
            .navigationTitle("My Notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }

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
                        exportSelectedNotes()
                    } label: {
                        Label("Export Selected Notes", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selectedNoteIDs.isEmpty)

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
            .sheet(isPresented: $showingShareSheet) {
                if let shareURL {
                    ActivityShareSheet(activityItems: [shareURL])
                }
            }
            .alert("Unable to Export Notes", isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage ?? "An unknown export error occurred.")
            }
        }
        .onChange(of: vm.currentNote) { _, newValue in
            if let newValue, selectedNote == nil {
                selectedNote = newValue
            }
        }
        .onChange(of: vm.notes) { _, updatedNotes in
            let currentIDs = Set(updatedNotes.map(\.id))
            selectedNoteIDs = selectedNoteIDs.intersection(currentIDs)
        }
    }

    private func toggleSelection(for noteID: UUID) {
        if selectedNoteIDs.contains(noteID) {
            selectedNoteIDs.remove(noteID)
        } else {
            selectedNoteIDs.insert(noteID)
        }
    }

    private func exportSelectedNotes() {
        let notesToExport = vm.notes.filter { selectedNoteIDs.contains($0.id) }
        do {
            shareURL = try vm.exportNotesForSharing(notesToExport)
            showingShareSheet = true
        } catch {
            exportErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "An unknown export error occurred."
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
