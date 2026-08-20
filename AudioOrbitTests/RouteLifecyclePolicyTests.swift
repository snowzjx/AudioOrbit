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

    func testDestinationSwitchRetryIsBounded() {
        XCTAssertEqual(
            RouteLifecyclePolicy.nextSwitchRetryNumber(after: 0),
            1
        )
        XCTAssertEqual(
            RouteLifecyclePolicy.nextSwitchRetryNumber(after: 1),
            2
        )
        XCTAssertNil(RouteLifecyclePolicy.nextSwitchRetryNumber(after: 2))
        XCTAssertNil(RouteLifecyclePolicy.nextSwitchRetryNumber(after: 3))
    }

    func testReplacementPrefersRendererThenMatchingHelperIdentity() throws {
        let renderer = process(
            pid: 20,
            bundle: "com.apple.WebKit.WebContent",
            name: "Safari Web Content"
        )
        let matchingGPU = process(
            pid: 30,
            bundle: "com.apple.WebKit.GPU",
            name: "Safari Graphics and Media"
        )

        XCTAssertEqual(
            RouteLifecyclePolicy.replacementSource(
                from: [matchingGPU, renderer],
                originalBundleIdentifier: "com.apple.WebKit.GPU",
                originalName: "Safari Graphics and Media",
                anchoredRendererPID: 20
            )?.pid,
            renderer.pid
        )
        XCTAssertEqual(
            RouteLifecyclePolicy.replacementSource(
                from: [renderer, matchingGPU],
                originalBundleIdentifier: "com.apple.WebKit.GPU",
                originalName: "Safari Graphics and Media",
                anchoredRendererPID: nil
            )?.pid,
            matchingGPU.pid
        )
    }

    func testReplacementRejectsEqualSafariCandidates() {
        let first = process(
            pid: 20,
            bundle: "com.apple.WebKit.GPU",
            name: "Safari Graphics and Media"
        )
        let second = process(
            pid: 30,
            bundle: "com.apple.WebKit.GPU",
            name: "Safari Graphics and Media"
        )

        XCTAssertNil(RouteLifecyclePolicy.replacementSource(
            from: [first, second],
            originalBundleIdentifier: "com.apple.WebKit.GPU",
            originalName: "Safari Graphics and Media",
            anchoredRendererPID: nil
        ))
    }

    func testSilentMigrationStartsAtThreeSecondsThenRetriesEveryFive() {
        let attempts = (0...15).filter {
            RouteLifecyclePolicy.shouldAttemptSilentMigration(
                silentSeconds: $0,
                firstAttemptAfter: 3,
                retryEvery: 5
            )
        }
        XCTAssertEqual(attempts, [3, 8, 13])
    }

    private func process(
        pid: pid_t,
        bundle: String,
        name: String
    ) -> AudioProcessSnapshot {
        AudioProcessSnapshot(
            id: UInt32(pid),
            pid: pid,
            bundleIdentifier: bundle,
            name: name,
            isRunningOutput: true
        )
    }
}
