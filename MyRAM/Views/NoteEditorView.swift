// NoteEditorView.swift
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import VisionKit

#if targetEnvironment(macCatalyst)
private let defaultEditorTextFont = UIFont.systemFont(ofSize: 20)
#else
private let defaultEditorTextFont = UIFont.preferredFont(forTextStyle: .body)
#endif
private let editorCommitDelayNanoseconds: UInt64 = 500_000_000

enum EditorBufferOwner {
    case idle
    case localEditing
    case applyingRemoteSync
    case restoringHistory
    case resolvingConflict
}

enum EditorBufferReloadPolicy {
    static func shouldDeferRemoteRefresh(owner: EditorBufferOwner, hasPendingNoteCommit: Bool) -> Bool {
        owner == .localEditing && hasPendingNoteCommit
    }
}

enum EditorSelectionFormattingPolicy {
    static let largeSelectionFormattingThreshold = 2_000

    static func shouldDeferFullFormattingScan(selectionLength: Int) -> Bool {
        selectionLength > largeSelectionFormattingThreshold
    }
}

enum EditorTextPlacementResolver {
    static func caretRange(forTapLocation point: CGPoint, in textView: UITextView) -> NSRange {
        let textLength = textView.textStorage.length
        guard textLength > 0 else { return NSRange(location: 0, length: 0) }

        textView.layoutManager.ensureLayout(for: textView.textContainer)

        var location = point
        location.x -= textView.textContainerInset.left
        location.y -= textView.textContainerInset.top
        location.x -= textView.textContainer.lineFragmentPadding

        let characterIndex = textView.layoutManager.characterIndex(
            for: location,
            in: textView.textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return NSRange(location: min(max(characterIndex, 0), textLength), length: 0)
    }
}

struct DeferredRichTextContentEncoder {
    let encode: () -> Data?
}

enum EditorRichTextContentUpdate {
    case immediate(Data?)
    case deferred(DeferredRichTextContentEncoder)
}

enum EditorRichTextCommitPolicy {
    static func committedRichTextContentData(
        currentData: Data?,
        pendingEncoder: DeferredRichTextContentEncoder?
    ) -> Data? {
        pendingEncoder?.encode() ?? currentData
    }
}

struct NoteEditorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var vm: NotesViewModel
    let note: Note
    let onNewNote: (Note) -> Void
    var showsTopBar = true
    var toolbarBridge: NoteEditorToolbarBridge?
    var syncController: MyRAMSyncController? = nil
    var syncConflicts: [SyncConflictVersion] = []
    var currentNoteSearchText: Binding<String>? = nil
    var currentNoteSearchFocusToken = 0
    var onOpenSyncConflicts: (() -> Void)?
    @StateObject private var formattingController = TextFormattingController()
    
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var richTextContentData: Data?
    @State private var selectAllToggleToken = 0
    @State private var pinSelectionToggleToken = 0
    @State private var lookupSelectionToggleToken = 0
    @State private var appendUnpinnedThoughtToggleToken = 0
    @State private var pendingUnpinnedThoughtText = ""
    @State private var restoreContentToggleToken = 0
    @State private var captureSelectionToggleToken = 0
    @State private var boldToggleToken = 0
    @State private var italicToggleToken = 0
    @State private var underlineToggleToken = 0
    @State private var strikethroughToggleToken = 0
    @State private var checklistToggleToken = 0
    @State private var pasteAndMatchFormattingToggleToken = 0
    @State private var increaseFontSizeToggleToken = 0
    @State private var decreaseFontSizeToggleToken = 0
    @State private var textColorToggleToken = 0
    @State private var pendingTextUIColor: UIColor?
    @State private var pendingTextColorUsesDefault = false
    @State private var selectedTextUIColor: UIColor?
    @State private var formattingState = EditorFormattingState()
    @State private var showingFormattingControls = false
    @State private var showingUndoRedoActions = false
    @State private var isKeyboardVisible = false
    @State private var keyboardFocusToggleToken = 0
    @State private var activeUndoManager: UndoManager?
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var undoHistory: [NoteSnapshot] = []
    @State private var redoHistory: [NoteSnapshot] = []
    @State private var lastSnapshot = NoteSnapshot()
    @State private var isApplyingUndo = false
    @State private var isApplyingRemoteSyncUpdate = false
    @State private var selectedPickerItems: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var expandedAttachment: NotePhotoAttachment?
    @State private var areAttachmentsExpanded = false
    @State private var lookupRequest: LookupRequest?
    @State private var sharePayload: NoteSharePayload?
    @State private var exportErrorMessage: String?
    @State private var showingNearbySync = false
    @State private var selectedSyncConflict: SyncConflictVersion?
    @State private var isLocalCurrentNoteSearchPresented = false
    @State private var localCurrentNoteSearchText = ""
    @State private var debouncedCurrentNoteSearchText = ""
    @State private var currentNoteSearchMatches: [NoteSearchMatch] = []
    @State private var currentNoteSearchDebounceTask: Task<Void, Never>?
    @State private var selectedCurrentNoteMatchID: String?
    @State private var currentNoteSearchFocusRequest = 0
    @State private var showingCreateFolderPrompt = false
    @State private var newFolderName = ""
    @State private var showingTitleEditor = false
    @State private var titleDraft = ""
    @State private var arePinnedThoughtsExpanded = false
    @State private var editingPinnedThoughtID: UUID?
    @State private var editingPinnedTextDraftText = ""
    @State private var activeReorderPayload: String?
    @State private var activeReorderOffset: CGSize = .zero
    @State private var pendingReorderInsertionIndex: Int?
    @State private var reorderItemFrames: [String: CGRect] = [:]
    @State private var keyboardToast: KeyboardToast?
    @State private var keyboardToastTask: Task<Void, Never>?
    @State private var pendingNoteCommitTask: Task<Void, Never>?
    @State private var hasPendingNoteCommit = false
    @State private var editorBufferOwner: EditorBufferOwner = .idle
    @State private var deferRemoteRefreshUntilCommit = false
    @State private var pendingRichTextContentEncoder: DeferredRichTextContentEncoder?
    @FocusState private var isCurrentNoteSearchFocused: Bool
    @FocusState private var focusedPinnedThoughtID: UUID?
    @AppStorage("editorChromeStyle") private var editorChromeStyleRaw = EditorChromeStyle.standard.rawValue
    @AppStorage("pinnedHighlightColor") private var pinnedHighlightColorRaw = PinnedHighlightColor.yellow.rawValue
    
    var body: some View {
        NavigationStack {
            configuredEditorContent
        }
    }

    private var configuredEditorContent: some View {
        editorPresentationContent
            .confirmationDialog("Edit History", isPresented: $showingUndoRedoActions, titleVisibility: .visible) {
                Button("Undo") {
                    performUndo()
                }
                .disabled(!canPerformUndo)

                Button("Redo") {
                    performRedo()
                }
                .disabled(!canPerformRedo)
            }
            .alert("Unable to Export Note", isPresented: Binding(
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
            .alert("Edit Title", isPresented: $showingTitleEditor) {
                TextField("Title", text: $titleDraft)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    title = trimmed
                }
            } message: {
                Text("Update the note title.")
            }
    }

    private var editorPresentationContent: some View {
        editorLifecycleContent
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $selectedPickerItems,
                matching: .images,
                preferredItemEncoding: .automatic
            )
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                guard case let .success(urls) = result else { return }
                importImageFiles(from: urls)
            }
            .sheet(item: $lookupRequest) { request in
                ReferenceLookupView(term: request.term)
            }
            .sheet(item: $sharePayload) { payload in
                ActivityShareSheet(activityItems: payload.urls)
            }
            .sheet(isPresented: $showingNearbySync) {
                nearbySyncSheet
            }
            .sheet(item: $selectedSyncConflict) { conflict in
                syncConflictSheet(for: conflict)
            }
    }

    private var editorLifecycleContent: some View {
        editorChromeContent
            .onAppear(perform: initializeEditor)
            .onChange(of: title) { handleEditorChange() }
            .onChange(of: currentNoteSearchQuery) {
                scheduleCurrentNoteSearchUpdate()
            }
            .onChange(of: content) {
                scheduleCurrentNoteSearchUpdate()
            }
            .onChange(of: sortedPinnedTextSearchSignature) {
                scheduleCurrentNoteSearchUpdate()
            }
            .onChange(of: currentNoteSearchFocusToken) {
                presentCurrentNoteSearch(focusesField: false)
            }
            .onChange(of: currentNoteSearchMatches) {
                reconcileSelectedCurrentNoteMatch()
            }
            .onChange(of: selectedCurrentNoteMatchID) {
                handleSelectedCurrentNoteMatchChanged()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active {
                    commitActivePinnedThoughtEdit()
                    commitPendingNoteEdit()
                    dismissCurrentNoteSearchKeyboard()
                }
            }
            .onDisappear {
                clearCurrentNoteSearch()
                commitActivePinnedThoughtEdit()
                commitPendingNoteEdit()
            }
            .onChange(of: focusedPinnedThoughtID) { oldValue, newValue in
                guard oldValue != newValue else { return }
                if let oldValue {
                    commitPinnedThoughtEdit(withID: oldValue)
                }
            }
            .onChange(of: vm.activeNoteSyncRevision) {
                reloadNoteFromSync()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            .onChange(of: selectedPickerItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task {
                    await importSelectedPickerItems(newItems)
                    selectedPickerItems = []
                }
            }
    }

    private var editorChromeContent: some View {
        editorContent
            .padding()
            .background(editorChromeStyle.editorBackgroundColor.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                syncStatusOverlay
            }
            .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var syncStatusOverlay: some View {
        if let syncController {
            SyncStatusIndicator(syncController: syncController) {
                openNearbySync(onFallback: onOpenSyncConflicts)
            }
            .padding(.top, showsTopBar ? 58 : 14)
            .frame(maxWidth: 180)
        }
    }

    private func initializeEditor() {
        title = note.title
        content = note.content
        richTextContentData = note.richTextContentData
        lastSnapshot = currentNoteSnapshot()
        vm.recordNoteOpened(note)
        arePinnedThoughtsExpanded = vm.isPinnedThoughtsSectionExpanded(for: note)
        configureToolbarBridge()
    }

    @ViewBuilder
    private var nearbySyncSheet: some View {
        NavigationStack {
            if let syncController {
                NearbySyncView(
                    syncController: syncController,
                    style: editorChromeStyle
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
    }

    private func syncConflictSheet(for conflict: SyncConflictVersion) -> some View {
        SyncConflictDetailView(
            conflict: conflict,
            localText: vm.localText(forSyncConflict: conflict),
            onClose: {
                selectedSyncConflict = nil
            },
            onCopy: {
                copySyncConflict(conflict)
            },
            onRestore: {
                selectedSyncConflict = nil
                vm.restoreSyncConflict(conflict)
            },
            onReview: {
                selectedSyncConflict = nil
                vm.markSyncConflictReviewed(conflict)
            },
            onSaveMerged: { mergedText in
                selectedSyncConflict = nil
                vm.saveMergedSyncConflict(conflict, mergedText: mergedText)
            }
        )
        .syncConflictPresentationSizing()
    }

    private var editorContent: some View {
        ZStack {
            editorMainColumn

            if let expandedAttachment {
                ExpandedPhotoView(attachment: expandedAttachment) {
                    self.expandedAttachment = nil
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .zIndex(10)
            }
        }
    }

    private var editorMainColumn: some View {
        VStack(spacing: 12) {
            if showsTopBar {
                editorTopBar
            }

            if isCurrentNoteSearchPresented {
                currentNoteSearchControls
            }

            VStack(spacing: 8) {
                editorSurface
                editorControlStrip
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            attachmentStrip
        }
    }

    private var editorSurface: some View {
        VStack(spacing: 12) {
            if !showsTitleInTopBar {
                editorTitleHeader
            }

            syncConflictNotice
            pinnedThoughtsSection
            editorTextView
        }
        .padding(.top, editorChromeStyle.isChromeAccent ? 6 : 0)
        .padding(.horizontal, editorChromeStyle.isChromeAccent ? 6 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ChromeEditorTrim(style: editorChromeStyle))
    }

    private var editorTextView: some View {
        SelectableTextView(
            text: $content,
            richTextContentData: $richTextContentData,
            keyboardFocusToggleToken: keyboardFocusToggleToken,
            captureSelectionToggleToken: captureSelectionToggleToken,
            selectAllToggleToken: selectAllToggleToken,
            pinSelectionToggleToken: pinSelectionToggleToken,
            lookupSelectionToggleToken: lookupSelectionToggleToken,
            appendUnpinnedThoughtToggleToken: appendUnpinnedThoughtToggleToken,
            pendingUnpinnedThoughtText: pendingUnpinnedThoughtText,
            restoreContentToggleToken: restoreContentToggleToken,
            boldToggleToken: boldToggleToken,
            italicToggleToken: italicToggleToken,
            underlineToggleToken: underlineToggleToken,
            strikethroughToggleToken: strikethroughToggleToken,
            checklistToggleToken: checklistToggleToken,
            pasteAndMatchFormattingToggleToken: pasteAndMatchFormattingToggleToken,
            increaseFontSizeToggleToken: increaseFontSizeToggleToken,
            decreaseFontSizeToggleToken: decreaseFontSizeToggleToken,
            textColorToggleToken: textColorToggleToken,
            pendingTextUIColor: pendingTextUIColor,
            pendingTextColorUsesDefault: pendingTextColorUsesDefault,
            searchHighlightRange: selectedBodySearchRange,
            formattingController: formattingController,
            backgroundColor: editorChromeStyle.editorSurfaceUIColor,
            textColor: editorChromeStyle.editorTextUIColor,
            tintColor: editorChromeStyle.editorTintUIColor,
            onContentChanged: handleContentChanged,
            onUndoManagerChanged: updateActiveUndoManager,
            onFormattingStateChanged: handleFormattingStateChanged,
            onEditingFocusChanged: handleEditorFocusChanged,
            onEditorScrolled: dismissCurrentNoteSearchKeyboard,
            onPinSelection: pinSelectedText,
            onLookupSelection: presentLookup
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentNoteSearchControls: some View {
        HStack(spacing: 8) {
            if !usesExternalCurrentNoteSearch {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("Search Note", text: currentNoteSearchBinding)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.search)
                    .focused($isCurrentNoteSearchFocused)
                    .onSubmit {
                        dismissCurrentNoteSearchKeyboard()
                        selectFirstCurrentNoteMatchIfNeeded()
                    }
                    .accessibilityIdentifier("current-note-search-field")
            }

            Text(currentNoteSearchSummary)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(minWidth: 56, alignment: .trailing)
                .accessibilityIdentifier("current-note-search-count")

            Button {
                selectPreviousCurrentNoteMatch()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(currentNoteSearchMatches.isEmpty)
            .accessibilityLabel("Previous match")
            .accessibilityIdentifier("current-note-search-previous")

            Button {
                selectNextCurrentNoteMatch()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(currentNoteSearchMatches.isEmpty)
            .accessibilityLabel("Next match")
            .accessibilityIdentifier("current-note-search-next")

            Button {
                clearCurrentNoteSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
            .accessibilityIdentifier("current-note-search-close")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(editorChromeStyle.toolbarFillColor)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(editorChromeStyle.toolbarStrokeColor, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onChange(of: currentNoteSearchFocusRequest) {
            guard !usesExternalCurrentNoteSearch else { return }
            isCurrentNoteSearchFocused = true
        }
        .padding(.horizontal, showsTopBar ? 0 : 12)
    }

    private var currentNoteSearchBinding: Binding<String> {
        Binding(
            get: { currentNoteSearchQuery },
            set: { setCurrentNoteSearchQuery($0) }
        )
    }

    private var usesExternalCurrentNoteSearch: Bool {
        currentNoteSearchText != nil
    }

    private var isCurrentNoteSearchPresented: Bool {
        usesExternalCurrentNoteSearch
            ? !currentNoteSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : isLocalCurrentNoteSearchPresented
    }

    private var currentNoteSearchQuery: String {
        currentNoteSearchText?.wrappedValue ?? localCurrentNoteSearchText
    }

    private var selectedCurrentNoteMatch: NoteSearchMatch? {
        guard let selectedCurrentNoteMatchID else { return nil }
        return currentNoteSearchMatches.first { $0.id == selectedCurrentNoteMatchID }
    }

    private var selectedBodySearchRange: NSRange? {
        guard case .body = selectedCurrentNoteMatch?.region else { return nil }
        return selectedCurrentNoteMatch?.nsRangeInRenderedText
    }

    private var selectedPinnedTextSearchID: UUID? {
        guard case let .pinnedText(id) = selectedCurrentNoteMatch?.region else { return nil }
        return id
    }

    private var sortedPinnedTextSearchSignature: [String] {
        sortedPinnedThoughts.map { "\($0.id.uuidString):\($0.text)" }
    }

    private var currentNoteSearchSummary: String {
        let trimmed = debouncedCurrentNoteSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "0" }
        guard let selectedCurrentNoteMatchID,
              let index = currentNoteSearchMatches.firstIndex(where: { $0.id == selectedCurrentNoteMatchID }) else {
            return currentNoteSearchMatches.isEmpty ? "0" : "\(currentNoteSearchMatches.count)"
        }
        return "\(index + 1) of \(currentNoteSearchMatches.count)"
    }

    @ViewBuilder
    private var syncConflictNotice: some View {
        if !syncConflicts.isEmpty, let onOpenSyncConflicts {
            SyncConflictNotice(
                conflictCount: syncConflicts.count,
                onOpen: {
                    if let firstConflict = syncConflicts.first {
                        selectedSyncConflict = firstConflict
                    } else {
                        onOpenSyncConflicts()
                    }
                }
            )
        }
    }

    private var editorControlStrip: some View {
        VStack(spacing: 8) {
            if showingFormattingControls {
                overflowFormattingControls
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let keyboardToast {
                Text(keyboardToast.message)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            collapsedEditorControls
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var sortedAttachments: [NotePhotoAttachment] {
        note.photoAttachments.sorted { $0.createdAt < $1.createdAt }
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if !sortedAttachments.isEmpty {
            AttachmentStrip(
                attachments: sortedAttachments,
                isExpanded: $areAttachmentsExpanded,
                backgroundColor: editorChromeStyle.editorSurfaceColor,
                onOpen: { attachment in
                    expandedAttachment = attachment
                },
                onDelete: { attachment in
                    vm.removePhotoAttachment(attachment, from: note)
                }
            )
        }
    }

    private var sortedPinnedThoughts: [PinnedThought] {
        vm.sortedPinnedThoughts(for: note)
    }

    private var canPerformUndo: Bool {
        canUndo || vm.hasUndoableAction
    }

    private var canPerformRedo: Bool {
        canRedo
    }

    @ViewBuilder
    private var pinnedThoughtsSection: some View {
        if sortedPinnedThoughts.isEmpty {
            HStack {
                Spacer()
                Button {
                    addPinnedThoughtFromSection()
                } label: {
                    Text("Pinned (0)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(pinnedHighlightText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .modifier(ChromePinnedBadge(style: editorChromeStyle, pinnedColor: pinnedHighlightColor))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pinned-thoughts-add")
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            arePinnedThoughtsExpanded.toggle()
                            vm.setPinnedThoughtsSectionExpanded(arePinnedThoughtsExpanded, for: note)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: arePinnedThoughtsExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                            Text("Pinned")
                                .font(.subheadline.weight(.semibold))
                            Text("\(sortedPinnedThoughts.count)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .modifier(ChromeCountBadge(style: editorChromeStyle))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .modifier(ChromeControlPlate(style: editorChromeStyle, cornerRadius: 8))
                    .accessibilityIdentifier("pinned-thoughts-toggle")

                    Spacer()

                    Button("Add") {
                        addPinnedThoughtFromSection()
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .modifier(ChromeControlPlate(style: editorChromeStyle, cornerRadius: 8))
                    .accessibilityIdentifier("pinned-thoughts-add")
                }

                if arePinnedThoughtsExpanded {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(sortedPinnedThoughts.enumerated()), id: \.element.id) { index, thought in
                                    if shouldShowReorderIndicator(at: index) {
                                        ReorderInsertionIndicator()
                                    }
                                    pinnedThoughtRow(thought, index: index, count: sortedPinnedThoughts.count)
                                        .id(thought.id)
                                }
                                if shouldShowReorderIndicator(at: sortedPinnedThoughts.count) {
                                    ReorderInsertionIndicator()
                                }
                            }
                        }
                        .scrollIndicators(.visible)
                        .frame(maxHeight: 180)
                        .onChange(of: selectedPinnedTextSearchID) { _, pinnedTextID in
                            guard let pinnedTextID else { return }
                            withAnimation(.easeInOut(duration: 0.18)) {
                                proxy.scrollTo(pinnedTextID, anchor: .center)
                            }
                        }
                        .onAppear {
                            guard let selectedPinnedTextSearchID else { return }
                            proxy.scrollTo(selectedPinnedTextSearchID, anchor: .center)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedPinnedThoughts.prefix(1), id: \.id) { thought in
                            Text(thought.text.isEmpty ? "Pinned" : thought.text)
                                .font(.body)
                                .foregroundStyle(pinnedHighlightText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(ChromePinnedSurface(style: editorChromeStyle, pinnedColor: pinnedHighlightColor))
                }
            }
            .padding(10)
            .modifier(ChromePinnedPanel(style: editorChromeStyle))
            .accessibilityIdentifier("pinned-thoughts-section")
            .onPreferenceChange(ReorderItemFramePreferenceKey.self) { frames in
                reorderItemFrames = frames
            }
        }
    }

    private func pinnedThoughtRow(_ thought: PinnedThought, index: Int, count: Int) -> some View {
        let isSelectedSearchMatch = selectedPinnedTextSearchID == thought.id
        return HStack(alignment: .top, spacing: 8) {
            ReorderDragHandle(
                payload: thought.id.uuidString,
                activePayload: $activeReorderPayload,
                accessibilityIdentifier: "pinned-thought-drag-handle",
                onChanged: { location, translation in
                    activeReorderOffset = translation
                    if let insertionIndex = reorderInsertionIndex(for: location) {
                        pendingReorderInsertionIndex = insertionIndex
                    }
                },
                onEnded: {
                    commitPendingPinnedThoughtMove()
                    activeReorderPayload = nil
                    activeReorderOffset = .zero
                    pendingReorderInsertionIndex = nil
                }
            )

            if editingPinnedThoughtID == thought.id {
                TextField("Pinned", text: $editingPinnedTextDraftText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(pinnedHighlightText)
                .tint(pinnedHighlightText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($focusedPinnedThoughtID, equals: thought.id)
                .onSubmit {
                    commitPinnedThoughtEdit(thought)
                }
                .onAppear {
                    focusedPinnedThoughtID = thought.id
                }
                .accessibilityIdentifier("pinned-thought-text")
            } else {
                Text(thought.text.isEmpty ? "Pinned" : thought.text)
                    .font(.subheadline)
                    .foregroundStyle(thought.text.isEmpty ? pinnedHighlightPlaceholderText : pinnedHighlightText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)

                Image(systemName: "pencil")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .accessibilityIdentifier("pinned-thought-edit-hint")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .modifier(ChromePinnedSurface(style: editorChromeStyle, pinnedColor: pinnedHighlightColor))
        .overlay {
            if isSelectedSearchMatch {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            beginPinnedThoughtEditing(thought)
        }
        .contextMenu {
            Button("Unpin") {
                unpinThoughtToBody(thought)
            }

            Button("Delete", role: .destructive) {
                deletePinnedParagraph(thought)
            }
        }
        .reorderItemFrame(payload: thought.id.uuidString)
        .offset(activeReorderPayload == thought.id.uuidString ? activeReorderOffset : .zero)
        .zIndex(activeReorderPayload == thought.id.uuidString ? 1 : 0)
        .accessibilityElement(children: .contain)
    }

    private func reorderInsertionIndex(for location: CGPoint) -> Int? {
        let orderedThoughts = sortedPinnedThoughts
        guard !orderedThoughts.isEmpty,
              let activeReorderPayload,
              orderedThoughts.contains(where: { $0.id.uuidString == activeReorderPayload }) else { return nil }

        for (index, thought) in orderedThoughts.enumerated() {
            let payload = thought.id.uuidString
            guard payload != activeReorderPayload,
                  let frame = reorderItemFrames[payload] else { continue }
            if location.y <= frame.midY {
                return index
            }
        }

        return orderedThoughts.count
    }

    private func shouldShowReorderIndicator(at insertionIndex: Int) -> Bool {
        guard let activeReorderPayload,
              let pendingReorderInsertionIndex,
              let currentIndex = sortedPinnedThoughts.firstIndex(where: { $0.id.uuidString == activeReorderPayload }) else {
            return false
        }

        return pendingReorderInsertionIndex == insertionIndex
            && insertionIndex != currentIndex
            && insertionIndex != currentIndex + 1
    }

    private func commitPendingPinnedThoughtMove() {
        guard let activeReorderPayload,
              let pendingReorderInsertionIndex,
              shouldShowReorderIndicator(at: pendingReorderInsertionIndex),
              let draggedID = UUID(uuidString: activeReorderPayload),
              let draggedThought = note.pinnedThoughts.first(where: { $0.id == draggedID }) else {
            return
        }

        vm.movePinnedThought(draggedThought, toIndex: pendingReorderInsertionIndex)
    }

    private func beginPinnedThoughtEditing(_ thought: PinnedThought) {
        if let editingPinnedThoughtID, editingPinnedThoughtID != thought.id {
            commitPinnedThoughtEdit(withID: editingPinnedThoughtID)
        }
        editingPinnedTextDraftText = thought.text
        editingPinnedThoughtID = thought.id
        focusedPinnedThoughtID = thought.id
    }

    private func commitActivePinnedThoughtEdit() {
        guard let editingPinnedThoughtID else { return }
        commitPinnedThoughtEdit(withID: editingPinnedThoughtID)
    }

    private var hasActivePinnedThoughtEdit: Bool {
        editingPinnedThoughtID != nil
    }

    private func commitPinnedThoughtEdit(_ thought: PinnedThought) {
        commitPinnedThoughtEdit(withID: thought.id)
    }

    private func commitPinnedThoughtEdit(withID thoughtID: UUID) {
        guard editingPinnedThoughtID == thoughtID else { return }
        let draft = editingPinnedTextDraftText
        guard let thought = note.pinnedThoughts.first(where: { $0.id == thoughtID }) else {
            editingPinnedThoughtID = nil
            editingPinnedTextDraftText = ""
            if focusedPinnedThoughtID == thoughtID {
                focusedPinnedThoughtID = nil
            }
            return
        }

        vm.updatePinnedThought(thought, text: draft)
        editingPinnedThoughtID = nil
        editingPinnedTextDraftText = ""
        if focusedPinnedThoughtID == thoughtID {
            focusedPinnedThoughtID = nil
        }
        applyDeferredRemoteRefreshIfNeeded()
    }

    private func pinSelectedText(_ selectedText: String) -> Bool {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showKeyboardToast(KeyboardToast(message: "Select text to pin"))
            return false
        }
        arePinnedThoughtsExpanded = true
        vm.setPinnedThoughtsSectionExpanded(true, for: note)
        guard let pinnedThought = vm.addPinnedThought(to: note, text: trimmed) else { return false }
        beginPinnedThoughtEditing(pinnedThought)
        return true
    }

    private func addPinnedThoughtFromSection() {
        commitActivePinnedThoughtEdit()
        arePinnedThoughtsExpanded = true
        vm.setPinnedThoughtsSectionExpanded(true, for: note)
        guard let pinnedThought = vm.addPinnedThought(to: note) else { return }
        beginPinnedThoughtEditing(pinnedThought)
    }

    private func configureToolbarBridge() {
        toolbarBridge?.title = title.isEmpty ? "Untitled" : title
        toolbarBridge?.canUndo = canPerformUndo
        toolbarBridge?.canRedo = canPerformRedo
        toolbarBridge?.editTitle = {
            titleDraft = title
            showingTitleEditor = true
        }
        toolbarBridge?.undo = { performUndo() }
        toolbarBridge?.redo = { performRedo() }
        toolbarBridge?.newNote = {
            commitActivePinnedThoughtEdit()
            commitPendingNoteEdit()
            onNewNote(vm.createNewNote())
        }
        toolbarBridge?.newFolder = {
            newFolderName = ""
            showingCreateFolderPrompt = true
        }
        toolbarBridge?.exportNote = {
            commitActivePinnedThoughtEdit()
            commitPendingNoteEdit()
            exportCurrentNote()
        }
        toolbarBridge?.importFromPhotoLibrary = { showingPhotoPicker = true }
        toolbarBridge?.importImageFile = { showingFileImporter = true }
        toolbarBridge?.deleteNote = {
            vm.deleteNote(note)
            dismiss()
        }
    }

    private func presentCurrentNoteSearch(focusesField: Bool = true) {
        isLocalCurrentNoteSearchPresented = true
        scheduleCurrentNoteSearchUpdate()
        selectFirstCurrentNoteMatchIfNeeded()
        if focusesField && !usesExternalCurrentNoteSearch {
            currentNoteSearchFocusRequest += 1
        }
    }

    private func clearCurrentNoteSearch() {
        currentNoteSearchDebounceTask?.cancel()
        isLocalCurrentNoteSearchPresented = false
        dismissCurrentNoteSearchKeyboard()
        if let currentNoteSearchText {
            currentNoteSearchText.wrappedValue = ""
        } else {
            localCurrentNoteSearchText = ""
        }
        debouncedCurrentNoteSearchText = ""
        currentNoteSearchMatches = []
        selectedCurrentNoteMatchID = nil
    }

    private func dismissCurrentNoteSearchKeyboard() {
        isCurrentNoteSearchFocused = false
    }

    private func setCurrentNoteSearchQuery(_ query: String) {
        if let currentNoteSearchText {
            currentNoteSearchText.wrappedValue = query
        } else {
            localCurrentNoteSearchText = query
            isLocalCurrentNoteSearchPresented = true
        }
    }

    private func scheduleCurrentNoteSearchUpdate() {
        currentNoteSearchDebounceTask?.cancel()
        let query = currentNoteSearchQuery
        let bodyText = content
        let pinnedTexts = sortedPinnedThoughts.map { NoteSearchPinnedText(id: $0.id, text: $0.text) }
        currentNoteSearchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let matches = NoteSearchMatcher.matches(
                in: bodyText,
                pinnedTexts: pinnedTexts,
                query: query
            )
            await MainActor.run {
                debouncedCurrentNoteSearchText = query
                currentNoteSearchMatches = matches
                reconcileSelectedCurrentNoteMatch()
            }
        }
    }

    private func reconcileSelectedCurrentNoteMatch() {
        guard !currentNoteSearchMatches.isEmpty else {
            selectedCurrentNoteMatchID = nil
            return
        }

        if let selectedCurrentNoteMatchID,
           currentNoteSearchMatches.contains(where: { $0.id == selectedCurrentNoteMatchID }) {
            return
        }

        selectedCurrentNoteMatchID = currentNoteSearchMatches.first?.id
    }

    private func selectFirstCurrentNoteMatchIfNeeded() {
        if selectedCurrentNoteMatchID == nil {
            reconcileSelectedCurrentNoteMatch()
        }
    }

    private func selectPreviousCurrentNoteMatch() {
        moveSelectedCurrentNoteMatch(by: -1)
    }

    private func selectNextCurrentNoteMatch() {
        moveSelectedCurrentNoteMatch(by: 1)
    }

    private func moveSelectedCurrentNoteMatch(by delta: Int) {
        guard !currentNoteSearchMatches.isEmpty else { return }
        let currentIndex = selectedCurrentNoteMatchID
            .flatMap { selectedID in currentNoteSearchMatches.firstIndex { $0.id == selectedID } }
            ?? (delta > 0 ? -1 : 0)
        let nextIndex = (currentIndex + delta + currentNoteSearchMatches.count) % currentNoteSearchMatches.count
        selectedCurrentNoteMatchID = currentNoteSearchMatches[nextIndex].id
    }

    private func handleSelectedCurrentNoteMatchChanged() {
        guard let selectedCurrentNoteMatch else { return }
        if case .pinnedText = selectedCurrentNoteMatch.region, !arePinnedThoughtsExpanded {
            arePinnedThoughtsExpanded = true
            vm.setPinnedThoughtsSectionExpanded(true, for: note)
        }
    }

    private func handleEditorFocusChanged(_ isFocused: Bool) {
        toolbarBridge?.isEditorFocused = isFocused
        if isFocused {
            dismissCurrentNoteSearchKeyboard()
        }
    }

    private func unpinThoughtToBody(_ thought: PinnedThought) {
        commitPinnedThoughtEdit(thought)
        let unpinnedText = thought.text.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.unpinThought(thought)
        guard !unpinnedText.isEmpty else { return }
        pendingUnpinnedThoughtText = unpinnedText
        appendUnpinnedThoughtToggleToken += 1
    }

    private func deletePinnedParagraph(_ thought: PinnedThought) {
        if editingPinnedThoughtID == thought.id {
            editingPinnedThoughtID = nil
            editingPinnedTextDraftText = ""
        }
        if focusedPinnedThoughtID == thought.id {
            focusedPinnedThoughtID = nil
        }
        vm.deletePinnedParagraph(thought)
    }

    private var editorTopBar: some View {
        GeometryReader { proxy in
            let layout = topBarActionLayout(totalWidth: proxy.size.width)
            ChromeActionBar(style: editorChromeStyle) {
                if showsTitleInTopBar {
                    titleEditorButton
                        .frame(maxWidth: max(130, estimatedTitleWidth), alignment: .leading)
                }

                Spacer(minLength: 0)

                ForEach(layout.visibleActions, id: \.self) { action in
                    topBarVisibleAction(for: action)
                }

                Menu {
                    ForEach(layout.overflowActions, id: \.self) { action in
                        overflowMenuItem(for: action)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .modifier(ChromeControlPlate(style: editorChromeStyle))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary)
                }
                .tint(.primary)
                .accessibilityIdentifier("note-editor-more")
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: 42)
    }

    private var showsTitleInTopBar: Bool {
#if targetEnvironment(macCatalyst)
        false
#else
        showsTopBar
#endif
    }

    private var editorTitleHeader: some View {
        HStack {
            titleEditorButton
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleEditorButton: some View {
        Button {
            titleDraft = title
            showingTitleEditor = true
        } label: {
            HStack(spacing: 6) {
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(title.isEmpty ? .secondary : .primary)
                    .italic(title.isEmpty)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .allowsTightening(true)
                Image(systemName: "pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("edit-note-title")
        .layoutPriority(1)
    }

    private var editorChromeStyle: EditorChromeStyle {
        EditorChromeStyle(rawValue: editorChromeStyleRaw) ?? .standard
    }

    private var pinnedHighlightColor: PinnedHighlightColor {
        PinnedHighlightColor(rawValue: pinnedHighlightColorRaw) ?? .yellow
    }

    private var pinnedHighlightText: Color {
        PinnedHighlightPalette.text(for: pinnedHighlightColor)
    }

    private var pinnedHighlightPlaceholderText: Color {
        PinnedHighlightPalette.placeholderText(for: pinnedHighlightColor)
    }

    private func topBarActionLayout(totalWidth: CGFloat) -> TopBarActionLayout {
        let promotableActions = NoteEditorOverflowAction.priorityOrder.filter { $0 != .deleteNote }
        let minimumTitleWidth: CGFloat = 130
        let titleWidth = max(minimumTitleWidth, estimatedTitleWidth)
        let overflowButtonWidth: CGFloat = 28
        let actionButtonWidth: CGFloat = 28
        let interItemSpacing: CGFloat = 8
        let horizontalPadding: CGFloat = 20

        let usableWidth = max(0, totalWidth - horizontalPadding)
        let titleAvailableWidth = max(0, usableWidth - overflowButtonWidth - interItemSpacing)
        var remainingWidth = titleWidth > titleAvailableWidth
            ? 0
            : max(0, titleAvailableWidth - titleWidth)
        var visibleActions: [NoteEditorOverflowAction] = []
        var overflowActions: [NoteEditorOverflowAction] = []

        for action in promotableActions {
            let neededWidth = actionButtonWidth + (visibleActions.isEmpty ? 0 : interItemSpacing)
            if remainingWidth >= neededWidth {
                visibleActions.append(action)
                remainingWidth -= neededWidth
            } else {
                overflowActions.append(action)
            }
        }

        overflowActions.append(.deleteNote)
        return TopBarActionLayout(visibleActions: visibleActions, overflowActions: overflowActions)
    }

    private var estimatedTitleWidth: CGFloat {
        let displayTitle = title.isEmpty ? "Untitled" : title
        let titleFont = UIFont.preferredFont(forTextStyle: .headline)
        let textWidth = (displayTitle as NSString).size(withAttributes: [.font: titleFont]).width
        return ceil(textWidth) + 26
    }

    @ViewBuilder
    private func topBarVisibleAction(for action: NoteEditorOverflowAction) -> some View {
        switch action {
        case .newNote:
            topBarActionButton(systemImage: "square.and.pencil", identifier: "topbar-new-note") {
                commitActivePinnedThoughtEdit()
                commitPendingNoteEdit()
                onNewNote(vm.createNewNote())
            }
        case .newFolder:
            topBarActionButton(systemImage: "folder.badge.plus", identifier: "topbar-new-folder") {
                newFolderName = ""
                showingCreateFolderPrompt = true
            }
        case .exportNote:
            topBarActionButton(systemImage: "square.and.arrow.up", identifier: "topbar-export-note") {
                commitActivePinnedThoughtEdit()
                commitPendingNoteEdit()
                exportCurrentNote()
            }
        case .attachments:
            Menu {
                attachmentImportMenuItems
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .modifier(ChromeControlPlate(style: editorChromeStyle))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
            }
            .tint(.primary)
            .accessibilityIdentifier("topbar-attachments")
        case .search:
            topBarActionButton(systemImage: "magnifyingglass", identifier: "topbar-search-note") {
                presentCurrentNoteSearch()
            }
        case .deleteNote:
            EmptyView()
        }
    }

    private func topBarActionButton(
        systemImage: String,
        identifier: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 28)
                .modifier(ChromeControlPlate(style: editorChromeStyle))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .opacity(isDisabled ? 0.4 : 1)
        .disabled(isDisabled)
        .accessibilityIdentifier(identifier)
    }

    private func updateActiveUndoManager(_ undoManager: UndoManager?) {
        activeUndoManager = undoManager
        refreshUndoState()
    }

    private func refreshUndoState() {
        DispatchQueue.main.async {
            canUndo = (activeUndoManager?.canUndo ?? false) || !undoHistory.isEmpty
            canRedo = (activeUndoManager?.canRedo ?? false) || !redoHistory.isEmpty
            toolbarBridge?.canUndo = canPerformUndo
            toolbarBridge?.canRedo = canPerformRedo
        }
    }

    private func currentNoteSnapshot() -> NoteSnapshot {
        NoteSnapshot(
            title: title,
            content: content,
            richTextContentData: richTextContentData,
            pinnedThoughts: sortedPinnedThoughts.map {
                PinnedThoughtSnapshot(
                    text: $0.text,
                    order: $0.order,
                    isCollapsed: $0.isCollapsed
                )
            }
        )
    }

    private func scheduleNoteCommit() {
        hasPendingNoteCommit = true
        pendingNoteCommitTask?.cancel()
        pendingNoteCommitTask = Task {
            try? await Task.sleep(nanoseconds: editorCommitDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                commitPendingNoteEdit()
            }
        }
    }

    private func cancelPendingNoteCommit() {
        pendingNoteCommitTask?.cancel()
        pendingNoteCommitTask = nil
        hasPendingNoteCommit = false
    }

    private func commitPendingNoteEdit() {
        guard hasPendingNoteCommit else { return }
        cancelPendingNoteCommit()
        let committedRichTextContentData = EditorRichTextCommitPolicy.committedRichTextContentData(
            currentData: richTextContentData,
            pendingEncoder: pendingRichTextContentEncoder
        )
        pendingRichTextContentEncoder = nil
        richTextContentData = committedRichTextContentData
        vm.commitNoteEdit(
            note,
            title: title,
            content: content,
            richTextContentData: committedRichTextContentData
        )
        vm.recordNoteEdited(note)
        if editorBufferOwner == .localEditing {
            editorBufferOwner = .idle
        }
        lastSnapshot = currentNoteSnapshot()
        applyDeferredRemoteRefreshIfNeeded()
    }

    private func handleEditorChange() {
        guard !isApplyingRemoteSyncUpdate else { return }
        let currentSnapshot = currentNoteSnapshot()
        guard currentSnapshot != lastSnapshot else {
            refreshUndoState()
            return
        }

        if !isApplyingUndo {
            undoHistory.append(lastSnapshot)
            redoHistory.removeAll()
            if undoHistory.count > 200 {
                undoHistory.removeFirst(undoHistory.count - 200)
            }
        }
        lastSnapshot = currentSnapshot
        editorBufferOwner = .localEditing
        vm.recordActiveNoteTextEdited(note)
        scheduleNoteCommit()
        toolbarBridge?.title = title.isEmpty ? "Untitled" : title
        refreshUndoState()
    }

    private func handleContentChanged(_ plainText: String, _ richTextUpdate: EditorRichTextContentUpdate) {
        content = plainText
        switch richTextUpdate {
        case .immediate(let richTextData):
            pendingRichTextContentEncoder = nil
            richTextContentData = richTextData
        case .deferred(let encoder):
            pendingRichTextContentEncoder = encoder
        }
        handleEditorChange()
    }

    private func reloadNoteFromSync() {
        guard !hasActivePinnedThoughtEdit else {
            deferRemoteRefreshUntilCommit = true
            return
        }

        guard !EditorBufferReloadPolicy.shouldDeferRemoteRefresh(
            owner: editorBufferOwner,
            hasPendingNoteCommit: hasPendingNoteCommit
        ) else {
            deferRemoteRefreshUntilCommit = true
            return
        }

        applyRemoteNoteRefresh()
    }

    private func applyDeferredRemoteRefreshIfNeeded() {
        guard deferRemoteRefreshUntilCommit else { return }
        deferRemoteRefreshUntilCommit = false
        applyRemoteNoteRefresh()
    }

    private func applyRemoteNoteRefresh() {
        guard vm.currentNote?.id == note.id,
              let refreshedNote = vm.refreshedNote(withID: note.id) else { return }
        cancelPendingNoteCommit()
        editorBufferOwner = .applyingRemoteSync
        isApplyingRemoteSyncUpdate = true
        title = refreshedNote.title
        content = refreshedNote.content
        richTextContentData = refreshedNote.richTextContentData
        restoreContentToggleToken += 1
        editingPinnedThoughtID = nil
        focusedPinnedThoughtID = nil
        editingPinnedTextDraftText = ""
        lastSnapshot = currentNoteSnapshot()
        toolbarBridge?.title = title.isEmpty ? "Untitled" : title
        refreshUndoState()
        DispatchQueue.main.async {
            isApplyingRemoteSyncUpdate = false
            if editorBufferOwner == .applyingRemoteSync {
                editorBufferOwner = .idle
            }
        }
    }

    private func handleFormattingStateChanged(_ state: EditorFormattingState) {
        formattingState = state
        guard !showingFormattingControls else { return }

        if let color = state.foregroundColor {
            selectedTextUIColor = color
        } else {
            selectedTextUIColor = nil
        }
    }

    private func undoLastEdit() {
        if !undoHistory.isEmpty {
            undoSnapshotEdit()
            return
        }

        if activeUndoManager?.canUndo == true {
            isApplyingUndo = true
            activeUndoManager?.undo()
            DispatchQueue.main.async {
                isApplyingUndo = false
                lastSnapshot = currentNoteSnapshot()
                trimUndoHistory(afterRestoring: lastSnapshot)
                refreshUndoState()
            }
            return
        }

        undoSnapshotEdit()
    }

    private func undoSnapshotEdit() {
        guard let snapshot = undoHistory.popLast() else {
            refreshUndoState()
            return
        }

        let currentSnapshot = currentNoteSnapshot()
        redoHistory.append(currentSnapshot)

        isApplyingUndo = true
        restore(snapshot)
        DispatchQueue.main.async {
            isApplyingUndo = false
            refreshUndoState()
        }
    }

    private func redoLastEdit() {
        if !redoHistory.isEmpty {
            redoSnapshotEdit()
            return
        }

        if activeUndoManager?.canRedo == true {
            isApplyingUndo = true
            activeUndoManager?.redo()
            DispatchQueue.main.async {
                isApplyingUndo = false
                lastSnapshot = currentNoteSnapshot()
                refreshUndoState()
            }
            return
        }

        redoSnapshotEdit()
    }

    private func redoSnapshotEdit() {
        guard let snapshot = redoHistory.popLast() else {
            refreshUndoState()
            return
        }

        let currentSnapshot = currentNoteSnapshot()
        undoHistory.append(currentSnapshot)

        isApplyingUndo = true
        restore(snapshot)
        DispatchQueue.main.async {
            isApplyingUndo = false
            refreshUndoState()
        }
    }

    private func restore(_ snapshot: NoteSnapshot) {
        editorBufferOwner = .restoringHistory
        title = snapshot.title
        content = snapshot.content
        richTextContentData = snapshot.richTextContentData
        restoreContentToggleToken += 1
        restorePinnedThoughts(snapshot.pinnedThoughts)
        lastSnapshot = snapshot
        cancelPendingNoteCommit()
        vm.commitNoteEdit(
            note,
            title: snapshot.title,
            content: snapshot.content,
            richTextContentData: snapshot.richTextContentData
        )
        vm.recordNoteEdited(note)
        editorBufferOwner = .idle
    }

    private func restorePinnedThoughts(_ snapshots: [PinnedThoughtSnapshot]) {
        editingPinnedTextDraftText = ""
        for thought in sortedPinnedThoughts {
            vm.unpinThought(thought)
        }

        for snapshot in snapshots.sorted(by: { $0.order < $1.order }) {
            guard let thought = vm.addPinnedThought(to: note, text: snapshot.text) else { continue }
            if snapshot.isCollapsed {
                vm.setPinnedThoughtCollapsed(thought, isCollapsed: true)
            }
        }
        editingPinnedThoughtID = nil
        focusedPinnedThoughtID = nil
    }

    private func performUndo() {
        commitActivePinnedThoughtEdit()
        if canUndo {
            undoLastEdit()
        } else {
            vm.undoLastAction()
        }
        refreshUndoState()
    }

    private func performRedo() {
        commitActivePinnedThoughtEdit()
        redoLastEdit()
        refreshUndoState()
    }

    private func trimUndoHistory(afterRestoring snapshot: NoteSnapshot) {
        guard let restoredIndex = undoHistory.lastIndex(of: snapshot) else { return }
        undoHistory.removeSubrange(restoredIndex...)
    }

    private func importImageFiles(from urls: [URL]) {
        var addedAttachment = false
        for url in urls {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            guard let data = try? Data(contentsOf: url),
                  let normalizedData = normalizedImageData(from: data) else {
                continue
            }

            vm.addPhotoAttachment(to: note, imageData: normalizedData)
            addedAttachment = true
        }

        if addedAttachment {
            areAttachmentsExpanded = true
        }
    }

    private func importSelectedPickerItems(_ items: [PhotosPickerItem]) async {
        var addedAttachment = false
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let normalizedData = normalizedImageData(from: data) else {
                continue
            }

            vm.addPhotoAttachment(to: note, imageData: normalizedData)
            addedAttachment = true
        }

        if addedAttachment {
            areAttachmentsExpanded = true
        }
    }

    private func normalizedImageData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.85) ?? data
    }

    private func openNearbySync(onFallback: (() -> Void)? = nil) {
#if targetEnvironment(macCatalyst)
        onFallback?()
#else
        if syncController != nil {
            showingNearbySync = true
        } else {
            onFallback?()
        }
#endif
    }

    private func copySyncConflict(_ conflict: SyncConflictVersion) {
        UIPasteboard.general.string = conflict.remoteText
    }

    private var collapsedEditorControls: some View {
        desktopOrMobileEditorControls
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if editorChromeStyle == .chromeAccent {
                    Capsule().fill(chromeAccentGradient(for: colorScheme))
                } else {
                    Capsule().fill(editorChromeStyle.toolbarFillColor)
                }
            }
            .overlay {
                if editorChromeStyle == .chromeAccent {
                    Capsule()
                        .stroke(chromeAccentToolbarTrimGradient(for: colorScheme), lineWidth: 0.9)
                } else {
                    Capsule()
                        .stroke(editorChromeStyle.toolbarStrokeColor, lineWidth: 1)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("keyboard-control-bar")
    }

    @ViewBuilder
    private var desktopOrMobileEditorControls: some View {
#if targetEnvironment(macCatalyst)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                inlineActionButton(systemImage: "pin", identifier: "keyboard-control-pin") {
                    pinSelectionToggleToken += 1
                }

                desktopInlineFormattingControls
            }
        }
        .frame(maxWidth: 560)
#else
        HStack(spacing: 8) {
            inlineActionButton(
                systemImage: isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                identifier: "keyboard-control-toggle"
            ) {
                if isKeyboardVisible {
                    dismissKeyboard()
                } else {
                    keyboardFocusToggleToken += 1
                }
            }
            inlineActionButton(systemImage: "arrow.uturn.backward.circle", identifier: "keyboard-control-history") {
                showingUndoRedoActions = true
            }
            .opacity((canPerformUndo || canPerformRedo) ? 1 : 0.4)
            .disabled(!canPerformUndo && !canPerformRedo)

            inlineActionButton(systemImage: "pin", identifier: "keyboard-control-pin") {
                pinSelectionToggleToken += 1
            }
            inlineActionButton(systemImage: "book", identifier: "keyboard-control-define") {
                lookupSelectionToggleToken += 1
            }

            inlineActionButton(systemImage: "scissors", identifier: "keyboard-control-cut") {
                performResponderAction(#selector(UIResponder.cut(_:)))
            }
            inlineActionButton(systemImage: "doc.on.doc", identifier: "keyboard-control-copy") {
                performKeyboardAction(
                    #selector(UIResponder.copy(_:)),
                    toast: KeyboardToast(message: "Copied")
                )
            }
            inlinePasteMenu
            inlineActionButton(systemImage: "selection.pin.in.out", identifier: "keyboard-control-select-all") {
                selectAllToggleToken += 1
            }
            inlineActionButton(systemImage: "checkmark.square", identifier: "keyboard-control-checklist") {
                checklistToggleToken += 1
            }

            Button {
                captureSelectionToggleToken += 1
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingFormattingControls.toggle()
                }
            } label: {
                Image(systemName: showingFormattingControls ? "xmark.circle" : "ellipsis.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .modifier(ChromeControlPlate(style: editorChromeStyle, cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("keyboard-control-overflow-toggle")
        }
#endif
    }

    private var desktopInlineFormattingControls: some View {
        HStack(spacing: 8) {
            formattingToggleButton(
                label: "B",
                isActive: formattingState.bold,
                identifier: "format-bold-toggle"
            ) {
                boldToggleToken += 1
            }
            formattingToggleButton(
                label: "I",
                isActive: formattingState.italic,
                identifier: "format-italic-toggle"
            ) {
                italicToggleToken += 1
            }
            formattingToggleButton(
                label: "U",
                isActive: formattingState.underline,
                identifier: "format-underline-toggle"
            ) {
                underlineToggleToken += 1
            }
            formattingToggleButton(
                label: "S",
                isActive: formattingState.strikethrough,
                identifier: "format-strikethrough-toggle",
                isStrikethroughLabel: true
            ) {
                strikethroughToggleToken += 1
            }

            inlineActionButton(systemImage: "checkmark.square", identifier: "format-checklist-toggle") {
                checklistToggleToken += 1
            }

            textColorMenu(controlSize: 26, swatchSize: 18)
        }
    }

    private func textColorMenu(controlSize: CGFloat, swatchSize: CGFloat) -> some View {
        Menu {
            Button {
                applyDefaultTextColor()
            } label: {
                Label("Auto Text Color", systemImage: "textformat")
            }
            .accessibilityIdentifier("format-color-default")

            ForEach(textColorSwatches) { swatch in
                Button {
                    applyTextColor(swatch.uiColor)
                } label: {
                    Label(swatch.name, systemImage: "circle.fill")
                }
                .accessibilityIdentifier("format-color-\(swatch.id)")
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(uiColor: selectedTextUIColor ?? editorChromeStyle.editorTextUIColor))
                    .frame(width: swatchSize, height: swatchSize)
                    .overlay {
                        Circle()
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    }
                Text("A")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(editorChromeStyle.editorSurfaceColor)
            }
            .frame(width: controlSize, height: controlSize)
            .modifier(ChromeControlPlate(style: editorChromeStyle, cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("format-color-menu")
        .accessibilityLabel("Text Color")
    }

    private var overflowFormattingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                formattingToggleButton(
                    label: "B",
                    isActive: formattingState.bold,
                    identifier: "format-bold-toggle"
                ) {
                    boldToggleToken += 1
                }
                formattingToggleButton(
                    label: "I",
                    isActive: formattingState.italic,
                    identifier: "format-italic-toggle"
                ) {
                    italicToggleToken += 1
                }
                formattingToggleButton(
                    label: "U",
                    isActive: formattingState.underline,
                    identifier: "format-underline-toggle"
                ) {
                    underlineToggleToken += 1
                }
                formattingToggleButton(
                    label: "S",
                    isActive: formattingState.strikethrough,
                    identifier: "format-strikethrough-toggle",
                    isStrikethroughLabel: true
                ) {
                    strikethroughToggleToken += 1
                }

                Button {
                    checklistToggleToken += 1
                } label: {
                    Image(systemName: "checkmark.square")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .modifier(ChromeControlPlate(style: editorChromeStyle))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("format-checklist-toggle")

                Button {
                    decreaseFontSizeToggleToken += 1
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 26, height: 34)
                        .modifier(ChromeControlPlate(style: editorChromeStyle, cornerRadius: 7))
                }
                .accessibilityIdentifier("format-font-smaller")

                Text("\(Int(formattingState.fontSize.rounded()))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(width: 30, height: 34)

                Button {
                    increaseFontSizeToggleToken += 1
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 26, height: 34)
                        .modifier(ChromeControlPlate(style: editorChromeStyle, cornerRadius: 7))
                }
                .accessibilityIdentifier("format-font-larger")
            }

            HStack(spacing: 5) {
                Button {
                    applyDefaultTextColor()
                } label: {
                    Circle()
                        .fill(Color(uiColor: editorChromeStyle.editorTextUIColor))
                        .frame(width: 22, height: 22)
                        .overlay {
                            Text("A")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(editorChromeStyle.editorSurfaceColor)
                        }
                        .overlay {
                            Circle()
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("format-color-default")
                .accessibilityLabel("Auto Text Color")

                ForEach(textColorSwatches) { swatch in
                    Button {
                        applyTextColor(swatch.uiColor)
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: isSelectedTextColor(swatch.uiColor) ? 20 : 18, height: isSelectedTextColor(swatch.uiColor) ? 20 : 18)
                            .frame(width: 20, height: 22)
                            .overlay {
                                if isSelectedTextColor(swatch.uiColor) {
                                    Circle()
                                        .stroke(Color.primary, lineWidth: 2)
                                        .padding(-2)
                                }
                            }
                            .overlay {
                                Circle()
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("format-color-\(swatch.id)")
                    .accessibilityLabel(swatch.name)
                }
            }
            .accessibilityIdentifier("format-color-swatches")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if editorChromeStyle.isChromeAccent {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(chromeAccentGradient(for: colorScheme))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(editorChromeStyle.toolbarFillColor)
            }
        }
        .overlay {
            if editorChromeStyle.isChromeAccent {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(chromeAccentToolbarTrimGradient(for: colorScheme), lineWidth: 0.9)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(editorChromeStyle.toolbarStrokeColor, lineWidth: 1)
            }
        }
        .frame(maxWidth: min(UIScreen.main.bounds.width * 0.9, 340))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keyboard-control-overflow-panel")
    }
    
    private func dismissKeyboard() {
        performResponderAction(#selector(UIResponder.resignFirstResponder))
    }


    private func formattingToggleButton(
        label: String,
        isActive: Bool,
        identifier: String,
        isStrikethroughLabel: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.headline.weight(.semibold))
                .strikethrough(isStrikethroughLabel)
                .frame(width: 34, height: 34)
                .modifier(ChromeControlPlate(style: editorChromeStyle, isActive: isActive))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private var textColorSwatches: [TextColorSwatch] {
        [
            TextColorSwatch(name: "Red", uiColor: .systemRed),
            TextColorSwatch(name: "Orange", uiColor: .systemOrange),
            TextColorSwatch(name: "Yellow", uiColor: .systemYellow),
            TextColorSwatch(name: "Green", uiColor: .systemGreen),
            TextColorSwatch(name: "Mint", uiColor: .systemMint),
            TextColorSwatch(name: "Blue", uiColor: .systemBlue),
            TextColorSwatch(name: "Purple", uiColor: .systemPurple),
            TextColorSwatch(name: "Pink", uiColor: .systemPink),
            TextColorSwatch(name: "Brown", uiColor: .systemBrown),
            TextColorSwatch(name: "Gray", uiColor: .systemGray),
            TextColorSwatch(name: "Black", uiColor: .black),
            TextColorSwatch(name: "White", uiColor: .white)
        ]
    }

    private func applyTextColor(_ color: UIColor) {
        pendingTextUIColor = color
        pendingTextColorUsesDefault = false
        selectedTextUIColor = color
        textColorToggleToken += 1
    }

    private func applyDefaultTextColor() {
        pendingTextUIColor = nil
        pendingTextColorUsesDefault = true
        selectedTextUIColor = nil
        textColorToggleToken += 1
    }

    private func isSelectedTextColor(_ color: UIColor) -> Bool {
        guard let selectedTextUIColor else { return false }
        return selectedTextUIColor.isApproximatelyEqual(to: color)
    }

    private var inlinePasteMenu: some View {
        Menu {
            Button {
                performResponderAction(#selector(UIResponder.paste(_:)))
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier("keyboard-control-paste-standard")

            Button {
                pasteAndMatchFormattingToggleToken += 1
            } label: {
                Label("Paste and Match Destination Formatting", systemImage: "paintbrush")
            }
            .accessibilityIdentifier("keyboard-control-paste-match-formatting")
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 26, height: 26)
                .modifier(ChromeControlPlate(style: editorChromeStyle, cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("keyboard-control-paste")
    }

    private func inlineActionButton(
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 26, height: 26)
                .modifier(ChromeControlPlate(style: editorChromeStyle, cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityIdentifier(identifier)
    }

    private func performResponderAction(_ action: Selector) {
        UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil)
    }

    private func performKeyboardAction(_ action: Selector, toast: KeyboardToast) {
        performResponderAction(action)
        showKeyboardToast(toast)
    }

    private func showKeyboardToast(_ toast: KeyboardToast) {
        keyboardToastTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            keyboardToast = toast
        }
        keyboardToastTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.15)) {
                    keyboardToast = nil
                }
            }
        }
    }

    private func presentLookup(for selectedText: String) {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showKeyboardToast(KeyboardToast(message: "Select text to define"))
            return
        }
        lookupRequest = LookupRequest(term: trimmed)
    }

    private func exportCurrentNote() {
        do {
            let exportURLs = try vm.exportNotesForSharing([note])
            sharePayload = NoteSharePayload(urls: exportURLs)
        } catch {
            exportErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "An unknown export error occurred."
        }
    }

    @ViewBuilder
    private func overflowMenuItem(for action: NoteEditorOverflowAction) -> some View {
        switch action {
        case .exportNote:
            Button {
                commitActivePinnedThoughtEdit()
                commitPendingNoteEdit()
                exportCurrentNote()
            } label: {
                Label("Export Note", systemImage: "square.and.arrow.up")
            }
            .foregroundStyle(.primary)
        case .attachments:
            Menu {
                attachmentImportMenuItems
            } label: {
                Label("Attachments", systemImage: "paperclip")
            }
            .foregroundStyle(.primary)
        case .newNote:
            Button {
                commitActivePinnedThoughtEdit()
                commitPendingNoteEdit()
                onNewNote(vm.createNewNote())
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
        case .search:
            Button {
                presentCurrentNoteSearch()
            } label: {
                Label("Search Note", systemImage: "magnifyingglass")
            }
            .foregroundStyle(.primary)
        case .deleteNote:
            Button(role: .destructive) {
                vm.deleteNote(note)
                dismiss()
            } label: {
                Label("Delete Note", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var attachmentImportMenuItems: some View {
        Button {
            showingPhotoPicker = true
        } label: {
            Label("Photo Library", systemImage: "photo")
        }
        .foregroundStyle(.primary)

        Button {
            showingFileImporter = true
        } label: {
            Label("Import Image", systemImage: "square.and.arrow.down")
        }
        .foregroundStyle(.primary)
    }
}

enum NoteEditorOverflowAction: String, CaseIterable {
    case newNote
    case newFolder
    case search
    case exportNote
    case attachments
    case deleteNote

    static let priorityOrder: [NoteEditorOverflowAction] = [
        .search,
        .newNote,
        .newFolder,
        .exportNote,
        .attachments,
        .deleteNote
    ]
}

private struct TopBarActionLayout {
    let visibleActions: [NoteEditorOverflowAction]
    let overflowActions: [NoteEditorOverflowAction]
}

struct EditorFormattingState: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var fontSize: CGFloat = defaultEditorTextFont.pointSize
    var foregroundColor: UIColor?
}

struct EditorSelectionFormattingCache {
    var range = NSRange(location: 0, length: 0)
    var formattingState: EditorFormattingState?
    var formattingStateIsDirty = true
    var formattingStateIsApproximate = false

    mutating func markDirty(range: NSRange) {
        self.range = range
        formattingStateIsDirty = true
    }

    mutating func update(range: NSRange, formattingState: EditorFormattingState, isApproximate: Bool) {
        self.range = range
        self.formattingState = formattingState
        formattingStateIsDirty = false
        formattingStateIsApproximate = isApproximate
    }
}

enum NoteSearchRegion: Equatable {
    case pinnedText(id: UUID)
    case body
}

struct NoteSearchMatch: Identifiable, Equatable {
    let id: String
    let region: NoteSearchRegion
    let plainTextRange: Range<String.Index>
    let nsRangeInRenderedText: NSRange?
    let previewText: String
}

struct NoteSearchPinnedText {
    let id: UUID
    let text: String
}

enum NoteSearchMatcher {
    static func matches(
        in bodyText: String,
        pinnedTexts: [NoteSearchPinnedText],
        query: String
    ) -> [NoteSearchMatch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let pinnedMatches = pinnedTexts.flatMap { pinnedText in
            matches(
                in: pinnedText.text,
                query: trimmedQuery,
                region: .pinnedText(id: pinnedText.id),
                idPrefix: "pinned-\(pinnedText.id.uuidString)",
                includesRenderedRange: false
            )
        }

        let bodyMatches = matches(
            in: bodyText,
            query: trimmedQuery,
            region: .body,
            idPrefix: "body",
            includesRenderedRange: true
        )

        return pinnedMatches + bodyMatches
    }

    private static func matches(
        in text: String,
        query: String,
        region: NoteSearchRegion,
        idPrefix: String,
        includesRenderedRange: Bool
    ) -> [NoteSearchMatch] {
        var results: [NoteSearchMatch] = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let range = text.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
              ) {
            let nsRange = NSRange(range, in: text)
            results.append(NoteSearchMatch(
                id: "\(idPrefix)-\(nsRange.location)-\(nsRange.length)",
                region: region,
                plainTextRange: range,
                nsRangeInRenderedText: includesRenderedRange ? nsRange : nil,
                previewText: preview(in: text, matchRange: range)
            ))

            searchStart = range.upperBound < text.endIndex
                ? text.index(after: range.lowerBound)
                : text.endIndex
        }

        return results
    }

    private static func preview(in text: String, matchRange: Range<String.Index>) -> String {
        let contextLength = 32
        let lower = text.index(
            matchRange.lowerBound,
            offsetBy: -contextLength,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let upper = text.index(
            matchRange.upperBound,
            offsetBy: contextLength,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        return String(text[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct NoteSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct LookupRequest: Identifiable {
    let id = UUID()
    let term: String
}

private struct TextColorSwatch: Identifiable {
    let name: String
    let uiColor: UIColor

    var id: String {
        name.lowercased()
    }

    var color: Color {
        Color(uiColor: uiColor)
    }
}

private final class TextFormattingController: ObservableObject {
    fileprivate var applyTextColorHandler: ((UIColor?) -> Void)?

    func applyTextColor(_ color: UIColor?) {
        applyTextColorHandler?(color)
    }
}

final class NoteEditorToolbarBridge: ObservableObject {
    @Published var title = "Untitled"
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var isEditorFocused = false

    var editTitle: (() -> Void)?
    var undo: (() -> Void)?
    var redo: (() -> Void)?
    var newNote: (() -> Void)?
    var newFolder: (() -> Void)?
    var exportNote: (() -> Void)?
    var importFromPhotoLibrary: (() -> Void)?
    var importImageFile: (() -> Void)?
    var deleteNote: (() -> Void)?

    func reset() {
        title = "Untitled"
        canUndo = false
        canRedo = false
        isEditorFocused = false
        editTitle = nil
        undo = nil
        redo = nil
        newNote = nil
        newFolder = nil
        exportNote = nil
        importFromPhotoLibrary = nil
        importImageFile = nil
        deleteNote = nil
    }
}

private struct NoteSnapshot: Equatable {
    var title: String = ""
    var content: String = ""
    var richTextContentData: Data?
    var pinnedThoughts: [PinnedThoughtSnapshot] = []
}

private struct PinnedThoughtSnapshot: Equatable {
    let text: String
    let order: Int
    let isCollapsed: Bool
}

enum PinnedHighlightColor: String, CaseIterable, Identifiable {
    case yellow
    case mint
    case blue
    case purple
    case slate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yellow:
            "Yellow"
        case .mint:
            "Mint"
        case .blue:
            "Blue"
        case .purple:
            "Purple"
        case .slate:
            "Slate"
        }
    }
}

enum PinnedHighlightPalette {
    static let appIconOrange = Color(red: 249 / 255, green: 167 / 255, blue: 19 / 255)
    static let highlightUIColor = UIColor(red: 250 / 255, green: 185 / 255, blue: 66 / 255, alpha: 1)
    static let textUIColor = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)

    static let highlight = Color(uiColor: highlightUIColor)
    static let text = Color(uiColor: textUIColor)
    static let placeholderText = Color(uiColor: textUIColor.withAlphaComponent(0.68))

    static func highlightUIColor(for color: PinnedHighlightColor) -> UIColor {
        switch color {
        case .yellow:
            highlightUIColor
        case .mint:
            UIColor(red: 122 / 255, green: 225 / 255, blue: 191 / 255, alpha: 1)
        case .blue:
            UIColor(red: 85 / 255, green: 161 / 255, blue: 238 / 255, alpha: 1)
        case .purple:
            UIColor(red: 173 / 255, green: 136 / 255, blue: 232 / 255, alpha: 1)
        case .slate:
            UIColor(red: 65 / 255, green: 78 / 255, blue: 96 / 255, alpha: 1)
        }
    }

    static func textUIColor(for color: PinnedHighlightColor) -> UIColor {
        readableTextUIColor(on: highlightUIColor(for: color))
    }

    static func placeholderTextUIColor(for color: PinnedHighlightColor) -> UIColor {
        textUIColor(for: color).withAlphaComponent(0.68)
    }

    static func highlight(for color: PinnedHighlightColor) -> Color {
        Color(uiColor: highlightUIColor(for: color))
    }

    static func text(for color: PinnedHighlightColor) -> Color {
        Color(uiColor: textUIColor(for: color))
    }

    static func placeholderText(for color: PinnedHighlightColor) -> Color {
        Color(uiColor: placeholderTextUIColor(for: color))
    }

    private static func readableTextUIColor(on background: UIColor) -> UIColor {
        let whiteContrast = contrastRatio(foreground: .white, background: background)
        let darkContrast = contrastRatio(foreground: textUIColor, background: background)
        if max(whiteContrast, darkContrast) >= 4.5 {
            return whiteContrast > darkContrast ? .white : textUIColor
        }
        let components = rgbaComponents(from: background)
        return components.luminance < 0.5 ? .white : textUIColor
    }

    private static func contrastRatio(foreground: UIColor, background: UIColor) -> CGFloat {
        let lighter = max(relativeLuminance(foreground), relativeLuminance(background))
        let darker = min(relativeLuminance(foreground), relativeLuminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: UIColor) -> CGFloat {
        let components = rgbaComponents(from: color)
        func convert(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return (0.2126 * convert(components.red))
            + (0.7152 * convert(components.green))
            + (0.0722 * convert(components.blue))
    }

    private static func rgbaComponents(from color: UIColor) -> RGBAComponents {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return RGBAComponents(red: red, green: green, blue: blue, alpha: alpha)
        }

        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) {
            return RGBAComponents(red: white, green: white, blue: white, alpha: alpha)
        }

        let ciColor = CIColor(color: color)
        return RGBAComponents(red: ciColor.red, green: ciColor.green, blue: ciColor.blue, alpha: ciColor.alpha)
    }
}

private struct KeyboardToast: Equatable {
    let message: String
}

private struct ReorderDragHandle: View {
    let payload: String
    @Binding var activePayload: String?
    let accessibilityIdentifier: String
    let onChanged: (CGPoint, CGSize) -> Void
    let onEnded: () -> Void

    var body: some View {
        ReorderGripDots()
            .frame(width: 24, height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if activePayload == nil {
                            activePayload = payload
                        }
                        onChanged(value.location, value.translation)
                    }
                    .onEnded { _ in
                        onEnded()
                    }
            )
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityLabel("Reorder")
    }
}

private struct ReorderGripDots: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
        .frame(width: 24, height: 30)
    }
}

private struct ReorderInsertionIndicator: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.leading, 32)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }
}

private extension View {
    func reorderItemFrame(payload: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReorderItemFramePreferenceKey.self,
                    value: [payload: proxy.frame(in: .global)]
                )
            }
        }
    }
}

private struct ReorderItemFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct AttachmentThumbnail: View {
    let attachment: NotePhotoAttachment
    let size: CGFloat

    var body: some View {
        if let image = UIImage(data: attachment.imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                }
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct AttachmentStrip: View {
    let attachments: [NotePhotoAttachment]
    @Binding var isExpanded: Bool
    let backgroundColor: Color
    let onOpen: (NotePhotoAttachment) -> Void
    let onDelete: (NotePhotoAttachment) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(attachments, id: \.id) { attachment in
                        AttachmentStripItem(
                            attachment: attachment,
                            onOpen: onOpen,
                            onDelete: onDelete
                        )
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Label("Attachments", systemImage: "paperclip")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("\(attachments.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
        .tint(.primary)
        .padding(10)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct AttachmentStripItem: View {
    let attachment: NotePhotoAttachment
    let onOpen: (NotePhotoAttachment) -> Void
    let onDelete: (NotePhotoAttachment) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AttachmentThumbnail(attachment: attachment, size: 64)
                .onTapGesture {
                    onOpen(attachment)
                }

            Button {
                onDelete(attachment)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.white, .black.opacity(0.7))
                    .padding(4)
            }
        }
    }
}

private struct ExpandedPhotoView: View {
    let attachment: NotePhotoAttachment
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            if let image = UIImage(data: attachment.imageData) {
                LiveTextImageView(image: image, imageID: attachment.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                    .background(Color.black)
            } else {
                ContentUnavailableView(
                    "Photo Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This attachment could not be loaded.")
                )
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close Attachment")
            .padding(.top, 18)
            .padding(.trailing, 18)
        }
        .contentShape(Rectangle())
        .frame(
            minWidth: 320,
            idealWidth: 900,
            maxWidth: .infinity,
            minHeight: 320,
            idealHeight: 700,
            maxHeight: .infinity
        )
    }
}

private struct ReferenceLookupView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(
        _ uiViewController: UIReferenceLibraryViewController,
        context: Context
    ) {}
}

@MainActor
private struct LiveTextImageView: UIViewRepresentable {
    let image: UIImage
    let imageID: UUID

    func makeUIView(context: Context) -> LiveTextEnabledImageView {
        LiveTextEnabledImageView(frame: .zero)
    }

    func updateUIView(_ imageView: LiveTextEnabledImageView, context: Context) {
        imageView.setAnalyzedImage(image, id: imageID)
    }
}

@MainActor
private final class LiveTextEnabledImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private let liveTextInteraction = ImageAnalysisInteraction()
    private let analyzer = ImageAnalyzer()
    private var analysisTask: Task<Void, Never>?
    private var sourceImage: UIImage?
    private var sourceImageID: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)

        delegate = self
        minimumZoomScale = 1.0
        maximumZoomScale = 5.0
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false

        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        liveTextInteraction.preferredInteractionTypes = [.textSelection, .dataDetectors]
        imageView.addInteraction(liveTextInteraction)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= minimumZoomScale + 0.0001 {
            fitImageToBounds()
        } else {
            centerImageIfNeeded()
        }
    }

    func setAnalyzedImage(_ image: UIImage, id: UUID) {
        guard sourceImageID != id else { return }

        sourceImageID = id
        sourceImage = image
        imageView.image = image
        setZoomScale(1.0, animated: false)
        fitImageToBounds()

        analysisTask?.cancel()
        analysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
                let analysis = try await analyzer.analyze(image, configuration: configuration)
                guard !Task.isCancelled else { return }
                liveTextInteraction.analysis = analysis
            } catch {
                liveTextInteraction.analysis = nil
            }
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageIfNeeded()
    }

    private func fitImageToBounds() {
        guard let image = sourceImage else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }

        let widthScale = bounds.width / imageSize.width
        let heightScale = bounds.height / imageSize.height
        let scale = min(widthScale, heightScale)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
        centerImageIfNeeded()
    }

    private func centerImageIfNeeded() {
        let offsetX = max((bounds.width - contentSize.width) * 0.5, 0)
        let offsetY = max((bounds.height - contentSize.height) * 0.5, 0)
        imageView.center = CGPoint(
            x: contentSize.width * 0.5 + offsetX,
            y: contentSize.height * 0.5 + offsetY
        )
    }
}

private struct SelectableTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var richTextContentData: Data?
    let keyboardFocusToggleToken: Int
    let captureSelectionToggleToken: Int
    let selectAllToggleToken: Int
    let pinSelectionToggleToken: Int
    let lookupSelectionToggleToken: Int
    let appendUnpinnedThoughtToggleToken: Int
    let pendingUnpinnedThoughtText: String
    let restoreContentToggleToken: Int
    let boldToggleToken: Int
    let italicToggleToken: Int
    let underlineToggleToken: Int
    let strikethroughToggleToken: Int
    let checklistToggleToken: Int
    let pasteAndMatchFormattingToggleToken: Int
    let increaseFontSizeToggleToken: Int
    let decreaseFontSizeToggleToken: Int
    let textColorToggleToken: Int
    let pendingTextUIColor: UIColor?
    let pendingTextColorUsesDefault: Bool
    let searchHighlightRange: NSRange?
    let formattingController: TextFormattingController
    let backgroundColor: UIColor
    let textColor: UIColor
    let tintColor: UIColor?
    let onContentChanged: (String, EditorRichTextContentUpdate) -> Void
    let onUndoManagerChanged: (UndoManager?) -> Void
    let onFormattingStateChanged: (EditorFormattingState) -> Void
    let onEditingFocusChanged: (Bool) -> Void
    let onEditorScrolled: () -> Void
    let onPinSelection: (String) -> Bool
    let onLookupSelection: (String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        context.coordinator.textView = textView
        context.coordinator.installFormattingControllerHandler()
        context.coordinator.installChecklistTapRecognizer(on: textView)
        context.coordinator.installTextPlacementTapRecognizer(on: textView)
        textView.delegate = context.coordinator
        textView.font = defaultEditorTextFont
        textView.textColor = textColor
        textView.adjustsFontForContentSizeCategory = true
        textView.allowsEditingTextAttributes = true
        textView.backgroundColor = backgroundColor
        textView.tintColor = tintColor
        textView.layer.cornerRadius = 8
        textView.typingAttributes = [
            .font: textView.font ?? defaultEditorTextFont,
            .foregroundColor: textColor,
            .paragraphStyle: ChecklistItemEditor.editorParagraphStyle
        ]
        textView.textContainerInset = ChecklistItemEditor.textContainerInsets(hasChecklistItems: false)
        textView.keyboardDismissMode = .interactive
#if targetEnvironment(macCatalyst)
        textView.alwaysBounceVertical = false
#else
        textView.alwaysBounceVertical = true
#endif
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.textView = textView
        context.coordinator.formattingController = formattingController
        context.coordinator.installFormattingControllerHandler()
        context.coordinator.installChecklistTapRecognizer(on: textView)
        context.coordinator.installTextPlacementTapRecognizer(on: textView)
        context.coordinator.isUpdatingUIView = true
        defer {
            context.coordinator.isUpdatingUIView = false
        }

        context.coordinator.updateEditorLayout(in: textView)
        context.coordinator.ensureEditorTypingParagraphStyle(in: textView)
        textView.backgroundColor = backgroundColor
        textView.tintColor = tintColor
        context.coordinator.defaultTextColor = textColor

        let hasPendingFormattingMutation = context.coordinator.hasPendingFormattingMutation(
            boldToggleToken: boldToggleToken,
            italicToggleToken: italicToggleToken,
            underlineToggleToken: underlineToggleToken,
            strikethroughToggleToken: strikethroughToggleToken,
            checklistToggleToken: checklistToggleToken,
            pasteAndMatchFormattingToggleToken: pasteAndMatchFormattingToggleToken,
            increaseFontSizeToggleToken: increaseFontSizeToggleToken,
            decreaseFontSizeToggleToken: decreaseFontSizeToggleToken,
            textColorToggleToken: textColorToggleToken
        )

        context.coordinator.clearAppliedContentIfSynced()

        if context.coordinator.restoreContentToggleToken != restoreContentToggleToken {
            context.coordinator.restoreContentToggleToken = restoreContentToggleToken
            context.coordinator.applyBoundContent(
                plainText: text,
                richTextContentData: richTextContentData,
                in: textView
            )
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        } else if !textView.isFirstResponder
            && !context.coordinator.isHandlingUserFocusChange
            && !hasPendingFormattingMutation
            && !context.coordinator.hasUnsyncedAppliedContent {
            context.coordinator.applyBoundContent(
                plainText: text,
                richTextContentData: richTextContentData,
                in: textView
            )
        }
        context.coordinator.text = $text
        context.coordinator.richTextContentData = $richTextContentData
        context.coordinator.onContentChanged = onContentChanged
        context.coordinator.onUndoManagerChanged = onUndoManagerChanged
        context.coordinator.onFormattingStateChanged = onFormattingStateChanged
        context.coordinator.onEditingFocusChanged = onEditingFocusChanged
        context.coordinator.onEditorScrolled = onEditorScrolled
        context.coordinator.onPinSelection = onPinSelection
        context.coordinator.onLookupSelection = onLookupSelection
        context.coordinator.applySearchHighlight(searchHighlightRange, in: textView)

        if context.coordinator.captureSelectionToggleToken != captureSelectionToggleToken {
            context.coordinator.captureSelectionToggleToken = captureSelectionToggleToken
            context.coordinator.captureCurrentSelection(in: textView)
        }

        if context.coordinator.keyboardFocusToggleToken != keyboardFocusToggleToken {
            context.coordinator.keyboardFocusToggleToken = keyboardFocusToggleToken
            if !textView.isFirstResponder {
                textView.becomeFirstResponder()
            }
        }

        if context.coordinator.selectAllToggleToken != selectAllToggleToken {
            context.coordinator.selectAllToggleToken = selectAllToggleToken
            let fullLength = textView.textStorage.length
            if fullLength > 0 && textView.selectedRange.location == 0 && textView.selectedRange.length == fullLength {
                textView.selectedRange = NSRange(location: fullLength, length: 0)
            } else {
                textView.selectAll(nil)
            }
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        }

        if context.coordinator.pinSelectionToggleToken != pinSelectionToggleToken {
            context.coordinator.pinSelectionToggleToken = pinSelectionToggleToken
            context.coordinator.pinCurrentSelection(in: textView)
        }

        if context.coordinator.lookupSelectionToggleToken != lookupSelectionToggleToken {
            context.coordinator.lookupSelectionToggleToken = lookupSelectionToggleToken
            context.coordinator.lookupCurrentSelection(in: textView)
        }

        if context.coordinator.appendUnpinnedThoughtToggleToken != appendUnpinnedThoughtToggleToken {
            context.coordinator.appendUnpinnedThoughtToggleToken = appendUnpinnedThoughtToggleToken
            context.coordinator.appendUnpinnedThought(pendingUnpinnedThoughtText, in: textView)
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        }

        if context.coordinator.boldToggleToken != boldToggleToken {
            context.coordinator.boldToggleToken = boldToggleToken
            context.coordinator.toggleBold(in: textView)
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        }

        if context.coordinator.italicToggleToken != italicToggleToken {
            context.coordinator.italicToggleToken = italicToggleToken
            context.coordinator.toggleItalic(in: textView)
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        }

        if context.coordinator.underlineToggleToken != underlineToggleToken {
            context.coordinator.underlineToggleToken = underlineToggleToken
            context.coordinator.toggleUnderline(in: textView)
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        }

        if context.coordinator.strikethroughToggleToken != strikethroughToggleToken {
            context.coordinator.strikethroughToggleToken = strikethroughToggleToken
            context.coordinator.toggleStrikethrough(in: textView)
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        }

        if context.coordinator.checklistToggleToken != checklistToggleToken {
            context.coordinator.checklistToggleToken = checklistToggleToken
            context.coordinator.toggleChecklistItem(in: textView)
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        }

        if context.coordinator.pasteAndMatchFormattingToggleToken != pasteAndMatchFormattingToggleToken {
            context.coordinator.pasteAndMatchFormattingToggleToken = pasteAndMatchFormattingToggleToken
            context.coordinator.pasteAndMatchDestinationFormatting(in: textView)
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        }

        if context.coordinator.increaseFontSizeToggleToken != increaseFontSizeToggleToken {
            context.coordinator.increaseFontSizeToggleToken = increaseFontSizeToggleToken
            context.coordinator.adjustFontSize(in: textView, by: 1)
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        }

        if context.coordinator.decreaseFontSizeToggleToken != decreaseFontSizeToggleToken {
            context.coordinator.decreaseFontSizeToggleToken = decreaseFontSizeToggleToken
            context.coordinator.adjustFontSize(in: textView, by: -1)
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        }

        if context.coordinator.textColorToggleToken != textColorToggleToken {
            context.coordinator.textColorToggleToken = textColorToggleToken
            context.coordinator.applyTextColor(
                in: textView,
                color: pendingTextUIColor,
                usesDefaultColor: pendingTextColorUsesDefault
            )
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        }

        context.coordinator.normalizeTypingAttributes(in: textView)
        context.coordinator.reportFormattingState(from: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            formattingController: formattingController,
            text: $text,
            richTextContentData: $richTextContentData,
            onContentChanged: onContentChanged,
            onUndoManagerChanged: onUndoManagerChanged,
            onFormattingStateChanged: onFormattingStateChanged,
            onEditingFocusChanged: onEditingFocusChanged,
            onEditorScrolled: onEditorScrolled,
            onPinSelection: onPinSelection,
            onLookupSelection: onLookupSelection
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        private static let searchHighlightLayerName = "MyRAMSearchHighlightLayer"
        var formattingController: TextFormattingController
        var text: Binding<String>
        var richTextContentData: Binding<Data?>
        var onContentChanged: (String, EditorRichTextContentUpdate) -> Void
        var onUndoManagerChanged: (UndoManager?) -> Void
        var onFormattingStateChanged: (EditorFormattingState) -> Void
        var onEditingFocusChanged: (Bool) -> Void
        var onEditorScrolled: () -> Void
        var onPinSelection: (String) -> Bool
        var onLookupSelection: (String) -> Void
        var defaultTextColor: UIColor = .label
        weak var textView: UITextView?
        var captureSelectionToggleToken = 0
        var keyboardFocusToggleToken = 0
        var selectAllToggleToken = 0
        var pinSelectionToggleToken = 0
        var lookupSelectionToggleToken = 0
        var appendUnpinnedThoughtToggleToken = 0
        var restoreContentToggleToken = 0
        var boldToggleToken = 0
        var italicToggleToken = 0
        var underlineToggleToken = 0
        var strikethroughToggleToken = 0
        var checklistToggleToken = 0
        var pasteAndMatchFormattingToggleToken = 0
        var increaseFontSizeToggleToken = 0
        var decreaseFontSizeToggleToken = 0
        var textColorToggleToken = 0
        private var activeSearchHighlightRange: NSRange?
        private var activeSearchHighlightRects: [CGRect] = []
        private var activeSearchHighlightLayers: [CALayer] = []
        private var lastReportedFormattingState: EditorFormattingState?
        private var selectionFormattingCache = EditorSelectionFormattingCache()
        var lastKnownSelectionRange = NSRange(location: 0, length: 0)
        var isUpdatingUIView = false
        var isHandlingUserFocusChange = false
        private var isApplyingBoundContent = false
        private var focusAcquisitionSelectionRange: NSRange?
        private var appliedPlainTextAwaitingBinding: String?
        private var appliedRichTextDataAwaitingBinding: Data?
        private weak var checklistTapRecognizer: UITapGestureRecognizer?
#if targetEnvironment(macCatalyst)
        private struct PendingFocusTapContext {
            let range: NSRange
            let contentOffset: CGPoint
        }

        private weak var textPlacementTapRecognizer: UITapGestureRecognizer?
        private var pendingFocusTapContext: PendingFocusTapContext?
#endif

        init(
            formattingController: TextFormattingController,
            text: Binding<String>,
            richTextContentData: Binding<Data?>,
            onContentChanged: @escaping (String, EditorRichTextContentUpdate) -> Void,
            onUndoManagerChanged: @escaping (UndoManager?) -> Void,
            onFormattingStateChanged: @escaping (EditorFormattingState) -> Void,
            onEditingFocusChanged: @escaping (Bool) -> Void,
            onEditorScrolled: @escaping () -> Void,
            onPinSelection: @escaping (String) -> Bool,
            onLookupSelection: @escaping (String) -> Void
        ) {
            self.formattingController = formattingController
            self.text = text
            self.richTextContentData = richTextContentData
            self.onContentChanged = onContentChanged
            self.onUndoManagerChanged = onUndoManagerChanged
            self.onFormattingStateChanged = onFormattingStateChanged
            self.onEditingFocusChanged = onEditingFocusChanged
            self.onEditorScrolled = onEditorScrolled
            self.onPinSelection = onPinSelection
            self.onLookupSelection = onLookupSelection
        }

        deinit {
            formattingController.applyTextColorHandler = nil
        }

        func installFormattingControllerHandler() {
            formattingController.applyTextColorHandler = { [weak self] color in
                guard let self, let textView = self.textView else { return }
                self.applyTextColor(in: textView, color: color)
                self.reportUndoManagerChanged(textView.undoManager)
            }
        }

        func installChecklistTapRecognizer(on textView: UITextView) {
            if checklistTapRecognizer?.view === textView {
                return
            }

            if let previous = checklistTapRecognizer {
                previous.view?.removeGestureRecognizer(previous)
            }

            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleChecklistTap(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            textView.addGestureRecognizer(recognizer)
            checklistTapRecognizer = recognizer
        }

        func installTextPlacementTapRecognizer(on textView: UITextView) {
#if targetEnvironment(macCatalyst)
            if textPlacementTapRecognizer?.view === textView {
                return
            }

            if let previous = textPlacementTapRecognizer {
                previous.view?.removeGestureRecognizer(previous)
            }

            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTextPlacementTap(_:)))
            recognizer.cancelsTouchesInView = true
            recognizer.delegate = self
            textView.addGestureRecognizer(recognizer)
            textPlacementTapRecognizer = recognizer
#endif
        }

        @objc
        private func handleChecklistTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let textView = textView else { return }

            let locationInView = recognizer.location(in: textView)
            let location = CGPoint(
                x: locationInView.x - textView.textContainerInset.left,
                y: locationInView.y - textView.textContainerInset.top
            )

            guard location.x >= 0,
                  location.x <= ChecklistItemEditor.gutterTapWidth else { return }

            let layoutManager = textView.layoutManager
            let container = textView.textContainer
            let characterIndex = layoutManager.characterIndex(
                for: location,
                in: container,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            guard characterIndex < textView.attributedText.length else { return }
            guard ChecklistItemEditor.isChecklistLine(
                at: characterIndex,
                in: textView.attributedText.string as NSString
            ) else { return }

            toggleChecklistItem(
                in: textView,
                selection: NSRange(location: characterIndex, length: 0),
                animated: true
            )
            reportUndoManagerChanged(textView.undoManager)
        }

#if targetEnvironment(macCatalyst)
        @objc
        private func handleTextPlacementTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let textView = textView,
                  !textView.isFirstResponder else { return }

            let location = recognizer.location(in: textView)
            let gutterAdjustedX = location.x - textView.textContainerInset.left
            if gutterAdjustedX >= 0, gutterAdjustedX <= ChecklistItemEditor.gutterTapWidth {
                return
            }

            let cursorRange = EditorTextPlacementResolver.caretRange(forTapLocation: location, in: textView)
            let tapContext = PendingFocusTapContext(range: cursorRange, contentOffset: textView.contentOffset)

            pendingFocusTapContext = tapContext
            isHandlingUserFocusChange = true
            textView.selectedRange = cursorRange
            textView.becomeFirstResponder()
            restorePendingFocusTapSelection(in: textView, clear: false)
            lastKnownSelectionRange = cursorRange
            reportFormattingState(from: textView)

            RunLoop.main.perform { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.restorePendingFocusTapSelection(in: textView, clear: false)
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.restorePendingFocusTapSelection(in: textView, clear: true)
                }
            }
        }
#endif

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
#if targetEnvironment(macCatalyst)
            if gestureRecognizer === textPlacementTapRecognizer || otherGestureRecognizer === textPlacementTapRecognizer {
                return false
            }
#endif
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            applyChecklistRendering(in: textView)
            updateEditorLayout(in: textView)
            syncContent(from: textView, serializesRichTextImmediately: false)
            markSelectionFormattingDirty(from: textView)
            reportFormattingState(from: textView)
            onUndoManagerChanged(textView.undoManager)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if isApplyingBoundContent {
                selectionFormattingCache.markDirty(range: safeSelectedRange(in: textView))
                return
            }

            if isHandlingUserFocusChange {
                // UIKit can emit a transient end-of-document selection while a
                // text view becomes first responder. Do not let that provisional
                // callback replace the selection we intend to restore after focus.
                selectionFormattingCache.markDirty(range: focusAcquisitionSelectionRange ?? safeSelectedRange(in: textView))
                return
            }

            cacheSelectionFormattingRange(from: textView)
        }

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            focusAcquisitionSelectionRange = safeSelectedRange(in: textView)
            isHandlingUserFocusChange = true
            return true
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            onEditingFocusChanged(true)
            lastKnownSelectionRange = safeSelectedRange(in: textView)
            focusAcquisitionSelectionRange = focusAcquisitionSelectionRange ?? lastKnownSelectionRange
            RunLoop.main.perform { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyPendingFocusTapSelection(in: textView)
                self.reportFormattingState(from: textView)
            }
            reportFormattingState(from: textView)
            onUndoManagerChanged(textView.undoManager)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isHandlingUserFocusChange = false
            focusAcquisitionSelectionRange = nil
            onEditingFocusChanged(false)
            updateLastKnownSelectionRange(from: textView)
            syncContent(from: textView)
            reportFormattingState(from: textView)
            onUndoManagerChanged(textView.undoManager)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            onEditorScrolled()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView,
                  activeSearchHighlightRange != nil else { return }
            positionSearchHighlightLayers(in: textView)
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
#if targetEnvironment(macCatalyst)
            return UIMenu(children: suggestedActions)
#else
            UIMenu(children: [])
#endif
        }

        func hasPendingFormattingMutation(
            boldToggleToken: Int,
            italicToggleToken: Int,
            underlineToggleToken: Int,
            strikethroughToggleToken: Int,
            checklistToggleToken: Int,
            pasteAndMatchFormattingToggleToken: Int,
            increaseFontSizeToggleToken: Int,
            decreaseFontSizeToggleToken: Int,
            textColorToggleToken: Int
        ) -> Bool {
            self.boldToggleToken != boldToggleToken
                || self.italicToggleToken != italicToggleToken
                || self.underlineToggleToken != underlineToggleToken
                || self.strikethroughToggleToken != strikethroughToggleToken
                || self.checklistToggleToken != checklistToggleToken
                || self.pasteAndMatchFormattingToggleToken != pasteAndMatchFormattingToggleToken
                || self.increaseFontSizeToggleToken != increaseFontSizeToggleToken
                || self.decreaseFontSizeToggleToken != decreaseFontSizeToggleToken
                || self.textColorToggleToken != textColorToggleToken
        }

        func toggleBold(in textView: UITextView) {
            toggleFontTrait(.traitBold, in: textView)
        }

        func toggleItalic(in textView: UITextView) {
            toggleFontTrait(.traitItalic, in: textView)
        }

        func toggleUnderline(in textView: UITextView) {
            toggleTextDecoration(in: textView, key: .underlineStyle)
        }

        func toggleStrikethrough(in textView: UITextView) {
            toggleTextDecoration(in: textView, key: .strikethroughStyle)
        }

        func toggleChecklistItem(in textView: UITextView) {
            toggleChecklistItem(in: textView, selection: textView.selectedRange, animated: false)
        }

        func pasteAndMatchDestinationFormatting(in textView: UITextView) {
            guard let pastedText = UIPasteboard.general.string,
                  !pastedText.isEmpty else { return }

            let selectedRange = safeSelectedRange(in: textView)
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let replacement = EditorPasteFormatter.attributedString(
                matchingDestinationFormattingFor: pastedText,
                typingAttributes: textView.typingAttributes,
                defaultAttributes: defaultTextAttributes(for: textView)
            )
            mutable.replaceCharacters(in: selectedRange, with: replacement)
            applyAttributedText(
                mutable,
                in: textView,
                selectedRange: NSRange(location: selectedRange.location + replacement.length, length: 0)
            )
            textView.becomeFirstResponder()
        }

        private func toggleChecklistItem(in textView: UITextView, selection: NSRange, animated: Bool) {
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let updatedSelection = ChecklistItemEditor.applyChecklistAction(
                in: mutable,
                selection: selection
            )
            applyAttributedText(mutable, in: textView, selectedRange: updatedSelection, animated: animated)
        }

        func adjustFontSize(in textView: UITextView, by delta: CGFloat) {
            let selectedRange = formattingActionRange(in: textView)

            if selectedRange.length == 0 {
                var typingAttributes = textView.typingAttributes
                let baseFont = (typingAttributes[.font] as? UIFont)
                    ?? textView.font
                    ?? defaultEditorTextFont
                typingAttributes[.font] = adjustedFontSize(from: baseFont, delta: delta)
                textView.typingAttributes = typingAttributes
                markSelectionFormattingDirty(from: textView)
                reportFormattingState(from: textView)
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            mutable.enumerateAttribute(.font, in: selectedRange) { value, range, _ in
                let baseFont = (value as? UIFont)
                    ?? textView.font
                    ?? defaultEditorTextFont
                mutable.addAttribute(
                    .font,
                    value: adjustedFontSize(from: baseFont, delta: delta),
                    range: range
                )
            }
            applyAttributedText(mutable, in: textView, selectedRange: selectedRange)
        }

        func applyTextColor(
            in textView: UITextView,
            color: UIColor?,
            usesDefaultColor: Bool = false
        ) {
            let selectedRange = formattingActionRange(in: textView)

            if selectedRange.length == 0 {
                var typingAttributes = textView.typingAttributes
                if usesDefaultColor {
                    // Auto uses the editor default for display, but syncContent
                    // strips this default foreground before RTF encoding. That
                    // keeps UIKit readable now without saving light/dark colors
                    // as explicit formatting.
                    typingAttributes[.foregroundColor] = defaultTextColor
                    typingAttributes[.autoTextColorDisplay] = true
                    syncDecorationColorsWithForeground(in: &typingAttributes, color: defaultTextColor)
                } else {
                    let resolvedColor = color ?? textView.textColor ?? defaultTextColor
                    typingAttributes[.foregroundColor] = resolvedColor
                    typingAttributes.removeValue(forKey: .autoTextColorDisplay)
                    syncDecorationColorsWithForeground(in: &typingAttributes, color: resolvedColor)
                }
                textView.typingAttributes = typingAttributes
                textView.becomeFirstResponder()
                markSelectionFormattingDirty(from: textView)
                reportFormattingState(from: textView)
                return
            }

            textView.textStorage.beginEditing()
            let previousText = NSAttributedString(attributedString: textView.attributedText)
            let previousSelection = textView.selectedRange
            if usesDefaultColor {
                // UITextView can render attributed ranges without foreground
                // attributes as black. Paint the selected text with the editor
                // default for the live view; storage encoding removes this
                // default color so Auto remains unformatted in synced RTF.
                textView.textStorage.addAttribute(.foregroundColor, value: defaultTextColor, range: selectedRange)
                textView.textStorage.addAttribute(.autoTextColorDisplay, value: true, range: selectedRange)
                syncDecorationColorsWithForeground(in: textView.textStorage, range: selectedRange, color: defaultTextColor)
            } else {
                let resolvedColor = color ?? textView.textColor ?? defaultTextColor
                textView.textStorage.addAttribute(.foregroundColor, value: resolvedColor, range: selectedRange)
                textView.textStorage.removeAttribute(.autoTextColorDisplay, range: selectedRange)
                syncDecorationColorsWithForeground(in: textView.textStorage, range: selectedRange, color: resolvedColor)
            }
            textView.textStorage.endEditing()

            restoreSelectionWithoutScrolling(selectedRange, in: textView)
            lastKnownSelectionRange = selectedRange
            textView.becomeFirstResponder()
            syncContent(from: textView)
            registerFormattingUndo(in: textView, previousText: previousText, previousSelection: previousSelection)
            markSelectionFormattingDirty(from: textView)
            reportFormattingState(from: textView)
        }

        private func registerFormattingUndo(
            in textView: UITextView,
            previousText: NSAttributedString,
            previousSelection: NSRange
        ) {
            guard let undoManager = textView.undoManager else { return }
            let currentText = NSAttributedString(attributedString: textView.attributedText)
            let currentSelection = textView.selectedRange

            undoManager.registerUndo(withTarget: self) { target in
                target.restoreFormattingUndoState(
                    in: textView,
                    previousText: currentText,
                    previousSelection: currentSelection,
                    restoredText: previousText,
                    restoredSelection: previousSelection
                )
            }
            undoManager.setActionName("Format")
        }

        private func restoreFormattingUndoState(
            in textView: UITextView,
            previousText: NSAttributedString,
            previousSelection: NSRange,
            restoredText: NSAttributedString,
            restoredSelection: NSRange
        ) {
            applyAttributedText(
                restoredText,
                in: textView,
                selectedRange: restoredSelection,
                registersUndo: false
            )
            registerFormattingUndo(
                in: textView,
                previousText: previousText,
                previousSelection: previousSelection
            )
            reportUndoManagerChanged(textView.undoManager)
        }

        func normalizeTypingAttributes(in textView: UITextView) {
            var typingAttributes = textView.typingAttributes
            typingAttributes[.paragraphStyle] = ChecklistItemEditor.bodyParagraphStyle(
                hasChecklistItems: ChecklistItemEditor.containsChecklistItems(in: textView.text as NSString)
            )
            textView.typingAttributes = typingAttributes
        }

        func applySearchHighlight(_ range: NSRange?, in textView: UITextView) {
            if range == activeSearchHighlightRange, hasSearchHighlightLayers(in: textView) {
                positionSearchHighlightLayers(in: textView)
                return
            }
            clearSearchHighlight(in: textView)

            activeSearchHighlightRange = nil
            activeSearchHighlightRects = []
            guard let range,
                  range.location != NSNotFound,
                  range.length > 0,
                  NSMaxRange(range) <= textStorageLength(in: textView) else {
                return
            }

            activeSearchHighlightRange = range
            textView.scrollRangeToVisible(range)
            drawSearchHighlight(range, in: textView)
        }

        private func hasSearchHighlightLayers(in textView: UITextView) -> Bool {
            activeSearchHighlightLayers.contains { $0.superlayer === textView.layer }
        }

        private func drawSearchHighlight(_ range: NSRange, in textView: UITextView) {
            clearSearchHighlight(in: textView)
            activeSearchHighlightRects = []
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let glyphRange = textView.layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            let emptySelection = NSRange(location: NSNotFound, length: 0)

            textView.layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: emptySelection,
                in: textView.textContainer
            ) { rect, _ in
                guard !rect.isEmpty else { return }
                let highlightLayer = CALayer()
                highlightLayer.name = Self.searchHighlightLayerName
                highlightLayer.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.45).cgColor
                highlightLayer.cornerRadius = 3
                self.activeSearchHighlightRects.append(rect.insetBy(dx: -2, dy: -1))
                self.activeSearchHighlightLayers.append(highlightLayer)
                textView.layer.insertSublayer(highlightLayer, at: 0)
            }
            positionSearchHighlightLayers(in: textView)
        }

        private func clearSearchHighlight(in textView: UITextView) {
            activeSearchHighlightLayers.forEach { $0.removeFromSuperlayer() }
            textView.layer.sublayers?
                .filter { $0.name == Self.searchHighlightLayerName }
                .forEach { $0.removeFromSuperlayer() }
            activeSearchHighlightRects = []
            activeSearchHighlightLayers = []
        }

        private func positionSearchHighlightLayers(in textView: UITextView) {
            guard activeSearchHighlightLayers.count == activeSearchHighlightRects.count,
                  activeSearchHighlightLayers.allSatisfy({ $0.superlayer === textView.layer }) else {
                if let activeSearchHighlightRange {
                    drawSearchHighlight(activeSearchHighlightRange, in: textView)
                }
                return
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (layer, rect) in zip(activeSearchHighlightLayers, activeSearchHighlightRects) {
                layer.frame = rect.offsetBy(
                    dx: textView.textContainerInset.left - textView.contentOffset.x,
                    dy: textView.textContainerInset.top - textView.contentOffset.y
                )
            }
            CATransaction.commit()
        }

        private func syncContent(
            from textView: UITextView,
            serializesRichTextImmediately: Bool = true
        ) {
            let plainText = textView.text ?? ""
            let richTextUpdate: EditorRichTextContentUpdate
            let encodedRichText: Data?
            if serializesRichTextImmediately {
                encodedRichText = RichTextContentCodec.encode(storageAttributedText(from: textView))
                richTextUpdate = .immediate(encodedRichText)
            } else {
                // Typing keeps the live text current; the commit boundary pays
                // for full RTF serialization.
                encodedRichText = richTextContentData.wrappedValue
                richTextUpdate = .deferred(deferredRichTextContentEncoder(for: textView))
            }

            guard text.wrappedValue != plainText
                || (serializesRichTextImmediately && richTextContentData.wrappedValue != encodedRichText) else {
                clearAppliedContentIfSynced()
                return
            }

            if isUpdatingUIView {
                appliedPlainTextAwaitingBinding = plainText
                appliedRichTextDataAwaitingBinding = encodedRichText
                RunLoop.main.perform { [weak self] in
                    guard let self else { return }
                    guard self.text.wrappedValue != plainText
                        || self.richTextContentData.wrappedValue != encodedRichText else {
                        self.clearAppliedContentIfSynced()
                        return
                    }
                    self.text.wrappedValue = plainText
                    self.richTextContentData.wrappedValue = encodedRichText
                    self.onContentChanged(plainText, richTextUpdate)
                    self.clearAppliedContentIfSynced()
                }
                return
            }

            text.wrappedValue = plainText
            if serializesRichTextImmediately {
                richTextContentData.wrappedValue = encodedRichText
            }
            onContentChanged(plainText, richTextUpdate)
            clearAppliedContentIfSynced()
        }

        private func deferredRichTextContentEncoder(for textView: UITextView) -> DeferredRichTextContentEncoder {
            DeferredRichTextContentEncoder { [weak self, weak textView] in
                guard let self, let textView else { return nil }
                return RichTextContentCodec.encode(self.storageAttributedText(from: textView))
            }
        }

        private func storageAttributedText(from textView: UITextView) -> NSAttributedString {
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let fullRange = NSRange(location: 0, length: mutable.length)

            // Auto text is painted with defaultTextColor for the live editor so
            // UIKit does not show black attributed text in dark mode. Before
            // save/sync, remove that display-only color so Auto is stored as no
            // explicit foreground attribute.
            mutable.enumerateAttribute(.autoTextColorDisplay, in: fullRange) { value, range, _ in
                guard value != nil else { return }
                mutable.removeAttribute(.foregroundColor, range: range)
                stripDefaultDecorationColor(.underlineColor, in: mutable, range: range, textView: textView)
                stripDefaultDecorationColor(.strikethroughColor, in: mutable, range: range, textView: textView)
                mutable.removeAttribute(.autoTextColorDisplay, range: range)
            }
            mutable.removeAttribute(.autoTextColorDisplay, range: fullRange)

            return mutable
        }

        private func stripDefaultDecorationColor(
            _ key: NSAttributedString.Key,
            in attributedText: NSMutableAttributedString,
            range: NSRange,
            textView: UITextView
        ) {
            attributedText.enumerateAttribute(key, in: range) { value, range, _ in
                guard let color = value as? UIColor,
                      isEditorDefaultTextColor(color, in: textView) else { return }
                attributedText.removeAttribute(key, range: range)
            }
        }

        private func isEditorDefaultTextColor(_ color: UIColor, in textView: UITextView) -> Bool {
            color.resolvedColor(with: textView.traitCollection)
                .isApproximatelyEqual(to: defaultTextColor.resolvedColor(with: textView.traitCollection))
        }

        var hasUnsyncedAppliedContent: Bool {
            guard let appliedPlainTextAwaitingBinding else { return false }
            return text.wrappedValue != appliedPlainTextAwaitingBinding
                || richTextContentData.wrappedValue != appliedRichTextDataAwaitingBinding
        }

        func clearAppliedContentIfSynced() {
            guard let appliedPlainTextAwaitingBinding else { return }
            if text.wrappedValue == appliedPlainTextAwaitingBinding
                && richTextContentData.wrappedValue == appliedRichTextDataAwaitingBinding {
                self.appliedPlainTextAwaitingBinding = nil
                appliedRichTextDataAwaitingBinding = nil
            }
        }

        func reportFormattingState(from textView: UITextView, allowsLargeSelectionScan: Bool = false) {
            let state = formattingState(from: textView, allowsLargeSelectionScan: allowsLargeSelectionScan)
            guard state != lastReportedFormattingState else { return }
            lastReportedFormattingState = state
            if isUpdatingUIView {
                RunLoop.main.perform { [weak self] in
                    guard let self, self.lastReportedFormattingState == state else { return }
                    self.onFormattingStateChanged(state)
                }
                return
            }
            onFormattingStateChanged(state)
        }

        func reportUndoManagerChanged(_ undoManager: UndoManager?) {
            if isUpdatingUIView {
                RunLoop.main.perform { [weak self] in
                    self?.onUndoManagerChanged(undoManager)
                }
                return
            }
            onUndoManagerChanged(undoManager)
        }

        func applyBoundContent(
            plainText: String,
            richTextContentData: Data?,
            in textView: UITextView
        ) {
            let desiredAttributedText = RichTextContentCodec.decode(
                richTextData: richTextContentData,
                plainText: plainText,
                baseFont: textView.font ?? defaultEditorTextFont
            )
            let normalizedAttributedText = RichTextContentCodec.normalizedForDisplay(
                desiredAttributedText,
                traitCollection: textView.traitCollection,
                defaultTextColor: defaultTextColor
            )
            guard !textView.attributedText.isEqual(to: normalizedAttributedText) else {
                return
            }

            let selectedRange = textView.selectedRange
            isApplyingBoundContent = true
            defer { isApplyingBoundContent = false }
            textView.attributedText = normalizedAttributedText
            applyChecklistRendering(in: textView)
            let newLength = textStorageLength(in: textView)
            let clampedLocation = min(max(selectedRange.location, 0), newLength)
            let clampedLength = min(selectedRange.length, max(newLength - clampedLocation, 0))
            let restoredRange = NSRange(location: clampedLocation, length: clampedLength)
            restoreSelectionWithoutScrolling(restoredRange, in: textView)
            lastKnownSelectionRange = restoredRange
            reportFormattingState(from: textView)
        }

        func captureCurrentSelection(in textView: UITextView) {
            let selectedRange = textView.selectedRange
            guard selectedRange.length > 0 else { return }
            lastKnownSelectionRange = selectedRange
            reportFormattingState(from: textView)
        }

        func lookupCurrentSelection(in textView: UITextView) {
            let selectedText = selectedPlainText(in: textView)

            // This function is triggered from updateUIView after SwiftUI sees
            // lookupSelectionToggleToken change. Do not mutate parent @State
            // synchronously during updateUIView; defer so the sheet presentation
            // is scheduled after the representable update completes.
            RunLoop.main.perform { [weak self] in
                self?.onLookupSelection(selectedText)
            }

            // Do not immediately refocus the editor here. Refocusing can fight
            // SwiftUI sheet presentation for the dictionary controller.
            reportFormattingState(from: textView)
        }

        func pinCurrentSelection(in textView: UITextView) {
            let cursorRange = textView.selectedRange.location != NSNotFound
                ? textView.selectedRange
                : lastKnownSelectionRange
            let fullText = textView.text as NSString
            guard cursorRange.location != NSNotFound,
                  cursorRange.location <= fullText.length else {
                _ = onPinSelection("")
                return
            }

            let pinCandidate = ChecklistItemEditor.pinCandidate(in: fullText, selection: cursorRange)
            guard let pinCandidate else {
                _ = onPinSelection("")
                return
            }

            lastKnownSelectionRange = cursorRange
            let textToPin = pinCandidate.text
            let deletionRange = pinCandidate.sourceRange
            guard onPinSelection(textToPin) else {
                textView.selectedRange = cursorRange
                textView.becomeFirstResponder()
                reportFormattingState(from: textView)
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            mutable.deleteCharacters(in: deletionRange)
            let caretLocation = min(deletionRange.location, mutable.length)
            applyAttributedText(mutable, in: textView, selectedRange: NSRange(location: caretLocation, length: 0))
            textView.becomeFirstResponder()
            reportUndoManagerChanged(textView.undoManager)
        }

        private func selectedPlainText(in textView: UITextView) -> String {
            let fullText = textView.text as NSString
            let currentRange = safeSelectedRange(in: textView)
            if currentRange.length > 0,
               NSMaxRange(currentRange) <= fullText.length {
                lastKnownSelectionRange = currentRange
                return fullText.substring(with: currentRange)
            }

            let cachedRange = lastKnownSelectionRange
            if cachedRange.length > 0,
               cachedRange.location != NSNotFound,
               NSMaxRange(cachedRange) <= fullText.length {
                restoreSelectionWithoutScrolling(cachedRange, in: textView)
                return fullText.substring(with: cachedRange)
            }

            return ""
        }

        func appendUnpinnedThought(_ thoughtText: String, in textView: UITextView) {
            let trimmedThought = thoughtText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedThought.isEmpty else { return }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let needsSeparator = mutable.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let appendedText = needsSeparator ? "\n\n\(trimmedThought)" : trimmedThought
            let appendRange = NSRange(location: mutable.length, length: appendedText.utf16.count)
            mutable.append(NSAttributedString(
                string: appendedText,
                attributes: defaultTextAttributes(for: textView)
            ))
            applyAttributedText(
                mutable,
                in: textView,
                selectedRange: NSRange(location: NSMaxRange(appendRange), length: 0)
            )
        }

        func ensureEditorTypingParagraphStyle(in textView: UITextView) {
            guard textView.typingAttributes[.paragraphStyle] == nil else { return }
            var typingAttributes = textView.typingAttributes
            typingAttributes[.paragraphStyle] = ChecklistItemEditor.bodyParagraphStyle(
                hasChecklistItems: ChecklistItemEditor.containsChecklistItems(in: textView.text as NSString)
            )
            textView.typingAttributes = typingAttributes
        }

        private func defaultTextAttributes(for textView: UITextView) -> [NSAttributedString.Key: Any] {
            [
                .font: textView.font ?? defaultEditorTextFont,
                .foregroundColor: defaultTextColor,
                .paragraphStyle: ChecklistItemEditor.bodyParagraphStyle(
                    hasChecklistItems: ChecklistItemEditor.containsChecklistItems(in: textView.text as NSString)
                )
            ]
        }

        private func formattingState(
            from textView: UITextView,
            allowsLargeSelectionScan: Bool = false
        ) -> EditorFormattingState {
            let range = effectiveSelectionRange(in: textView)
            let usesLargeSelectionPath = EditorSelectionFormattingPolicy
                .shouldDeferFullFormattingScan(selectionLength: range.length)
            let needsFullState = usesLargeSelectionPath && allowsLargeSelectionScan
            if let cachedState = selectionFormattingCache.formattingState,
               !selectionFormattingCache.formattingStateIsDirty,
               NSEqualRanges(selectionFormattingCache.range, range),
               !(needsFullState && selectionFormattingCache.formattingStateIsApproximate) {
                return cachedState
            }

            let state: EditorFormattingState
            let isApproximate: Bool
            if usesLargeSelectionPath && !allowsLargeSelectionScan {
                state = approximateFormattingState(from: textView, range: range)
                isApproximate = true
            } else {
                state = fullFormattingState(from: textView, range: range)
                isApproximate = false
            }
            selectionFormattingCache.update(
                range: range,
                formattingState: state,
                isApproximate: isApproximate
            )
            return state
        }

        private func fullFormattingState(from textView: UITextView, range: NSRange) -> EditorFormattingState {
            let font = selectedFont(in: textView, range: range)
            let foregroundColor = selectedForegroundColor(in: textView, range: range)
            return EditorFormattingState(
                bold: hasTrait(.traitBold, in: textView, range: range),
                italic: hasTrait(.traitItalic, in: textView, range: range),
                underline: hasDecoration(.underlineStyle, in: textView, range: range),
                strikethrough: hasDecoration(.strikethroughStyle, in: textView, range: range),
                fontSize: font.pointSize,
                foregroundColor: foregroundColor
            )
        }

        private func approximateFormattingState(
            from textView: UITextView,
            range: NSRange
        ) -> EditorFormattingState {
            let font = selectedFont(in: textView, range: range)
            let foregroundColor = selectedForegroundColor(in: textView, range: range)
            return EditorFormattingState(
                bold: approximateTrait(.traitBold, in: textView, range: range),
                italic: approximateTrait(.traitItalic, in: textView, range: range),
                underline: approximateDecoration(.underlineStyle, in: textView, range: range),
                strikethrough: approximateDecoration(.strikethroughStyle, in: textView, range: range),
                fontSize: font.pointSize,
                foregroundColor: foregroundColor
            )
        }

        private func approximateTrait(
            _ trait: UIFontDescriptor.SymbolicTraits,
            in textView: UITextView,
            range: NSRange
        ) -> Bool {
            let font = selectedFont(in: textView, range: range)
            return font.fontDescriptor.symbolicTraits.contains(trait)
        }

        private func approximateDecoration(
            _ key: NSAttributedString.Key,
            in textView: UITextView,
            range: NSRange
        ) -> Bool {
            if range.length == 0 {
                return (textView.typingAttributes[key] as? Int ?? 0) != 0
            }
            if range.location < textView.attributedText.length {
                return (textView.attributedText.attribute(key, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
            }
            return false
        }

        private func selectedFont(in textView: UITextView, range: NSRange) -> UIFont {
            if range.length == 0 {
                return (textView.typingAttributes[.font] as? UIFont)
                    ?? textView.font
                    ?? defaultEditorTextFont
            }
            if range.location < textView.attributedText.length,
               let font = textView.attributedText.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont {
                return font
            }
            return textView.font ?? defaultEditorTextFont
        }

        private func selectedForegroundColor(in textView: UITextView, range: NSRange) -> UIColor? {
            if range.length == 0 {
                return textView.typingAttributes[.foregroundColor] as? UIColor
            }
            if range.location < textView.attributedText.length {
                return textView.attributedText.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
            }
            return nil
        }

        private func hasTrait(
            _ trait: UIFontDescriptor.SymbolicTraits,
            in textView: UITextView,
            range: NSRange
        ) -> Bool {
            if range.length == 0 {
                let font = (textView.typingAttributes[.font] as? UIFont)
                    ?? textView.font
                    ?? defaultEditorTextFont
                return font.fontDescriptor.symbolicTraits.contains(trait)
            }

            var hasAll = true
            textView.attributedText.enumerateAttribute(.font, in: range) { value, _, stop in
                let font = value as? UIFont ?? defaultEditorTextFont
                if !font.fontDescriptor.symbolicTraits.contains(trait) {
                    hasAll = false
                    stop.pointee = true
                }
            }
            return hasAll
        }

        private func hasDecoration(
            _ key: NSAttributedString.Key,
            in textView: UITextView,
            range: NSRange
        ) -> Bool {
            if range.length == 0 {
                return (textView.typingAttributes[key] as? Int ?? 0) != 0
            }

            var hasAll = true
            textView.attributedText.enumerateAttribute(key, in: range) { value, _, stop in
                if (value as? Int ?? 0) == 0 {
                    hasAll = false
                    stop.pointee = true
                }
            }
            return hasAll
        }

        private func toggleFontTrait(_ trait: UIFontDescriptor.SymbolicTraits, in textView: UITextView) {
            let selectedRange = formattingActionRange(in: textView)

            if selectedRange.length == 0 {
                var typingAttributes = textView.typingAttributes
                let baseFont = (typingAttributes[.font] as? UIFont)
                    ?? textView.font
                    ?? defaultEditorTextFont
                let shouldApply = !baseFont.fontDescriptor.symbolicTraits.contains(trait)
                typingAttributes[.font] = fontBySettingTrait(
                    on: baseFont,
                    trait: trait,
                    isEnabled: shouldApply
                )
                textView.typingAttributes = typingAttributes
                markSelectionFormattingDirty(from: textView)
                reportFormattingState(from: textView)
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let shouldApply = shouldApplyFontTrait(in: mutable, range: selectedRange, trait: trait)
            mutable.enumerateAttribute(.font, in: selectedRange) { value, range, _ in
                let baseFont = (value as? UIFont)
                    ?? textView.font
                    ?? defaultEditorTextFont
                mutable.addAttribute(
                    .font,
                    value: fontBySettingTrait(
                        on: baseFont,
                        trait: trait,
                        isEnabled: shouldApply
                    ),
                    range: range
                )
            }
            applyAttributedText(mutable, in: textView, selectedRange: selectedRange)
        }

        private func shouldApplyFontTrait(
            in attributedText: NSAttributedString,
            range: NSRange,
            trait: UIFontDescriptor.SymbolicTraits
        ) -> Bool {
            var hasTraitMissing = false
            attributedText.enumerateAttribute(.font, in: range) { value, _, stop in
                let font = value as? UIFont ?? defaultEditorTextFont
                if !font.fontDescriptor.symbolicTraits.contains(trait) {
                    hasTraitMissing = true
                    stop.pointee = true
                }
            }
            return hasTraitMissing
        }

        private func fontBySettingTrait(
            on baseFont: UIFont,
            trait: UIFontDescriptor.SymbolicTraits,
            isEnabled: Bool
        ) -> UIFont {
            var traits = baseFont.fontDescriptor.symbolicTraits
            if isEnabled {
                traits.insert(trait)
            } else {
                traits.remove(trait)
            }

            if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) {
                return UIFont(descriptor: descriptor, size: baseFont.pointSize)
            }

            let systemDescriptor = UIFont.systemFont(ofSize: baseFont.pointSize).fontDescriptor
            if let descriptor = systemDescriptor.withSymbolicTraits(traits) {
                return UIFont(descriptor: descriptor, size: baseFont.pointSize)
            }

            if trait == .traitBold {
                if isEnabled {
                    return UIFont.boldSystemFont(ofSize: baseFont.pointSize)
                }
                if traits.contains(.traitItalic) {
                    return UIFont.italicSystemFont(ofSize: baseFont.pointSize)
                }
                return UIFont.systemFont(ofSize: baseFont.pointSize)
            }

            if trait == .traitItalic {
                if isEnabled {
                    return UIFont.italicSystemFont(ofSize: baseFont.pointSize)
                }
                if traits.contains(.traitBold) {
                    return UIFont.boldSystemFont(ofSize: baseFont.pointSize)
                }
                return UIFont.systemFont(ofSize: baseFont.pointSize)
            }

            return baseFont
        }

        private func adjustedFontSize(from baseFont: UIFont, delta: CGFloat) -> UIFont {
            let newPointSize = min(max(baseFont.pointSize + delta, 11), 40)
            return UIFont(descriptor: baseFont.fontDescriptor, size: newPointSize)
        }

        private func toggleTextDecoration(in textView: UITextView, key: NSAttributedString.Key) {
            let selectedRange = formattingActionRange(in: textView)
            let colorKey = decorationColorKey(for: key)

            if selectedRange.length == 0 {
                var typingAttributes = textView.typingAttributes
                let currentValue = typingAttributes[key] as? Int ?? 0
                let shouldApply = currentValue == 0
                typingAttributes[key] = shouldApply ? NSUnderlineStyle.single.rawValue : 0
                if let colorKey {
                    if shouldApply, let color = typingAttributes[.foregroundColor] as? UIColor {
                        typingAttributes[colorKey] = color
                    } else {
                        typingAttributes.removeValue(forKey: colorKey)
                    }
                }
                textView.typingAttributes = typingAttributes
                markSelectionFormattingDirty(from: textView)
                reportFormattingState(from: textView)
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let shouldApply = shouldApplyDecoration(in: mutable, range: selectedRange, key: key)
            let value = shouldApply ? NSUnderlineStyle.single.rawValue : 0
            mutable.addAttribute(key, value: value, range: selectedRange)
            if let colorKey {
                if shouldApply {
                    mutable.enumerateAttribute(.foregroundColor, in: selectedRange) { foregroundColor, range, _ in
                        if let foregroundColor {
                            mutable.addAttribute(colorKey, value: foregroundColor, range: range)
                        } else {
                            mutable.removeAttribute(colorKey, range: range)
                        }
                    }
                } else {
                    mutable.removeAttribute(colorKey, range: selectedRange)
                }
            }
            applyAttributedText(mutable, in: textView, selectedRange: selectedRange)
        }

        private func syncDecorationColorsWithForeground(
            in typingAttributes: inout [NSAttributedString.Key: Any],
            color: UIColor?
        ) {
            syncDecorationColor(
                in: &typingAttributes,
                styleKey: .underlineStyle,
                colorKey: .underlineColor,
                color: color
            )
            syncDecorationColor(
                in: &typingAttributes,
                styleKey: .strikethroughStyle,
                colorKey: .strikethroughColor,
                color: color
            )
        }

        private func syncDecorationColor(
            in typingAttributes: inout [NSAttributedString.Key: Any],
            styleKey: NSAttributedString.Key,
            colorKey: NSAttributedString.Key,
            color: UIColor?
        ) {
            let style = typingAttributes[styleKey] as? Int ?? 0
            guard style != 0 else {
                typingAttributes.removeValue(forKey: colorKey)
                return
            }

            if let color {
                typingAttributes[colorKey] = color
            } else {
                typingAttributes.removeValue(forKey: colorKey)
            }
        }

        private func syncDecorationColorsWithForeground(
            in attributedText: NSMutableAttributedString,
            range: NSRange,
            color: UIColor?
        ) {
            syncDecorationColor(
                in: attributedText,
                range: range,
                styleKey: .underlineStyle,
                colorKey: .underlineColor,
                color: color
            )
            syncDecorationColor(
                in: attributedText,
                range: range,
                styleKey: .strikethroughStyle,
                colorKey: .strikethroughColor,
                color: color
            )
        }

        private func syncDecorationColor(
            in attributedText: NSMutableAttributedString,
            range: NSRange,
            styleKey: NSAttributedString.Key,
            colorKey: NSAttributedString.Key,
            color: UIColor?
        ) {
            attributedText.enumerateAttribute(styleKey, in: range) { value, range, _ in
                let style = value as? Int ?? 0
                guard style != 0 else {
                    attributedText.removeAttribute(colorKey, range: range)
                    return
                }

                if let color {
                    attributedText.addAttribute(colorKey, value: color, range: range)
                } else {
                    attributedText.removeAttribute(colorKey, range: range)
                }
            }
        }

        private func decorationColorKey(for key: NSAttributedString.Key) -> NSAttributedString.Key? {
            switch key {
            case .underlineStyle:
                return .underlineColor
            case .strikethroughStyle:
                return .strikethroughColor
            default:
                return nil
            }
        }

        private func shouldApplyDecoration(
            in attributedText: NSAttributedString,
            range: NSRange,
            key: NSAttributedString.Key
        ) -> Bool {
            var hasUndecoratedSegment = false
            attributedText.enumerateAttribute(key, in: range) { value, _, stop in
                let style = value as? Int ?? 0
                if style == 0 {
                    hasUndecoratedSegment = true
                    stop.pointee = true
                }
            }
            return hasUndecoratedSegment
        }

        private func applyAttributedText(
            _ attributedText: NSAttributedString,
            in textView: UITextView,
            selectedRange: NSRange,
            animated: Bool = false,
            registersUndo: Bool = true
        ) {
            let previousText = NSAttributedString(attributedString: textView.attributedText)
            let previousSelection = textView.selectedRange
            let styledText = NSMutableAttributedString(attributedString: attributedText)
            _ = ChecklistItemEditor.applyEditorRendering(in: styledText)
            let previousTypingAttributes = textView.typingAttributes

            let applyUpdates = {
                textView.attributedText = styledText
                self.restoreSelectionWithoutScrolling(selectedRange, in: textView)
                if selectedRange.length == 0 {
                    textView.typingAttributes = previousTypingAttributes
                }
                self.updateEditorLayout(in: textView)
            }

            if animated {
                UIView.transition(
                    with: textView,
                    duration: 0.16,
                    options: [.transitionCrossDissolve, .allowUserInteraction]
                ) {
                    applyUpdates()
                }
            } else {
                applyUpdates()
            }

            lastKnownSelectionRange = selectedRange
            syncContent(from: textView)
            if registersUndo {
                registerFormattingUndo(
                    in: textView,
                    previousText: previousText,
                    previousSelection: previousSelection
                )
            }
            markSelectionFormattingDirty(from: textView)
            reportFormattingState(from: textView)
        }

        func applyChecklistRendering(in textView: UITextView) {
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            guard ChecklistItemEditor.applyEditorRendering(in: mutable) else {
                updateEditorLayout(in: textView)
                return
            }

            let selectedRange = textView.selectedRange
            textView.attributedText = mutable
            updateEditorLayout(in: textView)
            let newLength = textStorageLength(in: textView)
            let safeLocation = min(selectedRange.location, newLength)
            let safeLength = min(selectedRange.length, newLength - safeLocation)
            let safeRange = NSRange(location: safeLocation, length: safeLength)
            restoreSelectionWithoutScrolling(safeRange, in: textView)
            lastKnownSelectionRange = safeRange
        }

        func updateEditorLayout(in textView: UITextView) {
            let hasChecklistItems = ChecklistItemEditor.containsChecklistItems(in: textView.text as NSString)
            let desiredInsets = ChecklistItemEditor.textContainerInsets(hasChecklistItems: hasChecklistItems)
            if textView.textContainerInset != desiredInsets {
                textView.textContainerInset = desiredInsets
            }
        }

        private func effectiveSelectionRange(in textView: UITextView) -> NSRange {
            let currentRange = textView.selectedRange
            if currentRange.length > 0 {
                return currentRange
            }

            guard !textView.isFirstResponder else {
                return currentRange
            }

            let fullLength = textStorageLength(in: textView)
            let cachedRange = lastKnownSelectionRange
            if cachedRange.length > 0, cachedRange.location + cachedRange.length <= fullLength {
                return cachedRange
            }

            return currentRange
        }

        private func formattingActionRange(in textView: UITextView) -> NSRange {
            let currentRange = safeSelectedRange(in: textView)
            if currentRange.length > 0 {
                lastKnownSelectionRange = currentRange
                return currentRange
            }

            if textView.isFirstResponder {
                lastKnownSelectionRange = currentRange
                return currentRange
            }

            let fullLength = textStorageLength(in: textView)
            let cachedRange = lastKnownSelectionRange
            if cachedRange.length > 0, cachedRange.location + cachedRange.length <= fullLength {
                restoreSelectionWithoutScrolling(cachedRange, in: textView)
                return cachedRange
            }

            return currentRange
        }

        private func updateLastKnownSelectionRange(from textView: UITextView) {
            let range = safeSelectedRange(in: textView)
            if range.length > 0 || textView.isFirstResponder {
                lastKnownSelectionRange = range
            }
        }

        private func cacheSelectionFormattingRange(from textView: UITextView) {
            let range = safeSelectedRange(in: textView)
            if range.length > 0 || textView.isFirstResponder {
                lastKnownSelectionRange = range
            }
            // Selection drags can fire hundreds of callbacks. Keep the live
            // callback to cached range bookkeeping; formatting is refreshed on
            // demand by commands and focus changes.
            selectionFormattingCache.markDirty(range: range)
        }

        private func markSelectionFormattingDirty(from textView: UITextView) {
            selectionFormattingCache.markDirty(range: effectiveSelectionRange(in: textView))
        }

        private func applyPendingFocusTapSelection(in textView: UITextView) {
#if targetEnvironment(macCatalyst)
            if pendingFocusTapContext != nil {
                restorePendingFocusTapSelection(in: textView, clear: true)
                isHandlingUserFocusChange = false
                return
            }
#endif

            if let focusAcquisitionSelectionRange,
               isValidSelectionRange(focusAcquisitionSelectionRange, in: textView) {
                restoreSelectionWithoutScrolling(focusAcquisitionSelectionRange, in: textView)
                lastKnownSelectionRange = focusAcquisitionSelectionRange
            } else {
                updateLastKnownSelectionRange(from: textView)
            }
            self.focusAcquisitionSelectionRange = nil
            isHandlingUserFocusChange = false
        }

        private func safeSelectedRange(in textView: UITextView) -> NSRange {
            let textLength = textStorageLength(in: textView)
            let selectedRange = textView.selectedRange
            guard selectedRange.location != NSNotFound else {
                return NSRange(location: textLength, length: 0)
            }

            let safeLocation = min(max(selectedRange.location, 0), textLength)
            let safeLength = min(selectedRange.length, max(textLength - safeLocation, 0))
            return NSRange(location: safeLocation, length: safeLength)
        }

        private func isValidSelectionRange(_ range: NSRange, in textView: UITextView) -> Bool {
            range.location != NSNotFound
                && range.location >= 0
                && range.length >= 0
                && NSMaxRange(range) <= textStorageLength(in: textView)
        }

        private func restoreSelectionWithoutScrolling(_ range: NSRange, in textView: UITextView) {
            let previousOffset = textView.contentOffset
            restoreSelection(range, preserving: previousOffset, in: textView)
        }

        private func restoreSelection(_ range: NSRange, preserving contentOffset: CGPoint, in textView: UITextView) {
            textView.selectedRange = range
            textView.setContentOffset(contentOffset, animated: false)
        }

        private func textStorageLength(in textView: UITextView) -> Int {
            textView.textStorage.length
        }

#if targetEnvironment(macCatalyst)
        private func restorePendingFocusTapSelection(in textView: UITextView, clear: Bool) {
            guard let pendingFocusTapContext else { return }

            let textLength = textStorageLength(in: textView)
            let location = min(max(pendingFocusTapContext.range.location, 0), textLength)
            let range = NSRange(location: location, length: 0)
            restoreSelection(range, preserving: pendingFocusTapContext.contentOffset, in: textView)
            lastKnownSelectionRange = range

            if clear {
                self.pendingFocusTapContext = nil
                isHandlingUserFocusChange = false
            }
        }
#endif
    }
}

enum EditorPasteFormatter {
    static func attributedString(
        matchingDestinationFormattingFor text: String,
        typingAttributes: [NSAttributedString.Key: Any],
        defaultAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        var attributes = defaultAttributes
        typingAttributes.forEach { key, value in
            attributes[key] = value
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}

enum ChecklistItemEditor {
    static let uncheckedPrefix = "☐\t"
    static let checkedPrefix = "☑︎\t"
    static let checkedPrefixVariant = "☑\t"
    static let legacyUncheckedGlyphPrefix = "☐ "
    static let legacyCheckedGlyphPrefix = "☑︎ "
    static let legacyCheckedGlyphPrefixVariant = "☑ "
    static let legacyUncheckedPrefix = "- [ ] "
    static let legacyCheckedPrefix = "- [x] "
    static let legacyShortUncheckedPrefix = "[ ] "
    static let legacyShortCheckedPrefix = "[x] "

    private static let autoChecklistStrikethroughKey = NSAttributedString.Key("com.apexcoretechs.myram.checklist-auto-strikethrough")
    private static let minimumChecklistGutterWidth: CGFloat = 28
    private static let checklistGutterReferenceFontSize: CGFloat = 20
    private static let uncheckedChecklistIconFontSize = checklistGutterReferenceFontSize
    private static let checkedChecklistIconFontSize = checklistGutterReferenceFontSize
    private static let checklistGutterWidth: CGFloat = {
        let iconFont = UIFont.systemFont(ofSize: checklistGutterReferenceFontSize, weight: .regular)
        let uncheckedWidth = (uncheckedPrefix.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .size(withAttributes: [.font: iconFont])
            .width
        let checkedWidth = (checkedPrefix.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .size(withAttributes: [.font: iconFont])
            .width
        return max(minimumChecklistGutterWidth, ceil(max(uncheckedWidth, checkedWidth)) + 12)
    }()
    private static let paragraphSpacing: CGFloat = UIFont.preferredFont(forTextStyle: .body).lineHeight * 0.5
    private static let compactTextInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
    static let gutterTapWidth: CGFloat = 44

    static var editorParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = 0
        style.lineBreakMode = .byWordWrapping
        applyParagraphSpacing(to: style)
        return style
    }

    static func bodyParagraphStyle(hasChecklistItems: Bool) -> NSParagraphStyle {
        guard hasChecklistItems else { return editorParagraphStyle }

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = checklistGutterWidth
        style.headIndent = checklistGutterWidth
        style.tabStops = [NSTextTab(textAlignment: .left, location: checklistGutterWidth)]
        style.defaultTabInterval = checklistGutterWidth
        style.lineBreakMode = .byWordWrapping
        applyParagraphSpacing(to: style)
        return style
    }

    static func textContainerInsets(hasChecklistItems: Bool) -> UIEdgeInsets {
        guard hasChecklistItems else { return compactTextInset }
        return UIEdgeInsets(
            top: compactTextInset.top,
            left: compactTextInset.left,
            bottom: compactTextInset.bottom,
            right: compactTextInset.right + checklistGutterWidth
        )
    }

    private static var checklistParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = checklistGutterWidth
        style.tabStops = [NSTextTab(textAlignment: .left, location: checklistGutterWidth)]
        style.defaultTabInterval = checklistGutterWidth
        style.lineBreakMode = .byWordWrapping
        applyParagraphSpacing(to: style)
        return style
    }

    private static func applyParagraphSpacing(to style: NSMutableParagraphStyle) {
        style.lineSpacing = 0
        style.paragraphSpacing = paragraphSpacing
    }

    static func applyChecklistAction(
        in attributedText: NSMutableAttributedString,
        selection: NSRange
    ) -> NSRange {
        let text = attributedText.string as NSString
        let clampedSelectionLocation = min(max(selection.location, 0), text.length)
        let lineRangeWithNewline = text.lineRange(for: NSRange(location: clampedSelectionLocation, length: 0))
        let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
        let line = text.substring(with: lineRange)

        let replacement: (range: NSRange, prefix: String)
        if line.hasPrefix(checkedPrefix) {
            replacement = (NSRange(location: lineRange.location, length: checkedPrefix.utf16.count), uncheckedPrefix)
        } else if line.hasPrefix(checkedPrefixVariant) {
            replacement = (NSRange(location: lineRange.location, length: checkedPrefixVariant.utf16.count), uncheckedPrefix)
        } else if line.hasPrefix(uncheckedPrefix) {
            replacement = (NSRange(location: lineRange.location, length: uncheckedPrefix.utf16.count), checkedPrefix)
        } else if line.hasPrefix(legacyCheckedGlyphPrefix) {
            replacement = (NSRange(location: lineRange.location, length: legacyCheckedGlyphPrefix.utf16.count), uncheckedPrefix)
        } else if line.hasPrefix(legacyCheckedGlyphPrefixVariant) {
            replacement = (NSRange(location: lineRange.location, length: legacyCheckedGlyphPrefixVariant.utf16.count), uncheckedPrefix)
        } else if line.hasPrefix(legacyUncheckedGlyphPrefix) {
            replacement = (NSRange(location: lineRange.location, length: legacyUncheckedGlyphPrefix.utf16.count), checkedPrefix)
        } else if line.hasPrefix(legacyCheckedPrefix) {
            replacement = (NSRange(location: lineRange.location, length: legacyCheckedPrefix.utf16.count), uncheckedPrefix)
        } else if line.hasPrefix(legacyUncheckedPrefix) {
            replacement = (NSRange(location: lineRange.location, length: legacyUncheckedPrefix.utf16.count), checkedPrefix)
        } else if line.hasPrefix(legacyShortCheckedPrefix) {
            replacement = (NSRange(location: lineRange.location, length: legacyShortCheckedPrefix.utf16.count), uncheckedPrefix)
        } else if line.hasPrefix(legacyShortUncheckedPrefix) {
            replacement = (NSRange(location: lineRange.location, length: legacyShortUncheckedPrefix.utf16.count), checkedPrefix)
        } else {
            replacement = (NSRange(location: lineRange.location, length: 0), uncheckedPrefix)
        }

        let delta = replacement.prefix.utf16.count - replacement.range.length
        attributedText.replaceCharacters(in: replacement.range, with: replacement.prefix)
        _ = applyEditorRendering(in: attributedText)

        let oldLocation = clampedSelectionLocation
        let adjustedLocation: Int
        if oldLocation < replacement.range.location {
            adjustedLocation = oldLocation
        } else if oldLocation <= replacement.range.location + replacement.range.length {
            adjustedLocation = replacement.range.location + replacement.prefix.utf16.count
        } else {
            adjustedLocation = oldLocation + delta
        }

        let newLength = attributedText.length
        return NSRange(location: min(max(adjustedLocation, 0), newLength), length: 0)
    }

    @discardableResult
    static func applyEditorRendering(in attributedText: NSMutableAttributedString) -> Bool {
        let previous = attributedText.copy() as? NSAttributedString
        normalizeLegacyPrefixes(in: attributedText)
        applyEditorParagraphStyles(in: attributedText)
        applyChecklistPrefixRendering(in: attributedText)
        let fullRange = NSRange(location: 0, length: attributedText.length)

        var autoRanges: [NSRange] = []
        attributedText.enumerateAttribute(autoChecklistStrikethroughKey, in: fullRange) { value, range, _ in
            if (value as? Bool) == true {
                autoRanges.append(range)
            }
        }

        autoRanges.forEach { range in
            attributedText.removeAttribute(.strikethroughStyle, range: range)
            attributedText.removeAttribute(.strikethroughColor, range: range)
            attributedText.removeAttribute(autoChecklistStrikethroughKey, range: range)
        }

        checkedContentRanges(in: attributedText.string as NSString).forEach { range in
            guard range.length > 0 else { return }
            attributedText.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: range
            )
            attributedText.addAttribute(
                autoChecklistStrikethroughKey,
                value: true,
                range: range
            )
        }

        return previous?.isEqual(to: attributedText) == false
    }

    static func checkedContentRanges(in text: NSString) -> [NSRange] {
        guard text.length > 0 else { return [] }

        var ranges: [NSRange] = []
        var cursor = 0
        while cursor < text.length {
            let lineRangeWithNewline = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
            let line = text.substring(with: lineRange)

            let prefixLength: Int?
            if line.hasPrefix(checkedPrefix) {
                prefixLength = checkedPrefix.utf16.count
            } else if line.hasPrefix(checkedPrefixVariant) {
                prefixLength = checkedPrefixVariant.utf16.count
            } else if line.hasPrefix(legacyCheckedGlyphPrefix) {
                prefixLength = legacyCheckedGlyphPrefix.utf16.count
            } else if line.hasPrefix(legacyCheckedGlyphPrefixVariant) {
                prefixLength = legacyCheckedGlyphPrefixVariant.utf16.count
            } else {
                prefixLength = nil
            }

            if let prefixLength {
                let start = lineRange.location + prefixLength
                let length = max(lineRange.length - prefixLength, 0)
                ranges.append(NSRange(location: start, length: length))
            }

            let nextCursor = lineRangeWithNewline.location + lineRangeWithNewline.length
            if nextCursor <= cursor { break }
            cursor = nextCursor
        }
        return ranges
    }

    static func pinCandidate(in text: NSString, selection: NSRange) -> (text: String, sourceRange: NSRange)? {
        guard text.length > 0,
              selection.location != NSNotFound,
              selection.location <= text.length else { return nil }

        let lineProbeLocation = min(selection.location, max(text.length - 1, 0))
        let lineRangeWithNewline = text.lineRange(for: NSRange(location: lineProbeLocation, length: 0))
        let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
        let line = text.substring(with: lineRange)
        let prefixLength = checklistPrefixLength(in: line) ?? 0
        guard lineRange.length >= prefixLength else { return nil }

        let contentRange = NSRange(
            location: lineRange.location + prefixLength,
            length: lineRange.length - prefixLength
        )
        let pinnedText = text.substring(with: contentRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pinnedText.isEmpty else { return nil }

        return (pinnedText, lineRangeWithNewline)
    }

    static func isChecklistIcon(at characterIndex: Int, in text: NSString) -> Bool {
        guard text.length > 0 else { return false }
        let clampedLocation = min(max(characterIndex, 0), max(text.length - 1, 0))
        let lineRangeWithNewline = text.lineRange(for: NSRange(location: clampedLocation, length: 0))
        let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
        guard lineRange.length > 0 else { return false }

        let line = text.substring(with: lineRange)
        guard let glyphRange = checklistGlyphRange(in: line, lineLocation: lineRange.location) else {
            return false
        }

        return NSLocationInRange(clampedLocation, glyphRange)
    }


    static func isChecklistLine(at characterIndex: Int, in text: NSString) -> Bool {
        guard text.length > 0 else { return false }
        let clampedLocation = min(max(characterIndex, 0), max(text.length - 1, 0))
        let lineRangeWithNewline = text.lineRange(for: NSRange(location: clampedLocation, length: 0))
        let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
        guard lineRange.length > 0 else { return false }
        let line = text.substring(with: lineRange)
        return checklistPrefixLength(in: line) != nil
    }

    static func containsChecklistItems(in text: NSString) -> Bool {
        guard text.length > 0 else { return false }

        var cursor = 0
        while cursor < text.length {
            let lineRangeWithNewline = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
            let line = text.substring(with: lineRange)
            if checklistPrefixLength(in: line) != nil {
                return true
            }

            let nextCursor = lineRangeWithNewline.location + lineRangeWithNewline.length
            if nextCursor <= cursor { break }
            cursor = nextCursor
        }

        return false
    }

    private static func checklistIconFontSize(for line: String) -> CGFloat {
        if line.hasPrefix(uncheckedPrefix) || line.hasPrefix(legacyUncheckedGlyphPrefix) {
            return uncheckedChecklistIconFontSize
        }
        return checkedChecklistIconFontSize
    }

    private static func applyChecklistPrefixRendering(in attributedText: NSMutableAttributedString) {
        let text = attributedText.string as NSString
        guard text.length > 0 else { return }

        var cursor = 0
        while cursor < text.length {
            let lineRangeWithNewline = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
            let line = text.substring(with: lineRange)
            if let glyphRange = checklistGlyphRange(in: line, lineLocation: lineRange.location) {
                attributedText.addAttribute(
                    .font,
                    value: UIFont.systemFont(ofSize: checklistIconFontSize(for: line), weight: .regular),
                    range: glyphRange
                )
                attributedText.addAttribute(.baselineOffset, value: -1, range: glyphRange)
                attributedText.addAttribute(.foregroundColor, value: UIColor.label, range: glyphRange)
            }

            let nextCursor = lineRangeWithNewline.location + lineRangeWithNewline.length
            if nextCursor <= cursor { break }
            cursor = nextCursor
        }
    }

    private static func normalizeLegacyPrefixes(in attributedText: NSMutableAttributedString) {
        let text = attributedText.string as NSString
        guard text.length > 0 else { return }

        var replacements: [(range: NSRange, replacement: String)] = []
        var cursor = 0
        while cursor < text.length {
            let lineRangeWithNewline = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
            let line = text.substring(with: lineRange)

            if line.hasPrefix(legacyCheckedGlyphPrefix) {
                replacements.append((NSRange(location: lineRange.location, length: legacyCheckedGlyphPrefix.utf16.count), checkedPrefix))
            } else if line.hasPrefix(legacyCheckedGlyphPrefixVariant) {
                replacements.append((NSRange(location: lineRange.location, length: legacyCheckedGlyphPrefixVariant.utf16.count), checkedPrefix))
            } else if line.hasPrefix(legacyUncheckedGlyphPrefix) {
                replacements.append((NSRange(location: lineRange.location, length: legacyUncheckedGlyphPrefix.utf16.count), uncheckedPrefix))
            } else if line.hasPrefix(legacyCheckedPrefix) {
                replacements.append((NSRange(location: lineRange.location, length: legacyCheckedPrefix.utf16.count), checkedPrefix))
            } else if line.hasPrefix(legacyUncheckedPrefix) {
                replacements.append((NSRange(location: lineRange.location, length: legacyUncheckedPrefix.utf16.count), uncheckedPrefix))
            } else if line.hasPrefix(legacyShortCheckedPrefix) {
                replacements.append((NSRange(location: lineRange.location, length: legacyShortCheckedPrefix.utf16.count), checkedPrefix))
            } else if line.hasPrefix(legacyShortUncheckedPrefix) {
                replacements.append((NSRange(location: lineRange.location, length: legacyShortUncheckedPrefix.utf16.count), uncheckedPrefix))
            }

            let nextCursor = lineRangeWithNewline.location + lineRangeWithNewline.length
            if nextCursor <= cursor { break }
            cursor = nextCursor
        }

        replacements.reversed().forEach { replacement in
            attributedText.replaceCharacters(in: replacement.range, with: replacement.replacement)
        }
    }

    private static func applyEditorParagraphStyles(in attributedText: NSMutableAttributedString) {
        let text = attributedText.string as NSString
        guard text.length > 0 else { return }
        let hasChecklistItems = containsChecklistItems(in: text)

        var cursor = 0
        while cursor < text.length {
            let lineRangeWithNewline = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineRange = normalizedLineRange(from: lineRangeWithNewline, in: text)
            let line = text.substring(with: lineRange)
            let paragraphStyle = checklistPrefixLength(in: line) == nil
                ? bodyParagraphStyle(hasChecklistItems: hasChecklistItems)
                : checklistParagraphStyle

            attributedText.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: lineRangeWithNewline
            )

            let nextCursor = lineRangeWithNewline.location + lineRangeWithNewline.length
            if nextCursor <= cursor { break }
            cursor = nextCursor
        }
    }

    private static func normalizedLineRange(from lineRange: NSRange, in text: NSString) -> NSRange {
        guard lineRange.length > 0 else { return lineRange }
        var length = lineRange.length
        let lastIndex = lineRange.location + lineRange.length - 1
        if lastIndex >= 0, lastIndex < text.length, text.character(at: lastIndex) == 10 {
            length -= 1
        }
        return NSRange(location: lineRange.location, length: max(length, 0))
    }

    private static func checklistPrefixLength(in line: String) -> Int? {
        if line.hasPrefix(checkedPrefix) {
            return checkedPrefix.utf16.count
        }
        if line.hasPrefix(checkedPrefixVariant) {
            return checkedPrefixVariant.utf16.count
        }
        if line.hasPrefix(uncheckedPrefix) {
            return uncheckedPrefix.utf16.count
        }
        if line.hasPrefix(legacyCheckedGlyphPrefix) {
            return legacyCheckedGlyphPrefix.utf16.count
        }
        if line.hasPrefix(legacyCheckedGlyphPrefixVariant) {
            return legacyCheckedGlyphPrefixVariant.utf16.count
        }
        if line.hasPrefix(legacyUncheckedGlyphPrefix) {
            return legacyUncheckedGlyphPrefix.utf16.count
        }
        if line.hasPrefix(legacyCheckedPrefix) {
            return legacyCheckedPrefix.utf16.count
        }
        if line.hasPrefix(legacyUncheckedPrefix) {
            return legacyUncheckedPrefix.utf16.count
        }
        if line.hasPrefix(legacyShortCheckedPrefix) {
            return legacyShortCheckedPrefix.utf16.count
        }
        if line.hasPrefix(legacyShortUncheckedPrefix) {
            return legacyShortUncheckedPrefix.utf16.count
        }
        return nil
    }

    private static func checklistGlyphRange(in line: String, lineLocation: Int) -> NSRange? {
        let prefixLength: Int
        let delimiterLength: Int
        if line.hasPrefix(checkedPrefix) {
            prefixLength = checkedPrefix.utf16.count
            delimiterLength = "\t".utf16.count
        } else if line.hasPrefix(checkedPrefixVariant) {
            prefixLength = checkedPrefixVariant.utf16.count
            delimiterLength = "\t".utf16.count
        } else if line.hasPrefix(uncheckedPrefix) {
            prefixLength = uncheckedPrefix.utf16.count
            delimiterLength = "\t".utf16.count
        } else if line.hasPrefix(legacyCheckedGlyphPrefix) {
            prefixLength = legacyCheckedGlyphPrefix.utf16.count
            delimiterLength = " ".utf16.count
        } else if line.hasPrefix(legacyCheckedGlyphPrefixVariant) {
            prefixLength = legacyCheckedGlyphPrefixVariant.utf16.count
            delimiterLength = " ".utf16.count
        } else if line.hasPrefix(legacyUncheckedGlyphPrefix) {
            prefixLength = legacyUncheckedGlyphPrefix.utf16.count
            delimiterLength = " ".utf16.count
        } else {
            return nil
        }

        return NSRange(
            location: lineLocation,
            length: max(prefixLength - delimiterLength, 0)
        )
    }
}

enum RichTextContentCodec {
    static func decode(
        richTextData: Data?,
        plainText: String,
        baseFont: UIFont
    ) -> NSAttributedString {
        if let richTextData,
           let attributedText = try? NSAttributedString(
            data: richTextData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            return attributedText
        }
        return NSAttributedString(
            string: plainText,
            attributes: [.font: baseFont]
        )
    }

    static func encode(_ attributedText: NSAttributedString) -> Data? {
        guard attributedText.length > 0 else { return nil }
        return try? attributedText.data(
            from: NSRange(location: 0, length: attributedText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    static func normalizedForDisplay(
        _ attributedText: NSAttributedString,
        traitCollection: UITraitCollection,
        defaultTextColor: UIColor = .label
    ) -> NSAttributedString {
        // Preserve explicit colors exactly. Missing foreground means Auto, so
        // paint it with the current editor default for display only; syncContent
        // strips that default color back out before saving/syncing.
        _ = traitCollection
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            guard value == nil else { return }
            mutable.addAttribute(.foregroundColor, value: defaultTextColor, range: range)
            mutable.addAttribute(.autoTextColorDisplay, value: true, range: range)
        }
        return mutable
    }

    static func sanitizedConflictRichTextData(_ richTextData: Data?, plainText: String) -> Data? {
        guard let richTextData,
              let attributedText = try? NSAttributedString(
                data: richTextData,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ),
              attributedText.string == plainText else { return nil }
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: mutable.length)
        stripLegacyDefaultTextColors(from: mutable, range: fullRange)
        return encode(mutable)
    }

    private static func stripLegacyDefaultTextColors(from attributedText: NSMutableAttributedString, range: NSRange) {
        attributedText.enumerateAttribute(.foregroundColor, in: range) { value, range, _ in
            guard let color = value as? UIColor,
                  color.looksLikeLegacyDefaultTextColor else { return }
            attributedText.removeAttribute(.foregroundColor, range: range)
        }
        stripLegacyDefaultDecorationColor(.underlineColor, from: attributedText, range: range)
        stripLegacyDefaultDecorationColor(.strikethroughColor, from: attributedText, range: range)
    }

    private static func stripLegacyDefaultDecorationColor(
        _ key: NSAttributedString.Key,
        from attributedText: NSMutableAttributedString,
        range: NSRange
    ) {
        attributedText.enumerateAttribute(key, in: range) { value, range, _ in
            guard let color = value as? UIColor,
                  color.looksLikeLegacyDefaultTextColor else { return }
            attributedText.removeAttribute(key, range: range)
        }
    }

}

private extension UIColor {
    func isApproximatelyEqual(to other: UIColor) -> Bool {
        guard let lhs = rgbaComponents,
              let rhs = other.rgbaComponents else {
            return false
        }

        return abs(lhs.red - rhs.red) <= 0.02
            && abs(lhs.green - rhs.green) <= 0.02
            && abs(lhs.blue - rhs.blue) <= 0.02
            && abs(lhs.alpha - rhs.alpha) <= 0.02
    }

    var looksLikeLegacyDefaultTextColor: Bool {
        guard let components = rgbaComponents, components.alpha > 0.6 else { return false }
        return components.saturation <= 0.08
            && (components.luminance <= 0.42 || components.luminance >= 0.58)
    }

    private var rgbaComponents: RGBAComponents? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return RGBAComponents(red: red, green: green, blue: blue, alpha: alpha)
        }

        var white: CGFloat = 0
        if getWhite(&white, alpha: &alpha) {
            return RGBAComponents(red: white, green: white, blue: white, alpha: alpha)
        }

        let ciColor = CIColor(color: self)
        return RGBAComponents(red: ciColor.red, green: ciColor.green, blue: ciColor.blue, alpha: ciColor.alpha)
    }
}

private extension NSAttributedString.Key {
    static let autoTextColorDisplay = NSAttributedString.Key("com.myram.autoTextColorDisplay")
}

private struct RGBAComponents {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    var luminance: CGFloat {
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    var saturation: CGFloat {
        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        guard maxComponent > 0 else { return 0 }
        return (maxComponent - minComponent) / maxComponent
    }
}

struct ChromeActionBar<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let style: EditorChromeStyle
    let cornerRadius: CGFloat
    let content: Content

    init(
        style: EditorChromeStyle,
        cornerRadius: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            if style == .chromeAccent {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(chromeAccentGradient(for: colorScheme))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(style.toolbarFillColor)
            }
        }
        .overlay {
            if style == .chromeAccent {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(chromeAccentToolbarTrimGradient(for: colorScheme), lineWidth: 0.9)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(style.toolbarStrokeColor, lineWidth: 1)
            }
        }
    }
}

private struct ChromeEditorTrim: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let style: EditorChromeStyle

    func body(content: Content) -> some View {
        content
            .overlay {
                if style.isChromeAccent {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(chromeAccentTrimGradient(for: colorScheme), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if style.isChromeAccent {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .inset(by: 3)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.42), lineWidth: 0.8)
                        .allowsHitTesting(false)
                }
            }
            .shadow(
                color: style.isChromeAccent ? Color.black.opacity(colorScheme == .dark ? 0.28 : 0.10) : .clear,
                radius: style.isChromeAccent ? 12 : 0,
                x: 0,
                y: style.isChromeAccent ? 6 : 0
            )
    }
}

private struct ChromeControlPlate: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let style: EditorChromeStyle
    var isActive = false
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background {
                if style.isChromeAccent {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(chromeAccentControlGradient(for: colorScheme, isActive: isActive))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isActive ? Color.primary.opacity(0.18) : style.toolbarControlFillColor)
                }
            }
            .overlay {
                if style.isChromeAccent {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(chromeAccentStrokeColor(for: colorScheme), lineWidth: 0.75)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct ChromePinnedPanel: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let style: EditorChromeStyle

    func body(content: Content) -> some View {
        content
            .background {
                if style.isChromeAccent {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(chromeAccentGradient(for: colorScheme))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                }
            }
            .overlay {
                if style.isChromeAccent {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(chromeAccentToolbarTrimGradient(for: colorScheme), lineWidth: 0.9)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(
                color: style.isChromeAccent ? Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08) : .clear,
                radius: style.isChromeAccent ? 8 : 0,
                x: 0,
                y: style.isChromeAccent ? 4 : 0
            )
    }
}

private struct ChromePinnedSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let style: EditorChromeStyle
    let pinnedColor: PinnedHighlightColor

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PinnedHighlightPalette.highlight(for: pinnedColor))
                    .overlay {
                        if style.isChromeAccent {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(chromeAccentPinnedShineGradient(for: colorScheme))
                                .blendMode(.screen)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            .overlay {
                if style.isChromeAccent {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(chromeAccentPinnedStrokeColor(for: colorScheme), lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ChromePinnedBadge: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let style: EditorChromeStyle
    let pinnedColor: PinnedHighlightColor

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PinnedHighlightPalette.highlight(for: pinnedColor))
                    .overlay {
                        if style.isChromeAccent {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(chromeAccentPinnedShineGradient(for: colorScheme))
                                .blendMode(.screen)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .overlay {
                if style.isChromeAccent {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(chromeAccentPinnedStrokeColor(for: colorScheme), lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(
                color: style.isChromeAccent ? Color.black.opacity(colorScheme == .dark ? 0.20 : 0.08) : .clear,
                radius: style.isChromeAccent ? 5 : 0,
                x: 0,
                y: style.isChromeAccent ? 2 : 0
            )
    }
}

private struct ChromeCountBadge: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let style: EditorChromeStyle

    func body(content: Content) -> some View {
        content
            .background {
                if style.isChromeAccent {
                    Capsule().fill(chromeAccentControlGradient(for: colorScheme))
                } else {
                    Capsule().fill(Color.secondary.opacity(0.18))
                }
            }
            .overlay {
                if style.isChromeAccent {
                    Capsule()
                        .stroke(chromeAccentStrokeColor(for: colorScheme), lineWidth: 0.7)
                }
            }
            .clipShape(Capsule())
    }
}

func chromeAccentGradient(for colorScheme: ColorScheme) -> LinearGradient {
    if colorScheme == .dark {
        return LinearGradient(
            colors: [
                Color(red: 0.34, green: 0.35, blue: 0.39),
                Color(red: 0.19, green: 0.20, blue: 0.23),
                Color(red: 0.30, green: 0.31, blue: 0.35)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    return LinearGradient(
        colors: [
            Color(red: 0.95, green: 0.95, blue: 0.96),
            Color(red: 0.81, green: 0.82, blue: 0.85),
            Color(red: 0.92, green: 0.92, blue: 0.94)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

func chromeAccentControlGradient(for colorScheme: ColorScheme, isActive: Bool = false) -> LinearGradient {
    if colorScheme == .dark {
        return LinearGradient(
            colors: [
                Color(red: isActive ? 0.44 : 0.39, green: isActive ? 0.45 : 0.40, blue: isActive ? 0.50 : 0.45),
                Color(red: isActive ? 0.25 : 0.21, green: isActive ? 0.26 : 0.22, blue: isActive ? 0.30 : 0.26),
                Color(red: isActive ? 0.38 : 0.33, green: isActive ? 0.39 : 0.34, blue: isActive ? 0.44 : 0.39)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    return LinearGradient(
        colors: [
            Color(red: isActive ? 1.00 : 0.98, green: isActive ? 1.00 : 0.98, blue: isActive ? 1.00 : 0.99),
            Color(red: isActive ? 0.74 : 0.79, green: isActive ? 0.76 : 0.81, blue: isActive ? 0.82 : 0.86),
            Color(red: isActive ? 0.96 : 0.93, green: isActive ? 0.97 : 0.94, blue: isActive ? 1.00 : 0.96)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

func chromeAccentTrimGradient(for colorScheme: ColorScheme) -> LinearGradient {
    if colorScheme == .dark {
        return LinearGradient(
            colors: [
                Color.white.opacity(0.30),
                Color(red: 0.36, green: 0.38, blue: 0.43).opacity(0.70),
                Color.black.opacity(0.35)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    return LinearGradient(
        colors: [
            Color.white.opacity(0.92),
            Color(red: 0.63, green: 0.66, blue: 0.72).opacity(0.82),
            Color.white.opacity(0.64)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

func chromeAccentToolbarTrimGradient(for colorScheme: ColorScheme) -> LinearGradient {
    if colorScheme == .dark {
        return LinearGradient(
            colors: [
                Color.black.opacity(0.38),
                Color.white.opacity(0.32),
                Color.black.opacity(0.30)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    return LinearGradient(
        colors: [
            Color(red: 0.56, green: 0.58, blue: 0.64).opacity(0.78),
            Color.white.opacity(0.94),
            Color(red: 0.62, green: 0.64, blue: 0.70).opacity(0.72)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

func chromeAccentStrokeColor(for colorScheme: ColorScheme) -> Color {
    Color.white.opacity(colorScheme == .dark ? 0.22 : 0.44)
}

func chromeAccentPinnedStrokeColor(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark
        ? Color.white.opacity(0.26)
        : Color(red: 0.60, green: 0.62, blue: 0.68).opacity(0.78)
}

func chromeAccentPinnedShineGradient(for colorScheme: ColorScheme) -> LinearGradient {
    LinearGradient(
        colors: [
            Color.white.opacity(colorScheme == .dark ? 0.06 : 0.14),
            Color.white.opacity(colorScheme == .dark ? 0.22 : 0.36),
            Color.white.opacity(colorScheme == .dark ? 0.02 : 0.07)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
