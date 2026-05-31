// NoteEditorView.swift
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import VisionKit

struct NoteEditorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: NotesViewModel
    let note: Note
    let onNewNote: (Note) -> Void
    
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var richTextContentData: Data?
    @State private var selectAllToggleToken = 0
    @State private var captureSelectionToggleToken = 0
    @State private var boldToggleToken = 0
    @State private var italicToggleToken = 0
    @State private var underlineToggleToken = 0
    @State private var strikethroughToggleToken = 0
    @State private var increaseFontSizeToggleToken = 0
    @State private var decreaseFontSizeToggleToken = 0
    @State private var selectedTextUIColor: UIColor?
    @State private var selectedTextColorForPicker: Color = .primary
    @State private var applyTextColorToggleToken = 0
    @State private var formattingState = EditorFormattingState()
    @State private var showingFormattingControls = false
    @State private var activeUndoManager: UndoManager?
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var undoHistory: [NoteSnapshot] = []
    @State private var redoHistory: [NoteSnapshot] = []
    @State private var lastSnapshot = NoteSnapshot()
    @State private var isApplyingUndo = false
    @State private var selectedPickerItems: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var expandedAttachment: NotePhotoAttachment?
    @State private var areAttachmentsExpanded = false
    @State private var sharePayload: NoteSharePayload?
    @State private var exportErrorMessage: String?
    @State private var showingCreateFolderPrompt = false
    @State private var newFolderName = ""
    @State private var suggestionLabels: [String] = []
    @State private var showingTitleEditor = false
    @State private var titleDraft = ""
    @State private var keyboardToast: KeyboardToast?
    @State private var keyboardToastTask: Task<Void, Never>?
    @AppStorage("editorChromeStyle") private var editorChromeStyleRaw = EditorChromeStyle.standard.rawValue
    private let editorBottomInset: CGFloat = 58
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                editorTopBar

                ZStack(alignment: .bottomTrailing) {
                    SelectableTextView(
                        text: $content,
                        richTextContentData: $richTextContentData,
                        bottomContentInset: editorBottomInset,
                        captureSelectionToggleToken: captureSelectionToggleToken,
                        selectAllToggleToken: selectAllToggleToken,
                        boldToggleToken: boldToggleToken,
                        italicToggleToken: italicToggleToken,
                        underlineToggleToken: underlineToggleToken,
                        strikethroughToggleToken: strikethroughToggleToken,
                        increaseFontSizeToggleToken: increaseFontSizeToggleToken,
                        decreaseFontSizeToggleToken: decreaseFontSizeToggleToken,
                        selectedTextColor: selectedTextUIColor,
                        applyTextColorToggleToken: applyTextColorToggleToken,
                        onContentChanged: handleContentChanged,
                        onUndoManagerChanged: updateActiveUndoManager,
                        onFormattingStateChanged: handleFormattingStateChanged
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    VStack(alignment: .trailing, spacing: 8) {
                        if let keyboardToast {
                            Text(keyboardToast.message)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        if showingFormattingControls {
                            inlineFormattingControls
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        attachmentInlineActions
                    }
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                }

                if !sortedAttachments.isEmpty {
                    DisclosureGroup(isExpanded: $areAttachmentsExpanded) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(sortedAttachments, id: \.id) { attachment in
                                    ZStack(alignment: .topTrailing) {
                                        AttachmentThumbnail(attachment: attachment, size: 64)
                                            .onTapGesture {
                                                expandedAttachment = attachment
                                            }

                                        Button {
                                            vm.removePhotoAttachment(attachment, from: note)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.body)
                                                .foregroundStyle(.white, .black.opacity(0.7))
                                                .padding(4)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack(spacing: 8) {
                            Label("Attachments", systemImage: "paperclip")
                                .font(.subheadline.weight(.medium))
                            Text("\(sortedAttachments.count)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(Capsule())
                            Image(systemName: areAttachmentsExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if !suggestionLabels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Optional recommendations")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(suggestionLabels, id: \.self) { label in
                                    Text(displayName(for: label))
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.15))
                                        .foregroundStyle(Color.accentColor)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
            .toolbar(.hidden, for: .navigationBar)
            .presentationDragIndicator(.visible)
            .onAppear {
                title = note.title
                content = note.content
                richTextContentData = note.richTextContentData
                lastSnapshot = NoteSnapshot(
                    title: title,
                    content: content,
                    richTextContentData: richTextContentData
                )
                vm.recordNoteOpened(note)
                refreshSuggestionLabels()
            }
            .onChange(of: title) { handleEditorChange() }
            .onChange(of: selectedPickerItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task {
                    await importSelectedPickerItems(newItems)
                    selectedPickerItems = []
                }
            }
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
            .sheet(item: $expandedAttachment) { attachment in
                ExpandedPhotoView(attachment: attachment)
            }
            .sheet(item: $sharePayload) { payload in
                ActivityShareSheet(activityItems: payload.urls)
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
    }

    private var sortedAttachments: [NotePhotoAttachment] {
        note.photoAttachments.sorted { $0.createdAt < $1.createdAt }
    }

    private var canPerformUndo: Bool {
        canUndo || vm.hasUndoableAction
    }

    private var canPerformRedo: Bool {
        canRedo
    }

    private var editorTopBar: some View {
        GeometryReader { proxy in
            let layout = topBarActionLayout(totalWidth: proxy.size.width)
            ChromeActionBar(style: editorChromeStyle) {
                titleEditorButton

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
                }
                .accessibilityIdentifier("note-editor-more")
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: 42)
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
                onNewNote(vm.createNewNote())
            }
        case .newFolder:
            topBarActionButton(systemImage: "folder.badge.plus", identifier: "topbar-new-folder") {
                newFolderName = ""
                showingCreateFolderPrompt = true
            }
        case .exportNote:
            topBarActionButton(systemImage: "square.and.arrow.up", identifier: "topbar-export-note") {
                exportCurrentNote()
            }
        case .attachments:
            Menu {
                attachmentImportMenuItems
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .accessibilityIdentifier("topbar-attachments")
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
        }
        .buttonStyle(.plain)
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
        }
    }

    private func handleEditorChange() {
        let currentSnapshot = NoteSnapshot(
            title: title,
            content: content,
            richTextContentData: richTextContentData
        )
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
        vm.updateNote(
            note,
            title: title,
            content: content,
            richTextContentData: richTextContentData
        )
        vm.recordNoteEdited(note)
        refreshSuggestionLabels()
        refreshUndoState()
    }

    private func handleContentChanged(_ plainText: String, _ richTextData: Data?) {
        content = plainText
        richTextContentData = richTextData
        handleEditorChange()
    }

    private func handleFormattingStateChanged(_ state: EditorFormattingState) {
        formattingState = state
        guard !showingFormattingControls else { return }

        if let color = state.foregroundColor {
            selectedTextColorForPicker = Color(uiColor: color)
        } else {
            selectedTextColorForPicker = .primary
        }
    }

    private func refreshSuggestionLabels() {
        suggestionLabels = vm.noteSuggestionLabels(for: note)
    }

    private func displayName(for label: String) -> String {
        switch label {
        case "possible_task":
            return "Possible Task"
        case "possible_event":
            return "Possible Event"
        case "reminder_candidate":
            return "Reminder Candidate"
        case "idea":
            return "Idea"
        case "journal_entry":
            return "Journal Entry"
        case "high_revisit_value":
            return "High Revisit Value"
        case "merge_candidate":
            return "Merge Candidate"
        default:
            return label
        }
    }

    private func undoLastEdit() {
        if activeUndoManager?.canUndo == true {
            isApplyingUndo = true
            activeUndoManager?.undo()
            DispatchQueue.main.async {
                isApplyingUndo = false
                lastSnapshot = NoteSnapshot(
                    title: title,
                    content: content,
                    richTextContentData: richTextContentData
                )
                trimUndoHistory(afterRestoring: lastSnapshot)
                refreshUndoState()
            }
            return
        }

        guard let snapshot = undoHistory.popLast() else {
            refreshUndoState()
            return
        }

        let currentSnapshot = NoteSnapshot(
            title: title,
            content: content,
            richTextContentData: richTextContentData
        )
        redoHistory.append(currentSnapshot)

        isApplyingUndo = true
        title = snapshot.title
        content = snapshot.content
        richTextContentData = snapshot.richTextContentData
        lastSnapshot = snapshot
        vm.updateNote(
            note,
            title: snapshot.title,
            content: snapshot.content,
            richTextContentData: snapshot.richTextContentData
        )
        DispatchQueue.main.async {
            isApplyingUndo = false
            refreshUndoState()
        }
    }

    private func redoLastEdit() {
        if activeUndoManager?.canRedo == true {
            isApplyingUndo = true
            activeUndoManager?.redo()
            DispatchQueue.main.async {
                isApplyingUndo = false
                lastSnapshot = NoteSnapshot(
                    title: title,
                    content: content,
                    richTextContentData: richTextContentData
                )
                refreshUndoState()
            }
            return
        }

        guard let snapshot = redoHistory.popLast() else {
            refreshUndoState()
            return
        }

        let currentSnapshot = NoteSnapshot(
            title: title,
            content: content,
            richTextContentData: richTextContentData
        )
        undoHistory.append(currentSnapshot)

        isApplyingUndo = true
        title = snapshot.title
        content = snapshot.content
        richTextContentData = snapshot.richTextContentData
        lastSnapshot = snapshot
        vm.updateNote(
            note,
            title: snapshot.title,
            content: snapshot.content,
            richTextContentData: snapshot.richTextContentData
        )
        DispatchQueue.main.async {
            isApplyingUndo = false
            refreshUndoState()
        }
    }

    private func performUndo() {
        if canUndo {
            undoLastEdit()
        } else {
            vm.undoLastAction()
        }
        refreshUndoState()
    }

    private func performRedo() {
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

    private var attachmentInlineActions: some View {
        HStack(spacing: 8) {
            inlineActionButton(
                systemImage: "keyboard.chevron.compact.down",
                identifier: "keyboard-control-dismiss"
            ) {
                dismissKeyboard()
            }
            inlineActionButton(
                systemImage: "arrow.uturn.backward",
                identifier: "keyboard-control-undo"
            ) {
                performUndo()
            }
            .opacity(canPerformUndo ? 1 : 0.4)
            .disabled(!canPerformUndo)

            inlineActionButton(
                systemImage: "arrow.uturn.forward",
                identifier: "keyboard-control-redo"
            ) {
                performRedo()
            }
            .opacity(canPerformRedo ? 1 : 0.4)
            .disabled(!canPerformRedo)
            inlineActionButton(systemImage: "scissors", identifier: "keyboard-control-cut") {
                performResponderAction(#selector(UIResponder.cut(_:)))
            }
            inlineActionButton(systemImage: "doc.on.doc", identifier: "keyboard-control-copy") {
                performKeyboardAction(
                    #selector(UIResponder.copy(_:)),
                    toast: KeyboardToast(message: "Copied")
                )
            }
            inlineActionButton(
                systemImage: "doc.on.clipboard",
                identifier: "keyboard-control-paste"
            ) {
                performResponderAction(#selector(UIResponder.paste(_:)))
            }
            inlineActionButton(
                systemImage: "selection.pin.in.out",
                identifier: "keyboard-control-select-all"
            ) {
                selectAllToggleToken += 1
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
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("keyboard-control-formatting-menu")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if editorChromeStyle == .chromeAccent {
                Capsule().fill(chromeAccentGradient(for: colorScheme))
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay {
            if editorChromeStyle == .chromeAccent {
                Capsule()
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.44), lineWidth: 0.9)
            }
        }
        .accessibilityIdentifier("keyboard-control-bar")
    }

    private var inlineFormattingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            }

            HStack(spacing: 14) {
                Button {
                    decreaseFontSizeToggleToken += 1
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                }
                .accessibilityIdentifier("format-font-smaller")

                Text("\(Int(formattingState.fontSize.rounded()))")
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 38)

                Button {
                    increaseFontSizeToggleToken += 1
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .accessibilityIdentifier("format-font-larger")
            }

            ColorPicker("Text Color", selection: Binding(
                get: { selectedTextColorForPicker },
                set: { newValue in
                    selectedTextColorForPicker = newValue
                    selectedTextUIColor = UIColor(newValue)
                    applyTextColorToggleToken += 1
                }
            ), supportsOpacity: false)
            .accessibilityIdentifier("format-color-picker")

            Button("Use Default Text Color") {
                selectedTextColorForPicker = .primary
                selectedTextUIColor = nil
                applyTextColorToggleToken += 1
            }
            .accessibilityIdentifier("format-color-default")
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .frame(maxWidth: min(UIScreen.main.bounds.width * 0.82, 320))
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
                .background(isActive ? Color.accentColor.opacity(0.2) : Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
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

    private func dismissKeyboard() {
        performResponderAction(#selector(UIResponder.resignFirstResponder))
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
                exportCurrentNote()
            } label: {
                Label("Export Note", systemImage: "square.and.arrow.up")
            }
        case .attachments:
            Menu {
                attachmentImportMenuItems
            } label: {
                Label("Attachments", systemImage: "paperclip")
            }
        case .newNote:
            Button {
                onNewNote(vm.createNewNote())
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
        case .newFolder:
            Button {
                newFolderName = ""
                showingCreateFolderPrompt = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
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

        Button {
            showingFileImporter = true
        } label: {
            Label("Import Image", systemImage: "square.and.arrow.down")
        }
    }
}

enum NoteEditorOverflowAction: String, CaseIterable {
    case newNote
    case newFolder
    case exportNote
    case attachments
    case deleteNote

    static let priorityOrder: [NoteEditorOverflowAction] = [
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

struct EditorFormattingState {
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var fontSize: CGFloat = 17
    var foregroundColor: UIColor?
}

private struct NoteSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct NoteSnapshot: Equatable {
    var title: String = ""
    var content: String = ""
    var richTextContentData: Data?
}

private struct KeyboardToast: Equatable {
    let message: String
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

private struct ExpandedPhotoView: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: NotePhotoAttachment

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let image = UIImage(data: attachment.imageData) {
                    LiveTextImageView(image: image)
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
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

@MainActor
private struct LiveTextImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> LiveTextEnabledImageView {
        LiveTextEnabledImageView(frame: .zero)
    }

    func updateUIView(_ imageView: LiveTextEnabledImageView, context: Context) {
        imageView.setAnalyzedImage(image)
    }
}

@MainActor
private final class LiveTextEnabledImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private let liveTextInteraction = ImageAnalysisInteraction()
    private let analyzer = ImageAnalyzer()
    private var analysisTask: Task<Void, Never>?
    private var sourceImage: UIImage?

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

    func setAnalyzedImage(_ image: UIImage) {
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
    let bottomContentInset: CGFloat
    let captureSelectionToggleToken: Int
    let selectAllToggleToken: Int
    let boldToggleToken: Int
    let italicToggleToken: Int
    let underlineToggleToken: Int
    let strikethroughToggleToken: Int
    let increaseFontSizeToggleToken: Int
    let decreaseFontSizeToggleToken: Int
    let selectedTextColor: UIColor?
    let applyTextColorToggleToken: Int
    let onContentChanged: (String, Data?) -> Void
    let onUndoManagerChanged: (UndoManager?) -> Void
    let onFormattingStateChanged: (EditorFormattingState) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.adjustsFontForContentSizeCategory = true
        textView.allowsEditingTextAttributes = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 8
        textView.typingAttributes = [
            .font: textView.font ?? .preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ]
        textView.textContainerInset = UIEdgeInsets(
            top: 12,
            left: 8,
            bottom: 12 + bottomContentInset,
            right: 8
        )
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: bottomContentInset, right: 0)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.textColor = .label
        context.coordinator.isUpdatingUIView = true
        defer {
            context.coordinator.isUpdatingUIView = false
        }

        let desiredInsets = UIEdgeInsets(
            top: 12,
            left: 8,
            bottom: 12 + bottomContentInset,
            right: 8
        )
        if textView.textContainerInset != desiredInsets {
            textView.textContainerInset = desiredInsets
            textView.scrollIndicatorInsets = UIEdgeInsets(
                top: 0,
                left: 0,
                bottom: bottomContentInset,
                right: 0
            )
        }

        let hasPendingFormattingMutation = context.coordinator.hasPendingFormattingMutation(
            boldToggleToken: boldToggleToken,
            italicToggleToken: italicToggleToken,
            underlineToggleToken: underlineToggleToken,
            strikethroughToggleToken: strikethroughToggleToken,
            increaseFontSizeToggleToken: increaseFontSizeToggleToken,
            decreaseFontSizeToggleToken: decreaseFontSizeToggleToken,
            applyTextColorToggleToken: applyTextColorToggleToken
        )

        if !textView.isFirstResponder && !hasPendingFormattingMutation {
            let desiredAttributedText = RichTextContentCodec.decode(
                richTextData: richTextContentData,
                plainText: text,
                baseFont: textView.font ?? .preferredFont(forTextStyle: .body)
            )
            let normalizedAttributedText = RichTextContentCodec.normalizedForDisplay(
                desiredAttributedText,
                traitCollection: textView.traitCollection
            )
            if !textView.attributedText.isEqual(to: normalizedAttributedText) {
                let selectedRange = textView.selectedRange
                textView.attributedText = normalizedAttributedText
                let newLength = (textView.text as NSString).length
                textView.selectedRange = selectedRange.location <= newLength
                    ? selectedRange
                    : NSRange(location: newLength, length: 0)
            }
        }
        context.coordinator.text = $text
        context.coordinator.richTextContentData = $richTextContentData
        context.coordinator.onContentChanged = onContentChanged
        context.coordinator.onUndoManagerChanged = onUndoManagerChanged
        context.coordinator.onFormattingStateChanged = onFormattingStateChanged

        if context.coordinator.captureSelectionToggleToken != captureSelectionToggleToken {
            context.coordinator.captureSelectionToggleToken = captureSelectionToggleToken
            context.coordinator.captureCurrentSelection(in: textView)
        }

        if context.coordinator.selectAllToggleToken != selectAllToggleToken {
            context.coordinator.selectAllToggleToken = selectAllToggleToken
            let fullLength = (textView.text as NSString).length
            if fullLength > 0 && textView.selectedRange.location == 0 && textView.selectedRange.length == fullLength {
                textView.selectedRange = NSRange(location: fullLength, length: 0)
            } else {
                textView.selectAll(nil)
            }
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

        if context.coordinator.applyTextColorToggleToken != applyTextColorToggleToken {
            context.coordinator.applyTextColorToggleToken = applyTextColorToggleToken
            context.coordinator.selectedTextColor = selectedTextColor
            context.coordinator.applyTextColor(in: textView, color: selectedTextColor)
            context.coordinator.reportUndoManagerChanged(textView.undoManager)
        }

        context.coordinator.normalizeTypingAttributes(in: textView)
        context.coordinator.reportFormattingState(from: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            richTextContentData: $richTextContentData,
            onContentChanged: onContentChanged,
            onUndoManagerChanged: onUndoManagerChanged,
            onFormattingStateChanged: onFormattingStateChanged
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var richTextContentData: Binding<Data?>
        var onContentChanged: (String, Data?) -> Void
        var onUndoManagerChanged: (UndoManager?) -> Void
        var onFormattingStateChanged: (EditorFormattingState) -> Void
        var captureSelectionToggleToken = 0
        var selectAllToggleToken = 0
        var boldToggleToken = 0
        var italicToggleToken = 0
        var underlineToggleToken = 0
        var strikethroughToggleToken = 0
        var increaseFontSizeToggleToken = 0
        var decreaseFontSizeToggleToken = 0
        var selectedTextColor: UIColor?
        var applyTextColorToggleToken = 0
        var lastKnownSelectionRange = NSRange(location: 0, length: 0)
        var isUpdatingUIView = false

        init(
            text: Binding<String>,
            richTextContentData: Binding<Data?>,
            onContentChanged: @escaping (String, Data?) -> Void,
            onUndoManagerChanged: @escaping (UndoManager?) -> Void,
            onFormattingStateChanged: @escaping (EditorFormattingState) -> Void
        ) {
            self.text = text
            self.richTextContentData = richTextContentData
            self.onContentChanged = onContentChanged
            self.onUndoManagerChanged = onUndoManagerChanged
            self.onFormattingStateChanged = onFormattingStateChanged
        }

        func textViewDidChange(_ textView: UITextView) {
            syncContent(from: textView)
            reportFormattingState(from: textView)
            onUndoManagerChanged(textView.undoManager)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length > 0 {
                lastKnownSelectionRange = textView.selectedRange
            }
            reportFormattingState(from: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            lastKnownSelectionRange = textView.selectedRange
            reportFormattingState(from: textView)
            onUndoManagerChanged(textView.undoManager)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            syncContent(from: textView)
            reportFormattingState(from: textView)
            onUndoManagerChanged(textView.undoManager)
        }

        func hasPendingFormattingMutation(
            boldToggleToken: Int,
            italicToggleToken: Int,
            underlineToggleToken: Int,
            strikethroughToggleToken: Int,
            increaseFontSizeToggleToken: Int,
            decreaseFontSizeToggleToken: Int,
            applyTextColorToggleToken: Int
        ) -> Bool {
            self.boldToggleToken != boldToggleToken
                || self.italicToggleToken != italicToggleToken
                || self.underlineToggleToken != underlineToggleToken
                || self.strikethroughToggleToken != strikethroughToggleToken
                || self.increaseFontSizeToggleToken != increaseFontSizeToggleToken
                || self.decreaseFontSizeToggleToken != decreaseFontSizeToggleToken
                || self.applyTextColorToggleToken != applyTextColorToggleToken
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

        func adjustFontSize(in textView: UITextView, by delta: CGFloat) {
            let selectedRange = formattingActionRange(in: textView)

            if selectedRange.length == 0 {
                var typingAttributes = textView.typingAttributes
                let baseFont = (typingAttributes[.font] as? UIFont)
                    ?? textView.font
                    ?? .preferredFont(forTextStyle: .body)
                typingAttributes[.font] = adjustedFontSize(from: baseFont, delta: delta)
                textView.typingAttributes = typingAttributes
                reportFormattingState(from: textView)
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            mutable.enumerateAttribute(.font, in: selectedRange) { value, range, _ in
                let baseFont = (value as? UIFont)
                    ?? textView.font
                    ?? .preferredFont(forTextStyle: .body)
                mutable.addAttribute(
                    .font,
                    value: adjustedFontSize(from: baseFont, delta: delta),
                    range: range
                )
            }
            applyAttributedText(mutable, in: textView, selectedRange: selectedRange)
        }

        func applyTextColor(in textView: UITextView, color: UIColor?) {
            let selectedRange = formattingActionRange(in: textView)

            if selectedRange.length == 0 {
                var typingAttributes = textView.typingAttributes
                if color == nil {
                    typingAttributes.removeValue(forKey: .foregroundColor)
                } else {
                    typingAttributes[.foregroundColor] = color
                }
                textView.typingAttributes = typingAttributes
                reportFormattingState(from: textView)
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            if color == nil {
                mutable.removeAttribute(.foregroundColor, range: selectedRange)
            } else if let color {
                mutable.addAttribute(.foregroundColor, value: color, range: selectedRange)
            }
            applyAttributedText(mutable, in: textView, selectedRange: selectedRange)
        }

        func normalizeTypingAttributes(in textView: UITextView) {
            var typingAttributes = textView.typingAttributes
            if let color = typingAttributes[.foregroundColor] as? UIColor {
                let resolvedColor = color.resolvedColor(with: textView.traitCollection)
                if textView.traitCollection.userInterfaceStyle == .dark
                    && resolvedColor.isPrimaryTextCandidate(in: .dark) {
                    typingAttributes[.foregroundColor] = UIColor.label
                }
                if textView.traitCollection.userInterfaceStyle == .light
                    && resolvedColor.isPrimaryTextCandidate(in: .light) {
                    typingAttributes[.foregroundColor] = UIColor.label
                }
            }
            textView.typingAttributes = typingAttributes
        }

        private func syncContent(from textView: UITextView) {
            let plainText = textView.text ?? ""
            let encodedRichText = RichTextContentCodec.encode(textView.attributedText)
            guard text.wrappedValue != plainText || richTextContentData.wrappedValue != encodedRichText else {
                return
            }

            if isUpdatingUIView {
                RunLoop.main.perform { [weak self] in
                    guard let self else { return }
                    guard self.text.wrappedValue != plainText
                        || self.richTextContentData.wrappedValue != encodedRichText else {
                        return
                    }
                    self.text.wrappedValue = plainText
                    self.richTextContentData.wrappedValue = encodedRichText
                    self.onContentChanged(plainText, encodedRichText)
                }
                return
            }

            text.wrappedValue = plainText
            richTextContentData.wrappedValue = encodedRichText
            onContentChanged(plainText, encodedRichText)
        }

        func reportFormattingState(from textView: UITextView) {
            let state = formattingState(from: textView)
            if isUpdatingUIView {
                RunLoop.main.perform { [weak self] in
                    self?.onFormattingStateChanged(state)
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

        func captureCurrentSelection(in textView: UITextView) {
            let selectedRange = textView.selectedRange
            guard selectedRange.length > 0 else { return }
            lastKnownSelectionRange = selectedRange
            reportFormattingState(from: textView)
        }

        private func formattingState(from textView: UITextView) -> EditorFormattingState {
            let range = effectiveSelectionRange(in: textView)
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

        private func selectedFont(in textView: UITextView, range: NSRange) -> UIFont {
            if range.length == 0 {
                return (textView.typingAttributes[.font] as? UIFont)
                    ?? textView.font
                    ?? .preferredFont(forTextStyle: .body)
            }
            if range.location < textView.attributedText.length,
               let font = textView.attributedText.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont {
                return font
            }
            return textView.font ?? .preferredFont(forTextStyle: .body)
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
                    ?? .preferredFont(forTextStyle: .body)
                return font.fontDescriptor.symbolicTraits.contains(trait)
            }

            var hasAll = true
            textView.attributedText.enumerateAttribute(.font, in: range) { value, _, stop in
                let font = value as? UIFont ?? .preferredFont(forTextStyle: .body)
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
                    ?? .preferredFont(forTextStyle: .body)
                let shouldApply = !baseFont.fontDescriptor.symbolicTraits.contains(trait)
                typingAttributes[.font] = fontBySettingTrait(
                    on: baseFont,
                    trait: trait,
                    isEnabled: shouldApply
                )
                textView.typingAttributes = typingAttributes
                reportFormattingState(from: textView)
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let shouldApply = shouldApplyFontTrait(in: mutable, range: selectedRange, trait: trait)
            mutable.enumerateAttribute(.font, in: selectedRange) { value, range, _ in
                let baseFont = (value as? UIFont)
                    ?? textView.font
                    ?? .preferredFont(forTextStyle: .body)
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
                let font = value as? UIFont ?? .preferredFont(forTextStyle: .body)
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

            if selectedRange.length == 0 {
                var typingAttributes = textView.typingAttributes
                let currentValue = typingAttributes[key] as? Int ?? 0
                typingAttributes[key] = currentValue == 0 ? NSUnderlineStyle.single.rawValue : 0
                textView.typingAttributes = typingAttributes
                reportFormattingState(from: textView)
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let shouldApply = shouldApplyDecoration(in: mutable, range: selectedRange, key: key)
            let value = shouldApply ? NSUnderlineStyle.single.rawValue : 0
            mutable.addAttribute(key, value: value, range: selectedRange)
            applyAttributedText(mutable, in: textView, selectedRange: selectedRange)
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
            selectedRange: NSRange
        ) {
            textView.attributedText = attributedText
            textView.selectedRange = selectedRange
            lastKnownSelectionRange = selectedRange
            syncContent(from: textView)
            reportFormattingState(from: textView)
        }

        private func effectiveSelectionRange(in textView: UITextView) -> NSRange {
            let currentRange = textView.selectedRange
            if currentRange.length > 0 {
                return currentRange
            }

            guard !textView.isFirstResponder else {
                return currentRange
            }

            let fullLength = (textView.text as NSString).length
            let cachedRange = lastKnownSelectionRange
            if cachedRange.length > 0, cachedRange.location + cachedRange.length <= fullLength {
                return cachedRange
            }

            return currentRange
        }

        private func formattingActionRange(in textView: UITextView) -> NSRange {
            let currentRange = textView.selectedRange
            if currentRange.length > 0 {
                return currentRange
            }

            let fullLength = (textView.text as NSString).length
            let cachedRange = lastKnownSelectionRange
            if cachedRange.length > 0, cachedRange.location + cachedRange.length <= fullLength {
                textView.selectedRange = cachedRange
                return cachedRange
            }

            return currentRange
        }
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
        traitCollection: UITraitCollection
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: mutable.length)

        mutable.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            guard let color = value as? UIColor else { return }
            let resolvedColor = color.resolvedColor(with: traitCollection)
            if traitCollection.userInterfaceStyle == .dark
                && resolvedColor.isPrimaryTextCandidate(in: .dark) {
                mutable.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            }
            if traitCollection.userInterfaceStyle == .light
                && resolvedColor.isPrimaryTextCandidate(in: .light) {
                mutable.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            }
        }

        return mutable
    }
}

private extension UIColor {
    func isPrimaryTextCandidate(in interfaceStyle: UIUserInterfaceStyle) -> Bool {
        guard let components = rgbaComponents, components.alpha > 0.6 else { return false }

        let saturation = components.saturation
        let luminance = components.luminance

        switch interfaceStyle {
        case .dark:
            return saturation <= 0.08 && luminance <= 0.42
        case .light:
            return saturation <= 0.08 && luminance >= 0.58
        default:
            return false
        }
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
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay {
            if style == .chromeAccent {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.44), lineWidth: 0.9)
            }
        }
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
