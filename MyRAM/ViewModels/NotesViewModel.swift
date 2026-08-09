// NotesViewModel.swift
import NearbySyncCore
import SwiftUI
import SwiftData

enum NotesListItem: Identifiable {
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

enum PendingSyncRecoveryStatus: Equatable {
    case idle
    case running
    case succeeded
    case failed(String)

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

private struct PreparedLocalNoteEdit {
    let titleChange: SyncConvergenceCapturedLocalChange?
    let bodyChanges: [SyncConvergenceCapturedLocalChange]

    var capturedChanges: [SyncConvergenceCapturedLocalChange] {
        (titleChange.map { [$0] } ?? []) + bodyChanges
    }
}

private struct LegacyIncomingNoteSnapshot {
    let id: UUID
    let title: String
    let content: String
    let richTextContentData: Data?
    let isPinned: Bool?
    let createdAt: Date
    let modifiedAt: Date
    let deletedAt: Date?
    let folderID: UUID?
}

private struct LegacyIncomingIsolatedApplyResult {
    let syncConflicts: [SyncConflictVersion]
    let preservedConflicts: [SyncConflictVersion]
    let bufferedEffects: LegacyIncomingBufferedEffects
    let noteSnapshot: LegacyIncomingNoteSnapshot?
    let deletedCurrentNoteID: UUID?
    let currentFolderReplacementID: UUID?
    let shouldRefreshActiveNote: Bool
}

private enum LegacyIncomingIsolatedApplyFailure: Error {
    case nonAcknowledgeableOutcome
}

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var folders: [Folder] = []
    @Published var currentNote: Note? = nil
    @Published var currentFolder: Folder? = nil
    @Published private(set) var syncConflicts: [SyncConflictVersion] = []
    @Published private(set) var activeEditorSyncUpdate: ActiveEditorSyncUpdate?
    @Published private(set) var syncBatchErrorMessage: String?
    @Published private(set) var pendingSyncRecoveryStatus: PendingSyncRecoveryStatus = .idle
    @Published private(set) var hasUndoableAction = false
    @Published private(set) var hasRedoableAction = false
    
    private static let recentlyDeletedRetention: TimeInterval = 7 * 24 * 60 * 60
    private static let syncTextQuietPeriod: TimeInterval = 2
    private let context: ModelContext
    private let syncController: MyRAMSyncControlling?
    private let syncConflictStore: SyncConflictStore
    private let syncConflictService: MyRAMSyncConflictService
    private let saveContext: () throws -> Void
    private let saveLegacyIncomingApplyContext: (ModelContext) throws -> Void
    private let commitLegacyIncomingEffects: (LegacyIncomingBufferedEffects) throws -> Void
    private let syncBatchAccumulator: IPhoneSyncBatchAccumulator
    private let pendingIncomingBatches: FileBackedSyncBatchQueue
    private let pendingLocalConvergenceBatches: FileBackedSyncConvergenceLocalObligationQueue
    private var refreshPendingSyncStatusForLocalConvergenceMutation: (() async -> Void)?
    private let bodyHashCapabilityEnabled: Bool
    private let noteIntelligenceService = NoteIntelligenceService()
    private var pinnedThoughtExpansionByNoteID: [UUID: Bool] = [:]
    private(set) var isApplyingRemoteSyncChange = false
    private var mountedActiveEditorNoteID: UUID?
    private var syncConvergenceRuntime: SyncConvergenceRuntime!
    private var activeEditorPresentationAcknowledgment: ActiveEditorPresentationAcknowledgment?
    private var recentTextEditByNoteID: [UUID: Date] = [:]
    private var syncBatchReadyTask: Task<Void, Never>?
    private var pendingConvergenceResumeTask: Task<Void, Never>?
    private var undoStack: [UndoAction] = [] {
        didSet {
            hasUndoableAction = !undoStack.isEmpty
        }
    }
    private var redoStack: [UndoAction] = [] {
        didSet {
            hasRedoableAction = !redoStack.isEmpty
        }
    }

    init(
        context: ModelContext,
        syncController: MyRAMSyncControlling? = nil,
        syncConflictStore: SyncConflictStore = SyncConflictStore(),
        pendingIncomingBatchQueueFileURL: URL? = NotesViewModel.pendingIncomingBatchQueueFileURL(),
        pendingIncomingBatchQueueLimit: Int = 100,
        pendingLocalConvergenceBatchQueueFileURL: URL? = NotesViewModel.pendingLocalConvergenceBatchQueueFileURL(),
        pendingLocalConvergenceBatchQueueLimit: Int = 100,
        bodyHashCapabilityEnabled: Bool = true,
        syncBatchQuietWindow: TimeInterval = 3,
        resumesPendingConvergenceOnInit: Bool = true,
        saveContext: (() throws -> Void)? = nil,
        saveLegacyIncomingApplyContext: ((ModelContext) throws -> Void)? = nil,
        commitLegacyIncomingEffects: ((LegacyIncomingBufferedEffects) throws -> Void)? = nil
    ) {
        let resolvedSaveContext = saveContext ?? { try context.save() }
        self.context = context
        self.syncController = syncController
        self.syncConflictStore = syncConflictStore
        self.saveContext = resolvedSaveContext
        self.saveLegacyIncomingApplyContext = saveLegacyIncomingApplyContext ?? { try $0.save() }
        self.commitLegacyIncomingEffects = commitLegacyIncomingEffects ?? { effects in
            try Self.commitLegacyIncomingEffects(effects, to: syncConflictStore)
        }
        pendingIncomingBatches = FileBackedSyncBatchQueue(
            fileURL: pendingIncomingBatchQueueFileURL,
            limit: pendingIncomingBatchQueueLimit
        )
        pendingLocalConvergenceBatches = FileBackedSyncConvergenceLocalObligationQueue(
            fileURL: pendingLocalConvergenceBatchQueueFileURL,
            limit: pendingLocalConvergenceBatchQueueLimit
        )
        self.bodyHashCapabilityEnabled = bodyHashCapabilityEnabled
        syncBatchAccumulator = IPhoneSyncBatchAccumulator(
            originDeviceID: UUID(uuidString: MyRAMDeviceIdentity.currentDeviceID()) ?? UUID(),
            quietWindow: syncBatchQuietWindow
        )
        syncConflictService = MyRAMSyncConflictService(
            context: context,
            store: syncConflictStore,
            saveOperation: { _ in try resolvedSaveContext() }
        )
        self.syncController?.onChangesReceived = { [weak self] changes in
            await self?.applyIncomingSyncChanges(changes) ?? changes.map {
                LegacyIncomingChangeResult(changeID: $0.id, disposition: .retryRequired)
            }
        }
        self.syncController?.onLocalChangesAcknowledged = { [weak self] changes in
            await self?.advanceSyncBaselines(forAcknowledgedLocalChanges: changes)
        }
        self.syncController?.onBatchReceived = { [weak self] batch in
            await self?.applyIncomingSyncBatch(batch) ?? .acknowledgementPermitted
        }
        self.syncController?.onDurablyCaptureIncomingBatch = { [weak self] batch in
            self?.durablyCaptureIncomingBatch(batch) ?? false
        }
        if let statusController = syncController as? MyRAMSyncConvergenceStatusConfiguring {
            statusController.localConvergencePendingCountProvider = { [weak self] in
                self?.pendingLocalConvergenceBatches.pendingCount ?? 0
            }
            statusController.onFlushLocalConvergenceRequested = { [weak self] in
                await self?.resumePendingConvergencePresentation()
            }
            refreshPendingSyncStatusForLocalConvergenceMutation = { [weak statusController] in
                await statusController?.refreshPendingSyncStatus()
            }
        }
        syncConvergenceRuntime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: pendingIncomingBatches,
            localObligationQueue: pendingLocalConvergenceBatches,
            localBatchTransportAdapter: syncController as? SyncConvergenceLocalBatchTransportAdapter,
            presentationAdapter: NotesViewModelConvergencePresentationAdapter(viewModel: self),
            incomingLocalBoundaryAdapter: self,
            conflictStore: syncConflictStore
        )
        syncBatchReadyTask = Task { [weak self, syncBatchAccumulator] in
            let stream = await syncBatchAccumulator.readyBatches()
            for await obligation in stream {
                await self?.handleReadyLocalBatch(obligation)
            }
        }
        syncConflicts = syncConflictService.activeConflicts()
        purgeExpiredDeletedNotes()
        refreshCurrentFolderContent()
        loadLastNote()
        if resumesPendingConvergenceOnInit {
            resumePendingConvergencePresentationIfNeeded()
        }
    }

    deinit {
        syncBatchReadyTask?.cancel()
        pendingConvergenceResumeTask?.cancel()
    }

    func undoLastAction() {
        guard let action = undoStack.popLast() else { return }

        let succeeded: Bool
        switch action {
        case .noteCreation(let snapshot):
            undoNoteCreation(using: snapshot)
            succeeded = true
        case .folderCreation(let snapshot):
            undoFolderCreation(using: snapshot)
            succeeded = true
        case .noteMove(let snapshot):
            undoNoteMove(using: snapshot)
            succeeded = true
        case .noteDeletion(let snapshot):
            succeeded = undoNoteDeletion(using: snapshot)
        case .folderDeletion(let snapshot):
            succeeded = undoFolderDeletion(using: snapshot)
        }
        guard succeeded else {
            undoStack.append(action)
            return
        }
        redoStack.append(action)
        resumePendingConvergencePresentationIfNeeded()
    }

    func redoLastAction() {
        guard let action = redoStack.popLast() else { return }

        let succeeded: Bool
        switch action {
        case .noteCreation(let snapshot):
            succeeded = redoNoteCreation(using: snapshot)
        case .folderCreation(let snapshot):
            redoFolderCreation(using: snapshot)
            succeeded = true
        case .noteMove(let snapshot):
            redoNoteMove(using: snapshot)
            succeeded = true
        case .noteDeletion(let snapshot):
            redoNoteDeletion(using: snapshot)
            succeeded = true
        case .folderDeletion(let snapshot):
            redoFolderDeletion(using: snapshot)
            succeeded = true
        }
        guard succeeded else {
            redoStack.append(action)
            return
        }
        undoStack.append(action)
        resumePendingConvergencePresentationIfNeeded()
    }

    func refreshCurrentFolderContent() {
        let notesDescriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        let foldersDescriptor = FetchDescriptor<Folder>(
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )

        let allNotes = (try? context.fetch(notesDescriptor)) ?? []
        let allFolders = (try? context.fetch(foldersDescriptor)) ?? []

        if let currentFolder {
            notes = allNotes
                .filter { note in
                    let noteIsPinned = note.isPinned ?? false
                    let noteBelongsToCurrentFolder = note.folder?.id == currentFolder.id

                    // Pinned notes are global quick access; regular notes stay folder-scoped.
                    return noteIsPinned || noteBelongsToCurrentFolder
                }
                .sorted(by: sortNotes)
            folders = allFolders.filter { $0.parentFolder?.id == currentFolder.id }
        } else {
            notes = allNotes
                .filter { note in
                    let noteIsPinned = note.isPinned ?? false
                    let noteBelongsToRoot = note.folder == nil

                    // Root shows all pinned notes plus regular root notes.
                    return noteIsPinned || noteBelongsToRoot
                }
                .sorted(by: sortNotes)
            folders = allFolders.filter { $0.parentFolder == nil }
        }
    }

    func currentFolderListItems() -> [NotesListItem] {
        let pinnedNotes = notes.filter { $0.isPinned ?? false }
        let regularNotes = notes.filter { !($0.isPinned ?? false) }

        return pinnedNotes.map(NotesListItem.note)
            + folders.map(NotesListItem.folder)
            + regularNotes.map(NotesListItem.note)
    }

    func fetchRecentlyDeletedNotes() -> [Note] {
        purgeExpiredDeletedNotes()
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.deletedAt != nil },
            sortBy: [SortDescriptor(\.deletedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchSearchableNotes() -> [Note] {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).sorted(by: sortNotes)
    }

    func refreshRecentlyDeletedNotes() {
        purgeExpiredDeletedNotes()
    }

    private func loadLastNote() {
        guard let idString = UserDefaults.standard.string(forKey: "lastNoteID"),
              let uuid = UUID(uuidString: idString) else {
            return
        }

        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == uuid && note.deletedAt == nil
            }
        )
        if let note = (try? context.fetch(descriptor))?.first {
            currentNote = note
            currentFolder = note.folder
            refreshCurrentFolderContent()
        }
    }

    @discardableResult
    func createNewNote() -> Note? {
        let note = Note()
        let previousFolderModifiedAt = currentFolder?.modifiedAt
        do {
            let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
                noteID: note.id,
                body: note.content
            )
            _ = try NoteSequenceStateFullBodyIntegration.insertNewNote(
                note,
                preparedState: prepared,
                in: context
            )
            note.folder = currentFolder
            currentFolder?.modifiedAt = .now
            try saveContext()
        } catch {
            context.rollback()
            if let previousFolderModifiedAt {
                currentFolder?.modifiedAt = previousFolderModifiedAt
            }
            syncBatchErrorMessage = "Unable to create the note."
            return nil
        }
        recordSyncBatchChange(SyncConvergenceCapturedLocalChange(
            change: IPhoneSyncBatchCaptureHook.noteCreated(note),
            evidence: nil
        ))
        if let currentFolder {
            recordFolderSyncChange(currentFolder)
        }
        recordUndoAction(.noteCreation(NoteCreationUndoSnapshot(
            noteID: note.id,
            folderID: note.folder?.id
        )))
        refreshCurrentFolderContent()
        selectNote(note)
        return note
    }

    @discardableResult
    func importMarkdownDocument(_ document: ImportedMarkdownDocument) throws -> Note {
        let note = Note(title: document.suggestedTitle, content: document.source)
        let previousFolderModifiedAt = currentFolder?.modifiedAt

        do {
            let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
                noteID: note.id,
                body: note.content
            )
            _ = try NoteSequenceStateFullBodyIntegration.insertNewNote(
                note,
                preparedState: prepared,
                in: context
            )
            note.folder = currentFolder
            currentFolder?.modifiedAt = .now
            try saveContext()
        } catch {
            context.rollback()
            if let previousFolderModifiedAt {
                currentFolder?.modifiedAt = previousFolderModifiedAt
            }
            throw error
        }

        recordSyncBatchChange(SyncConvergenceCapturedLocalChange(
            change: IPhoneSyncBatchCaptureHook.noteCreated(note),
            evidence: nil
        ))
        if let currentFolder {
            recordFolderSyncChange(currentFolder)
        }
        recordUndoAction(.noteCreation(NoteCreationUndoSnapshot(
            noteID: note.id,
            folderID: note.folder?.id
        )))
        refreshCurrentFolderContent()
        selectNote(note)
        return note
    }

    func createFolder(named name: String = "New Folder") {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(
            name: trimmedName.isEmpty ? "New Folder" : trimmedName,
            parentFolder: currentFolder
        )
        currentFolder?.modifiedAt = .now
        context.insert(folder)
        try? context.save()
        recordFolderSyncChange(folder)
        if let currentFolder {
            recordFolderSyncChange(currentFolder)
        }
        recordUndoAction(.folderCreation(FolderCreationUndoSnapshot(
            folderID: folder.id,
            name: folder.name,
            createdAt: folder.createdAt,
            modifiedAt: folder.modifiedAt,
            parentFolderID: folder.parentFolder?.id
        )))
        refreshCurrentFolderContent()
    }

    func renameFolder(_ folder: Folder, to newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        folder.name = trimmedName
        folder.modifiedAt = .now
        try? context.save()
        recordFolderSyncChange(folder)
        refreshCurrentFolderContent()
    }

    func renameNote(_ note: Note, to newTitle: String) {
        guard note.deletedAt == nil else { return }
        let oldTitle = note.title
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        note.title = trimmedTitle
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        if let change = IPhoneSyncBatchCaptureHook.titleChanged(
            noteID: note.id,
            oldTitle: oldTitle,
            newTitle: trimmedTitle,
            modifiedAt: note.modifiedAt
        ) {
            recordSyncBatchChange(SyncConvergenceCapturedLocalChange(change: change, evidence: nil))
        }
        if let folder = note.folder {
            recordFolderSyncChange(folder)
        }
        refreshCurrentFolderContent()
    }

    func setNotePinned(_ note: Note, isPinned: Bool) {
        guard note.deletedAt == nil else { return }
        let currentPinned = note.isPinned ?? false
        guard currentPinned != isPinned else { return }
        note.isPinned = isPinned
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        recordNoteSyncChange(note)
        if let folder = note.folder {
            recordFolderSyncChange(folder)
        }
        refreshCurrentFolderContent()
    }

    func archiveNote(_ note: Note) {
        deleteNote(note)
    }

    func fetchAllFolders() -> [Folder] {
        let descriptor = FetchDescriptor<Folder>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func activeNoteCount(in folder: Folder) -> Int {
        var total = 0
        var queue: [Folder] = [folder]

        while let currentFolder = queue.first {
            queue.removeFirst()

            total += currentFolder.notes.reduce(into: 0) { count, note in
                if note.deletedAt == nil {
                    count += 1
                }
            }

            queue.append(contentsOf: currentFolder.childFolders)
        }

        return total
    }

    func openFolder(_ folder: Folder) {
        currentFolder = folder
        refreshCurrentFolderContent()
    }

    func navigateToParentFolder() {
        currentFolder = currentFolder?.parentFolder
        refreshCurrentFolderContent()
    }

    func deleteFolder(_ folder: Folder, preserveNotes: Bool = false) {
        let activeFolder = currentFolder
        let shouldNavigateToParent = activeFolder.map { isDescendantOrSame($0, of: folder) } ?? false
        let targetFolder = shouldNavigateToParent ? folder.parentFolder : currentFolder
        let subtreeFolders = allFoldersInSubtree(of: folder)
        let subtreeFolderIDs = Set(subtreeFolders.map(\.id))
        let deletedFolderPayloads = subtreeFolders.map { MyRAMFolderSyncPayload(folder: $0, isDeleted: true) }
        let deletedAt = Date()
        let folderSnapshot = buildFolderDeletionSnapshot(
            for: subtreeFolders,
            folderIDs: subtreeFolderIDs,
            preserveNotes: preserveNotes
        )

        if !preserveNotes,
           let selectedFolderID = currentNote?.folder?.id,
           subtreeFolderIDs.contains(selectedFolderID) {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }

        for noteMove in folderSnapshot.noteMoves {
            guard let note = fetchNote(withID: noteMove.noteID) else { continue }
            note.folder?.modifiedAt = deletedAt
            note.folder = nil
            if !preserveNotes {
                note.deletedAt = deletedAt
            }
            note.modifiedAt = deletedAt
        }

        for folderToDelete in subtreeFolders.sorted(by: { depth(for: $0) > depth(for: $1) }) {
            context.delete(folderToDelete)
        }
        try? context.save()
        for noteMove in folderSnapshot.noteMoves {
            guard let note = fetchNote(withID: noteMove.noteID) else { continue }
            recordNoteSyncChange(note, operation: note.deletedAt == nil ? .upsert : .delete)
        }
        for payload in deletedFolderPayloads {
            recordFolderSyncDeletion(payload)
        }
        recordUndoAction(.folderDeletion(folderSnapshot))

        currentFolder = targetFolder
        refreshCurrentFolderContent()
    }

    func selectNote(_ note: Note?) {
        let previousNoteID = currentNote?.id
        if let previousNoteID, previousNoteID != note?.id {
            resolveActiveEditorPresentation(noteID: previousNoteID, result: .verifiedComplete)
        }
        currentNote = note
        UserDefaults.standard.set(note?.id.uuidString, forKey: "lastNoteID")
        resumePendingConvergencePresentationIfNeeded()
    }

    func noteSuggestionLabels(for note: Note) -> [String] {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { item in
                item.deletedAt == nil
            }
        )
        let activeNotes = (try? context.fetch(descriptor)) ?? []
        return noteIntelligenceService.suggestionLabels(for: note, among: activeNotes)
    }

    func recordNoteOpened(_ note: Note) {
        noteIntelligenceService.recordNoteOpened(note)
    }

    func recordNoteEdited(_ note: Note) {
        noteIntelligenceService.recordNoteEdited(note)
    }

    func recordActiveNoteTextEdited(_ note: Note) {
        recentTextEditByNoteID[note.id] = Date()
    }

#if DEBUG
    func hasRecentTextEditForTesting(noteID: UUID) -> Bool {
        recentTextEditByNoteID[noteID] != nil
    }
#endif

    func refreshedNote(withID noteID: UUID) -> Note? {
        fetchNote(withID: noteID)
    }

    @discardableResult
    func commitNoteEdit(
        _ note: Note,
        title: String,
        content: String,
        richTextContentData: Data? = nil
    ) -> Bool {
        guard note.deletedAt == nil else { return false }
        let oldTitle = note.title
        let oldContent = note.content
        let oldRichTextContentData = note.richTextContentData
        let oldModifiedAt = note.modifiedAt
        let modifiedAt = Date.now
        let preparedEdit: PreparedLocalNoteEdit
        do {
            preparedEdit = try prepareLocalNoteEdit(
                noteID: note.id,
                oldTitle: oldTitle,
                newTitle: title,
                oldBody: oldContent,
                newBody: content,
                modifiedAt: modifiedAt
            )
        } catch {
            syncBatchErrorMessage = "Unable to capture local sync evidence for the latest edit."
            return false
        }
        note.title = title
        note.content = content
        note.richTextContentData = richTextContentData
        note.modifiedAt = modifiedAt
        do {
            try saveContext()
        } catch {
            note.title = oldTitle
            note.content = oldContent
            note.richTextContentData = oldRichTextContentData
            note.modifiedAt = oldModifiedAt
            syncBatchErrorMessage = "Unable to save the latest edit."
            return false
        }
        recordActiveNoteTextEdited(note)
        recordPreparedLocalNoteEdit(preparedEdit)
        return true
    }

    func updateNote(
        _ note: Note,
        title: String,
        content: String,
        richTextContentData: Data? = nil
    ) {
        commitNoteEdit(
            note,
            title: title,
            content: content,
            richTextContentData: richTextContentData
        )
    }

    func addPinnedThought(to note: Note, text: String = "") -> PinnedThought? {
        guard note.deletedAt == nil else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextOrder = ((note.pinnedThoughts.map(\.order).max()) ?? -1) + 1
        let thought = PinnedThought(text: trimmed, order: nextOrder, note: note)
        context.insert(thought)
        note.pinnedThoughts.append(thought)
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        recordPinnedThoughtSyncChange(thought)
        recordNoteSyncChange(note)
        if let folder = note.folder {
            recordFolderSyncChange(folder)
        }
        refreshCurrentFolderContent()
        return thought
    }

    func updatePinnedThought(_ thought: PinnedThought, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard thought.text != trimmed else { return }
        thought.text = trimmed
        thought.modifiedAt = .now
        thought.note?.modifiedAt = .now
        thought.note?.folder?.modifiedAt = .now
        try? context.save()
        recordPinnedThoughtSyncChange(thought)
        if let note = thought.note {
            recordNoteSyncChange(note)
        }
        if let folder = thought.note?.folder {
            recordFolderSyncChange(folder)
        }
        refreshCurrentFolderContent()
    }

    func setPinnedThoughtCollapsed(_ thought: PinnedThought, isCollapsed: Bool) {
        guard thought.isCollapsed != isCollapsed else { return }
        thought.isCollapsed = isCollapsed
        thought.modifiedAt = .now
        thought.note?.modifiedAt = .now
        try? context.save()
        recordPinnedThoughtSyncChange(thought)
        if let note = thought.note {
            recordNoteSyncChange(note)
        }
        refreshCurrentFolderContent()
    }

    func isPinnedThoughtsSectionExpanded(for note: Note) -> Bool {
        pinnedThoughtExpansionByNoteID[note.id] ?? false
    }

    func setPinnedThoughtsSectionExpanded(_ isExpanded: Bool, for note: Note) {
        pinnedThoughtExpansionByNoteID[note.id] = isExpanded
    }

    func movePinnedThought(_ thought: PinnedThought, direction: PinnedThoughtMoveDirection) {
        guard let note = thought.note else { return }
        var orderedThoughts = sortedPinnedThoughts(for: note)
        guard let currentIndex = orderedThoughts.firstIndex(where: { $0.id == thought.id }) else { return }
        let targetIndex: Int
        switch direction {
        case .up:
            targetIndex = currentIndex - 1
        case .down:
            targetIndex = currentIndex + 1
        }
        guard orderedThoughts.indices.contains(targetIndex) else { return }
        orderedThoughts.swapAt(currentIndex, targetIndex)
        for (index, orderedThought) in orderedThoughts.enumerated() {
            orderedThought.order = index
            orderedThought.modifiedAt = .now
        }
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        for orderedThought in orderedThoughts {
            recordPinnedThoughtSyncChange(orderedThought)
        }
        recordNoteSyncChange(note)
        if let folder = note.folder {
            recordFolderSyncChange(folder)
        }
        refreshCurrentFolderContent()
    }

    func movePinnedThought(_ thought: PinnedThought, before targetThought: PinnedThought) {
        guard let note = thought.note,
              targetThought.note?.id == note.id,
              thought.id != targetThought.id else { return }
        var orderedThoughts = sortedPinnedThoughts(for: note)
        guard let currentIndex = orderedThoughts.firstIndex(where: { $0.id == thought.id }),
              let targetIndex = orderedThoughts.firstIndex(where: { $0.id == targetThought.id }) else { return }
        let movedThought = orderedThoughts.remove(at: currentIndex)
        let adjustedTargetIndex = currentIndex < targetIndex ? targetIndex - 1 : targetIndex
        orderedThoughts.insert(movedThought, at: adjustedTargetIndex)
        for (index, orderedThought) in orderedThoughts.enumerated() {
            orderedThought.order = index
            orderedThought.modifiedAt = .now
        }
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        for orderedThought in orderedThoughts {
            recordPinnedThoughtSyncChange(orderedThought)
        }
        recordNoteSyncChange(note)
        if let folder = note.folder {
            recordFolderSyncChange(folder)
        }
        refreshCurrentFolderContent()
    }

    func movePinnedThought(_ thought: PinnedThought, toIndex targetIndex: Int) {
        guard let note = thought.note else { return }
        var orderedThoughts = sortedPinnedThoughts(for: note)
        guard let currentIndex = orderedThoughts.firstIndex(where: { $0.id == thought.id }) else { return }
        let clampedTargetIndex = min(max(targetIndex, 0), orderedThoughts.count)
        guard clampedTargetIndex != currentIndex,
              clampedTargetIndex != currentIndex + 1 else { return }

        let movedThought = orderedThoughts.remove(at: currentIndex)
        let adjustedTargetIndex = clampedTargetIndex > currentIndex
            ? clampedTargetIndex - 1
            : clampedTargetIndex

        orderedThoughts.insert(movedThought, at: adjustedTargetIndex)
        for (index, orderedThought) in orderedThoughts.enumerated() {
            orderedThought.order = index
            orderedThought.modifiedAt = .now
        }
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        for orderedThought in orderedThoughts {
            recordPinnedThoughtSyncChange(orderedThought)
        }
        recordNoteSyncChange(note)
        if let folder = note.folder {
            recordFolderSyncChange(folder)
        }
        refreshCurrentFolderContent()
    }

    func unpinThought(_ thought: PinnedThought) {
        deletePinnedParagraph(thought)
    }

    func deletePinnedParagraph(_ thought: PinnedThought) {
        let note = thought.note
        let deletionPayload = MyRAMPinnedThoughtSyncPayload(thought: thought, isDeleted: true)
        note?.pinnedThoughts.removeAll { $0.id == thought.id }
        context.delete(thought)
        reorderPinnedThoughts(for: note)
        note?.modifiedAt = .now
        note?.folder?.modifiedAt = .now
        try? context.save()
        recordPinnedThoughtSyncDeletion(deletionPayload)
        if let note {
            recordNoteSyncChange(note)
        }
        if let folder = note?.folder {
            recordFolderSyncChange(folder)
        }
        refreshCurrentFolderContent()
    }

    func sortedPinnedThoughts(for note: Note) -> [PinnedThought] {
        note.pinnedThoughts.sorted {
            if $0.order != $1.order {
                return $0.order < $1.order
            }
            return $0.createdAt < $1.createdAt
        }
    }

    func activeSyncConflicts(for note: Note) -> [SyncConflictVersion] {
        syncConflictService.activeConflicts(for: note, in: syncConflicts)
    }

    func localText(forSyncConflict conflict: SyncConflictVersion) -> String {
        switch conflict.field {
        case .noteTitle:
            return fetchNote(withID: conflict.entityID)?.title ?? conflict.localText
        case .noteContent:
            return fetchNote(withID: conflict.entityID)?.content ?? conflict.localText
        case .folderTitle:
            return fetchFolder(withID: conflict.entityID)?.name ?? conflict.localText
        case .pinnedText:
            return fetchPinnedThought(withID: conflict.entityID)?.text ?? conflict.localText
        }
    }

    func markSyncConflictReviewed(_ conflict: SyncConflictVersion) {
        // Terminal conflict action: keep the local model, remove the saved
        // remote version, and publish the kept local value as the winner.
        guard let result = syncConflictService.keepLocal(conflict, activeNoteID: currentNote?.id) else { return }
        let resolution = result.resolution
        syncConflicts = result.conflicts
        saveResolvedVersionAsSyncBase(conflict, resolvedText: resolution.resolvedText, result: result)
        recordSyncConflictResolution(
            conflict,
            resolvedText: resolution.resolvedText,
            baseText: resolution.baseText
        )

        if result.shouldRefreshActiveNote {
            publishActiveEditorReload(noteID: conflict.entityID, reason: .unsupportedIntegratedChange)
        }
        refreshCurrentFolderContent()
        resumePendingConvergencePresentationIfNeeded()
    }

    func restoreSyncConflict(_ conflict: SyncConflictVersion) {
        // Restore is local and terminal for this preserved conflict. It does not
        // bounce the restored value back as a fresh sync edit.
        guard let result = syncConflictService.acceptIncoming(conflict, activeNoteID: currentNote?.id) else { return }
        let resolution = result.resolution
        syncConflicts = result.conflicts
        saveResolvedVersionAsSyncBase(conflict, resolvedText: resolution.resolvedText, result: result)
        recordSyncConflictResolution(
            conflict,
            resolvedText: resolution.resolvedText,
            baseText: resolution.baseText
        )

        if result.shouldRefreshActiveNote {
            publishActiveEditorReload(noteID: conflict.entityID, reason: .unsupportedIntegratedChange)
        }
        refreshCurrentFolderContent()
        resumePendingConvergencePresentationIfNeeded()
    }

    func saveMergedSyncConflict(_ conflict: SyncConflictVersion, mergedText: String) {
        guard let result = syncConflictService.saveMergedText(
            conflict,
            text: mergedText,
            activeNoteID: currentNote?.id
        ) else { return }
        let resolution = result.resolution
        syncConflicts = result.conflicts
        saveResolvedVersionAsSyncBase(conflict, resolvedText: resolution.resolvedText, result: result)
        recordSyncConflictResolution(
            conflict,
            resolvedText: resolution.resolvedText,
            baseText: resolution.baseText
        )

        if result.shouldRefreshActiveNote {
            publishActiveEditorReload(noteID: conflict.entityID, reason: .unsupportedIntegratedChange)
        }
        refreshCurrentFolderContent()
        resumePendingConvergencePresentationIfNeeded()
    }

    func discardSyncConflict(_ conflict: SyncConflictVersion) {
        // Discard keeps the local model and publishes that local value as the
        // winner so peers do not keep replaying the discarded remote version.
        guard let result = syncConflictService.keepLocal(conflict, activeNoteID: currentNote?.id) else { return }
        let resolution = result.resolution
        syncConflicts = result.conflicts
        saveResolvedVersionAsSyncBase(conflict, resolvedText: resolution.resolvedText, result: result)
        recordSyncConflictResolution(
            conflict,
            resolvedText: resolution.resolvedText,
            baseText: resolution.baseText
        )

        if result.shouldRefreshActiveNote {
            publishActiveEditorReload(noteID: conflict.entityID, reason: .unsupportedIntegratedChange)
        }
        refreshCurrentFolderContent()
        resumePendingConvergencePresentationIfNeeded()
    }

    func addPhotoAttachment(to note: Note, imageData: Data) {
        guard note.deletedAt == nil else { return }
        let attachment = NotePhotoAttachment(imageData: imageData, note: note)
        context.insert(attachment)
        note.photoAttachments.append(attachment)
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        recordNoteSyncChange(note)
        recordPhotoAttachmentSyncChange(attachment, updatedAt: note.modifiedAt)
        if let folder = note.folder {
            recordFolderSyncChange(folder)
        }
        refreshCurrentFolderContent()
    }

    private func reorderPinnedThoughts(for note: Note?) {
        guard let note else { return }
        let orderedThoughts = sortedPinnedThoughts(for: note)
        for (index, thought) in orderedThoughts.enumerated() {
            thought.order = index
        }
    }

    func removePhotoAttachment(_ attachment: NotePhotoAttachment, from note: Note) {
        guard note.deletedAt == nil else { return }
        let deletionPayload = MyRAMPhotoAttachmentSyncPayload(attachment: attachment, isDeleted: true)
        note.photoAttachments.removeAll { $0.id == attachment.id }
        context.delete(attachment)
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        recordNoteSyncChange(note)
        recordPhotoAttachmentSyncDeletion(deletionPayload, updatedAt: note.modifiedAt)
        if let folder = note.folder {
            recordFolderSyncChange(folder)
        }
        refreshCurrentFolderContent()
    }

    func deleteNote(_ note: Note) {
        let snapshot = NoteDeletionUndoSnapshot(
            noteID: note.id,
            previousDeletedAt: note.deletedAt,
            previousFolderID: note.folder?.id
        )
        note.deletedAt = .now
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        recordSyncBatchChange(SyncConvergenceCapturedLocalChange(
            change: IPhoneSyncBatchCaptureHook.lifecycleChanged(note),
            evidence: nil
        ))
        if let folder = note.folder {
            recordFolderSyncChange(folder)
        }
        recordUndoAction(.noteDeletion(snapshot))
        refreshCurrentFolderContent()
        if currentNote?.id == note.id {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }
    }

    func moveNote(_ note: Note, to destinationFolder: Folder?) {
        guard note.deletedAt == nil else { return }
        if note.folder?.id == destinationFolder?.id { return }
        let previousFolderID = note.folder?.id
        let destinationFolderID = destinationFolder?.id

        note.folder?.modifiedAt = .now
        destinationFolder?.modifiedAt = .now
        note.folder = destinationFolder
        note.modifiedAt = .now
        try? context.save()
        recordNoteSyncChange(note)
        if let previousFolder = previousFolderID.flatMap(fetchFolder(withID:)) {
            recordFolderSyncChange(previousFolder)
        }
        if let destinationFolder {
            recordFolderSyncChange(destinationFolder)
        }
        recordUndoAction(.noteMove(NoteMoveUndoSnapshot(
            noteID: note.id,
            sourceFolderID: previousFolderID,
            destinationFolderID: destinationFolderID
        )))
        refreshCurrentFolderContent()
    }

    func restoreNote(_ note: Note) {
        do {
            _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
                for: note,
                in: context
            )
            note.deletedAt = nil
            note.modifiedAt = .now
            note.folder?.modifiedAt = .now
            try saveContext()
        } catch {
            context.rollback()
            syncBatchErrorMessage = "Unable to restore the note."
            return
        }
        recordSyncBatchChange(SyncConvergenceCapturedLocalChange(
            change: IPhoneSyncBatchCaptureHook.lifecycleChanged(note),
            evidence: nil
        ))
        if let folder = note.folder {
            recordFolderSyncChange(folder)
        }
        refreshCurrentFolderContent()
    }

#if DEBUG
    func generateDemoNotes() {
        let selectedDemoNoteID = currentNote?.id
        DebugDemoDataGenerator.generateDemoNotes(in: context)
        currentFolder = nil
        if let selectedDemoNoteID, DebugDemoDataGenerator.demoNoteIDs.contains(selectedDemoNoteID) {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }
        refreshCurrentFolderContent()
    }

    func clearDemoNotes() {
        DebugDemoDataGenerator.clearDemoNotes(in: context)
        if let currentNote, DebugDemoDataGenerator.demoNoteIDs.contains(currentNote.id) {
            self.currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }
        refreshCurrentFolderContent()
    }
#endif

    func permanentlyDeleteNote(_ note: Note) {
        removeUndoHistoryReferencingDeletedNote(noteID: note.id)
        context.delete(note)
        try? context.save()
        refreshCurrentFolderContent()
        if currentNote?.id == note.id {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }
    }

    private func sortNotes(_ lhs: Note, _ rhs: Note) -> Bool {
        let lhsPinned = lhs.isPinned ?? false
        let rhsPinned = rhs.isPinned ?? false
        if lhsPinned != rhsPinned {
            return lhsPinned && !rhsPinned
        }
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        return lhs.createdAt > rhs.createdAt
    }

    private func recordUndoAction(_ action: UndoAction) {
        redoStack.removeAll()
        undoStack.append(action)
    }

    private func undoNoteCreation(using snapshot: NoteCreationUndoSnapshot) {
        guard let note = fetchNote(withID: snapshot.noteID) else {
            refreshCurrentFolderContent()
            return
        }

        note.deletedAt = .now
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        refreshCurrentFolderContent()
        if currentNote?.id == note.id {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }
    }

    private func redoNoteCreation(using snapshot: NoteCreationUndoSnapshot) -> Bool {
        guard let note = fetchNote(withID: snapshot.noteID) else {
            refreshCurrentFolderContent()
            return true
        }

        do {
            _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
                for: note,
                in: context
            )
            note.deletedAt = nil
            note.folder = snapshot.folderID.flatMap(fetchFolder(withID:))
            note.modifiedAt = .now
            note.folder?.modifiedAt = .now
            try saveContext()
        } catch {
            context.rollback()
            syncBatchErrorMessage = "Unable to redo note creation."
            return false
        }
        refreshCurrentFolderContent()
        return true
    }

    private func undoFolderCreation(using snapshot: FolderCreationUndoSnapshot) {
        guard let folder = fetchFolder(withID: snapshot.folderID) else {
            refreshCurrentFolderContent()
            return
        }

        let parentFolder = folder.parentFolder
        for childFolder in Array(folder.childFolders) {
            childFolder.parentFolder = parentFolder
            childFolder.modifiedAt = .now
        }
        for note in Array(folder.notes) {
            note.folder = parentFolder
            note.modifiedAt = .now
        }
        parentFolder?.modifiedAt = .now

        if currentFolder?.id == folder.id {
            currentFolder = parentFolder
        }

        context.delete(folder)
        try? context.save()
        refreshCurrentFolderContent()
    }

    private func redoFolderCreation(using snapshot: FolderCreationUndoSnapshot) {
        if fetchFolder(withID: snapshot.folderID) != nil {
            refreshCurrentFolderContent()
            return
        }

        let folder = Folder(
            name: snapshot.name,
            parentFolder: snapshot.parentFolderID.flatMap(fetchFolder(withID:))
        )
        folder.id = snapshot.folderID
        folder.createdAt = snapshot.createdAt
        folder.modifiedAt = snapshot.modifiedAt
        context.insert(folder)
        folder.parentFolder?.modifiedAt = .now
        try? context.save()
        refreshCurrentFolderContent()
    }

    private func undoNoteMove(using snapshot: NoteMoveUndoSnapshot) {
        applyNoteMove(
            noteID: snapshot.noteID,
            destinationFolderID: snapshot.sourceFolderID
        )
    }

    private func redoNoteMove(using snapshot: NoteMoveUndoSnapshot) {
        applyNoteMove(
            noteID: snapshot.noteID,
            destinationFolderID: snapshot.destinationFolderID
        )
    }

    private func applyNoteMove(noteID: UUID, destinationFolderID: UUID?) {
        guard let note = fetchNote(withID: noteID), note.deletedAt == nil else {
            refreshCurrentFolderContent()
            return
        }

        let destinationFolder = destinationFolderID.flatMap(fetchFolder(withID:))
        note.folder?.modifiedAt = .now
        destinationFolder?.modifiedAt = .now
        note.folder = destinationFolder
        note.modifiedAt = .now
        try? context.save()
        refreshCurrentFolderContent()
    }

    private func undoNoteDeletion(using snapshot: NoteDeletionUndoSnapshot) -> Bool {
        guard let note = fetchNote(withID: snapshot.noteID) else {
            refreshCurrentFolderContent()
            return true
        }

        do {
            _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
                for: note,
                in: context
            )
            note.deletedAt = snapshot.previousDeletedAt
            note.folder = snapshot.previousFolderID.flatMap(fetchFolder(withID:))
            note.modifiedAt = .now
            note.folder?.modifiedAt = .now
            try saveContext()
        } catch {
            context.rollback()
            syncBatchErrorMessage = "Unable to undo note deletion."
            return false
        }
        refreshCurrentFolderContent()
        return true
    }

    private func redoNoteDeletion(using snapshot: NoteDeletionUndoSnapshot) {
        guard let note = fetchNote(withID: snapshot.noteID) else {
            refreshCurrentFolderContent()
            return
        }

        note.deletedAt = .now
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        refreshCurrentFolderContent()
        if currentNote?.id == note.id {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }
    }

    private func undoFolderDeletion(using snapshot: FolderDeletionUndoSnapshot) -> Bool {
        let notesToRestore = snapshot.noteMoves.compactMap {
            fetchNote(withID: $0.noteID)
        }
        do {
            for note in notesToRestore {
                _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
                    for: note,
                    in: context
                )
            }
        } catch {
            context.rollback()
            syncBatchErrorMessage = "Unable to undo folder deletion."
            return false
        }
        var recreatedFolders: [UUID: Folder] = [:]

        for folderRecord in snapshot.folders.sorted(by: { $0.depth < $1.depth }) {
            let parentFolder = folderRecord.parentFolderID.flatMap { parentID in
                recreatedFolders[parentID] ?? fetchFolder(withID: parentID)
            }
            let folder = Folder(name: folderRecord.name, parentFolder: parentFolder)
            folder.id = folderRecord.id
            folder.createdAt = folderRecord.createdAt
            folder.modifiedAt = folderRecord.modifiedAt
            context.insert(folder)
            recreatedFolders[folder.id] = folder
        }

        for noteMove in snapshot.noteMoves {
            guard let note = fetchNote(withID: noteMove.noteID) else { continue }
            note.folder = noteMove.originalFolderID.flatMap { folderID in
                recreatedFolders[folderID] ?? fetchFolder(withID: folderID)
            }
            note.deletedAt = noteMove.previousDeletedAt
            note.modifiedAt = .now
        }

        do {
            try saveContext()
        } catch {
            context.rollback()
            syncBatchErrorMessage = "Unable to undo folder deletion."
            return false
        }
        refreshCurrentFolderContent()
        return true
    }

    private func redoFolderDeletion(using snapshot: FolderDeletionUndoSnapshot) {
        let deletedAt = Date()
        let folderIDs = Set(snapshot.folders.map(\.id))
        let rootFolderRecord = snapshot.folders.min { $0.depth < $1.depth }
        let targetFolder = rootFolderRecord?.parentFolderID.flatMap(fetchFolder(withID:))

        if let currentFolder, folderIDs.contains(currentFolder.id) {
            self.currentFolder = targetFolder
        }

        if !snapshot.preserveNotes,
           let selectedFolderID = currentNote?.folder?.id,
           folderIDs.contains(selectedFolderID) {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }

        for noteMove in snapshot.noteMoves {
            guard let note = fetchNote(withID: noteMove.noteID) else { continue }
            note.folder?.modifiedAt = deletedAt
            note.folder = nil
            note.deletedAt = snapshot.preserveNotes ? noteMove.previousDeletedAt : deletedAt
            note.modifiedAt = deletedAt
        }

        for folderRecord in snapshot.folders.sorted(by: { $0.depth > $1.depth }) {
            guard let folder = fetchFolder(withID: folderRecord.id) else { continue }
            context.delete(folder)
        }

        try? context.save()
        refreshCurrentFolderContent()
    }

    private func buildFolderDeletionSnapshot(
        for folders: [Folder],
        folderIDs: Set<UUID>,
        preserveNotes: Bool
    ) -> FolderDeletionUndoSnapshot {
        let folderSnapshots = folders.map {
            FolderUndoSnapshot(
                id: $0.id,
                name: $0.name,
                createdAt: $0.createdAt,
                modifiedAt: $0.modifiedAt,
                parentFolderID: $0.parentFolder?.id,
                depth: depth(for: $0)
            )
        }

        let allNotes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let noteMoves = allNotes
            .filter { note in
                guard let folderID = note.folder?.id else { return false }
                return folderIDs.contains(folderID)
            }
            .map {
                NoteFolderUndoSnapshot(
                    noteID: $0.id,
                    originalFolderID: $0.folder?.id,
                    previousDeletedAt: $0.deletedAt
                )
            }

        return FolderDeletionUndoSnapshot(
            folders: folderSnapshots,
            noteMoves: noteMoves,
            preserveNotes: preserveNotes
        )
    }

    private func depth(for folder: Folder) -> Int {
        var depth = 0
        var cursor = folder.parentFolder
        while cursor != nil {
            depth += 1
            cursor = cursor?.parentFolder
        }
        return depth
    }

    private func fetchNote(withID noteID: UUID) -> Note? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == noteID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchFolder(withID folderID: UUID) -> Folder? {
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { folder in
                folder.id == folderID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchPinnedThought(withID thoughtID: UUID) -> PinnedThought? {
        let descriptor = FetchDescriptor<PinnedThought>(
            predicate: #Predicate { thought in
                thought.id == thoughtID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchPhotoAttachment(withID attachmentID: UUID) -> NotePhotoAttachment? {
        let descriptor = FetchDescriptor<NotePhotoAttachment>(
            predicate: #Predicate { attachment in
                attachment.id == attachmentID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private func recordNoteSyncChange(_ note: Note, operation: SyncOperation = .upsert) {
        guard !isApplyingRemoteSyncChange,
              !hasActiveNoteTextConflict(note),
              let payload = try? MyRAMSyncPayloadCoding.encode(
                MyRAMLegacySyncPayloadBuilder.notePayload(note: note, conflictStore: syncConflictStore)
              ) else { return }

        syncController?.recordLocalChange(
            entityType: .item,
            entityID: note.id.uuidString,
            operation: operation,
            payload: payload,
            updatedAt: note.modifiedAt
        )
    }

    private func prepareLocalNoteEdit(
        noteID: UUID,
        oldTitle: String,
        newTitle: String,
        oldBody: String,
        newBody: String,
        modifiedAt: Date
    ) throws -> PreparedLocalNoteEdit {
        let titleChange = IPhoneSyncBatchCaptureHook.titleChanged(
            noteID: noteID,
            oldTitle: oldTitle,
            newTitle: newTitle,
            modifiedAt: modifiedAt
        ).map { SyncConvergenceCapturedLocalChange(change: $0, evidence: nil) }

        let bodyChanges = try SyncBatchNoteChangeCapture.capturedBodyChanges(
            noteID: noteID,
            oldBody: oldBody,
            newBody: newBody,
            modifiedAt: modifiedAt,
            bodyHashCapabilityEnabled: bodyHashCapabilityEnabled
        )

        return PreparedLocalNoteEdit(titleChange: titleChange, bodyChanges: bodyChanges)
    }

    private func recordPreparedLocalNoteEdit(_ edit: PreparedLocalNoteEdit) {
        edit.capturedChanges.forEach(recordSyncBatchChange)
    }

    private func legacyIncomingBodyMutationNoteIDs(in changes: [SyncChange]) -> Set<UUID> {
        Set(changes.compactMap { change in
            guard change.entityType == .item,
                  let payload = try? MyRAMSyncPayloadCoding.decodeNote(from: change.payload) else {
                return nil
            }
            return payload.id
        })
    }

    private static func bodyMutationNoteIDs(in batch: SyncBatch) -> Set<UUID> {
        Set(batch.changes.compactMap { change -> UUID? in
            switch change {
            case .noteCreated(let payload):
                return payload.noteID
            case .noteBodyTextInserted(let payload):
                return payload.noteID
            case .noteBodyTextDeleted(let payload):
                return payload.noteID
            case .noteBodyTextInsertedAnchored(let payload):
                return payload.noteID
            case .noteBodyTextDeletedAnchored(let payload):
                return payload.noteID
            case .noteBodyReconciled(let payload):
                return payload.noteID
            case .noteTitleChanged, .noteLifecycleChanged:
                return nil
            }
        })
    }

    private func recordSyncBatchChange(_ capturedChange: SyncConvergenceCapturedLocalChange) {
        guard !isApplyingRemoteSyncChange else { return }
        Task {
            await syncBatchAccumulator.record(capturedChange)
            if let issue = await syncBatchAccumulator.takeLastSequenceReservationIssue() {
                syncBatchErrorMessage = SyncBatchSequenceIssueDescription.message(for: issue)
            }
        }
    }

    private func recordFolderSyncChange(_ folder: Folder) {
        guard !isApplyingRemoteSyncChange,
              let payload = try? MyRAMSyncPayloadCoding.encode(MyRAMFolderSyncPayload(folder: folder)) else { return }

        syncController?.recordLocalChange(
            entityType: .collection,
            entityID: folder.id.uuidString,
            payload: payload,
            updatedAt: folder.modifiedAt
        )
    }

    private func recordFolderSyncDeletion(_ payload: MyRAMFolderSyncPayload) {
        guard !isApplyingRemoteSyncChange,
              let data = try? MyRAMSyncPayloadCoding.encode(payload) else { return }

        syncController?.recordLocalChange(
            entityType: .collection,
            entityID: payload.id.uuidString,
            operation: .delete,
            payload: data,
            updatedAt: payload.modifiedAt
        )
    }

    private func recordPinnedThoughtSyncChange(_ thought: PinnedThought) {
        guard !isApplyingRemoteSyncChange,
              !hasActivePinnedTextConflict(thought),
              let payload = try? MyRAMSyncPayloadCoding.encode(
                MyRAMLegacySyncPayloadBuilder.pinnedThoughtPayload(
                    thought: thought,
                    conflictStore: syncConflictStore
                )
              ) else { return }
        syncController?.recordLocalChange(
            entityType: .marker,
            entityID: thought.id.uuidString,
            payload: payload,
            updatedAt: thought.modifiedAt
        )
    }

    private func recordPinnedThoughtSyncDeletion(_ payload: MyRAMPinnedThoughtSyncPayload) {
        guard !isApplyingRemoteSyncChange,
              !syncConflictStore.hasActiveConflict(entityType: .pinnedThought, entityID: payload.id, field: .pinnedText),
              let data = try? MyRAMSyncPayloadCoding.encode(payload) else { return }

        syncController?.recordLocalChange(
            entityType: .marker,
            entityID: payload.id.uuidString,
            operation: .delete,
            payload: data,
            updatedAt: payload.modifiedAt
        )
    }

    private func hasActiveNoteTextConflict(_ note: Note) -> Bool {
        return syncConflictStore.hasActiveConflict(entityType: .note, entityID: note.id, field: .noteTitle)
            || syncConflictStore.hasActiveConflict(entityType: .note, entityID: note.id, field: .noteContent)
    }

    private func hasActivePinnedTextConflict(_ thought: PinnedThought) -> Bool {
        syncConflictStore.hasActiveConflict(entityType: .pinnedThought, entityID: thought.id, field: .pinnedText)
    }

    private func recordPhotoAttachmentSyncChange(_ attachment: NotePhotoAttachment, updatedAt: Date) {
        guard !isApplyingRemoteSyncChange,
              let payload = try? MyRAMSyncPayloadCoding.encode(MyRAMPhotoAttachmentSyncPayload(attachment: attachment)) else { return }

        syncController?.recordLocalChange(
            entityType: .attachment,
            entityID: attachment.id.uuidString,
            payload: payload,
            updatedAt: updatedAt
        )
    }

    private func recordPhotoAttachmentSyncDeletion(_ payload: MyRAMPhotoAttachmentSyncPayload, updatedAt: Date) {
        guard !isApplyingRemoteSyncChange,
              let data = try? MyRAMSyncPayloadCoding.encode(payload) else { return }

        syncController?.recordLocalChange(
            entityType: .attachment,
            entityID: payload.id.uuidString,
            operation: .delete,
            payload: data,
            updatedAt: updatedAt
        )
    }

    private func recordSyncConflictPreserved(_ conflict: SyncConflictVersion) {
        recordSyncConflictMetadata(MyRAMSyncConflictPayload(action: .preserved, conflict: conflict, updatedAt: conflict.preservedAt))
    }

    private func recordSyncConflictResolution(
        _ conflict: SyncConflictVersion,
        resolvedText: String,
        baseText: String
    ) {
        recordSyncConflictMetadata(
            MyRAMSyncConflictPayload(
                action: .resolved,
                conflict: conflict,
                resolvedText: resolvedText,
                baseText: baseText
            )
        )
    }

    private func saveResolvedVersionAsSyncBase(
        _ conflict: SyncConflictVersion,
        resolvedText: String,
        result: SyncConflictRestoreResult
    ) {
        // Conflict resolution establishes the chosen text as the next shared
        // baseline; otherwise the first normal edit after resolution is
        // compared against the stale pre-conflict text.
        switch conflict.field {
        case .noteTitle:
            guard let note = result.note else { return }
            syncConflictStore.saveNoteTitleBaseline(
                noteID: conflict.entityID,
                title: resolvedText,
                modifiedAt: note.modifiedAt,
                originDeviceID: nil
            )

        case .noteContent:
            guard let note = result.note else { return }
            syncConflictStore.saveNoteContentBaseline(
                noteID: conflict.entityID,
                content: resolvedText,
                richTextContentData: note.richTextContentData,
                modifiedAt: note.modifiedAt,
                originDeviceID: nil
            )

        case .folderTitle:
            break

        case .pinnedText:
            guard let pinnedThought = result.pinnedThought else { return }
            syncConflictStore.savePinnedTextBaseline(
                thoughtID: conflict.entityID,
                text: resolvedText,
                modifiedAt: pinnedThought.modifiedAt,
                originDeviceID: nil
            )
        }
    }

    private func recordSyncConflictMetadata(_ payload: MyRAMSyncConflictPayload) {
        guard let data = try? MyRAMSyncPayloadCoding.encode(payload) else { return }
        syncController?.recordLocalChange(
            entityType: .conflict,
            entityID: payload.conflictID.uuidString,
            payload: data,
            updatedAt: payload.updatedAt
        )
    }

    func advanceSyncBaselines(forAcknowledgedLocalChanges changes: [SyncChange]) async {
        for change in changes where change.operation == .upsert {
            switch change.entityType {
            case .item:
                guard let payload = try? MyRAMSyncPayloadCoding.decodeNote(from: change.payload) else { continue }
                syncConflictStore.saveNoteTitleBaseline(
                    noteID: payload.id,
                    title: payload.title,
                    modifiedAt: payload.modifiedAt,
                    originDeviceID: change.originDeviceID
                )
                syncConflictStore.saveNoteContentBaseline(
                    noteID: payload.id,
                    content: payload.content,
                    richTextContentData: payload.richTextContentData,
                    modifiedAt: payload.modifiedAt,
                    originDeviceID: change.originDeviceID
                )

            case .marker:
                guard let payload = try? MyRAMSyncPayloadCoding.decodePinnedThought(from: change.payload) else { continue }
                syncConflictStore.savePinnedTextBaseline(
                    thoughtID: payload.id,
                    text: payload.text,
                    modifiedAt: payload.modifiedAt,
                    originDeviceID: change.originDeviceID
                )

            case .collection, .attachment, .conflict:
                continue
            }
        }
    }

    func applyIncomingSyncChanges(_ changes: [SyncChange]) async -> [LegacyIncomingChangeResult] {
        guard !changes.isEmpty else { return [] }
        let activeNoteID = currentNote?.id
        isApplyingRemoteSyncChange = true
        defer { isApplyingRemoteSyncChange = false }
        var dispositions: [LegacyIncomingChangeResult] = []

        for change in changes {
            guard !context.hasChanges else {
                dispositions.append(LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired))
                continue
            }

            if let boundaryOutcome = await finalizePendingLocalObligationForLegacyIncomingChangesIfNeeded(
                beforeIncomingBodyMutationFor: legacyIncomingBodyMutationNoteIDs(in: [change])
            ) {
                await handleConvergenceRuntimeOutcome(boundaryOutcome)
                dispositions.append(LegacyIncomingChangeResult(
                    changeID: change.id,
                    disposition: Self.legacyDisposition(forBoundaryOutcome: boundaryOutcome)
                ))
                continue
            }

            guard !context.hasChanges else {
                dispositions.append(LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired))
                continue
            }

            let applyResult: LegacyIncomingIsolatedApplyResult
            do {
                applyResult = try applyLegacyIncomingChangeInIsolatedContext(
                    change,
                    activeNoteID: activeNoteID,
                    currentNoteID: currentNote?.id,
                    currentFolderID: currentFolder?.id
                )
            } catch {
                dispositions.append(LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired))
                continue
            }

            do {
                try commitLegacyIncomingEffects(applyResult.bufferedEffects)
                try refreshMainContextAfterLegacyIncomingApply(change, noteSnapshot: applyResult.noteSnapshot)
            } catch {
                dispositions.append(LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired))
                continue
            }
            let committedSyncConflicts = syncConflictStore.activeConflicts()

            // Only after durable persistence succeeds do any observable side
            // effects fire: conflict publication, current note/folder state,
            // UserDefaults, folder refresh, and the editor reload.
            syncConflicts = committedSyncConflicts
            applyResult.preservedConflicts.forEach(recordSyncConflictPreserved)

            if applyResult.deletedCurrentNoteID != nil {
                currentNote = nil
                UserDefaults.standard.removeObject(forKey: "lastNoteID")
            }
            if let replacementFolderID = applyResult.currentFolderReplacementID {
                currentFolder = fetchFolder(withID: replacementFolderID)
            }

            refreshCurrentFolderContent()
            if applyResult.shouldRefreshActiveNote {
                publishActiveEditorReload(noteID: activeNoteID, reason: .unsupportedIntegratedChange)
            }
            dispositions.append(LegacyIncomingChangeResult(changeID: change.id, disposition: .applied))
        }
        return dispositions
    }

    private func applyLegacyIncomingChangeInIsolatedContext(
        _ change: SyncChange,
        activeNoteID: UUID?,
        currentNoteID: UUID?,
        currentFolderID: UUID?
    ) throws -> LegacyIncomingIsolatedApplyResult {
        let isolatedContext = ModelContext(context.container)
        try verifyLegacyIncomingPersistedRowsAreVisible(change, in: isolatedContext)
        try refreshIsolatedNoteFromMainContextIfNeeded(for: change, in: isolatedContext)
        let bufferedConflictStore = BufferedSyncConflictStore(base: syncConflictStore)
        let applier = MyRAMSyncChangeApplier(
            context: isolatedContext,
            conflictStore: bufferedConflictStore,
            isTextApplicationUnsafe: { [weak self] entityType, entityID, field in
                self?.isIncomingTextUnsafe(entityType: entityType, entityID: entityID, field: field) ?? false
            }
        )
        let result = applier.apply(
            [change],
            activeNoteID: activeNoteID,
            currentNoteID: currentNoteID,
            currentFolderID: currentFolderID
        )
        guard result.outcomes.first?.shouldAcknowledge == true else {
            isolatedContext.rollback()
            throw LegacyIncomingIsolatedApplyFailure.nonAcknowledgeableOutcome
        }
        var noteSnapshot = try legacyIncomingNoteSnapshot(for: change, in: isolatedContext)
        if let cleanBaseSnapshot = try cleanBaseLegacyIncomingNoteSnapshot(for: change),
           result.preservedConflicts.isEmpty {
            // Some SwiftData contexts keep a stale row after boundary admission.
            // When the clean main note exactly matches the incoming base, this is
            // the same apply decision the isolated applier would make from fresh state.
            noteSnapshot = cleanBaseSnapshot
            try applyLegacyIncomingNoteSnapshot(cleanBaseSnapshot, in: isolatedContext, savesContext: false)
            bufferedConflictStore.saveNoteTitleBaseline(
                noteID: cleanBaseSnapshot.id,
                title: cleanBaseSnapshot.title,
                modifiedAt: cleanBaseSnapshot.modifiedAt,
                originDeviceID: change.originDeviceID
            )
            bufferedConflictStore.saveNoteContentBaseline(
                noteID: cleanBaseSnapshot.id,
                content: cleanBaseSnapshot.content,
                richTextContentData: cleanBaseSnapshot.richTextContentData,
                modifiedAt: cleanBaseSnapshot.modifiedAt,
                originDeviceID: change.originDeviceID
            )
        }
        try saveLegacyIncomingApplyContext(isolatedContext)
        return LegacyIncomingIsolatedApplyResult(
            syncConflicts: applier.syncConflicts,
            preservedConflicts: result.preservedConflicts,
            bufferedEffects: bufferedConflictStore.effects,
            noteSnapshot: noteSnapshot,
            deletedCurrentNoteID: result.deletedCurrentNoteID,
            currentFolderReplacementID: result.currentFolderReplacementID,
            shouldRefreshActiveNote: result.shouldRefreshActiveNote
        )
    }

    private func verifyLegacyIncomingPersistedRowsAreVisible(_ change: SyncChange, in context: ModelContext) throws {
        switch change.entityType {
        case .collection:
            guard let payload = try? MyRAMSyncPayloadCoding.decodeFolder(from: change.payload) else { throw CocoaError(.fileReadCorruptFile) }
            let isolatedFolder = try fetchFolder(withID: payload.id, in: context)
            if change.operation == .delete {
                guard isolatedFolder != nil else { throw CocoaError(.fileNoSuchFile) }
            } else if try fetchFolder(withID: payload.id, in: self.context) != nil, isolatedFolder == nil {
                throw CocoaError(.fileNoSuchFile)
            }

        case .item:
            guard let payload = try? MyRAMSyncPayloadCoding.decodeNote(from: change.payload) else { throw CocoaError(.fileReadCorruptFile) }
            let isolatedNote = try fetchNote(withID: payload.id, in: context)
            if change.operation == .delete {
                guard isolatedNote != nil else { throw CocoaError(.fileNoSuchFile) }
            } else if try fetchNote(withID: payload.id, in: self.context) != nil, isolatedNote == nil {
                throw CocoaError(.fileNoSuchFile)
            }

        case .marker:
            guard let payload = try? MyRAMSyncPayloadCoding.decodePinnedThought(from: change.payload) else { throw CocoaError(.fileReadCorruptFile) }
            let isolatedThought = try fetchPinnedThought(withID: payload.id, in: context)
            if change.operation == .delete || payload.isDeleted {
                guard isolatedThought != nil else { throw CocoaError(.fileNoSuchFile) }
            } else if try fetchPinnedThought(withID: payload.id, in: self.context) != nil, isolatedThought == nil {
                throw CocoaError(.fileNoSuchFile)
            }
            if let noteID = payload.noteID {
                guard try fetchNote(withID: noteID, in: context) != nil else { throw CocoaError(.fileNoSuchFile) }
            }

        case .attachment:
            guard let payload = try? MyRAMSyncPayloadCoding.decodePhotoAttachment(from: change.payload) else { throw CocoaError(.fileReadCorruptFile) }
            let isolatedAttachment = try fetchPhotoAttachment(withID: payload.id, in: context)
            if change.operation == .delete || payload.isDeleted {
                guard isolatedAttachment != nil else { throw CocoaError(.fileNoSuchFile) }
            } else if try fetchPhotoAttachment(withID: payload.id, in: self.context) != nil, isolatedAttachment == nil {
                throw CocoaError(.fileNoSuchFile)
            } else if let noteID = payload.noteID {
                guard try fetchNote(withID: noteID, in: context) != nil else { throw CocoaError(.fileNoSuchFile) }
            }

        case .conflict:
            return
        }
    }

    private static func commitLegacyIncomingEffects(
        _ effects: LegacyIncomingBufferedEffects,
        to store: SyncConflictStore
    ) throws {
        try store.commitLegacyIncomingEffectsChecked(effects)
    }

    private func refreshMainContextAfterLegacyIncomingApply(
        _ change: SyncChange,
        noteSnapshot: LegacyIncomingNoteSnapshot?
    ) throws {
        if let noteSnapshot {
            try applyLegacyIncomingNoteSnapshot(noteSnapshot, in: context)
        }
        switch change.entityType {
        case .collection:
            if let payload = try? MyRAMSyncPayloadCoding.decodeFolder(from: change.payload) {
                _ = try fetchFolder(withID: payload.id, in: context)
                if let parentID = payload.parentFolderID {
                    _ = try fetchFolder(withID: parentID, in: context)
                }
            }
        case .item:
            break
        case .marker:
            if let payload = try? MyRAMSyncPayloadCoding.decodePinnedThought(from: change.payload) {
                _ = try fetchPinnedThought(withID: payload.id, in: context)
                if let noteID = payload.noteID {
                    _ = try fetchNote(withID: noteID, in: context)
                }
            }
        case .attachment:
            if let payload = try? MyRAMSyncPayloadCoding.decodePhotoAttachment(from: change.payload) {
                _ = try fetchPhotoAttachment(withID: payload.id, in: context)
                if let noteID = payload.noteID {
                    _ = try fetchNote(withID: noteID, in: context)
                }
            }
        case .conflict:
            if let payload = try? MyRAMSyncPayloadCoding.decodeSyncConflict(from: change.payload),
               let conflict = payload.conflict {
                switch conflict.entityType {
                case .note:
                    _ = try fetchNote(withID: conflict.entityID, in: context)
                case .folder:
                    _ = try fetchFolder(withID: conflict.entityID, in: context)
                case .pinnedThought:
                    _ = try fetchPinnedThought(withID: conflict.entityID, in: context)
                }
            }
        }
    }

    private func cleanBaseLegacyIncomingNoteSnapshot(for change: SyncChange) throws -> LegacyIncomingNoteSnapshot? {
        guard change.entityType == .item,
              let payload = try? MyRAMSyncPayloadCoding.decodeNote(from: change.payload),
              let mainNote = try fetchNote(withID: payload.id, in: context),
              mainNote.title == payload.baseTitle,
              mainNote.content == payload.baseContent,
              mainNote.richTextContentData == payload.baseRichTextContentData else {
            return nil
        }
        return LegacyIncomingNoteSnapshot(
            id: payload.id,
            title: payload.title,
            content: payload.content,
            richTextContentData: payload.richTextContentData,
            isPinned: payload.isPinned,
            createdAt: payload.createdAt,
            modifiedAt: payload.modifiedAt,
            deletedAt: payload.deletedAt,
            folderID: payload.folderID
        )
    }

    private func refreshIsolatedNoteFromMainContextIfNeeded(
        for change: SyncChange,
        in isolatedContext: ModelContext
    ) throws {
        guard change.entityType == .item,
              let payload = try? MyRAMSyncPayloadCoding.decodeNote(from: change.payload),
              let mainNote = try fetchNote(withID: payload.id, in: context),
              try fetchNote(withID: payload.id, in: isolatedContext) != nil else {
            return
        }
        isolatedContext.rollback()
        let snapshot = LegacyIncomingNoteSnapshot(
            id: mainNote.id,
            title: mainNote.title,
            content: mainNote.content,
            richTextContentData: mainNote.richTextContentData,
            isPinned: mainNote.isPinned,
            createdAt: mainNote.createdAt,
            modifiedAt: mainNote.modifiedAt,
            deletedAt: mainNote.deletedAt,
            folderID: mainNote.folder?.id
        )
        try applyLegacyIncomingNoteSnapshot(snapshot, in: isolatedContext, savesContext: false)
    }

    private func legacyIncomingNoteSnapshot(
        for change: SyncChange,
        in context: ModelContext
    ) throws -> LegacyIncomingNoteSnapshot? {
        let noteID: UUID?
        switch change.entityType {
        case .item:
            noteID = (try? MyRAMSyncPayloadCoding.decodeNote(from: change.payload))?.id
        case .conflict:
            guard let payload = try? MyRAMSyncPayloadCoding.decodeSyncConflict(
                from: change.payload
            ), payload.action == .resolved,
            payload.conflict?.field == .noteContent else {
                return nil
            }
            noteID = payload.conflict?.entityID
        case .collection, .marker, .attachment:
            noteID = nil
        }
        guard let noteID,
              let note = try fetchNote(withID: noteID, in: context) else {
            return nil
        }
        return LegacyIncomingNoteSnapshot(
            id: note.id,
            title: note.title,
            content: note.content,
            richTextContentData: note.richTextContentData,
            isPinned: note.isPinned,
            createdAt: note.createdAt,
            modifiedAt: note.modifiedAt,
            deletedAt: note.deletedAt,
            folderID: note.folder?.id
        )
    }

    private func applyLegacyIncomingNoteSnapshot(
        _ snapshot: LegacyIncomingNoteSnapshot,
        in context: ModelContext,
        savesContext: Bool = true
    ) throws {
        let folder = try snapshot.folderID.flatMap {
            try fetchFolder(withID: $0, in: context)
        }
        let existingNote = try fetchNote(withID: snapshot.id, in: context)
        let note: Note
        if let existingNote {
            note = existingNote
            _ = try NoteSequenceStateFullBodyIntegration.replaceBody(
                of: note,
                with: snapshot.content,
                in: context
            )
        } else {
            note = Note(
                title: snapshot.title,
                content: snapshot.content
            )
            note.id = snapshot.id
            let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
                noteID: snapshot.id,
                body: snapshot.content
            )
            _ = try NoteSequenceStateFullBodyIntegration.insertNewNote(
                note,
                preparedState: prepared,
                in: context
            )
        }
        note.title = snapshot.title
        note.richTextContentData = snapshot.richTextContentData
        note.isPinned = snapshot.isPinned
        note.createdAt = snapshot.createdAt
        note.modifiedAt = snapshot.modifiedAt
        note.deletedAt = snapshot.deletedAt
        note.folder = folder
        if savesContext, context.hasChanges {
            try context.save()
        }
    }

    private func fetchNote(withID noteID: UUID, in context: ModelContext) throws -> Note? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == noteID
            }
        )
        return try context.fetch(descriptor).first
    }

    private func fetchFolder(withID folderID: UUID, in context: ModelContext) throws -> Folder? {
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { folder in
                folder.id == folderID
            }
        )
        return try context.fetch(descriptor).first
    }

    private func fetchPinnedThought(withID thoughtID: UUID, in context: ModelContext) throws -> PinnedThought? {
        let descriptor = FetchDescriptor<PinnedThought>(
            predicate: #Predicate { thought in
                thought.id == thoughtID
            }
        )
        return try context.fetch(descriptor).first
    }

    private func fetchPhotoAttachment(withID attachmentID: UUID, in context: ModelContext) throws -> NotePhotoAttachment? {
        let descriptor = FetchDescriptor<NotePhotoAttachment>(
            predicate: #Predicate { attachment in
                attachment.id == attachmentID
            }
        )
        return try context.fetch(descriptor).first
    }

    func applyIncomingSyncBatch(_ batch: SyncBatch) async -> SyncConvergenceRemoteBatchDisposition {
        guard (try? SyncBatchAnchoredPayloadPolicy.validateInbound(batch)) != nil else {
            return .acknowledgementPermitted
        }
        guard !batch.changes.isEmpty else { return .acknowledgementPermitted }
        let outcome = await syncConvergenceRuntime.submitRemoteBatch(batch)
        await handleConvergenceRuntimeOutcome(outcome)
        return SyncConvergenceRemoteBatchDispositionPolicy.disposition(
            for: outcome,
            batchID: batch.id
        )
    }

    /// Durably persists an incoming batch's raw bytes, independent of whatever
    /// `applyIncomingSyncBatch` later does with them. Capture occurs before
    /// convergence and is necessary but not sufficient for acknowledgement: the
    /// convergence disposition controls whether acknowledgement is permitted.
    /// Deferred or rejected work can therefore leave the sender's durable copy
    /// available for later redelivery.
    func durablyCaptureIncomingBatch(_ batch: SyncBatch) -> Bool {
        guard (try? SyncBatchAnchoredPayloadPolicy.validateInbound(batch)) != nil else {
            return false
        }
        guard !batch.changes.isEmpty else { return true }
        if pendingIncomingBatches.contains(batch.id) { return true }
        do {
            try pendingIncomingBatches.enqueueIncoming(batch)
            return true
        } catch {
            return false
        }
    }

    func localConvergenceQueueSnapshot() -> FileBackedSyncBatchQueueSnapshot {
        pendingLocalConvergenceBatches.snapshot()
    }

    var hasMountedActiveEditor: Bool {
        mountedActiveEditorNoteID != nil
    }

    func replaceLocalConvergenceBatches(_ batches: [SyncBatch]) async throws {
        try batches.forEach(SyncBatchAnchoredPayloadPolicy.validateRecovery)
        try pendingLocalConvergenceBatches.replacePendingBatches(batches)
        await refreshPendingSyncStatusForLocalConvergenceMutation?()
    }

    func capturePendingLocalBatchForRecovery() async -> SyncBatchID? {
        guard let obligation = await syncBatchAccumulator.takePendingBatchNow() else {
            await resumePendingConvergencePresentation()
            return nil
        }
        let outcome = await syncConvergenceRuntime.submitLocalObligation(obligation)
        await handleConvergenceRuntimeOutcome(outcome)
        await resumePendingConvergencePresentation()
        return obligation.id
    }

    func resetPendingSync(
        syncController: MyRAMSyncController,
        prepareEditorState: @escaping () throws -> Void
    ) async {
        guard !pendingSyncRecoveryStatus.isRunning else { return }
        pendingSyncRecoveryStatus = .running
        let coordinator = PendingSyncRecoveryCoordinator(
            queueAdmin: syncController,
            localQueueSnapshot: { [weak self] in
                self?.localConvergenceQueueSnapshot()
                    ?? FileBackedSyncBatchQueueSnapshot(pendingBatches: [], health: .fileMissing)
            },
            replaceLocalBatches: { [weak self] batches in
                try await self?.replaceLocalConvergenceBatches(batches)
            },
            flushReadyLocalBatch: { [weak self] in
                await self?.capturePendingLocalBatchForRecovery()
            }
        )

        do {
            try await coordinator.resetPendingSync(
                prepareDurableState: {
                    try prepareEditorState()
                    try context.save()
                },
                buildReplacement: { legacy, unsent, local, recoveryTimestamp in
                    try SyncRecoveryStateBuilder.build(
                        context: context,
                        conflictStore: syncConflictStore,
                        legacySnapshot: legacy,
                        unsentBatches: unsent,
                        localConvergenceBatches: local,
                        currentDeviceID: syncController.currentDeviceID,
                        recoveryTimestamp: recoveryTimestamp
                    )
                }
            )
            pendingSyncRecoveryStatus = .succeeded
        } catch {
            pendingSyncRecoveryStatus = .failed(Self.recoveryMessage(for: error))
        }
    }

    func rollbackIfNeededOnLaunch(syncController: MyRAMSyncController) async throws {
        let coordinator = PendingSyncRecoveryCoordinator(
            queueAdmin: syncController,
            localQueueSnapshot: { [weak self] in
                self?.localConvergenceQueueSnapshot()
                    ?? FileBackedSyncBatchQueueSnapshot(pendingBatches: [], health: .fileMissing)
            },
            replaceLocalBatches: { [weak self] batches in
                try await self?.replaceLocalConvergenceBatches(batches)
            },
            flushReadyLocalBatch: { nil }
        )
        try await coordinator.rollbackIfNeededOnLaunch()
    }

    private static func recoveryMessage(for error: Error) -> String {
        switch error {
        case PendingSyncRecoveryCoordinator.RecoveryError.unhealthyLegacyQueue:
            return "Reset is blocked because the legacy pending queue is unreadable."
        case PendingSyncRecoveryCoordinator.RecoveryError.unhealthyUnsentBatchQueue:
            return "Reset is blocked because the unsent batch queue is unreadable."
        case PendingSyncRecoveryCoordinator.RecoveryError.unhealthyLocalObligationQueue:
            return "Reset is blocked because the pending local batch queue is unreadable."
        case SyncRecoveryStateBuilderError.activeConflict:
            return "Resolve the active sync conflict before resetting pending sync."
        case SyncRecoveryStateBuilderError.unsupportedPendingLegacyConflictMetadata:
            return "Resolve the active sync conflict before resetting pending sync."
        case SyncRecoveryStateBuilderError.missingCurrentNoteReferencedByUnsentBatch,
             SyncRecoveryStateBuilderError.missingCurrentNoteReferencedByLocalObligation,
             SyncRecoveryStateBuilderError.missingCurrentEntity,
             SyncRecoveryStateBuilderError.invalidLegacyEntityID,
             SyncRecoveryStateBuilderError.targetCoverageMismatch:
            return "Reset is blocked because some queued sync work cannot be safely represented."
        case PendingSyncRecoveryCoordinator.RecoveryError.capturedBatchNotDurable:
            return "Reset is blocked because the latest edit was not saved into the pending sync queue."
        case PendingSyncRecoveryCoordinator.RecoveryError.rollbackFailed:
            return "Reset failed and rollback could not finish. Restart MyRAM before syncing again."
        default:
            return "Reset Pending Sync failed without changing local notes."
        }
    }

    private func handleReadyLocalBatch(_ obligation: SyncConvergenceLocalObligation) async {
        let outcome = await syncConvergenceRuntime.submitLocalObligation(obligation)
        await handleConvergenceRuntimeOutcome(outcome)
    }

    func resumePendingConvergencePresentationIfNeeded() {
        guard pendingConvergenceResumeTask == nil else { return }
        pendingConvergenceResumeTask = Task { [weak self] in
            await self?.resumePendingConvergencePresentation()
            await MainActor.run {
                self?.pendingConvergenceResumeTask = nil
            }
        }
    }

    private func resumePendingConvergencePresentation() async {
        let outcome = await syncConvergenceRuntime.resumePendingWork()
        await handleConvergenceRuntimeOutcome(outcome)
    }

    private func handleConvergenceRuntimeOutcome(_ outcome: SyncConvergenceRuntimeOutcome) async {
        switch outcome {
        case .drained:
            syncBatchErrorMessage = nil
        case .pending:
            break
        case .deferred(let deferred):
            if let message = Self.syncErrorMessage(for: deferred) {
                syncBatchErrorMessage = message
            }
        case .quarantined:
            syncBatchErrorMessage = "Pending local sync evidence needs recovery before this note can continue syncing."
        case .alreadyDraining:
            break
        case .blocked(let failure):
            syncBatchErrorMessage = SyncBatchDrainFailureClassifier.userMessage(for: failure)
        }
        await refreshPendingSyncStatusForLocalConvergenceMutation?()
    }

    static func syncErrorMessage(for deferred: SyncConvergenceDeferredWork) -> String? {
        let items = deferred.incoming + deferred.localObligations + deferred.postCommit
        for item in items {
            switch item.reason {
            case .planning(let reason):
                switch reason {
            case .anchorlessMatchingBaseEvidenceUnavailable:
                return SyncBatchDrainFailureClassifier.userMessage(
                    for: SyncBatchDrainFailure(batchID: item.batchID, kind: .anchorlessBaseUnavailable)
                )
            case .unreconstructableBase:
                return SyncBatchDrainFailureClassifier.userMessage(
                    for: SyncBatchDrainFailure(batchID: item.batchID, kind: .mismatchedBase)
                )
            case .unsupportedReconciliation, .historyPressure:
                continue
                }
            case .legacyLocalEvidenceStale, .transportUnavailable, .postCommitPending:
                continue
            }
        }
        return nil
    }

    func acknowledgeActiveEditorSyncUpdate(
        id updateID: UUID,
        noteID: UUID,
        result: SyncConvergencePostCommitAdapterResult
    ) {
        guard let acknowledgment = activeEditorPresentationAcknowledgment,
              acknowledgment.updateID == updateID,
              acknowledgment.noteID == noteID else { return }
        activeEditorPresentationAcknowledgment = nil
        if activeEditorSyncUpdate?.id == updateID,
           activeEditorSyncUpdate?.noteID == noteID {
            activeEditorSyncUpdate = nil
        }
        acknowledgment.complete(result)
    }

    func registerActiveEditor(noteID: UUID) {
        mountedActiveEditorNoteID = noteID
        resumePendingConvergencePresentationIfNeeded()
    }

    func unregisterActiveEditor(noteID: UUID) {
        guard mountedActiveEditorNoteID == noteID else { return }
        mountedActiveEditorNoteID = nil
        let result: SyncConvergencePostCommitAdapterResult = currentNote?.id == noteID ? .stillPending : .verifiedComplete
        resolveActiveEditorPresentation(noteID: noteID, result: result)
    }

    private func resolveActiveEditorPresentation(
        noteID: UUID,
        result: SyncConvergencePostCommitAdapterResult
    ) {
        guard let acknowledgment = activeEditorPresentationAcknowledgment,
              acknowledgment.noteID == noteID else { return }
        acknowledgeActiveEditorSyncUpdate(id: acknowledgment.updateID, noteID: noteID, result: result)
    }

    func publishConvergencePresentationUpdate(
        _ update: ActiveEditorSyncUpdate,
        incorporationIdentity: SyncConvergencePersistedIncorporationIdentity
    ) async -> SyncConvergencePostCommitAdapterResult {
        guard currentNote?.id == update.noteID else { return .verifiedComplete }
        guard mountedActiveEditorNoteID == update.noteID else { return .verifiedComplete }
        if activeEditorPresentationAcknowledgment != nil {
            return .stillPending
        }

        return await withCheckedContinuation { continuation in
            activeEditorPresentationAcknowledgment = ActiveEditorPresentationAcknowledgment(
                updateID: update.id,
                noteID: update.noteID,
                incorporationIdentity: incorporationIdentity,
                continuation: continuation
            )
            activeEditorSyncUpdate = update
        }
    }

    fileprivate func noteProjection(id noteID: UUID) -> SyncConvergenceProjectedNote? {
        refreshedNote(withID: noteID).map {
            SyncConvergenceProjectedNote(
                noteID: $0.id,
                folderID: $0.folder?.id,
                title: $0.title,
                body: $0.content,
                createdAt: $0.createdAt,
                modifiedAt: $0.modifiedAt
            )
        }
    }

    private func publishActiveEditorReload(noteID: UUID?, reason: ActiveEditorReloadReason) {
        guard let noteID,
              currentNote?.id == noteID else { return }
        activeEditorSyncUpdate = ActiveEditorSyncUpdate(
            noteID: noteID,
            disposition: .reload(reason)
        )
    }

    nonisolated private static func pendingIncomingBatchQueueFileURL() -> URL? {
        SyncBatchQueueFileLocation.pendingIncoming(for: .iPhone)
    }

    nonisolated private static func pendingLocalConvergenceBatchQueueFileURL() -> URL? {
        SyncBatchQueueFileLocation.pendingLocalConvergence(for: .iPhone)
    }

    private func isIncomingTextUnsafe(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> Bool {
        guard let activeNoteID = currentNote?.id else { return false }
        let affectedNoteID: UUID?
        switch (entityType, field) {
        case (.note, .noteTitle), (.note, .noteContent):
            affectedNoteID = entityID
        case (.pinnedThought, .pinnedText):
            affectedNoteID = fetchPinnedThought(withID: entityID)?.note?.id
        case (.folder, .folderTitle):
            affectedNoteID = nil
        default:
            affectedNoteID = nil
        }
        guard affectedNoteID == activeNoteID else { return false }
        guard let lastEditAt = recentTextEditByNoteID[activeNoteID] else { return false }
        return Date().timeIntervalSince(lastEditAt) < Self.syncTextQuietPeriod
    }

    private func removeUndoHistoryReferencingDeletedNote(noteID: UUID) {
        undoStack.removeAll { action in
            switch action {
            case .noteCreation(let snapshot):
                return snapshot.noteID == noteID
            case .folderCreation:
                return false
            case .noteMove(let snapshot):
                return snapshot.noteID == noteID
            case .noteDeletion(let snapshot):
                return snapshot.noteID == noteID
            case .folderDeletion(let snapshot):
                return snapshot.noteMoves.contains { $0.noteID == noteID }
            }
        }
        redoStack.removeAll { action in
            switch action {
            case .noteCreation(let snapshot):
                return snapshot.noteID == noteID
            case .folderCreation:
                return false
            case .noteMove(let snapshot):
                return snapshot.noteID == noteID
            case .noteDeletion(let snapshot):
                return snapshot.noteID == noteID
            case .folderDeletion(let snapshot):
                return snapshot.noteMoves.contains { $0.noteID == noteID }
            }
        }
    }

    private func isDescendantOrSame(_ folder: Folder, of ancestor: Folder) -> Bool {
        var cursor: Folder? = folder
        while let current = cursor {
            if current.id == ancestor.id {
                return true
            }
            cursor = current.parentFolder
        }
        return false
    }

    private func allFoldersInSubtree(of rootFolder: Folder) -> [Folder] {
        var result: [Folder] = []
        var queue: [Folder] = [rootFolder]

        while let next = queue.first {
            queue.removeFirst()
            result.append(next)
            queue.append(contentsOf: next.childFolders)
        }

        return result
    }

    private func purgeExpiredDeletedNotes() {
        let cutoff = Date().addingTimeInterval(-Self.recentlyDeletedRetention)
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt != nil })
        let deletedNotes = (try? context.fetch(descriptor)) ?? []

        for note in deletedNotes {
            if let deletedAt = note.deletedAt, deletedAt < cutoff {
                context.delete(note)
            }
        }

        try? context.save()
    }

    func exportNotesForSharing(
        _ notesToExport: [Note],
        nowProvider: () -> Date = Date.init
    ) throws -> [URL] {
        let nonDeletedNotes = notesToExport.filter { $0.deletedAt == nil }
        guard !nonDeletedNotes.isEmpty else {
            throw NoteExportError.noNotesSelected
        }

        let exportTime = nowProvider()
        return try Self.writeStructuredExportJSON(notes: nonDeletedNotes, exportedAt: exportTime)
    }

    @discardableResult
    func importNotes(from exportURL: URL) throws -> [Note] {
        let didStartAccessing = exportURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                exportURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: exportURL)
        let manifest: ExportManifest
        do {
            manifest = try JSONDecoder().decode(ExportManifest.self, from: data)
        } catch {
            throw NoteImportError.invalidFile
        }

        guard manifest.format == "myram-note-export", manifest.version == 1 else {
            throw NoteImportError.unsupportedFormat
        }

        let importedNotes: [Note]
        do {
            importedNotes = try manifest.notes.compactMap { try importNote(from: $0) }
            guard !importedNotes.isEmpty else {
                throw NoteImportError.noImportableNotes
            }
            try saveContext()
        } catch {
            context.rollback()
            throw error
        }
        refreshCurrentFolderContent()
        selectNote(importedNotes[0])
        return importedNotes
    }

    nonisolated static func buildNoteExportText(
        for note: Note,
        exportedAt: Date = Date(),
        dateFormatter: (Date) -> String = NotesViewModel.defaultDateFormatter
    ) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled"
            : note.title
        let body = note.content.isEmpty ? "(No content)" : note.content
        let pinnedThoughts = note.pinnedThoughts
            .sorted {
                if $0.order != $1.order {
                    return $0.order < $1.order
                }
                return $0.createdAt < $1.createdAt
            }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let pinnedThoughtLines = pinnedThoughts.isEmpty
            ? ["Pinned:", "(None)"]
            : ["Pinned:"] + pinnedThoughts.map { "- \($0)" }

        let exportLines: [String] = [
            "MyRAM Notes Export",
            "Exported: \(dateFormatter(exportedAt))",
            "",
            "Title: \(title)",
            "Created: \(dateFormatter(note.createdAt))",
            "Modified: \(dateFormatter(note.modifiedAt))",
            ""
        ] + pinnedThoughtLines + [
            "",
            "Body:",
            body,
            ""
        ]
        return exportLines.joined(separator: "\n")
    }

    nonisolated static func makeExportFilename(notes: [Note], now: Date) -> String {
        let timestamp = makeExportTimestamp(now)
        if notes.count == 1, let note = notes.first {
            let stem = makeSafeFileStem(from: note.title, fallback: "Note")
            return "MyRAM-\(stem)-\(timestamp).myram"
        }
        return "MyRAM-Notes-\(timestamp).myram"
    }

    nonisolated private static func writeStructuredExportJSON(
        notes: [Note],
        exportedAt: Date
    ) throws -> [URL] {
        let exportRoot = try makeExportDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        var manifestNotes: [ExportManifestNote] = []
        var attachmentURLs: [URL] = []
        var usedAttachmentFilenames: Set<String> = []
        var textURLs: [URL] = []
        var usedTextFilenames: Set<String> = []

        for (index, note) in notes.enumerated() {
            let sortedAttachments = note.photoAttachments.sorted { $0.createdAt < $1.createdAt }
            var manifestAttachments: [ExportManifestAttachment] = []
            let textBaseName = makeSafeFileStem(from: note.title, fallback: "Note-\(index + 1)")
            let textFilename = "\(uniqueFilename(baseName: textBaseName, used: &usedTextFilenames)).txt"
            let textURL = exportRoot.appendingPathComponent(textFilename)
            let noteText = buildNoteExportText(for: note, exportedAt: exportedAt)
            guard let noteTextData = noteText.data(using: .utf8) else {
                throw NoteExportError.failedToEncodeText
            }
            try noteTextData.write(to: textURL, options: .atomic)
            textURLs.append(textURL)

            for attachment in sortedAttachments {
                let mimeType = inferredMimeType(for: attachment.imageData)
                let fileExtension = inferredImageFileExtension(for: attachment.imageData)
                let baseName = "\(note.id.uuidString)-\(attachment.id.uuidString)"
                let uniqueFileStem = uniqueFilename(baseName: baseName, used: &usedAttachmentFilenames)
                let filename = "\(uniqueFileStem).\(fileExtension)"
                let attachmentURL = exportRoot.appendingPathComponent(filename)
                try attachment.imageData.write(to: attachmentURL, options: .atomic)
                attachmentURLs.append(attachmentURL)

                manifestAttachments.append(
                    ExportManifestAttachment(
                        id: attachment.id.uuidString,
                        createdAt: iso8601Timestamp(from: attachment.createdAt),
                        mimeType: mimeType,
                        filename: filename,
                        data: attachment.imageData.base64EncodedString()
                    )
                )
            }

            manifestNotes.append(
                ExportManifestNote(
                    id: note.id.uuidString,
                    title: note.title,
                    content: note.content,
                    pinnedThoughts: sortedPinnedThoughtExportItems(for: note),
                    createdAt: iso8601Timestamp(from: note.createdAt),
                    modifiedAt: iso8601Timestamp(from: note.modifiedAt),
                    deletedAt: note.deletedAt.map(iso8601Timestamp(from:)),
                    folderPath: folderPathSegments(for: note.folder),
                    attachments: manifestAttachments
                )
            )
        }

        let manifest = ExportManifest(
            format: "myram-note-export",
            version: 1,
            exportedAt: iso8601Timestamp(from: exportedAt),
            notes: manifestNotes
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let manifestData = try? encoder.encode(manifest) else {
            throw NoteExportError.failedToEncodeManifest
        }

        let exportFilename = makeExportFilename(notes: notes, now: exportedAt)
        let exportURL = exportRoot.appendingPathComponent(exportFilename)
        if fileManager.fileExists(atPath: exportURL.path) {
            try fileManager.removeItem(at: exportURL)
        }
        try manifestData.write(to: exportURL, options: .atomic)
        return [exportURL]
            + textURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
            + attachmentURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated private static func sortedPinnedThoughtExportItems(for note: Note) -> [ExportManifestPinnedThought] {
        note.pinnedThoughts
            .sorted {
                if $0.order != $1.order {
                    return $0.order < $1.order
                }
                return $0.createdAt < $1.createdAt
            }
            .map {
                ExportManifestPinnedThought(
                    id: $0.id.uuidString,
                    text: $0.text,
                    order: $0.order,
                    isCollapsed: $0.isCollapsed,
                    createdAt: iso8601Timestamp(from: $0.createdAt),
                    modifiedAt: iso8601Timestamp(from: $0.modifiedAt)
                )
            }
    }

    private func importNote(from noteRecord: ExportManifestNote) throws -> Note? {
        if noteRecord.deletedAt != nil {
            return nil
        }

        let folder = folder(forPath: noteRecord.folderPath)
        let note = Note(title: noteRecord.title, content: noteRecord.content)
        note.createdAt = Self.date(from: noteRecord.createdAt) ?? .now
        note.modifiedAt = Self.date(from: noteRecord.modifiedAt) ?? .now
        let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: note.id,
            body: note.content
        )
        _ = try NoteSequenceStateFullBodyIntegration.insertNewNote(
            note,
            preparedState: prepared,
            in: context
        )
        note.folder = folder

        let pinnedThoughts = noteRecord.pinnedThoughts.sorted {
            if $0.order != $1.order {
                return $0.order < $1.order
            }
            return $0.createdAt < $1.createdAt
        }

        for thoughtRecord in pinnedThoughts {
            let thought = PinnedThought(
                text: thoughtRecord.text,
                order: thoughtRecord.order,
                note: note
            )
            thought.isCollapsed = thoughtRecord.isCollapsed
            thought.createdAt = Self.date(from: thoughtRecord.createdAt) ?? note.createdAt
            thought.modifiedAt = Self.date(from: thoughtRecord.modifiedAt) ?? note.modifiedAt
            context.insert(thought)
            note.pinnedThoughts.append(thought)
        }

        for attachmentRecord in noteRecord.attachments {
            guard let imageData = Data(base64Encoded: attachmentRecord.data) else { continue }
            let attachment = NotePhotoAttachment(imageData: imageData, note: note)
            attachment.createdAt = Self.date(from: attachmentRecord.createdAt) ?? note.createdAt
            context.insert(attachment)
            note.photoAttachments.append(attachment)
        }

        folder?.modifiedAt = .now
        return note
    }

    private func folder(forPath path: [String]) -> Folder? {
        var parent: Folder?

        for rawSegment in path {
            let name = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            if let existingFolder = fetchFolders().first(where: { folder in
                folder.name == name && folder.parentFolder?.id == parent?.id
            }) {
                parent = existingFolder
                continue
            }

            let folder = Folder(name: name, parentFolder: parent)
            context.insert(folder)
            folders.append(folder)
            parent = folder
        }

        return parent
    }

    private func fetchFolders() -> [Folder] {
        let descriptor = FetchDescriptor<Folder>()
        return (try? context.fetch(descriptor)) ?? []
    }

    nonisolated private static func writeSingleNoteExport(note: Note, exportedAt: Date) throws -> URL {
        let exportText = buildNoteExportText(for: note, exportedAt: exportedAt)
        guard let utf8Data = exportText.data(using: .utf8) else {
            throw NoteExportError.failedToEncodeText
        }

        let exportDirectory = try makeExportDirectory()
        let filename = "\(makeSafeFileStem(from: note.title, fallback: "Note"))-\(makeExportTimestamp(exportedAt)).txt"
        let exportURL = exportDirectory.appendingPathComponent(filename)
        try utf8Data.write(to: exportURL, options: .atomic)
        return exportURL
    }

    nonisolated private static func writeMultipleNoteExportArchive(notes: [Note], exportedAt: Date) throws -> URL {
        let exportRoot = try makeExportDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesDirectory = exportRoot.appendingPathComponent("Notes", isDirectory: true)
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

        var usedFilenames: Set<String> = []
        for (index, note) in notes.enumerated() {
            let baseName = makeSafeFileStem(from: note.title, fallback: "Note-\(index + 1)")
            let uniqueName = uniqueFilename(baseName: baseName, used: &usedFilenames)
            let noteText = buildNoteExportText(for: note, exportedAt: exportedAt)

            guard let utf8Data = noteText.data(using: .utf8) else {
                throw NoteExportError.failedToEncodeText
            }

            let fileURL = notesDirectory.appendingPathComponent("\(uniqueName).txt")
            try utf8Data.write(to: fileURL, options: .atomic)
        }

        let zipFilename = "MyRAM-Notes-\(makeExportTimestamp(exportedAt)).zip"
        let zipURL = exportRoot.appendingPathComponent(zipFilename)
        if fileManager.fileExists(atPath: zipURL.path) {
            try fileManager.removeItem(at: zipURL)
        }
        let filesToArchive = try fileManager.contentsOfDirectory(
            at: notesDirectory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        let archiveEntries: [(name: String, data: Data)] = try filesToArchive.map { url in
            let fileData = try Data(contentsOf: url)
            return ("Notes/\(url.lastPathComponent)", fileData)
        }

        try writeZipArchive(entries: archiveEntries, to: zipURL)
        return zipURL
    }

    nonisolated private static func makeExportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyRAMExports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    nonisolated private static func makeExportTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    nonisolated private static func makeSafeFileStem(from rawTitle: String, fallback: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(40)
        let safe = String(mapped).trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? fallback : safe
    }

    nonisolated private static func folderPathSegments(for folder: Folder?) -> [String] {
        var segments: [String] = []
        var cursor = folder
        while let current = cursor {
            segments.append(current.name)
            cursor = current.parentFolder
        }
        return segments.reversed()
    }

    nonisolated private static func inferredMimeType(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3,
           bytes[0] == 0xFF,
           bytes[1] == 0xD8,
           bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 8,
           bytes[0] == 0x89,
           bytes[1] == 0x50,
           bytes[2] == 0x4E,
           bytes[3] == 0x47,
           bytes[4] == 0x0D,
           bytes[5] == 0x0A,
           bytes[6] == 0x1A,
           bytes[7] == 0x0A {
            return "image/png"
        }
        if bytes.count >= 6,
           bytes[0] == 0x47,
           bytes[1] == 0x49,
           bytes[2] == 0x46,
           bytes[3] == 0x38 {
            return "image/gif"
        }
        if bytes.count >= 12,
           bytes[0] == 0x52,
           bytes[1] == 0x49,
           bytes[2] == 0x46,
           bytes[3] == 0x46,
           bytes[8] == 0x57,
           bytes[9] == 0x45,
           bytes[10] == 0x42,
           bytes[11] == 0x50 {
            return "image/webp"
        }
        if bytes.count >= 12,
           bytes[4] == 0x66,
           bytes[5] == 0x74,
           bytes[6] == 0x79,
           bytes[7] == 0x70 {
            return "image/heic"
        }
        return "application/octet-stream"
    }

    nonisolated private static func inferredImageFileExtension(for data: Data) -> String {
        let mimeType = inferredMimeType(for: data)
        switch mimeType {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/heic":
            return "heic"
        default:
            return "bin"
        }
    }

    nonisolated private static func iso8601Timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated private static func date(from timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp)
    }

    nonisolated private static func uniqueFilename(baseName: String, used: inout Set<String>) -> String {
        if !used.contains(baseName) {
            used.insert(baseName)
            return baseName
        }

        var index = 2
        while used.contains("\(baseName)-\(index)") {
            index += 1
        }
        let unique = "\(baseName)-\(index)"
        used.insert(unique)
        return unique
    }

    nonisolated private static func writeZipArchive(
        entries: [(name: String, data: Data)],
        to url: URL
    ) throws {
        var archiveData = Data()
        var centralDirectoryData = Data()

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            guard nameData.count <= Int(UInt16.max),
                  entry.data.count <= Int(UInt32.max),
                  archiveData.count <= Int(UInt32.max) else {
                throw NoteExportError.failedToCreateArchive
            }

            let crc32 = crc32(for: entry.data)
            let fileSize = UInt32(entry.data.count)
            let localHeaderOffset = UInt32(archiveData.count)

            appendUInt32(0x04034B50, to: &archiveData)
            appendUInt16(20, to: &archiveData)
            appendUInt16(0, to: &archiveData)
            appendUInt16(0, to: &archiveData)
            appendUInt16(0, to: &archiveData)
            appendUInt16(0, to: &archiveData)
            appendUInt32(crc32, to: &archiveData)
            appendUInt32(fileSize, to: &archiveData)
            appendUInt32(fileSize, to: &archiveData)
            appendUInt16(UInt16(nameData.count), to: &archiveData)
            appendUInt16(0, to: &archiveData)
            archiveData.append(nameData)
            archiveData.append(entry.data)

            appendUInt32(0x02014B50, to: &centralDirectoryData)
            appendUInt16(20, to: &centralDirectoryData)
            appendUInt16(20, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt32(crc32, to: &centralDirectoryData)
            appendUInt32(fileSize, to: &centralDirectoryData)
            appendUInt32(fileSize, to: &centralDirectoryData)
            appendUInt16(UInt16(nameData.count), to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt32(0, to: &centralDirectoryData)
            appendUInt32(localHeaderOffset, to: &centralDirectoryData)
            centralDirectoryData.append(nameData)
        }

        guard archiveData.count <= Int(UInt32.max),
              centralDirectoryData.count <= Int(UInt32.max),
              entries.count <= Int(UInt16.max) else {
            throw NoteExportError.failedToCreateArchive
        }

        let centralDirectoryOffset = UInt32(archiveData.count)
        let centralDirectorySize = UInt32(centralDirectoryData.count)
        let entryCount = UInt16(entries.count)
        archiveData.append(centralDirectoryData)

        appendUInt32(0x06054B50, to: &archiveData)
        appendUInt16(0, to: &archiveData)
        appendUInt16(0, to: &archiveData)
        appendUInt16(entryCount, to: &archiveData)
        appendUInt16(entryCount, to: &archiveData)
        appendUInt32(centralDirectorySize, to: &archiveData)
        appendUInt32(centralDirectoryOffset, to: &archiveData)
        appendUInt16(0, to: &archiveData)

        try archiveData.write(to: url, options: .atomic)
    }

    nonisolated private static func crc32(for data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crc32LookupTable[index]
        }
        return crc ^ 0xFFFF_FFFF
    }

    nonisolated private static let crc32LookupTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if (crc & 1) == 1 {
                crc = (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    nonisolated private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    nonisolated private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    nonisolated static func defaultDateFormatter(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension NotesViewModel: SyncConvergenceIncomingLocalBoundaryAdapter {
    private static func legacyDisposition(
        forBoundaryOutcome outcome: SyncConvergenceRuntimeOutcome
    ) -> LegacyIncomingCandidateDisposition {
        if case .quarantined = outcome {
            return .quarantined
        }
        return .retryRequired
    }

    private func finalizePendingLocalObligationForLegacyIncomingChangesIfNeeded(
        beforeIncomingBodyMutationFor noteIDs: Set<UUID>
    ) async -> SyncConvergenceRuntimeOutcome? {
        let queuedOutcome = await syncConvergenceRuntime.admitQueuedLocalObligationsForIncomingMutation(affecting: noteIDs)
        if case .cannotProceed(let outcome) = queuedOutcome {
            return outcome
        }

        for noteID in noteIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard await syncBatchAccumulator.containsPendingBodyChange(for: noteID) else { continue }
            guard let obligation = await syncBatchAccumulator.takePendingObligationIfAffecting(noteID: noteID) else {
                return nil
            }
            let outcome = await syncConvergenceRuntime.admitPendingLocalObligationForIncomingMutation(obligation)
            switch outcome {
            case .ready, .evidenceRegistered:
                continue
            case .cannotProceed(let outcome):
                return outcome
            }
        }
        return nil
    }

    func prepareForIncomingBodyMutation(
        affecting noteIDs: Set<UUID>
    ) async -> SyncConvergenceIncomingLocalBoundaryPreparation {
        for noteID in noteIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard await syncBatchAccumulator.containsPendingBodyChange(for: noteID) else { continue }
            guard let obligation = await syncBatchAccumulator.takePendingObligationIfAffecting(noteID: noteID) else {
                return .failed(.boundaryInvariantViolation(noteID: noteID))
            }
            return .localObligation(obligation)
        }
        return .ready
    }
}

private extension ModelContext {
    func hasPendingChanges(for modelType: Note.Type, id: UUID) -> Bool {
        hasPendingModelChange { (note: Note) in note.id == id }
    }

    func hasPendingChanges(for modelType: Folder.Type, id: UUID) -> Bool {
        hasPendingModelChange { (folder: Folder) in folder.id == id }
    }

    func hasPendingChanges(for modelType: PinnedThought.Type, id: UUID) -> Bool {
        hasPendingModelChange { (thought: PinnedThought) in thought.id == id }
    }

    func hasPendingChanges(for modelType: NotePhotoAttachment.Type, id: UUID) -> Bool {
        hasPendingModelChange { (attachment: NotePhotoAttachment) in attachment.id == id }
    }

    private func hasPendingModelChange<T: PersistentModel>(_ matches: (T) -> Bool) -> Bool {
        (insertedModelsArray + changedModelsArray + deletedModelsArray).contains {
            guard let model = $0 as? T else { return false }
            return matches(model)
        }
    }
}

private struct ActiveEditorPresentationAcknowledgment {
    let updateID: UUID
    let noteID: UUID
    let incorporationIdentity: SyncConvergencePersistedIncorporationIdentity
    let continuation: CheckedContinuation<SyncConvergencePostCommitAdapterResult, Never>

    func complete(_ result: SyncConvergencePostCommitAdapterResult) {
        continuation.resume(returning: result)
    }
}

enum PinnedThoughtMoveDirection {
    case up
    case down
}

private enum UndoAction {
    case noteCreation(NoteCreationUndoSnapshot)
    case folderCreation(FolderCreationUndoSnapshot)
    case noteMove(NoteMoveUndoSnapshot)
    case noteDeletion(NoteDeletionUndoSnapshot)
    case folderDeletion(FolderDeletionUndoSnapshot)
}

private struct NoteCreationUndoSnapshot {
    let noteID: UUID
    let folderID: UUID?
}

private struct FolderCreationUndoSnapshot {
    let folderID: UUID
    let name: String
    let createdAt: Date
    let modifiedAt: Date
    let parentFolderID: UUID?
}

private struct NoteMoveUndoSnapshot {
    let noteID: UUID
    let sourceFolderID: UUID?
    let destinationFolderID: UUID?
}

private struct NoteDeletionUndoSnapshot {
    let noteID: UUID
    let previousDeletedAt: Date?
    let previousFolderID: UUID?
}

private struct FolderDeletionUndoSnapshot {
    let folders: [FolderUndoSnapshot]
    let noteMoves: [NoteFolderUndoSnapshot]
    let preserveNotes: Bool
}

private struct FolderUndoSnapshot {
    let id: UUID
    let name: String
    let createdAt: Date
    let modifiedAt: Date
    let parentFolderID: UUID?
    let depth: Int
}

private struct NoteFolderUndoSnapshot {
    let noteID: UUID
    let originalFolderID: UUID?
    let previousDeletedAt: Date?
}

private struct ExportManifest: Codable {
    let format: String
    let version: Int
    let exportedAt: String
    let notes: [ExportManifestNote]
}

private struct ExportManifestNote: Codable {
    let id: String
    let title: String
    let content: String
    let pinnedThoughts: [ExportManifestPinnedThought]
    let createdAt: String
    let modifiedAt: String
    let deletedAt: String?
    let folderPath: [String]
    let attachments: [ExportManifestAttachment]
}

private struct ExportManifestPinnedThought: Codable {
    let id: String
    let text: String
    let order: Int
    let isCollapsed: Bool
    let createdAt: String
    let modifiedAt: String
}

private struct ExportManifestAttachment: Codable {
    let id: String
    let createdAt: String
    let mimeType: String
    let filename: String
    let data: String
}

enum NoteExportError: LocalizedError {
    case noNotesSelected
    case failedToEncodeText
    case failedToEncodeManifest
    case failedToCreateArchive

    var errorDescription: String? {
        switch self {
        case .noNotesSelected:
            "No notes were selected to export."
        case .failedToEncodeText:
            "The note export could not be encoded as UTF-8."
        case .failedToEncodeManifest:
            "The note export manifest could not be encoded as JSON."
        case .failedToCreateArchive:
            "The selected notes could not be zipped for export."
        }
    }
}

enum NoteImportError: LocalizedError {
    case invalidFile
    case unsupportedFormat
    case noImportableNotes

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            "The selected file is not a valid MyRAM export."
        case .unsupportedFormat:
            "This MyRAM export format is not supported."
        case .noImportableNotes:
            "The selected MyRAM export does not contain any importable notes."
        }
    }
}
