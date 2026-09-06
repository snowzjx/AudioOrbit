import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
import Foundation

struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var size = UInt32(MemoryLayout<T>.size)
    let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    storage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
    defer { storage.deallocate() }
    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage)
    guard status == noErr else { throw DriverError("Core Audio property failed: \(status)") }
    return storage.load(as: T.self)
}

func uid(_ id: AudioObjectID) throws -> String {
    try property(id, kAudioDevicePropertyDeviceUID, "" as CFString) as String
}

func ids(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(1, &address, 0, nil, &size) == noErr else { throw DriverError("Cannot enumerate Core Audio objects") }
    var values = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    guard AudioObjectGetPropertyData(1, &address, 0, nil, &size, &values) == noErr else { throw DriverError("Cannot read Core Audio objects") }
    return values
}

func inventory() throws -> [String: Any] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else { throw DriverError("Cannot list displays") }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else { throw DriverError("Cannot read displays") }
    let screens: [[String: Any]] = displays.map { id in
        let frame = CGDisplayBounds(id)
        let uuid = CGDisplayCreateUUIDFromDisplayID(id)!.takeRetainedValue()
        return ["uuid": CFUUIDCreateString(nil, uuid)! as String, "frame": [frame.minX, frame.minY, frame.width, frame.height],
                "mirrored": CGDisplayIsInMirrorSet(id) != 0, "main": CGDisplayIsMain(id) != 0]
    }
    var devices: [[String: Any]] = []
    for id in try ids(kAudioHardwarePropertyDevices) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { continue }
        devices.append(["uid": try uid(id), "name": try property(id, kAudioObjectPropertyName, "" as CFString) as String,
                        "alive": try property(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) != 0])
    }
    let playing: [[String: Any]] = try ids(kAudioHardwarePropertyProcessObjectList).compactMap { id in
        guard (try? property(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) == 1 else { return nil }
        return ["pid": try property(id, kAudioProcessPropertyPID, Int32(0))]
    }
    let apps = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    return ["displays": screens, "outputs": devices, "playing": playing,
            "defaultUID": try uid(property(1, kAudioHardwarePropertyDefaultOutputDevice, UInt32(0))),
            "accessibility": AXIsProcessTrusted(), "postEvents": CGPreflightPostEventAccess(),
            "driverBundle": Bundle.main.bundleURL.path,
            "sessionReady": session[kCGSessionOnConsoleKey as String] as? Bool == true && session["CGSSessionScreenIsLocked"] as? Bool != true,
            "apps": apps, "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "safariVersion": Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"]
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func window(_ token: String) throws -> AXUIElement {
    guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first else { throw DriverError("Safari is not running") }
    let app = AXUIElementCreateApplication(safari.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 2)
    let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    // Include the delimiter: the silent window's token extends the playing
    // token, so substring matching just the UUID would select both windows.
    let marker = "AudioOrbit E2E \(token) END"
    let matches = windows.filter { (attribute($0, kAXTitleAttribute) as? String ?? "").contains(marker) }
    guard matches.count == 1 else { throw DriverError("Expected one fixture window, found \(matches.count)") }
    return matches[0]
}

func frame(_ element: AXUIElement) throws -> CGRect {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { throw DriverError("Window geometry unavailable") }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { throw DriverError("Invalid AX geometry") }
    return CGRect(origin: point, size: size)
}

func setValue(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) throws {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success, settable.boolValue,
          AXUIElementSetAttributeValue(element, name as CFString, value) == .success else { throw DriverError("Cannot set \(name)") }
}

func mouse(_ type: CGEventType, _ point: CGPoint) throws {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { throw DriverError("Cannot create mouse event") }
    event.post(tap: .cghidEventTap)
    // Let WindowServer consume events before this short-lived app exits.
    Thread.sleep(forTimeInterval: 0.04)
}

func button(_ root: AXUIElement, _ label: String) -> AXUIElement? {
    var queue = [root]
    var visited = 0
    while !queue.isEmpty && visited < 4000 {
        let element = queue.removeFirst()
        visited += 1
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { attribute(element, $0) as? String }
        if role == kAXButtonRole && names.contains(label) { return element }
        queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    return nil
}

func toolbarDragPoint(_ window: AXUIElement, verifyHit: Bool = true) throws -> CGPoint {
    let bounds = try frame(window)
    var pid: pid_t = 0
    guard AXUIElementGetPid(window, &pid) == .success else { throw DriverError("Cannot identify Safari window owner") }
    let application = AXUIElementCreateApplication(pid)
    var hitDiagnostics: [String] = []
    let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
    guard let toolbar = children.first(where: { (attribute($0, kAXRoleAttribute) as? String) == kAXToolbarRole }) else {
        throw DriverError("Safari toolbar unavailable; cannot choose a safe drag point")
    }
    let bar = try frame(toolbar)
    // Compact Safari puts its address field at the old fixed title-bar point.
    // Choose empty toolbar space from live control bounds, then verify the hit.
    let roles: Set<String> = [kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole,
                              kAXTextFieldRole, kAXRadioButtonRole, kAXCheckBoxRole]
    var queue = attribute(toolbar, kAXChildrenAttribute) as? [AXUIElement] ?? []
    var controls: [CGRect] = []
    var visited = 0
    while !queue.isEmpty && visited < 1000 {
        let item = queue.removeFirst()
        visited += 1
        if roles.contains(attribute(item, kAXRoleAttribute) as? String ?? ""), let rect = try? frame(item) {
            controls.append(rect.insetBy(dx: -6, dy: -4))
        }
        queue.append(contentsOf: attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    let left = max(bounds.minX + 90, bar.minX + 8)
    let right = min(bounds.maxX - 16, bar.maxX - 8)
    for y in [bar.midY, bar.maxY - 6, bar.minY + 6] {
        guard y > bounds.minY + 4 && y < bounds.maxY else { continue }
        var gaps: [(Double, Double)] = [(left, right)]
        for rect in controls where y >= rect.minY && y <= rect.maxY {
            gaps = gaps.flatMap { a, b -> [(Double, Double)] in
                if rect.maxX <= a || rect.minX >= b { return [(a, b)] }
                return [(a, min(b, rect.minX)), (max(a, rect.maxX), b)].filter { $0.1 > $0.0 }
            }
        }
        for (a, b) in gaps.sorted(by: { $0.1 - $0.0 > $1.1 - $1.0 }) where b - a >= 18 {
            let point = CGPoint(x: (a + b) / 2, y: y)
            if !verifyHit { return point }
            var hit: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit)
            hitDiagnostics.append("\(status.rawValue):\(hit.flatMap { attribute($0, kAXRoleAttribute) as? String } ?? "none")")
            if status == .success, let hit {
                if CFEqual(hit, toolbar) || CFEqual(hit, window) { return point }
                if (attribute(hit, kAXRoleAttribute) as? String) == kAXGroupRole {
                    var ancestor: AXUIElement? = hit
                    for _ in 0..<12 {
                        guard let current = ancestor else { break }
                        if CFEqual(current, toolbar) { return point }
                        ancestor = attribute(current, kAXParentAttribute).map { $0 as! AXUIElement }
                    }
                }
            }
        }
    }
    throw DriverError("No empty Safari toolbar area is available for dragging: \(hitDiagnostics.joined(separator: ", ")); toolbar=\(bar); controls=\(controls)")
}

func appleScript(_ script: String) throws -> NSAppleEventDescriptor {
    var error: NSDictionary?
    guard let source = NSAppleScript(source: script) else { throw DriverError("Cannot construct Safari command") }
    let result = source.executeAndReturnError(&error)
    if let error { throw DriverError("Safari Automation permission or command failed: \(error)") }
    return result
}

@main
struct Desktop {
    static func main() {
        var completionURL: URL?
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            if args.first == "--managed-directory" {
                guard args.count >= 4, let parent = Int32(args[2]), parent > 1 else {
                    throw DriverError("Invalid managed launch")
                }
                let directory = URL(fileURLWithPath: args[1])
                completionURL = directory.appendingPathComponent("completed")
                try Data(String(getpid()).utf8).write(to: directory.appendingPathComponent("app.pid"), options: .atomic)
                // Independent of the main thread: even a blocked Apple Event
                // must stop when its runner cancels or dies.
                let releasesMouse = args.contains("drag")
                DispatchQueue.global().async {
                    while true {
                        if kill(parent, 0) != 0 || FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop.request").path) {
                            if releasesMouse { try? mouse(.leftMouseUp, CGEvent(source: nil)?.location ?? .zero) }
                            exit(3)
                        }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                }
                args.removeFirst(3)
            }
            guard let command = args.first else { throw DriverError("Missing driver command") }
            switch command {
            case "inventory": try emit(inventory())
            case "inspect-toolbar":
                guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first,
                      let focused = attribute(AXUIElementCreateApplication(safari.processIdentifier), kAXFocusedWindowAttribute) else {
                    throw DriverError("No focused Safari window")
                }
                let point = try toolbarDragPoint(focused as! AXUIElement, verifyHit: false)
                try emit(["dragPoint": [point.x, point.y]])
            case "generate":
                guard args.count == 2 else { throw DriverError("generate requires output path") }
                try generateFixture(URL(fileURLWithPath: args[1]))
                try emit(["generated": true])
            case "validate-fixture":
                guard args.count == 2 else { throw DriverError("validate-fixture requires a path") }
                try emit(validateFixture(URL(fileURLWithPath: args[1])))
            case "release-mouse":
                try mouse(.leftMouseUp, CGEvent(source: nil)?.location ?? .zero)
                try emit(["released": true])
            case "default-watch":
                let path = args[1]
                var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
                let initial = try uid(property(1, kAudioHardwarePropertyDefaultOutputDevice, UInt32(0)))
                // A latched event catches even an A→B→A change between polls.
                guard AudioObjectAddPropertyListenerBlock(1, &address, .main, { _, _ in
                    try? Data("changed".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
                }) == noErr else { throw DriverError("Cannot observe the default output") }
                try emit(["defaultUID": initial])
                RunLoop.main.run()
            case "open":
                guard args.count == 2, args[1].hasPrefix("http://127.0.0.1:"), !args[1].contains("\""), !args[1].contains("\\"), !args[1].contains("\n") else { throw DriverError("Expected a local fixture URL") }
                let result = try appleScript("tell application \"Safari\"\nmake new document with properties {URL:\"\(args[1])\"}\nactivate\nreturn id of front window\nend tell")
                try emit(["windowID": result.int32Value])
            case "close":
                guard args.count == 3, let id = Int(args[1]), args[2].allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw DriverError("Invalid owned window") }
                // Check the fixture token in the URL as well as the recorded ID.
                let result = try appleScript("tell application \"Safari\"\nif exists window id \(id) then\nif (count of tabs of window id \(id)) is 1 and (URL of current tab of window id \(id)) contains \"\(args[2])\" then\nclose window id \(id)\nelse\nreturn false\nend if\nend if\nreturn true\nend tell")
                try emit(["closed": result.booleanValue])
            case "frame", "place", "drag", "click", "focus":
                guard args.count >= 2, AXIsProcessTrusted() else { throw DriverError("Grant Accessibility to the E2E driver before running") }
                let element = try window(args[1])
                if command == "focus" || command == "click" || command == "drag" {
                    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first?.activate(options: [])
                    guard AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success else { throw DriverError("Cannot raise fixture window") }
                    Thread.sleep(forTimeInterval: 0.15)
                }
                if command == "focus" {
                    guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first,
                          let focused = attribute(AXUIElementCreateApplication(safari.processIdentifier), kAXFocusedWindowAttribute),
                          CFEqual(focused, element) else { throw DriverError("Safari did not focus the silent fixture window") }
                }
                if command == "place" {
                    guard args.count == 6, let x = Double(args[2]), let y = Double(args[3]), let w = Double(args[4]), let h = Double(args[5]) else { throw DriverError("Invalid geometry") }
                    var size = CGSize(width: w, height: h)
                    var point = CGPoint(x: x, y: y)
                    try setValue(element, kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
                    try setValue(element, kAXPositionAttribute, AXValueCreate(.cgPoint, &point)!)
                } else if command == "drag" {
                    guard args.count == 4, let x = Double(args[2]), let y = Double(args[3]), CGPreflightPostEventAccess() else { throw DriverError("Drag needs destination and event-posting permission") }
                    let bounds = try frame(element)
                    let start = try toolbarDragPoint(element)
                    let delta = CGPoint(x: x - bounds.minX, y: y - bounds.minY)
                    defer { try? mouse(.leftMouseUp, CGEvent(source: nil)?.location ?? start) }
                    try mouse(.mouseMoved, start)
                    try mouse(.leftMouseDown, start)
                    for step in 1...40 {
                        Thread.sleep(forTimeInterval: 0.02)
                        let fraction = Double(step) / 40
                        try mouse(.leftMouseDragged, CGPoint(x: start.x + delta.x * fraction, y: start.y + delta.y * fraction))
                    }
                } else if command == "click" {
                    guard args.count == 3, let target = button(element, args[2]) else { throw DriverError("Fixture button unavailable") }
                    let bounds = try frame(target)
                    let point = CGPoint(x: bounds.midX, y: bounds.midY)
                    try mouse(.mouseMoved, point)
                    try mouse(.leftMouseDown, point)
                    try mouse(.leftMouseUp, point)
                }
                let bounds = try frame(element)
                try emit(["frame": [bounds.minX, bounds.minY, bounds.width, bounds.height]])
            default: throw DriverError("Unknown driver command")
            }
            if let completionURL {
                try Data("success".utf8).write(to: completionURL, options: .atomic)
            }
            exit(0)
        } catch {
            try? emit(["error": String(describing: error)])
            exit(2)
        }
    }
}
