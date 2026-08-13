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
        committedDisplayUUID: UUID? = nil
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
                issue: "Accessibility permission is required to inspect application windows."
            )
        }
        let windows = elementArrayAttribute(
            application,
            kAXWindowsAttribute as CFString
        ) ?? []

        let accessibilityCandidates = windows.enumerated().compactMap { index, window in
            candidate(
                from: window,
                processPID: windowOwner.pid,
                index: index,
                isFocused: focusedWindow.map { CFEqual($0, window) } ?? false,
                isMain: mainWindow.map { CFEqual($0, window) } ?? false
            )
        }
        let candidates: [WindowCandidateSnapshot]
        if WindowDisplayPolicy.selectWindow(
            from: accessibilityCandidates,
            displays: displays
        ) == nil {
            // Safari's HTML video fullscreen surface is visible at Core
            // Graphics layer 0 but is not consistently exposed as an
            // AXStandardWindow. Use only same-PID, on-screen application
            // surfaces and let the existing largest-visible policy select it.
            candidates = accessibilityCandidates + visibleSurfaceCandidates(
                processPID: windowOwner.pid
            )
        } else {
            candidates = accessibilityCandidates
        }
        let eligibleCount = candidates.filter {
            WindowDisplayPolicy.selectWindow(from: [$0], displays: displays) != nil
        }.count

        guard let selection = WindowDisplayPolicy.selectWindow(
            from: candidates,
            displays: displays
        ) else {
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
                issue: "No visible application window intersects a connected display."
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
            issue: display == nil ? "The selected window does not intersect a connected display." : nil
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
        isMain: Bool
    ) -> WindowCandidateSnapshot? {
        guard let position = pointAttribute(window, kAXPositionAttribute as CFString),
              let size = sizeAttribute(window, kAXSizeAttribute as CFString) else { return nil }
        let role = stringAttribute(window, kAXRoleAttribute as CFString)
        let subrole = stringAttribute(window, kAXSubroleAttribute as CFString)
        let isNormalWindow = role == (kAXWindowRole as String)
            && (subrole == nil || subrole == (kAXStandardWindowSubrole as String))
        let identifier = stringAttribute(window, kAXIdentifierAttribute as CFString)
            ?? "\(processPID):\(index)"
        return WindowCandidateSnapshot(
            stableIdentifier: identifier,
            frame: CGRect(origin: position, size: size),
            isFocused: isFocused,
            isMain: isMain,
            isMinimized: boolAttribute(window, kAXMinimizedAttribute as CFString) ?? false,
            isNormalWindow: isNormalWindow,
            frontToBackIndex: index
        )
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
