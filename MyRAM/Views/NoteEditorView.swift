// NoteEditorView.swift
import SwiftUI
import UIKit

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
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                UndoableTextField(
                    text: $title,
                    placeholder: "Title",
                    onUndoManagerChanged: updateActiveUndoManager
                )
                .frame(height: 44)
                
                SelectableTextView(
                    text: $content,
                    selectAllToken: selectAllToken,
                    onUndoManagerChanged: updateActiveUndoManager
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding()
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        undoLastEdit()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!canUndo)

                    Button {
                        selectAllToken += 1
                    } label: {
                        Image(systemName: "selection.pin.in.out")
                    }

                    Button {
                        vm.deleteNote(note)
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                    }

                    Button {
                        onNewNote(vm.createNewNote())
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .onAppear {
                title = note.title
                content = note.content
                lastSnapshot = NoteSnapshot(title: title, content: content)
            }
            .onChange(of: title) { handleEditorChange() }
            .onChange(of: content) { handleEditorChange() }
        }
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
        refreshUndoState()
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

    private func trimUndoHistory(afterRestoring snapshot: NoteSnapshot) {
        guard let restoredIndex = undoHistory.lastIndex(of: snapshot) else { return }
        undoHistory.removeSubrange(restoredIndex...)
    }
}

private struct NoteSnapshot: Equatable {
    var title: String = ""
    var content: String = ""
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
