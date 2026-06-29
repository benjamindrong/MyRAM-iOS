import Foundation

enum MacSidebarCollapsePolicy {
    enum CollapseState: Equatable {
        case expanded
        case autoCollapsed
        case manuallyCollapsed
    }

    static let collapseWidthThreshold: CGFloat = 500

    static func stateAfterWidthChange(
        currentState: CollapseState,
        availableWidth: CGFloat,
        collapseThreshold: CGFloat = collapseWidthThreshold
    ) -> CollapseState {
        switch currentState {
        case .manuallyCollapsed:
            return .manuallyCollapsed
        case .expanded:
            return availableWidth < collapseThreshold ? .autoCollapsed : .expanded
        case .autoCollapsed:
            return availableWidth >= collapseThreshold ? .expanded : .autoCollapsed
        }
    }

    static func stateAfterManualVisibilityChange(isSidebarVisible: Bool) -> CollapseState {
        isSidebarVisible ? .expanded : .manuallyCollapsed
    }
}
