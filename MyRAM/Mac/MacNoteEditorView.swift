#if os(macOS)
import AppKit
import SwiftUI

struct MacNoteEditorView: View {
    @State private var note: Note?
    @State private var attributedText = NSAttributedString(string: "")
    @State private var hasLoadedNote = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            MacTextViewRepresentable(attributedText: $attributedText) {
                scheduleSave()
            }
                .frame(minWidth: 640, minHeight: 460)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }

            if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(28)
        .frame(minWidth: 720, minHeight: 560)
        .onAppear(perform: loadNoteIfNeeded)
        .onDisappear(perform: flushPendingSave)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MyRAM")
                .font(.title.weight(.semibold))
            Text(platformStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var platformStatus: String {
        // Keep platform identity centralized in the shared helper introduced for the Mac port.
        guard MyRAMPlatform.isNativeMacOS else { return "Unsupported platform" }
        return note.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Loading Untitled note"
    }

    private func loadNoteIfNeeded() {
        guard !hasLoadedNote else { return }
        hasLoadedNote = true

        do {
            let adapter = MacNotePersistenceAdapter()
            let loadedNote = try adapter.loadDefaultNote()
            note = loadedNote
            attributedText = adapter.attributedContent(for: loadedNote)
            loadError = nil
        } catch {
            loadError = "Unable to load note: \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            saveCurrentNote()
        }
    }

    private func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        saveCurrentNote()
    }

    private func saveCurrentNote() {
        guard let note else { return }

        do {
            try MacNotePersistenceAdapter().save(note: note, attributedContent: attributedText)
            saveError = nil
        } catch {
            saveError = "Unable to save note: \(error.localizedDescription)"
        }
    }
}
#endif
