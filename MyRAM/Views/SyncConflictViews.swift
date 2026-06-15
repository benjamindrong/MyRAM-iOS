import SwiftUI
import UIKit

struct SyncConflictNotice: View {
    let conflictCount: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "text.badge.checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("A synced version was preserved for review.")
                        .font(.caption.weight(.semibold))
                    Text("Open Sync Conflicts to copy or restore it within 7 days.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text("\(conflictCount)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.18))
                    .clipShape(Capsule())
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "A synced version was preserved for review. Open Sync Conflicts to copy or restore it within 7 days."
        )
        .accessibilityIdentifier("sync-conflict-notice")
    }
}

struct SyncConflictReviewList: View {
    let conflicts: [SyncConflictVersion]
    let onCopy: (SyncConflictVersion) -> Void
    let onRestore: (SyncConflictVersion) -> Void
    let onReview: (SyncConflictVersion) -> Void
    let onDiscard: (SyncConflictVersion) -> Void
    @State private var selectedConflict: SyncConflictVersion?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(indexedConflicts, id: \.element.id) { entry in
                    conflictRow(entry.element)
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxHeight: 360)
        .sheet(item: $selectedConflict) { conflict in
            SyncConflictDetailView(
                conflict: conflict,
                onCopy: {
                    onCopy(conflict)
                },
                onRestore: {
                    selectedConflict = nil
                    onRestore(conflict)
                },
                onReview: {
                    selectedConflict = nil
                    onReview(conflict)
                },
                onDiscard: {
                    selectedConflict = nil
                    onDiscard(conflict)
                }
            )
            .presentationDetents([.large])
        }
    }

    private var indexedConflicts: [(offset: Int, element: SyncConflictVersion)] {
        Array(conflicts.enumerated())
    }

    private func conflictRow(_ conflict: SyncConflictVersion) -> some View {
        Button {
            selectedConflict = conflict
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conflict.field.displayTitle)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(conflict.preservedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(conflict.remoteText.isEmpty ? "Empty text" : conflict.remoteText)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Label("Review preserved version", systemImage: "doc.text.magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct SyncConflictDetailView: View {
    let conflict: SyncConflictVersion
    let onCopy: () -> Void
    let onRestore: () -> Void
    let onReview: () -> Void
    let onDiscard: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ViewThatFits(in: .horizontal) {
                        headerRow
                        headerStack
                    }

                    conflictTextSection(title: "Preserved Synced Version", text: conflict.remoteText)
                    conflictTextSection(title: "Current Version", text: conflict.localText)

                    actionButtons
                }
                .padding(detailPadding)
                .frame(maxWidth: detailMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(conflict.field.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .modifier(SyncConflictDetailFrame())
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            headerTitle

            Spacer(minLength: 16)

            closeButton
        }
    }

    private var headerStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerTitle
            closeButton
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conflict.field.displayTitle)
                .font(.title3.weight(.semibold))
            Text(conflict.preservedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var closeButton: some View {
        Button("Close") {
            dismiss()
        }
        .buttonStyle(.bordered)
    }

    private var detailPadding: CGFloat {
        horizontalSizeClass == .compact ? 16 : 24
    }

    private var detailMaxWidth: CGFloat {
        horizontalSizeClass == .compact ? .infinity : 1_020
    }

    private var actionButtons: some View {
        Group {
#if targetEnvironment(macCatalyst)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    copyButton

                    Spacer(minLength: 8)

                    restoreButton
                    reviewedButton
                    discardButton
                }

                stackedActionButtons
            }
#else
            stackedActionButtons
#endif
        }
        .controlSize(.regular)
        .padding(.top, 4)
    }

    private var stackedActionButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            copyButton
                .frame(maxWidth: .infinity)
            restoreButton
                .frame(maxWidth: .infinity)
            reviewedButton
                .frame(maxWidth: .infinity)
            discardButton
                .frame(maxWidth: .infinity)
        }
    }

    private var copyButton: some View {
        Button("Copy Preserved Version") {
            onCopy()
        }
        .buttonStyle(.bordered)
    }

    private var restoreButton: some View {
        Button("Restore Preserved Version") {
            onRestore()
        }
        .buttonStyle(.borderedProminent)
    }

    private var reviewedButton: some View {
        Button("Keep Local Version") {
            onReview()
        }
        .buttonStyle(.bordered)
    }

    private var discardButton: some View {
        Button("Discard Preserved Version", role: .destructive) {
            onDiscard()
        }
        .buttonStyle(.bordered)
    }

    private func conflictTextSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            SelectableConflictText(text: text.isEmpty ? "Empty text" : text)
                .frame(minHeight: 160)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct SyncConflictDetailFrame: ViewModifier {
    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        content.frame(minWidth: 860, minHeight: 680)
#else
        content
#endif
    }
}

private struct SelectableConflictText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.textContainer.lineFragmentPadding = 0
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = .label
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.text = text
        textView.font = UIFont.preferredFont(forTextStyle: .body)
    }
}

private extension SyncConflictField {
    var displayTitle: String {
        switch self {
        case .noteTitle:
            "Note Title"
        case .noteContent:
            "Note Text"
        case .folderTitle:
            "Folder Title"
        case .pinnedText:
            "Pinned Text"
        }
    }
}
