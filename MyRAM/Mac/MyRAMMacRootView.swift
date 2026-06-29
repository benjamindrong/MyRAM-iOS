#if os(macOS)
import AppKit
import SwiftUI

struct MyRAMMacRootView: View {
    @State private var notes: [Note] = []
    @State private var selectedNoteID: UUID?
    @State private var attributedText = NSAttributedString(string: "")
    @State private var hasLoadedNotes = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            MacNoteListView(
                notes: notes,
                selectedNoteID: selectedNoteID,
                onSelect: selectNote,
                onCreateNote: createNote
            )
        } detail: {
            MacNoteEditorView(
                note: selectedNote,
                attributedText: $attributedText,
                loadError: loadError,
                saveError: saveError,
                onTextChanged: scheduleSave
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear(perform: loadNotesIfNeeded)
        .onDisappear(perform: flushPendingSave)
    }

    private var selectedNote: Note? {
        guard let selectedNoteID else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }

    private func loadNotesIfNeeded() {
        guard !hasLoadedNotes else { return }
        hasLoadedNotes = true
        loadNotesSelectingFirst()
    }

    private func loadNotesSelectingFirst() {
        do {
            let loadedNotes = try MacNotePersistenceAdapter().loadNotesCreatingFirstIfNeeded()
            notes = loadedNotes
            selectedNoteID = loadedNotes.first?.id
            attributedText = loadedNotes.first.map {
                MacNotePersistenceAdapter().attributedContent(for: $0)
            } ?? NSAttributedString(string: "")
            loadError = nil
        } catch {
            loadError = "Unable to load notes: \(error.localizedDescription)"
        }
    }

    private func selectNote(_ note: Note) {
        guard note.id != selectedNoteID else { return }

        flushPendingSave()
        selectedNoteID = note.id
        attributedText = MacNotePersistenceAdapter().attributedContent(for: note)
        saveError = nil
    }

    private func createNote() {
        flushPendingSave()

        do {
            let newNote = try MacNotePersistenceAdapter().createNote()
            notes = try MacNotePersistenceAdapter().loadNotesCreatingFirstIfNeeded()
            selectedNoteID = newNote.id
            attributedText = MacNotePersistenceAdapter().attributedContent(for: newNote)
            loadError = nil
            saveError = nil
        } catch {
            loadError = "Unable to create note: \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        guard let noteID = selectedNoteID else { return }
        let contentToSave = NSAttributedString(attributedString: attributedText)

        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, selectedNoteID == noteID else { return }
            saveNote(id: noteID, attributedContent: contentToSave)
        }
    }

    private func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil

        guard let selectedNoteID else { return }
        saveNote(id: selectedNoteID, attributedContent: attributedText)
    }

    private func saveNote(id noteID: UUID, attributedContent: NSAttributedString) {
        do {
            let adapter = MacNotePersistenceAdapter()
            guard let note = try adapter.loadNote(id: noteID) else { return }
            try adapter.save(note: note, attributedContent: attributedContent)
            notes = try adapter.loadNotesCreatingFirstIfNeeded()
            saveError = nil
        } catch {
            saveError = "Unable to save note: \(error.localizedDescription)"
        }
    }
}

private struct MacNoteListView: View {
    let notes: [Note]
    let selectedNoteID: UUID?
    let onSelect: (Note) -> Void
    let onCreateNote: () -> Void

    var body: some View {
        List(selection: selectedBinding) {
            ForEach(notes, id: \.id) { note in
                Button {
                    onSelect(note)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayTitle(for: note))
                            .font(.headline)
                            .lineLimit(1)
                        Text(displayPreview(for: note))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectionBackground(for: note))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(note.id)
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Text("Notes")
                    .font(.headline)
                Spacer()
                Button(action: onCreateNote) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Note")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .navigationSplitViewColumnWidth(min: 96, ideal: 260, max: 360)
    }

    private var selectedBinding: Binding<UUID?> {
        Binding(
            get: { selectedNoteID },
            set: { selectedID in
                guard let selectedID, let note = notes.first(where: { $0.id == selectedID }) else { return }
                onSelect(note)
            }
        )
    }

    private func displayTitle(for note: Note) -> String {
        if !note.title.isEmpty {
            return note.title
        }

        let trimmedContent = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedContent.isEmpty ? "Untitled" : trimmedContent
    }

    private func displayPreview(for note: Note) -> String {
        let trimmedContent = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedContent.isEmpty ? "No additional text" : trimmedContent
    }

    @ViewBuilder
    private func selectionBackground(for note: Note) -> some View {
        if note.id == selectedNoteID {
            Color.accentColor.opacity(0.18)
        } else {
            Color.clear
        }
    }
}
#endif
