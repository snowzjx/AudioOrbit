import Foundation

enum RouteHardwareRecoveryAction: Equatable, Sendable {
    case none
    case enterSafePassThrough
    case beginReconnectDwell
    case cancelReconnectAndWait
}

enum RouteHardwareRecoveryPolicy {
    static func action(
        state: TapProbeState,
        destinationIsAlive: Bool,
        destinationMatchesRenderer: Bool
    ) -> RouteHardwareRecoveryAction {
        switch state {
        case .running:
            return destinationIsAlive && destinationMatchesRenderer
                ? .none
                : .enterSafePassThrough
        case .waitingForDestination:
            return destinationIsAlive ? .beginReconnectDwell : .none
        case .reconnecting:
            return destinationIsAlive ? .none : .cancelReconnectAndWait
        case .idle, .starting, .switching, .stopping, .failed:
            return .none
        }
    }
}

enum PermissionRoutingAction: Equatable, Sendable {
    case keepCurrentState
    case continueHeadphoneOverride
    case stopAndRestorePassThrough
}

enum PermissionRoutingPolicy {
    static func action(
        accessibilityGranted: Bool,
        automaticRoutingEnabled: Bool,
        hasConfiguredHeadphoneOverride: Bool
    ) -> PermissionRoutingAction {
        if accessibilityGranted || !automaticRoutingEnabled {
            return .keepCurrentState
        }
        return hasConfiguredHeadphoneOverride
            ? .continueHeadphoneOverride
            : .stopAndRestorePassThrough
    }
}
