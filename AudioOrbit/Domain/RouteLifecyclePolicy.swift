import Foundation

enum ExistingRouteReconciliationAction: Equatable, Sendable {
    case useRunningRoute
    case retryAfterTransition
    case replaceRoute
}

enum RouteLifecyclePolicy {
    private static let maximumSwitchRetryCount = 2

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

    /// Returns the one-based retry number for a failed destination switch.
    /// Nil means the bounded allowance is exhausted and the same candidate
    /// must remain suppressed until a new/forced decision resets the count.
    static func nextSwitchRetryNumber(after failureCount: Int) -> Int? {
        guard failureCount < maximumSwitchRetryCount else { return nil }
        return failureCount + 1
    }

    /// Chooses a helper replacement without relying on Core Audio's process
    /// enumeration order. Renderer identity is strongest, followed by the
    /// helper bundle and process name. Equal best candidates are ambiguous and
    /// deliberately return nil so an unrelated Safari playback cannot capture
    /// the route during churn.
    static func replacementSource(
        from candidates: [AudioProcessSnapshot],
        originalBundleIdentifier: String?,
        originalName: String,
        anchoredRendererPID: pid_t?
    ) -> AudioProcessSnapshot? {
        guard !candidates.isEmpty else { return nil }
        let scored = candidates.map { candidate in
            var score = 0
            if candidate.pid == anchoredRendererPID { score += 8 }
            if let originalBundleIdentifier,
               candidate.bundleIdentifier == originalBundleIdentifier {
                score += 4
            }
            if candidate.name == originalName { score += 1 }
            return (candidate, score)
        }
        guard let bestScore = scored.map(\.1).max(), bestScore > 0 else {
            return nil
        }
        let best = scored.filter { $0.1 == bestScore }.map(\.0)
        return best.count == 1 ? best[0] : nil
    }

    static func shouldAttemptSilentMigration(
        silentSeconds: Int,
        firstAttemptAfter: Int,
        retryEvery: Int
    ) -> Bool {
        guard retryEvery > 0, silentSeconds >= firstAttemptAfter else {
            return false
        }
        return silentSeconds == firstAttemptAfter
            || (silentSeconds - firstAttemptAfter) % retryEvery == 0
    }
}
