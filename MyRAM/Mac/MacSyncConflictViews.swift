#if os(macOS)
import SwiftUI

enum MacSyncConflictResolutionAction {
    case keepLocal
    case acceptIncoming
    case saveMerged(String)
}

struct MacSyncConflictSummaryView: View {
    let store: SyncConflictStore
    let refreshToken: Date?
    let resolve: (SyncConflictVersion, MacSyncConflictResolutionAction) async throws -> Void

    @State private var conflicts: [SyncConflictVersion] = []
    @State private var isPresented = false

    var body: some View {
        Button {
            refresh()
            isPresented = true
        } label: {
            HStack {
                Label("Conflicts", systemImage: "exclamationmark.bubble")
                Spacer()
                Text("\(conflicts.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .onAppear(perform: refresh)
        .onChange(of: refreshToken) { _, _ in refresh() }
        .sheet(isPresented: $isPresented, onDismiss: refresh) {
            MacSyncConflictListView(
                conflicts: $conflicts,
                store: store,
                resolve: resolve
            )
            .frame(minWidth: 680, minHeight: 480)
        }
    }

    init(
        store: SyncConflictStore,
        refreshToken: Date? = nil,
        resolve: @escaping (SyncConflictVersion, MacSyncConflictResolutionAction) async throws -> Void
    ) {
        self.store = store
        self.refreshToken = refreshToken
        self.resolve = resolve
    }

    private func refresh() {
        conflicts = store.activeConflicts()
    }
}

private struct MacSyncConflictListView: View {
    @Binding var conflicts: [SyncConflictVersion]
    let store: SyncConflictStore
    let resolve: (SyncConflictVersion, MacSyncConflictResolutionAction) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedConflictID: UUID?

    var body: some View {
        NavigationSplitView {
            List(conflicts, selection: $selectedConflictID) { conflict in
                VStack(alignment: .leading, spacing: 3) {
                    Text(conflict.field.displayName)
                        .font(.headline)
                    Text(conflict.entityID.uuidString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(conflict.id)
            }
            .navigationTitle("Sync Conflicts")
        } detail: {
            if let conflict = conflicts.first(where: { $0.id == selectedConflictID }) {
                MacSyncConflictDetailView(conflict: conflict) { action in
                    try await resolve(conflict, action)
                    conflicts = store.activeConflicts()
                    selectedConflictID = conflicts.first?.id
                }
            } else {
                ContentUnavailableView(
                    conflicts.isEmpty ? "No Conflicts" : "Select a Conflict",
                    systemImage: conflicts.isEmpty ? "checkmark.circle" : "exclamationmark.bubble"
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: dismiss.callAsFunction)
            }
        }
        .onAppear {
            conflicts = store.activeConflicts()
            selectedConflictID = selectedConflictID ?? conflicts.first?.id
        }
    }
}

private struct MacSyncConflictDetailView: View {
    let conflict: SyncConflictVersion
    let resolve: (MacSyncConflictResolutionAction) async throws -> Void

    @State private var mergedText: String
    @State private var isResolving = false
    @State private var errorMessage: String?

    init(
        conflict: SyncConflictVersion,
        resolve: @escaping (MacSyncConflictResolutionAction) async throws -> Void
    ) {
        self.conflict = conflict
        self.resolve = resolve
        _mergedText = State(initialValue: conflict.localText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(conflict.field.displayName)
                .font(.title2.weight(.semibold))

            HStack(alignment: .top, spacing: 12) {
                conflictText(title: "Local", text: conflict.localText)
                conflictText(title: "Incoming", text: conflict.remoteText)
            }

            Text("Merged Result")
                .font(.headline)
            TextEditor(text: $mergedText)
                .font(.body.monospaced())
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Button("Keep Local") { perform(.keepLocal) }
                Button("Accept Incoming") { perform(.acceptIncoming) }
                Spacer()
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Save Merged Result") { perform(.saveMerged(mergedText)) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(isResolving)
        }
        .padding(20)
    }

    private func conflictText(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ScrollView {
                Text(text.isEmpty ? "(Empty)" : text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
    }

    private func perform(_ action: MacSyncConflictResolutionAction) {
        guard !isResolving else { return }
        isResolving = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await resolve(action)
            } catch {
                errorMessage = "The conflict could not be resolved. It remains available to retry."
            }
            isResolving = false
        }
    }
}

private extension SyncConflictField {
    var displayName: String {
        switch self {
        case .noteTitle: "Note Title"
        case .noteContent: "Note Content"
        case .folderTitle: "Folder Title"
        case .pinnedText: "Pinned Text"
        }
    }
}
#endif
