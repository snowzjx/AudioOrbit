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
    /// A moved AX window can lead the cached Core Graphics snapshot by one
    /// frame. Discard that snapshot on every AX event so surface matching
    /// never resolves a fresh AX frame against stale CG bounds.
    static func invalidateSurfaceScanCache() {
        surfaceScanCache.removeAllObjects()
    }

    /// Renderer ownership changes on tab moves and WebKit presentation
    /// churn. AX events invalidate this short-lived cache so the final event
    /// in a transition cannot leave a stale renderer mapping behind.
    static func invalidateWindowMetadataCache() {
        chromeWalkCache.removeAllObjects()
    }

    func evidence(
        for process: AudioProcessSnapshot,
        windowOwner: WindowOwnerSnapshot,
        associationReason: ProcessWindowAssociationReason,
        displays: [DisplaySnapshot],
        committedDisplayUUID: UUID? = nil,
        preferredWindowIdentifier: String? = nil,
        preferredRendererPID: pid_t? = nil,
        allowsUnverifiedFullscreenPresentation: Bool = false
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
        let windowFramePairs: [(Int, CGRect)] = windows.enumerated().compactMap {
            index, window -> (Int, CGRect)? in
            guard let position = pointAttribute(
                window,
                kAXPositionAttribute as CFString
            ), let size = sizeAttribute(
                window,
                kAXSizeAttribute as CFString
            ) else { return nil }
            return (index, CGRect(origin: position, size: size))
        }
        let windowFrames = [Int: CGRect](
            uniqueKeysWithValues: windowFramePairs
        )

        // Helper processes such as Safari's media service do not expose the
        // browser window that initiated playback. Match the owning app's AX
        // windows to public Core Graphics window numbers so the chosen window
        // keeps a stable identity when focus moves to another browser window.
        var surfaceCandidates = WindowRouteAffinityPolicy.pinsInitialWindow(
            for: associationReason
        ) ? visibleSurfaceCandidates(processPID: windowOwner.pid) : []

        let surfaceAssignments = assignSurfaceIdentifiers(
            to: windowFrames,
            surfaces: surfaceCandidates
        )
        let assignedSurfaceIdentifiers = Set(surfaceAssignments.values)
        let requiresOnScreenSurface = WindowRouteAffinityPolicy
            .pinsInitialWindow(for: associationReason)
            && !surfaceCandidates.isEmpty
        let accessibilityCandidates: [WindowCandidateSnapshot] = windows
            .enumerated().compactMap { index, window in
                guard let frame = windowFrames[index] else { return nil }
                let snapshot = candidate(
                    from: window,
                    processPID: windowOwner.pid,
                    index: index,
                    frame: frame,
                    isFocused: focusedWindow.map { CFEqual($0, window) } ?? false,
                    isMain: mainWindow.map { CFEqual($0, window) } ?? false,
                    matchedSurfaceIdentifier: surfaceAssignments[index]
                )
                // Safari may expose AX windows from inactive Spaces. For a
                // helper route, require a matching on-screen CG surface when
                // the surface scan is available; a true presentation missing
                // from AX is recovered by the constrained surface fallback.
                if requiresOnScreenSurface,
                   surfaceAssignments[index] == nil {
                    return nil
                }
                return snapshot
            }
        let candidates: [WindowCandidateSnapshot]
        if WindowDisplayPolicy.selectWindow(
            from: accessibilityCandidates,
            displays: displays,
            preferredWindowIdentifier: preferredWindowIdentifier,
            preferredRendererPID: preferredRendererPID,
            allowsUnverifiedFullscreenPresentation:
                allowsUnverifiedFullscreenPresentation
        ) == nil {
            // Safari's HTML video fullscreen surface is visible at Core
            // Graphics layer 0 but is not consistently exposed as an
            // AXStandardWindow. Only an unmatched surface that nearly covers
            // a display is safe evidence; ordinary Safari windows and their
            // already-matched surfaces must not take over another route.
            if surfaceCandidates.isEmpty {
                surfaceCandidates = visibleSurfaceCandidates(processPID: windowOwner.pid)
            }
            let fullscreenSurfaces = surfaceCandidates.filter {
                !assignedSurfaceIdentifiers.contains($0.stableIdentifier)
                    && WindowDisplayPolicy.isLikelyFullscreenSurface(
                        $0.frame,
                        displays: displays
                    )
            }
            candidates = accessibilityCandidates + fullscreenSurfaces
        } else {
            candidates = accessibilityCandidates
        }
        let eligibleCount = candidates.filter {
            WindowDisplayPolicy.selectWindow(from: [$0], displays: displays) != nil
        }.count

        // The audio follows the window the video plays in — not focus.
        // Priority: (1) the fullscreen presentation (AXFullScreen=true, the
        // WebKit fullscreen AXDialog); (2) the preferred window supplied by
        // the caller — the renderer-PID-tracked playing window; (3)
        // focus/largest as the fallback. Safari's per-window media marker
        // is deliberately NOT used: it follows focus, not playback.
        let selection = WindowDisplayPolicy.selectWindow(
            from: candidates,
            displays: displays,
            preferredWindowIdentifier: preferredWindowIdentifier,
            preferredRendererPID: preferredRendererPID,
            allowsUnverifiedFullscreenPresentation:
                allowsUnverifiedFullscreenPresentation
        )
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
                    candidates.map {
                        ($0.stableIdentifier, $0.frame)
                    },
                    uniquingKeysWith: { first, _ in first }
                ),
                focusedWindowIdentifier: candidates.first(where: \.isFocused)?
                    .stableIdentifier,
                webViewProcessIDsByWindow: Self.webViewProcessMap(
                    from: candidates.filter { !$0.isSurfaceOnly }
                ),
                surfaceOnlyWindowIdentifiers: candidates
                    .filter(\.isSurfaceOnly)
                    .map(\.stableIdentifier)
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
                candidates.map {
                    ($0.stableIdentifier, $0.frame)
                },
                uniquingKeysWith: { first, _ in first }
            ),
            focusedWindowIdentifier: candidates.first(where: \.isFocused)?
                .stableIdentifier,
            webViewProcessIDsByWindow: Self.webViewProcessMap(
                from: candidates.filter { !$0.isSurfaceOnly }
            ),
            surfaceOnlyWindowIdentifiers: candidates
                .filter(\.isSurfaceOnly)
                .map(\.stableIdentifier)
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

    /// The full-desktop CG window scan is expensive and shared across
    /// sources, so it is cached briefly (1 s) and reused for every PID.
    private final class SurfaceScanEntry {
        let windowInfo: [[String: Any]]
        let timestamp: ContinuousClock.Instant

        init(windowInfo: [[String: Any]], timestamp: ContinuousClock.Instant) {
            self.windowInfo = windowInfo
            self.timestamp = timestamp
        }
    }

    private static let surfaceScanCache = NSCache<NSString, SurfaceScanEntry>()
    private static let surfaceScanTTL: Duration = .seconds(1)
    private static let surfaceScanCacheKey = "scan" as NSString

    private func visibleSurfaceCandidates(processPID: pid_t) -> [WindowCandidateSnapshot] {
        let now = ContinuousClock.now
        let windowInfo: [[String: Any]]
        if let entry = Self.surfaceScanCache.object(forKey: Self.surfaceScanCacheKey),
           now - entry.timestamp < Self.surfaceScanTTL {
            windowInfo = entry.windowInfo
        } else {
            let options: CGWindowListOption = [
                .optionOnScreenOnly, .excludeDesktopElements,
            ]
            windowInfo = CGWindowListCopyWindowInfo(
                options,
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
            Self.surfaceScanCache.setObject(
                SurfaceScanEntry(windowInfo: windowInfo, timestamp: now),
                forKey: Self.surfaceScanCacheKey
            )
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
                frontToBackIndex: index,
                isSurfaceOnly: true
            )
        }
    }

    private func candidate(
        from window: AXUIElement,
        processPID: pid_t,
        index: Int,
        frame: CGRect,
        isFocused: Bool,
        isMain: Bool,
        matchedSurfaceIdentifier: String?
    ) -> WindowCandidateSnapshot? {
        let role = stringAttribute(window, kAXRoleAttribute as CFString)
        let subrole = stringAttribute(window, kAXSubroleAttribute as CFString)
        let isNormalWindow = role == (kAXWindowRole as String)
            && (subrole == nil || subrole == (kAXStandardWindowSubrole as String))
        // Safari's AX UUID survives ordinary moves; the CG window number can
        // be replaced during compositor transitions. Prefer the normalized
        // AX identity and use the matched surface only for windows that do
        // not expose a stable AX identifier.
        let identifier = Self.stableAXIdentifier(
                stringAttribute(window, kAXIdentifierAttribute as CFString)
            )
            ?? matchedSurfaceIdentifier
            ?? "ax:\(processPID):\(index)"
        // The renderer-PID walk descends the window's AX children with
        // several XPC attribute reads per node. Cache it briefly per window;
        // AX events invalidate the cache on tab/window structural changes.
        let chrome = cachedChromeWalk(
            processPID: processPID,
            identifier: identifier,
            window: window
        )
        return WindowCandidateSnapshot(
            stableIdentifier: identifier,
            frame: frame,
            isFocused: isFocused,
            isMain: isMain,
            isMinimized: boolAttribute(window, kAXMinimizedAttribute as CFString) ?? false,
            isNormalWindow: isNormalWindow,
            frontToBackIndex: index,
            isFullscreen: boolAttribute(window, "AXFullScreen" as CFString)
                ?? false,
            webViewProcessID: chrome.webViewProcessID
        )
    }

    private struct ChromeWalkResult {
        let webViewProcessID: pid_t?
    }

    private final class ChromeWalkCacheEntry {
        let result: ChromeWalkResult
        let timestamp: ContinuousClock.Instant

        init(result: ChromeWalkResult, timestamp: ContinuousClock.Instant) {
            self.result = result
            self.timestamp = timestamp
        }
    }

    /// Chrome walks are cached per stable window identifier for a short TTL.
    /// NSCache is thread-safe; the evidence path runs on cooperative queues.
    private static let chromeWalkCache = NSCache<NSString, ChromeWalkCacheEntry>()
    private static let chromeWalkTTL: Duration = .seconds(2)

    private func cachedChromeWalk(
        processPID: pid_t,
        identifier: String,
        window: AXUIElement
    ) -> ChromeWalkResult {
        let key = "\(processPID):\(identifier)" as NSString
        let now = ContinuousClock.now
        if let entry = Self.chromeWalkCache.object(forKey: key),
           now - entry.timestamp < Self.chromeWalkTTL {
            return entry.result
        }
        let result = ChromeWalkResult(
            webViewProcessID: browserViewProcessID(in: window, depth: 0)
        )
        Self.chromeWalkCache.setObject(
            ChromeWalkCacheEntry(result: result, timestamp: now),
            forKey: key
        )
        return result
    }

    /// Safari's window identifier embeds volatile page state before a
    /// stable UUID (`SafariWindow?IsSecure=true&UUID=…`). Navigating the
    /// active tab between http and https flips the IsSecure flag, which
    /// used to change the window's identity and desynchronize the anchor.
    /// Keep only the UUID when one is present.
    static func stableAXIdentifier(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let range = raw.range(of: "UUID=") else { return raw }
        let uuid = raw[range.upperBound...].prefix { $0 != "&" }
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
        to windowFrames: [Int: CGRect],
        surfaces: [WindowCandidateSnapshot]
    ) -> [Int: String] {
        var claimedIdentifiers = Set<String>()
        var assignments: [Int: String] = [:]
        for (index, frame) in windowFrames.sorted(by: { $0.key < $1.key }) {
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
