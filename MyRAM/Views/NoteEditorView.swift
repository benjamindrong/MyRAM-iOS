// NoteEditorView.swift
import SwiftUI
import UIKit

struct NoteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @ObservedObject var vm: NotesViewModel
    let note: Note
    let onNewNote: (Note) -> Void
    
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var selectAllToken = 0
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("Title", text: $title)
                    .font(.title2)
                    .textFieldStyle(.roundedBorder)
                
                SelectableTextView(text: $content, selectAllToken: selectAllToken)
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
                        undoManager?.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!(undoManager?.canUndo ?? false))

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
            }
            .onChange(of: title) { vm.updateNote(note, title: title, content: content) }
            .onChange(of: content) { vm.updateNote(note, title: title, content: content) }
        }
    }
}

private struct SelectableTextView: UIViewRepresentable {
    @Binding var text: String
    let selectAllToken: Int

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

        if context.coordinator.selectAllToken != selectAllToken {
            context.coordinator.selectAllToken = selectAllToken
            textView.selectAll(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        var selectAllToken = 0

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}
