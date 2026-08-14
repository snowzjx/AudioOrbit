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
        XCTAssertEqual(WindowRouteAffinityPolicy.routeAnchor(
            existing: nil,
            selected: "playing",
            associationReason: .systemWebKitClient
        ), "playing")
        XCTAssertEqual(WindowRouteAffinityPolicy.routeAnchor(
            existing: "playing",
            selected: "focused-elsewhere",
            associationReason: .systemWebKitClient
        ), "playing")
        XCTAssertNil(WindowRouteAffinityPolicy.routeAnchor(
            existing: "playing",
            selected: "focused-elsewhere",
            associationReason: .sameProcess
        ))
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
