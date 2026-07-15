#if os(macOS)
import AppKit
import SwiftUI

struct MyRAMMacRootView: View {
    @StateObject private var syncController = MacSyncBatchController(context: PersistenceManager.shared.context)
    @StateObject private var editorSyncBridge = MacEditorSyncBridge()
    @State private var syncConvergenceCoordinator: MacSyncConvergenceCoordinator?
    @State private var notes: [Note] = []
    @State private var selectedNoteID: UUID?
    @State private var attributedText = NSAttributedString(string: "")
    @State private var hasLoadedNotes = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var hasUnsavedChanges = false
    @State private var editorRevision = UUID()
    @State private var saveSingleFlight = MacNoteSaveSingleFlight()
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
        .onAppear(perform: configureSyncConvergenceIfNeeded)
        .onDisappear {
            Task { await flushPendingSave() }
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
            editorRevision = UUID()
            loadError = nil
            resumeSyncConvergence()
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
            editorRevision = UUID()
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
                editorRevision = UUID()
                return
            }
            loadError = nil
        } catch {
            loadError = "Unable to load notes: \(error.localizedDescription)"
        }
    }

    private func configureSyncConvergenceIfNeeded() {
        guard syncConvergenceCoordinator == nil else { return }

        let presentationSurface = MacSyncConvergencePresentationSurface(
            selectedNoteID: { selectedNoteID },
            hasUnsavedChanges: { hasUnsavedChanges },
            refreshNotesList: { refreshNotesList() },
            applyIncremental: { actions, noteID, authoritativeBody in
                editorSyncBridge.applyBatch(actions, selectedNoteID: noteID, authoritativeBody: authoritativeBody)
            },
            reloadSelectedEditor: { noteID, authoritativeBody in
                guard selectedNoteID == noteID else { return true }
                reloadSelectedEditor(reason: .unsafeIncrementalApply)
                return attributedText.string == authoritativeBody
            },
            currentEditorBody: { attributedText.string }
        )
        let boundarySurface = MacSyncIncomingLocalBoundarySurface(
            prepareForIncomingBodyMutation: { noteIDs in
                await MacIncomingBoundaryPreparer(
                    selectedNoteID: { selectedNoteID },
                    hasUnsavedChanges: { hasUnsavedChanges },
                    saveSelectedNoteForBoundary: { noteID in
                        await saveNoteForIncomingBoundary(id: noteID, attributedContent: attributedText)
                    },
                    takePendingObligation: { noteID in
                        await syncController.recordAndTakeBoundaryObligation(
                            adding: [],
                            affecting: noteID
                        )
                    }
                ).prepare(affecting: noteIDs)
            }
        )
        syncConvergenceCoordinator = MacSyncConvergenceCoordinator(
            context: PersistenceManager.shared.context,
            syncController: syncController,
            presentationSurface: presentationSurface,
            incomingBoundarySurface: boundarySurface
        )
        resumeSyncConvergence()
    }

    private func resumeSyncConvergence() {
        Task { await syncConvergenceCoordinator?.resumePendingWork() }
    }

    private func reloadSelectedEditor(reason: MacSelectedEditorReloadReason) {
        let outcome = MacSelectedEditorReloader.reload(
            hasUnsavedChanges: hasUnsavedChanges,
            selectedNote: selectedNote,
            recordWholeNoteReload: {
                #if DEBUG
                editorSyncBridge.fullDocumentMetrics?.recordWholeNoteReload()
                #endif
            },
            loadAttributedContent: { note in
                MacNotePersistenceAdapter().attributedContent(for: note)
            },
            applyAttributedContent: { attributedContent in
                attributedText = attributedContent
            }
        )

        guard outcome != .deferredForUnsavedChanges else {
            saveError = "Incoming sync is waiting for local edits to save."
            return
        }

        guard outcome == .reloaded else { return }
        editorRevision = UUID()
        saveError = nil
    }

    private func selectNote(_ note: Note) {
        guard note.id != selectedNoteID else { return }

        Task { @MainActor in
            guard await flushPendingSave() else { return }
            selectedNoteID = note.id
            attributedText = MacNotePersistenceAdapter().attributedContent(for: note)
            hasUnsavedChanges = false
            editorRevision = UUID()
            saveError = nil
            resumeSyncConvergence()
        }
    }

    private func createNote() {
        Task { @MainActor in
            guard await flushPendingSave() else { return }

            do {
                let newNote = try MacNotePersistenceAdapter().createNote()
                let capturedCreate = SyncConvergenceCapturedLocalChange(
                    change: SyncBatchNoteChangeCapture.noteCreated(
                        noteID: newNote.id,
                        title: newNote.title,
                        body: newNote.content,
                        folderID: newNote.folder?.id,
                        createdAt: newNote.createdAt,
                        modifiedAt: newNote.modifiedAt
                    ),
                    evidence: nil
                )
                await syncController.record(capturedCreate, at: newNote.modifiedAt)
                notes = try MacNotePersistenceAdapter().loadNotesCreatingFirstIfNeeded()
                selectedNoteID = newNote.id
                attributedText = MacNotePersistenceAdapter().attributedContent(for: newNote)
                hasUnsavedChanges = false
                editorRevision = UUID()
                loadError = nil
                saveError = nil
                resumeSyncConvergence()
            } catch {
                loadError = "Unable to create note: \(error.localizedDescription)"
            }
        }
    }

    private func scheduleSave() {
        guard let noteID = selectedNoteID else { return }
        let contentToSave = NSAttributedString(attributedString: attributedText)
        editorRevision = UUID()
        hasUnsavedChanges = true

        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, selectedNoteID == noteID else { return }
            _ = await saveNote(id: noteID, attributedContent: contentToSave, publication: .ordinary)
        }
    }

    private func flushPendingSave() async -> Bool {
        saveTask?.cancel()
        saveTask = nil

        guard hasUnsavedChanges, let selectedNoteID else { return true }
        let result = await saveNote(id: selectedNoteID, attributedContent: attributedText, publication: .ordinary)
        return MacEditorSaveOwnership.flushMayProceed(for: result)
    }


    private func saveNoteForIncomingBoundary(
        id noteID: UUID,
        attributedContent: NSAttributedString
    ) async -> MacIncomingBoundaryResult {
        let attempt = MacEditorSaveAttempt(
            noteID: noteID,
            editorRevision: editorRevision,
            attributedContent: NSAttributedString(attributedString: attributedContent)
        )
        let completion = await completeSaveAttempt(attempt, publication: .incomingBoundary)
        return await boundaryResult(for: completion, requestedAttempt: attempt)
    }

    private func saveNote(
        id noteID: UUID,
        attributedContent: NSAttributedString,
        publication: MacLocalSavePublication
    ) async -> MacPendingSaveResult {
        let attempt = MacEditorSaveAttempt(
            noteID: noteID,
            editorRevision: editorRevision,
            attributedContent: NSAttributedString(attributedString: attributedContent)
        )
        let completion = await completeSaveAttempt(attempt, publication: publication)
        return pendingSaveResult(for: completion, requestedAttempt: attempt)
    }

    private func completeSaveAttempt(
        _ attempt: MacEditorSaveAttempt,
        publication: MacLocalSavePublication
    ) async -> MacNoteSaveOperationCompletion {
        await saveSingleFlight.complete(
            attempt: attempt,
            stillOwnsAttempt: { stillOwnsEditorState(attempt) },
            operation: { await executeSaveAttempt(attempt, publication: publication) }
        )
    }

    private func executeSaveAttempt(
        _ attempt: MacEditorSaveAttempt,
        publication: MacLocalSavePublication
    ) async -> MacNoteSaveOperationCompletion {
        guard stillOwnsEditorState(attempt) else {
            return .supersededBeforeStart(attempt: attempt)
        }

        let adapter = MacNotePersistenceAdapter()
        let prepared: MacPreparedLocalNoteEdit
        do {
            prepared = try adapter.prepareLocalNoteEdit(
                noteID: attempt.noteID,
                proposedAttributedContent: attempt.attributedContent
            )
        } catch MacPendingSaveFailure.noteMissing {
            return .failed(attempt: attempt, failure: .noteMissing(noteID: attempt.noteID))
        } catch {
            return .failed(attempt: attempt, failure: .captureFailed(noteID: attempt.noteID))
        }

        guard prepared.hasAnyAuthoritativeMutation || prepared.previousRichTextContentData != prepared.proposedRichTextContentData else {
            return .completed(attempt: attempt, mutationKind: .none, publication: .none)
        }

        do {
            try adapter.persistPreparedLocalNoteEdit(prepared)
        } catch MacPendingSaveFailure.noteMissing {
            return .failed(attempt: attempt, failure: .noteMissing(noteID: attempt.noteID))
        } catch {
            return .failed(attempt: attempt, failure: .persistenceFailed(noteID: attempt.noteID))
        }

        let publicationOutcome: MacNoteSavePublicationOutcome
        switch publication {
        case .ordinary:
            await syncController.record(prepared.capturedChanges, at: prepared.modifiedAt)
            publicationOutcome = .ordinaryRecorded
        case .incomingBoundary:
            let obligation = await syncController.recordAndTakeBoundaryObligation(
                adding: prepared.capturedChanges,
                affecting: attempt.noteID,
                at: prepared.modifiedAt
            )
            publicationOutcome = .boundaryExtracted(obligation)
        }

        return .completed(
            attempt: attempt,
            mutationKind: prepared.hasBodyMutation ? .body : .nonBodyOnly,
            publication: publicationOutcome
        )
    }

    private func pendingSaveResult(
        for completion: MacNoteSaveOperationCompletion,
        requestedAttempt: MacEditorSaveAttempt
    ) -> MacPendingSaveResult {
        switch completion {
        case .failed(let attempt, let failure):
            setSaveError(for: attempt, failure: failure)
            return .failed(failure)
        case .supersededBeforeStart:
            return .superseded(noteID: requestedAttempt.noteID)
        case .completed(let attempt, let mutationKind, _):
            refreshNotesAfterSave()
            guard MacEditorSaveOwnership.owns(
                selectedNoteID: selectedNoteID,
                editorRevision: editorRevision,
                attempt: requestedAttempt
            ), MacEditorSaveOwnership.owns(
                selectedNoteID: selectedNoteID,
                editorRevision: editorRevision,
                attempt: attempt
            ) else {
                return .superseded(noteID: requestedAttempt.noteID)
            }
            hasUnsavedChanges = false
            saveError = nil
            resumeSyncConvergence()
            switch mutationKind {
            case .none:
                return .noChanges
            case .nonBodyOnly:
                return .savedWithoutBodyMutation
            case .body:
                return .savedWithPendingBodyMutation(noteID: attempt.noteID)
            }
        }
    }

    private func boundaryResult(
        for completion: MacNoteSaveOperationCompletion,
        requestedAttempt: MacEditorSaveAttempt
    ) async -> MacIncomingBoundaryResult {
        switch completion {
        case .failed(let attempt, let failure):
            setSaveError(for: attempt, failure: failure)
            return .failed(failure)
        case .supersededBeforeStart:
            return .staleLocalState(noteID: requestedAttempt.noteID)
        case .completed(let attempt, _, let publication):
            refreshNotesAfterSave()
            let obligation: SyncConvergenceLocalObligation?
            switch publication {
            case .boundaryExtracted(let extracted):
                obligation = extracted
            case .ordinaryRecorded, .none:
                // An ordinary save proves publication completed, not that no pending body evidence remains.
                obligation = await syncController.recordAndTakeBoundaryObligation(
                    adding: [],
                    affecting: attempt.noteID
                )
            }
            let result = MacIncomingBoundaryCompletionPolicy.result(
                for: completion,
                obligation: obligation,
                requestedAttemptStillOwnsEditor: stillOwnsEditorState(requestedAttempt),
                completingAttemptStillOwnsEditor: stillOwnsEditorState(attempt)
            )
            if case .ready = result {
                hasUnsavedChanges = false
                saveError = nil
            }
            return result
        }
    }

    private func stillOwnsEditorState(_ attempt: MacEditorSaveAttempt) -> Bool {
        MacEditorSaveOwnership.owns(
            selectedNoteID: selectedNoteID,
            editorRevision: editorRevision,
            attempt: attempt
        )
    }

    private func setSaveError(for attempt: MacEditorSaveAttempt, failure: MacPendingSaveFailure) {
        guard stillOwnsEditorState(attempt) else { return }
        switch failure {
        case .noteMissing:
            saveError = "Unable to save note: note was not found."
        case .captureFailed:
            saveError = "Unable to save note: local edit capture failed."
        case .persistenceFailed:
            saveError = "Unable to save note: local edit persistence failed."
        }
    }

    private func refreshNotesAfterSave() {
        do {
            notes = try MacNotePersistenceAdapter().loadNotesCreatingFirstIfNeeded()
        } catch {
            loadError = "Unable to load notes: \(error.localizedDescription)"
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

@MainActor
enum MacSelectedEditorReloadOutcome: Equatable {
    case reloaded
    case deferredForUnsavedChanges
    case noSelectedNote
}

@MainActor
struct MacSelectedEditorReloader {
    static func reload(
        hasUnsavedChanges: Bool,
        selectedNote: Note?,
        recordWholeNoteReload: () -> Void,
        loadAttributedContent: (Note) -> NSAttributedString,
        applyAttributedContent: (NSAttributedString) -> Void
    ) -> MacSelectedEditorReloadOutcome {
        guard !hasUnsavedChanges else {
            return .deferredForUnsavedChanges
        }

        guard let selectedNote else {
            return .noSelectedNote
        }

        recordWholeNoteReload()
        applyAttributedContent(loadAttributedContent(selectedNote))
        return .reloaded
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

private enum MacLocalSavePublication {
    case ordinary
    case incomingBoundary
}

#endif
