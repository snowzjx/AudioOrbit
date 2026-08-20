import CoreGraphics
import XCTest
@testable import AudioOrbit

final class WindowDisplayPolicyTests: XCTestCase {
    func testFocusedThenMainThenLargestVisibleWindowPolicy() throws {
        let displays = [display("00000000-0000-0000-0000-000000000001", frame: .init(x: 0, y: 0, width: 1_000, height: 800))]
        let candidates = [
            window("large", frame: .init(x: 0, y: 0, width: 900, height: 700)),
            window("main", frame: .init(x: 20, y: 20, width: 300, height: 300), isMain: true),
            window("focused", frame: .init(x: 40, y: 40, width: 100, height: 100), isFocused: true),
        ]

        var selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(from: candidates, displays: displays))
        XCTAssertEqual(selection.window.stableIdentifier, "focused")
        XCTAssertEqual(selection.source, .focused)

        selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: candidates.filter { !$0.isFocused },
            displays: displays
        ))
        XCTAssertEqual(selection.window.stableIdentifier, "main")
        XCTAssertEqual(selection.source, .main)

        selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: candidates.filter { !$0.isFocused && !$0.isMain },
            displays: displays
        ))
        XCTAssertEqual(selection.window.stableIdentifier, "large")
        XCTAssertEqual(selection.source, .largestVisible)
    }

    func testRejectsMinimizedNonNormalZeroAreaAndOffscreenWindows() {
        let displays = [display("00000000-0000-0000-0000-000000000001", frame: .init(x: 0, y: 0, width: 1_000, height: 800))]
        let candidates = [
            window("minimized", frame: .init(x: 0, y: 0, width: 100, height: 100), isMinimized: true),
            window("panel", frame: .init(x: 0, y: 0, width: 100, height: 100), isNormal: false),
            window("zero", frame: .zero),
            window("offscreen", frame: .init(x: 2_000, y: 2_000, width: 100, height: 100)),
        ]

        XCTAssertNil(WindowDisplayPolicy.selectWindow(from: candidates, displays: displays))
    }

    func testPlaybackWindowAnchorBeatsAnotherFocusedWindow() throws {
        let displays = [display(
            "00000000-0000-0000-0000-000000000001",
            frame: .init(x: 0, y: 0, width: 2_000, height: 800)
        )]
        let candidates = [
            window(
                "playing",
                frame: .init(x: 0, y: 0, width: 800, height: 700)
            ),
            window(
                "focused",
                frame: .init(x: 1_000, y: 0, width: 800, height: 700),
                isFocused: true
            ),
        ]

        let selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: candidates,
            displays: displays,
            preferredWindowIdentifier: "playing"
        ))

        XCTAssertEqual(selection.window.stableIdentifier, "playing")
        XCTAssertEqual(selection.source, .routeAnchor)
    }

    func testRendererAnchorBeatsStaleWindowIdentifierAndFocusedWindow() throws {
        let displays = [display(
            "00000000-0000-0000-0000-000000000001",
            frame: .init(x: 0, y: 0, width: 2_000, height: 800)
        )]
        var staleAnchor = window(
            "old-window",
            frame: .init(x: 0, y: 0, width: 800, height: 700),
            isFocused: true
        )
        staleAnchor.webViewProcessID = 10
        var movedPlaybackWindow = window(
            "new-window",
            frame: .init(x: 1_000, y: 0, width: 800, height: 700)
        )
        movedPlaybackWindow.webViewProcessID = 20

        let selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: [staleAnchor, movedPlaybackWindow],
            displays: displays,
            preferredWindowIdentifier: staleAnchor.stableIdentifier,
            preferredRendererPID: 20
        ))

        XCTAssertEqual(selection.window.stableIdentifier, "new-window")
        XCTAssertEqual(selection.source, .routeAnchor)
    }

    func testFullscreenWindowBeatsPlaybackAnchorUntilItExitsFullscreen() throws {
        let displays = [display(
            "00000000-0000-0000-0000-000000000001",
            frame: .init(x: 0, y: 0, width: 2_000, height: 800)
        )]
        var fullscreen = window(
            "fullscreen",
            frame: .init(x: 1_000, y: 0, width: 1_000, height: 800)
        )
        fullscreen.isFullscreen = true
        let anchor = window(
            "anchor",
            frame: .init(x: 0, y: 0, width: 900, height: 700),
            isFocused: true
        )

        var selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: [anchor, fullscreen],
            displays: displays,
            preferredWindowIdentifier: anchor.stableIdentifier
        ))
        XCTAssertEqual(selection.window.stableIdentifier, "fullscreen")
        XCTAssertEqual(selection.source, .fullscreen)

        fullscreen.isFullscreen = false
        selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: [anchor, fullscreen],
            displays: displays,
            preferredWindowIdentifier: anchor.stableIdentifier
        ))
        XCTAssertEqual(selection.window.stableIdentifier, "anchor")
        XCTAssertEqual(selection.source, .routeAnchor)
    }

    func testVideoPresentationWithAnotherRendererDoesNotStealRoute() throws {
        let displays = [display(
            "00000000-0000-0000-0000-000000000001",
            frame: .init(x: 0, y: 0, width: 2_000, height: 800)
        )]
        var anchor = window(
            "desktop-window",
            frame: .init(x: 0, y: 0, width: 1_000, height: 800)
        )
        anchor.webViewProcessID = 20
        var presentation = window(
            "video-presentation",
            frame: .init(x: 1_000, y: 0, width: 1_000, height: 800),
            isNormal: false
        )
        presentation.isFullscreen = true
        presentation.webViewProcessID = 30

        let selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: [anchor, presentation],
            displays: displays,
            preferredWindowIdentifier: anchor.stableIdentifier,
            preferredRendererPID: 20
        ))

        XCTAssertEqual(selection.window.stableIdentifier, anchor.stableIdentifier)
        XCTAssertEqual(selection.source, .routeAnchor)
    }

    func testSingleOwnerRouteMayFollowOneWebKitHandoffPresentation() throws {
        let displays = [display(
            "00000000-0000-0000-0000-000000000001",
            frame: .init(x: 0, y: 0, width: 2_000, height: 800)
        )]
        var anchor = window(
            "desktop-window",
            frame: .init(x: 0, y: 0, width: 1_000, height: 800)
        )
        anchor.webViewProcessID = 20
        var presentation = window(
            "video-presentation",
            frame: .init(x: 1_000, y: 0, width: 1_000, height: 800),
            isNormal: false
        )
        presentation.isFullscreen = true
        presentation.webViewProcessID = 30

        let selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: [anchor, presentation],
            displays: displays,
            preferredWindowIdentifier: anchor.stableIdentifier,
            preferredRendererPID: 20,
            allowsUnverifiedFullscreenPresentation: true
        ))

        XCTAssertEqual(selection.window.stableIdentifier, presentation.stableIdentifier)
        XCTAssertEqual(selection.source, .fullscreen)
    }

    func testSingleUnlabelledVideoPresentationMayRepresentAnchoredRenderer() throws {
        let displays = [display(
            "00000000-0000-0000-0000-000000000001",
            frame: .init(x: 0, y: 0, width: 2_000, height: 800)
        )]
        var anchor = window(
            "desktop-window",
            frame: .init(x: 0, y: 0, width: 1_000, height: 800)
        )
        anchor.webViewProcessID = 20
        var presentation = window(
            "video-presentation",
            frame: .init(x: 1_000, y: 0, width: 1_000, height: 800),
            isNormal: false
        )
        presentation.isFullscreen = true

        let selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: [anchor, presentation],
            displays: displays,
            preferredWindowIdentifier: anchor.stableIdentifier,
            preferredRendererPID: 20
        ))

        XCTAssertEqual(selection.window.stableIdentifier, presentation.stableIdentifier)
        XCTAssertEqual(selection.source, .fullscreen)
    }

    func testMultipleUnlabelledPresentationsKeepAnchoredWindow() throws {
        let displays = [display(
            "00000000-0000-0000-0000-000000000001",
            frame: .init(x: 0, y: 0, width: 3_000, height: 800)
        )]
        var anchor = window(
            "desktop-window",
            frame: .init(x: 0, y: 0, width: 1_000, height: 800)
        )
        anchor.webViewProcessID = 20
        var first = window(
            "presentation-a",
            frame: .init(x: 1_000, y: 0, width: 1_000, height: 800),
            isNormal: false
        )
        first.isFullscreen = true
        var second = window(
            "presentation-b",
            frame: .init(x: 2_000, y: 0, width: 1_000, height: 800),
            isNormal: false
        )
        second.isFullscreen = true

        let selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: [anchor, first, second],
            displays: displays,
            preferredWindowIdentifier: anchor.stableIdentifier,
            preferredRendererPID: 20
        ))

        XCTAssertEqual(selection.window.stableIdentifier, anchor.stableIdentifier)
        XCTAssertEqual(selection.source, .routeAnchor)
    }

    func testMultipleFullscreenWindowsPreferAnchoredRendererAndOtherwiseStayDeterministic() throws {
        let displays = [display(
            "00000000-0000-0000-0000-000000000001",
            frame: .init(x: 0, y: 0, width: 2_000, height: 800)
        )]
        var first = window(
            "cg:200",
            frame: .init(x: 0, y: 0, width: 1_000, height: 800)
        )
        first.isFullscreen = true
        first.webViewProcessID = 20
        var second = window(
            "cg:100",
            frame: .init(x: 1_000, y: 0, width: 1_000, height: 800)
        )
        second.isFullscreen = true
        second.webViewProcessID = 10

        var selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: [first, second],
            displays: displays,
            preferredRendererPID: 20
        ))
        XCTAssertEqual(selection.window.stableIdentifier, "cg:200")

        selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: [first, second],
            displays: displays
        ))
        XCTAssertEqual(selection.window.stableIdentifier, "cg:100")
        selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: [second, first],
            displays: displays
        ))
        XCTAssertEqual(selection.window.stableIdentifier, "cg:100")

        let anchor = window(
            "anchor",
            frame: .init(x: 0, y: 0, width: 800, height: 700)
        )
        selection = try XCTUnwrap(WindowDisplayPolicy.selectWindow(
            from: [anchor, second],
            displays: displays,
            preferredWindowIdentifier: anchor.stableIdentifier,
            preferredRendererPID: 20
        ))
        XCTAssertEqual(selection.window.stableIdentifier, "anchor")
        XCTAssertEqual(selection.source, .routeAnchor)
    }

    func testMissingPlaybackWindowAnchorDoesNotFallBackToFocusedWindow() {
        let displays = [display(
            "00000000-0000-0000-0000-000000000001",
            frame: .init(x: 0, y: 0, width: 1_000, height: 800)
        )]

        XCTAssertNil(WindowDisplayPolicy.selectWindow(
            from: [window(
                "focused",
                frame: .init(x: 0, y: 0, width: 800, height: 700),
                isFocused: true
            )],
            displays: displays,
            preferredWindowIdentifier: "playing"
        ))
    }

    func testOnlyHelperAssociationsPinTheirInitialWindow() {
        XCTAssertFalse(WindowRouteAffinityPolicy.pinsInitialWindow(for: .sameProcess))
        XCTAssertTrue(WindowRouteAffinityPolicy.pinsInitialWindow(for: .parentApplication))
        XCTAssertTrue(WindowRouteAffinityPolicy.pinsInitialWindow(for: .matchingBundle))
        XCTAssertTrue(WindowRouteAffinityPolicy.pinsInitialWindow(for: .systemWebKitClient))
        XCTAssertFalse(WindowRouteAffinityPolicy.beginsNewPlaybackSession(
            wasRunningOutput: nil,
            isRunningOutput: true
        ))
        XCTAssertFalse(WindowRouteAffinityPolicy.beginsNewPlaybackSession(
            wasRunningOutput: true,
            isRunningOutput: true
        ))
        XCTAssertTrue(WindowRouteAffinityPolicy.beginsNewPlaybackSession(
            wasRunningOutput: false,
            isRunningOutput: true
        ))
        XCTAssertFalse(WindowRouteAffinityPolicy.beginsNewPlaybackSession(
            wasRunningOutput: false,
            isRunningOutput: true,
            silenceTicks: 1,
            requiredSilenceTicks: 2
        ))
        XCTAssertTrue(WindowRouteAffinityPolicy.beginsNewPlaybackSession(
            wasRunningOutput: false,
            isRunningOutput: true,
            silenceTicks: 2,
            requiredSilenceTicks: 2
        ))
    }

    func testRendererReporterKeepsCurrentWindowWhenPIDAppearsTwice() {
        let reporters: [String: pid_t] = [
            "cg:11604": 900,
            "cg:12134": 900,
        ]

        XCTAssertEqual(
            WindowRouteAffinityPolicy.reporterWindowIdentifier(
                rendererPID: 900,
                currentWindowIdentifier: "cg:12134",
                webViewProcessIDsByWindow: reporters
            ),
            "cg:12134"
        )
        XCTAssertEqual(
            WindowRouteAffinityPolicy.reporterWindowIdentifier(
                rendererPID: 900,
                currentWindowIdentifier: "gone",
                webViewProcessIDsByWindow: reporters
            ),
            "cg:11604"
        )
    }

    func testWebContentSourceSeedsRendererBeforeWindowAnchorExists() {
        XCTAssertEqual(
            WindowRouteAffinityPolicy.preferredRendererPID(
                anchoredRendererPID: nil,
                sourcePID: 900,
                sourceBundleIdentifier: "com.apple.WebKit.WebContent"
            ),
            900
        )
        XCTAssertNil(WindowRouteAffinityPolicy.preferredRendererPID(
            anchoredRendererPID: nil,
            sourcePID: 901,
            sourceBundleIdentifier: "com.apple.WebKit.GPU"
        ))
        XCTAssertEqual(
            WindowRouteAffinityPolicy.preferredRendererPID(
                anchoredRendererPID: 777,
                sourcePID: 900,
                sourceBundleIdentifier: "com.apple.WebKit.WebContent"
            ),
            777
        )
    }

    func testPrecomputedEvidenceIsOnlyReusedForMatchingDirectFirstRoute() {
        XCTAssertTrue(WindowRouteAffinityPolicy.canReusePrecomputedEvidence(
            sourcePID: 100,
            associationReason: .sameProcess,
            cachedSourcePID: 100,
            cachedAssociationReason: .sameProcess,
            committedDisplayUUID: nil,
            preferredWindowIdentifier: nil,
            preferredRendererPID: nil
        ))
        XCTAssertFalse(WindowRouteAffinityPolicy.canReusePrecomputedEvidence(
            sourcePID: 200,
            associationReason: .systemWebKitClient,
            cachedSourcePID: 100,
            cachedAssociationReason: .sameProcess,
            committedDisplayUUID: nil,
            preferredWindowIdentifier: nil,
            preferredRendererPID: nil
        ))
        XCTAssertFalse(WindowRouteAffinityPolicy.canReusePrecomputedEvidence(
            sourcePID: 100,
            associationReason: .sameProcess,
            cachedSourcePID: 100,
            cachedAssociationReason: .sameProcess,
            committedDisplayUUID: UUID(),
            preferredWindowIdentifier: "cg:1",
            preferredRendererPID: 10
        ))
    }

    func testMediaTargetAdoptionRemovedWithDwellMachinery() {
        // The dwell-based media arbitration was replaced by
        // event-corroborated adoption; the policy helper is gone and the
        // anchor decision lives in AppModel. Keep a placeholder so the
        // suite still names the behavior it used to pin down.
        XCTAssertTrue(WindowRouteAffinityPolicy.pinsInitialWindow(for: .parentApplication))
        XCTAssertFalse(WindowRouteAffinityPolicy.pinsInitialWindow(for: .sameProcess))
    }

    func testSafariWindowIdentifierNormalizesToStableUUID() {
        let secure = AccessibilityWindowDiscovery.stableAXIdentifier(
            "SafariWindow?IsSecure=true&UUID=9F1E1A0F-249C-4FCC-930D-27702C2C5D5D"
        )
        let insecure = AccessibilityWindowDiscovery.stableAXIdentifier(
            "SafariWindow?IsSecure=false&UUID=9F1E1A0F-249C-4FCC-930D-27702C2C5D5D"
        )
        let extended = AccessibilityWindowDiscovery.stableAXIdentifier(
            "SafariWindow?UUID=9F1E1A0F-249C-4FCC-930D-27702C2C5D5D&Mode=Video"
        )
        XCTAssertEqual(secure, "9F1E1A0F-249C-4FCC-930D-27702C2C5D5D")
        XCTAssertEqual(insecure, "9F1E1A0F-249C-4FCC-930D-27702C2C5D5D")
        XCTAssertEqual(extended, "9F1E1A0F-249C-4FCC-930D-27702C2C5D5D")
        XCTAssertEqual(
            AccessibilityWindowDiscovery.stableAXIdentifier(
                "Mail.messageViewer.window.15"
            ),
            "Mail.messageViewer.window.15"
        )
        XCTAssertNil(AccessibilityWindowDiscovery.stableAXIdentifier("UUID="))
        XCTAssertNil(AccessibilityWindowDiscovery.stableAXIdentifier(nil))
    }

    func testLargestIntersectionWorksWithNegativeAndVerticallyStackedCoordinates() throws {
        let left = display("00000000-0000-0000-0000-000000000001", name: "Left", frame: .init(x: -1_000, y: 0, width: 1_000, height: 800))
        let main = display("00000000-0000-0000-0000-000000000002", name: "Main", frame: .init(x: 0, y: 0, width: 1_000, height: 800))
        let upper = display("00000000-0000-0000-0000-000000000003", name: "Upper", frame: .init(x: 0, y: -800, width: 1_000, height: 800))

        XCTAssertEqual(
            WindowDisplayPolicy.resolveDisplay(
                for: .init(x: -700, y: 100, width: 900, height: 500),
                displays: [left, main, upper]
            )?.name,
            "Left"
        )
        XCTAssertEqual(
            WindowDisplayPolicy.resolveDisplay(
                for: .init(x: 100, y: -700, width: 600, height: 900),
                displays: [left, main, upper]
            )?.name,
            "Upper"
        )
    }

    func testDisplayTiePrefersCommittedThenWindowCenterThenUUID() throws {
        let left = display("00000000-0000-0000-0000-000000000001", name: "Left", frame: .init(x: 0, y: 0, width: 500, height: 500))
        let right = display("00000000-0000-0000-0000-000000000002", name: "Right", frame: .init(x: 500, y: 0, width: 500, height: 500))
        let centeredOnBoundary = CGRect(x: 400, y: 100, width: 200, height: 200)

        XCTAssertEqual(
            WindowDisplayPolicy.resolveDisplay(
                for: centeredOnBoundary,
                displays: [left, right],
                committedDisplayUUID: right.id
            )?.id,
            right.id
        )
        XCTAssertEqual(
            WindowDisplayPolicy.resolveDisplay(
                for: .init(x: 450, y: 100, width: 200, height: 200),
                displays: [left, right]
            )?.id,
            right.id
        )
        XCTAssertEqual(
            WindowDisplayPolicy.resolveDisplay(
                for: centeredOnBoundary,
                displays: [left, right]
            )?.id,
            left.id
        )
    }

    func testDisplayTransitionRequiresStrongBoundaryEvidence() {
        let left = display(
            "00000000-0000-0000-0000-000000000001",
            name: "Left",
            frame: .init(x: 0, y: 0, width: 1_000, height: 800)
        )
        let right = display(
            "00000000-0000-0000-0000-000000000002",
            name: "Right",
            frame: .init(x: 1_000, y: 0, width: 1_000, height: 800)
        )

        XCTAssertFalse(DisplayTransitionPolicy.shouldCommit(
            candidateDisplayUUID: right.id,
            committedDisplayUUID: left.id,
            windowFrame: .init(x: 750, y: 100, width: 500, height: 400),
            displays: [left, right]
        ))
        XCTAssertTrue(DisplayTransitionPolicy.shouldCommit(
            candidateDisplayUUID: right.id,
            committedDisplayUUID: left.id,
            windowFrame: .init(x: 850, y: 100, width: 500, height: 400),
            displays: [left, right]
        ))
    }

    func testDisplayTransitionAllowsFirstCommitWithoutStrongEvidence() {
        let left = display(
            "00000000-0000-0000-0000-000000000001",
            frame: .init(x: 0, y: 0, width: 1_000, height: 800)
        )

        XCTAssertTrue(DisplayTransitionPolicy.shouldCommit(
            candidateDisplayUUID: left.id,
            committedDisplayUUID: nil,
            windowFrame: .init(x: -900, y: 100, width: 1_000, height: 400),
            displays: [left]
        ))
    }

    func testSurfaceFallbackRequiresNearFullscreenGeometry() {
        let display = display(
            "00000000-0000-0000-0000-000000000001",
            frame: .init(x: 0, y: 0, width: 1_000, height: 800)
        )

        XCTAssertTrue(WindowDisplayPolicy.isLikelyFullscreenSurface(
            .init(x: 0, y: 0, width: 1_000, height: 800),
            displays: [display]
        ))
        XCTAssertTrue(WindowDisplayPolicy.isLikelyFullscreenSurface(
            .init(x: 0, y: 20, width: 1_000, height: 760),
            displays: [display]
        ))
        XCTAssertFalse(WindowDisplayPolicy.isLikelyFullscreenSurface(
            .init(x: 100, y: 100, width: 800, height: 600),
            displays: [display]
        ))
    }

    private func display(
        _ uuid: String,
        name: String = "Display",
        frame: CGRect
    ) -> DisplaySnapshot {
        DisplaySnapshot(
            id: UUID(uuidString: uuid)!,
            runtimeID: 1,
            name: name,
            frame: frame,
            scale: 2,
            isMain: false,
            isBuiltIn: false
        )
    }

    private func window(
        _ id: String,
        frame: CGRect,
        isFocused: Bool = false,
        isMain: Bool = false,
        isMinimized: Bool = false,
        isNormal: Bool = true
    ) -> WindowCandidateSnapshot {
        WindowCandidateSnapshot(
            stableIdentifier: id,
            frame: frame,
            isFocused: isFocused,
            isMain: isMain,
            isMinimized: isMinimized,
            isNormalWindow: isNormal,
            frontToBackIndex: 0
        )
    }
}
