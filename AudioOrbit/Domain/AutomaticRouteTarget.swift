import Foundation

struct AutomaticRouteTarget: Equatable, Sendable {
    let sourcePID: pid_t
    let sourceDisplayName: String
    let displayUUID: UUID
    let displayName: String
    let destinationDeviceUID: String
}

enum AutomaticRouteTargetPolicy {
    static func resolve(
        source: AudioProcessSnapshot,
        association: ProcessWindowAssociation?,
        evidence: WindowDisplayEvidence?,
        displays: [DisplaySnapshot],
        mappings: [DisplayAudioMapping],
        devices: [AudioDeviceSnapshot]
    ) -> AutomaticRouteTarget? {
        guard let association,
              let displayUUID = evidence?.displayUUID,
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
