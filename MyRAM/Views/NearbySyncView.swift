import SwiftUI

struct NearbySyncView: View {
    @ObservedObject var syncController: MyRAMSyncController
    let style: EditorChromeStyle
    let conflicts: [SyncConflictVersion]
    let localTextForConflict: (SyncConflictVersion) -> String
    let onCopyConflict: (SyncConflictVersion) -> Void
    let onRestoreConflict: (SyncConflictVersion) -> Void
    let onReviewConflict: (SyncConflictVersion) -> Void
    let onDiscardConflict: (SyncConflictVersion) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Connection") {
                    LabeledContent("Device", value: syncController.localPeerName)
                    LabeledContent("Status", value: syncController.connectionSummary)
                    LabeledContent("Last Event", value: syncController.lastConnectionEvent)
                    LabeledContent("Queued Changes", value: "\(syncController.pendingChangeCount)")
                    if let lastSyncAt = syncController.lastSyncAt {
                        LabeledContent("Last Sync", value: lastSyncAt.formatted(date: .abbreviated, time: .standard))
                    }

                    Button("Manual Sync") {
                        syncController.flushPendingChanges()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!syncController.hasConnectedPeers)
                }

                section("Nearby Devices") {
                    if syncController.availablePeers.isEmpty {
                        Text("No nearby devices")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(syncController.availablePeers) { peer in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(peer.isTrusted ? "Trusted" : "New device")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button(peer.isTrusted ? "Reconnect" : "Pair") {
                                syncController.invite(peer)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                section("Sync Conflicts") {
                    if conflicts.isEmpty {
                        Text("No versions waiting to sync")
                            .foregroundStyle(.secondary)
                    } else {
                        SyncConflictReviewList(
                            conflicts: conflicts,
                            localText: localTextForConflict,
                            onCopy: onCopyConflict,
                            onRestore: onRestoreConflict,
                            onReview: onReviewConflict,
                            onDiscard: onDiscardConflict
                        )
                    }
                }

                if let lastErrorMessage = syncController.lastErrorMessage {
                    Text(lastErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .background(style.appBackgroundColor.ignoresSafeArea())
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.listRowBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
