#if os(macOS)
import Foundation
@preconcurrency import MultipeerConnectivity

typealias MacSyncSeenBatchStore = SyncBatchSeenBatchStore

#if DEBUG
extension MacSyncBatchController {
    /// BEN-36-only network cycling seam. It is unavailable unless the launch has passed the
    /// endurance safety gate, and it operates only on the controller's retained production
    /// MultipeerConnectivity objects so the workload exercises the real transport path.
    @discardableResult
    func setBenchmarkEnduranceNetworkingEnabled(_ enabled: Bool) -> Bool {
        guard case .valid = MyRAMSyncBenchmarkConfiguration.enduranceLaunchValidation() else {
            return false
        }

        let children = Mirror(reflecting: self).children
        guard let session = children.first(where: { $0.label == "session" })?.value as? MCSession,
              let advertiser = children.first(where: { $0.label == "advertiser" })?.value as? MCNearbyServiceAdvertiser,
              let browser = children.first(where: { $0.label == "browser" })?.value as? MCNearbyServiceBrowser else {
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .peerObserved,
                outcome: "enduranceNetworkControlUnavailable"
            )
            return false
        }

        if enabled {
            advertiser.startAdvertisingPeer()
            browser.startBrowsingForPeers()
        } else {
            advertiser.stopAdvertisingPeer()
            browser.stopBrowsingForPeers()
            session.disconnect()
        }
        return true
    }
}
#endif
#endif
