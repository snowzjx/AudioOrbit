import CoreAudio
import Foundation

struct ConcurrentRouteAdmission {
    static func canStart(
        processID: AudioObjectID?,
        deviceID: AudioObjectID?,
        processes: [AudioProcessSnapshot],
        devices: [AudioDeviceSnapshot],
        activeSourcePIDs: Set<pid_t>
    ) -> Bool {
        guard let process = processes.first(where: { $0.id == processID }),
              let device = devices.first(where: { $0.id == deviceID }),
              device.isAlive else { return false }
        return !activeSourcePIDs.contains(process.pid)
    }

    static func suggestedProcessID(
        processes: [AudioProcessSnapshot],
        activeSourcePIDs: Set<pid_t>
    ) -> AudioObjectID? {
        let available = processes.filter { !activeSourcePIDs.contains($0.pid) }
        return available.first(where: \.isRunningOutput)?.id ?? available.first?.id
    }

    static func suggestedDeviceID(
        devices: [AudioDeviceSnapshot],
        activeDestinationUIDs: Set<String>
    ) -> AudioObjectID? {
        let available = devices.filter(\.isAlive)
        return available.first(where: {
            !$0.isDefault && !activeDestinationUIDs.contains($0.uid)
        })?.id
            ?? available.first(where: { !$0.isDefault })?.id
            ?? available.first?.id
    }
}
