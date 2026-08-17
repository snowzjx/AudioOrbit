import ApplicationServices
import Foundation

enum AccessibilityPermission {
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestFromUserAction() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

struct AccessibilityWindowDiscovery {
    func evidence(
        for process: AudioProcessSnapshot,
        windowOwner: WindowOwnerSnapshot,
        associationReason: ProcessWindowAssociationReason,
        displays: [DisplaySnapshot],
        committedDisplayUUID: UUID? = nil,
        preferredWindowIdentifier: String? = nil
    ) -> WindowDisplayEvidence {
        let application = AXUIElementCreateApplication(windowOwner.pid)
        let focusedWindow = elementAttribute(application, kAXFocusedWindowAttribute as CFString)
        let mainWindow = elementAttribute(application, kAXMainWindowAttribute as CFString)

        guard AccessibilityPermission.isGranted else {
            return WindowDisplayEvidence(
                sourcePID: process.pid,
                sourceName: windowOwner.name,
                audioProcessName: process.name,
                windowOwnerPID: windowOwner.pid,
                associationReason: associationReason,
                eligibleWindowCount: 0,
                selectedWindowIdentifier: nil,
                selectionSource: nil,
                windowFrame: nil,
                displayUUID: nil,
                displayName: nil,
                issue: "Accessibility permission is required to inspect application windows.",
                candidateWindowIdentifiers: [],
                focusedWindowIdentifier: nil
            )
        }
        let windows = elementArrayAttribute(
            application,
            kAXWindowsAttribute as CFString
        ) ?? []

        // Helper processes such as Safari's media service do not expose the
        // browser window that initiated playback. Match the owning app's AX
        // windows to public Core Graphics window numbers so the chosen window
        // keeps a stable identity when focus moves to another browser window.
        var surfaceCandidates = WindowRouteAffinityPolicy.pinsInitialWindow(
            for: associationReason
        ) ? visibleSurfaceCandidates(processPID: windowOwner.pid) : []

        let surfaceAssignments = assignSurfaceIdentifiers(
            to: windows,
            surfaces: surfaceCandidates
        )
        let accessibilityCandidates = windows.enumerated().compactMap { index, window in
            candidate(
                from: window,
                processPID: windowOwner.pid,
                index: index,
                isFocused: focusedWindow.map { CFEqual($0, window) } ?? false,
                isMain: mainWindow.map { CFEqual($0, window) } ?? false,
                matchedSurfaceIdentifier: surfaceAssignments[index]
            )
        }
        let candidates: [WindowCandidateSnapshot]
        if WindowDisplayPolicy.selectWindow(
            from: accessibilityCandidates,
            displays: displays,
            preferredWindowIdentifier: preferredWindowIdentifier
        ) == nil {
            // Safari's HTML video fullscreen surface is visible at Core
            // Graphics layer 0 but is not consistently exposed as an
            // AXStandardWindow. Use only same-PID, on-screen application
            // surfaces and let the existing largest-visible policy select it.
            if surfaceCandidates.isEmpty {
                surfaceCandidates = visibleSurfaceCandidates(processPID: windowOwner.pid)
            }
            candidates = accessibilityCandidates + surfaceCandidates
        } else {
            candidates = accessibilityCandidates
        }
        let eligibleCount = candidates.filter {
            WindowDisplayPolicy.selectWindow(from: [$0], displays: displays) != nil
        }.count

        var selection = WindowDisplayPolicy.selectWindow(
            from: candidates,
            displays: displays,
            preferredWindowIdentifier: preferredWindowIdentifier
        )
        // Safari marks the playing tab's window with a per-window audio
        // indicator in its chrome. When the anchor did not match, prefer
        // that window over focus/largest-visible so a video that starts in
        // a background window still routes to the right display. Chrome
        // controls replicated across every window of an app never trigger
        // this, because the rule requires exactly one matching window.
        if selection?.source != .routeAnchor {
            let mediaCandidates = candidates.filter(\.hasMediaIndicator)
            if mediaCandidates.count == 1,
               let mediaWindow = mediaCandidates.first,
               mediaWindow.stableIdentifier != selection?.window.stableIdentifier,
               WindowDisplayPolicy.selectWindow(
                   from: [mediaWindow],
                   displays: displays
               ) != nil {
                selection = (mediaWindow, .mediaIndicator)
            }
        }
        guard let selection else {
            return WindowDisplayEvidence(
                sourcePID: process.pid,
                sourceName: windowOwner.name,
                audioProcessName: process.name,
                windowOwnerPID: windowOwner.pid,
                associationReason: associationReason,
                eligibleWindowCount: eligibleCount,
                selectedWindowIdentifier: nil,
                selectionSource: nil,
                windowFrame: nil,
                displayUUID: nil,
                displayName: nil,
                issue: "No visible application window intersects a connected display.",
                candidateWindowIdentifiers: candidates.map(\.stableIdentifier),
                candidateWindowFrames: Dictionary(
                    uniqueKeysWithValues: candidates.map {
                        ($0.stableIdentifier, $0.frame)
                    }
                ),
                focusedWindowIdentifier: candidates.first(where: \.isFocused)?
                    .stableIdentifier,
                mediaPlayingWindowIdentifiers: candidates.filter(\.hasMediaIndicator)
                    .map(\.stableIdentifier),
                webViewProcessIDsByWindow: Self.webViewProcessMap(from: candidates)
            )
        }

        let display = WindowDisplayPolicy.resolveDisplay(
            for: selection.window.frame,
            displays: displays,
            committedDisplayUUID: committedDisplayUUID
        )
        return WindowDisplayEvidence(
            sourcePID: process.pid,
            sourceName: windowOwner.name,
            audioProcessName: process.name,
            windowOwnerPID: windowOwner.pid,
            associationReason: associationReason,
            eligibleWindowCount: eligibleCount,
            selectedWindowIdentifier: selection.window.stableIdentifier,
            selectionSource: selection.source,
            windowFrame: selection.window.frame,
            displayUUID: display?.id,
            displayName: display?.name,
            issue: display == nil ? "The selected window does not intersect a connected display." : nil,
            candidateWindowIdentifiers: candidates.map(\.stableIdentifier),
            candidateWindowFrames: Dictionary(
                uniqueKeysWithValues: candidates.map {
                    ($0.stableIdentifier, $0.frame)
                }
            ),
            focusedWindowIdentifier: candidates.first(where: \.isFocused)?
                .stableIdentifier,
            mediaPlayingWindowIdentifiers: candidates.filter(\.hasMediaIndicator)
                .map(\.stableIdentifier),
            webViewProcessIDsByWindow: Self.webViewProcessMap(from: candidates)
        )
    }

    private static func webViewProcessMap(
        from candidates: [WindowCandidateSnapshot]
    ) -> [String: pid_t] {
        Dictionary(
            candidates.compactMap { candidate in
                candidate.webViewProcessID.map {
                    (candidate.stableIdentifier, $0)
                }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func visibleSurfaceCandidates(processPID: pid_t) -> [WindowCandidateSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowInfo.enumerated().compactMap { index, info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processPID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else {
                return nil
            }
            let frame = CGRect(x: x, y: y, width: width, height: height)
            guard
                  frame.width > 0,
                  frame.height > 0 else {
                return nil
            }
            return WindowCandidateSnapshot(
                stableIdentifier: "cg:\(number.uint32Value)",
                frame: frame,
                isFocused: false,
                isMain: false,
                isMinimized: false,
                isNormalWindow: true,
                frontToBackIndex: index
            )
        }
    }

    private func candidate(
        from window: AXUIElement,
        processPID: pid_t,
        index: Int,
        isFocused: Bool,
        isMain: Bool,
        matchedSurfaceIdentifier: String?
    ) -> WindowCandidateSnapshot? {
        guard let position = pointAttribute(window, kAXPositionAttribute as CFString),
              let size = sizeAttribute(window, kAXSizeAttribute as CFString) else { return nil }
        let role = stringAttribute(window, kAXRoleAttribute as CFString)
        let subrole = stringAttribute(window, kAXSubroleAttribute as CFString)
        let isNormalWindow = role == (kAXWindowRole as String)
            && (subrole == nil || subrole == (kAXStandardWindowSubrole as String))
        let frame = CGRect(origin: position, size: size)
        let identifier = matchedSurfaceIdentifier
            ?? Self.stableAXIdentifier(
                stringAttribute(window, kAXIdentifierAttribute as CFString)
            )
            ?? "ax:\(processPID):\(index)"
        return WindowCandidateSnapshot(
            stableIdentifier: identifier,
            frame: frame,
            isFocused: isFocused,
            isMain: isMain,
            isMinimized: boolAttribute(window, kAXMinimizedAttribute as CFString) ?? false,
            isNormalWindow: isNormalWindow,
            frontToBackIndex: index,
            hasMediaIndicator: mediaIndicatorFound(in: window, depth: 0),
            webViewProcessID: browserViewProcessID(in: window, depth: 0)
        )
    }

    /// Safari's window identifier embeds volatile page state before a
    /// stable UUID (`SafariWindow?IsSecure=true&UUID=…`). Navigating the
    /// active tab between http and https flips the IsSecure flag, which
    /// used to change the window's identity and desynchronize the anchor.
    /// Keep only the UUID when one is present.
    static func stableAXIdentifier(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let range = raw.range(of: "UUID=") else { return raw }
        let uuid = raw[range.upperBound...]
        return uuid.isEmpty ? nil : String(uuid)
    }

    /// Assigns each AX window a distinct Core Graphics surface by largest
    /// overlap instead of edge tolerance. AX frames and CG bounds
    /// legitimately differ by the title bar, shadow and coordinate
    /// rounding, and an exact-edge match made Safari windows fall back to
    /// their unstable AX identifier, which changed between ticks and made
    /// the anchor oscillate. Windows are processed in AX (front-to-back)
    /// order and a claimed surface is never reused, so two stacked windows
    /// cannot collapse onto the same window number.
    private func assignSurfaceIdentifiers(
        to windows: [AXUIElement],
        surfaces: [WindowCandidateSnapshot]
    ) -> [Int: String] {
        var claimedIdentifiers = Set<String>()
        var assignments: [Int: String] = [:]
        for (index, window) in windows.enumerated() {
            guard let position = pointAttribute(window, kAXPositionAttribute as CFString),
                  let size = sizeAttribute(window, kAXSizeAttribute as CFString) else {
                continue
            }
            let frame = CGRect(origin: position, size: size)
            let frameArea = frame.width * frame.height
            var best: (identifier: String, area: CGFloat)?
            for surface in surfaces
                where !claimedIdentifiers.contains(surface.stableIdentifier) {
                let intersection = frame.intersection(surface.frame)
                guard !intersection.isNull, !intersection.isEmpty else { continue }
                let area = intersection.width * intersection.height
                let surfaceArea = surface.frame.width * surface.frame.height
                let smallerArea = min(frameArea, surfaceArea)
                guard smallerArea > 0, area / smallerArea >= 0.5 else { continue }
                if area > (best?.area ?? 0) {
                    best = (surface.stableIdentifier, area)
                }
            }
            if let best {
                claimedIdentifiers.insert(best.identifier)
                assignments[index] = best.identifier
            }
        }
        return assignments
    }
    /// Reads the renderer pid of the window's active tab from Safari's
    /// BrowserView identifier (`BrowserView?IsPageLoaded=…&WebViewProcessID=NNN`).
    /// A torn-off tab keeps its renderer process, so the window that reports
    /// the anchored pid after a move is the playback window — this tracks
    /// the media's actual host, not the chrome window identity.
    private func browserViewProcessID(in element: AXUIElement, depth: Int) -> pid_t? {
        guard depth <= 4 else { return nil }
        if let identifier = stringAttribute(element, kAXIdentifierAttribute as CFString),
           identifier.hasPrefix("BrowserView?"),
           let range = identifier.range(of: "WebViewProcessID=") {
            let digits = identifier[range.upperBound...].prefix(while: \.isNumber)
            return digits.isEmpty ? nil : Int(digits).map(pid_t.init)
        }
        guard let children = elementArrayAttribute(
            element,
            kAXChildrenAttribute as CFString
        ) else {
            return nil
        }
        for child in children {
            if let pid = browserViewProcessID(in: child, depth: depth + 1) {
                return pid
            }
        }
        return nil
    }

    /// Detects whether a window's chrome exposes a media-playing indicator,
    /// such as the mute button Safari places in a tab while that tab plays
    /// audio. Only window chrome metadata is read — never titles and never
    /// web content, which the walk explicitly avoids descending into.
    private static let mediaIndicatorMarkers = [
        "mute", "unmute", "speaker", "playing", "audio",
        "静音", "播放", "声音",
    ]

    private static let mediaMetadataAttributes: [String] = [
        kAXRoleDescriptionAttribute,
        kAXSubroleAttribute,
        kAXIdentifierAttribute,
        kAXDescriptionAttribute,
        kAXHelpAttribute,
    ]

    private func matchesMediaMarker(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return Self.mediaIndicatorMarkers.contains(where: lowercased.contains)
    }
    
    private func mediaIndicatorFound(in element: AXUIElement, depth: Int) -> Bool {
        guard depth <= 6 else { return false }
        for name in Self.mediaMetadataAttributes {
            guard let value = stringAttribute(element, name as CFString) else {
                continue
            }
            if matchesMediaMarker(value) {
                return true
            }
        }
        let role = (stringAttribute(element, kAXRoleAttribute as CFString) ?? "")
            .lowercased()
        if role.contains("webarea") || role.contains("scrollarea")
            || role.contains("textarea") {
            return false
        }
        guard let children = elementArrayAttribute(
            element,
            kAXChildrenAttribute as CFString
        ) else {
            return false
        }
        for child in children where mediaIndicatorFound(in: child, depth: depth + 1) {
            return true
        }
        return false
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }

    private func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func elementArrayAttribute(_ element: AXUIElement, _ name: CFString) -> [AXUIElement]? {
        guard let values = attribute(element, name) as? [Any] else { return nil }
        return values.compactMap { value in
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(cfValue, to: AXUIElement.self)
        }
    }

    private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ name: CFString) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    private func pointAttribute(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ name: CFString) -> CGSize? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return size
    }
}