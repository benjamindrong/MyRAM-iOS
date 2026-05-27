// NotesListView.swift
import SwiftUI
import SwiftData
import UIKit

struct NotesListView: View {
    @StateObject private var vm: NotesViewModel
    @State private var editMode: EditMode = .inactive
    @State private var selectedNote: Note? = nil
    @State private var showingRecentlyDeleted = false
    @State private var recentlyDeletedNotes: [Note] = []
    @State private var selectedNoteIDs: Set<UUID> = []
    @State private var sharePayload: SharePayload?
    @State private var exportErrorMessage: String?
    @State private var showingCreateFolderPrompt = false
    @State private var newFolderName = ""
    @State private var folderAwaitingRename: Folder?
    @State private var renameFolderName = ""
    @State private var noteMoveRequest: NoteMoveRequest?
    @State private var pendingFolderDeletionQueue: [Folder] = []
    @State private var folderAwaitingDeleteDecision: Folder?
    @AppStorage("appearanceSetting") private var appearanceSettingRaw = AppearanceSetting.system.rawValue
    
    init(context: ModelContext) {
        _vm = StateObject(wrappedValue: NotesViewModel(context: context))
    }
    
    var body: some View {
        NavigationStack {
            List(selection: $selectedNoteIDs) {
                ForEach(listItems) { item in
                    row(for: item)
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(vm.currentFolder?.name ?? "My Notes")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if vm.currentFolder != nil {
                        Button {
                            vm.navigateToParentFolder()
                            selectedNoteIDs.removeAll()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }

                    Button(editMode.isEditing ? "Done" : "Select") {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            selectedNote = vm.createNewNote()
                        } label: {
                            Label("New Note", systemImage: "square.and.pencil")
                        }

                        Button {
                            newFolderName = ""
                            showingCreateFolderPrompt = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }

                        Picker("Appearance", selection: $appearanceSettingRaw) {
                            ForEach(AppearanceSetting.allCases) { appearanceSetting in
                                Text(appearanceSetting.title).tag(appearanceSetting.rawValue)
                            }
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
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
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
            .sheet(item: $sharePayload) { payload in
                ActivityShareSheet(activityItems: payload.urls)
            }
            .alert("Unable to Export Notes", isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage ?? "An unknown export error occurred.")
            }
            .alert("New Folder", isPresented: $showingCreateFolderPrompt) {
                TextField("Folder Name", text: $newFolderName)
                Button("Cancel", role: .cancel) {
                    newFolderName = ""
                }
                Button("Create") {
                    vm.createFolder(named: newFolderName)
                    newFolderName = ""
                }
            } message: {
                Text("Enter a name for the new folder.")
            }
            .alert(
                "Rename Folder",
                isPresented: Binding(
                    get: { folderAwaitingRename != nil },
                    set: { if !$0 { folderAwaitingRename = nil } }
                )
            ) {
                TextField("Folder Name", text: $renameFolderName)
                Button("Cancel", role: .cancel) {
                    folderAwaitingRename = nil
                    renameFolderName = ""
                }
                Button("Save") {
                    if let folder = folderAwaitingRename {
                        vm.renameFolder(folder, to: renameFolderName)
                    }
                    folderAwaitingRename = nil
                    renameFolderName = ""
                }
            } message: {
                Text("Update the folder name.")
            }
            .confirmationDialog(
                "Delete folder \"\(folderAwaitingDeleteDecision?.name ?? "")\"?",
                isPresented: Binding(
                    get: { folderAwaitingDeleteDecision != nil },
                    set: { if !$0 { folderAwaitingDeleteDecision = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Folder and All Contents", role: .destructive) {
                    guard let folder = folderAwaitingDeleteDecision else { return }
                    vm.deleteFolder(folder, preserveNotes: false)
                    folderAwaitingDeleteDecision = nil
                    presentNextFolderDeletionPromptIfNeeded()
                }
                Button("Delete Folder Only and Keep Notes", role: .destructive) {
                    guard let folder = folderAwaitingDeleteDecision else { return }
                    vm.deleteFolder(folder, preserveNotes: true)
                    folderAwaitingDeleteDecision = nil
                    presentNextFolderDeletionPromptIfNeeded()
                }
                Button("Cancel", role: .cancel) {
                    folderAwaitingDeleteDecision = nil
                    pendingFolderDeletionQueue.removeAll()
                }
            } message: {
                Text("Choose whether to delete the folder contents or move notes to top level before deleting the folder.")
            }
            .sheet(item: $noteMoveRequest) { request in
                NoteMoveDestinationView(
                    note: request.note,
                    currentFolder: request.note.folder,
                    availableFolders: vm.fetchAllFolders(),
                    folderPathProvider: buildFolderPath(for:),
                    onMove: { destination in
                        vm.moveNote(request.note, to: destination)
                    }
                )
            }
        }
        .onChange(of: vm.notes) { _, updatedNotes in
            let currentIDs = Set(updatedNotes.map(\.id))
            selectedNoteIDs = selectedNoteIDs.intersection(currentIDs)
        }
    }

    private var listItems: [NotesListItem] {
        vm.folders.map(NotesListItem.folder) + vm.notes.map(NotesListItem.note)
    }

    @ViewBuilder
    private func row(for item: NotesListItem) -> some View {
        switch item {
        case .folder(let folder):
            folderRow(folder)
        case .note(let note):
            noteRow(note)
        }
    }

    private func folderRow(_ folder: Folder) -> some View {
        Button {
            if editMode.isEditing { return }
            vm.openFolder(folder)
            selectedNoteIDs.removeAll()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                Text(folder.name)
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .listRowSeparatorTint(.secondary.opacity(0.35))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button("Rename") {
                folderAwaitingRename = folder
                renameFolderName = folder.name
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", role: .destructive) {
                pendingFolderDeletionQueue.append(folder)
                presentNextFolderDeletionPromptIfNeeded()
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        Button {
            if editMode.isEditing {
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
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button("Move") {
                noteMoveRequest = NoteMoveRequest(note: note)
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", role: .destructive) {
                vm.deleteNote(note)
            }
        }
    }

    private func toggleSelection(for noteID: UUID) {
        if selectedNoteIDs.contains(noteID) {
            selectedNoteIDs.remove(noteID)
        } else {
            selectedNoteIDs.insert(noteID)
        }
    }

    private func presentNextFolderDeletionPromptIfNeeded() {
        guard folderAwaitingDeleteDecision == nil,
              !pendingFolderDeletionQueue.isEmpty else {
            return
        }
        folderAwaitingDeleteDecision = pendingFolderDeletionQueue.removeFirst()
    }

    private func buildFolderPath(for folder: Folder) -> String {
        var segments: [String] = [folder.name]
        var cursor = folder.parentFolder
        while let current = cursor {
            segments.append(current.name)
            cursor = current.parentFolder
        }
        return segments.reversed().joined(separator: " / ")
    }

    private func exportSelectedNotes() {
        let notesToExport = vm.notes.filter { selectedNoteIDs.contains($0.id) }
        do {
            let exportURLs = try vm.exportNotesForSharing(notesToExport)
            sharePayload = SharePayload(urls: exportURLs)
        } catch {
            exportErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "An unknown export error occurred."
        }
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private enum NotesListItem: Identifiable {
    case folder(Folder)
    case note(Note)

    var id: String {
        switch self {
        case .folder(let folder):
            return "folder-\(folder.id.uuidString)"
        case .note(let note):
            return "note-\(note.id.uuidString)"
        }
    }
}

private struct NoteMoveRequest: Identifiable {
    let id = UUID()
    let note: Note
}

private struct NoteMoveDestinationView: View {
    @Environment(\.dismiss) private var dismiss
    let note: Note
    let currentFolder: Folder?
    let availableFolders: [Folder]
    let folderPathProvider: (Folder) -> String
    let onMove: (Folder?) -> Void

    private var sortedFolders: [Folder] {
        availableFolders.sorted {
            folderPathProvider($0).localizedCaseInsensitiveCompare(folderPathProvider($1)) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onMove(nil)
                    dismiss()
                } label: {
                    HStack {
                        Text("Top Level")
                        Spacer()
                        if currentFolder == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(currentFolder == nil)

                ForEach(sortedFolders, id: \.id) { folder in
                    Button {
                        onMove(folder)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(folder.name)
                                    .font(.headline)
                                Text(folderPathProvider(folder))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if currentFolder?.id == folder.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(currentFolder?.id == folder.id)
                }
            }
            .navigationTitle("Move Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
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
