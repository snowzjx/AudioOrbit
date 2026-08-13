import CoreAudio
import Foundation

struct AudioDeviceVolumeState: Equatable, Sendable {
    let scalar: Float?
    let isSettable: Bool
}

struct AudioDeviceVolumeController {
    func state(deviceID: AudioObjectID, outputChannelCount: UInt32) -> AudioDeviceVolumeState {
        let elements = controllableElements(
            deviceID: deviceID,
            outputChannelCount: outputChannelCount
        )
        let readable = elements.compactMap { element in
            try? CoreAudioProperty.value(
                Float32.self,
                objectID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: element
            )
        }
        let scalar = readable.isEmpty
            ? nil
            : readable.reduce(0, +) / Float(readable.count)
        return AudioDeviceVolumeState(
            scalar: scalar.map { min(1, max(0, $0)) },
            isSettable: !elements.isEmpty
        )
    }

    func setVolume(
        _ scalar: Float,
        deviceID: AudioObjectID,
        outputChannelCount: UInt32
    ) throws {
        let clamped = min(1, max(0, scalar))
        let elements = controllableElements(
            deviceID: deviceID,
            outputChannelCount: outputChannelCount
        )
        guard !elements.isEmpty else {
            throw AudioDeviceVolumeError.notSettable
        }
        for element in elements {
            try CoreAudioProperty.setFloat32(
                clamped,
                objectID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: element
            )
        }
    }

    private func controllableElements(
        deviceID: AudioObjectID,
        outputChannelCount: UInt32
    ) -> [AudioObjectPropertyElement] {
        if supportsSettableVolume(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        return (1...max(1, outputChannelCount)).compactMap { channel in
            let element = AudioObjectPropertyElement(channel)
            return supportsSettableVolume(deviceID: deviceID, element: element)
                ? element
                : nil
        }
    }

    private func supportsSettableVolume(
        deviceID: AudioObjectID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        CoreAudioProperty.hasProperty(
            objectID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput,
            element: element
        ) && CoreAudioProperty.isSettable(
            objectID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput,
            element: element
        )
    }
}

enum AudioDeviceVolumeError: Error, CustomStringConvertible {
    case notSettable

    var description: String {
        "This output has a fixed level or manages volume on the device itself."
    }
}
