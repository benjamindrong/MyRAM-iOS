#if os(macOS)
import AppKit
import SwiftUI

struct MyRAMMacRootView: View {
    @StateObject private var startupCoordinator = MacStartupCoordinator()
    @StateObject private var syncController = MacSyncBatchController(
        context: PersistenceManager.shared.context,
        startsNetworking: false
    )
    @StateObject private var editorSyncBridge = MacEditorSyncBridge()
    @State private var syncConvergenceCoordinator: MacSyncConvergenceCoordinator?
    @State private var notes: [Note] = []
    @State private var selectedNoteID: UUID?
    @State private var attributedText = NSAttributedString(string: "")
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
    @State private var isMarkdownFileOperationInProgress = false
    @State private var pendingMarkdownOpenURLs: [URL] = []
    @State private var markdownFileErrorMessage: String?

    var body: some View {
        Group {
            switch startupCoordinator.state {
            case .idle, .running:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                readyContent
            }
        }
        .frame(minWidth: 260, minHeight: 280)
        .onAppear {
            startupCoordinator.startIfNeeded(actions: startupActions)
        }
        .onDisappear {
            Task { await flushPendingSave() }
        }
        .onOpenURL { url in
            pendingMarkdownOpenURLs.append(url)
            drainPendingMarkdownOpenURLsIfReady()
        }
        .onChange(of: startupCoordinator.state) { _, _ in
            drainPendingMarkdownOpenURLsIfReady()
        }
        .focusedSceneValue(\.markdownCommandActions, markdownCommandActions)
        .alert(
            "Markdown File Error",
            isPresented: Binding(
                get: { markdownFileErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        markdownFileErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(markdownFileErrorMessage ?? "")
        }
    }

    private var readyContent: some View {
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
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            handleWidthChange(width)
        }
        .onChange(of: columnVisibility) { _, newValue in
            handleColumnVisibilityChange(newValue)
        }
    }

    private var startupActions: MacStartupCoordinator.Actions {
        MacStartupCoordinator.Actions(
            migrateNoteSequenceStates: {
                try await NoteSequenceStateBootstrapMigrator(
                    container: PersistenceManager.shared.container
                ).runToCompletion()
            },
            loadNotesCreatingFirstIfNeeded: {
                try loadNotesSelectingFirstForStartup()
            },
            configureConvergenceIfNeeded: {
                configureSyncConvergenceIfNeeded()
            },
            startNetworkingIfNeeded: {
                syncController.startNetworkingIfNeeded()
            },
            resumePendingConvergence: {
                resumeSyncConvergence()
            }
        )
    }

    private var selectedNote: Note? {
        guard let selectedNoteID else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }

    private var markdownCommandActions: MacMarkdownCommandActions {
        let isReady = startupCoordinator.state == .ready
        return MacMarkdownCommandActions(
            canImport: isReady && !isMarkdownFileOperationInProgress,
            canExport: isReady
                && selectedNoteID != nil
                && !isMarkdownFileOperationInProgress,
            importMarkdown: beginMarkdownImportWithPanel,
            exportMarkdown: beginMarkdownExportWithPanel
        )
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

    private func loadNotesSelectingFirstForStartup() throws {
        let loadedNotes = try MacNotePersistenceAdapter().loadNotesCreatingFirstIfNeeded()
        notes = loadedNotes
        selectedNoteID = loadedNotes.first?.id
        attributedText = loadedNotes.first.map {
            MacNotePersistenceAdapter().attributedContent(for: $0)
        } ?? NSAttributedString(string: "")
        hasUnsavedChanges = false
        editorRevision = UUID()
        loadError = nil
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
            closeRemovedSelectedEditor: { noteID in
                guard selectedNoteID == noteID else { return }
                selectedNoteID = nil
                attributedText = NSAttributedString(string: "")
                hasUnsavedChanges = false
                editorRevision = UUID()
            },
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

    private func beginMarkdownImportWithPanel() {
        guard startupCoordinator.state == .ready,
              !isMarkdownFileOperationInProgress else {
            return
        }

        isMarkdownFileOperationInProgress = true
        Task { @MainActor in
            do {
                _ = try await MacMarkdownFileOperationCoordinator().performImport(
                    flush: { await flushPendingSave() },
                    selectSource: {
                        let panel = NSOpenPanel()
                        panel.title = "Import Markdown"
                        panel.allowedContentTypes = [MarkdownFileClassifier.markdownContentType]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        return panel.runModal() == .OK ? panel.url : nil
                    },
                    consume: consumeMarkdownFile,
                    publish: publishImportedMarkdown,
                    present: presentImportedMarkdown
                )
                finishMarkdownFileOperation()
            } catch {
                finishMarkdownFileOperation(errorMessage: markdownErrorMessage(for: error))
            }
        }
    }

    private func beginMarkdownExportWithPanel() {
        guard startupCoordinator.state == .ready,
              selectedNoteID != nil,
              !isMarkdownFileOperationInProgress else {
            return
        }

        isMarkdownFileOperationInProgress = true
        Task { @MainActor in
            do {
                _ = try await MacMarkdownFileOperationCoordinator().performExport(
                    flush: { await flushPendingSave() },
                    loadSource: {
                        guard let selectedNoteID,
                              let note = try MacNotePersistenceAdapter().loadNote(id: selectedNoteID) else {
                            return nil
                        }
                        return MacMarkdownExportSource(title: note.title, source: note.content)
                    },
                    selectDestination: { filename in
                        let panel = NSSavePanel()
                        panel.title = "Export Markdown"
                        panel.allowedContentTypes = [MarkdownFileClassifier.markdownContentType]
                        panel.nameFieldStringValue = filename
                        return panel.runModal() == .OK ? panel.url : nil
                    },
                    write: { source, url in
                        let didStartAccessing = url.startAccessingSecurityScopedResource()
                        defer {
                            if didStartAccessing {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        try MarkdownFileWriter().write(source: source, to: url)
                    }
                )
                finishMarkdownFileOperation()
            } catch {
                finishMarkdownFileOperation(errorMessage: markdownErrorMessage(for: error))
            }
        }
    }

    private func drainPendingMarkdownOpenURLsIfReady() {
        guard startupCoordinator.state == .ready,
              !isMarkdownFileOperationInProgress,
              !pendingMarkdownOpenURLs.isEmpty else {
            return
        }

        let url = pendingMarkdownOpenURLs.removeFirst()
        isMarkdownFileOperationInProgress = true
        Task { @MainActor in
            do {
                _ = try await MacMarkdownFileOperationCoordinator().performImport(
                    flush: { await flushPendingSave() },
                    selectSource: { url },
                    consume: consumeMarkdownFile,
                    publish: publishImportedMarkdown,
                    present: presentImportedMarkdown
                )
                finishMarkdownFileOperation()
            } catch {
                finishMarkdownFileOperation(errorMessage: markdownErrorMessage(for: error))
            }
        }
    }

    private func consumeMarkdownFile(from url: URL) throws -> Note {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard MarkdownFileClassifier().kind(for: url) == .markdown else {
            throw MarkdownFileIOError.unsupportedFileType
        }

        let document = try MarkdownFileReader().read(from: url)
        return try MacNotePersistenceAdapter().createNote(
            title: document.suggestedTitle,
            body: document.source,
            richTextContentData: nil
        )
    }

    private func publishImportedMarkdown(_ importedNote: Note) async {
        let capturedCreate = SyncConvergenceCapturedLocalChange(
            change: SyncBatchNoteChangeCapture.noteCreated(
                noteID: importedNote.id,
                title: importedNote.title,
                body: importedNote.content,
                folderID: nil,
                createdAt: importedNote.createdAt,
                modifiedAt: importedNote.modifiedAt
            ),
            evidence: nil
        )
        await syncController.record(capturedCreate, at: importedNote.modifiedAt)
    }

    private func presentImportedMarkdown(_ importedNote: Note) throws {
        let adapter = MacNotePersistenceAdapter()
        notes = try adapter.loadNotesCreatingFirstIfNeeded()
        selectedNoteID = importedNote.id
        attributedText = adapter.attributedContent(for: importedNote)
        hasUnsavedChanges = false
        editorRevision = UUID()
        loadError = nil
        saveError = nil
        resumeSyncConvergence()
    }

    private func finishMarkdownFileOperation(errorMessage: String? = nil) {
        markdownFileErrorMessage = errorMessage
        isMarkdownFileOperationInProgress = false
        drainPendingMarkdownOpenURLsIfReady()
    }

    private func markdownErrorMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
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
        if case .completed = completion {
            refreshNotesAfterSave()
        }
        var state = editorSaveState
        let result = state.pendingResult(for: completion, requestedAttempt: requestedAttempt)
        applyEditorSaveState(state)
        switch result {
        case .noChanges, .savedWithoutBodyMutation, .savedWithPendingBodyMutation:
            resumeSyncConvergence()
        case .superseded, .failed:
            break
        }
        return result
    }

    private func boundaryResult(
        for completion: MacNoteSaveOperationCompletion,
        requestedAttempt: MacEditorSaveAttempt
    ) async -> MacIncomingBoundaryResult {
        switch completion {
        case .failed(let attempt, let failure):
            var state = editorSaveState
            state.setSaveError(for: attempt, failure: failure)
            applyEditorSaveState(state)
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
            var state = editorSaveState
            state.markBoundaryReadyIfOwned(
                requestedAttempt: requestedAttempt,
                completingAttempt: attempt,
                result: result
            )
            applyEditorSaveState(state)
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

    private var editorSaveState: MacEditorSaveState {
        MacEditorSaveState(
            selectedNoteID: selectedNoteID,
            editorRevision: editorRevision,
            hasUnsavedChanges: hasUnsavedChanges,
            saveError: saveError
        )
    }

    private func applyEditorSaveState(_ state: MacEditorSaveState) {
        hasUnsavedChanges = state.hasUnsavedChanges
        saveError = state.saveError
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
