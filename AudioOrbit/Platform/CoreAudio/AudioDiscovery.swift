import AppKit
import CoreAudio
import Foundation

struct AudioDiscovery {
    func snapshot() throws -> AudioDiscoverySnapshot {
        let defaultOutputID: AudioObjectID = try CoreAudioProperty.value(
            objectID: CoreAudioProperty.systemObject,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        return AudioDiscoverySnapshot(
            devices: try devices(defaultOutputID: defaultOutputID),
            processes: try processes()
        )
    }

    private func devices(defaultOutputID: AudioObjectID) throws -> [AudioDeviceSnapshot] {
        let ids: [AudioObjectID] = try CoreAudioProperty.array(
            objectID: CoreAudioProperty.systemObject,
            selector: kAudioHardwarePropertyDevices
        )

        return ids.compactMap { id in
            guard let channels = try? CoreAudioProperty.channelCount(
                objectID: id,
                scope: kAudioObjectPropertyScopeOutput
            ), channels > 0 else { return nil }

            guard let uid = try? CoreAudioProperty.string(
                objectID: id,
                selector: kAudioDevicePropertyDeviceUID
            ), let name = try? CoreAudioProperty.string(
                objectID: id,
                selector: kAudioObjectPropertyName
            ) else { return nil }

            let sampleRate = (try? CoreAudioProperty.value(
                Float64.self,
                objectID: id,
                selector: kAudioDevicePropertyNominalSampleRate
            )) ?? 0
            let aliveValue = (try? CoreAudioProperty.value(
                UInt32.self,
                objectID: id,
                selector: kAudioDevicePropertyDeviceIsAlive
            )) ?? 0

            let transportType = (try? CoreAudioProperty.value(
                UInt32.self,
                objectID: id,
                selector: kAudioDevicePropertyTransportType
            )) ?? kAudioDeviceTransportTypeUnknown
            let volume = AudioDeviceVolumeController().state(
                deviceID: id,
                outputChannelCount: channels
            )

            return AudioDeviceSnapshot(
                id: id,
                uid: uid,
                name: name,
                outputChannelCount: channels,
                nominalSampleRate: sampleRate,
                transportType: transportType,
                volumeScalar: volume.scalar,
                isVolumeSettable: volume.isSettable,
                isAlive: aliveValue != 0,
                isDefault: id == defaultOutputID
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func processes() throws -> [AudioProcessSnapshot] {
        let ids: [AudioObjectID] = try CoreAudioProperty.array(
            objectID: CoreAudioProperty.systemObject,
            selector: kAudioHardwarePropertyProcessObjectList
        )

        return ids.compactMap { id in
            guard let pid: pid_t = try? CoreAudioProperty.value(
                objectID: id,
                selector: kAudioProcessPropertyPID
            ) else { return nil }

            let bundleIdentifier = try? CoreAudioProperty.string(
                objectID: id,
                selector: kAudioProcessPropertyBundleID
            )
            let runningOutputValue = (try? CoreAudioProperty.value(
                UInt32.self,
                objectID: id,
                selector: kAudioProcessPropertyIsRunningOutput
            )) ?? 0
            let runningApplication = NSRunningApplication(processIdentifier: pid)
            let displayName = runningApplication?.localizedName
                ?? bundleIdentifier?.split(separator: ".").last.map(String.init)
                ?? "Process \(pid)"

            return AudioProcessSnapshot(
                id: id,
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                name: displayName,
                isRunningOutput: runningOutputValue != 0
            )
        }
        .sorted {
            if $0.isRunningOutput != $1.isRunningOutput { return $0.isRunningOutput }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
