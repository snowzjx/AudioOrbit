import XCTest
@testable import AudioOrbit

final class RouteRecoveryPolicyTests: XCTestCase {
    func testRunningRouteKeepsHealthyMatchingDestination() {
        XCTAssertEqual(
            RouteHardwareRecoveryPolicy.action(
                state: .running,
                destinationIsAlive: true,
                destinationMatchesRenderer: true
            ),
            .none
        )
    }

    func testRunningRouteEntersPassThroughWhenDestinationDisappears() {
        XCTAssertEqual(
            RouteHardwareRecoveryPolicy.action(
                state: .running,
                destinationIsAlive: false,
                destinationMatchesRenderer: false
            ),
            .enterSafePassThrough
        )
    }

    func testRunningRouteEntersPassThroughWhenHardwareIdentityChanges() {
        XCTAssertEqual(
            RouteHardwareRecoveryPolicy.action(
                state: .running,
                destinationIsAlive: true,
                destinationMatchesRenderer: false
            ),
            .enterSafePassThrough
        )
    }

    func testWaitingRouteOnlyStartsReconnectForLiveDestination() {
        XCTAssertEqual(
            RouteHardwareRecoveryPolicy.action(
                state: .waitingForDestination,
                destinationIsAlive: true,
                destinationMatchesRenderer: false
            ),
            .beginReconnectDwell
        )
        XCTAssertEqual(
            RouteHardwareRecoveryPolicy.action(
                state: .waitingForDestination,
                destinationIsAlive: false,
                destinationMatchesRenderer: false
            ),
            .none
        )
    }

    func testReconnectReturnsToWaitingIfDestinationVanishesAgain() {
        XCTAssertEqual(
            RouteHardwareRecoveryPolicy.action(
                state: .reconnecting,
                destinationIsAlive: false,
                destinationMatchesRenderer: false
            ),
            .cancelReconnectAndWait
        )
    }

    func testPermissionRevocationAlwaysChoosesAnAudiblePolicy() {
        XCTAssertEqual(
            PermissionRoutingPolicy.action(
                accessibilityGranted: false,
                automaticRoutingEnabled: true,
                hasConfiguredHeadphoneOverride: false
            ),
            .stopAndRestorePassThrough
        )
        XCTAssertEqual(
            PermissionRoutingPolicy.action(
                accessibilityGranted: false,
                automaticRoutingEnabled: true,
                hasConfiguredHeadphoneOverride: true
            ),
            .continueHeadphoneOverride
        )
    }
}
