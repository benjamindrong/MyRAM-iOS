#if os(macOS)
import AppKit
import SwiftUI

struct MyRAMMacRootView: View {
    @StateObject private var syncController = MacSyncBatchController(context: PersistenceManager.shared.context)
    @StateObject private var editorSyncBridge = MacEditorSyncBridge()
    @State private var notes: [Note] = []
    @State private var selectedNoteID: UUID?
    @State private var attributedText = NSAttributedString(string: "")
    @State private var hasLoadedNotes = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var hasUnsavedChanges = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarCollapseState: MacSidebarCollapsePolicy.CollapseState = .expanded
    @State private var isApplyingAutomaticVisibilityChange = false
    @State private var isExpandingWindowForSidebar = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacNoteListView(
                notes: notes,
                selectedNoteID: selectedNoteID,
                syncController: syncController,
                onSelect: selectNote,
                onCreateNote: createNote
            )
        } detail: {
            MacNoteEditorView(
                note: selectedNote,
                attributedText: $attributedText,
                syncBridge: editorSyncBridge,
                loadError: loadError,
                saveError: saveError,
                onTextChanged: scheduleSave
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 260, minHeight: 280)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            handleWidthChange(width)
        }
        .onChange(of: columnVisibility) { _, newValue in
            handleColumnVisibilityChange(newValue)
        }
        .onAppear(perform: loadNotesIfNeeded)
        .onAppear {
            syncController.onBeforeApplyingRemoteBatch = {
                flushPendingSave()
            }
            syncController.onBatchApplied = { appliedBatch in
                handleAppliedSyncBatch(appliedBatch)
            }
        }
        .onDisappear {
            _ = flushPendingSave()
        }
    }

    private var selectedNote: Note? {
        guard let selectedNoteID else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }

    private func handleWidthChange(_ width: CGFloat) {
        guard !isExpandingWindowForSidebar else { return }

        let nextState = MacSidebarCollapsePolicy.stateAfterWidthChange(
            currentState: sidebarCollapseState,
            availableWidth: width
        )
        guard nextState != sidebarCollapseState else { return }

        sidebarCollapseState = nextState
        isApplyingAutomaticVisibilityChange = true
        withAnimation(.easeInOut(duration: 0.25)) {
            columnVisibility = nextState == .expanded ? .all : .detailOnly
        }
    }

    private func handleColumnVisibilityChange(_ newValue: NavigationSplitViewVisibility) {
        if isApplyingAutomaticVisibilityChange {
            isApplyingAutomaticVisibilityChange = false
            return
        }

        if sidebarCollapseState == .autoCollapsed, newValue == .all {
            reopenAutoCollapsedSidebarAfterWindowExpansion()
            return
        }

        sidebarCollapseState = MacSidebarCollapsePolicy.stateAfterManualVisibilityChange(
            isSidebarVisible: newValue == .all
        )
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
            hasUnsavedChanges = false
            loadError = nil
        } catch {
            loadError = "Unable to load notes: \(error.localizedDescription)"
        }
    }

    private func loadNotesKeepingSelection() {
        do {
            let loadedNotes = try MacNotePersistenceAdapter().loadNotesCreatingFirstIfNeeded()
            notes = loadedNotes
            if let selectedNoteID, loadedNotes.contains(where: { $0.id == selectedNoteID }) {
                attributedText = selectedNote.map {
                    MacNotePersistenceAdapter().attributedContent(for: $0)
                } ?? NSAttributedString(string: "")
            } else {
                selectedNoteID = loadedNotes.first?.id
                attributedText = loadedNotes.first.map {
                    MacNotePersistenceAdapter().attributedContent(for: $0)
                } ?? NSAttributedString(string: "")
            }
            hasUnsavedChanges = false
            loadError = nil
        } catch {
            loadError = "Unable to load notes: \(error.localizedDescription)"
        }
    }

    private func refreshNotesList() {
        do {
            let loadedNotes = try MacNotePersistenceAdapter().loadNotesCreatingFirstIfNeeded()
            notes = loadedNotes
            guard let selectedNoteID, loadedNotes.contains(where: { $0.id == selectedNoteID }) else {
                selectedNoteID = loadedNotes.first?.id
                attributedText = loadedNotes.first.map {
                    MacNotePersistenceAdapter().attributedContent(for: $0)
                } ?? NSAttributedString(string: "")
                hasUnsavedChanges = false
                return
            }
            loadError = nil
        } catch {
            loadError = "Unable to load notes: \(error.localizedDescription)"
        }
    }

    private func reloadSelectedEditor(reason: MacSelectedEditorReloadReason) {
        guard !hasUnsavedChanges else {
            // Defensive only: the pre-apply flush should have saved local edits before any fallback reload reason can fire.
            saveError = "Incoming sync is waiting for local edits to save."
            return
        }

        guard let selectedNote else { return }
        attributedText = MacNotePersistenceAdapter().attributedContent(for: selectedNote)
        saveError = nil
    }

    private func handleAppliedSyncBatch(_ appliedBatch: MacAppliedSyncBatch) {
        let plan = MacIncomingSyncApplicationPolicy.plan(
            appliedBatch: appliedBatch,
            selectedNoteID: selectedNoteID,
            editorState: hasUnsavedChanges ? .unsafeForIncrementalApply : .ready
        )

        if plan.shouldRefreshNotesList {
            refreshNotesList()
        }

        if let reason = plan.reloadSelectedEditorReason {
            reloadSelectedEditor(reason: reason)
            return
        }

        guard let selectedNoteID, !plan.editorActions.isEmpty else { return }
        let result = editorSyncBridge.applyBatch(plan.editorActions, selectedNoteID: selectedNoteID)
        if case .requiresReload = result.disposition {
            reloadSelectedEditor(reason: .unsafeIncrementalApply)
        }
    }

    private func selectNote(_ note: Note) {
        guard note.id != selectedNoteID else { return }
        guard flushPendingSave() else { return }

        selectedNoteID = note.id
        attributedText = MacNotePersistenceAdapter().attributedContent(for: note)
        hasUnsavedChanges = false
        saveError = nil
    }

    private func createNote() {
        guard flushPendingSave() else { return }

        do {
            let newNote = try MacNotePersistenceAdapter().createNote()
            syncController.record(
                SyncBatchNoteChangeCapture.noteCreated(
                    noteID: newNote.id,
                    title: newNote.title,
                    body: newNote.content,
                    folderID: newNote.folder?.id,
                    createdAt: newNote.createdAt,
                    modifiedAt: newNote.modifiedAt
                )
            )
            notes = try MacNotePersistenceAdapter().loadNotesCreatingFirstIfNeeded()
            selectedNoteID = newNote.id
            attributedText = MacNotePersistenceAdapter().attributedContent(for: newNote)
            hasUnsavedChanges = false
            loadError = nil
            saveError = nil
        } catch {
            loadError = "Unable to create note: \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        guard let noteID = selectedNoteID else { return }
        let contentToSave = NSAttributedString(attributedString: attributedText)
        hasUnsavedChanges = true

        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, selectedNoteID == noteID else { return }
            _ = saveNote(id: noteID, attributedContent: contentToSave)
        }
    }

    private func flushPendingSave() -> Bool {
        saveTask?.cancel()
        saveTask = nil

        guard hasUnsavedChanges, let selectedNoteID else { return true }
        return saveNote(id: selectedNoteID, attributedContent: attributedText)
    }

    private func saveNote(id noteID: UUID, attributedContent: NSAttributedString) -> Bool {
        do {
            let adapter = MacNotePersistenceAdapter()
            guard let note = try adapter.loadNote(id: noteID) else {
                saveError = "Unable to save note: note was not found."
                return false
            }
            let oldTitle = note.title
            let oldContent = note.content
            try adapter.save(note: note, attributedContent: attributedContent)
            recordSyncBatchChanges(note: note, oldTitle: oldTitle, oldContent: oldContent)
            notes = try adapter.loadNotesCreatingFirstIfNeeded()
            hasUnsavedChanges = selectedNoteID == noteID ? false : hasUnsavedChanges
            saveError = nil
            syncController.drainPendingIncomingBatchesIfPossible()
            return true
        } catch {
            saveError = "Unable to save note: \(error.localizedDescription)"
            return false
        }
    }

    private func recordSyncBatchChanges(note: Note, oldTitle: String, oldContent: String) {
        if let change = SyncBatchNoteChangeCapture.titleChanged(
            noteID: note.id,
            oldTitle: oldTitle,
            newTitle: note.title,
            modifiedAt: note.modifiedAt
        ) {
            syncController.record(change)
        }

        if let change = SyncBatchNoteChangeCapture.bodyTextChanged(
            noteID: note.id,
            oldBody: oldContent,
            newBody: note.content,
            modifiedAt: note.modifiedAt
        ) {
            syncController.record(change)
        }
    }

    private func reopenAutoCollapsedSidebarAfterWindowExpansion() {
        isApplyingAutomaticVisibilityChange = true
        columnVisibility = .detailOnly

        guard let window = NSApp.keyWindow else {
            showAutoCollapsedSidebar()
            return
        }

        let visibleFrame = window.screen?.visibleFrame ?? window.frame
        let expandedFrame = MacSidebarCollapsePolicy.windowFrameExpandingSidebarToLeft(
            currentFrame: window.frame,
            visibleFrame: visibleFrame
        )

        guard expandedFrame != window.frame else {
            showAutoCollapsedSidebar()
            return
        }

        isExpandingWindowForSidebar = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().setFrame(expandedFrame, display: true)
        } completionHandler: {
            showAutoCollapsedSidebar()
        }
    }

    private func showAutoCollapsedSidebar() {
        isExpandingWindowForSidebar = false
        sidebarCollapseState = .expanded
        isApplyingAutomaticVisibilityChange = true
        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = .all
        }
    }
}

private struct MacNoteListView: View {
    let notes: [Note]
    let selectedNoteID: UUID?
    @ObservedObject var syncController: MacSyncBatchController
    let onSelect: (Note) -> Void
    let onCreateNote: () -> Void

    var body: some View {
        List(selection: selectedBinding) {
            Section {
                MacSyncStatusView(syncController: syncController)
            }

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
        .navigationSplitViewColumnWidth(ideal: 260, max: 360)
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

private struct MacSyncStatusView: View {
    @ObservedObject var syncController: MacSyncBatchController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sync")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    syncController.flushPendingBatch()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Sync Now")
                .disabled(!syncController.hasConnectedPeers)
            }

            Text(syncController.connectionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !syncController.availablePeers.isEmpty {
                ForEach(syncController.availablePeers) { peer in
                    HStack {
                        Text(peer.displayName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button("Pair") {
                            syncController.invite(peer)
                        }
                        .controlSize(.mini)
                    }
                }
            }

            Text(syncController.lastConnectionEvent)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let error = syncController.lastErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
    }
}
#endif
