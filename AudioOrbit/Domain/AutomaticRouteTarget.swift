import Foundation

struct AutomaticRouteTarget: Equatable, Sendable {
    let sourcePID: pid_t
    let sourceDisplayName: String
    let displayUUID: UUID
    let displayName: String
    let destinationDeviceUID: String
}

enum AutomaticRouteEligibilityPolicy {
    static func applicationBundleIdentifier(
        source: AudioProcessSnapshot,
        association: ProcessWindowAssociation?
    ) -> String? {
        association?.windowOwner.bundleIdentifier ?? source.bundleIdentifier
    }

    static func shouldManage(
        source: AudioProcessSnapshot,
        association: ProcessWindowAssociation?,
        ignoredBundleIdentifiers: Set<String>
    ) -> Bool {
        guard let bundleIdentifier = applicationBundleIdentifier(
            source: source,
            association: association
        ) else { return true }
        return !ignoredBundleIdentifiers.contains(bundleIdentifier)
    }
}

enum AutomaticRouteTargetPolicy {
    static func resolve(
        source: AudioProcessSnapshot,
        association: ProcessWindowAssociation?,
        evidence: WindowDisplayEvidence?,
        displayUUID explicitDisplayUUID: UUID? = nil,
        displays: [DisplaySnapshot],
        mappings: [DisplayAudioMapping],
        devices: [AudioDeviceSnapshot]
    ) -> AutomaticRouteTarget? {
        guard let association,
              let displayUUID = explicitDisplayUUID ?? evidence?.displayUUID,
              let display = displays.first(where: { $0.id == displayUUID }),
              let mapping = mappings.first(where: { $0.displayUUID == displayUUID }),
              mapping.behavior == .routeToDevice,
              let destination = mapping.resolvedDevice(in: devices) else { return nil }
        return AutomaticRouteTarget(
            sourcePID: source.pid,
            sourceDisplayName: association.windowOwner.name,
            displayUUID: displayUUID,
            displayName: display.name,
            destinationDeviceUID: destination.uid
        )
    }
}
