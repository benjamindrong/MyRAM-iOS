import SwiftUI

struct NearbySyncView: View {
    @ObservedObject var syncController: MyRAMSyncController
    let style: EditorChromeStyle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Connection") {
                    LabeledContent("Device", value: syncController.localPeerName)
                    LabeledContent("Status", value: syncController.connectionSummary)
                    LabeledContent("Last Event", value: syncController.lastConnectionEvent)
                    pendingStatusRows(syncController.pendingSyncStatus)
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

    @ViewBuilder
    private func pendingStatusRows(_ status: PendingSyncStatus) -> some View {
        LabeledContent("Queued Changes", value: "\(status.totalOutboundItems)")
        if status.legacyChanges > 0 {
            LabeledContent("Legacy changes", value: "\(status.legacyChanges)")
        }
        if status.unsentBatches > 0 {
            LabeledContent("Unsent batches", value: "\(status.unsentBatches)")
        }
        if status.localConvergenceObligations > 0 {
            LabeledContent("Pending local batch", value: "\(status.localConvergenceObligations)")
        }
        ForEach(Array(status.healthIssues.enumerated()), id: \.offset) { _, issue in
            Text(issue.description)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
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
