import AppKit
import ColorSync
import CoreGraphics
import Foundation

struct DisplayDiscovery {
    func snapshots() throws -> [DisplaySnapshot] {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success else {
            throw DisplayDiscoveryError.unableToEnumerate
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            throw DisplayDiscoveryError.unableToEnumerate
        }

        var screensByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            screensByDisplayID[CGDirectDisplayID(number.uint32Value)] = screen
        }

        return displayIDs.prefix(Int(displayCount)).compactMap { displayID -> DisplaySnapshot? in
            guard CGDisplayIsActive(displayID) != 0 else { return nil }
            guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
                return nil
            }
            let cfUUID = unmanagedUUID.takeRetainedValue()
            guard let uuidString = CFUUIDCreateString(nil, cfUUID) as String?,
                  let uuid = UUID(uuidString: uuidString) else { return nil }
            let screen = screensByDisplayID[displayID]
            return DisplaySnapshot(
                id: uuid,
                runtimeID: displayID,
                name: screen?.localizedName ?? "Display \(displayID)",
                frame: CGDisplayBounds(displayID),
                scale: Double(screen?.backingScaleFactor ?? 1),
                isMain: CGDisplayIsMain(displayID) != 0,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0
            )
        }
        .sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

enum DisplayDiscoveryError: Error, CustomStringConvertible {
    case unableToEnumerate

    var description: String {
        "AudioOrbit could not enumerate the connected displays. Reconnect the display and try again."
    }
}

private func audioOrbitDisplayReconfigurationCallback(
    _ displayID: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    _ = displayID
    _ = flags
    guard let userInfo else { return }
    Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue().handleChange()
}

final class DisplayMonitor {
    var onChange: (() -> Void)?
    private var isStarted = false

    func start() throws {
        guard !isStarted else { return }
        let error = CGDisplayRegisterReconfigurationCallback(
            audioOrbitDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard error == .success else { throw DisplayDiscoveryError.unableToEnumerate }
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        CGDisplayRemoveReconfigurationCallback(
            audioOrbitDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        isStarted = false
    }

    fileprivate func handleChange() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }

    deinit {
        stop()
    }
}
