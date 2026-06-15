import SwiftUI

struct SyncStatusIndicator: View {
    @ObservedObject var syncController: MyRAMSyncController
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("sync-status-indicator")
    }

    private var content: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(status.color.opacity(0.18))
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
            }

            Image(systemName: status.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.color)

            Text(status.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if syncController.pendingChangeCount > 0 {
                Text("\(syncController.pendingChangeCount)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(status.color.opacity(0.18))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(status.color.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var status: SyncIndicatorStatus {
        if syncController.lastErrorMessage != nil {
            return SyncIndicatorStatus(
                title: "Sync Issue",
                symbol: "exclamationmark.triangle.fill",
                color: .red
            )
        }

        if syncController.hasConnectedPeers {
            return SyncIndicatorStatus(
                title: syncController.pendingChangeCount > 0 ? "Syncing" : "Connected",
                symbol: "dot.radiowaves.left.and.right",
                color: syncController.pendingChangeCount > 0 ? .orange : .green
            )
        }

        if syncController.pendingChangeCount > 0 {
            return SyncIndicatorStatus(
                title: "Queued",
                symbol: "tray.full.fill",
                color: .orange
            )
        }

        return SyncIndicatorStatus(
            title: "Nearby",
            symbol: "dot.radiowaves.left.and.right",
            color: .secondary
        )
    }

    private var accessibilityText: String {
        if syncController.pendingChangeCount > 0 {
            return "\(status.title), \(syncController.pendingChangeCount) queued changes"
        }
        return status.title
    }
}

private struct SyncIndicatorStatus {
    let title: String
    let symbol: String
    let color: Color
}
