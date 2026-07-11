import SwiftUI

struct NearbySyncView: View {
    @ObservedObject var syncController: MyRAMSyncController
    @ObservedObject var notesViewModel: NotesViewModel
    let style: EditorChromeStyle
    let prepareEditorState: () throws -> Void
    @State private var showingResetConfirmation = false

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

                section("Advanced") {
                    Button("Reset Pending Sync") {
                        showingResetConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(isResetDisabled)

                    switch notesViewModel.pendingSyncRecoveryStatus {
                    case .idle:
                        EmptyView()
                    case .running:
                        ProgressView()
                    case .succeeded:
                        Text("Replacement changes will drain after a connected peer acknowledges them.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
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
        .alert("Reset Pending Sync?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset and Resync", role: .destructive) {
                Task {
                    await notesViewModel.resetPendingSync(
                        syncController: syncController,
                        prepareEditorState: prepareEditorState
                    )
                }
            }
        } message: {
            Text(resetConfirmationMessage)
        }
    }

    private var isResetDisabled: Bool {
        syncController.pendingSyncStatus.totalOutboundItems == 0
            || !syncController.pendingSyncStatus.healthIssues.isEmpty
            || notesViewModel.pendingSyncRecoveryStatus.isRunning
    }

    private var resetConfirmationMessage: String {
        let status = syncController.pendingSyncStatus
        return """
        This will replace \(status.legacyChanges) legacy changes, \(status.unsentBatches) unsent batches, and \(status.localConvergenceObligations) pending local batch with a fresh synchronization of this device's current notes and related data.

        Your current local notes, folders, pinned content, attachments, and deletion state will remain on this device.
        """
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
