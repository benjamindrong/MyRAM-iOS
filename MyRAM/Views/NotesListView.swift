// NotesListView.swift
import SwiftUI
import SwiftData
import UIKit

struct NotesListView: View {
    private let topBarControlSize: CGFloat = 44
    private let topBarIconSize: CGFloat = 20
    private let topBarHeight: CGFloat = 44
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
    @State private var bulkNoteMoveRequest: BulkNoteMoveRequest?
    @State private var pendingFolderDeletionQueue: [Folder] = []
    @State private var folderAwaitingDeleteDecision: Folder?
    @State private var showingRootTitleRenamePrompt = false
    @State private var rootTitleDraft = ""
    @State private var rootTitleUndoHistory: [String] = []
    @State private var rootTitleRedoHistory: [String] = []
    @State private var showingListUndoRedoActions = false
    @State private var noteActionDialogContext: NoteActionDialogContext?
#if DEBUG
    @State private var showingClearDemoNotesConfirmation = false
#endif
    @AppStorage("mainListTitle") private var mainListTitle = "My Notes"
    @AppStorage("appearanceSetting") private var appearanceSettingRaw = AppearanceSetting.system.rawValue
    @AppStorage("editorChromeStyle") private var editorChromeStyleRaw = EditorChromeStyle.standard.rawValue
    
    init(context: ModelContext) {
        _vm = StateObject(wrappedValue: NotesViewModel(context: context))
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                notesListTopBar
                    .padding(.horizontal)
                    .padding(.top, 6)

                List(selection: $selectedNoteIDs) {
                    ForEach(listItems) { item in
                        row(for: item)
                    }
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, $editMode)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedNote) { note in
                NoteEditorView(vm: vm, note: note) { newNote in
                    selectedNote = newNote
                }
            }
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
                    performListUndo()
                }
                .disabled(!canPerformListUndo)

                Button("Redo") {
                    performListRedo()
                }
                .disabled(!canPerformListRedo)
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
            .confirmationDialog(
                noteActionDialogTitle,
                isPresented: Binding(
                    get: { noteActionDialogContext != nil },
                    set: { if !$0 { noteActionDialogContext = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let context = noteActionDialogContext {
                    noteActionButtons(for: context)
                }
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
        }
        .onChange(of: vm.notes) { _, updatedNotes in
            let currentIDs = Set(updatedNotes.map(\.id))
            selectedNoteIDs = selectedNoteIDs.intersection(currentIDs)
        }
    }

    private var editorChromeStyle: EditorChromeStyle {
        EditorChromeStyle(rawValue: editorChromeStyleRaw) ?? .standard
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

                ForEach(layout.visibleActions, id: \.self) { action in
                    topBarVisibleAction(for: action)
                }

                Menu {
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
            .opacity((canPerformListUndo || canPerformListRedo) ? 1 : 0.4)
            .disabled(!canPerformListUndo && !canPerformListRedo)
        case .newNote:
            compactActionButton(systemImage: "square.and.pencil", identifier: "notes-topbar-new-note") {
                selectedNote = vm.createNewNote()
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
            .disabled(!canPerformListUndo && !canPerformListRedo)
        case .newNote:
            Button {
                selectedNote = vm.createNewNote()
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparatorTint(.secondary.opacity(0.35))
        .listRowBackground(Color(.secondarySystemGroupedBackground))
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
                        .contextMenu {
                            noteActionButtons(for: .single(note))
                        } preview: {
                            NoteContextPreview(note: note)
                        }
                }
            } else {
                Button {
                    vm.selectNote(note)
                    selectedNote = note
                } label: {
                    noteRowContent(note)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    noteActionButtons(for: .single(note))
                } preview: {
                    NoteContextPreview(note: note)
                }
            }
        }
        .tag(note.id)
        .listRowSeparatorTint(.secondary.opacity(0.3))
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    private func noteRowContent(_ note: Note) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                let pinnedThoughtPreview = pinnedThoughtPreviewText(for: note)
                if !pinnedThoughtPreview.isEmpty {
                    Text(pinnedThoughtPreview)
                        .lineLimit(1)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                let contentPreview = noteContentPreviewText(for: note)
                if !contentPreview.isEmpty {
                    Text(contentPreview)
                        .lineLimit(2)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if note.isPinned == true {
                Image(systemName: "pin.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
        vm.notes.filter { selectedNoteIDs.contains($0.id) }
    }

    private var shouldPinSelectedNotes: Bool {
        selectedNotes.contains { ($0.isPinned ?? false) == false }
    }

    private var bulkPinActionTitleWithCount: String {
        shouldPinSelectedNotes
            ? "Pin \(selectedNotes.count) Selected"
            : "Unpin \(selectedNotes.count) Selected"
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

    private func deleteSelectedNotes() {
        for selectedNote in selectedNotes {
            vm.deleteNote(selectedNote)
        }
        selectedNoteIDs.removeAll()
    }

    private func toggleSelection(for noteID: UUID) {
        if selectedNoteIDs.contains(noteID) {
            selectedNoteIDs.remove(noteID)
        } else {
            selectedNoteIDs.insert(noteID)
        }
    }

    private func isBulkNoteActionTarget(_ note: Note) -> Bool {
        editMode.isEditing
            && selectedNoteIDs.contains(note.id)
            && selectedNotes.count > 1
    }

    private func handleBulkNoteLongPress(_ note: Note) {
        guard isBulkNoteActionTarget(note) else {
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        noteActionDialogContext = .bulk
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

    private func exportSingleNote(_ note: Note) {
        do {
            let exportURLs = try vm.exportNotesForSharing([note])
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

private struct NoteContextPreview: View {
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            let contentPreview = noteContentPreviewText(for: note)
            if !contentPreview.isEmpty {
                Text(contentPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
