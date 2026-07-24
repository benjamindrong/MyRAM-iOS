// NotesListView.swift
import SwiftUI
import SwiftData
import UIKit
import Combine

@MainActor
final class NotesListState: ObservableObject {
    enum BootstrapState: Equatable {
        case recovering
        case ready
        case failed(String)
    }

    struct BootstrapActions {
        var rollbackIfNeededOnLaunch: @MainActor () async throws -> Void
        var migrateNoteSequenceStates: @MainActor () async throws -> Void
        var refreshPendingSyncStatus: @MainActor () async -> Void
        var resumeOutboundAfterRecovery: @MainActor () -> Void
        var startNetworkingIfNeeded: @MainActor () -> Void
        var resumePendingConvergencePresentationIfNeeded: @MainActor () -> Void
    }

    let vm: NotesViewModel
    let syncController: MyRAMSyncController
    @Published private(set) var bootstrapState: BootstrapState = .recovering
    private let bootstrapActions: BootstrapActions
    private var cancellables: Set<AnyCancellable> = []

    init(
        context: ModelContext,
        startsBootstrapAutomatically: Bool = true,
        bootstrapActionsFactory: ((NotesViewModel, MyRAMSyncController) -> BootstrapActions)? = nil
    ) {
        let syncController = MyRAMSyncController(startsNetworking: false)
        syncController.suspendOutboundForRecovery()
        self.syncController = syncController
        vm = NotesViewModel(
            context: context,
            syncController: syncController,
            resumesPendingConvergenceOnInit: false
        )
        bootstrapActions = bootstrapActionsFactory?(vm, syncController)
            ?? BootstrapActions(
                rollbackIfNeededOnLaunch: { [vm, syncController] in
                    try await vm.rollbackIfNeededOnLaunch(syncController: syncController)
                },
                migrateNoteSequenceStates: {
                    try await NoteSequenceStateBootstrapMigrator(
                        container: PersistenceManager.shared.container
                    ).runToCompletion()
                },
                refreshPendingSyncStatus: { [syncController] in
                    await syncController.refreshPendingSyncStatus()
                },
                resumeOutboundAfterRecovery: { [syncController] in
                    syncController.resumeOutboundAfterRecovery()
                },
                startNetworkingIfNeeded: { [syncController] in
                    syncController.startNetworkingIfNeeded()
                },
                resumePendingConvergencePresentationIfNeeded: { [vm] in
                    vm.resumePendingConvergencePresentationIfNeeded()
                }
            )

        vm.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        syncController.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        if startsBootstrapAutomatically {
            Task { [weak self] in
                await self?.bootstrapAfterRecovery()
            }
        }
    }

    func bootstrapAfterRecovery() async {
        do {
            try await bootstrapActions.rollbackIfNeededOnLaunch()
            try await bootstrapActions.migrateNoteSequenceStates()
            await bootstrapActions.refreshPendingSyncStatus()
            bootstrapActions.resumeOutboundAfterRecovery()
            bootstrapActions.startNetworkingIfNeeded()
            bootstrapActions.resumePendingConvergencePresentationIfNeeded()
            bootstrapState = .ready
        } catch {
            bootstrapState = .failed(
                "Startup recovery or note-state preparation failed. Restart MyRAM before syncing or editing."
            )
        }
    }
}

struct NotesListView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let topBarControlSize: CGFloat = 44
    private let topBarIconSize: CGFloat = 20
    private let topBarHeight: CGFloat = 44
#if targetEnvironment(macCatalyst)
    // Legacy Catalyst desktop shell sizing. Native macOS will use an os(macOS) boundary instead.
    private let desktopSidebarDefaultWidth: CGFloat = 300
    private let desktopSidebarMinimumWidth: CGFloat = 0
    private let desktopSidebarMinimumExpandedWidth: CGFloat = 220
    private let desktopSidebarMaximumWidth: CGFloat = 520
    private let desktopSidebarDividerWidth: CGFloat = 1
    private let desktopSidebarResizeHitWidth: CGFloat = 10
    private let desktopSidebarHandleSize: CGFloat = 30
    private let desktopSidebarToggleDragThreshold: CGFloat = 4
#endif
    @ObservedObject private var state: NotesListState
    @StateObject private var editorToolbarBridge = NoteEditorToolbarBridge()
    @State private var editMode: EditMode = .inactive
    @State private var selectedNote: Note? = nil
    @State private var showingRecentlyDeleted = false
    @State private var recentlyDeletedNotes: [Note] = []
    @State private var selectedNoteIDs: Set<UUID> = []
    @State private var sharePayload: SharePayload?
    @State private var exportErrorMessage: String?
    @State private var importErrorMessage: String?
    @State private var showingCreateFolderPrompt = false
    @State private var newFolderName = ""
    @State private var folderAwaitingRename: Folder?
    @State private var renameFolderName = ""
    @State private var noteMoveRequest: NoteMoveRequest?
    @State private var bulkNoteMoveRequest: BulkNoteMoveRequest?
    @State private var pendingFolderDeletionQueue: [Folder] = []
    @State private var folderAwaitingDeleteDecision: Folder?
    @State private var showingRootTitleRenamePrompt = false
    @State private var rootTitleDraft = ""
    @State private var rootTitleUndoHistory: [String] = []
    @State private var rootTitleRedoHistory: [String] = []
    @State private var showingListUndoRedoActions = false
    @State private var showingNearbySync = false
    @State private var searchText = ""
    @State private var searchScope: NotesSearchScope = .allNotes
    @State private var currentNoteSearchText = ""
    @State private var currentNoteSearchFocusToken = 0
    @State private var noteActionDialogContext: NoteActionDialogContext?
    @FocusState private var isSearchFocused: Bool
#if targetEnvironment(macCatalyst)
    // Legacy Catalyst desktop sidebar state; not a native macOS policy.
    @State private var desktopSidebarWidth: CGFloat = 300
    @State private var lastExpandedDesktopSidebarWidth: CGFloat = 300
    @State private var desktopSidebarDragStartWidth: CGFloat?
#endif
#if DEBUG
    @State private var showingClearDemoNotesConfirmation = false
#endif
    @AppStorage("mainListTitle") private var mainListTitle = "My Notes"
    @AppStorage("appearanceSetting") private var appearanceSettingRaw = AppearanceSetting.system.rawValue
    @AppStorage("editorChromeStyle") private var editorChromeStyleRaw = EditorChromeStyle.standard.rawValue
    @AppStorage("pinnedHighlightColor") private var pinnedHighlightColorRaw = PinnedHighlightColor.yellow.rawValue
    
    init(state: NotesListState) {
        self.state = state
    }

    private var vm: NotesViewModel { state.vm }
    private var syncController: MyRAMSyncController { state.syncController }
    
    var body: some View {
        NavigationStack {
            switch state.bootstrapState {
            case .recovering:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(editorChromeStyle.appBackgroundColor.ignoresSafeArea())
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.red)
                    Button("Copy Support Details") {
                        UIPasteboard.general.string = message
                    }
                        .buttonStyle(.borderedProminent)
                    Text("Close and reopen MyRAM before syncing or editing.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(editorChromeStyle.appBackgroundColor.ignoresSafeArea())
            case .ready:
                readyContent
            }
        }
    }

    private var readyContent: some View {
        VStack(spacing: 6) {
            notesListTopBar
                .padding(.horizontal)
                .padding(.top, 6)

            notesSearchField
                .padding(.horizontal)

#if targetEnvironment(macCatalyst)
            // Legacy Catalyst desktop split view. Future native macOS will use os(macOS)-gated AppKit/SwiftUI code.
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    notesListContent
                        .frame(width: desktopSidebarWidth)

                    desktopEditorDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                desktopSidebarDivider
                    .offset(x: desktopSidebarWidth)
                    .zIndex(1)

                desktopSidebarResizeHandle
                    .offset(x: desktopSidebarWidth)
                    .zIndex(2)
            }
#else
            notesListContent
#endif
        }
        .background(editorChromeStyle.appBackgroundColor.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .background(searchKeyboardShortcut)
        .modifier(MobileNoteEditorSheet(
            selectedNote: $selectedNote,
            vm: vm,
            syncController: syncController,
            onOpenSyncConflicts: {
                showingNearbySync = true
            }
        ))
            .sheet(isPresented: $showingRecentlyDeleted) {
                RecentlyDeletedView(
                    notes: recentlyDeletedNotes,
                    onAppear: {
                        recentlyDeletedNotes = vm.fetchRecentlyDeletedNotes()
                    },
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
            .sheet(isPresented: $showingNearbySync) {
                NavigationStack {
                    NearbySyncView(
                        syncController: syncController,
                        notesViewModel: vm,
                        style: editorChromeStyle,
                        resetAvailability: vm.hasMountedActiveEditor
                            ? NearbySyncView.ResetAvailability(
                                isAvailable: false,
                                unavailableReason: "Close the editor or open Nearby Sync from the editor before resetting."
                            )
                            : .available,
                        prepareEditorState: {}
                    )
                        .navigationTitle("Nearby Sync")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    showingNearbySync = false
                                }
                            }
                        }
                }
            }
            .onOpenURL { url in
                importMyRAMFile(from: url)
            }
            .alert("Unable to Export Notes", isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage ?? "An unknown export error occurred.")
            }
            .alert("Unable to Import Notes", isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage ?? "An unknown import error occurred.")
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
            .alert("Rename Main List", isPresented: $showingRootTitleRenamePrompt) {
                TextField("Main List Title", text: $rootTitleDraft)
                Button("Cancel", role: .cancel) {
                    rootTitleDraft = mainListTitle
                }
                Button("Save") {
                    let trimmed = rootTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let newTitle = trimmed.isEmpty ? "My Notes" : trimmed
                    guard newTitle != mainListTitle else { return }
                    rootTitleUndoHistory.append(mainListTitle)
                    rootTitleRedoHistory.removeAll()
                    if rootTitleUndoHistory.count > 40 {
                        rootTitleUndoHistory.removeFirst(rootTitleUndoHistory.count - 40)
                    }
                    mainListTitle = newTitle
                }
            } message: {
                Text("Set the title shown on the top-level notes list.")
            }
            .confirmationDialog("Edit History", isPresented: $showingListUndoRedoActions, titleVisibility: .visible) {
                Button("Undo") {
                    performCombinedUndo()
                }
                .disabled(!canPerformCombinedUndo)

                Button("Redo") {
                    performCombinedRedo()
                }
                .disabled(!canPerformCombinedRedo)
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
            .sheet(item: $bulkNoteMoveRequest) { request in
                BulkNoteMoveDestinationView(
                    availableFolders: vm.fetchAllFolders(),
                    folderPathProvider: buildFolderPath(for:),
                    onMove: { destination in
                        for note in request.notes {
                            vm.moveNote(note, to: destination)
                        }
                    }
                )
            }
#if os(iOS) && !targetEnvironment(macCatalyst)
            .overlay {
                if let context = noteActionDialogContext {
                    NoteActionSheetOverlay(
                        context: context,
                        selectedCount: selectedNotes.count,
                        pinActionTitle: pinActionTitle(for: context),
                        onDismiss: { noteActionDialogContext = nil },
                        onPin: {
                            performPinAction(for: context)
                            noteActionDialogContext = nil
                        },
                        onMove: {
                            performMoveAction(for: context)
                            noteActionDialogContext = nil
                        },
                        onExport: {
                            performExportAction(for: context)
                            noteActionDialogContext = nil
                        },
                        onDelete: {
                            performDeleteAction(for: context)
                            noteActionDialogContext = nil
                        }
                    )
                }
            }
#endif
            .overlay(alignment: .bottomTrailing) {
                SyncStatusIndicator(syncController: syncController) {
                    showingNearbySync = true
                }
                .padding(.trailing, 16)
                .padding(.bottom, 14)
            }
#if DEBUG
            .confirmationDialog(
                "Clear Demo Notes?",
                isPresented: $showingClearDemoNotesConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Demo Notes", role: .destructive) {
                    vm.clearDemoNotes()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only notes created by the demo data generator will be removed.")
            }
#endif
        .onChange(of: vm.notes) { _, updatedNotes in
            let currentIDs = Set(updatedNotes.map(\.id))
            selectedNoteIDs = selectedNoteIDs.intersection(currentIDs)
            if let selectedNote, !currentIDs.contains(selectedNote.id) {
                self.selectedNote = nil
                editorToolbarBridge.reset()
            }
        }
        .onChange(of: selectedNote?.id) { _, noteID in
            if noteID == nil {
                searchScope = .allNotes
                currentNoteSearchText = ""
                editorToolbarBridge.reset()
            } else {
                currentNoteSearchText = ""
                currentNoteSearchFocusToken += searchScope == .currentNote ? 1 : 0
            }
        }
    }

#if targetEnvironment(macCatalyst)
    // Legacy Catalyst desktop sidebar affordance; do not carry this into the native macOS target by default.
    private var desktopSidebarDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(desktopSidebarWidth == 0 ? 0.30 : 0.22))
            .frame(width: desktopSidebarDividerWidth)
            .frame(maxHeight: .infinity)
    }

    private var desktopSidebarResizeHandle: some View {
        ZStack {
            // Keep resize hit testing near the divider so editor clicks are not intercepted.
            Color.clear
                .frame(width: desktopSidebarResizeHitWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let startWidth = desktopSidebarDragStartWidth ?? desktopSidebarWidth
                            desktopSidebarDragStartWidth = startWidth
                            desktopSidebarWidth = clampedDesktopSidebarWidth(
                                startWidth + value.translation.width
                            )
                        }
                        .onEnded { value in
                            desktopSidebarDragStartWidth = nil

                            let didDrag = abs(value.translation.width) > desktopSidebarToggleDragThreshold
                                || abs(value.translation.height) > desktopSidebarToggleDragThreshold
                            if didDrag {
                                snapDesktopSidebarWidthIfNeeded()
                                if desktopSidebarWidth > 0 {
                                    lastExpandedDesktopSidebarWidth = desktopSidebarWidth
                                }
                            }
                        }
                )
                .accessibilityHidden(true)

            Button {
                toggleDesktopSidebar()
            } label: {
                Image(systemName: desktopSidebarWidth == 0 ? "chevron.right" : "chevron.left")
                    .font(.caption.weight(.bold))
                    .frame(width: desktopSidebarHandleSize, height: desktopSidebarHandleSize)
                    .background(.thinMaterial)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.12), radius: 4, x: 0, y: 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(desktopSidebarWidth == 0 ? "Show notes sidebar" : "Hide notes sidebar")
            .accessibilityHint("Drag the divider to resize the notes sidebar.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                toggleDesktopSidebar()
            }
        }
            .frame(width: desktopSidebarHandleSize)
            .frame(maxHeight: .infinity)
            .offset(x: -(desktopSidebarHandleSize - desktopSidebarResizeHitWidth) / 2)
    }

    private func clampedDesktopSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, desktopSidebarMinimumWidth), desktopSidebarMaximumWidth)
    }

    private func snapDesktopSidebarWidthIfNeeded() {
        guard desktopSidebarWidth > 0,
              desktopSidebarWidth < desktopSidebarMinimumExpandedWidth else {
            return
        }
        desktopSidebarWidth = 0
    }

    private func toggleDesktopSidebar() {
        if desktopSidebarWidth == 0 {
            let savedWidth = lastExpandedDesktopSidebarWidth > 0
                ? lastExpandedDesktopSidebarWidth
                : desktopSidebarDefaultWidth
            let restoredWidth = max(savedWidth, desktopSidebarMinimumExpandedWidth)
            desktopSidebarWidth = clampedDesktopSidebarWidth(restoredWidth)
        } else {
            lastExpandedDesktopSidebarWidth = desktopSidebarWidth
            desktopSidebarWidth = 0
        }
    }
#endif

    private var editorChromeStyle: EditorChromeStyle {
        EditorChromeStyle(rawValue: editorChromeStyleRaw) ?? .standard
    }

    private var pinnedHighlightColor: PinnedHighlightColor {
        PinnedHighlightColor(rawValue: pinnedHighlightColorRaw) ?? .yellow
    }

    private var pinnedHighlightText: Color {
        PinnedHighlightPalette.text(for: pinnedHighlightColor)
    }

    private var notesListContent: some View {
        List(selection: notesListSelection) {
            ForEach(listItems) { item in
                row(for: item)
            }
        }
#if targetEnvironment(macCatalyst)
        // Legacy Catalyst desktop context menu. Native macOS should get an explicit os(macOS) interaction model.
        .contextMenu(forSelectionType: UUID.self) { noteIDs in
            desktopNoteContextMenuButtons(for: noteIDs)
        } primaryAction: { noteIDs in
            if noteIDs.count == 1,
               let noteID = noteIDs.first,
               let note = note(for: noteID) {
                handleNotePrimaryAction(note)
            }
        }
#endif
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .scrollContentBackground(editorChromeStyle.isWarmPaper ? .hidden : .automatic)
        .contentMargins(.top, 0, for: .scrollContent)
    }

    private var notesSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(searchScope.searchPlaceholder, text: activeSearchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .onSubmit {
                    isSearchFocused = false
                    if searchScope == .currentNote {
                        currentNoteSearchFocusToken += 1
                    }
                }
                .focused($isSearchFocused)
                .accessibilityIdentifier("notes-search-field")

            if MyRAMPlatform.isMacCatalyst {
                // Legacy Catalyst exposes desktop current-note search from the split editor shell.
                if selectedNote != nil {
                    Picker("Search scope", selection: $searchScope) {
                        ForEach(NotesSearchScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 156)
                    .onChange(of: searchScope) {
                        isSearchFocused = false
                        if searchScope == .currentNote {
                            currentNoteSearchFocusToken += 1
                        }
                    }
                    .accessibilityIdentifier("notes-search-scope")
                }
            }

            if isSearching {
                Button {
                    activeSearchText.wrappedValue = ""
                    if searchScope == .currentNote {
                        currentNoteSearchFocusToken += 1
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("notes-search-clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(editorChromeStyle.toolbarFillColor)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(editorChromeStyle.toolbarStrokeColor, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var isSearching: Bool {
        !activeSearchText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var activeSearchText: Binding<String> {
        Binding(
            get: {
                searchScope == .currentNote ? currentNoteSearchText : searchText
            },
            set: { newValue in
                if searchScope == .currentNote {
                    currentNoteSearchText = newValue
                } else {
                    searchText = newValue
                }
            }
        )
    }

    private var searchKeyboardShortcut: some View {
        Button {
            activateSearchFromShortcut()
        } label: {
            EmptyView()
        }
        .keyboardShortcut("f", modifiers: .command)
        .accessibilityHidden(true)
        .hidden()
    }

    private func activateSearchFromShortcut() {
        if MyRAMPlatform.isMacCatalyst {
            // Legacy Catalyst routes Command-F between sidebar and embedded editor search.
            if isSearchFocused {
                searchScope = .allNotes
            } else if editorToolbarBridge.isEditorFocused, selectedNote != nil {
                searchScope = .currentNote
                currentNoteSearchFocusToken += 1
            } else if selectedNote != nil {
                searchScope = .currentNote
                currentNoteSearchFocusToken += 1
            } else {
                searchScope = .allNotes
            }
        }
        isSearchFocused = true
    }

    private var notesListSelection: Binding<Set<UUID>> {
        Binding(
            get: { selectedNoteIDs },
            set: { proposedSelection in
                if MyRAMPlatform.isMacCatalyst, editMode.isEditing {
                    // Legacy Catalyst emulates multi-toggle selection in the desktop list shell.
                    selectedNoteIDs = toggledDesktopSelection(from: selectedNoteIDs, proposedSelection: proposedSelection)
                    return
                }

                selectedNoteIDs = proposedSelection
            }
        )
    }

    @ViewBuilder
    private var desktopEditorDetail: some View {
        if let selectedNote {
            NoteEditorView(
                vm: vm,
                note: selectedNote,
                onNewNote: { newNote in
                    self.selectedNote = newNote
                },
                showsTopBar: false,
                toolbarBridge: editorToolbarBridge,
                syncConflicts: vm.activeSyncConflicts(for: selectedNote),
                currentNoteSearchText: $currentNoteSearchText,
                currentNoteSearchFocusToken: currentNoteSearchFocusToken,
                onOpenSyncConflicts: {
                    showingNearbySync = true
                }
            )
            .id(selectedNote.id)
        } else {
            ContentUnavailableView(
                "Select a Note",
                systemImage: "note.text",
                description: Text("Choose a note from the sidebar or create a new one.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var notesListTopBar: some View {
        GeometryReader { proxy in
            let layout = topBarActionLayout(totalWidth: proxy.size.width)
            ChromeActionBar(style: editorChromeStyle) {
                if vm.currentFolder != nil {
                    compactActionButton(systemImage: "chevron.left", identifier: "notes-topbar-back") {
                        vm.navigateToParentFolder()
                        selectedNoteIDs.removeAll()
                    }
                }

                selectionModeButton

                titleControl

                Spacer(minLength: 0)

#if targetEnvironment(macCatalyst)
                // Legacy Catalyst embeds editor toolbar actions into the desktop list top bar.
                if selectedNote != nil {
                    desktopEditorToolbarActions
                }
#endif

                ForEach(layout.visibleActions, id: \.self) { action in
                    topBarVisibleAction(for: action)
                }

                Menu {
                    Button {
                        showingNearbySync = true
                    } label: {
                        Label("Nearby Sync", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .foregroundStyle(.primary)

                    Divider()

                    ForEach(layout.overflowActions, id: \.self) { action in
                        overflowMenuItem(for: action)
                    }

                    Menu("Appearance") {
                        Picker("Mode", selection: $appearanceSettingRaw) {
                            ForEach(AppearanceSetting.allCases) { appearanceSetting in
                                Text(appearanceSetting.title).tag(appearanceSetting.rawValue)
                            }
                        }

                        Picker("Style", selection: $editorChromeStyleRaw) {
                            ForEach(EditorChromeStyle.allCases) { style in
                                Text(style.title).tag(style.rawValue)
                            }
                        }

                        Picker("Pinned Color", selection: $pinnedHighlightColorRaw) {
                            ForEach(PinnedHighlightColor.allCases) { color in
                                Text(color.title).tag(color.rawValue)
                            }
                        }
                    }

#if DEBUG
                    Divider()

                    Button {
                        vm.generateDemoNotes()
                    } label: {
                        Label("Generate Demo Notes", systemImage: "wand.and.stars")
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("generate-demo-notes")

                    Button(role: .destructive) {
                        showingClearDemoNotesConfirmation = true
                    } label: {
                        Label("Clear Demo Notes", systemImage: "trash")
                    }
                    .accessibilityIdentifier("clear-demo-notes")
#endif
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: topBarIconSize, weight: .semibold))
                        .frame(width: topBarControlSize, height: topBarControlSize)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary)
                }
                .tint(.primary)
                .accessibilityIdentifier("notes-list-more")
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: topBarHeight)
    }

    @ViewBuilder
    private var titleControl: some View {
        if vm.currentFolder == nil {
            Button {
                rootTitleDraft = mainListTitle
                showingRootTitleRenamePrompt = true
            } label: {
                HStack(spacing: 6) {
                    Text(mainListTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .allowsTightening(true)
                    Image(systemName: "pencil")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("edit-main-list-title")
        } else {
            Button {
                guard let folder = vm.currentFolder else { return }
                folderAwaitingRename = folder
                renameFolderName = folder.name
            } label: {
                HStack(spacing: 6) {
                    Text(vm.currentFolder?.name ?? mainListTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .allowsTightening(true)
                    Image(systemName: "pencil")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("edit-folder-title")
        }
    }

    private var selectionModeButton: some View {
        compactActionButton(
            systemImage: editMode.isEditing ? "checkmark.circle.fill" : "checkmark.circle",
            identifier: "notes-topbar-select"
        ) {
            editMode = editMode.isEditing ? .inactive : .active
        }
        .accessibilityLabel(editMode.isEditing ? "Finish selecting notes" : "Select notes")
    }

    private var desktopEditorToolbarActions: some View {
        HStack(spacing: 8) {
            compactActionButton(systemImage: "square.and.arrow.up", identifier: "desktop-topbar-export-note") {
                editorToolbarBridge.exportNote?()
            }

            Menu {
                Button {
                    editorToolbarBridge.importFromPhotoLibrary?()
                } label: {
                    Label("Photo Library", systemImage: "photo")
                }

                Button {
                    editorToolbarBridge.importImageFile?()
                } label: {
                    Label("Import Image", systemImage: "square.and.arrow.down")
                }
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: topBarIconSize, weight: .semibold))
                    .frame(width: topBarControlSize, height: topBarControlSize)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
            }
            .tint(.primary)
            .accessibilityIdentifier("desktop-topbar-attachments")

            compactActionButton(systemImage: "trash", identifier: "desktop-topbar-delete-note") {
                editorToolbarBridge.deleteNote?()
                selectedNote = nil
                editorToolbarBridge.reset()
            }
        }
    }

    private func compactActionButton(
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: topBarIconSize, weight: .semibold))
                .frame(width: topBarControlSize, height: topBarControlSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityIdentifier(identifier)
    }

    private func topBarActionLayout(totalWidth: CGFloat) -> TopBarActionLayout {
        let minimumTitleWidth: CGFloat = 56
        let titleWidth = max(minimumTitleWidth, estimatedTitleWidth)
        let selectControlWidth: CGFloat = topBarControlSize
        let backButtonWidth: CGFloat = vm.currentFolder == nil ? 0 : topBarControlSize
        let overflowButtonWidth: CGFloat = topBarControlSize
        let actionButtonWidth: CGFloat = topBarControlSize
        let interItemSpacing: CGFloat = 8
        let horizontalPadding: CGFloat = 20

        let reservedLeadingWidth = selectControlWidth + backButtonWidth
            + (vm.currentFolder == nil ? interItemSpacing : interItemSpacing * 2)
        let usableWidth = max(0, totalWidth - horizontalPadding)
        let titleAvailableWidth = max(
            0,
            usableWidth - reservedLeadingWidth - overflowButtonWidth - interItemSpacing
        )
        var remainingWidth = titleWidth > titleAvailableWidth
            ? 0
            : max(0, titleAvailableWidth - titleWidth)
        var visibleActions: [NotesListTopBarAction] = []
        var overflowActions: [NotesListTopBarAction] = []

        for action in NotesListTopBarAction.priorityOrder {
            let neededWidth = actionButtonWidth + (visibleActions.isEmpty ? 0 : interItemSpacing)
            if remainingWidth >= neededWidth {
                visibleActions.append(action)
                remainingWidth -= neededWidth
            } else {
                overflowActions.append(action)
            }
        }

        return TopBarActionLayout(visibleActions: visibleActions, overflowActions: overflowActions)
    }

    private var estimatedTitleWidth: CGFloat {
        let displayTitle = vm.currentFolder?.name ?? mainListTitle
        let titleFont = UIFont.preferredFont(forTextStyle: .title3)
        let textWidth = (displayTitle as NSString).size(withAttributes: [.font: titleFont]).width
        let editAffordanceWidth: CGFloat = vm.currentFolder == nil ? 30 : 0
        return ceil(textWidth) + 16 + editAffordanceWidth
    }

    @ViewBuilder
    private func topBarVisibleAction(for action: NotesListTopBarAction) -> some View {
        switch action {
        case .history:
            compactActionButton(systemImage: "arrow.uturn.backward.circle", identifier: "notes-topbar-history") {
                showingListUndoRedoActions = true
            }
            .opacity((canPerformCombinedUndo || canPerformCombinedRedo) ? 1 : 0.4)
            .disabled(!canPerformCombinedUndo && !canPerformCombinedRedo)
        case .newNote:
            compactActionButton(systemImage: "square.and.pencil", identifier: "notes-topbar-new-note") {
                selectedNote = vm.createNewNoteIfPossible()
            }
        case .newFolder:
            compactActionButton(systemImage: "folder.badge.plus", identifier: "notes-topbar-new-folder") {
                newFolderName = ""
                showingCreateFolderPrompt = true
            }
        case .recentlyDeleted:
            compactActionButton(systemImage: "trash", identifier: "notes-topbar-recently-deleted") {
                showingRecentlyDeleted = true
            }
        }
    }

    @ViewBuilder
    private func overflowMenuItem(for action: NotesListTopBarAction) -> some View {
        switch action {
        case .history:
            Button {
                showingListUndoRedoActions = true
            } label: {
                Label("Edit History", systemImage: "arrow.uturn.backward.circle")
            }
            .foregroundStyle(.primary)
            .disabled(!canPerformCombinedUndo && !canPerformCombinedRedo)
        case .newNote:
            Button {
                selectedNote = vm.createNewNoteIfPossible()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .foregroundStyle(.primary)
        case .newFolder:
            Button {
                newFolderName = ""
                showingCreateFolderPrompt = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .foregroundStyle(.primary)
        case .recentlyDeleted:
            Button {
                showingRecentlyDeleted = true
            } label: {
                Label("Recently Deleted", systemImage: "trash")
            }
            .foregroundStyle(.primary)
        }
    }

    private var listItems: [NotesListItem] {
        if isSearching && searchScope == .allNotes {
            return searchResultNotes.map(NotesListItem.note)
        }

        return vm.currentFolderListItems()
    }

    private var searchResultNotes: [Note] {
        guard isSearching && searchScope == .allNotes else { return [] }
        return vm.fetchSearchableNotes()
            .filter { noteMatchesSearch($0, query: searchText) }
    }

    private var actionableNotes: [Note] {
        isSearching && searchScope == .allNotes ? searchResultNotes : vm.notes
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
        let noteCount = vm.activeNoteCount(in: folder)

        return Button {
            if editMode.isEditing { return }
            vm.openFolder(folder)
            selectedNoteIDs.removeAll()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(folder.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(noteCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(noteCount) notes")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ChromeListRowSurface(style: editorChromeStyle))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparatorTint(.secondary.opacity(0.35))
        .listRowBackground(Color.clear)
        .contextMenu {
            Button("Rename") {
                folderAwaitingRename = folder
                renameFolderName = folder.name
            }
            Button("Delete", role: .destructive) {
                pendingFolderDeletionQueue.append(folder)
                presentNextFolderDeletionPromptIfNeeded()
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
#if targetEnvironment(macCatalyst)
        // Legacy Catalyst desktop rows rely on SwiftUI list selection instead of mobile long-press actions.
        noteRowContent(note)
            .tag(note.id)
            .listRowSeparatorTint(.secondary.opacity(0.3))
            .listRowBackground(Color.clear)
#else
        Group {
            if editMode.isEditing {
                if isBulkNoteActionTarget(note) {
                    noteRowContent(note)
                        .highPriorityGesture(
                            LongPressGesture(minimumDuration: 0.35)
                                .onEnded { _ in
                                    handleBulkNoteLongPress(note)
                                }
                        )
                } else {
                    noteRowContent(note)
                        .highPriorityGesture(noteLongPressGesture(for: note))
                }
            } else {
                Button {
                    handleNotePrimaryAction(note)
                } label: {
                    noteRowContent(note)
                }
                .buttonStyle(.plain)
                .highPriorityGesture(noteLongPressGesture(for: note))
            }
        }
        .tag(note.id)
        .listRowSeparatorTint(.secondary.opacity(0.3))
        .listRowBackground(Color.clear)
#endif
    }

    private func noteRowContent(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let folderHint = pinnedNoteFolderHint(for: note) {
                    Text("📁 \(folderHint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel("Pinned note from \(folderHint)")
                }

                let pinnedThoughtPreview = pinnedThoughtPreviewText(for: note)
                if !pinnedThoughtPreview.isEmpty {
                    Text(pinnedThoughtPreview)
                        .lineLimit(1)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(pinnedHighlightText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .modifier(ChromeListPinnedPreview(style: editorChromeStyle, pinnedColor: pinnedHighlightColor))
                }
                let contentPreview = noteContentPreviewText(for: note)
                if !contentPreview.isEmpty {
                    Text(contentPreview)
                        .lineLimit(2)
                        .font(.subheadline)
                        .foregroundStyle(notePreviewContentTextColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if note.isPinned == true {
                Image(systemName: "pin.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ChromeListRowSurface(style: editorChromeStyle))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func noteContextMenuButtons(for context: NoteActionDialogContext) -> some View {
        Button(pinActionTitle(for: context)) {
            performPinAction(for: context)
        }
        Button(moveActionTitle(for: context)) {
            performMoveAction(for: context)
        }
        Button(exportActionTitle(for: context)) {
            performExportAction(for: context)
        }
        Button(deleteActionTitle(for: context), role: .destructive) {
            performDeleteAction(for: context)
        }
    }

    private func desktopNoteActionContext(for note: Note) -> NoteActionDialogContext {
        if selectedNoteIDs.contains(note.id), !selectedNotes.isEmpty {
            return .bulk
        }
        return .single(note)
    }

    @ViewBuilder
    private func desktopNoteContextMenuButtons(for noteIDs: Set<UUID>) -> some View {
        let notes = notes(for: noteIDs)
        if notes.count == 1, let note = notes.first {
            noteContextMenuButtons(for: desktopNoteActionContext(for: note))
        } else if !notes.isEmpty {
            Button(desktopBulkPinActionTitle(for: notes)) {
                selectedNoteIDs = Set(notes.map(\.id))
                setPinnedStateForSelectedNotes(isPinned: shouldPinSelectedNotes)
            }
            Button("Move \(notes.count) to Folder") {
                selectedNoteIDs = Set(notes.map(\.id))
                bulkNoteMoveRequest = BulkNoteMoveRequest(notes: selectedNotes)
            }
            Button("Export \(notes.count) Selected") {
                selectedNoteIDs = Set(notes.map(\.id))
                exportSelectedNotes()
            }
            Button("Delete \(notes.count) Selected", role: .destructive) {
                selectedNoteIDs = Set(notes.map(\.id))
                deleteSelectedNotes()
            }
        }
    }

    @ViewBuilder
    private func noteActionButtons(for context: NoteActionDialogContext) -> some View {
        switch context {
        case .single(let note):
            Button((note.isPinned ?? false) ? "Unpin" : "Pin") {
                vm.setNotePinned(note, isPinned: !(note.isPinned ?? false))
            }
            Button("Move to Folder") {
                noteMoveRequest = NoteMoveRequest(note: note)
            }
            Button("Export") {
                exportSingleNote(note)
            }
            Button("Delete", role: .destructive) {
                vm.deleteNote(note)
            }
        case .bulk:
            let count = selectedNotes.count
            Button(bulkPinActionTitleWithCount) {
                setPinnedStateForSelectedNotes(isPinned: shouldPinSelectedNotes)
            }
            Button("Move \(count) to Folder") {
                bulkNoteMoveRequest = BulkNoteMoveRequest(notes: selectedNotes)
            }
            Button("Export \(count) Selected") {
                exportSelectedNotes()
            }
            Button("Delete \(count) Selected", role: .destructive) {
                deleteSelectedNotes()
            }
        }
    }

    private var selectedNotes: [Note] {
        actionableNotes.filter { selectedNoteIDs.contains($0.id) }
    }

    private func note(for noteID: UUID) -> Note? {
        actionableNotes.first { $0.id == noteID }
    }

    private func notes(for noteIDs: Set<UUID>) -> [Note] {
        actionableNotes.filter { noteIDs.contains($0.id) }
    }

    private var shouldPinSelectedNotes: Bool {
        selectedNotes.contains { ($0.isPinned ?? false) == false }
    }

    private func desktopBulkPinActionTitle(for notes: [Note]) -> String {
        notes.contains { ($0.isPinned ?? false) == false }
            ? "Pin \(notes.count) Selected"
            : "Unpin \(notes.count) Selected"
    }

    private var bulkPinActionTitleWithCount: String {
        shouldPinSelectedNotes
            ? "Pin \(selectedNotes.count) Selected"
            : "Unpin \(selectedNotes.count) Selected"
    }

    private func pinActionTitle(for context: NoteActionDialogContext) -> String {
        switch context {
        case .single(let note):
            return (note.isPinned ?? false) ? "Unpin" : "Pin"
        case .bulk:
            return bulkPinActionTitleWithCount
        }
    }

    private func moveActionTitle(for context: NoteActionDialogContext) -> String {
        switch context {
        case .single:
            return "Move to Folder"
        case .bulk:
            return "Move \(selectedNotes.count) to Folder"
        }
    }

    private func exportActionTitle(for context: NoteActionDialogContext) -> String {
        switch context {
        case .single:
            return "Export"
        case .bulk:
            return "Export \(selectedNotes.count) Selected"
        }
    }

    private func deleteActionTitle(for context: NoteActionDialogContext) -> String {
        switch context {
        case .single:
            return "Delete"
        case .bulk:
            return "Delete \(selectedNotes.count) Selected"
        }
    }

    private var noteActionDialogTitle: String {
        guard let context = noteActionDialogContext else { return "" }
        switch context {
        case .single(let note):
            return note.title.isEmpty ? "Untitled Note" : note.title
        case .bulk:
            return "\(selectedNotes.count) Notes Selected"
        }
    }

    private var canPerformListUndo: Bool {
        !rootTitleUndoHistory.isEmpty || vm.hasUndoableAction
    }

    private var canPerformListRedo: Bool {
        !rootTitleRedoHistory.isEmpty || vm.hasRedoableAction
    }

    private var canPerformCombinedUndo: Bool {
        (selectedNote != nil && editorToolbarBridge.canUndo) || canPerformListUndo
    }

    private var canPerformCombinedRedo: Bool {
        (selectedNote != nil && editorToolbarBridge.canRedo) || canPerformListRedo
    }

    private func performCombinedUndo() {
        if selectedNote != nil, editorToolbarBridge.canUndo {
            editorToolbarBridge.undo?()
            return
        }

        performListUndo()
    }

    private func performCombinedRedo() {
        if selectedNote != nil, editorToolbarBridge.canRedo {
            editorToolbarBridge.redo?()
            return
        }

        performListRedo()
    }

    private func performListUndo() {
        if let previousTitle = rootTitleUndoHistory.popLast() {
            rootTitleRedoHistory.append(mainListTitle)
            mainListTitle = previousTitle
            return
        }
        vm.undoLastAction()
    }

    private func performListRedo() {
        if let nextTitle = rootTitleRedoHistory.popLast() {
            rootTitleUndoHistory.append(mainListTitle)
            mainListTitle = nextTitle
            return
        }
        vm.redoLastAction()
    }

    private func setPinnedStateForSelectedNotes(isPinned: Bool) {
        for selectedNote in selectedNotes {
            vm.setNotePinned(selectedNote, isPinned: isPinned)
        }
    }

    private func performPinAction(for context: NoteActionDialogContext) {
        switch context {
        case .single(let note):
            vm.setNotePinned(note, isPinned: !(note.isPinned ?? false))
        case .bulk:
            setPinnedStateForSelectedNotes(isPinned: shouldPinSelectedNotes)
        }
    }

    private func performMoveAction(for context: NoteActionDialogContext) {
        switch context {
        case .single(let note):
            noteMoveRequest = NoteMoveRequest(note: note)
        case .bulk:
            bulkNoteMoveRequest = BulkNoteMoveRequest(notes: selectedNotes)
        }
    }

    private func performExportAction(for context: NoteActionDialogContext) {
        switch context {
        case .single(let note):
            exportSingleNote(note)
        case .bulk:
            exportSelectedNotes()
        }
    }

    private func performDeleteAction(for context: NoteActionDialogContext) {
        switch context {
        case .single(let note):
            vm.deleteNote(note)
        case .bulk:
            deleteSelectedNotes()
        }
    }

    private func deleteSelectedNotes() {
        for selectedNote in selectedNotes {
            vm.deleteNote(selectedNote)
        }
        selectedNoteIDs.removeAll()
    }

    private func handleNotePrimaryAction(_ note: Note) {
        if editMode.isEditing {
            toggleSelection(for: note.id)
            return
        }

        vm.selectNote(note)
        selectedNote = note
    }

    private func toggleSelection(for noteID: UUID) {
        if selectedNoteIDs.contains(noteID) {
            selectedNoteIDs.remove(noteID)
        } else {
            selectedNoteIDs.insert(noteID)
        }
    }

    private func toggledDesktopSelection(
        from currentSelection: Set<UUID>,
        proposedSelection: Set<UUID>
    ) -> Set<UUID> {
        guard let clickedNoteID = proposedSelection.first, proposedSelection.count == 1 else {
            return proposedSelection
        }

        var updatedSelection = currentSelection
        if updatedSelection.contains(clickedNoteID) {
            updatedSelection.remove(clickedNoteID)
        } else {
            updatedSelection.insert(clickedNoteID)
        }
        return updatedSelection
    }

    private func isBulkNoteActionTarget(_ note: Note) -> Bool {
        editMode.isEditing
            && selectedNoteIDs.contains(note.id)
            && !selectedNotes.isEmpty
    }

    private func handleBulkNoteLongPress(_ note: Note) {
        guard isBulkNoteActionTarget(note) else {
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        noteActionDialogContext = .bulk
    }

    private func noteLongPressGesture(for note: Note) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .onEnded { _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                noteActionDialogContext = .single(note)
            }
    }

    private func pinnedNoteFolderHint(for note: Note) -> String? {
        guard note.isPinned ?? false else { return nil }

        let noteFolderID = note.folder?.id
        let currentFolderID = vm.currentFolder?.id

        // Only cross-context pinned notes need a location hint.
        guard noteFolderID != currentFolderID else { return nil }

        if let folder = note.folder {
            return buildFolderPath(for: folder)
        }
        return mainListTitle
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
        let notesToExport = actionableNotes.filter { selectedNoteIDs.contains($0.id) }
        do {
            let exportURLs = try vm.exportNotesForSharing(notesToExport)
            sharePayload = SharePayload(urls: exportURLs)
        } catch {
            exportErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "An unknown export error occurred."
        }
    }

    private func exportSingleNote(_ note: Note) {
        do {
            let exportURLs = try vm.exportNotesForSharing([note])
            sharePayload = SharePayload(urls: exportURLs)
        } catch {
            exportErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "An unknown export error occurred."
        }
    }

    private func importMyRAMFile(from url: URL) {
        do {
            selectedNote = try vm.importNotes(from: url).first
        } catch {
            importErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "An unknown import error occurred."
        }
    }

    private var notePreviewContentTextColor: Color {
        colorScheme == .dark ? .primary : .secondary
    }

    private func copySyncConflict(_ conflict: SyncConflictVersion) {
        UIPasteboard.general.string = conflict.remoteText
    }

}

private struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct MobileNoteEditorSheet: ViewModifier {
    @Binding var selectedNote: Note?
    @ObservedObject var vm: NotesViewModel
    @ObservedObject var syncController: MyRAMSyncController
    let onOpenSyncConflicts: () -> Void

    func body(content: Content) -> some View {
        if MyRAMPlatform.isMacCatalyst {
            // Legacy Catalyst shows the editor in the desktop split shell, not a mobile sheet.
            content
        } else {
            content
                .sheet(item: $selectedNote) { note in
                    NoteEditorView(
                        vm: vm,
                        note: note,
                        onNewNote: { newNote in
                            selectedNote = newNote
                        },
                        syncController: syncController,
                        syncConflicts: vm.activeSyncConflicts(for: note),
                        onOpenSyncConflicts: onOpenSyncConflicts
                    )
                }
        }
    }
}

private struct ChromeListRowSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let style: EditorChromeStyle

    func body(content: Content) -> some View {
        content
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(rowFillColor)
            }
            .overlay {
                if style.isChromeAccent {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(chromeAccentPinnedStrokeColor(for: colorScheme), lineWidth: 0.85)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var rowFillColor: Color {
        if style.isChromeAccent {
            return chromeAccentRowFillColor(for: colorScheme)
        }
        return style.listRowBackgroundColor
    }
}

private struct ChromeListPinnedPreview: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let style: EditorChromeStyle
    let pinnedColor: PinnedHighlightColor

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(PinnedHighlightPalette.highlight(for: pinnedColor))
                    .overlay {
                        if style.isChromeAccent {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(chromeAccentPinnedShineGradient(for: colorScheme))
                                .blendMode(.screen)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            .overlay {
                if style.isChromeAccent {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(chromeAccentPinnedStrokeColor(for: colorScheme), lineWidth: 0.8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct NoteContextPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("pinnedHighlightColor") private var pinnedHighlightColorRaw = PinnedHighlightColor.yellow.rawValue
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            let pinnedThoughtPreview = pinnedThoughtPreviewText(for: note)
            if !pinnedThoughtPreview.isEmpty {
                Text(pinnedThoughtPreview)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PinnedHighlightPalette.text(for: pinnedHighlightColor))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(PinnedHighlightPalette.highlight(for: pinnedHighlightColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            let contentPreview = noteContentPreviewText(for: note)
            if !contentPreview.isEmpty {
                Text(contentPreview)
                    .font(.caption)
                    .foregroundStyle(notePreviewContentTextColor)
                    .lineLimit(12)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 320, height: 320, alignment: .topLeading)
        .padding(14)
        .background(Color.clear)
    }

    private var notePreviewContentTextColor: Color {
        colorScheme == .dark ? .primary : .secondary
    }

    private var pinnedHighlightColor: PinnedHighlightColor {
        PinnedHighlightColor(rawValue: pinnedHighlightColorRaw) ?? .yellow
    }
}

private struct NoteActionSheetOverlay: View {
    let context: NoteActionDialogContext
    let selectedCount: Int
    let pinActionTitle: String
    let onDismiss: () -> Void
    let onPin: () -> Void
    let onMove: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 10) {
                switch context {
                case .single(let note):
                    NoteContextPreview(note: note)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
                case .bulk:
                    Text("\(selectedCount) Notes Selected")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                VStack(spacing: 0) {
                    NoteActionSheetRow(title: pinActionTitle, action: onPin)
                    NoteActionSheetRow(title: moveTitle, action: onMove)
                    NoteActionSheetRow(title: exportTitle, action: onExport)
                    NoteActionSheetRow(title: deleteTitle, role: .destructive, showDivider: false, action: onDelete)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 28)
        }
    }

    private var moveTitle: String {
        selectedCount > 1 ? "Move \(selectedCount) to Folder" : "Move to Folder"
    }

    private var exportTitle: String {
        selectedCount > 1 ? "Export \(selectedCount) Selected" : "Export"
    }

    private var deleteTitle: String {
        selectedCount > 1 ? "Delete \(selectedCount) Selected" : "Delete"
    }
}

private func chromeAccentRowFillColor(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark
        ? Color(red: 0.20, green: 0.21, blue: 0.24).opacity(0.88)
        : Color(red: 0.97, green: 0.97, blue: 0.98).opacity(0.96)
}

private struct NoteActionSheetRow: View {
    let title: String
    var role: ButtonRole?
    var showDivider = true
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
        .overlay(alignment: .bottom) {
            if showDivider {
                Divider()
                    .padding(.horizontal, 18)
            }
        }
    }
}

private enum NotesSearchScope: String, CaseIterable, Identifiable {
    case allNotes
    case currentNote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allNotes:
            "All"
        case .currentNote:
            "Current"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .allNotes:
            "Search Notes"
        case .currentNote:
            "Search Current Note"
        }
    }
}

private func pinnedThoughtPreviewText(for note: Note) -> String {
    let thoughts = note.pinnedThoughts
        .sorted {
            if $0.order != $1.order {
                return $0.order < $1.order
            }
            return $0.createdAt < $1.createdAt
        }
        .map(\.text)
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard !thoughts.isEmpty else { return "" }
    return thoughts.prefix(2).joined(separator: " • ")
}

func noteContentPreviewText(for note: Note) -> String {
    let previewLines = note.content
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !isCompletedChecklistPreviewLine($0) }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    return previewLines
}

func noteMatchesSearch(_ note: Note, query: String) -> Bool {
    let terms = query
        .split { $0.isWhitespace || $0.isNewline }
        .map(String.init)
    guard !terms.isEmpty else { return true }

    let searchableText = [
        note.title,
        noteContentPreviewText(for: note),
        note.pinnedThoughts
            .map(\.text)
            .joined(separator: " ")
    ]
    .joined(separator: " ")

    return terms.allSatisfy {
        searchableText.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

func isCompletedChecklistPreviewLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix(ChecklistItemEditor.checkedPrefix)
        || trimmed.hasPrefix(ChecklistItemEditor.checkedPrefixVariant)
        || trimmed.range(
            of: #"^\[[xX]\]\s+"#,
            options: .regularExpression
        ) != nil
        || trimmed.range(
            of: #"^-\s+\[[xX]\]\s+"#,
            options: .regularExpression
        ) != nil
}

private enum NotesListTopBarAction: String, CaseIterable {
    case history
    case newNote
    case newFolder
    case recentlyDeleted

    static let priorityOrder: [NotesListTopBarAction] = [
        .history,
        .newNote,
        .newFolder,
        .recentlyDeleted
    ]
}

private struct TopBarActionLayout {
    let visibleActions: [NotesListTopBarAction]
    let overflowActions: [NotesListTopBarAction]
}

private enum NoteActionDialogContext {
    case single(Note)
    case bulk
}

private struct NoteMoveRequest: Identifiable {
    let id = UUID()
    let note: Note
}

private struct BulkNoteMoveRequest: Identifiable {
    let id = UUID()
    let notes: [Note]
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

private struct BulkNoteMoveDestinationView: View {
    @Environment(\.dismiss) private var dismiss
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
                    Text("Top Level")
                }

                ForEach(sortedFolders, id: \.id) { folder in
                    Button {
                        onMove(folder)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder.name)
                                .font(.headline)
                            Text(folderPathProvider(folder))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("Move Selected Notes")
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
    let onAppear: () -> Void
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
        .onAppear(perform: onAppear)
    }
}
