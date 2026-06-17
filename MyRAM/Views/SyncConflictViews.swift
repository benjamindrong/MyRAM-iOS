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
                    Text("A version is ready for review.")
                        .font(.caption.weight(.semibold))
                    Text("Open Sync Conflicts to copy, accept, or discard it within 7 days.")
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
            "A version is ready for review. Open Sync Conflicts to copy, accept, or discard it within 7 days."
        )
        .accessibilityIdentifier("sync-conflict-notice")
    }
}

struct SyncConflictReviewList: View {
    let conflicts: [SyncConflictVersion]
    let localText: (SyncConflictVersion) -> String
    let onCopy: (SyncConflictVersion) -> Void
    let onRestore: (SyncConflictVersion) -> Void
    let onReview: (SyncConflictVersion) -> Void
    let onSaveMerged: (SyncConflictVersion, String) -> Void
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
                    localText: localText(conflict),
                    onClose: {
                        selectedConflict = nil
                    },
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
                onSaveMerged: { mergedText in
                    selectedConflict = nil
                    onSaveMerged(conflict, mergedText)
                }
            )
            .syncConflictPresentationSizing()
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

                Label("Review version to sync", systemImage: "doc.text.magnifyingglass")
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
    let localText: String
    let onClose: () -> Void
    let onCopy: () -> Void
    let onRestore: () -> Void
    let onReview: () -> Void
    let onSaveMerged: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var mergedText = ""

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ViewThatFits(in: .horizontal) {
                            headerRow
                            headerStack
                        }

                        conflictTextSection(title: "Local Version", text: localText)
                        conflictTextSection(title: "Version to Sync", text: conflict.remoteText)
                        mergedResultSection

                        actionButtons
                    }
                    .padding(detailPadding)
                    .frame(width: detailContentWidth(for: geometry.size.width), alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(conflict.field.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
#if targetEnvironment(macCatalyst)
                ToolbarItem(placement: .cancellationAction) {
                    closeButton
                }
#endif
            }
        }
        .onAppear {
            if mergedText.isEmpty {
                mergedText = conflict.remoteText
            }
        }
        .modifier(SyncConflictDetailFrame())
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            headerTitle

            Spacer(minLength: 16)

#if !targetEnvironment(macCatalyst)
            closeButton
#endif
        }
    }

    private var headerStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerTitle
#if !targetEnvironment(macCatalyst)
            closeButton
#endif
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
        Button {
            closeDetail()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.bordered)
        .help("Close")
        .accessibilityIdentifier("sync-conflict-detail-close")
        .accessibilityLabel("Close")
    }

    private func closeDetail() {
#if targetEnvironment(macCatalyst)
        topPresentedViewController()?.dismiss(animated: true) {
            onClose()
        }
#else
        onClose()
#endif
    }

#if targetEnvironment(macCatalyst)
    private func topPresentedViewController() -> UIViewController? {
        let foregroundScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let rootViewController = foregroundScene?.windows
            .first { $0.isKeyWindow }?
            .rootViewController

        var presentedViewController = rootViewController
        while let nextPresentedViewController = presentedViewController?.presentedViewController {
            presentedViewController = nextPresentedViewController
        }
        return presentedViewController
    }
#endif

    private var detailPadding: CGFloat {
        horizontalSizeClass == .compact ? 16 : 24
    }

    private var detailMaxWidth: CGFloat {
        horizontalSizeClass == .compact ? 600 : 1_020
    }

    private func detailContentWidth(for availableWidth: CGFloat) -> CGFloat {
        let paddedWidth = max(availableWidth - detailPadding * 2, 0)
        return min(paddedWidth, detailMaxWidth)
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
                    saveMergedButton
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
            saveMergedButton
                .frame(maxWidth: .infinity)
        }
    }

    private var copyButton: some View {
        Button("Copy Version to Sync") {
            onCopy()
        }
        .buttonStyle(.bordered)
    }

    private var restoreButton: some View {
        Button("Accept Version to Sync") {
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

    private var saveMergedButton: some View {
        Button("Save Merged Result") {
            onSaveMerged(mergedText)
        }
        .buttonStyle(.borderedProminent)
    }

    private func conflictTextSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            SelectableConflictText(text: text.isEmpty ? "Empty text" : text)
                .frame(height: textBoxHeight(text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .background(Color.secondary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var mergedResultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Merged Result")
                .font(.headline)

            TextEditor(text: $mergedText)
                .frame(height: textBoxHeight(mergedText))
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .padding(8)
                .background(Color.secondary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func textBoxHeight(_ text: String) -> CGFloat {
#if targetEnvironment(macCatalyst)
        return 220
#else
        let explicitLines = max(text.components(separatedBy: .newlines).count, 1)
        let wrappedLines = max(text.count / 72, 1)
        let estimatedLines = max(explicitLines, wrappedLines)
        return max(120, CGFloat(estimatedLines) * 24 + 40)
#endif
    }
}

private struct SyncConflictDetailFrame: ViewModifier {
    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        content.frame(minHeight: 680)
#else
        content
#endif
    }
}

extension View {
    @ViewBuilder
    func syncConflictPresentationSizing() -> some View {
#if targetEnvironment(macCatalyst)
        presentationDetents([.large])
#else
        self
#endif
    }
}

private struct SelectableConflictText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.showsVerticalScrollIndicator = true
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
