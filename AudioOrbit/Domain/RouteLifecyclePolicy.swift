import Foundation

enum ExistingRouteReconciliationAction: Equatable, Sendable {
    case useRunningRoute
    case retryAfterTransition
    case replaceRoute
}

enum RouteLifecyclePolicy {
    static func reconciliationAction(
        for state: TapProbeState,
        requiresCleanupRetry: Bool = false
    ) -> ExistingRouteReconciliationAction {
        if requiresCleanupRetry {
            return .retryAfterTransition
        }
        switch state {
        case .running:
            return .useRunningRoute
        case .starting, .switching, .stopping, .reconnecting:
            return .retryAfterTransition
        case .idle, .waitingForDestination, .failed:
            return .replaceRoute
        }
    }
}
