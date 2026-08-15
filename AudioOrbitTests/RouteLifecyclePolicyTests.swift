import XCTest
@testable import AudioOrbit

final class RouteLifecyclePolicyTests: XCTestCase {
    func testRunningRouteCanBeReconciledInPlace() {
        XCTAssertEqual(
            RouteLifecyclePolicy.reconciliationAction(for: .running),
            .useRunningRoute
        )
    }

    func testLifecycleTransitionsAreRetriedInsteadOfReplaced() {
        for state in [
            TapProbeState.starting,
            .switching,
            .stopping,
            .reconnecting,
        ] {
            XCTAssertEqual(
                RouteLifecyclePolicy.reconciliationAction(for: state),
                .retryAfterTransition,
                "Expected \(state) to be treated as an in-flight transition"
            )
        }
    }

    func testIncompleteCleanupAlwaysWaitsForRetry() {
        for state in [TapProbeState.idle, .waitingForDestination, .failed] {
            XCTAssertEqual(
                RouteLifecyclePolicy.reconciliationAction(for: state),
                .replaceRoute
            )
            XCTAssertEqual(
                RouteLifecyclePolicy.reconciliationAction(
                    for: state,
                    requiresCleanupRetry: true
                ),
                .retryAfterTransition
            )
        }
    }
}
