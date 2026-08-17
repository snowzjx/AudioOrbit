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
    var hasMediaIndicator = false
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
    var mediaPlayingWindowIdentifiers: [String] = []
    var webViewProcessIDsByWindow: [String: pid_t] = [:]
}

enum WindowDisplayPolicy {
    static func selectWindow(
        from candidates: [WindowCandidateSnapshot],
        displays: [DisplaySnapshot],
        preferredWindowIdentifier: String? = nil
    ) -> (window: WindowCandidateSnapshot, source: WindowSelectionSource)? {
        let eligible = candidates.filter { candidate in
            guard candidate.isNormalWindow,
                  !candidate.isMinimized,
                  candidate.frame.width > 0,
                  candidate.frame.height > 0 else { return false }
            return visibleArea(of: candidate.frame, on: displays) > 0
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

    static func routeAnchor(
        existing: String?,
        selected: String?,
        associationReason: ProcessWindowAssociationReason
    ) -> String? {
        guard pinsInitialWindow(for: associationReason) else { return nil }
        return existing ?? selected
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

    /// Chooses the media window to follow. A single media window is the
    /// obvious target. With several, the freshest one wins: a torn-off tab
    /// lands in a freshly created window whose identifier age is small,
    /// while the source window's stale indicator keeps a large age. Old
    /// simultaneous playback stays ambiguous and is left alone.
    static func bestMediaTarget(
        _ mediaIdentifiers: Set<String>,
        ages: [String: Int],
        freshWindowAgeTicks: Int
    ) -> String? {
        if mediaIdentifiers.count == 1 {
            return mediaIdentifiers.first
        }
        guard mediaIdentifiers.count > 1 else { return nil }
        let minimumAge = mediaIdentifiers.map { ages[$0] ?? 0 }.min() ?? 0
        let freshest = mediaIdentifiers.filter { (ages[$0] ?? 0) == minimumAge }
        guard freshest.count == 1,
              minimumAge <= freshWindowAgeTicks else { return nil }
        return freshest.first
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