// NoteEditorView.swift
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import VisionKit

struct NoteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: NotesViewModel
    let note: Note
    let onNewNote: (Note) -> Void
    
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var selectAllToken = 0
    @State private var activeUndoManager: UndoManager?
    @State private var canUndo = false
    @State private var undoHistory: [NoteSnapshot] = []
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
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                UndoableTextField(
                    text: $title,
                    placeholder: "Title",
                    onUndoManagerChanged: updateActiveUndoManager
                )
                .frame(height: 44)
                
                ZStack(alignment: .bottomTrailing) {
                    SelectableTextView(
                        text: $content,
                        selectAllToken: selectAllToken,
                        onUndoManagerChanged: updateActiveUndoManager
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    attachmentInlineActions
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
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        performUndo()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!canPerformUndo)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            onNewNote(vm.createNewNote())
                        } label: {
                            Label("New Note", systemImage: "square.and.pencil")
                        }

                        Button {
                            newFolderName = ""
                            showingCreateFolderPrompt = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }

                        Menu {
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
                        } label: {
                            Label("Attachments", systemImage: "paperclip")
                        }

                        Button {
                            exportCurrentNote()
                        } label: {
                            Label("Export Note", systemImage: "square.and.arrow.up")
                        }

                        Button(role: .destructive) {
                            vm.deleteNote(note)
                            dismiss()
                        } label: {
                            Label("Delete Note", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                title = note.title
                content = note.content
                lastSnapshot = NoteSnapshot(title: title, content: content)
                vm.recordNoteOpened(note)
                refreshSuggestionLabels()
            }
            .onChange(of: title) { handleEditorChange() }
            .onChange(of: content) { handleEditorChange() }
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
        }
    }

    private var sortedAttachments: [NotePhotoAttachment] {
        note.photoAttachments.sorted { $0.createdAt < $1.createdAt }
    }

    private var canPerformUndo: Bool {
        canUndo || vm.hasUndoableAction
    }

    private func updateActiveUndoManager(_ undoManager: UndoManager?) {
        activeUndoManager = undoManager
        refreshUndoState()
    }

    private func refreshUndoState() {
        DispatchQueue.main.async {
            canUndo = (activeUndoManager?.canUndo ?? false) || !undoHistory.isEmpty
        }
    }

    private func handleEditorChange() {
        let currentSnapshot = NoteSnapshot(title: title, content: content)
        if !isApplyingUndo, currentSnapshot != lastSnapshot {
            undoHistory.append(lastSnapshot)
            if undoHistory.count > 200 {
                undoHistory.removeFirst(undoHistory.count - 200)
            }
        }
        lastSnapshot = currentSnapshot
        vm.updateNote(note, title: title, content: content)
        vm.recordNoteEdited(note)
        refreshSuggestionLabels()
        refreshUndoState()
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
                lastSnapshot = NoteSnapshot(title: title, content: content)
                trimUndoHistory(afterRestoring: lastSnapshot)
                refreshUndoState()
            }
            return
        }

        guard let snapshot = undoHistory.popLast() else {
            refreshUndoState()
            return
        }

        isApplyingUndo = true
        title = snapshot.title
        content = snapshot.content
        lastSnapshot = snapshot
        vm.updateNote(note, title: snapshot.title, content: snapshot.content)
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
        HStack(spacing: 6) {
            inlineActionButton(
                systemImage: "keyboard.chevron.compact.down",
                identifier: "keyboard-control-dismiss"
            ) {
                dismissKeyboard()
            }
            inlineActionButton(systemImage: "scissors", identifier: "keyboard-control-cut") {
                performResponderAction(#selector(UIResponder.cut(_:)))
            }
            inlineActionButton(systemImage: "doc.on.doc", identifier: "keyboard-control-copy") {
                performResponderAction(#selector(UIResponder.copy(_:)))
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
                selectAllToken += 1
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .accessibilityIdentifier("keyboard-control-bar")
    }

    private func inlineActionButton(
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityIdentifier(identifier)
    }

    private func performResponderAction(_ action: Selector) {
        UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil)
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
}

private struct NoteSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct NoteSnapshot: Equatable {
    var title: String = ""
    var content: String = ""
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

private struct UndoableTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onUndoManagerChanged: (UndoManager?) -> Void

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.delegate = context.coordinator
        textField.placeholder = placeholder
        textField.font = .preferredFont(forTextStyle: .title2)
        textField.adjustsFontForContentSizeCategory = true
        textField.borderStyle = .roundedRect
        textField.clearButtonMode = .whileEditing
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        if textField.text != text {
            textField.text = text
        }
        context.coordinator.text = $text
        context.coordinator.onUndoManagerChanged = onUndoManagerChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onUndoManagerChanged: onUndoManagerChanged)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onUndoManagerChanged: (UndoManager?) -> Void

        init(text: Binding<String>, onUndoManagerChanged: @escaping (UndoManager?) -> Void) {
            self.text = text
            self.onUndoManagerChanged = onUndoManagerChanged
        }

        @objc func textDidChange(_ textField: UITextField) {
            text.wrappedValue = textField.text ?? ""
            onUndoManagerChanged(textField.undoManager)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            onUndoManagerChanged(textField.undoManager)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            onUndoManagerChanged(textField.undoManager)
        }
    }
}

private struct SelectableTextView: UIViewRepresentable {
    @Binding var text: String
    let selectAllToken: Int
    let onUndoManagerChanged: (UndoManager?) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 8
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            let selectedRange = textView.selectedRange
            textView.text = text
            textView.selectedRange = selectedRange.location <= text.count ? selectedRange : NSRange(location: text.count, length: 0)
        }
        context.coordinator.text = $text
        context.coordinator.onUndoManagerChanged = onUndoManagerChanged

        if context.coordinator.selectAllToken != selectAllToken {
            context.coordinator.selectAllToken = selectAllToken
            textView.selectAll(nil)
            onUndoManagerChanged(textView.undoManager)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onUndoManagerChanged: onUndoManagerChanged)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var onUndoManagerChanged: (UndoManager?) -> Void
        var selectAllToken = 0

        init(text: Binding<String>, onUndoManagerChanged: @escaping (UndoManager?) -> Void) {
            self.text = text
            self.onUndoManagerChanged = onUndoManagerChanged
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            onUndoManagerChanged(textView.undoManager)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            onUndoManagerChanged(textView.undoManager)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            onUndoManagerChanged(textView.undoManager)
        }
    }
}
