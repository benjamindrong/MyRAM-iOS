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
    @EnvironmentObject private var externalImportCoordinator: MacMarkdownExternalImportCoordinator
    @EnvironmentObject private var externalOpenDispatcher: MyRAMExternalOpenDispatcher
    @EnvironmentObject private var widgetCoordinator: MyRAMWidgetHostCoordinator
    /// Stable in-memory identity for this scene. Used only to associate an
    /// external Open With URL with the scene that received it. Not persisted.
    @State private var markdownSceneID = UUID()
    @State private var fileOperationState = MacSceneLocalFileOperationState()
    @State private var activeExternalFileRequestID: UUID?

    // MYR-195 Slice 2: scene-local mode state. Not persisted, not Codable, not added to Note.
    // Each window/scene owns its mode independently.
    @State private var markdownEditorMode: MarkdownEditorMode = .edit
    /// Scene-local presentation state shared by Edit and Preview. It is never persisted.
    @State private var noteViewZoom: CGFloat = MacNoteViewZoom.actualSize
    // Resign-only seam forwarded to MacTextViewRepresentable. Incrementing causes the text
    // view to relinquish first responder without save, flush, or onTextChanged.
    @State private var macResignFocusToggleToken = 0

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
            _ = externalOpenDispatcher.enqueue(url: url, platform: .macOS)
            drainPendingExternalOpenRequestsIfReady()
        }
        .onChange(of: startupCoordinator.state) { _, _ in
            drainPendingExternalOpenRequestsIfReady()
        }
        .onChange(of: externalImportCoordinator.revision) { _, _ in
            drainPendingExternalOpenRequestsIfReady()
        }
        .focusedSceneValue(\.markdownCommandActions, markdownCommandActions)
        .focusedSceneValue(\.macNoteViewZoom, $noteViewZoom)
        .alert(
            "Markdown File Error",
            isPresented: Binding(
                get: { externalImportCoordinator.shouldPresentError(in: markdownSceneID) },
                set: { isPresented in
                    if !isPresented {
                        externalImportCoordinator.acknowledgeError(sceneID: markdownSceneID)
                        completeActiveExternalFileRequest()
                        drainPendingExternalOpenRequestsIfReady()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(externalImportCoordinator.pendingError?.message ?? "")
        }
        .alert(
            "Markdown File Error",
            isPresented: Binding(
                get: { fileOperationState.panelErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        fileOperationState.clearPanelError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(fileOperationState.panelErrorMessage ?? "")
        }
    }

    private var readyContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacNoteListView(
                notes: notes,
                selectedNoteID: selectedNoteID,
                syncController: syncController,
                widgetCoordinator: widgetCoordinator,
                onSelect: selectNote,
                onCreateNote: createNote
            )
        } detail: {
            MacNoteEditorView(
                note: selectedNote,
                attributedText: $attributedText,
                markdownEditorMode: macModeBinding,
                syncBridge: editorSyncBridge,
                loadError: loadError,
                saveError: saveError,
                onTextChanged: scheduleSave,
                resignFocusToggleToken: macResignFocusToggleToken,
                noteViewZoom: noteViewZoom
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
        MacMarkdownCommandActionsBuilder.build(
            isReady: startupCoordinator.state == .ready,
            hasSelectedNote: selectedNoteID != nil,
            isOperationInProgress: fileOperationState.isOperationInProgress,
            importMarkdown: beginMarkdownImportWithPanel,
            exportMarkdown: beginMarkdownExportWithPanel
        )
    }

    // MARK: - MYR-195 Slice 2: mode management

    /// Narrow selection-change helper. Applies the mode-reset rule:
    ///   oldID != newID  →  reset to Edit
    ///   oldID == newID  →  preserve mode
    /// Do not call for same-note reloads, attributedText changes, editorRevision bumps,
    /// save state changes, or sync state changes — those are not selection changes.
    private func updateMarkdownModeForSelectionChange(from oldID: UUID?, to newID: UUID?) {
        markdownEditorMode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: markdownEditorMode,
            oldID: oldID,
            newID: newID
        )
    }

    /// Routes user mode changes through the same production seam used by hosted tests.
    private var macModeBinding: Binding<MarkdownEditorMode> {
        MacMarkdownModeBindingFactory.make(
            mode: $markdownEditorMode,
            resignFocusToggleToken: $macResignFocusToggleToken,
            prepareForPreview: {
                guard let textView = editorSyncBridge.textView else { return }
                MacMarkdownPreviewFocusResignation.finalizeAndResignIfOwned(
                    window: textView.window,
                    textView: textView
                )
            }
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
        let newID = loadedNotes.first?.id
        updateMarkdownModeForSelectionChange(from: selectedNoteID, to: newID)
        selectedNoteID = newID
        attributedText = loadedNotes.first.map {
            MacNotePersistenceAdapter().attributedContent(for: $0)
        } ?? NSAttributedString(string: "")
        hasUnsavedChanges = false
        editorRevision = UUID()
        loadError = nil
        widgetCoordinator.publishNow()
    }

    private func loadNotesKeepingSelection() {
        do {
            let loadedNotes = try MacNotePersistenceAdapter().loadNotesCreatingFirstIfNeeded()
            notes = loadedNotes
            if let selectedNoteID, loadedNotes.contains(where: { $0.id == selectedNoteID }) {
                // Same note still exists: reload buffer but do NOT reset mode.
                attributedText = selectedNote.map {
                    MacNotePersistenceAdapter().attributedContent(for: $0)
                } ?? NSAttributedString(string: "")
            } else {
                // Note disappeared: fall back to first note — this is a selection change.
                let newID = loadedNotes.first?.id
                updateMarkdownModeForSelectionChange(from: selectedNoteID, to: newID)
                selectedNoteID = newID
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
                // Selected note disappeared: fallback is a real selection change.
                let newID = loadedNotes.first?.id
                updateMarkdownModeForSelectionChange(from: selectedNoteID, to: newID)
                selectedNoteID = newID
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
                let oldID = selectedNoteID
                selectedNoteID = nil
                updateMarkdownModeForSelectionChange(from: oldID, to: nil)
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
            let oldID = selectedNoteID
            selectedNoteID = note.id
            updateMarkdownModeForSelectionChange(from: oldID, to: note.id)
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
                let oldID = selectedNoteID
                selectedNoteID = newNote.id
                updateMarkdownModeForSelectionChange(from: oldID, to: newNote.id)
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
              fileOperationState.beginOperation() else {
            return
        }
        Task { @MainActor in
            do {
                let result = try await MacMarkdownFileOperationCoordinator().performImport(
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
                finishMarkdownPanelImportOperation(result)
            } catch {
                finishMarkdownFileOperation(errorMessage: markdownErrorMessage(for: error))
            }
        }
    }

    private func beginMarkdownExportWithPanel() {
        guard startupCoordinator.state == .ready,
              selectedNoteID != nil,
              fileOperationState.beginOperation() else {
            return
        }
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

    private func drainPendingExternalOpenRequestsIfReady() {
        if activeExternalFileRequestID != nil {
            drainPendingMarkdownOpenURLsIfReady()
            return
        }

        guard let request = externalOpenDispatcher.claimNextIfReady(
            startupIsReady: startupCoordinator.state == .ready,
            externalOperationIsAvailable: !fileOperationState.isOperationInProgress
                && externalImportCoordinator.activeRequest == nil
                && externalImportCoordinator.pendingError == nil
        ) else {
            return
        }

        switch request.kind {
        case .file(let url):
            activeExternalFileRequestID = request.id
            externalImportCoordinator.enqueue(url: url, sceneID: markdownSceneID)
            drainPendingMarkdownOpenURLsIfReady()

        case .widgetNote(let noteID):
            Task { @MainActor in
                let outcome = await MyRAMWidgetMacNoteRouter().route(
                    noteID: noteID,
                    flushPendingSave: flushPendingSave,
                    fetchActiveNote: { noteID in
                        try MacNotePersistenceAdapter().loadNote(id: noteID)
                    },
                    present: presentWidgetNote
                )
                switch outcome {
                case .completed:
                    externalOpenDispatcher.complete(requestID: request.id)
                    drainPendingExternalOpenRequestsIfReady()
                case .retainedForRetry:
                    externalOpenDispatcher.retainForRetry(requestID: request.id)
                }
            }
        }
    }

    private func drainPendingMarkdownOpenURLsIfReady() {
        guard !fileOperationState.isOperationInProgress else { return }
        guard let request = externalImportCoordinator.claimNext(
            sceneID: markdownSceneID,
            startupIsReady: startupCoordinator.state == .ready
        ) else {
            return
        }

        _ = fileOperationState.beginOperation()
        let url = request.url
        let requestID = request.id
        Task { @MainActor in
            do {
                let result = try await MacMarkdownFileOperationCoordinator().performImport(
                    flush: { await flushPendingSave() },
                    selectSource: { url },
                    consume: consumeMarkdownFile,
                    publish: publishImportedMarkdown,
                    present: presentImportedMarkdown
                )
                finishMarkdownImportOperation(result, requestID: requestID)
            } catch {
                externalImportCoordinator.complete(
                    requestID: requestID,
                    errorMessage: markdownErrorMessage(for: error)
                )
                finishMarkdownFileOperation()
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
        let oldID = selectedNoteID
        selectedNoteID = importedNote.id
        updateMarkdownModeForSelectionChange(from: oldID, to: importedNote.id)
        attributedText = adapter.attributedContent(for: importedNote)
        hasUnsavedChanges = false
        editorRevision = UUID()
        loadError = nil
        saveError = nil
        resumeSyncConvergence()
    }

    private func presentWidgetNote(_ note: Note) throws {
        let adapter = MacNotePersistenceAdapter()
        notes = try adapter.loadNotesCreatingFirstIfNeeded()
        let oldID = selectedNoteID
        selectedNoteID = note.id
        updateMarkdownModeForSelectionChange(from: oldID, to: note.id)
        attributedText = adapter.attributedContent(for: note)
        hasUnsavedChanges = false
        editorRevision = UUID()
        loadError = nil
        saveError = nil
        resumeSyncConvergence()
    }

    /// Cleans up after a File-menu panel import or export. Does not touch the external coordinator.
    private func finishMarkdownFileOperation(errorMessage: String? = nil) {
        fileOperationState.finishOperation(errorMessage: errorMessage)
        drainPendingExternalOpenRequestsIfReady()
    }

    /// Cleans up after a File-menu panel import result. Does not touch the external coordinator.
    private func finishMarkdownPanelImportOperation(_ result: MacMarkdownImportResult) {
        switch result {
        case .cancelled, .importedAndPresented:
            finishMarkdownFileOperation()
        case .importedButPresentationFailed:
            finishMarkdownFileOperation(
                errorMessage: "The Markdown note was imported, but MyRAM could not open it automatically."
            )
        }
    }

    private func finishMarkdownImportOperation(
        _ result: MacMarkdownImportResult,
        requestID: UUID
    ) {
        switch result {
        case .cancelled, .importedAndPresented:
            externalImportCoordinator.complete(requestID: requestID, errorMessage: nil)
            finishMarkdownFileOperation()
            completeActiveExternalFileRequest()
            drainPendingExternalOpenRequestsIfReady()
        case .importedButPresentationFailed:
            externalImportCoordinator.complete(
                requestID: requestID,
                errorMessage: "The Markdown note was imported, but MyRAM could not open it automatically."
            )
            finishMarkdownFileOperation()
        }
    }

    private func completeActiveExternalFileRequest() {
        guard let requestID = activeExternalFileRequestID else { return }
        externalOpenDispatcher.complete(requestID: requestID)
        activeExternalFileRequestID = nil
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
            drainPendingExternalOpenRequestsIfReady()
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
    @ObservedObject var widgetCoordinator: MyRAMWidgetHostCoordinator
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
                .contextMenu {
                    MyRAMWidgetSelectionButton(
                        coordinator: widgetCoordinator,
                        noteID: note.id
                    )
                }
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

/// Owns the exact Edit/Preview transition ordering shared by the root and integration tests.
enum MacMarkdownModeBindingFactory {
    static func make(
        mode: Binding<MarkdownEditorMode>,
        resignFocusToggleToken: Binding<Int>,
        prepareForPreview: @escaping () -> Void
    ) -> Binding<MarkdownEditorMode> {
        Binding(
            get: { mode.wrappedValue },
            set: { requested in
                guard requested != mode.wrappedValue else { return }

                if requested == .preview {
                    prepareForPreview()
                    resignFocusToggleToken.wrappedValue &+= 1
                }

                mode.wrappedValue = requested
            }
        )
    }
}

private enum MacLocalSavePublication {
    case ordinary
    case incomingBoundary
}

#endif
