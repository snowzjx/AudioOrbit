import CoreGraphics
import Foundation

struct DisplaySnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let runtimeID: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let scale: Double
    let isMain: Bool
    let isBuiltIn: Bool
}

enum WindowSelectionSource: String, Equatable, Sendable {
    case fullscreen = "Fullscreen window"
    case focused = "Focused window"
    case main = "Main window"
    case largestVisible = "Largest visible window"
    case routeAnchor = "Playback window"
    case mediaIndicator = "Playing media window"
}

struct WindowCandidateSnapshot: Equatable, Sendable {
    let stableIdentifier: String
    let frame: CGRect
    let isFocused: Bool
    let isMain: Bool
    let isMinimized: Bool
    let isNormalWindow: Bool
    let frontToBackIndex: Int
    /// True when the window reports kAXFullscreenAttribute — Safari's
    /// fullscreen presentation (green button or WebKit video fullscreen).
    var isFullscreen = false
    /// True for pure Core Graphics surfaces with no matching AX window
    /// (for example Safari's HTML video fullscreen surface). These inform
    /// display decisions but must never become the route anchor, which
    /// belongs to the application's real window.
    var isSurfaceOnly = false
    var webViewProcessID: pid_t?
}

struct WindowDisplayEvidence: Equatable, Sendable {
    let sourcePID: pid_t
    let sourceName: String
    let audioProcessName: String
    let windowOwnerPID: pid_t
    let associationReason: ProcessWindowAssociationReason
    let eligibleWindowCount: Int
    let selectedWindowIdentifier: String?
    let selectionSource: WindowSelectionSource?
    let windowFrame: CGRect?
    let displayUUID: UUID?
    let displayName: String?
    let issue: String?
    let candidateWindowIdentifiers: [String]
    /// Frames of all candidate windows/surfaces by stable identifier, used
    /// to detect Mission Control's simultaneous window scaling.
    var candidateWindowFrames: [String: CGRect] = [:]
    let focusedWindowIdentifier: String?
    var webViewProcessIDsByWindow: [String: pid_t] = [:]
    /// Identifiers of pure-surface candidates (Safari's fullscreen video
    /// surface): they may drive the display but never the anchor, and they
    /// are excluded from Mission Control's overview detection because the
    /// fullscreen-exit animation legitimately shrinks them.
    var surfaceOnlyWindowIdentifiers: [String] = []
}

enum WindowDisplayPolicy {
    static func selectWindow(
        from candidates: [WindowCandidateSnapshot],
        displays: [DisplaySnapshot],
        preferredWindowIdentifier: String? = nil,
        preferredRendererPID: pid_t? = nil,
        allowsUnverifiedFullscreenPresentation: Bool = false
    ) -> (window: WindowCandidateSnapshot, source: WindowSelectionSource)? {
        let eligible = candidates.filter { candidate in
            // Safari's fullscreen presentation is an AXDialog (non-standard
            // subrole) with AXFullScreen=true; it must be eligible so the
            // fullscreen preference below can drive the display.
            guard (candidate.isNormalWindow || candidate.isFullscreen),
                  !candidate.isMinimized,
                  candidate.frame.width > 0,
                  candidate.frame.height > 0 else { return false }
            return visibleArea(of: candidate.frame, on: displays) > 0
        }

        // A fullscreen window (Safari's fullscreen presentation)
        // dominates the user's attention. It must also win over a preferred
        // route anchor: Safari emits ordinary window-moved/focus events while
        // constructing and tearing down this presentation, and temporarily
        // falling back to the desktop window would bounce the route between
        // displays during the transition.
        let fullscreenCandidates = eligible.filter(\.isFullscreen)
        let videoPresentations = fullscreenCandidates.filter {
            !$0.isNormalWindow
        }
        if !videoPresentations.isEmpty {
            // Safari's HTML-video fullscreen surface is exposed as an
            // AXDialog rather than an AXStandardWindow. Prefer a matching
            // renderer, or retain a presentation already leased by this
            // route. Explicitly conflicting renderer evidence is never
            // allowed to capture the route.
            if let preferredRendererPID,
               let matchingPresentation = videoPresentations
                   .filter({ $0.webViewProcessID == preferredRendererPID })
                   .sorted(by: stableWindowOrder)
                   .first {
                return (matchingPresentation, .fullscreen)
            }
            if let preferredWindowIdentifier,
               let currentPresentation = videoPresentations.first(where: {
                   $0.stableIdentifier == preferredWindowIdentifier
               }) {
                return (currentPresentation, .fullscreen)
            }
            if preferredRendererPID != nil {
                // A presentation explicitly reporting another renderer
                // belongs to another Safari playback route. A single
                // unlabelled dialog may be the anchored renderer while
                // WebKit is handing it off; conflicting or multiple
                // presentations are ambiguous and must not steal the route.
                let unlabelled = fullscreenCandidates.filter {
                    $0.webViewProcessID == nil
                }
                if unlabelled.count == 1, let presentation = unlabelled.first {
                    return (presentation, .fullscreen)
                }
                if allowsUnverifiedFullscreenPresentation,
                   videoPresentations.count == 1,
                   let presentation = videoPresentations.first {
                    // With exactly one active route for this Safari owner,
                    // WebKit's one mismatched handoff dialog cannot conflict
                    // with another playback route. Multiple owner routes keep
                    // this escape hatch disabled in AppModel.
                    return (presentation, .fullscreen)
                }
            } else if let presentation = videoPresentations
                .sorted(by: stableWindowOrder)
                .first {
                return (presentation, .fullscreen)
            }
        }
        if let preferredRendererPID,
           let fullscreen = fullscreenCandidates
               .filter({ $0.webViewProcessID == preferredRendererPID })
               .sorted(by: stableWindowOrder)
               .first {
            return (fullscreen, .fullscreen)
        }
        if let preferredWindowIdentifier,
           let fullscreen = fullscreenCandidates.first(where: {
               $0.stableIdentifier == preferredWindowIdentifier
           }) {
            return (fullscreen, .fullscreen)
        }
        let unlabelledFullscreenCandidates = fullscreenCandidates.filter {
            $0.webViewProcessID == nil
        }
        if preferredRendererPID != nil,
           unlabelledFullscreenCandidates.count == 1,
           let fullscreen = unlabelledFullscreenCandidates.first {
            // Some WebKit presentation dialogs do not expose BrowserView.
            // An unlabelled fullscreen may still represent the anchored
            // renderer; a fullscreen explicitly owned by another renderer
            // must never steal this route.
            return (fullscreen, .fullscreen)
        }
        // More than one standard Safari window can temporarily claim
        // fullscreen.
        // AX front-to-back order changes with focus, so an arbitrary `first`
        // would flap between displays. A stable identifier tie-break keeps
        // the choice fixed when renderer evidence is unavailable.
        if preferredRendererPID == nil,
           let fullscreen = fullscreenCandidates.sorted(by: stableWindowOrder).first {
            return (fullscreen, .fullscreen)
        }

        // Outside fullscreen, the renderer PID is the playback identity.
        // Safari can replace a window's CG surface while it is dragged or
        // while a tab is torn off, so the old stable window identifier may
        // disappear for one evidence pass. Select the window that currently
        // hosts the anchored renderer in the same pass instead of returning
        // no evidence and waiting for another AX event.
        if let preferredRendererPID {
            let rendererCandidates = eligible.filter {
                $0.webViewProcessID == preferredRendererPID
            }
            if let preferredWindowIdentifier,
               let currentReporter = rendererCandidates.first(where: {
                   $0.stableIdentifier == preferredWindowIdentifier
               }) {
                return (currentReporter, .routeAnchor)
            }
            if let currentReporter = rendererCandidates
                .sorted(by: stableWindowOrder)
                .first {
                return (currentReporter, .routeAnchor)
            }
        }

        if let preferredWindowIdentifier {
            return eligible.first {
                $0.stableIdentifier == preferredWindowIdentifier
            }.map { ($0, .routeAnchor) }
        }

        if let focused = eligible.first(where: \.isFocused) {
            return (focused, .focused)
        }
        if let main = eligible.first(where: \.isMain) {
            return (main, .main)
        }
        return eligible.max { lhs, rhs in
            let lhsArea = visibleArea(of: lhs.frame, on: displays)
            let rhsArea = visibleArea(of: rhs.frame, on: displays)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            if lhs.frontToBackIndex != rhs.frontToBackIndex {
                return lhs.frontToBackIndex > rhs.frontToBackIndex
            }
            return lhs.stableIdentifier > rhs.stableIdentifier
        }.map { ($0, .largestVisible) }
    }

    private static func stableWindowOrder(
        _ lhs: WindowCandidateSnapshot,
        _ rhs: WindowCandidateSnapshot
    ) -> Bool {
        lhs.stableIdentifier < rhs.stableIdentifier
    }

    static func resolveDisplay(
        for windowFrame: CGRect,
        displays: [DisplaySnapshot],
        committedDisplayUUID: UUID? = nil
    ) -> DisplaySnapshot? {
        let intersecting = displays.compactMap { display -> (DisplaySnapshot, CGFloat)? in
            let area = intersectionArea(windowFrame, display.frame)
            return area > 0 ? (display, area) : nil
        }
        guard let maximumArea = intersecting.map({ $0.1 }).max() else { return nil }
        let tied = intersecting
            .filter { $0.1 == maximumArea }
            .map { $0.0 }

        if let committedDisplayUUID,
           let committed = tied.first(where: { $0.id == committedDisplayUUID }) {
            return committed
        }

        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let containingCenter = tied.first(where: {
            center.x > $0.frame.minX
                && center.x < $0.frame.maxX
                && center.y > $0.frame.minY
                && center.y < $0.frame.maxY
        }) {
            return containingCenter
        }

        return tied.min { $0.id.uuidString < $1.id.uuidString }
    }

    static func visibleArea(of windowFrame: CGRect, on displays: [DisplaySnapshot]) -> CGFloat {
        displays.reduce(0) { $0 + intersectionArea(windowFrame, $1.frame) }
    }

    /// Pure Core Graphics surfaces are accepted as Safari fullscreen
    /// evidence only when they nearly cover one connected display. Ordinary
    /// browser windows must never enter the fullscreen fallback path merely
    /// because their AX counterpart disappeared for one observation.
    static func isLikelyFullscreenSurface(
        _ frame: CGRect,
        displays: [DisplaySnapshot],
        minimumDimensionRatio: CGFloat = 0.85,
        minimumAreaRatio: CGFloat = 0.80
    ) -> Bool {
        displays.contains { display in
            let intersection = frame.intersection(display.frame)
            guard !intersection.isNull, !intersection.isEmpty,
                  display.frame.width > 0, display.frame.height > 0 else {
                return false
            }
            let widthRatio = intersection.width / display.frame.width
            let heightRatio = intersection.height / display.frame.height
            let areaRatio = (intersection.width * intersection.height)
                / (display.frame.width * display.frame.height)
            return widthRatio >= minimumDimensionRatio
                && heightRatio >= minimumDimensionRatio
                && areaRatio >= minimumAreaRatio
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}

enum WindowRouteAffinityPolicy {
    static func pinsInitialWindow(for reason: ProcessWindowAssociationReason) -> Bool {
        reason != .sameProcess
    }

    static func beginsNewPlaybackSession(
        wasRunningOutput: Bool?,
        isRunningOutput: Bool,
        silenceTicks: Int = 0,
        requiredSilenceTicks: Int = 0
    ) -> Bool {
        wasRunningOutput == false
            && isRunningOutput
            && silenceTicks >= requiredSilenceTicks
    }

    /// Resolves the window currently reporting the sticky renderer PID.
    /// Safari can transiently expose the same renderer from more than one
    /// window. Keep the current reporter while it remains valid so dictionary
    /// iteration order cannot make the anchor oscillate between windows.
    static func reporterWindowIdentifier(
        rendererPID: pid_t,
        currentWindowIdentifier: String?,
        webViewProcessIDsByWindow: [String: pid_t]
    ) -> String? {
        let reporters = webViewProcessIDsByWindow
            .filter { $0.value == rendererPID }
            .map(\.key)
        if let currentWindowIdentifier,
           reporters.contains(currentWindowIdentifier) {
            return currentWindowIdentifier
        }
        return reporters.sorted().first
    }

    /// A WebContent audio source is itself Safari's renderer process, so it
    /// can identify its owning window before an anchor has been adopted.
    /// GPU media helpers are shared and cannot safely use their own PID.
    static func preferredRendererPID(
        anchoredRendererPID: pid_t?,
        sourcePID: pid_t,
        sourceBundleIdentifier: String?
    ) -> pid_t? {
        if let anchoredRendererPID { return anchoredRendererPID }
        guard sourceBundleIdentifier == "com.apple.WebKit.WebContent" else {
            return nil
        }
        return sourcePID
    }

    /// Precomputed evidence exists to remove the first-route delay for a
    /// directly routed application. It must never be borrowed by a helper
    /// process: the helper has a different playback identity and can appear
    /// in a different/fullscreen window moments after the cache was created.
    static func canReusePrecomputedEvidence(
        sourcePID: pid_t,
        associationReason: ProcessWindowAssociationReason,
        cachedSourcePID: pid_t,
        cachedAssociationReason: ProcessWindowAssociationReason,
        committedDisplayUUID: UUID?,
        preferredWindowIdentifier: String?,
        preferredRendererPID: pid_t?
    ) -> Bool {
        associationReason == .sameProcess
            && cachedAssociationReason == .sameProcess
            && sourcePID == cachedSourcePID
            && committedDisplayUUID == nil
            && preferredWindowIdentifier == nil
            && preferredRendererPID == nil
    }

}

enum DisplayTransitionPolicy {
    static let requiredAreaRatio: CGFloat = 0.60
    static let boundaryInset: CGFloat = 48

    static func shouldCommit(
        candidateDisplayUUID: UUID,
        committedDisplayUUID: UUID?,
        windowFrame: CGRect,
        displays: [DisplaySnapshot]
    ) -> Bool {
        guard let candidate = displays.first(where: { $0.id == candidateDisplayUUID }) else {
            return false
        }
        guard let committedDisplayUUID else { return true }
        guard candidateDisplayUUID != committedDisplayUUID else { return true }

        let totalVisibleArea = displays.reduce(CGFloat.zero) { partial, display in
            partial + intersectionArea(windowFrame, display.frame)
        }
        let candidateArea = intersectionArea(windowFrame, candidate.frame)
        if totalVisibleArea > 0,
           candidateArea / totalVisibleArea >= requiredAreaRatio {
            return true
        }

        let insetFrame = candidate.frame.insetBy(dx: boundaryInset, dy: boundaryInset)
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return !insetFrame.isEmpty && insetFrame.contains(center)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}
